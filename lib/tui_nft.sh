#!/bin/bash
# MTProxyL — подменю: NFT лимитер + iOS фиксы + Smart режим

tui_nft_menu() {
    while true; do
        clear_screen
        draw_header "NFT ЛИМИТЕР И iOS ФИКСЫ"
        echo ""
        load_nft_settings 2>/dev/null

        # Статус
        echo -e "  ${BOLD}Zapret2 fix:${NC} $(zapret2_status)"

        local _zapret_active="false"
        nft list table ip "${ZAPRET2_NFT_TABLE:-MTProtoL}" &>/dev/null 2>&1 && _zapret_active="true"

        if [ "$_zapret_active" != "true" ] || nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null 2>&1; then
            echo -e "  ${BOLD}NFT лимитер:${NC} $(nft_status_line)"
        fi

        if [ "${IOS_FIX_ENABLED:-false}" = "true" ]; then
            echo -e "  ${BOLD}iOS фикс v1:${NC} $(ios_fix_status_line)"
        fi
        if [ "${IOS2_FIX_ENABLED:-false}" = "true" ]; then
            echo -e "  ${BOLD}iOS фикс v2:${NC} $(ios2_fix_status_line)"
        fi
        echo -e "  ${BOLD}MEKO оптим.:${NC} $(meko_opt_status)"
        echo ""

        # Текущие параметры (скрываем limiter если только zapret2 активен)
        if [ "$_zapret_active" != "true" ] || nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null 2>&1; then
            echo -e "  ${DIM}Режим:   ${BOLD}${NFT_MODE}${NC}"
            if [ "$NFT_MODE" = "smart" ]; then
                if [ "${NFT_IOS_LIMIT_ENABLED:-true}" = "true" ]; then
                    echo -e "  ${DIM}iOS:     ${NFT_IOS_RATE} burst ${NFT_IOS_BURST}${NC}"
                else
                    echo -e "  ${DIM}iOS:     unlimited${NC}"
                fi

                if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" = "true" ]; then
                    echo -e "  ${DIM}Other:   ${NFT_OTHER_RATE} burst ${NFT_OTHER_BURST}${NC}"
                    local _action_display
                    case "${NFT_OTHER_ACTION:-icmp-host-unreachable}" in
                        icmp-host-unreachable) _action_display="${GREEN}icmp-host-unreachable${NC} ${DIM}(рекомендуется)${NC}" ;;
                        drop)                  _action_display="${YELLOW}drop${NC}" ;;
                        *)                     _action_display="${DIM}reject (tcp reset)${NC}" ;;
                    esac
                    echo -e "  ${DIM}Action:  ${NC}${_action_display}"
                else
                    echo -e "  ${DIM}Other:   unlimited${NC}"
                fi

                if [ "${NFT_IOS_DETECT:-fingerprint}" = "ttl" ]; then
                    echo -e "  ${DIM}Detect:  TTL+Length${NC}"
                else
                    echo -e "  ${DIM}Detect:  TCP fingerprint${NC}"
                fi
            else
                echo -e "  ${DIM}Rate:    ${NFT_RATE}${NC}"
                echo -e "  ${DIM}Burst:   ${NFT_BURST}${NC}"
            fi
            echo -e "  ${DIM}Timeout: ${NFT_METER_TIMEOUT}${NC}"
            if [ -n "${NFT_SERVER_IP:-}" ]; then
                echo -e "  ${DIM}IP:      ${NFT_SERVER_IP}${NC}"
            else
                echo -e "  ${DIM}IP:      ${DIM}все IP сервера${NC}"
            fi
            if [ "$NFT_EXTRA_COUNT" -gt 0 ]; then
                echo -e "  ${DIM}Доп. правила: ${NFT_EXTRA_COUNT}${NC}"
            fi
        fi
        echo ""

        echo -e "  ${BRIGHT_GREEN}[s]${NC}  ${BOLD}★ Smart By-MEKO${NC} ${DIM}(iOS/Android авторазделение + REJECT)${NC}"
        echo -e "  ${BRIGHT_CYAN}[z]${NC}  ${BOLD}Zapret2 MTProto fix${NC} ${DIM}(TCP disorder + badsum + window control)${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  Применить NFT правила"
        echo -e "  ${CYAN}[2]${NC}  Удалить NFT правила"
        echo -e "  ${CYAN}[3]${NC}  Пресеты (жёсткий / средний / мягкий / smart)"
        echo -e "  ${CYAN}[4]${NC}  Настройки NFT (rate / burst / timeout / IP)"
        local _counter_label="Счётчик правил"
        if nft list table ip "${ZAPRET2_NFT_TABLE:-MTProtoL}" &>/dev/null 2>&1; then
            if nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null 2>&1; then
                _counter_label="Счётчики правил: Zapret2 + SYN limiter"
            else
                _counter_label="Счётчик правил Zapret2"
            fi
        elif nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null 2>&1; then
            _counter_label="Счётчик правил SYN limiter"
        fi
        echo -e "  ${CYAN}[5]${NC}  ${_counter_label}"
        if [ "$_zapret_active" != "true" ] || nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null 2>&1; then
            echo -e "  ${CYAN}[6]${NC}  Установить службу автозапуска"
            echo -e "  ${CYAN}[7]${NC}  Удалить службу"
            echo -e "  ${CYAN}[8]${NC}  Дополнительные правила"
        fi
        echo ""
        echo -e "  ${CYAN}[m]${NC}  Оптимизация By-MEKO (BBR, очереди, keepalive)"
        echo -e "  ${DIM}[o]${NC}  Устаревшие настройки (iOS фиксы)"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""
        local choice; choice=$(read_choice "выбор" "0")

         case "$choice" in
            z|Z) tui_zapret2_menu ;;
            s|S)
                if [ "$_zapret_active" = "true" ]; then
                    log_warn "Zapret2 fix активен — отключите его перед включением Smart"
                    press_any_key
                else
                    enable_smart_mode; press_any_key
                fi ;;
            1)
                if [ "$_zapret_active" = "true" ]; then
                    log_warn "Zapret2 fix активен — SYN limiter не нужен"
                    press_any_key; continue
                fi
                if [ -z "${PROXY_PORT:-}" ]; then
                    log_error "Порт прокси не задан — запустите прокси"
                    press_any_key; continue
                fi
                apply_nft_rules || true
                press_any_key ;;
            2)
                remove_nft_rules || true; press_any_key ;;
            3)
                if [ "$_zapret_active" = "true" ]; then
                    log_warn "Zapret2 fix активен — пресеты SYN limiter не нужны"
                    press_any_key
                else
                    tui_nft_presets
                fi ;;
            4)
                if [ "$_zapret_active" = "true" ]; then
                    log_warn "Zapret2 fix активен — настройки SYN limiter скрыты. Используйте [z] → Настройки"
                    press_any_key
                else
                    tui_nft_settings
                fi ;;
            5) show_nft_drop_counter || true ;;
            6)
                if [ "$_zapret_active" = "true" ]; then
                    log_warn "Zapret2 fix активен — служба SYN limiter не нужна"
                    press_any_key; continue
                fi
                if [ -z "${PROXY_PORT:-}" ]; then
                    log_error "Порт прокси не задан — запустите прокси"
                    press_any_key; continue
                fi
                install_nft_service || true
                press_any_key ;;
            7)
                remove_nft_service || true; press_any_key ;;
            8)
                if [ "$_zapret_active" = "true" ]; then
                    log_warn "Zapret2 fix активен — доп. правила SYN limiter не нужны"
                    press_any_key
                else
                    tui_nft_extra_menu
                fi ;;
            m|M) tui_meko_opt_menu ;;
            o|O) tui_nft_legacy_menu ;;
            0|"") return ;;
        esac
    done
}

