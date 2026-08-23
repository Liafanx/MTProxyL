#!/bin/bash
# MTProxyL — гео-блокировка по странам

GEOBLOCK_CACHE_DIR="${INSTALL_DIR}/geoblock"
GEOBLOCK_IPSET_PREFIX="mtproxyl_"
GEOBLOCK_COMMENT="mtproxyl-geoblock"

# Блокировку xtables держат соседи: zapret2 и synlimit движка правят те же
# таблицы. Без ожидания вызов просто падает, а правило молча не применяется.
_IPT_WAIT=""
_ipt() {
    if [ -z "$_IPT_WAIT" ]; then
        if iptables -w 5 -n -L INPUT >/dev/null 2>&1; then _IPT_WAIT="wait"; else _IPT_WAIT="no"; fi
    fi
    if [ "$_IPT_WAIT" = "wait" ]; then iptables -w 5 "$@"; else iptables "$@"; fi
}

# Дамп забираем в переменную, а не в конвейер: iptables-save большой, а
# `| grep -q` обрывает его на первом совпадении. При включённом pipefail
# SIGPIPE у iptables-save становится статусом всего конвейера, и найденное
# правило считалось бы отсутствующим.
_ipt_dump() {
    command -v iptables &>/dev/null || return 1
    iptables-save 2>/dev/null || true
}

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

    ipset create -exist "$setname" hash:net family inet maxelem 131072 || {
        log_error "ipset ${setname}: не удалось создать набор"; return 1; }
    ipset flush "$setname"

    if ! awk -v s="$setname" 'NF && !/^#/ { print "add " s " " $1 }' "$cache_file" \
        | ipset restore -exist; then
        log_error "ipset ${setname}: не удалось загрузить диапазоны"
        return 1
    fi

    local _target="DROP"
    [ "$GEOBLOCK_MODE" = "whitelist" ] && _target="ACCEPT"

    if ! _geoblock_rule_present "$setname" "$_target" "$PROXY_PORT"; then
        _ipt -I INPUT -m set --match-set "$setname" src \
            -p tcp --dport "$PROXY_PORT" \
            -m comment --comment "$GEOBLOCK_COMMENT" -j "$_target" || {
            log_error "iptables: правило для ${code^^} добавить не удалось"; return 1; }
    fi

    log_success "Гео-${GEOBLOCK_MODE} для ${code^^} (порт ${PROXY_PORT})"
}

# Точная проверка одного правила: -C сверяет спецификацию целиком, поэтому
# не зависит от того, как iptables-save печатает комментарий.
_geoblock_rule_present() {
    local _set="$1" _target="$2" _port="$3"
    _ipt -C INPUT -m set --match-set "$_set" src \
        -p tcp --dport "$_port" \
        -m comment --comment "$GEOBLOCK_COMMENT" -j "$_target" 2>/dev/null
}

_remove_country_rules() {
    local code="$1"
    local setname="${GEOBLOCK_IPSET_PREFIX}${code}"

    _ipt -D INPUT -m set --match-set "$setname" src \
        -p tcp --dport "$PROXY_PORT" \
        -m comment --comment "$GEOBLOCK_COMMENT" -j DROP 2>/dev/null || true
    _ipt -D INPUT -m set --match-set "$setname" src \
        -p tcp --dport "$PROXY_PORT" \
        -m comment --comment "$GEOBLOCK_COMMENT" -j ACCEPT 2>/dev/null || true
    ipset destroy "$setname" 2>/dev/null || true
}

_remove_default_drop() {
    _ipt -D INPUT -p tcp --dport "$PROXY_PORT" \
        -m comment --comment "${GEOBLOCK_COMMENT}-default" -j DROP 2>/dev/null || true
}

_ensure_default_drop() {
    [ "$GEOBLOCK_MODE" = "whitelist" ] || return 0
    [ -n "$BLOCKLIST_COUNTRIES" ] || return 0
    if ! _ipt -C INPUT -p tcp --dport "$PROXY_PORT" \
        -m comment --comment "${GEOBLOCK_COMMENT}-default" -j DROP 2>/dev/null; then
        _ipt -A INPUT -p tcp --dport "$PROXY_PORT" \
            -m comment --comment "${GEOBLOCK_COMMENT}-default" -j DROP || {
            log_error "iptables: запрещающее правило по умолчанию добавить не удалось"; return 1; }
    fi
}

