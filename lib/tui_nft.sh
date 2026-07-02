#!/bin/bash
# MTProxyL — подменю: NFT лимитер + iOS фиксы + Smart режим

tui_nft_menu() {
    while true; do
        clear_screen
        draw_header "NFT ЛИМИТЕР И iOS ФИКСЫ"
        echo ""
        load_nft_settings 2>/dev/null

        # Статус
        echo -e "  ${BOLD}NFT лимитер:${NC} $(nft_status_line)"
        echo -e "  ${BOLD}iOS фикс v1:${NC} $(ios_fix_status_line)"
        echo -e "  ${BOLD}iOS фикс v2:${NC} $(ios2_fix_status_line)"
        echo -e "  ${BOLD}MEKO оптим.:${NC} $(meko_opt_status)"
        echo ""

        # Текущие параметры
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
        echo ""

        echo -e "  ${BRIGHT_GREEN}[s]${NC}  ${BOLD}★ Smart By-MEKO${NC} ${DIM}(iOS/Android авторазделение + REJECT)${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  Применить NFT правила"
        echo -e "  ${CYAN}[2]${NC}  Удалить NFT правила"
        echo -e "  ${CYAN}[3]${NC}  Пресеты (жёсткий / средний / мягкий / smart)"
        echo -e "  ${CYAN}[4]${NC}  Настройки NFT (rate / burst / timeout / IP)"
        echo -e "  ${CYAN}[5]${NC}  Счётчик правил"
        echo -e "  ${CYAN}[6]${NC}  Установить службу автозапуска"
        echo -e "  ${CYAN}[7]${NC}  Удалить службу"
        echo -e "  ${CYAN}[8]${NC}  Дополнительные правила"
        echo ""
        echo -e "  ${CYAN}[a]${NC}  iOS Fix v1 — TCP keepalive"
        echo -e "  ${CYAN}[b]${NC}  iOS Fix v2 — MSS + redirect"
        echo -e "  ${CYAN}[m]${NC}  Оптимизация By-MEKO (BBR, очереди, keepalive)"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""
        local choice; choice=$(read_choice "выбор" "0")

        case "$choice" in
            s|S) enable_smart_mode; press_any_key ;;
            1)
                if [ -z "${PROXY_PORT:-}" ]; then
                    log_error "Порт прокси не задан — запустите прокси"
                    press_any_key; continue
                fi
                apply_nft_rules || true
                press_any_key ;;
            2) remove_nft_rules || true; press_any_key ;;
            3) tui_nft_presets ;;
            4) tui_nft_settings ;;
            5) show_nft_drop_counter || true ;;
            6)
                if [ -z "${PROXY_PORT:-}" ]; then
                    log_error "Порт прокси не задан — запустите прокси"
                    press_any_key; continue
                fi
                install_nft_service || true
                press_any_key ;;
            7) remove_nft_service || true; press_any_key ;;
            8) tui_nft_extra_menu ;;
            a|A) tui_ios1_menu ;;
            b|B) tui_ios2_menu ;;
            m|M) tui_meko_opt_menu ;;
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
    echo -e "      ${DIM}iOS/Android авторазделение по TTL + REJECT вместо DROP.${NC}"
    echo -e "      ${DIM}Подключение 3-8 сек. Один порт для всех клиентов.${NC}"
    echo ""
    echo -e "  ${RED}[1]${NC} Жёсткий (Classic)  — 1/second burst 1"
    echo -e "      ${DIM}Каждый IP — не более 1 SYN/сек. DROP при превышении.${NC}"
    echo ""
    echo -e "  ${YELLOW}[2]${NC} Средний (Classic)  — 1/second burst 3"
    echo -e "      ${DIM}Разрешает кратковременный burst.${NC}"
    echo ""
    echo -e "  ${GREEN}[3]${NC} Мягкий (Classic)   — 2/second burst 5"
    echo -e "      ${DIM}Для серверов с большим числом клиентов или за CGNAT.${NC}"
    echo ""
    echo -e "  ${DIM}[4]${NC} Свой вариант (Classic)"
    echo -e "  ${DIM}[0]${NC} Назад"
    echo ""
    local choice; choice=$(read_choice "выбор" "0")

    case "$choice" in
        s|S) enable_smart_mode ;;
        1) apply_nft_preset hard ;;
        2) apply_nft_preset medium ;;
        3) apply_nft_preset soft ;;
        4)
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
        echo -e "  ${DIM}[i]${NC} IP привязку"
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
