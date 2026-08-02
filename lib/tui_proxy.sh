#!/bin/bash
# MTProxyL — подменю: прокси

tui_proxy_menu() {
    while true; do
        clear_screen
        draw_header "УПРАВЛЕНИЕ ПРОКСИ"
        echo ""
        local _st; is_proxy_running && _st="$(draw_status running)" || _st="$(draw_status stopped)"
        echo -e "  Статус: ${_st}"
        local _manager="false"
        [ "${MTPROXYL_MODE:-manager}" = "manager" ] && _manager="true"
        if [ "$_manager" = "true" ]; then
            local _cst; _cst=$(own_container_state 2>/dev/null)
            echo -e "  Контейнер: ${_cst}"
            if [ "$_cst" != "running" ] && [ "$_cst" != "absent" ]; then
                local _prob; _prob=$(own_container_problem 2>/dev/null)
                [ -n "$_prob" ] && echo -e "  ${RED}Проблема:${NC} ${_prob}"
            fi
        fi
        echo ""
        echo -e "  ${DIM}[1]${NC} Запустить"
        echo -e "  ${DIM}[2]${NC} Остановить"
        echo -e "  ${DIM}[3]${NC} Перезапустить"
        echo -e "  ${DIM}[4]${NC} Логи"
        echo -e "  ${DIM}[5]${NC} Диагностика"
        [ "$_manager" = "true" ] && echo -e "  ${DIM}[6]${NC} Удалить контейнер ${DIM}(образ и конфиг сохранятся)${NC}"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) start_target || true; press_any_key ;;
            2) stop_target || true; press_any_key ;;
            3) restart_target || true; press_any_key ;;
            4) echo -e "  ${DIM}Ctrl+C для остановки...${NC}"; show_target_logs 30 || true; press_any_key ;;
            5) health_check || true; press_any_key ;;
            6)
                if [ "$_manager" != "true" ]; then
                    log_error "Пункт доступен только в режиме manager"
                    press_any_key; continue
                fi
                echo ""
                echo -e "  ${DIM}Контейнер будет остановлен и удалён. Образ, конфиг и секреты${NC}"
                echo -e "  ${DIM}сохранятся — прокси поднимется заново пунктом [1].${NC}"
                echo -en "  ${BOLD}Удалить контейнер? [y/N]:${NC} "
                local _yn; read_line _yn
                [[ "$_yn" =~ ^[yY] ]] && { remove_own_container || true; } || log_info "Отменено"
                press_any_key ;;
            0|"") return ;;
        esac
    done
}
