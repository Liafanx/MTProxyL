#!/bin/bash
# MTProxyL — подменю: selfmask

tui_selfmask_menu() {
    while true; do
        clear_screen
        draw_header "SELFMASK (NGINX + LET'S ENCRYPT)"
        echo ""
        echo -e "  ${BOLD}Статус:${NC} $(selfmask_status_line 2>/dev/null || echo "${DIM}неизвестно${NC}")"
        echo -e "  ${BOLD}Домен:${NC}  ${SELFMASK_DOMAIN:-${DIM}не задан${NC}}"
        echo -e "  ${BOLD}Backend:${NC} 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT:-8444}"
        echo -e "  ${BOLD}TLS:${NC}    ${SELFMASK_TLS_PROTOCOLS:-TLSv1.2}"
        echo ""

        echo -e "  ${YELLOW}${BOLD}Важно:${NC} домен FakeTLS должен поддерживать PQ hybrid"
        echo -e "  ${DIM}Проверка: @Sni_checker_bot${NC}"
        echo ""

        echo -e "  ${CYAN}[1]${NC}  Статус и требования"
        echo -e "  ${CYAN}[2]${NC}  Настроить / переустановить selfmask"
        echo -e "  ${CYAN}[3]${NC}  Проверить selfmask"
        echo -e "  ${CYAN}[4]${NC}  Отключить selfmask"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""

        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) selfmask_show_status; press_any_key ;;
            2) selfmask_setup; press_any_key ;;
            3) selfmask_verify; press_any_key ;;
            4) selfmask_disable; press_any_key ;;
            0|"") return ;;
        esac
    done
}
