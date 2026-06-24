#!/bin/bash
# MTProxyL — подменю: логи и трафик

tui_traffic_menu() {
    while true; do
        clear_screen
        draw_header "ЛОГИ И ТРАФИК"

        if ! is_proxy_running; then
            echo -e "  ${DIM}Прокси не запущен${NC}"; press_any_key; return
        fi

        local t_in t_out conns
        read -r t_in t_out conns <<< "$(get_proxy_stats)"
        echo ""
        echo -e "  ${BOLD}Общий трафик${NC}"
        echo -e "  ${SYM_DOWN} Скачано:    $(format_bytes "$t_in")"
        echo -e "  ${SYM_UP} Отправлено: $(format_bytes "$t_out")"
        echo -e "  ${BOLD}Активных соединений:${NC} ${conns}"
        echo ""

        echo -e "  ${BOLD}По пользователям${NC}"
        echo -e "  ${DIM}$(_repeat '─' 60)${NC}"
        local i; for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
            local label="${SECRETS_LABELS[$i]}"
            local u_in u_out u_conns
            read -r u_in u_out u_conns <<< "$(get_user_stats "$label")"
            echo -e "  ${GREEN}${SYM_OK}${NC} ${BOLD}${label}${NC}"
            echo -e "    ${SYM_DOWN} $(format_bytes "$u_in")  ${SYM_UP} $(format_bytes "$u_out")  соед: ${u_conns}"
        done
        echo ""
        echo -e "  ${DIM}[1]${NC} Потоковые логи"
        echo -e "  ${DIM}[2]${NC} Метрики движка"
        echo -e "  ${DIM}[3]${NC} Метрики движка (live)"
        echo -e "  ${DIM}[4]${NC} Активные соединения"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) echo -e "  ${DIM}Ctrl+C для остановки...${NC}"; docker logs -f --tail 30 "$CONTAINER_NAME" 2>&1; ;;
            2) show_metrics 2>/dev/null || log_error "Метрики недоступны"; press_any_key ;;
            3) tui_metrics_live ;;
            4) show_connections; press_any_key ;;
            0|"") return ;;
        esac
    done
}

tui_metrics_live() {
    local interval=5
    trap 'return 0' INT
    while true; do
        clear_screen
        show_metrics 2>/dev/null || { log_error "Метрики недоступны"; break; }
        echo -e "  ${DIM}[обновление каждые ${interval}с, Ctrl+C для остановки]${NC}"
        sleep "$interval" || break
    done
    trap - INT
}