# ── Пресеты ───────────────────────────────────────────────────
tui_nft_presets() {
    clear_screen
    draw_header "ПРЕСЕТЫ NFT"
    echo ""
    echo -e "  ${BOLD}Выберите пресет ограничения:${NC}"; echo ""
    echo -e "  ${BRIGHT_GREEN}[s]${NC} ${BOLD}★ Smart By-MEKO${NC}"
    echo -e "      ${DIM}iOS/Android авторазделение по fingerprint + REJECT.${NC}"
    echo -e "      ${DIM}Подключение 3-8 сек. Один порт для всех клиентов.${NC}"
    echo ""
    echo -e "  ${RED}[1]${NC} Classic — 1/second burst 1"
    echo -e "      ${DIM}Каждый IP — не более 1 SYN/сек. DROP при превышении.${NC}"
    echo ""
    echo -e "  ${DIM}[2]${NC} Свой вариант (Classic)"
    echo -e "  ${DIM}[0]${NC} Назад"
    echo ""
    local choice; choice=$(read_choice "выбор" "0")

    case "$choice" in
        s|S) enable_smart_mode ;;
        1) apply_nft_preset hard ;;
        2)
            echo -en "  ${BOLD}Rate (напр. 1/second, 2/second) [${NFT_RATE}]:${NC} "
            local r; read -r r; [ -n "$r" ] && NFT_RATE="$r"
            echo -en "  ${BOLD}Burst [${NFT_BURST}]:${NC} "
            local b; read -r b; [[ "$b" =~ ^[0-9]+$ ]] && NFT_BURST="$b"
            NFT_MODE="classic"
            save_nft_settings
            log_success "Свой вариант: rate=$NFT_RATE burst=$NFT_BURST"
            ;;
        0|"") return ;;
    esac

    if [ "$choice" != "0" ] && [ -n "$choice" ] && [ "$choice" != "s" ] && [ "$choice" != "S" ]; then
        echo ""
        echo -en "  ${BOLD}Применить NFT правила сейчас? [Y/n]:${NC} "
        local yn; read -r yn
        if [[ ! "$yn" =~ ^[nN]$ ]]; then
            apply_nft_rules || true
            [ "${NFT_ENABLED:-false}" = "true" ] && install_nft_service || true
        fi
    fi
    press_any_key
}

# ── Настройки NFT ─────────────────────────────────────────────
tui_nft_settings() {
    if [ "$NFT_MODE" = "smart" ]; then
        tui_nft_smart_settings_menu
        return
    fi

    clear_screen
    draw_header "НАСТРОЙКИ NFT"
    echo ""

    echo -e "  ${BOLD}Режим: Classic${NC}"
    echo ""
    echo -e "  ${BOLD}Текущие параметры:${NC}"
    echo -e "    Rate:    ${NFT_RATE}"
    echo -e "    Burst:   ${NFT_BURST}"
    echo -e "    Timeout: ${NFT_METER_TIMEOUT}"
    echo -e "    IP:      ${NFT_SERVER_IP:-${DIM}все IP сервера${NC}}"
    echo ""
    echo -e "  ${DIM}[1]${NC} Изменить Rate    [${NFT_RATE}]"
    echo -e "  ${DIM}[2]${NC} Изменить Burst   [${NFT_BURST}]"
    echo -e "  ${DIM}[3]${NC} Изменить Timeout [${NFT_METER_TIMEOUT}]"
    echo -e "  ${DIM}[4]${NC} Изменить/убрать IP привязку"
    echo -e "  ${DIM}[5]${NC} Переключить на Smart By-MEKO"
    echo -e "  ${DIM}[0]${NC} Назад"
    echo ""

    local choice; choice=$(read_choice "выбор" "0")
    case "$choice" in
        1)
            echo -en "  ${BOLD}Новый Rate (напр. 1/second, 2/second) [${NFT_RATE}]:${NC} "
            local r; read -r r
            if [ -n "$r" ]; then
                NFT_RATE="$r"
                save_nft_settings
                log_success "Rate: ${NFT_RATE}"
                prompt_apply_nft_rules
            fi
            ;;
        2)
            echo -en "  ${BOLD}Новый Burst [${NFT_BURST}]:${NC} "
            local b; read -r b
            if [[ "$b" =~ ^[0-9]+$ ]]; then
                NFT_BURST="$b"
                save_nft_settings
                log_success "Burst: ${NFT_BURST}"
                prompt_apply_nft_rules
            elif [ -n "$b" ]; then
                log_error "Burst должен быть числом"
            fi
            ;;
        3)
            echo -en "  ${BOLD}Новый Timeout (напр. 30s, 60s, 120s) [${NFT_METER_TIMEOUT}]:${NC} "
            local t; read -r t
            if [ -n "$t" ]; then
                NFT_METER_TIMEOUT="$t"
                save_nft_settings
                log_success "Timeout: ${NFT_METER_TIMEOUT}"
                prompt_apply_nft_rules
            fi
            ;;
        4)
            tui_nft_ip_settings
            ;;
        5)
            enable_smart_mode
            ;;
        0|"")
            return
            ;;
    esac

    press_any_key
}

