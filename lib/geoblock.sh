#!/bin/bash
# MTProxyL — гео-блокировка по странам

GEOBLOCK_CACHE_DIR="${INSTALL_DIR}/geoblock"
GEOBLOCK_IPSET_PREFIX="mtproxyl_"
GEOBLOCK_COMMENT="mtproxyl-geoblock"

_ensure_ipset() {
    command -v ipset &>/dev/null && return 0
    log_info "Установка ipset..."
    _wait_apt
    local os; os=$(detect_os)
    case "$os" in
        debian) apt-get install -y -qq ipset ;;
        rhel)   yum install -y -q ipset ;;
        alpine) apk add --no-cache ipset ;;
    esac
    command -v ipset &>/dev/null || { log_error "Не удалось установить ipset"; return 1; }
}

_download_country_cidrs() {
    local code="$1"
    local cache_file="${GEOBLOCK_CACHE_DIR}/${code}.zone"
    mkdir -p "$GEOBLOCK_CACHE_DIR"

    # Кэш 24 часа
    if [ -f "$cache_file" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) )) -lt 86400 ]; then
        return 0
    fi

    log_info "Загрузка IP-списка для ${code^^}..."
    local url="https://www.ipdeny.com/ipblocks/data/aggregated/${code}-aggregated.zone"
    if ! curl -fsSL --max-time 30 "$url" -o "$cache_file" 2>/dev/null; then
        rm -f "$cache_file"
        log_error "Не удалось загрузить IP-список для ${code^^} — проверьте код страны"
        return 1
    fi

    local count; count=$(wc -l < "$cache_file")
    log_info "Загружено ${count} IP-диапазонов для ${code^^}"
}

_apply_country_rules() {
    local code="$1"
    local setname="${GEOBLOCK_IPSET_PREFIX}${code}"
    local cache_file="${GEOBLOCK_CACHE_DIR}/${code}.zone"

    [ -f "$cache_file" ] || { log_error "Нет кэша IP для ${code}"; return 1; }

    ipset create -exist "$setname" hash:net family inet maxelem 131072
    ipset flush "$setname"

    awk -v s="$setname" 'NF && !/^#/ { print "add " s " " $1 }' "$cache_file" \
        | ipset restore -exist

    if [ "$GEOBLOCK_MODE" = "whitelist" ]; then
        if ! iptables -C INPUT -m set --match-set "$setname" src \
            -p tcp --dport "$PROXY_PORT" \
            -m comment --comment "$GEOBLOCK_COMMENT" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -m set --match-set "$setname" src \
                -p tcp --dport "$PROXY_PORT" \
                -m comment --comment "$GEOBLOCK_COMMENT" -j ACCEPT
        fi
    else
        if ! iptables -C INPUT -m set --match-set "$setname" src \
            -p tcp --dport "$PROXY_PORT" \
            -m comment --comment "$GEOBLOCK_COMMENT" -j DROP 2>/dev/null; then
            iptables -I INPUT -m set --match-set "$setname" src \
                -p tcp --dport "$PROXY_PORT" \
                -m comment --comment "$GEOBLOCK_COMMENT" -j DROP
        fi
    fi

    log_success "Гео-${GEOBLOCK_MODE} для ${code^^} (порт ${PROXY_PORT})"
}

_remove_country_rules() {
    local code="$1"
    local setname="${GEOBLOCK_IPSET_PREFIX}${code}"

    iptables -D INPUT -m set --match-set "$setname" src \
        -p tcp --dport "$PROXY_PORT" \
        -m comment --comment "$GEOBLOCK_COMMENT" -j DROP 2>/dev/null || true
    iptables -D INPUT -m set --match-set "$setname" src \
        -p tcp --dport "$PROXY_PORT" \
        -m comment --comment "$GEOBLOCK_COMMENT" -j ACCEPT 2>/dev/null || true
    ipset destroy "$setname" 2>/dev/null || true
}

_remove_default_drop() {
    iptables -D INPUT -p tcp --dport "$PROXY_PORT" \
        -m comment --comment "${GEOBLOCK_COMMENT}-default" -j DROP 2>/dev/null || true
}

