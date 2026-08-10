#!/bin/bash
# MTProxyL — подменю: дополнения (утилиты)

tui_addons_menu() {
    while true; do
        clear_screen
        draw_header "ДОПОЛНЕНИЯ (УТИЛИТЫ)"
        echo ""

        # Проверять PQ умеет любой OpenSSL 3.5.0+, включая системный: раньше
        # спрашивалась только своя сборка.
        local _pq_available="false" _pq_bin=""
        if _pq_bin=$(_pq_openssl_bin 2>/dev/null); then
            _pq_available="true"
        fi

        if [ "$_pq_available" = "true" ]; then
            local _ver
            _ver=$("$_pq_bin" version 2>/dev/null | awk '{print $2}')
            echo -e "  ${BOLD}PQ OpenSSL:${NC} ${GREEN}есть${NC} — $(_pq_openssl_source) (${_ver:-?})"
        else
            echo -e "  ${BOLD}PQ OpenSSL:${NC} ${DIM}нет${NC}"
            echo -e "  ${DIM}Нужен системный OpenSSL ${SELFMASK_MIN_SYSTEM_OPENSSL}+ либо сборка из состава MTProxyL.${NC}"
            echo -e "  ${DIM}Поставить нашу: пункт [3] ниже.${NC}"
        fi

        local _geoip_installed="false"
        geoip_installed && _geoip_installed="true"

        if [ "$_geoip_installed" = "true" ]; then
            echo -e "  ${BOLD}GeoIP:${NC} ${GREEN}установлен${NC}"
        else
            echo -e "  ${BOLD}GeoIP:${NC} ${DIM}не установлен${NC} ${DIM}(страна/город/ASN для истории IP)${NC}"
        fi

        echo ""
        echo -e "  ${CYAN}[1]${NC}  Проверить текущий SNI-домен на PQ"
        echo -e "  ${CYAN}[2]${NC}  Проверить произвольный домен на PQ"
        echo -e "  ${CYAN}[3]${NC}  Установить PQ OpenSSL (из Release)"
        echo -e "  ${CYAN}[4]${NC}  Проверка ограничений сервера (censorcheck)"
        echo -e "  ${CYAN}[5]${NC}  Selfmask (заглушка + сертификат)"
        echo -e "  ${CYAN}[6]${NC}  Веб-панель MTProxyL-Panel  ${DIM}$(panel_status_line)${NC}"
        echo -e "  ${CYAN}[7]${NC}  $([ "$_geoip_installed" = "true" ] && echo "Переустановить" || echo "Установить") базу GeoIP"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""

        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                if [ "$_pq_available" != "true" ]; then
                    log_error "Нет OpenSSL с поддержкой постквантового обмена ключами"
                    log_info "Нужен системный OpenSSL ${SELFMASK_MIN_SYSTEM_OPENSSL}+ либо сборка из состава MTProxyL (меню [3])"
                else
                    local _target; _target=$(_addon_pq_default_target)
                    if [ -z "$_target" ]; then
                        log_warn "SNI-домен не задан"
                    else
                        _addon_check_pq_domain "$_target"
                    fi
                fi
                press_any_key
                ;;
            2)
                if [ "$_pq_available" != "true" ]; then
                    log_error "Нет OpenSSL с поддержкой постквантового обмена ключами"
                    log_info "Нужен системный OpenSSL ${SELFMASK_MIN_SYSTEM_OPENSSL}+ либо сборка из состава MTProxyL (меню [3])"
                else
                    echo -en "  ${BOLD}Домен (или домен:порт):${NC} "
                    local _input
                    read_line _input
                    [ -n "$_input" ] && _addon_check_pq_domain "$_input"
                fi
                press_any_key
                ;;
            3)
                # Именно инструменты PQ, а не заглушка: этот пункт про openssl
                # для проверки домена, и системный nginx его не заменяет.
                selfmask_install_pq_tools
                press_any_key
                ;;
            4)
                _addon_censorcheck
                press_any_key
                ;;
            5)
                tui_selfmask_menu
                ;;
            6)
                tui_panel_menu
                ;;
            7)
                geoip_install
                press_any_key
                ;;
            0|"") return ;;
        esac
    done
}

# Проверка ограничений (censorship) сервера — портировано без изменений
# из MTproxy-reanimation (mtpr.sh:611-624, check_censor()). Работает по
# внешнему IP/порту сервера, не зависит от режима manager/reanimator.
_addon_censorcheck() {
    echo ""
    echo -e "  ${BOLD}Проверка ограничений на сервере${NC}"
    echo -e "  ${DIM}Источник: censorcheck.tlab.pw${NC}"
    echo ""
    if command -v wget &>/dev/null; then
        wget -qO- censorcheck.tlab.pw | bash
    elif command -v curl &>/dev/null; then
        curl -fsSL censorcheck.tlab.pw | bash
    else
        log_error "Не найден wget или curl"
        return 1
    fi
}

