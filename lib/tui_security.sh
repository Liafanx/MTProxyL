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
        echo -e "  ${DIM}[2]${NC} Upstream-маршруты"
        echo -e "  ${DIM}[3]${NC} SNI-политика: ${sni_label}"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) tui_geoblock_menu ;;
            2) tui_upstream_menu ;;
            3)
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
        echo ""
        echo -e "  ${DIM}[1]${NC} Добавить страну"
        echo -e "  ${DIM}[2]${NC} Удалить страну"
        echo -e "  ${DIM}[3]${NC} Очистить все"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) echo -e "  ${DIM}Коды: US DE NL FR GB SG JP CN RU IR${NC}"
               echo -en "  ${BOLD}Код:${NC} "; local cc; read -r cc
               [ -n "$cc" ] && handle_geoblock_command add "$cc"; press_any_key ;;
            2) echo -en "  ${BOLD}Код:${NC} "; local cc; read -r cc
               [ -n "$cc" ] && handle_geoblock_command remove "$cc"; press_any_key ;;
            3) handle_geoblock_command clear; press_any_key ;;
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
            1) echo -en "  ${BOLD}Имя:${NC} "; local n; read -r n
               echo -e "  ${DIM}[1] SOCKS5  [2] SOCKS4  [3] Direct${NC}"
               local tc; read -rp "  > " tc
               local t; case "$tc" in 1) t="socks5" ;; 2) t="socks4" ;; *) t="direct" ;; esac
               local a="" us="" ps=""
               if [ "$t" != "direct" ]; then
                   echo -en "  ${BOLD}Адрес:${NC} "; read -r a
                   echo -en "  ${BOLD}Логин:${NC} "; read -r us
                   echo -en "  ${BOLD}Пароль:${NC} "; read -r ps; fi
               echo -en "  ${BOLD}Вес [10]:${NC} "; local w; read -r w; w="${w:-10}"
               upstream_add "$n" "$t" "$a" "$us" "$ps" "$w" || true; press_any_key ;;
            2) echo -en "  ${BOLD}Имя:${NC} "; local n; read -r n; [ -n "$n" ] && upstream_remove "$n" || true; press_any_key ;;
            3) echo -en "  ${BOLD}Имя:${NC} "; local n; read -r n; [ -n "$n" ] && upstream_toggle "$n" || true; press_any_key ;;
            4) echo -en "  ${BOLD}Имя:${NC} "; local n; read -r n; [ -n "$n" ] && upstream_test "$n" || true; press_any_key ;;
            0|"") return ;;
        esac
    done
}