# ── Настройки Smart By-MEKO ───────────────────────────────────
tui_nft_smart_settings_menu() {
    while true; do
        clear_screen
        draw_header "НАСТРОЙКИ SMART BY-MEKO"
        echo ""

        local _detect_display
        if [ "${NFT_IOS_DETECT:-fingerprint}" = "ttl" ]; then
            _detect_display="${YELLOW}TTL+Length${NC} ${DIM}(устаревший режим)${NC}"
        else
            _detect_display="${GREEN}TCP fingerprint${NC} ${DIM}(рекомендуется)${NC}"
        fi

        echo -e "  ${BOLD}Текущие параметры:${NC}"
        if [ "${NFT_IOS_LIMIT_ENABLED:-true}" = "true" ]; then
            echo -e "    iOS лимит:    ${GREEN}включён${NC} — ${NFT_IOS_RATE} burst ${NFT_IOS_BURST}"
        else
            echo -e "    iOS лимит:    ${YELLOW}отключён${NC} ${DIM}(безусловный ACCEPT)${NC}"
        fi

        if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" = "true" ]; then
            echo -e "    Other лимит:  ${GREEN}включён${NC} — ${NFT_OTHER_RATE} burst ${NFT_OTHER_BURST}"
            echo -e "    Other Action: ${NFT_OTHER_ACTION:-icmp-host-unreachable}"
        else
            echo -e "    Other лимит:  ${YELLOW}отключён${NC} ${DIM}(безусловный ACCEPT)${NC}"
        fi

        echo -e "    Timeout:      ${NFT_METER_TIMEOUT}"
        echo -e "    iOS detect:   ${_detect_display}"
        echo -e "    IP:           ${NFT_SERVER_IP:-${DIM}все IP сервера${NC}}"
        echo ""

        echo -e "  ${BOLD}iOS:${NC}"
        echo -e "  ${DIM}[1]${NC} iOS Rate    [${NFT_IOS_RATE}]"
        echo -e "  ${DIM}[2]${NC} iOS Burst   [${NFT_IOS_BURST}]"
        echo -e "  ${DIM}[3]${NC} Вкл/выкл лимит iOS"
        echo ""
        echo -e "  ${BOLD}Other:${NC}"
        echo -e "  ${DIM}[4]${NC} Other Rate  [${NFT_OTHER_RATE}]"
        echo -e "  ${DIM}[5]${NC} Other Burst [${NFT_OTHER_BURST}]"
        echo -e "  ${DIM}[6]${NC} Other Action"
        echo -e "  ${DIM}[7]${NC} Вкл/выкл лимит Other"
        echo ""
        echo -e "  ${DIM}[8]${NC} Timeout     [${NFT_METER_TIMEOUT}]"
        echo -e "  ${DIM}[9]${NC} Метод идентификации iOS"
        echo -e "  ${DIM}[i]${NC} Изменить IP привязку(или убрать)"
        echo -e "  ${DIM}[c]${NC} Переключить на Classic режим"
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""

        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                if [ "${NFT_IOS_LIMIT_ENABLED:-true}" != "true" ]; then
                    log_warn "Лимит iOS отключён — сначала включите его"
                else
                    echo -en "  ${BOLD}iOS Rate [${NFT_IOS_RATE}]:${NC} "
                    local v; read -r v
                    [ -n "$v" ] && { NFT_IOS_RATE="$v"; save_nft_settings; log_success "iOS Rate: ${v}"; prompt_apply_nft_rules; }
                fi
                press_any_key ;;
            2)
                if [ "${NFT_IOS_LIMIT_ENABLED:-true}" != "true" ]; then
                    log_warn "Лимит iOS отключён — сначала включите его"
                else
                    echo -en "  ${BOLD}iOS Burst [${NFT_IOS_BURST}]:${NC} "
                    local v; read -r v
                    [[ "$v" =~ ^[0-9]+$ ]] && { NFT_IOS_BURST="$v"; save_nft_settings; log_success "iOS Burst: ${v}"; prompt_apply_nft_rules; }
                fi
                press_any_key ;;
            3)
                if [ "${NFT_IOS_LIMIT_ENABLED:-true}" = "true" ]; then
                    echo -en "  ${BOLD}Отключить лимит iOS? [y/N]:${NC} "
                    local yn; read -r yn
                    if [[ "$yn" =~ ^[yY]$ ]]; then
                        NFT_IOS_LIMIT_ENABLED="false"
                        save_nft_settings
                        log_success "Лимит iOS отключён"
                        prompt_apply_nft_rules
                    fi
                else
                    NFT_IOS_LIMIT_ENABLED="true"
                    save_nft_settings
                    log_success "Лимит iOS включён"
                    prompt_apply_nft_rules
                fi
                press_any_key ;;
            4)
                if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" != "true" ]; then
                    log_warn "Лимит Other отключён — сначала включите его"
                else
                    echo -en "  ${BOLD}Other Rate [${NFT_OTHER_RATE}]:${NC} "
                    local v; read -r v
                    [ -n "$v" ] && { NFT_OTHER_RATE="$v"; save_nft_settings; log_success "Other Rate: ${v}"; prompt_apply_nft_rules; }
                fi
                press_any_key ;;
            5)
                if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" != "true" ]; then
                    log_warn "Лимит Other отключён — сначала включите его"
                else
                    echo -en "  ${BOLD}Other Burst [${NFT_OTHER_BURST}]:${NC} "
                    local v; read -r v
                    [[ "$v" =~ ^[0-9]+$ ]] && { NFT_OTHER_BURST="$v"; save_nft_settings; log_success "Other Burst: ${v}"; prompt_apply_nft_rules; }
                fi
                press_any_key ;;
            6) tui_nft_other_action_menu ;;
            7)
                if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" = "true" ]; then
                    echo -en "  ${BOLD}Отключить лимит Other? [y/N]:${NC} "
                    local yn; read -r yn
                    if [[ "$yn" =~ ^[yY]$ ]]; then
                        NFT_OTHER_LIMIT_ENABLED="false"
                        save_nft_settings
                        log_success "Лимит Other отключён"
                        prompt_apply_nft_rules
                    fi
                else
                    NFT_OTHER_LIMIT_ENABLED="true"
                    save_nft_settings
                    log_success "Лимит Other включён"
                    prompt_apply_nft_rules
                fi
                press_any_key ;;
            8)
                echo -en "  ${BOLD}Timeout [${NFT_METER_TIMEOUT}]:${NC} "
                local v; read -r v
                [ -n "$v" ] && { NFT_METER_TIMEOUT="$v"; save_nft_settings; log_success "Timeout: ${v}"; prompt_apply_nft_rules; }
                press_any_key ;;
            9)
                echo ""
                echo -e "  ${BOLD}Метод идентификации iOS:${NC}"
                echo -e "  ${GREEN}[1]${NC} TCP fingerprint ${DIM}(рекомендуется)${NC}"
                echo -e "  ${YELLOW}[2]${NC} TTL + Length ${DIM}(старое поведение MTProxyL)${NC}"
                echo ""
                local dm; dm=$(read_choice "выбор" "1")
                case "$dm" in
                    2) NFT_IOS_DETECT="ttl"; save_nft_settings; log_success "iOS detect: TTL+Length"; prompt_apply_nft_rules ;;
                    *) NFT_IOS_DETECT="fingerprint"; save_nft_settings; log_success "iOS detect: TCP fingerprint"; prompt_apply_nft_rules ;;
                esac
                press_any_key ;;
            i|I) tui_nft_ip_settings ;;
            c|C)
                NFT_MODE="classic"
                save_nft_settings
                log_success "Переключено на Classic"
                prompt_apply_nft_rules
                press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── Настройки IP привязки ─────────────────────────────────────
