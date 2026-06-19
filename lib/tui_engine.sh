#!/bin/bash
# MTProxyL — подменю: движок

tui_engine_menu() {
    while true; do
        clear_screen
        draw_header "ДВИЖОК TELEMT"
        echo ""
        echo -e "  ${BOLD}Версия:${NC}    telemt v$(get_telemt_version)"
        echo -e "  ${BOLD}Закреплён:${NC} commit ${TELEMT_COMMIT}"
        echo ""
        echo -e "  ${DIM}[1]${NC} Список версий"
        echo -e "  ${DIM}[2]${NC} Обновить до версии"
        echo -e "  ${DIM}[3]${NC} Откатить"
        echo -e "  ${DIM}[4]${NC} Пересобрать"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) handle_engine_command list; press_any_key ;;
            2) handle_engine_command update; press_any_key ;;
            3) handle_engine_command rollback; press_any_key ;;
            4) build_telemt_image true; is_proxy_running && { load_secrets; restart_proxy_container || true; }; press_any_key ;;
            0|"") return ;;
        esac
    done
}
