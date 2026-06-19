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

# ── Диагностика ──────────────────────────────────────────────
health_check() {
    echo ""; draw_header "ДИАГНОСТИКА"; echo ""
    command -v docker &>/dev/null && echo -e "  ${GREEN}${SYM_CHECK}${NC} Docker установлен" || echo -e "  ${RED}${SYM_CROSS}${NC} Docker не установлен"
    is_proxy_running && echo -e "  ${GREEN}${SYM_CHECK}${NC} Контейнер запущен" || echo -e "  ${RED}${SYM_CROSS}${NC} Контейнер не запущен"
    curl -s --max-time 2 "http://127.0.0.1:${PROXY_METRICS_PORT}/metrics" &>/dev/null && echo -e "  ${GREEN}${SYM_CHECK}${NC} Метрики доступны" || echo -e "  ${RED}${SYM_CROSS}${NC} Метрики недоступны"
    [ -f "${CONFIG_DIR}/config.toml" ] && echo -e "  ${GREEN}${SYM_CHECK}${NC} Конфиг существует" || echo -e "  ${RED}${SYM_CROSS}${NC} Конфиг не найден"
    local active=0 i; for i in "${!SECRETS_ENABLED[@]}"; do [ "${SECRETS_ENABLED[$i]}" = "true" ] && active=$((active+1)); done
    [ $active -gt 0 ] && echo -e "  ${GREEN}${SYM_CHECK}${NC} ${active} активных секретов" || echo -e "  ${RED}${SYM_CROSS}${NC} Нет активных секретов"
    echo ""
}

show_server_info() {
    echo ""; draw_header "ИНФОРМАЦИЯ О СЕРВЕРЕ"; echo ""
    local os_name="?" kernel arch
    [ -f /etc/os-release ] && os_name=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$ID}")
    kernel=$(uname -r 2>/dev/null || echo "?"); arch=$(uname -m 2>/dev/null || echo "?")
    echo -e "  ${BOLD}Система${NC}"
    echo -e "    ОС:           ${os_name}"
    echo -e "    Ядро:         ${kernel}"
    echo -e "    Архитектура:  ${arch}"
    echo ""
    echo -e "  ${BOLD}Прокси${NC}"
    echo -e "    Скрипт:       v${VERSION}"
    echo -e "    Движок:       telemt v$(get_telemt_version)"
    echo -e "    Домен:        ${PROXY_DOMAIN}"
    echo -e "    Порт:         ${PROXY_PORT}"
    echo -e "    Маскировка:   ${MASKING_ENABLED}"
    echo ""
}