tui_nft_ip_settings() {
    clear_screen
    draw_header "IP ПРИВЯЗКА NFT"
    echo ""
    echo -e "  ${BOLD}Текущий IP:${NC} ${NFT_SERVER_IP:-${DIM}отключена (все IP сервера)${NC}}"
    echo ""
    echo -e "  ${DIM}Если указан IP — правило будет работать только для трафика${NC}"
    echo -e "  ${DIM}на этот адрес и порт. Если не указывать — для всех IP сервера.${NC}"
    echo ""
    echo -e "  ${DIM}Enter  — оставить текущее значение${NC}"
    echo -e "  ${DIM}none   — убрать привязку к IP${NC}"
    echo -e "  ${DIM}auto   — автоопределить публичный IPv4${NC}"
    echo -e "  ${DIM}или введите свой IPv4 вручную${NC}"
    echo ""

    while true; do
        echo -en "  ${BOLD}IPv4 [${NFT_SERVER_IP:-none}]:${NC} "
        local _val; read -r _val

        [ -z "$_val" ] && break

        case "$_val" in
            none|NONE|clear|CLEAR|-)
                NFT_SERVER_IP=""
                save_nft_settings
                log_success "IP привязка отключена"
                prompt_apply_nft_rules
                break ;;
            auto|AUTO)
                log_info "Определение публичного IP..."
                local _detected_ip; _detected_ip=$(get_public_ip)
                if [ -n "$_detected_ip" ] && validate_ip_literal "$_detected_ip"; then
                    NFT_SERVER_IP="$_detected_ip"
                    save_nft_settings
                    log_success "IP определён: ${NFT_SERVER_IP}"
                    prompt_apply_nft_rules
                    break
                else
                    log_error "Не удалось определить корректный IPv4"
                fi ;;
            *)
                if validate_ip_literal "$_val"; then
                    NFT_SERVER_IP="$_val"
                    save_nft_settings
                    log_success "IP установлен: ${NFT_SERVER_IP}"
                    prompt_apply_nft_rules
                    break
                else
                    log_error "Некорректный IPv4. Введите IPv4, Enter, none, clear, - или auto"
                fi ;;
        esac
    done
    press_any_key
}

# ── Дополнительные правила ────────────────────────────────────
tui_nft_extra_menu() {
    while true; do
        clear_screen
        draw_header "ДОПОЛНИТЕЛЬНЫЕ ПРАВИЛА"
        echo ""

        if [ "$NFT_EXTRA_COUNT" -eq 0 ]; then
            echo -e "  ${DIM}Нет дополнительных правил${NC}"
        else
            printf "  ${BOLD}%-4s %-8s %-18s %-12s %-8s${NC}\n" "#" "ПОРТ" "IP" "RATE" "BURST"
            echo -e "  ${DIM}$(_repeat '─' 56)${NC}"
            local _i
            for _i in $(seq 1 "$NFT_EXTRA_COUNT"); do
                printf "  %-4s %-8s %-18s %-12s %-8s\n" \
                    "$_i" \
                    "${NFT_EXTRA_PORT[$_i]:-?}" \
                    "${NFT_EXTRA_IP[$_i]:-все}" \
                    "${NFT_EXTRA_RATE[$_i]:-?}" \
                    "${NFT_EXTRA_BURST[$_i]:-?}"
            done
        fi

        echo ""
        echo -e "  ${DIM}[a]${NC} Добавить правило"
        echo -e "  ${DIM}[d]${NC} Удалить правило"
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""
        local choice; choice=$(read_choice "выбор" "0")

        case "$choice" in
            a|A)
                echo ""
                if [ "$NFT_MODE" = "smart" ]; then
                    echo -e "  ${YELLOW}Smart режим активен.${NC}"
                    echo -e "  ${DIM}Доп. правило унаследует Other Action: ${NFT_OTHER_ACTION:-icmp-host-unreachable}${NC}"
                    echo ""
                fi
                local _p=""
                echo -en "  ${BOLD}Порт:${NC} "
                read -r _p
                if ! [[ "$_p" =~ ^[0-9]+$ ]] || [ "$_p" -lt 1 ] || [ "$_p" -gt 65535 ]; then
                    log_error "Некорректный порт"
                    press_any_key; continue
                fi
                local _eip=""
                echo -en "  ${BOLD}IP (пусто = все):${NC} "
                read -r _eip
                if [ -n "$_eip" ] && ! validate_ip_literal "$_eip"; then
                    log_error "Некорректный IPv4"
                    press_any_key; continue
                fi
                local _r=""
                echo -en "  ${BOLD}Rate [1/second]:${NC} "
                read -r _r
                [ -z "$_r" ] && _r="1/second"
                local _b=""
                echo -en "  ${BOLD}Burst [1]:${NC} "
                read -r _b
                [ -z "$_b" ] && _b="1"
                nft_extra_add "$_p" "$_eip" "$_r" "$_b"
                local _add_rc=$?
                if [ "$_add_rc" -eq 0 ]; then
                    echo ""
                    echo -en "  ${BOLD}Применить правила сейчас? [Y/n]:${NC} "
                    local _yn=""
                    read -r _yn
                    if [[ ! "$_yn" =~ ^[nN]$ ]]; then
                        apply_nft_rules || true
                        [ "${NFT_ENABLED:-false}" = "true" ] && install_nft_service || true
                    fi
                fi
                press_any_key ;;
            d|D)
                [ "$NFT_EXTRA_COUNT" -eq 0 ] && { log_info "Нет правил для удаления"; press_any_key; continue; }
                echo -en "  ${BOLD}Номер правила для удаления:${NC} "
                local _idx; read -r _idx
                nft_extra_remove "$_idx" || true
                echo ""
                echo -en "  ${BOLD}Применить правила заново? [Y/n]:${NC} "
                local _yn; read -r _yn
                if [[ ! "$_yn" =~ ^[nN]$ ]]; then
                    apply_nft_rules || true
                    [ "${NFT_ENABLED:-false}" = "true" ] && install_nft_service || true
                fi
                press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── Other Action меню (Smart режим) ──────────────────────────