# Свой SNI-домен с портом прокси. Именно там отвечает наш FakeTLS: на 443
# обычно никто не слушает, и проверка упиралась в connection refused.
_addon_pq_default_target() {
    local _d; _d=$(_current_sni_domain 2>/dev/null)
    [ -n "$_d" ] || return 1
    local _p="${PROXY_PORT:-}"
    [[ "$_p" =~ ^[0-9]+$ ]] || _p=443
    echo "${_d}:${_p}"
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

    # Системный OpenSSL 3.5.0+ умеет X25519MLKEM768 сам — своя сборка нужна
    # только там, где он старее.
    local _openssl; _openssl=$(_pq_openssl_bin) || {
        log_error "Нет OpenSSL с поддержкой постквантового обмена ключами"
        log_info "Нужен системный OpenSSL ${SELFMASK_MIN_SYSTEM_OPENSSL}+ либо сборка из состава MTProxyL"
        log_info "Поставить нашу: mtproxyl selfmask pq-install (или из панели, раздел «Дополнения»)"
        return 1
    }
    echo -e "  ${DIM}Проверяем через: $(_pq_openssl_source)${NC}"

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
        _temp=$(_pq_negotiated_group "$_pq_out")
        _cert=$(_pq_parse_field "$_pq_out" "Peer certificate")
        _sig=$(_pq_parse_field "$_pq_out" "Signature type")
        _hash=$(_pq_parse_field "$_pq_out" "Hash used")

        echo -e "  ${GREEN}✅ Статус: поддерживается${NC}"
        [ -n "$_proto" ] && echo -e "    Протокол:    ${_proto}"
        [ -n "$_cipher" ] && echo -e "    Шифронабор:  ${_cipher}"
        [ -n "$_temp" ] && echo -e "    Группа:      ${_temp}"
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
    _temp=$(_pq_negotiated_group "$_std_out")
    _cert=$(_pq_parse_field "$_std_out" "Peer certificate")
    _sig=$(_pq_parse_field "$_std_out" "Signature type")
    _hash=$(_pq_parse_field "$_std_out" "Hash used")

    echo -e "  ${GREEN}Подключение: OK${NC}"
    [ -n "$_proto" ] && echo -e "    Протокол:    ${_proto}"
    [ -n "$_cipher" ] && echo -e "    Шифронабор:  ${_cipher}"
    [ -n "$_temp" ] && echo -e "    Группа:      ${_temp}"
    [ -n "$_cert" ] && echo -e "    Сертификат:  ${_cert}"
    [ -n "$_sig" ] && echo -e "    Подпись:     ${_sig}"
    [ -n "$_hash" ] && echo -e "    Хэш:        ${_hash}"

    echo ""
    echo -e "  ${BOLD}━━━ Вердикт ━━━${NC}"

    if [ -z "${_temp:-}" ]; then
        echo -e "  ${YELLOW}${BOLD}🟡 Маркер: неизвестно${NC}"
        echo -e "  ${DIM}Группа обмена ключами не определилась по выводу openssl${NC}"
    elif [[ "${_temp:-}" == X25519 ]]; then
        echo -e "  ${RED}${BOLD}🔴 МАРКЕР: ДА${NC}"
        echo -e "  ${RED}PQ не поддерживается + группа обмена ключами = X25519${NC}"
        echo -e "  ${YELLOW}⚠️ Риск блокировки на ТСПУ для iOS клиентов${NC}"
    else
        echo -e "  ${GREEN}${BOLD}🟢 Маркер: НЕТ${NC}"
        echo -e "  ${DIM}PQ не поддерживается, но группа обмена ключами не X25519${NC}"
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

# Какая группа обмена ключами согласована. До 3.5 openssl писал «Peer Temp
# Key», с 3.5 — «Negotiated TLS1.3 group»; ждали только первую.
_pq_negotiated_group() {
    local _text="$1" _val
    _val=$(_pq_parse_field "$_text" "Negotiated TLS1.3 group")
    [ -z "$_val" ] && _val=$(_pq_parse_field "$_text" "Negotiated group")
    if [ -z "$_val" ]; then
        # «X25519, 253 bits» — от старого формата нужно только имя группы.
        _val=$(_pq_parse_field "$_text" "Peer Temp Key")
        _val="${_val%%,*}"
    fi
    echo "$_val"
}
