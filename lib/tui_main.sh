#!/bin/bash
# MTProxyL — главное меню

show_banner() {
    echo -e "${BRIGHT_CYAN}"
    cat << 'BANNER'

    ███╗   ███╗████████╗██████╗ ██████╗  ██████╗
    ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗
    ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║
    ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║
    ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝
    ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝
BANNER
    echo -e "    ${BOLD}MTProxyL v${VERSION}${NC} ${DIM}by LiafanX${NC}"
    echo -e "${NC}"
}

show_main_menu() {
    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        show_banner

        local _running=false
        is_proxy_running && _running=true

        local status_str uptime_str t_in t_out conns
        if [ "$_running" = "true" ]; then
            status_str=$(draw_status running)
            local up_secs; up_secs=$(get_proxy_uptime)
            uptime_str=$(format_duration "$up_secs")
            read -r t_in t_out conns <<< "$(get_proxy_stats)"
        else
            status_str=$(draw_status stopped)
            uptime_str="—"; t_in=0; t_out=0; conns=0
        fi

        local active=0 disabled=0 i
        for i in "${!SECRETS_ENABLED[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && active=$((active+1)) || disabled=$((disabled+1))
        done

        echo -e "  ${BOLD}Движок:${NC}      telemt v$(get_telemt_version)  ${BOLD}Статус:${NC} ${status_str}"
        echo -e "  ${BOLD}Порт:${NC}        ${PROXY_PORT}            ${BOLD}Работает:${NC} ${uptime_str}"
        echo -e "  ${BOLD}Домен:${NC}       ${PROXY_DOMAIN}"
        echo -e "  ${BOLD}Трафик:${NC}      ${SYM_DOWN} $(format_bytes "$t_in")  ${SYM_UP} $(format_bytes "$t_out")  ${BOLD}Соед.:${NC} ${conns}"
        echo -e "  ${BOLD}Секреты:${NC}     ${active} активных / ${disabled} выключенных"

        load_nft_settings 2>/dev/null
        echo -e "  ${BOLD}NFT лимитер:${NC} $(nft_status_line 2>/dev/null || echo "${DIM}—${NC}")"
        echo -e "  ${BOLD}iOS фикс v1:${NC} $(ios_fix_status_line 2>/dev/null || echo "${DIM}—${NC}")"
        echo -e "  ${BOLD}iOS фикс v2:${NC} $(ios2_fix_status_line 2>/dev/null || echo "${DIM}—${NC}")"

        if [ -n "$_UPDATE_AVAILABLE" ]; then
            echo ""
            echo -e "  ${YELLOW}${BOLD}⬆ Доступно обновление: v${VERSION} → v${_UPDATE_AVAILABLE}${NC}"
            echo -e "  ${DIM}  Обновить: меню [9] → Проверить обновления${NC}"
        fi

        echo ""
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${BRIGHT_CYAN}[1]${NC}  Управление прокси"
        echo -e "  ${BRIGHT_CYAN}[2]${NC}  Управление секретами (пользователями)"
        echo -e "  ${BRIGHT_CYAN}[3]${NC}  Ссылки на прокси"
        echo -e "  ${BRIGHT_CYAN}[4]${NC}  Настройки"
        echo -e "  ${BRIGHT_CYAN}[5]${NC}  Безопасность и маршрутизация"
        echo -e "  ${BRIGHT_CYAN}[6]${NC}  Логи и трафик"
        echo -e "  ${BRIGHT_CYAN}[7]${NC}  NFT лимитер и iOS фиксы"
        echo -e "  ${BRIGHT_CYAN}[8]${NC}  Движок Telemt"
        echo -e "  ${BRIGHT_CYAN}[9]${NC}  Обновление и бэкапы"
        echo -e "  ${BRIGHT_CYAN}[e]${NC}  Режим эксперта (свои значения в config.toml)"
        echo -e "  ${BRIGHT_CYAN}[i]${NC}  Информация"
        echo ""
        echo -e "  ${BRIGHT_CYAN}[r]${NC}  Переустановить"
        echo -e "  ${RED}[u]${NC}  Удаление"
        echo -e "  ${BRIGHT_CYAN}[0]${NC}  Выход"
        echo ""
        local choice; choice=$(read_choice "выбор" "0")

        case "$choice" in
            1) tui_proxy_menu ;;
            2) tui_secrets_menu ;;
            3) tui_links_menu ;;
            4) tui_settings_menu ;;
            5) tui_security_menu ;;
            6) tui_traffic_menu ;;
            7) tui_nft_menu ;;
            8) tui_engine_menu ;;
            9) tui_backup_menu ;;
            e|E) tui_expert_menu ;;
            i|I) show_server_info; press_any_key ;;
            r|R) run_installer ;;
            u|U) uninstall; exit 0 ;;
            0|q|Q) exit 0 ;;
        esac
    done
}
