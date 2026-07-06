#!/bin/bash
# MTProxyL — подменю: дополнения (утилиты)

tui_addons_menu() {
    while true; do
        clear_screen
        draw_header "ДОПОЛНЕНИЯ (УТИЛИТЫ)"
        echo ""

        local _pq_installed="false"
        [ -x "$(_selfmask_pq_openssl_bin)" ] && _pq_installed="true"

        if [ "$_pq_installed" = "true" ]; then
            local _ver
            _ver=$("$(_selfmask_pq_openssl_bin)" version 2>/dev/null | awk '{print $2}')
            echo -e "  ${BOLD}PQ OpenSSL:${NC} ${GREEN}установлен${NC} (${_ver:-?})"
        else
            echo -e "  ${BOLD}PQ OpenSSL:${NC} ${DIM}не установлен${NC}"
            echo -e "  ${DIM}Для проверки PQ нужен PQ nginx (OpenSSL 3.5+).${NC}"
            echo -e "  ${DIM}Установите через: mtproxyl selfmask setup${NC}"
        fi

        echo ""
        echo -e "  ${CYAN}[1]${NC}  Проверить текущий SNI-домен на PQ"
        echo -e "  ${CYAN}[2]${NC}  Проверить произвольный домен на PQ"
        echo -e "  ${CYAN}[3]${NC}  Установить PQ OpenSSL (из Release)"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""

        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                if [ "$_pq_installed" != "true" ]; then
                    log_error "PQ OpenSSL не установлен"
                    log_info "Установите через: mtproxyl selfmask setup или меню [3]"
                else
                    local _domain="${PROXY_DOMAIN:-}"
                    if [ -z "$_domain" ]; then
                        log_warn "SNI-домен не задан"
                    else
                        _addon_check_pq_domain "$_domain"
                    fi
                fi
                press_any_key
                ;;
            2)
                if [ "$_pq_installed" != "true" ]; then
                    log_error "PQ OpenSSL не установлен"
                    log_info "Установите через: mtproxyl selfmask setup или меню [3]"
                else
                    echo -en "  ${BOLD}Домен (или домен:порт):${NC} "
                    local _input
                    read -r _input
                    [ -n "$_input" ] && _addon_check_pq_domain "$_input"
                fi
                press_any_key
                ;;
            3)
                _selfmask_install_pq_nginx
                press_any_key
                ;;
            0|"") return ;;
        esac
    done
}

