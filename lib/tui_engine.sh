#!/bin/bash
# MTProxyL — подменю: движок

tui_engine_menu() {
    while true; do
        clear_screen
        draw_header "ДВИЖОК TELEMT"
        echo ""
        echo -e "  ${BOLD}Носитель:${NC}  $(engine_backend_title)"
        echo -e "  ${BOLD}Версия:${NC}    telemt v$(get_telemt_version)"
        if engine_is_binary; then
            echo -e "  ${BOLD}Бинарник:${NC}  ${ENGINE_BIN_PATH}"
            echo -e "  ${BOLD}Служба:${NC}    ${ENGINE_SERVICE}.service"
        else
            echo -e "  ${BOLD}Закреплён:${NC} commit ${TELEMT_COMMIT}"
        fi
        echo ""
        echo -e "  ${DIM}[1]${NC} Список версий"
        echo -e "  ${DIM}[2]${NC} Обновить до версии"
        echo -e "  ${DIM}[3]${NC} Откатить"
        if engine_is_binary; then
            echo -e "  ${DIM}[4]${NC} Перекачать текущую версию"
            echo -e "  ${DIM}[5]${NC} Перейти на Docker-образ"
        else
            echo -e "  ${DIM}[4]${NC} Пересобрать"
            echo -e "  ${DIM}[5]${NC} Перейти на бинарник (без Docker)"
        fi
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) handle_engine_command list; press_any_key ;;
            2) handle_engine_command update; press_any_key ;;
            3) handle_engine_command rollback; press_any_key ;;
            4) handle_engine_command rebuild; press_any_key ;;
            5) if engine_is_binary; then
                   engine_switch_backend docker
               else
                   engine_switch_backend binary
               fi
               load_settings; press_any_key ;;
            0|"") return ;;
        esac
    done
}
