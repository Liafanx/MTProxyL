#!/bin/bash
# MTProxyL — трафик, метрики, статистика

_METRICS_CACHE=""
_METRICS_CACHE_AGE=0

_fetch_metrics() {
    local now; now=$(date +%s)
    if [ -n "$_METRICS_CACHE" ] && [ $((now - _METRICS_CACHE_AGE)) -lt 2 ]; then
        echo "$_METRICS_CACHE"; return 0
    fi
    _METRICS_CACHE=$(curl -s --max-time 2 "http://127.0.0.1:${PROXY_METRICS_PORT:-9090}/metrics" 2>/dev/null)
    _METRICS_CACHE_AGE=$now
    [ -n "$_METRICS_CACHE" ] && echo "$_METRICS_CACHE" && return 0
    return 1
}

get_proxy_stats() {
    is_proxy_running || { echo "0 0 0"; return; }
    local m
    if m=$(_fetch_metrics); then
        local bi bo conns
        bi=$(echo "$m" | awk '/^telemt_user_octets_from_client\{/{s+=$NF}END{printf "%.0f",s}')
        bo=$(echo "$m" | awk '/^telemt_user_octets_to_client\{/{s+=$NF}END{printf "%.0f",s}')
        conns=$(echo "$m" | awk '/^telemt_user_connections_current\{/{s+=$NF}END{printf "%.0f",s}')
        echo "${bi:-0} ${bo:-0} ${conns:-0}"
    else
        echo "0 0 0"
    fi
}

get_user_stats() {
    local user="$1"
    local m
    if m=$(_fetch_metrics); then
        local i o c
        i=$(echo "$m" | awk -v u="$user" '$0 ~ "^telemt_user_octets_from_client\\{.*user=\"" u "\"" {print $NF}')
        o=$(echo "$m" | awk -v u="$user" '$0 ~ "^telemt_user_octets_to_client\\{.*user=\"" u "\"" {print $NF}')
        c=$(echo "$m" | awk -v u="$user" '$0 ~ "^telemt_user_connections_current\\{.*user=\"" u "\"" {print $NF}')
        echo "${i:-0} ${o:-0} ${c:-0}"
    else
        echo "0 0 0"
    fi
}

flush_traffic_to_disk() {
    local _stats_dir="${INSTALL_DIR}/relay_stats"
    mkdir -p "$_stats_dir" 2>/dev/null
    # Упрощённая версия — сохраняем текущие метрики
    local m
    m=$(curl -s --max-time 2 "http://127.0.0.1:${PROXY_METRICS_PORT:-9090}/metrics" 2>/dev/null) || return 0

    local gi go
    gi=$(echo "$m" | awk '/^telemt_user_octets_from_client\{/{s+=$NF}END{printf "%.0f",s}')
    go=$(echo "$m" | awk '/^telemt_user_octets_to_client\{/{s+=$NF}END{printf "%.0f",s}')
    echo "${gi:-0}|${go:-0}" > "${_stats_dir}/cumulative_traffic" 2>/dev/null || true
}

show_traffic() {
    echo ""
    draw_header "ТРАФИК"
    local t_in t_out conns
    read -r t_in t_out conns <<< "$(get_proxy_stats)"
    echo ""
    echo -e "  ${BOLD}Всего:${NC} ${SYM_DOWN} $(format_bytes "$t_in")  ${SYM_UP} $(format_bytes "$t_out")  ${BOLD}Соединений:${NC} ${conns}"
    echo ""

    local i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        local label="${SECRETS_LABELS[$i]}"
        local u_in u_out u_conns
        read -r u_in u_out u_conns <<< "$(get_user_stats "$label")"
        echo -e "  ${GREEN}${SYM_OK}${NC} ${BOLD}${label}${NC}: ${SYM_DOWN} $(format_bytes "$u_in")  ${SYM_UP} $(format_bytes "$u_out")  соед: ${u_conns}"
    done
    echo ""
}