_addon_check_pq_domain() {
    local _raw="$1"
    local _host _port

    _raw="${_raw#http://}"
    _raw="${_raw#https://}"
    _raw="${_raw%%/*}"

    if [[ "$_raw" == *:* ]]; then
        _host="${_raw%%:*}"
        _port="${_raw##*:}"
    else
        _host="$_raw"
        _port="443"
    fi

    [ -z "$_host" ] && { log_error "Пустой домен"; return 1; }

    echo ""
    draw_header "ПРОВЕРКА PQ: ${_host}:${_port}"
    echo ""

    local _openssl="$(_selfmask_pq_openssl_bin)"

    # DNS
    local _ips
    _ips=$(getent ahostsv4 "$_host" 2>/dev/null | awk '{print $1}' | sort -u | head -5)
    if [ -n "$_ips" ]; then
        echo -e "  ${BOLD}IP:${NC} $(echo "$_ips" | tr '\n' ', ' | sed 's/,$//')"
    else
        log_warn "Не удалось определить IP для ${_host}"
    fi
    echo ""

    # 1. PQ-подключение
    echo -e "  ${BOLD}━━━ PQ-подключение ━━━${NC}"
    local _pq_out
    _pq_out=$("$_openssl" s_client \
        -connect "${_host}:${_port}" \
        -servername "$_host" \
        -groups X25519MLKEM768 \
        -brief </dev/null 2>&1 || true)

    if echo "$_pq_out" | grep -q "CONNECTION ESTABLISHED"; then
        local _proto _cipher _temp _cert _sig _hash
        _proto=$(_pq_parse_field "$_pq_out" "Protocol version")
        _cipher=$(_pq_parse_field "$_pq_out" "Ciphersuite")
        _temp=$(_pq_parse_field "$_pq_out" "Peer Temp Key")
        _cert=$(_pq_parse_field "$_pq_out" "Peer certificate")
        _sig=$(_pq_parse_field "$_pq_out" "Signature type")
        _hash=$(_pq_parse_field "$_pq_out" "Hash used")

        echo -e "  ${GREEN}✅ Статус: поддерживается${NC}"
        [ -n "$_proto" ] && echo -e "    Протокол:    ${_proto}"
        [ -n "$_cipher" ] && echo -e "    Шифронабор:  ${_cipher}"
        [ -n "$_temp" ] && echo -e "    Temp Key:    ${_temp}"
        [ -n "$_cert" ] && echo -e "    Сертификат:  ${_cert}"
        [ -n "$_sig" ] && echo -e "    Подпись:     ${_sig}"
        [ -n "$_hash" ] && echo -e "    Хэш:        ${_hash}"

        echo ""
        echo -e "  ${GREEN}${BOLD}🟢 Маркер: НЕТ${NC} — сервер принимает X25519MLKEM768"
        return 0
    fi

    echo -e "  ${YELLOW}🔸 PQ не поддерживается${NC}"

    local _reason
    _reason=$(echo "$_pq_out" | grep -E "alert|error:" | head -1)
    [ -n "$_reason" ] && echo -e "    ${DIM}${_reason}${NC}"
    echo ""

    # 2. Обычное TLS
    echo -e "  ${BOLD}━━━ Обычное TLS ━━━${NC}"
    local _std_out
    _std_out=$("$_openssl" s_client \
        -connect "${_host}:${_port}" \
        -servername "$_host" \
        -brief </dev/null 2>&1 || true)

    if ! echo "$_std_out" | grep -q "CONNECTION ESTABLISHED"; then
        echo -e "  ${RED}❌ TLS-подключение не удалось${NC}"
        local _err
        _err=$(echo "$_std_out" | grep -E "alert|error:" | head -1)
        [ -n "$_err" ] && echo -e "    ${DIM}${_err}${NC}"
        return 1
    fi

    local _proto _cipher _temp _cert _sig _hash
    _proto=$(_pq_parse_field "$_std_out" "Protocol version")
    _cipher=$(_pq_parse_field "$_std_out" "Ciphersuite")
    _temp=$(_pq_parse_field "$_std_out" "Peer Temp Key")
    _cert=$(_pq_parse_field "$_std_out" "Peer certificate")
    _sig=$(_pq_parse_field "$_std_out" "Signature type")
    _hash=$(_pq_parse_field "$_std_out" "Hash used")

    echo -e "  ${GREEN}Подключение: OK${NC}"
    [ -n "$_proto" ] && echo -e "    Протокол:    ${_proto}"
    [ -n "$_cipher" ] && echo -e "    Шифронабор:  ${_cipher}"
    [ -n "$_temp" ] && echo -e "    Temp Key:    ${_temp}"
    [ -n "$_cert" ] && echo -e "    Сертификат:  ${_cert}"
    [ -n "$_sig" ] && echo -e "    Подпись:     ${_sig}"
    [ -n "$_hash" ] && echo -e "    Хэш:        ${_hash}"

    echo ""
    echo -e "  ${BOLD}━━━ Вердикт ━━━${NC}"

    if [[ "${_temp:-}" == X25519 ]] || [[ "${_temp:-}" == X25519,* ]]; then
        echo -e "  ${RED}${BOLD}🔴 МАРКЕР: ДА${NC}"
        echo -e "  ${RED}PQ не поддерживается + Peer Temp Key = X25519${NC}"
        echo -e "  ${YELLOW}⚠️ Риск блокировки на ТСПУ для iOS клиентов${NC}"
    else
        echo -e "  ${GREEN}${BOLD}🟢 Маркер: НЕТ${NC}"
        echo -e "  ${DIM}PQ не поддерживается, но Peer Temp Key не X25519${NC}"
    fi
}

_pq_parse_field() {
    local _text="$1" _key="$2"
    echo "$_text" | while IFS= read -r _line; do
        local _stripped="${_line#"${_line%%[![:space:]]*}"}"
        if [[ "$_stripped" == "${_key}:"* ]]; then
            echo "${_stripped#*: }"
            return 0
        fi
    done
}