tui_nft_other_action_menu() {
    clear_screen
    draw_header "OTHER ACTION — SMART РЕЖИМ"
    echo ""
    echo -e "  ${BOLD}Действие для non-iOS устройств (Android / Desktop / macOS):${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} ${BOLD}icmp-host-unreachable${NC} ${DIM}(рекомендуется)${NC}"
    echo -e "      ${DIM}Сервер притворяется недоступным узлом сети.${NC}"
    echo -e "      ${DIM}Telegram мгновенно понимает: «этот путь закрыт» —${NC}"
    echo -e "      ${DIM}и сразу переключается на основное соединение.${NC}"
    echo -e "      ${DIM}Медиа начинает отправляться без задержек.${NC}"
    echo ""
    echo -e "  ${CYAN}[2]${NC} reject (tcp reset) ${DIM}(оригинал By-MEKO)${NC}"
    echo -e "      ${DIM}Жёсткий TCP сброс. Быстрый reconnect,${NC}"
    echo -e "      ${DIM}но небольшая задержка при старте отправки медиа.${NC}"
    echo ""
    echo -e "  ${YELLOW}[3]${NC} drop ${DIM}(не рекомендуется)${NC}"
    echo -e "      ${DIM}Тихое уничтожение пакета. Telegram ждёт таймаута —${NC}"
    echo -e "      ${DIM}отправка медиа может полностью зависать.${NC}"
    echo ""
    echo -e "  ${BOLD}Текущее:${NC} ${NFT_OTHER_ACTION:-icmp-host-unreachable}"
    echo ""
    echo -e "  ${DIM}[0]${NC}  Назад без изменений"
    echo ""
    local choice; choice=$(read_choice "выбор" "0")
    case "$choice" in
        1) NFT_OTHER_ACTION="icmp-host-unreachable" ;;
        2) NFT_OTHER_ACTION="reject" ;;
        3) NFT_OTHER_ACTION="drop" ;;
        0|"") return ;;
        *) log_error "Некорректный выбор"; press_any_key; return ;;
    esac
    save_nft_settings
    log_success "Other Action: ${NFT_OTHER_ACTION}"
    prompt_apply_nft_rules
    press_any_key
}

# ── Оптимизация By-MEKO меню ──────────────────────────────────
tui_meko_opt_menu() {
    while true; do
        clear_screen
        draw_header "ОПТИМИЗАЦИЯ СИСТЕМЫ BY-MEKO"
        echo ""
        echo -e "  Статус: $(meko_opt_status)"
        echo ""

        if [ -n "$MEKO_ORIG_KEEPALIVE_TIME" ]; then
            echo -e "  ${DIM}Значения до применения:${NC}"
            echo -e "    keepalive: ${MEKO_ORIG_KEEPALIVE_TIME}s / ${MEKO_ORIG_KEEPALIVE_INTVL}s × ${MEKO_ORIG_KEEPALIVE_PROBES}"
            echo -e "    congestion: ${MEKO_ORIG_TCP_CONGESTION:-cubic}  qdisc: ${MEKO_ORIG_DEFAULT_QDISC:-pfifo_fast}"
            echo ""
        fi

        echo -e "  ${DIM}[1]${NC} Применить / обновить"
        echo -e "  ${DIM}[2]${NC} Откатить"
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) meko_opt_apply; press_any_key ;;
            2) meko_opt_remove; press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── iOS Fix v1 меню ───────────────────────────────────────────