show_connections() {
    local m
    if ! m=$(_fetch_metrics 2>/dev/null); then
        log_error "Эндпоинт метрик недоступен — прокси запущен?"
        return 1
    fi

    local parsed
    parsed=$(echo "$m" | awk '
        function lbl(s, k,    p, q) {
            p = index(s, k "=\""); if (!p) return ""
            s = substr(s, p + length(k) + 2)
            q = index(s, "\""); return q ? substr(s, 1, q-1) : ""
        }
        /^telemt_user_connections_current\{/  { u=lbl($0,"user"); if(u) uc[u]+=$NF }
        /^telemt_user_octets_from_client\{/   { u=lbl($0,"user"); if(u) rx[u]+=$NF }
        /^telemt_user_octets_to_client\{/     { u=lbl($0,"user"); if(u) tx[u]+=$NF }
        /^telemt_connections_current /         { total=$NF }
        END {
            printf "T|%.0f\n", total+0
            for (u in uc)
                printf "U|%s|%.0f|%.0f|%.0f\n", u, uc[u]+0, rx[u]+0, tx[u]+0
        }
    ')

    local total=0
    IFS='|' read -r _ total <<< "$(echo "$parsed" | grep '^T|')"

    draw_header "АКТИВНЫЕ СОЕДИНЕНИЯ"
    echo ""
    echo -e "  ${BOLD}Всего активных:${NC} ${total:-0}"
    echo ""

    local user_lines
    user_lines=$(echo "$parsed" | grep '^U|' | sort -t'|' -k3 -rn)
    if [ -n "$user_lines" ]; then
        printf "  ${BOLD}%-16s %8s %12s %12s${NC}\n" "ПОЛЬЗОВАТЕЛЬ" "СОЕД." "СКАЧАНО" "ОТПРАВЛЕНО"
        echo -e "  ${DIM}$(_repeat '─' 54)${NC}"
        while IFS='|' read -r _ uname ucur urx utx; do
            printf "  %-16s %8s %12s %12s\n" "$uname" "$ucur" "$(format_bytes "$urx")" "$(format_bytes "$utx")"
        done <<< "$user_lines"
    else
        echo -e "  ${DIM}Нет подключённых пользователей${NC}"
    fi
    echo ""
}

show_status() {
    echo ""
    local status_str uptime_str traffic_in traffic_out connections
    if is_proxy_running; then
        status_str=$(draw_status running)
        local up_secs; up_secs=$(get_proxy_uptime)
        uptime_str=$(format_duration "$up_secs")
        read -r traffic_in traffic_out connections <<< "$(get_proxy_stats)"
    else
        status_str=$(draw_status stopped)
        uptime_str="—"; traffic_in=0; traffic_out=0; connections=0
    fi

    local active=0 disabled=0 i
    for i in "${!SECRETS_ENABLED[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] && active=$((active+1)) || disabled=$((disabled+1))
    done

    echo -e "  ${BOLD}Движок:${NC}      telemt v$(get_telemt_version)  ${BOLD}Статус:${NC} ${status_str}"
    echo -e "  ${BOLD}Порт:${NC}        ${PROXY_PORT}            ${BOLD}Время работы:${NC} ${uptime_str}"
    echo -e "  ${BOLD}Домен:${NC}       ${PROXY_DOMAIN}"
    echo -e "  ${BOLD}Трафик:${NC}      ${SYM_DOWN} $(format_bytes "$traffic_in")  ${SYM_UP} $(format_bytes "$traffic_out")"
    echo -e "  ${BOLD}Соединения:${NC}  ${connections}"
    echo -e "  ${BOLD}Секреты:${NC}     ${active} активных / ${disabled} выключенных"
    echo ""
}

show_status_json() {
    local status="stopped" uptime_secs=0 traffic_in=0 traffic_out=0 connections=0
    if is_proxy_running; then
        status="running"
        uptime_secs=$(get_proxy_uptime 2>/dev/null) || uptime_secs=0
        read -r traffic_in traffic_out connections <<< "$(get_proxy_stats)"
    fi
    printf '{"version":"%s","status":"%s","port":%d,"domain":"%s","uptime":%d,"connections":%d,"traffic_in":%d,"traffic_out":%d}\n' \
        "$VERSION" "$status" "$PROXY_PORT" "$PROXY_DOMAIN" "$uptime_secs" "${connections:-0}" "${traffic_in:-0}" "${traffic_out:-0}"
}

show_config() {
    local config="${CONFIG_DIR}/config.toml"
    if [ -f "$config" ]; then
        echo ""; draw_header "КОНФИГ ДВИЖКА"; echo ""
        sed 's/^/  /' "$config"; echo ""
    else
        log_error "Файл конфига не найден — прокси установлен?"
    fi
}

handle_metrics_command() {
    local subcmd="${1:-}"
    if [ "$subcmd" = "live" ]; then
        local interval="${2:-5}"
        [[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -ge 1 ] || interval=5
        while true; do
            clear_screen; show_traffic
            echo -e "  ${DIM}[обновление каждые ${interval}с, Ctrl+C для остановки]${NC}"
            sleep "$interval"
        done
    else
        show_traffic
    fi
}