# Правила гео-блокировки живут в iptables/ipset и не переживают
# перезагрузку сервера, а после смены порта прокси остаются висеть на
# старом. Проверяем факт, а не запись в настройках.
geoblock_rules_active() {
    [ -n "$BLOCKLIST_COUNTRIES" ] || return 1
    command -v iptables &>/dev/null || return 1
    local _dump; _dump=$(_ipt_dump) || return 1
    grep -q -- "--comment ${GEOBLOCK_COMMENT}" <<< "$_dump"
}

# Порт, на который реально навешаны правила (может отличаться от текущего
# PROXY_PORT, если порт меняли уже после применения).
geoblock_rules_port() {
    command -v iptables &>/dev/null || return 1
    local _dump; _dump=$(_ipt_dump) || return 1
    grep -- "--comment ${GEOBLOCK_COMMENT}" <<< "$_dump" \
        | grep -oE '\--dport [0-9]+' | awk '{print $2}' | sort -u | sed -n '1p'
}

# Счётчики заполняются для вызывающего: он один знает, ругаться ли на
# частичный результат. Возврат — 0, если применилась хоть одна страна.
GEOBLOCK_APPLIED=0
GEOBLOCK_FAILED=0
GEOBLOCK_NOCACHE=""

geoblock_reapply_all() {
    GEOBLOCK_APPLIED=0; GEOBLOCK_FAILED=0; GEOBLOCK_NOCACHE=""
    [ -z "$BLOCKLIST_COUNTRIES" ] && return 0
    command -v ipset &>/dev/null || return 1

    local code
    IFS=',' read -ra codes <<< "$BLOCKLIST_COUNTRIES"
    for code in "${codes[@]}"; do
        [ -z "$code" ] && continue
        if [ ! -f "${GEOBLOCK_CACHE_DIR}/${code}.zone" ]; then
            GEOBLOCK_NOCACHE="${GEOBLOCK_NOCACHE}${GEOBLOCK_NOCACHE:+, }${code}"
            continue
        fi
        if _apply_country_rules "$code" >/dev/null 2>&1; then
            GEOBLOCK_APPLIED=$((GEOBLOCK_APPLIED + 1))
        else
            GEOBLOCK_FAILED=$((GEOBLOCK_FAILED + 1))
        fi
    done
    _ensure_default_drop || true
    [ "$GEOBLOCK_APPLIED" -gt 0 ]
}

geoblock_remove_all() {
    if command -v iptables &>/dev/null; then
        local _dump; _dump=$(_ipt_dump)
        # Комментарий в дампе бывает и в кавычках: без снятия правило
        # уходило бы в iptables вместе с ними и не удалялось.
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            _ipt $rule 2>/dev/null || true
        done < <(grep -E -- "--comment \"?${GEOBLOCK_COMMENT}(-default)?\"?" <<< "$_dump" \
                    | sed 's/^-A/-D/; s/--comment "\([^"]*\)"/--comment \1/')
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
            geoblock_reapply_all || true
            local _total=$((GEOBLOCK_APPLIED + GEOBLOCK_FAILED))
            [ -n "$GEOBLOCK_NOCACHE" ] && \
                log_warn "Без списка IP, пропущены: ${GEOBLOCK_NOCACHE}"
            if [ "$GEOBLOCK_APPLIED" -gt 0 ]; then
                log_success "Гео-блокировка применена: ${GEOBLOCK_APPLIED} из ${_total} (порт ${PROXY_PORT})"
                [ "$GEOBLOCK_FAILED" -gt 0 ] && \
                    log_warn "Не применились: ${GEOBLOCK_FAILED} — подробности в mtproxyl geoblock list"
            else
                log_error "Правила применить не удалось"
                [ -n "$GEOBLOCK_NOCACHE" ] && \
                    log_info "Списки IP не скачались — проверьте доступ к ipdeny.com"
            fi
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
