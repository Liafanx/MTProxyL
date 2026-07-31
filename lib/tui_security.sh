#!/bin/bash
# MTProxyL — подменю: безопасность и маршрутизация

tui_security_menu() {
    while true; do
        clear_screen
        draw_header "БЕЗОПАСНОСТЬ И МАРШРУТИЗАЦИЯ"
        echo ""
        local sni_label
        if [ "$UNKNOWN_SNI_ACTION" = "drop" ]; then
            sni_label="${RED}Drop${NC} (строгий)"
        else
            sni_label="${GREEN}Mask${NC} (перенаправление)"
        fi
        echo -e "  ${DIM}[1]${NC} Гео-блокировка"
        if [ "${MTPROXYL_MODE:-manager}" = "manager" ]; then
            echo -e "  ${DIM}[2]${NC} Upstream-маршруты"
            echo -e "  ${DIM}[3]${NC} SNI-политика: ${sni_label}"
        else
            echo -e "  ${DIM}────────────────────────────────────${NC}"
            echo -e "  ${DIM}Upstream-маршруты и SNI-политика правят только${NC}"
            echo -e "  ${DIM}собственный генерируемый конфиг менеджера — в режиме${NC}"
            echo -e "  ${DIM}reanimator недоступны (конфиг цели чужой).${NC}"
        fi
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) tui_geoblock_menu ;;
            2) _require_manager_mode && tui_upstream_menu || press_any_key ;;
            3)
                _require_manager_mode || { press_any_key; continue; }
                echo ""
                echo -e "  ${BOLD}SNI-политика${NC}"
                echo -e "  ${DIM}[1]${NC} ${GREEN}Mask${NC}  — перенаправлять на mask backend"
                echo -e "  ${DIM}[2]${NC} ${RED}Drop${NC}  — закрывать соединение"
                local sc; sc=$(read_choice "выбор" "0")
                case "$sc" in
                    1) UNKNOWN_SNI_ACTION="mask"; save_settings; reload_proxy_config 2>/dev/null || true; log_success "SNI: Mask" ;;
                    2) UNKNOWN_SNI_ACTION="drop"; save_settings; reload_proxy_config 2>/dev/null || true; log_success "SNI: Drop" ;;
                esac; press_any_key ;;
            0|"") return ;;
        esac
    done
}

tui_geoblock_menu() {
    while true; do
        clear_screen
        draw_header "ГЕО-БЛОКИРОВКА"
        echo ""
        echo -e "  ${BOLD}Режим:${NC}   ${GEOBLOCK_MODE}"
        echo -e "  ${BOLD}Страны:${NC} ${BLOCKLIST_COUNTRIES:-${DIM}нет${NC}}"
        if [ -n "${BLOCKLIST_COUNTRIES:-}" ]; then
            # Правила iptables/ipset не переживают перезагрузку — показываем
            # реальное состояние, а не только список стран в настройках.
            if geoblock_rules_active; then
                local _gp; _gp=$(geoblock_rules_port)
                if [ -n "$_gp" ] && [ "$_gp" != "${PROXY_PORT}" ]; then
                    echo -e "  ${BOLD}Правила:${NC} ${YELLOW}на порту ${_gp}, прокси на ${PROXY_PORT} — переприменить${NC}"
                else
                    echo -e "  ${BOLD}Правила:${NC} ${GREEN}активны${NC}"
                fi
            else
                echo -e "  ${BOLD}Правила:${NC} ${RED}отсутствуют${NC} ${DIM}(сброшены перезагрузкой?)${NC}"
            fi
        fi
        echo ""
        echo -e "  ${DIM}[1]${NC} Добавить страну"
        echo -e "  ${DIM}[2]${NC} Удалить страну"
        echo -e "  ${DIM}[3]${NC} Переприменить правила"
        echo -e "  ${DIM}[4]${NC} Очистить все"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) echo -e "  ${DIM}Коды: US DE NL FR GB SG JP CN RU IR${NC}"
               echo -en "  ${BOLD}Код:${NC} "; local cc; read_line cc
               [ -n "$cc" ] && handle_geoblock_command add "$cc"; press_any_key ;;
            2) echo -en "  ${BOLD}Код:${NC} "; local cc; read_line cc
               [ -n "$cc" ] && handle_geoblock_command remove "$cc"; press_any_key ;;
            3) handle_geoblock_command reapply; press_any_key ;;
            4) handle_geoblock_command clear; press_any_key ;;
            0|"") return ;;
        esac
    done
}

tui_upstream_menu() {
    while true; do
        clear_screen
        upstream_list
        echo -e "  ${DIM}[1]${NC} Добавить"
        echo -e "  ${DIM}[2]${NC} Удалить"
        echo -e "  ${DIM}[3]${NC} Вкл/выкл"
        echo -e "  ${DIM}[4]${NC} Тест"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) echo -en "  ${BOLD}Имя:${NC} "; local n; read_line n
               echo -e "  ${DIM}[1] SOCKS5  [2] SOCKS4  [3] Direct${NC}"
               local tc; read -erp "  > " tc
               local t; case "$tc" in 1) t="socks5" ;; 2) t="socks4" ;; *) t="direct" ;; esac
               local a="" us="" ps=""
               if [ "$t" != "direct" ]; then
                   echo -en "  ${BOLD}Адрес:${NC} "; read_line a
                   echo -en "  ${BOLD}Логин:${NC} "; read_line us
                   echo -en "  ${BOLD}Пароль:${NC} "; read_line ps; fi
               echo -en "  ${BOLD}Вес [10]:${NC} "; local w; read_line w; w="${w:-10}"
               upstream_add "$n" "$t" "$a" "$us" "$ps" "$w" || true; press_any_key ;;
            2) echo -en "  ${BOLD}Имя:${NC} "; local n; read_line n; [ -n "$n" ] && upstream_remove "$n" || true; press_any_key ;;
            3) echo -en "  ${BOLD}Имя:${NC} "; local n; read_line n; [ -n "$n" ] && upstream_toggle "$n" || true; press_any_key ;;
            4) echo -en "  ${BOLD}Имя:${NC} "; local n; read_line n; [ -n "$n" ] && upstream_test "$n" || true; press_any_key ;;
            0|"") return ;;
        esac
    done
}
