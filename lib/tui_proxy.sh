#!/bin/bash
# MTProxyL — подменю: прокси

tui_proxy_menu() {
    while true; do
        clear_screen
        draw_header "УПРАВЛЕНИЕ ПРОКСИ"
        echo ""
        local _st; is_proxy_running && _st="$(draw_status running)" || _st="$(draw_status stopped)"
        echo -e "  Статус: ${_st}"
        echo ""
        echo -e "  ${DIM}[1]${NC} Запустить"
        echo -e "  ${DIM}[2]${NC} Остановить"
        echo -e "  ${DIM}[3]${NC} Перезапустить"
        echo -e "  ${DIM}[4]${NC} Логи"
        echo -e "  ${DIM}[5]${NC} Диагностика"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) start_proxy_container || true; press_any_key ;;
            2) stop_proxy_container || true; press_any_key ;;
            3) restart_proxy_container || true; press_any_key ;;
            4) echo -e "  ${DIM}Ctrl+C для остановки...${NC}"; docker logs -f --tail 30 "$CONTAINER_NAME" 2>&1 || true; press_any_key ;;
            5) health_check || true; press_any_key ;;
            0|"") return ;;
        esac
    done
}