_ensure_default_drop() {
    [ "$GEOBLOCK_MODE" = "whitelist" ] || return 0
    [ -n "$BLOCKLIST_COUNTRIES" ] || return 0
    if ! iptables -C INPUT -p tcp --dport "$PROXY_PORT" \
        -m comment --comment "${GEOBLOCK_COMMENT}-default" -j DROP 2>/dev/null; then
        iptables -A INPUT -p tcp --dport "$PROXY_PORT" \
            -m comment --comment "${GEOBLOCK_COMMENT}-default" -j DROP
    fi
}

# Правила гео-блокировки живут в iptables/ipset и не переживают
# перезагрузку сервера, а после смены порта прокси остаются висеть на
# старом. Проверяем факт, а не запись в настройках.
geoblock_rules_active() {
    [ -n "$BLOCKLIST_COUNTRIES" ] || return 1
    command -v iptables &>/dev/null || return 1
    iptables-save 2>/dev/null | grep -q -- "--comment ${GEOBLOCK_COMMENT}" || return 1
    return 0
}

# Порт, на который реально навешаны правила (может отличаться от текущего
# PROXY_PORT, если порт меняли уже после применения).
geoblock_rules_port() {
    command -v iptables &>/dev/null || return 1
    iptables-save 2>/dev/null \
        | grep -- "--comment ${GEOBLOCK_COMMENT}" \
        | grep -oE '\--dport [0-9]+' | awk '{print $2}' | sort -u | head -1
}

geoblock_reapply_all() {
    [ -z "$BLOCKLIST_COUNTRIES" ] && return 0
    command -v ipset &>/dev/null || return 0

    local code
    IFS=',' read -ra codes <<< "$BLOCKLIST_COUNTRIES"
    for code in "${codes[@]}"; do
        [ -z "$code" ] && continue
        [ -f "${GEOBLOCK_CACHE_DIR}/${code}.zone" ] && _apply_country_rules "$code" &>/dev/null || true
    done
    _ensure_default_drop
}

geoblock_remove_all() {
    if command -v iptables &>/dev/null; then
        iptables-save 2>/dev/null | grep -E -- "--comment ${GEOBLOCK_COMMENT}(-default)?" | \
            sed 's/^-A/-D/' | while IFS= read -r rule; do
                iptables $rule 2>/dev/null || true
            done
    fi

    if command -v ipset &>/dev/null; then
        ipset list -n 2>/dev/null | grep "^${GEOBLOCK_IPSET_PREFIX}" | \
            while IFS= read -r setname; do
                ipset destroy "$setname" 2>/dev/null || true
            done
    fi
}