tui_ios1_menu() {
    while true; do
        clear_screen
        draw_header "iOS FIX v1 — TCP KEEPALIVE"
        echo ""
        echo -e "  Статус: $(ios_fix_status_line)"; echo ""

        local _t _i _p
        _t=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
        _i=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
        _p=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
        local _detect=$(( ${_t:-7200} + ${_i:-75} * ${_p:-9} ))

        echo -e "  ${BOLD}Значения ядра:${NC}"
        echo -e "    tcp_keepalive_time   = ${_t:-?}  ${DIM}(дефолт: 7200, фикс: ${IOS_KA_TIME})${NC}"
        echo -e "    tcp_keepalive_intvl  = ${_i:-?}  ${DIM}(дефолт: 75,   фикс: ${IOS_KA_INTVL})${NC}"
        echo -e "    tcp_keepalive_probes = ${_p:-?}  ${DIM}(дефолт: 9,    фикс: ${IOS_KA_PROBES})${NC}"
        echo -e "    ${DIM}Время обнаружения мёртвого коннекта: ~${_detect} сек${NC}"

        if [ -n "$IOS_ORIG_TIME" ]; then
            echo ""
            echo -e "  ${DIM}Значения до установки фикса: time=${IOS_ORIG_TIME} intvl=${IOS_ORIG_INTVL} probes=${IOS_ORIG_PROBES}${NC}"
        fi

        echo ""
        echo -e "  ${DIM}[1]${NC} Применить / обновить фикс"
        echo -e "  ${DIM}[2]${NC} Откатить фикс"
        echo -e "  ${DIM}[3]${NC} Изменить keepalive_time   [${IOS_KA_TIME}]"
        echo -e "  ${DIM}[4]${NC} Изменить keepalive_intvl  [${IOS_KA_INTVL}]"
        echo -e "  ${DIM}[5]${NC} Изменить keepalive_probes [${IOS_KA_PROBES}]"
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""
        local choice; choice=$(read_choice "выбор" "0")

        case "$choice" in
            1) ios_fix_apply; press_any_key ;;
            2) ios_fix_remove; press_any_key ;;
            3)
                echo -en "  ${BOLD}tcp_keepalive_time [${IOS_KA_TIME}]:${NC} "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]]; then
                    IOS_KA_TIME="$_v"; save_nft_settings; log_success "keepalive_time = $_v"
                elif [ -n "$_v" ]; then log_error "Должно быть числом"; fi
                press_any_key ;;
            4)
                echo -en "  ${BOLD}tcp_keepalive_intvl [${IOS_KA_INTVL}]:${NC} "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]]; then
                    IOS_KA_INTVL="$_v"; save_nft_settings; log_success "keepalive_intvl = $_v"
                elif [ -n "$_v" ]; then log_error "Должно быть числом"; fi
                press_any_key ;;
            5)
                echo -en "  ${BOLD}tcp_keepalive_probes [${IOS_KA_PROBES}]:${NC} "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]]; then
                    IOS_KA_PROBES="$_v"; save_nft_settings; log_success "keepalive_probes = $_v"
                elif [ -n "$_v" ]; then log_error "Должно быть числом"; fi
                press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── iOS Fix v2 меню ───────────────────────────────────────────
tui_ios2_menu() {
    while true; do
        clear_screen
        draw_header "iOS FIX v2 — MSS + REDIRECT"
        echo ""

        # Предупреждение если Smart режим
        if [ "$NFT_MODE" = "smart" ]; then
            echo -e "  ${YELLOW}⚠ Smart By-MEKO активен — iOS Fix v2 не нужен.${NC}"
            echo -e "  ${DIM}  Smart автоматически разделяет iOS/Android на одном порту.${NC}"
            echo ""
        fi

        echo -e "  Статус: $(ios2_fix_status_line)"; echo ""

        local _target="${IOS2_TARGET_PORT:-${PROXY_PORT:-443}}"
        echo -e "  ${BOLD}Текущие параметры:${NC}"
        echo -e "    Внешний порт iOS: ${IOS2_EXTERNAL_PORT}"
        echo -e "    Основной порт:    ${_target}"
        echo -e "    MSS:              ${IOS2_MSS}"
        echo ""
        echo -e "  ${DIM}[1]${NC} Применить / обновить"
        echo -e "  ${DIM}[2]${NC} Откатить"
        echo -e "  ${DIM}[3]${NC} Изменить внешний порт iOS [${IOS2_EXTERNAL_PORT}]"
        echo -e "  ${DIM}[4]${NC} Изменить целевой порт     [${_target}]"
        echo -e "  ${DIM}[5]${NC} Изменить MSS              [${IOS2_MSS}]"
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""
        local choice; choice=$(read_choice "выбор" "0")

        case "$choice" in
            1) ios2_fix_apply; press_any_key ;;
            2) ios2_fix_remove; press_any_key ;;
            3)
                echo -en "  ${BOLD}Новый внешний порт iOS [${IOS2_EXTERNAL_PORT}]:${NC} "
                local _p; read -r _p
                if [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; then
                    IOS2_EXTERNAL_PORT="$_p"; save_nft_settings; log_success "Внешний порт: $_p"
                    prompt_apply_nft_rules
                elif [ -n "$_p" ]; then log_error "Некорректный порт (1..65535)"; fi
                press_any_key ;;
            4)
                echo -en "  ${BOLD}Новый целевой порт [${_target}]:${NC} "
                local _p; read -r _p
                if [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; then
                    IOS2_TARGET_PORT="$_p"; save_nft_settings; log_success "Целевой порт: $_p"
                    prompt_apply_nft_rules
                elif [ -n "$_p" ]; then log_error "Некорректный порт (1..65535)"; fi
                press_any_key ;;
            5)
                echo -en "  ${BOLD}Новый MSS [${IOS2_MSS}] (88..4096):${NC} "
                local _m; read -r _m
                if [[ "$_m" =~ ^[0-9]+$ ]] && [ "$_m" -ge 88 ] && [ "$_m" -le 4096 ]; then
                    IOS2_MSS="$_m"; save_nft_settings; log_success "MSS: $_m"
                    prompt_apply_nft_rules
                elif [ -n "$_m" ]; then log_error "MSS должен быть в диапазоне 88..4096"; fi
                press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── Устаревшие настройки (iOS фиксы) ─────────────────────────
tui_nft_legacy_menu() {
    while true; do
        clear_screen
        draw_header "УСТАРЕВШИЕ НАСТРОЙКИ"
        echo ""
        echo -e "  ${DIM}Эти настройки сохранены для обратной совместимости.${NC}"
        echo -e "  ${DIM}При использовании Smart By-MEKO или Zapret2 fix они не нужны.${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  iOS Fix v1 — TCP keepalive"
        echo -e "  ${CYAN}[2]${NC}  iOS Fix v2 — MSS + redirect"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) tui_ios1_menu ;;
            2) tui_ios2_menu ;;
            0|"") return ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════
#  Zapret2 TUI меню
# ══════════════════════════════════════════════════════════════

