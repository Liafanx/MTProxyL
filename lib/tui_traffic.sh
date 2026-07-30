#!/bin/bash
# MTProxyL — подменю: логи и трафик

tui_traffic_menu() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        _tui_traffic_menu_reanimator
        return
    fi

    while true; do
        clear_screen
        draw_header "ЛОГИ И ТРАФИК"

        if ! is_proxy_running; then
            echo -e "  ${DIM}Прокси не запущен${NC}"; press_any_key; return
        fi

        flush_traffic_to_disk 2>/dev/null || true

        local t_in t_out conns
        read -r t_in t_out conns <<< "$(get_persistent_stats)"
        local s_in s_out s_conns
        read -r s_in s_out s_conns <<< "$(get_proxy_stats)"
        echo ""
        echo -e "  ${BOLD}Общий трафик (с учётом перезагрузок):${NC}"
        echo -e "  ${SYM_DOWN} Скачано:    $(format_bytes "$t_in")"
        echo -e "  ${SYM_UP} Отправлено: $(format_bytes "$t_out")"
        echo ""
        echo -e "  ${BOLD}Текущая сессия:${NC}"
        echo -e "  ${SYM_DOWN} Скачано:    $(format_bytes "$s_in")"
        echo -e "  ${SYM_UP} Отправлено: $(format_bytes "$s_out")"
        echo -e "  ${BOLD}Активных соединений:${NC} ${s_conns}"
        echo ""

        echo -e "  ${BOLD}По пользователям${NC}"
        echo -e "  ${DIM}$(_repeat '─' 60)${NC}"
        local i; for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
            local label="${SECRETS_LABELS[$i]}"
            local u_in u_out u_conns
            read -r u_in u_out u_conns <<< "$(get_persistent_user_stats "$label")"
            local su_in su_out su_conns
            read -r su_in su_out su_conns <<< "$(get_user_stats "$label")"
            echo -e "  ${GREEN}${SYM_OK}${NC} ${BOLD}${label}${NC}"
            echo -e "    Всего: ${SYM_DOWN} $(format_bytes "$u_in")  ${SYM_UP} $(format_bytes "$u_out")"
            echo -e "    Сессия: ${SYM_DOWN} $(format_bytes "$su_in")  ${SYM_UP} $(format_bytes "$su_out")  соед: ${su_conns}"
        done
        echo ""
        echo -e "  ${DIM}[1]${NC} Потоковые логи"
        echo -e "  ${DIM}[2]${NC} Метрики движка"
        echo -e "  ${DIM}[3]${NC} Метрики движка (live)"
        echo -e "  ${DIM}[4]${NC} Активные соединения"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) echo -e "  ${DIM}Ctrl+C для остановки...${NC}"; show_target_logs 30; ;;
            2) show_metrics 2>/dev/null || log_error "Метрики недоступны"; press_any_key ;;
            3) tui_metrics_live ;;
            4) show_connections; press_any_key ;;
            0|"") return ;;
        esac
    done
}

# Reanimator: трафик/соединения/пользователи берём из API цели
# (/v1/users), т.к. Prometheus-метрики у telemt по умолчанию выключены.
# Метрики движка показываем только если цель их реально отдаёт.
_tui_traffic_menu_reanimator() {
    while true; do
        clear_screen
        draw_header "ЛОГИ И ТРАФИК (ЦЕЛЬ)"

        if ! is_proxy_running; then
            echo -e "  ${DIM}Цель не запущена${NC}"; press_any_key; return
        fi

        local _json _rc _rows=""
        _json=$(_get_telemt_users_json 2>/dev/null); _rc=$?
        [ $_rc -eq 0 ] && _rows=$(_target_user_stats "$_json")

        echo ""
        if [ $_rc -ne 0 ]; then
            log_warn "Статистика недоступна: $(_telemt_api_unavailable_reason)"
            [ $_rc -eq 2 ] && log_info "Включите [server.api] enabled = true в конфиге цели и перезапустите её"
        else
            local _tot_oct _tot_conn _tot_ips
            _tot_oct=$(_json_sum_field "$_json" "total_octets")
            _tot_conn=$(_json_sum_field "$_json" "current_connections")
            _tot_ips=$(_json_sum_field "$_json" "active_unique_ips")
            echo -e "  ${BOLD}Всего по цели${NC} ${DIM}(API 127.0.0.1:$(_get_telemt_api_port))${NC}:"
            echo -e "  Передано:            $(format_bytes "$_tot_oct")"
            echo -e "  Активных соединений: ${_tot_conn}"
            echo -e "  Уникальных IP:       ${_tot_ips}"
            echo ""
            echo -e "  ${BOLD}По пользователям${NC}"
            echo -e "  ${DIM}$(_repeat '─' 60)${NC}"
            local _u _en _c _ips _oct _mark
            while IFS='|' read -r _u _en _c _ips _oct; do
                [ -z "$_u" ] && continue
                if [ "$_en" = "false" ]; then
                    _mark="${DIM}${SYM_CROSS}${NC}"
                else
                    _mark="${GREEN}${SYM_OK}${NC}"
                fi
                echo -e "  ${_mark} ${BOLD}${_u}${NC}"
                echo -e "    Передано: $(format_bytes "$_oct")  соед: ${_c}  уник. IP: ${_ips}"
            done <<< "$_rows"
        fi

        echo ""
        echo -e "  ${DIM}[1]${NC} Потоковые логи"
        echo -e "  ${DIM}[2]${NC} Обновить статистику"
        echo -e "  ${DIM}[3]${NC} Метрики движка цели"
        echo -e "  ${DIM}[4]${NC} Метрики движка цели (live)"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) echo -e "  ${DIM}Ctrl+C для остановки...${NC}"; show_target_logs 30 ;;
            2) ;;
            3)
                if _target_metrics_available; then
                    show_metrics 2>/dev/null || log_error "Не удалось разобрать метрики"
                else
                    _target_metrics_hint
                fi
                press_any_key ;;
            4)
                if _target_metrics_available; then
                    tui_metrics_live
                else
                    _target_metrics_hint
                    press_any_key
                fi ;;
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