handle_geoblock_command() {
    case "${1:-list}" in
        add)
            check_root
            local code=$(echo "$2" | tr '[:upper:]' '[:lower:]')
            [[ "$code" =~ ^[a-z]{2}$ ]] || { log_error "Код страны: 2 буквы (напр. us, de, ir)"; return 1; }
            if echo ",$BLOCKLIST_COUNTRIES," | grep -q ",${code},"; then
                log_info "Страна '${code^^}' уже в списке"
            else
                _ensure_ipset && _download_country_cidrs "$code" && {
                    [ -z "$BLOCKLIST_COUNTRIES" ] && BLOCKLIST_COUNTRIES="$code" || BLOCKLIST_COUNTRIES="${BLOCKLIST_COUNTRIES},${code}"
                    save_settings
                    _apply_country_rules "$code"
                    _ensure_default_drop
                }
            fi
            ;;
        remove)
            check_root
            local code=$(echo "$2" | tr '[:upper:]' '[:lower:]')
            [[ "$code" =~ ^[a-z]{2}$ ]] || { log_error "Код страны: 2 буквы"; return 1; }
            if echo ",$BLOCKLIST_COUNTRIES," | grep -q ",${code},"; then
                BLOCKLIST_COUNTRIES=$(echo ",$BLOCKLIST_COUNTRIES," | sed "s/,${code},/,/g;s/^,//;s/,$//")
                save_settings
                _remove_country_rules "$code"
                rm -f "${GEOBLOCK_CACHE_DIR}/${code}.zone"
                [ -z "$BLOCKLIST_COUNTRIES" ] && _remove_default_drop
                log_success "Удалена ${code^^}"
            else
                log_info "Страна '${code^^}' не в списке"
            fi
            ;;
        clear)
            check_root
            IFS=',' read -ra codes <<< "$BLOCKLIST_COUNTRIES"
            for code in "${codes[@]}"; do
                [ -z "$code" ] && continue
                _remove_country_rules "$code"
                rm -f "${GEOBLOCK_CACHE_DIR}/${code}.zone"
            done
            _remove_default_drop
            BLOCKLIST_COUNTRIES=""
            save_settings
            log_success "Все гео-блокировки сняты"
            ;;
        reapply)
            check_root
            [ -z "$BLOCKLIST_COUNTRIES" ] && { log_info "Список стран пуст — нечего применять"; return 0; }
            _ensure_ipset || return 1
            log_info "Переприменение гео-блокировки на порт ${PROXY_PORT}..."
            geoblock_remove_all >/dev/null 2>&1 || true
            local _code
            IFS=',' read -ra codes <<< "$BLOCKLIST_COUNTRIES"
            for _code in "${codes[@]}"; do
                [ -z "$_code" ] && continue
                _download_country_cidrs "$_code" || continue
            done
            geoblock_reapply_all
            geoblock_rules_active && log_success "Гео-блокировка применена (порт ${PROXY_PORT})" \
                || log_error "Правила применить не удалось"
            ;;
        list|"")
            if [ "${2:-}" = "--json" ]; then
                geoblock_list_json
                return 0
            fi
            echo -e "  ${BOLD}Заблокированные страны:${NC} ${BLOCKLIST_COUNTRIES:-${DIM}нет${NC}}"
            echo -e "  ${BOLD}Режим:${NC} ${GEOBLOCK_MODE}"
            if [ -n "$BLOCKLIST_COUNTRIES" ]; then
                if geoblock_rules_active; then
                    local _rp; _rp=$(geoblock_rules_port)
                    if [ -n "$_rp" ] && [ "$_rp" != "${PROXY_PORT}" ]; then
                        echo -e "  ${BOLD}Правила:${NC} ${YELLOW}висят на порту ${_rp}, а прокси на ${PROXY_PORT}${NC}"
                        echo -e "  ${DIM}Переприменить: mtproxyl geoblock reapply${NC}"
                    else
                        echo -e "  ${BOLD}Правила:${NC} ${GREEN}активны${NC}"
                    fi
                else
                    echo -e "  ${BOLD}Правила:${NC} ${RED}отсутствуют${NC} ${DIM}(сброшены перезагрузкой?)${NC}"
                    echo -e "  ${DIM}Восстановить: mtproxyl geoblock reapply${NC}"
                fi
            fi
            ;;
        *)
            echo -e "  ${BOLD}Гео-блокировка:${NC}"
            echo -e "    ${GREEN}geoblock add${NC} <CC>      Заблокировать страну"
            echo -e "    ${GREEN}geoblock remove${NC} <CC>   Разблокировать"
            echo -e "    ${GREEN}geoblock list${NC}          Список и состояние правил"
            echo -e "    ${GREEN}geoblock reapply${NC}       Переприменить (после перезагрузки/смены порта)"
            echo -e "    ${GREEN}geoblock clear${NC}         Очистить все"
            ;;
    esac
}

# Машинный список заблокированных стран для панели.
geoblock_list_json() {
    local _c _first=1
    printf '{"countries":['
    if [ -n "${BLOCKLIST_COUNTRIES:-}" ]; then
        IFS=',' read -ra _arr <<< "$BLOCKLIST_COUNTRIES"
        for _c in "${_arr[@]}"; do
            [ -n "$_c" ] || continue
            [ $_first -eq 1 ] || printf ','
            _first=0
            printf '"%s"' "$(json_escape "$_c")"
        done
    fi
    printf ']}\n'
}