tui_zapret2_menu() {
    while true; do
        clear_screen
        draw_header "ZAPRET2 MTPROTO FIX"
        echo ""
        echo -e "  Статус: $(zapret2_status)"
        echo ""

        if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
            echo -e "  ${BOLD}Параметры:${NC}"
            echo -e "    out-range:   ${ZAPRET2_OUT_RANGE}"
            echo -e "    in-range:    ${ZAPRET2_IN_RANGE}"
            echo -e "    split len:   ${ZAPRET2_SPLIT_LEN}"
            echo -e "    win SYN+ACK: ${ZAPRET2_WIN_SYNACK}"
            echo -e "    win ACK:     ${ZAPRET2_WIN_ACK}"
            echo -e "    NFQUEUE:     ${ZAPRET2_QNUM}"
            echo -e "    fwmark:      ${ZAPRET2_FWMARK}"
            echo -e "    Порт:        ${PROXY_PORT:-не задан}"
            if [ "${ZAPRET2_DEBUG:-false}" = "true" ]; then
                echo -e "    Debug:       ${YELLOW}включён${NC} → ${ZAPRET2_DEBUG_LOG}"
            else
                echo -e "    Debug:       ${DIM}выключен${NC}"
            fi
            echo ""

            local _svc_status="${DIM}не установлена${NC}"
            if systemctl is-enabled "$ZAPRET2_SERVICE" &>/dev/null 2>&1; then
                if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null 2>&1; then
                    _svc_status="${GREEN}работает${NC}"
                else
                    _svc_status="${YELLOW}остановлена${NC}"
                fi
            fi
            echo -e "  ${BOLD}Служба:${NC} ${_svc_status}"
            if nft list table ip "${ZAPRET2_NFT_TABLE}" &>/dev/null 2>&1; then
                echo -e "  ${BOLD}NFT:${NC}    ${GREEN}ip ${ZAPRET2_NFT_TABLE} активна${NC}"
            else
                echo -e "  ${BOLD}NFT:${NC}    ${RED}таблица не найдена${NC}"
            fi
            echo ""
        fi

        echo -e "  ${GREEN}[1]${NC}  Установить / переустановить"
        if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
            echo -e "  ${CYAN}[2]${NC}  Перезапустить"
            if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null 2>&1; then
                echo -e "  ${CYAN}[3]${NC}  Остановить"
            else
                echo -e "  ${GREEN}[3]${NC}  Запустить"
            fi
            echo -e "  ${CYAN}[4]${NC}  Настройки параметров"
            echo -e "  ${CYAN}[5]${NC}  Показать конфиг + Lua + NFT"
            echo -e "  ${CYAN}[6]${NC}  Логи службы"
            echo -e "  ${CYAN}[7]${NC}  Диагностика (wscale + NFT + queue)"
            echo -e "  ${CYAN}[r]${NC}  Сбросить настройки к дефолту"
            if [ "${ZAPRET2_DEBUG:-false}" = "true" ]; then
                echo -e "  ${CYAN}[d]${NC}  Debug лог (tail -100)"
            fi
            echo -e "  ${RED}[8]${NC}  Удалить"
        fi
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) zapret2_install; press_any_key ;;
            2)
                if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
                    zapret2_apply_nft
                    systemctl restart "$ZAPRET2_SERVICE" 2>/dev/null
                    sleep 1
                    systemctl status "$ZAPRET2_SERVICE" --no-pager -l 2>/dev/null || true
                fi
                press_any_key ;;
            3)
                if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
                    if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null 2>&1; then
                        zapret2_stop
                    else
                        zapret2_start_existing
                    fi
                fi
                press_any_key ;;
            4) [ "${ZAPRET2_APPLIED:-false}" = "true" ] && tui_zapret2_settings ;;
            5)
                if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
                    echo ""
                    echo -e "  ${BOLD}=== ${ZAPRET2_CONF} ===${NC}"
                    cat "$ZAPRET2_CONF" 2>/dev/null || echo "  (не найден)"
                    echo ""
                    echo -e "  ${BOLD}=== ${ZAPRET2_LUA} ===${NC}"
                    cat "$ZAPRET2_LUA" 2>/dev/null || echo "  (не найден)"
                    echo ""
                    echo -e "  ${BOLD}=== NFT table ip ${ZAPRET2_NFT_TABLE} ===${NC}"
                    nft list table ip "${ZAPRET2_NFT_TABLE}" 2>/dev/null || echo "  (таблица не найдена)"
                fi
                press_any_key ;;
            6)
                if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
                    echo ""
                    journalctl -u "$ZAPRET2_SERVICE" -n 30 --no-pager 2>/dev/null || log_warn "Логов нет"
                fi
                press_any_key ;;
            7)
                if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
                    echo ""
                    echo -e "  ${BOLD}=== systemd ===${NC}"
                    systemctl status "$ZAPRET2_SERVICE" --no-pager -l 2>/dev/null || true
                    echo ""
                    echo -e "  ${BOLD}=== journal ===${NC}"
                    journalctl -u "$ZAPRET2_SERVICE" -n 20 --no-pager 2>/dev/null || true
                    echo ""
                    echo -e "  ${BOLD}=== NFQUEUE ===${NC}"
                    modprobe nfnetlink_queue 2>/dev/null || true
                    cat /proc/net/netfilter/nfnetlink_queue 2>/dev/null || echo "  unavailable"
                    echo ""
                    echo -e "  ${BOLD}=== NFT table ===${NC}"
                    nft list table ip "${ZAPRET2_NFT_TABLE}" 2>/dev/null || true
                    echo ""
                    echo -e "  ${BOLD}=== old limiter ===${NC}"
                    nft list table inet "${NFT_TABLE:-mtproxyl_limit}" 2>/dev/null || echo "  отсутствует"
                    zapret2_check_wscale "true"
                fi
                press_any_key ;;
            r|R)
                if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
                    echo ""
                    echo -e "  ${BOLD}Сброс к дефолту:${NC}"
                    echo -e "    out-range: a  in-range: a"
                    echo -e "    split len: 400  win SYN+ACK: 1400  win ACK: 10"
                    echo -e "    NFQUEUE: 200  fwmark: 0x40000000"
                    echo ""
                    echo -en "  ${BOLD}Сбросить и перезапустить? [y/N]:${NC} "
                    local _yn; read -r _yn
                    if [[ "$_yn" =~ ^[yY]$ ]]; then
                        ZAPRET2_OUT_RANGE="a"
                        ZAPRET2_IN_RANGE="a"
                        ZAPRET2_SPLIT_LEN="400"
                        ZAPRET2_WIN_SYNACK="1400"
                        ZAPRET2_WIN_ACK="10"
                        ZAPRET2_QNUM="200"
                        ZAPRET2_FWMARK="0x40000000"
                        save_nft_settings
                        zapret2_update_config
                        log_success "Настройки сброшены к дефолту"
                    else
                        log_info "Отменено"
                    fi
                fi
                press_any_key ;;
            d|D)
                if [ "${ZAPRET2_APPLIED:-false}" = "true" ] && [ "${ZAPRET2_DEBUG:-false}" = "true" ]; then
                    echo ""
                    if [ -f "${ZAPRET2_DEBUG_LOG}" ]; then
                        echo -e "  ${BOLD}=== ${ZAPRET2_DEBUG_LOG} (tail -100) ===${NC}"
                        echo ""
                        tail -100 "${ZAPRET2_DEBUG_LOG}"
                    else
                        log_info "Debug лог пуст или не существует"
                    fi
                else
                    log_info "Debug лог не включён. Включите через [4] → [9]"
                fi
                press_any_key ;;
            8) [ "${ZAPRET2_APPLIED:-false}" = "true" ] && zapret2_remove; press_any_key ;;
            0|"") return ;;
        esac
    done
}