show_metrics() {
    local m
    m=$(_fetch_metrics 2>/dev/null) || { log_error "Эндпоинт метрик недоступен"; return 1; }

    local parsed
    parsed=$(echo "$m" | awk '
        function lbl(s, k,    p, q) {
            p = index(s, k "=\""); if (!p) return ""
            s = substr(s, p + length(k) + 2)
            q = index(s, "\""); return q ? substr(s, 1, q-1) : ""
        }
        /^telemt_uptime_seconds /                           { uptime = $NF }
        /^telemt_connections_total /                        { c_tot  = $NF }
        /^telemt_connections_bad_total /                    { c_bad  = $NF }
        /^telemt_connections_current /                      { c_cur  = $NF }
        /^telemt_connections_me_current /                   { c_me   = $NF }
        /^telemt_connections_direct_current /               { c_dir  = $NF }
        /^telemt_upstream_connect_attempt_total /           { up_att = $NF }
        /^telemt_upstream_connect_success_total /           { up_ok  = $NF }
        /^telemt_upstream_connect_fail_total /              { up_fail= $NF }
        /^telemt_me_reconnect_attempts_total /              { me_att = $NF }
        /^telemt_me_reconnect_success_total /               { me_ok  = $NF }
        /^telemt_me_writers_active_current /                { me_wa  = $NF }
        /^telemt_me_writers_warm_current /                  { me_ww  = $NF }
        /^telemt_upstream_connect_duration_success_total\{/ { b=lbl($0,"bucket"); if(b) ds[b]+=$NF }
        /^telemt_upstream_connect_duration_fail_total\{/    { b=lbl($0,"bucket"); if(b) df[b]+=$NF }
        /^telemt_user_connections_current\{/ { u=lbl($0,"user"); if(u) uc[u]+=$NF }
        /^telemt_user_connections_total\{/   { u=lbl($0,"user"); if(u) ut[u]+=$NF }
        /^telemt_user_octets_from_client\{/  { u=lbl($0,"user"); if(u) rx[u]+=$NF }
        /^telemt_user_octets_to_client\{/    { u=lbl($0,"user"); if(u) tx[u]+=$NF }
        /^telemt_user_unique_ips_current\{/  { u=lbl($0,"user"); if(u) ui[u]+=$NF }
        END {
            printf "S|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f\n",
                uptime+0,c_tot+0,c_bad+0,c_cur+0,c_me+0,c_dir+0,
                up_att+0,up_ok+0,up_fail+0,me_att+0,me_ok+0,me_wa+0,me_ww+0
            bkeys[1]="le_100ms";   bnames[1]="<=100мс"
            bkeys[2]="101_500ms";  bnames[2]="101-500мс"
            bkeys[3]="501_1000ms"; bnames[3]="501мс-1с"
            bkeys[4]="gt_1000ms";  bnames[4]=">1с"
            for (i=1;i<=4;i++) {
                b=bkeys[i]; ok=ds[b]+0; fail=df[b]+0; tot=ok+fail
                printf "D|%s|%s|%.0f|%.0f|%.1f\n", b, bnames[i], ok, fail, (tot>0 ? ok/tot*100 : -1)
            }
            for (u in uc) users[u]=1
            for (u in rx) users[u]=1
            for (u in ui) users[u]=1
            for (u in users)
                printf "U|%s|%.0f|%.0f|%.0f|%.0f|%.0f\n", u, uc[u]+0, ut[u]+0, rx[u]+0, tx[u]+0, ui[u]+0
        }
    ')

    local uptime c_tot c_bad c_cur c_me c_dir up_att up_ok up_fail me_att me_ok me_wa me_ww
    IFS='|' read -r _ uptime c_tot c_bad c_cur c_me c_dir up_att up_ok up_fail me_att me_ok me_wa me_ww \
        <<< "$(echo "$parsed" | grep '^S|')"

    local c_good=$(( ${c_tot:-0} - ${c_bad:-0} ))
    local up_rate=0 me_rate=0
    [ "${up_att:-0}" -gt 0 ] && up_rate=$(awk -v a="$up_att" -v b="$up_ok" 'BEGIN{printf "%.1f", b/a*100}')
    [ "${me_att:-0}" -gt 0 ] && me_rate=$(awk -v a="$me_att" -v b="$me_ok" 'BEGIN{printf "%.1f", b/a*100}')

    local up_status
    if [ "${up_att:-0}" -eq 0 ]; then up_status="${DIM}—${NC}"
    elif awk -v r="$up_rate" 'BEGIN{exit !(r+0 >= 95)}'; then up_status="${BRIGHT_GREEN}OK${NC} ${up_rate}%"
    elif awk -v r="$up_rate" 'BEGIN{exit !(r+0 >= 80)}'; then up_status="${YELLOW}WARN${NC} ${up_rate}%"
    else up_status="${BRIGHT_RED}CRIT${NC} ${up_rate}%"; fi

    draw_header "МЕТРИКИ"
    echo -e "  ${DIM}аптайм:${NC} $(format_duration "${uptime:-0}")   ${DIM}upstream:${NC} ${up_status}   ${DIM}активных:${NC} ${c_cur:-0}   ${DIM}writers:${NC} ${me_wa:-0}/${me_ww:-0}"
    echo ""

    echo -e "  ${BOLD}Соединения${NC}"
    echo -e "  ${DIM}всего:${NC} ${c_tot:-0}   ${DIM}авториз.:${NC} ${BRIGHT_GREEN}${c_good}${NC}   ${DIM}отклонено:${NC} ${BRIGHT_RED}${c_bad:-0}${NC}"
    echo -e "  ${DIM}активных:${NC} ${c_cur:-0}  (ME: ${c_me:-0}  direct: ${c_dir:-0})"
    echo ""

    echo -e "  ${BOLD}Upstream${NC}"
    echo -e "  ${DIM}попыток:${NC} ${up_att:-0}   ${DIM}успех:${NC} ${BRIGHT_GREEN}${up_ok:-0}${NC}   ${DIM}ошибок:${NC} ${BRIGHT_RED}${up_fail:-0}${NC}   ${DIM}rate:${NC} ${up_status}"
    while IFS='|' read -r _ bk bn ok fail pct; do
        local ppct
        ppct=$(awk -v p="$pct" 'BEGIN{if(p+0<0) print "—"; else printf "%.0f%%", p}')
        printf "    %-12s  %6s ок  %6s ош  (%s)\n" "$bn" "$ok" "$fail" "$ppct"
    done < <(echo "$parsed" | grep '^D|')
    echo ""

    local user_lines
    user_lines=$(echo "$parsed" | grep '^U|' | sort -t'|' -k3 -rn)
    if [ -n "$user_lines" ]; then
        echo -e "  ${BOLD}Пользователи${NC}"
        while IFS='|' read -r _ uname ucur utot urx utx uips; do
            echo -e "  ${GREEN}${SYM_OK}${NC} ${BOLD}${uname}${NC}  активных: ${ucur}  всего: ${utot}  ${SYM_DOWN} $(format_bytes "$urx")  ${SYM_UP} $(format_bytes "$utx")  IP: ${uips}"
        done <<< "$user_lines"
        echo ""
    fi

    local me_rate_disp; [ "${me_att:-0}" -gt 0 ] && me_rate_disp="${me_rate}%" || me_rate_disp="—"
    echo -e "  ${BOLD}ME Health${NC}"
    echo -e "  ${DIM}переподкл.:${NC} ${me_ok:-0}/${me_att:-0} (${me_rate_disp})   ${DIM}writers:${NC} ${me_wa:-0} активных / ${me_ww:-0} warm"
    echo ""
}
