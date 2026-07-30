#!/bin/bash
# MTProxyL — подменю: цель / режим (Manager ⇄ Reanimator)

tui_target_menu() {
    while true; do
        clear_screen
        draw_header "ЦЕЛЬ / РЕЖИМ"
        echo ""
        echo -e "  ${BOLD}Текущий режим:${NC} ${MTPROXYL_MODE:-manager}"
        if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
            echo -e "  ${BOLD}Цель:${NC}          ${DETECTED_MODE:-unknown}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
            echo -e "  ${BOLD}Конфиг цели:${NC}   ${DETECTED_CONFIG_PATH:-нет}"
            echo -e "  ${BOLD}Сеть Docker:${NC}   ${DETECTED_NETWORK_MODE:-?}"
        fi
        echo ""
        echo -e "  ${DIM}[1]${NC} Повторить обнаружение цели"
        if [ "${MTPROXYL_MODE:-manager}" = "manager" ]; then
            echo -e "  ${DIM}[2]${NC} Переключиться в Reanimator"
        else
            echo -e "  ${DIM}[2]${NC} Переключиться в Manager"
        fi
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) run_target_detection; save_detect_settings; sync_port_from_target; press_any_key ;;
            2)
                if [ "${MTPROXYL_MODE:-manager}" = "manager" ]; then
                    switch_to_reanimator_mode
                else
                    switch_to_manager_mode
                fi
                press_any_key ;;
            0|"") return ;;
        esac
    done
}