tui_zapret2_settings() {
    while true; do
        clear_screen
        draw_header "НАСТРОЙКИ ZAPRET2"
        echo ""
        echo -e "  ${DIM}Изменение параметров перезаписывает конфиг, Lua и перезапускает службу.${NC}"
        echo ""
        echo -e "  ${DIM}[1]${NC} out-range   [${ZAPRET2_OUT_RANGE}]  ${DIM}— исходящие пакеты (a=always)${NC}"
        echo -e "  ${DIM}[2]${NC} split len   [${ZAPRET2_SPLIT_LEN}]  ${DIM}— размер частей ClientHello (50..400)${NC}"
        echo -e "  ${DIM}[3]${NC} win SYN+ACK [${ZAPRET2_WIN_SYNACK}]  ${DIM}— окно в SYN+ACK${NC}"
        echo -e "  ${DIM}[4]${NC} win ACK     [${ZAPRET2_WIN_ACK}]  ${DIM}— окно в пустых ACK${NC}"
        echo -e "  ${DIM}[5]${NC} in-range    [${ZAPRET2_IN_RANGE}]  ${DIM}— входящие пакеты${NC}"
        echo -e "  ${DIM}[6]${NC} NFQUEUE     [${ZAPRET2_QNUM}]  ${DIM}— номер очереди${NC}"
        echo -e "  ${DIM}[7]${NC} fwmark      [${ZAPRET2_FWMARK}]"
        echo -e "  ${DIM}[8]${NC} Проверка wscale / win ACK"
        echo ""
        if [ "${ZAPRET2_DEBUG:-false}" = "true" ]; then
            echo -e "  ${DIM}[9]${NC} Debug лог ${YELLOW}[включён]${NC}"
        else
            echo -e "  ${DIM}[9]${NC} Debug лог ${DIM}[выключен]${NC}"
        fi
        echo ""
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                echo -en "  out-range [${ZAPRET2_OUT_RANGE}]: "
                local _v; read -r _v
                if [ -n "$_v" ]; then
                    ZAPRET2_OUT_RANGE="$_v"; save_nft_settings
                    log_success "out-range = ${_v}"; zapret2_update_config
                fi
                press_any_key ;;
            2)
                echo -en "  split len [${ZAPRET2_SPLIT_LEN}] (50..400): "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 50 ] && [ "$_v" -le 1000 ]; then
                    ZAPRET2_SPLIT_LEN="$_v"; save_nft_settings
                    log_success "split len = ${_v}"; zapret2_update_config
                elif [ -n "$_v" ]; then log_error "Диапазон: 50..1000"; fi
                press_any_key ;;
            3)
                echo -en "  win SYN+ACK [${ZAPRET2_WIN_SYNACK}]: "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 10 ] && [ "$_v" -le 65535 ]; then
                    ZAPRET2_WIN_SYNACK="$_v"; save_nft_settings
                    log_success "win SYN+ACK = ${_v}"; zapret2_update_config
                elif [ -n "$_v" ]; then log_error "Диапазон: 10..65535"; fi
                press_any_key ;;
            4)
                echo -en "  win ACK [${ZAPRET2_WIN_ACK}]: "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 1 ] && [ "$_v" -le 65535 ]; then
                    ZAPRET2_WIN_ACK="$_v"; save_nft_settings
                    echo -e "  ${YELLOW}⚠ Если перестанет подключаться — верните 10${NC}"
                    log_success "win ACK = ${_v}"; zapret2_update_config
                elif [ -n "$_v" ]; then log_error "Диапазон: 1..65535"; fi
                press_any_key ;;
            5)
                echo -en "  in-range [${ZAPRET2_IN_RANGE}]: "
                local _v; read -r _v
                if [ -n "$_v" ]; then
                    ZAPRET2_IN_RANGE="$_v"; save_nft_settings
                    log_success "in-range = ${_v}"; zapret2_update_config
                fi
                press_any_key ;;
            6)
                echo -en "  NFQUEUE [${ZAPRET2_QNUM}]: "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 0 ] && [ "$_v" -le 65535 ]; then
                    ZAPRET2_QNUM="$_v"; save_nft_settings
                    log_success "NFQUEUE = ${_v}"; zapret2_update_config
                elif [ -n "$_v" ]; then log_error "Диапазон: 0..65535"; fi
                press_any_key ;;
            7)
                echo -en "  fwmark [${ZAPRET2_FWMARK}]: "
                local _v; read -r _v
                if [ -n "$_v" ]; then
                    ZAPRET2_FWMARK="$_v"; save_nft_settings
                    log_success "fwmark = ${_v}"; zapret2_update_config
                fi
                press_any_key ;;
            8) zapret2_check_wscale "false"; press_any_key ;;
            9)
                if [ "${ZAPRET2_DEBUG:-false}" = "true" ]; then
                    echo -en "  ${BOLD}Выключить debug лог? [Y/n]:${NC} "
                    local _yn; read -r _yn
                    if [[ ! "$_yn" =~ ^[nN]$ ]]; then
                        ZAPRET2_DEBUG="false"; save_nft_settings
                        log_success "Debug лог выключен"; zapret2_update_config
                    fi
                else
                    echo -e "  ${YELLOW}⚠ Debug лог может быстро расти — выключите после отладки${NC}"
                    echo -en "  ${BOLD}Включить debug лог? [Y/n]:${NC} "
                    local _yn; read -r _yn
                    if [[ ! "$_yn" =~ ^[nN]$ ]]; then
                        ZAPRET2_DEBUG="true"; save_nft_settings
                        log_success "Debug лог включён → ${ZAPRET2_DEBUG_LOG}"; zapret2_update_config
                    fi
                fi
                press_any_key ;;
            0|"") return ;;
        esac
    done
}
