#!/bin/bash
# MTProxyL — гео-блокировка по странам

GEOBLOCK_CACHE_DIR="${INSTALL_DIR}/geoblock"
GEOBLOCK_IPSET_PREFIX="mtproxyl_"
GEOBLOCK_COMMENT="mtproxyl-geoblock"
GEOBLOCK_SERVICE="mtproxyl-geoblock"
GEOBLOCK_UNIT="/etc/systemd/system/${GEOBLOCK_SERVICE}.service"

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

geoblock_ports() {
    local _proxy="${PROXY_PORT:-443}" _web="" _proxy_printed="false"
    if ! declare -F mtproto_is_enabled >/dev/null || mtproto_is_enabled; then
        printf '%s\n' "$_proxy"
        _proxy_printed="true"
    fi
    if declare -F web_is_enabled >/dev/null && web_is_enabled \
        && { web_frontend_is_direct || ! mtproto_is_enabled; }; then
        _web=$(web_public_port 2>/dev/null)
        [ -z "$_web" ] || { [ "$_proxy_printed" = "true" ] && [ "$_web" = "$_proxy" ]; } \
            || printf '%s\n' "$_web"
    fi
}

geoblock_ports_label() {
    geoblock_ports | sort -nu | paste -sd, -
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
    local _tmp; _tmp=$(_mktemp "$GEOBLOCK_CACHE_DIR") || return 1
    if ! curl -fsSL --max-time 30 "$url" -o "$_tmp" 2>/dev/null || [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"
        if [ -s "$cache_file" ]; then
            log_warn "Не удалось обновить список ${code^^} — используется сохранённый"
            return 0
        fi
        log_error "Не удалось загрузить IP-список для ${code^^} — проверьте код страны"
        return 1
    fi
    mv "$_tmp" "$cache_file"

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

    local _port
    while IFS= read -r _port; do
        if ! _geoblock_rule_present "$setname" "$_target" "$_port"; then
            _ipt -I INPUT -m set --match-set "$setname" src \
                -p tcp --dport "$_port" \
                -m comment --comment "$GEOBLOCK_COMMENT" -j "$_target" || {
                log_error "iptables: правило для ${code^^} на порту ${_port} добавить не удалось"
                return 1
            }
        fi
    done < <(geoblock_ports)

    log_success "Гео-${GEOBLOCK_MODE} для ${code^^} (порты $(geoblock_ports_label))"
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
    local _port
    while IFS= read -r _port; do
        _ipt -D INPUT -m set --match-set "$setname" src \
            -p tcp --dport "$_port" \
            -m comment --comment "$GEOBLOCK_COMMENT" -j DROP 2>/dev/null || true
        _ipt -D INPUT -m set --match-set "$setname" src \
            -p tcp --dport "$_port" \
            -m comment --comment "$GEOBLOCK_COMMENT" -j ACCEPT 2>/dev/null || true
    done < <({ geoblock_ports; geoblock_rules_ports; } | sort -nu)
    ipset destroy "$setname" 2>/dev/null || true
}

_remove_default_drop() {
    local _port
    while IFS= read -r _port; do
        _ipt -D INPUT -p tcp --dport "$_port" \
            -m comment --comment "${GEOBLOCK_COMMENT}-default" -j DROP 2>/dev/null || true
    done < <({ geoblock_ports; geoblock_rules_ports; } | sort -nu)
}

_ensure_default_drop() {
    [ "$GEOBLOCK_MODE" = "whitelist" ] || return 0
    [ -n "$BLOCKLIST_COUNTRIES" ] || return 0
    local _port
    while IFS= read -r _port; do
        if ! _ipt -C INPUT -p tcp --dport "$_port" \
            -m comment --comment "${GEOBLOCK_COMMENT}-default" -j DROP 2>/dev/null; then
            local _allows _position
            _allows=$(_ipt_dump | grep -E -- "^-A INPUT .*--comment \"?${GEOBLOCK_COMMENT}\"?.*-j ACCEPT" | wc -l)
            _position=$((_allows + 1))
            _ipt -I INPUT "$_position" -p tcp --dport "$_port" \
                -m comment --comment "${GEOBLOCK_COMMENT}-default" -j DROP || {
                log_error "iptables: запрещающее правило на порту ${_port} добавить не удалось"
                return 1
            }
        fi
    done < <(geoblock_ports)
}

# Проверяем правила в ядре, а не только сохранённый список стран.
geoblock_rules_active() {
    [ -n "$BLOCKLIST_COUNTRIES" ] || return 1
    command -v iptables &>/dev/null || return 1
    local _dump; _dump=$(_ipt_dump) || return 1
    grep -Eq -- "--comment \"?${GEOBLOCK_COMMENT}\"?([[:space:]]|$)" <<< "$_dump" || return 1
    if [ "${GEOBLOCK_MODE:-blacklist}" = "whitelist" ]; then
        local _port
        while IFS= read -r _port; do
            _ipt -C INPUT -p tcp --dport "$_port" \
                -m comment --comment "${GEOBLOCK_COMMENT}-default" -j DROP 2>/dev/null || return 1
        done < <(geoblock_ports)
    fi
    return 0
}

# Порт, на который реально навешаны правила (может отличаться от текущего
# PROXY_PORT, если порт меняли уже после применения).
geoblock_rules_port() {
    geoblock_rules_ports | sed -n '1p'
}

geoblock_rules_ports() {
    command -v iptables &>/dev/null || return 1
    local _dump; _dump=$(_ipt_dump) || return 1
    grep -E -- "--comment \"?${GEOBLOCK_COMMENT}(-default)?\"?" <<< "$_dump" \
        | grep -oE '\--dport [0-9]+' | awk '{print $2}' | sort -nu
}

geoblock_rules_match_ports() {
    [ "$(geoblock_rules_ports)" = "$(geoblock_ports | sort -nu)" ]
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
        # Успех молчит: на два десятка стран это два десятка строк. Причину
        # неудачи, наоборот, показываем — иначе счётчик ни о чём не говорит.
        local _out
        if _out=$(_apply_country_rules "$code" 2>&1); then
            GEOBLOCK_APPLIED=$((GEOBLOCK_APPLIED + 1))
        else
            GEOBLOCK_FAILED=$((GEOBLOCK_FAILED + 1))
            [ -n "$_out" ] && printf '%s\n' "$_out"
        fi
    done
    if [ "$GEOBLOCK_MODE" = "whitelist" ] && [ "$GEOBLOCK_APPLIED" -gt 0 ]; then
        _ensure_default_drop || return 1
    fi
    [ "$GEOBLOCK_APPLIED" -gt 0 ] && [ "$GEOBLOCK_FAILED" -eq 0 ] \
        && [ -z "$GEOBLOCK_NOCACHE" ]
}

geoblock_mode_title() {
    [ "${GEOBLOCK_MODE:-blacklist}" = "whitelist" ] \
        && echo "разрешать только выбранные" || echo "блокировать выбранные"
}

geoblock_service_enabled() {
    command -v systemctl &>/dev/null || return 1
    systemctl is-enabled --quiet "$GEOBLOCK_SERVICE" 2>/dev/null
}

geoblock_install_service() {
    command -v systemctl &>/dev/null || return 0
    cat > "$GEOBLOCK_UNIT" <<UNIT_EOF
[Unit]
Description=MTProxyL country rules
After=network-online.target nftables.service netfilter-persistent.service
Wants=network-online.target
Before=mtproxyl.service mtproxyl-telemt.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${INSTALL_DIR}/mtproxyl.sh geoblock restore

[Install]
WantedBy=multi-user.target
UNIT_EOF
    systemctl daemon-reload
    systemctl enable "$GEOBLOCK_SERVICE" &>/dev/null || {
        log_error "Не удалось включить ${GEOBLOCK_SERVICE}.service"
        return 1
    }
}

geoblock_remove_service() {
    command -v systemctl &>/dev/null || return 0
    systemctl disable --now "$GEOBLOCK_SERVICE" &>/dev/null || true
    rm -f "$GEOBLOCK_UNIT"
    systemctl daemon-reload
}

geoblock_restore() {
    [ -n "${BLOCKLIST_COUNTRIES:-}" ] || return 0
    command -v ipset &>/dev/null || { log_error "ipset не установлен"; return 1; }
    geoblock_remove_all >/dev/null 2>&1 || true
    if geoblock_reapply_all && geoblock_rules_active; then
        log_success "Гео-блокировка восстановлена на портах $(geoblock_ports_label)"
        return 0
    fi
    log_error "Гео-блокировку после загрузки восстановить не удалось"
    return 1
}

geoblock_set_mode() {
    local _new="${1:-}" _old="${GEOBLOCK_MODE:-blacklist}" _code
    local -a _codes=()
    case "$_new" in
        blacklist|whitelist) ;;
        *) log_error "Режим: blacklist или whitelist"; return 1 ;;
    esac
    [ "$_new" != "$_old" ] || { log_info "Режим уже включён: $(geoblock_mode_title)"; return 0; }
    IFS=',' read -ra _codes <<< "${BLOCKLIST_COUNTRIES:-}"
    for _code in "${_codes[@]}"; do
        [ -z "$_code" ] || _download_country_cidrs "$_code" || return 1
    done
    GEOBLOCK_MODE="$_new"
    save_settings
    geoblock_remove_all >/dev/null 2>&1 || true
    if [ -z "${BLOCKLIST_COUNTRIES:-}" ] || geoblock_reapply_all; then
        if [ -z "${BLOCKLIST_COUNTRIES:-}" ]; then
            geoblock_remove_service
        else
            geoblock_install_service || true
        fi
        log_success "Режим: $(geoblock_mode_title)"
        if [ "$_new" = "whitelist" ] && [ -z "${BLOCKLIST_COUNTRIES:-}" ]; then
            log_info "Список пуст — ограничения включатся после добавления первой страны"
        fi
        return 0
    fi
    GEOBLOCK_MODE="$_old"
    save_settings
    geoblock_remove_all >/dev/null 2>&1 || true
    geoblock_reapply_all >/dev/null 2>&1 || true
    log_error "Новый режим не применился, возвращён прежний"
    return 1
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
                geoblock_install_service || true
                if ! geoblock_rules_active || ! geoblock_rules_match_ports; then
                    geoblock_restore || return 1
                fi
            else
                _ensure_ipset && _download_country_cidrs "$code" && {
                    [ -z "$BLOCKLIST_COUNTRIES" ] && BLOCKLIST_COUNTRIES="$code" || BLOCKLIST_COUNTRIES="${BLOCKLIST_COUNTRIES},${code}"
                    save_settings
                    _apply_country_rules "$code" || return 1
                    _ensure_default_drop || return 1
                    geoblock_install_service || true
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
                if [ -z "$BLOCKLIST_COUNTRIES" ]; then
                    _remove_default_drop
                    geoblock_remove_service
                fi
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
            geoblock_remove_service
            log_success "Все гео-блокировки сняты"
            ;;
        mode)
            check_root
            geoblock_set_mode "${2:-}"
            ;;
        restore)
            check_root
            geoblock_restore
            ;;
        reapply)
            check_root
            [ -z "$BLOCKLIST_COUNTRIES" ] && { log_info "Список стран пуст — нечего применять"; return 0; }
            _ensure_ipset || return 1
            log_info "Переприменение гео-блокировки на порты $(geoblock_ports_label)..."
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
                geoblock_install_service || true
                log_success "Гео-блокировка применена: ${GEOBLOCK_APPLIED} из ${_total} (порты $(geoblock_ports_label))"
                [ "$GEOBLOCK_FAILED" -gt 0 ] && \
                    log_warn "Не применились: ${GEOBLOCK_FAILED} — причина выше"
                if [ "$GEOBLOCK_FAILED" -gt 0 ] || [ -n "$GEOBLOCK_NOCACHE" ]; then
                    return 1
                fi
            else
                log_error "Правила применить не удалось"
                [ -n "$GEOBLOCK_NOCACHE" ] && \
                    log_info "Списки IP не скачались — проверьте доступ к ipdeny.com"
                return 1
            fi
            ;;
        list|"")
            if [ "${2:-}" = "--json" ]; then
                geoblock_list_json
                return 0
            fi
            echo -e "  ${BOLD}Выбранные страны:${NC} ${BLOCKLIST_COUNTRIES:-${DIM}нет${NC}}"
            echo -e "  ${BOLD}Режим:${NC} $(geoblock_mode_title)"
            echo -e "  ${BOLD}После загрузки:${NC} $(geoblock_service_enabled && echo -e "${GREEN}восстановятся${NC}" || echo -e "${YELLOW}служба не включена${NC}")"
            if [ "${GEOBLOCK_MODE:-blacklist}" = "whitelist" ] && [ -z "${BLOCKLIST_COUNTRIES:-}" ]; then
                echo -e "  ${BOLD}Ограничения:${NC} ${YELLOW}не активны до добавления первой страны${NC}"
            fi
            if [ -n "$BLOCKLIST_COUNTRIES" ]; then
                if geoblock_rules_active; then
                    local _rp; _rp=$(geoblock_rules_ports | paste -sd, -)
                    if ! geoblock_rules_match_ports; then
                        echo -e "  ${BOLD}Правила:${NC} ${YELLOW}на портах ${_rp:-—}, нужны $(geoblock_ports_label)${NC}"
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
            echo -e "    ${GREEN}geoblock add${NC} <CC>      Добавить страну"
            echo -e "    ${GREEN}geoblock remove${NC} <CC>   Удалить страну"
            echo -e "    ${GREEN}geoblock mode${NC} blacklist|whitelist"
            echo -e "    ${GREEN}geoblock list${NC}          Список и состояние правил"
            echo -e "    ${GREEN}geoblock reapply${NC}       Переприменить сейчас"
            echo -e "    ${GREEN}geoblock clear${NC}         Очистить все"
            ;;
    esac
}

# Машинное состояние гео-блокировки для панели.
geoblock_list_json() {
    local _c _first=1
    printf '{"mode":"%s","rules_active":%s,"ports_match":%s,"service_enabled":%s,"countries":[' \
        "$(json_escape "${GEOBLOCK_MODE:-blacklist}")" \
        "$(geoblock_rules_active && echo true || echo false)" \
        "$(geoblock_rules_match_ports && echo true || echo false)" \
        "$(geoblock_service_enabled && echo true || echo false)"
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
