#!/bin/bash
# MTProxyL — подменю: логи и трафик

# Состояние снимков истории одной строкой — для пункта меню.
_tui_ip_history_line() {
    local _min; _min=$(_ip_history_interval_minutes)
    if [ "$_min" -gt 0 ] && ip_history_timer_active; then
        echo "снимки каждые ${_min} мин"
    else
        echo "снимки выключены"
    fi
}

# Сокращённый экран для остановленного прокси: статистики нет, но логи и
# история IP работают. Возвращает 0, если надо остаться в меню.
_tui_traffic_actions() {
    echo -e "  ${DIM}[1]${NC} Потоковые логи"
    echo -e "  ${DIM}[5]${NC} История IP: ${1}"
    echo -e "  ${DIM}[0]${NC} Назад"
    local choice; choice=$(read_choice "выбор" "0")
    case "$choice" in
        1) echo -e "  ${DIM}Ctrl+C для остановки...${NC}"; show_target_logs 30; return 0 ;;
        5) tui_ip_history_menu; return 0 ;;
    esac
    return 1
}

# Снимки истории IP. Доступно в обоих режимах: история копится и по чужой цели.
tui_ip_history_menu() {
    while true; do
        clear_screen
        draw_header "ИСТОРИЯ IP"

        local _db="${_USER_IPS_DB}"
        [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] && _db="${_TARGET_USER_IPS_DB}"
        local _min; _min=$(_ip_history_interval_minutes)

        echo ""
        if [ "$_min" -gt 0 ] && ip_history_timer_active; then
            echo -e "  ${BOLD}Снимки:${NC}     ${GREEN}каждые ${_min} мин${NC}"
            local _next
            _next=$(systemctl list-timers "$IP_HISTORY_TIMER" --no-pager 2>/dev/null \
                | awk 'NR == 2 && $5 != "" { printf "%s %s %s (через %s)", $2, $3, $4, $5 }')
            [ -n "$_next" ] && echo -e "  ${BOLD}Следующий:${NC} ${DIM}${_next}${NC}"
        else
            echo -e "  ${BOLD}Снимки:${NC}     ${YELLOW}выключены${NC}"
            echo -e "  ${DIM}Адреса записываются только при обращении к списку${NC}"
            echo -e "  ${DIM}пользователей — то есть пока открыта панель.${NC}"
        fi
        echo -e "  ${BOLD}Записей:${NC}    $(grep -c '^USER|' "$_db" 2>/dev/null || echo 0)"
        echo -e "  ${BOLD}Хранить:${NC}    $(_user_ip_history_cap) адресов на пользователя"
        echo ""
        echo -e "  ${DIM}[1]${NC} Снять адреса сейчас"
        echo -e "  ${DIM}[2]${NC} Интервал снимков"
        if [ "$_min" -gt 0 ]; then
            echo -e "  ${DIM}[3]${NC} Выключить снимки"
        else
            echo -e "  ${DIM}[3]${NC} Включить снимки"
        fi
        echo -e "  ${DIM}[4]${NC} Сколько адресов хранить"
        echo -e "  ${DIM}[0]${NC} Назад"

        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                if ip_history_snapshot; then
                    log_success "Адреса записаны"
                else
                    log_warn "Движок не ответил — снимать нечего"
                fi
                press_any_key ;;
            2)
                echo -en "  ${BOLD}Минут между снимками [${_min}, 0 — выключить]:${NC} "
                local _v; read_line _v
                [ -n "$_v" ] || continue
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -le 1440 ]; then
                    IP_HISTORY_INTERVAL="$_v"
                    save_settings
                    install_ip_history_timer
                    log_success "Интервал: $([ "$_v" -gt 0 ] && echo "${_v} мин" || echo "снимки выключены")"
                else
                    log_error "Нужно число от 0 до 1440"
                fi
                press_any_key ;;
            3)
                if [ "$_min" -gt 0 ]; then
                    IP_HISTORY_INTERVAL="0"
                    save_settings
                    remove_ip_history_timer
                    log_success "Снимки выключены"
                else
                    IP_HISTORY_INTERVAL="5"
                    save_settings
                    install_ip_history_timer
                    log_success "Снимки: каждые 5 мин"
                fi
                press_any_key ;;
            4)
                echo -en "  ${BOLD}Адресов на пользователя [$(_user_ip_history_cap)]:${NC} "
                local _c; read_line _c
                [ -n "$_c" ] || continue
                if [[ "$_c" =~ ^[0-9]+$ ]] && [ "$_c" -ge 1 ] && [ "$_c" -le 100000 ]; then
                    IP_HISTORY_LIMIT="$_c"
                    save_settings
                    log_success "Хранить: ${_c} адресов"
                    log_info "Лишнее подрежется на ближайшем снимке"
                else
                    log_error "Нужно число от 1 до 100000"
                fi
                press_any_key ;;
            0|"") return ;;
        esac
    done
}

tui_traffic_menu() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        _tui_traffic_menu_reanimator
        return
    fi

    while true; do
        clear_screen
        draw_header "ЛОГИ И ТРАФИК"

        # Раньше остановленный прокси закрывал весь экран. Снимки истории IP
        # настраиваются и без него, поэтому уходит только статистика.
        local _running="true"
        is_proxy_running || _running="false"
        if [ "$_running" != "true" ]; then
            echo ""
            echo -e "  ${DIM}Прокси не запущен — статистика недоступна${NC}"
            echo ""
            _tui_traffic_actions "$(_tui_ip_history_line)" && continue
            return
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
        # В режиме супер эксперта пользователи заданы в конфиге пользователя,
        # а не в secrets.conf — иначе показали бы только «своих».
        local _labels=()
        if _superexpert_active; then
            local _su _sk
            while IFS='|' read -r _su _sk; do
                [ -n "$_su" ] && _labels+=("$_su")
            done <<< "$(_superexpert_users)"
        else
            local i
            for i in "${!SECRETS_LABELS[@]}"; do
                [ "${SECRETS_ENABLED[$i]}" = "true" ] && _labels+=("${SECRETS_LABELS[$i]}")
            done
        fi
        local label
        for label in "${_labels[@]}"; do
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
        echo -e "  ${DIM}[5]${NC} История IP: $(_tui_ip_history_line)"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) echo -e "  ${DIM}Ctrl+C для остановки...${NC}"; show_target_logs 30; ;;
            2) show_metrics 2>/dev/null || log_error "Метрики недоступны"; press_any_key ;;
            3) tui_metrics_live ;;
            4) show_connections; press_any_key ;;
            5) tui_ip_history_menu ;;
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
            echo ""
            echo -e "  ${DIM}Цель не запущена — статистика недоступна${NC}"
            echo ""
            _tui_traffic_actions "$(_tui_ip_history_line)" && continue
            return
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
        echo -e "  ${DIM}[5]${NC} История IP: $(_tui_ip_history_line)"
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
            5) tui_ip_history_menu ;;
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

