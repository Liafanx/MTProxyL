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

# ── Персистентная база трафика ────────────────────────────────
_TRAFFIC_DB="${INSTALL_DIR}/relay_stats/traffic_db"

# Загрузить накопленный трафик из базы
_load_traffic_db() {
    local _db="$_TRAFFIC_DB"
    [ -f "$_db" ] || return 0
    # Формат файла:
    # TOTAL|in_bytes|out_bytes
    # USER|label|in_bytes|out_bytes
    while IFS='|' read -r _type _a _b _c; do
        case "$_type" in
            TOTAL) _DB_TOTAL_IN="${_a:-0}"; _DB_TOTAL_OUT="${_b:-0}" ;;
            USER)  _DB_USER_IN["$_a"]="${_b:-0}"; _DB_USER_OUT["$_a"]="${_c:-0}" ;;
        esac
    done < "$_db"
}

# Сохранить трафик в базу
_save_traffic_db() {
    local _db="$_TRAFFIC_DB"
    local _stats_dir="${INSTALL_DIR}/relay_stats"
    mkdir -p "$_stats_dir" 2>/dev/null
    local _tmp="${_db}.tmp.$$"
    {
        echo "TOTAL|${_DB_TOTAL_IN:-0}|${_DB_TOTAL_OUT:-0}"
        local _u
        for _u in "${!_DB_USER_IN[@]}"; do
            echo "USER|${_u}|${_DB_USER_IN[$_u]:-0}|${_DB_USER_OUT[$_u]:-0}"
        done
    } > "$_tmp" 2>/dev/null
    mv "$_tmp" "$_db" 2>/dev/null
    chmod 600 "$_db" 2>/dev/null
}

# Снимок текущих метрик Prometheus → сохранение дельты в базу
flush_traffic_to_disk() {
    local _stats_dir="${INSTALL_DIR}/relay_stats"
    mkdir -p "$_stats_dir" 2>/dev/null

    local m
    m=$(curl -s --max-time 2 "http://127.0.0.1:${PROXY_METRICS_PORT:-9090}/metrics" 2>/dev/null) || return 0

    # Текущие значения из Prometheus (сессионные — сбрасываются при рестарте)
    local _cur_in _cur_out
    _cur_in=$(echo "$m" | awk '/^telemt_user_octets_from_client\{/{s+=$NF}END{printf "%.0f",s}')
    _cur_out=$(echo "$m" | awk '/^telemt_user_octets_to_client\{/{s+=$NF}END{printf "%.0f",s}')

    # Загружаем предыдущий снимок сессии (чтобы считать дельту)
    local _snap_file="${_stats_dir}/session_snapshot"
    local _prev_in=0 _prev_out=0
    if [ -f "$_snap_file" ]; then
        IFS='|' read -r _prev_in _prev_out < "$_snap_file" 2>/dev/null || true
    fi
    [[ "$_prev_in" =~ ^[0-9]+$ ]] || _prev_in=0
    [[ "$_prev_out" =~ ^[0-9]+$ ]] || _prev_out=0

    # Дельта (если текущие < предыдущих — был рестарт, дельта = текущие)
    local _delta_in _delta_out
    if [ "${_cur_in:-0}" -ge "$_prev_in" ] 2>/dev/null; then
        _delta_in=$(( ${_cur_in:-0} - _prev_in ))
    else
        _delta_in="${_cur_in:-0}"
    fi
    if [ "${_cur_out:-0}" -ge "$_prev_out" ] 2>/dev/null; then
        _delta_out=$(( ${_cur_out:-0} - _prev_out ))
    else
        _delta_out="${_cur_out:-0}"
    fi

    # Сохраняем текущий снимок сессии
    echo "${_cur_in:-0}|${_cur_out:-0}" > "$_snap_file" 2>/dev/null || true

    # Загружаем базу и прибавляем дельту
    declare -A _DB_USER_IN _DB_USER_OUT
    _DB_TOTAL_IN=0; _DB_TOTAL_OUT=0
    _load_traffic_db

    _DB_TOTAL_IN=$(( ${_DB_TOTAL_IN:-0} + _delta_in ))
    _DB_TOTAL_OUT=$(( ${_DB_TOTAL_OUT:-0} + _delta_out ))

    # Per-user дельты
    local _parsed_users
    _parsed_users=$(echo "$m" | awk '
        function lbl(s, k,    p, q) {
            p = index(s, k "=\""); if (!p) return ""
            s = substr(s, p + length(k) + 2)
            q = index(s, "\""); return q ? substr(s, 1, q-1) : ""
        }
        /^telemt_user_octets_from_client\{/ { u=lbl($0,"user"); if(u) rx[u]+=$NF }
        /^telemt_user_octets_to_client\{/   { u=lbl($0,"user"); if(u) tx[u]+=$NF }
        END { for (u in rx) printf "%s|%.0f|%.0f\n", u, rx[u]+0, tx[u]+0 }
    ')

    local _user_snap_file="${_stats_dir}/user_session_snapshot"
    declare -A _prev_user_in _prev_user_out
    if [ -f "$_user_snap_file" ]; then
        while IFS='|' read -r _pu _pi _po; do
            [ -z "$_pu" ] && continue
            _prev_user_in["$_pu"]="${_pi:-0}"
            _prev_user_out["$_pu"]="${_po:-0}"
        done < "$_user_snap_file"
    fi

    # Сохраняем снимок пользователей
    echo "$_parsed_users" > "$_user_snap_file" 2>/dev/null || true

    while IFS='|' read -r _pu _pi _po; do
        [ -z "$_pu" ] && continue
        local _pui="${_prev_user_in[$_pu]:-0}" _puo="${_prev_user_out[$_pu]:-0}"
        [[ "$_pui" =~ ^[0-9]+$ ]] || _pui=0
        [[ "$_puo" =~ ^[0-9]+$ ]] || _puo=0

        local _dui _duo
        if [ "${_pi:-0}" -ge "$_pui" ] 2>/dev/null; then
            _dui=$(( ${_pi:-0} - _pui ))
        else
            _dui="${_pi:-0}"
        fi
        if [ "${_po:-0}" -ge "$_puo" ] 2>/dev/null; then
            _duo=$(( ${_po:-0} - _puo ))
        else
            _duo="${_po:-0}"
        fi

        _DB_USER_IN["$_pu"]=$(( ${_DB_USER_IN[$_pu]:-0} + _dui ))
        _DB_USER_OUT["$_pu"]=$(( ${_DB_USER_OUT[$_pu]:-0} + _duo ))
    done <<< "$_parsed_users"

    _save_traffic_db
}

# Получить накопленный трафик (база + текущая сессия)
get_persistent_stats() {
    declare -A _DB_USER_IN _DB_USER_OUT
    _DB_TOTAL_IN=0; _DB_TOTAL_OUT=0
    _load_traffic_db

    local _cur_in=0 _cur_out=0 _cur_conns=0
    if is_proxy_running 2>/dev/null; then
        read -r _cur_in _cur_out _cur_conns <<< "$(get_proxy_stats)"
    fi

    local _snap_file="${INSTALL_DIR}/relay_stats/session_snapshot"
    local _snap_in=0 _snap_out=0
    if [ -f "$_snap_file" ]; then
        IFS='|' read -r _snap_in _snap_out < "$_snap_file" 2>/dev/null || true
    fi
    [[ "$_snap_in" =~ ^[0-9]+$ ]] || _snap_in=0
    [[ "$_snap_out" =~ ^[0-9]+$ ]] || _snap_out=0

    # unsaved delta = текущие метрики - последний снимок (если не было рестарта)
    local _unsaved_in=0 _unsaved_out=0
    if [ "${_cur_in:-0}" -ge "$_snap_in" ] 2>/dev/null; then
        _unsaved_in=$(( ${_cur_in:-0} - _snap_in ))
    else
        _unsaved_in="${_cur_in:-0}"
    fi
    if [ "${_cur_out:-0}" -ge "$_snap_out" ] 2>/dev/null; then
        _unsaved_out=$(( ${_cur_out:-0} - _snap_out ))
    else
        _unsaved_out="${_cur_out:-0}"
    fi

    local _total_in=$(( ${_DB_TOTAL_IN:-0} + _unsaved_in ))
    local _total_out=$(( ${_DB_TOTAL_OUT:-0} + _unsaved_out ))

    echo "${_total_in} ${_total_out} ${_cur_conns:-0}"
}

get_persistent_user_stats() {
    local user="$1"
    declare -A _DB_USER_IN _DB_USER_OUT
    _DB_TOTAL_IN=0; _DB_TOTAL_OUT=0
    _load_traffic_db

    local _cur_in=0 _cur_out=0 _cur_conns=0
    if is_proxy_running 2>/dev/null; then
        read -r _cur_in _cur_out _cur_conns <<< "$(get_user_stats "$user")"
    fi

    local _user_snap_file="${INSTALL_DIR}/relay_stats/user_session_snapshot"
    local _snap_in=0 _snap_out=0
    if [ -f "$_user_snap_file" ]; then
        while IFS='|' read -r _pu _pi _po; do
            [ "$_pu" = "$user" ] && { _snap_in="${_pi:-0}"; _snap_out="${_po:-0}"; break; }
        done < "$_user_snap_file"
    fi
    [[ "$_snap_in" =~ ^[0-9]+$ ]] || _snap_in=0
    [[ "$_snap_out" =~ ^[0-9]+$ ]] || _snap_out=0

    local _unsaved_in=0 _unsaved_out=0
    if [ "${_cur_in:-0}" -ge "$_snap_in" ] 2>/dev/null; then
        _unsaved_in=$(( ${_cur_in:-0} - _snap_in ))
    else
        _unsaved_in="${_cur_in:-0}"
    fi
    if [ "${_cur_out:-0}" -ge "$_snap_out" ] 2>/dev/null; then
        _unsaved_out=$(( ${_cur_out:-0} - _snap_out ))
    else
        _unsaved_out="${_cur_out:-0}"
    fi

    local _total_in=$(( ${_DB_USER_IN[$user]:-0} + _unsaved_in ))
    local _total_out=$(( ${_DB_USER_OUT[$user]:-0} + _unsaved_out ))

    echo "${_total_in} ${_total_out} ${_cur_conns:-0}"
}

show_traffic() {
    echo ""
    draw_header "ТРАФИК"

    # Сохраняем текущую дельту в базу
    flush_traffic_to_disk 2>/dev/null || true

    local t_in t_out conns
    read -r t_in t_out conns <<< "$(get_persistent_stats)"

    local s_in s_out s_conns
    read -r s_in s_out s_conns <<< "$(get_proxy_stats)"

    echo ""
    echo -e "  ${BOLD}Всего (с учётом перезагрузок):${NC}"
    echo -e "    ${SYM_DOWN} $(format_bytes "$t_in")  ${SYM_UP} $(format_bytes "$t_out")"
    echo ""
    echo -e "  ${BOLD}Текущая сессия:${NC}"
    echo -e "    ${SYM_DOWN} $(format_bytes "$s_in")  ${SYM_UP} $(format_bytes "$s_out")  ${BOLD}Соед.:${NC} ${conns}"
    echo ""

    local i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        local label="${SECRETS_LABELS[$i]}"
        local u_in u_out u_conns
        read -r u_in u_out u_conns <<< "$(get_persistent_user_stats "$label")"
        local su_in su_out su_conns
        read -r su_in su_out su_conns <<< "$(get_user_stats "$label")"
        echo -e "  ${GREEN}${SYM_OK}${NC} ${BOLD}${label}${NC}: ${SYM_DOWN} $(format_bytes "$u_in")  ${SYM_UP} $(format_bytes "$u_out")  соед: ${su_conns}"
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
        flush_traffic_to_disk 2>/dev/null || true
        read -r traffic_in traffic_out connections <<< "$(get_persistent_stats)"
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
        /^telemt_uptime_seconds[{ ]/                       { uptime = $NF }
        /^telemt_connections_total[{ ]/                     { c_tot  = $NF }
        /^telemt_connections_bad_total[{ ]/                 { c_bad  = $NF }
        /^telemt_connections_current[{ ]/                   { c_cur  = $NF }
        /^telemt_connections_me_current[{ ]/                { c_me   = $NF }
        /^telemt_connections_direct_current[{ ]/            { c_dir  = $NF }
        /^telemt_upstream_connect_attempt_total[{ ]/        { up_att = $NF }
        /^telemt_upstream_connect_success_total[{ ]/        { up_ok  = $NF }
        /^telemt_upstream_connect_fail_total[{ ]/           { up_fail= $NF }
        /^telemt_me_reconnect_attempts_total[{ ]/           { me_att = $NF }
        /^telemt_me_reconnect_success_total[{ ]/            { me_ok  = $NF }
        /^telemt_me_writers_active_current[{ ]/             { me_wa  = $NF }
        /^telemt_me_writers_warm_current[{ ]/               { me_ww  = $NF }
        /^telemt_me_endpoint_quarantine_total[{ ]/          { me_quar= $NF }
        /^telemt_me_crc_mismatch_total[{ ]/                 { me_crc = $NF }
        /^telemt_pool_drain_active[{ ]/                     { pool   = $NF }
        /^telemt_desync_total[{ ]/                          { desync = $NF }
        /^telemt_secure_padding_invalid_total[{ ]/          { padinv = $NF }
        /^telemt_upstream_connect_duration_success_total\{/ { b=lbl($0,"bucket"); if(b) ds[b]+=$NF }
        /^telemt_upstream_connect_duration_fail_total\{/    { b=lbl($0,"bucket"); if(b) df[b]+=$NF }
        /^telemt_user_connections_current\{/  { u=lbl($0,"user"); if(u) uc[u]+=$NF }
        /^telemt_user_connections_total\{/    { u=lbl($0,"user"); if(u) ut[u]+=$NF }
        /^telemt_user_octets_from_client\{/   { u=lbl($0,"user"); if(u) rx[u]+=$NF }
        /^telemt_user_octets_to_client\{/     { u=lbl($0,"user"); if(u) tx[u]+=$NF }
        /^telemt_user_unique_ips_current\{/   { u=lbl($0,"user"); if(u) ui[u]+=$NF }
        END {
            printf "S|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f\n",
                uptime+0,c_tot+0,c_bad+0,c_cur+0,c_me+0,c_dir+0,
                up_att+0,up_ok+0,up_fail+0,me_att+0,me_ok+0,
                me_wa+0,me_ww+0,me_quar+0,me_crc+0,pool+0,desync+0,padinv+0
            bkeys[1]="le_100ms";   bnames[1]="<=100ms"
            bkeys[2]="101_500ms";  bnames[2]="101-500ms"
            bkeys[3]="501_1000ms"; bnames[3]="501ms-1s"
            bkeys[4]="gt_1000ms";  bnames[4]=">1s"
            for (i=1;i<=4;i++) {
                b=bkeys[i]; ok=ds[b]+0; fail=df[b]+0; tot=ok+fail
                printf "D|%s|%s|%.0f|%.0f|%.1f\n", b, bnames[i], ok, fail, (tot>0 ? ok/tot*100 : -1)
            }
            for (u in uc) users[u]=1
            for (u in rx) users[u]=1
            for (u in tx) users[u]=1
            for (u in ui) users[u]=1
            for (u in users)
                printf "U|%s|%.0f|%.0f|%.0f|%.0f|%.0f\n", u, uc[u]+0, ut[u]+0, rx[u]+0, tx[u]+0, ui[u]+0
        }
    ')

    local uptime c_tot c_bad c_cur c_me c_dir up_att up_ok up_fail me_att me_ok me_wa me_ww me_quar me_crc pool desync padinv
    IFS='|' read -r _ uptime c_tot c_bad c_cur c_me c_dir up_att up_ok up_fail \
                       me_att me_ok me_wa me_ww me_quar me_crc pool desync padinv \
        <<< "$(echo "$parsed" | grep '^S|')"

    local c_good=$(( ${c_tot:-0} - ${c_bad:-0} ))
    local up_rate=0 me_rate=0
    [ "${up_att:-0}" -gt 0 ] && up_rate=$(awk -v a="$up_att" -v b="$up_ok" 'BEGIN{printf "%.1f", b/a*100}')
    [ "${me_att:-0}" -gt 0 ] && me_rate=$(awk -v a="$me_att" -v b="$me_ok" 'BEGIN{printf "%.1f", b/a*100}')

    local up_color up_label
    if   [ "${up_att:-0}" -eq 0 ]; then up_color="$DIM"; up_label="—"
    elif awk -v r="$up_rate" 'BEGIN{exit !(r+0 >= 95)}'; then up_color="$BRIGHT_GREEN"; up_label="OK ${up_rate}%"
    elif awk -v r="$up_rate" 'BEGIN{exit !(r+0 >= 80)}'; then up_color="$YELLOW"; up_label="WARN ${up_rate}%"
    else up_color="$BRIGHT_RED"; up_label="CRIT ${up_rate}%"; fi

    local me_rate_disp; [ "${me_att:-0}" -gt 0 ] && me_rate_disp="${me_rate}%" || me_rate_disp="—"

    local W=72

    echo ""
    echo -e "  ${BRIGHT_CYAN}${BOX_TL}$(_repeat "$BOX_H" $W)${BOX_TR}${NC}"
    echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}  ${BOLD}МЕТРИКИ ДВИЖКА${NC}$(printf '%*s' $((W - 16)))${BRIGHT_CYAN}${BOX_V}${NC}"
    echo -e "  ${BRIGHT_CYAN}${BOX_LT}$(_repeat "$BOX_H" $W)${BOX_RT}${NC}"

    # Шапка
    echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}  ${DIM}Аптайм:${NC} $(format_duration "${uptime:-0}")   ${DIM}Upstream:${NC} ${up_color}${up_label}${NC}   ${DIM}Активных:${NC} ${c_cur:-0}   ${DIM}Writers:${NC} ${me_wa:-0}/${me_ww:-0}$(printf '%*s' 1)${BRIGHT_CYAN}${BOX_V}${NC}"
    echo -e "  ${BRIGHT_CYAN}${BOX_LT}$(_repeat "$BOX_H" $W)${BOX_RT}${NC}"

    # Соединения
    echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}  ${BOLD}Соединения${NC}$(printf '%*s' $((W - 12)))${BRIGHT_CYAN}${BOX_V}${NC}"
    echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}    ${DIM}Всего:${NC} ${c_tot:-0}   ${DIM}Авториз.:${NC} ${BRIGHT_GREEN}${c_good}${NC}   ${DIM}Отклонено:${NC} ${BRIGHT_RED}${c_bad:-0}${NC}$(printf '%*s' 1)${BRIGHT_CYAN}${BOX_V}${NC}"
    echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}    ${DIM}Активных:${NC} ${c_cur:-0}  (ME: ${c_me:-0}  Direct: ${c_dir:-0})$(printf '%*s' 1)${BRIGHT_CYAN}${BOX_V}${NC}"
    echo -e "  ${BRIGHT_CYAN}${BOX_LT}$(_repeat "$BOX_H" $W)${BOX_RT}${NC}"

    # Upstream
    echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}  ${BOLD}Upstream${NC}$(printf '%*s' $((W - 10)))${BRIGHT_CYAN}${BOX_V}${NC}"
    echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}    ${DIM}Попыток:${NC} ${up_att:-0}   ${DIM}Успех:${NC} ${BRIGHT_GREEN}${up_ok:-0}${NC}   ${DIM}Ошибок:${NC} ${BRIGHT_RED}${up_fail:-0}${NC}$(printf '%*s' 1)${BRIGHT_CYAN}${BOX_V}${NC}"

    while IFS='|' read -r _ bk bn ok fail pct; do
        local ppct
        ppct=$(awk -v p="$pct" 'BEGIN{if(p+0<0) print "—"; else printf "%.0f%%", p}')
        echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}      ${DIM}${bn}${NC}  ${ok} ок  ${fail} ош  (${ppct})$(printf '%*s' 1)${BRIGHT_CYAN}${BOX_V}${NC}"
    done < <(echo "$parsed" | grep '^D|')
    echo -e "  ${BRIGHT_CYAN}${BOX_LT}$(_repeat "$BOX_H" $W)${BOX_RT}${NC}"

    # Пользователи
    local user_lines
    user_lines=$(echo "$parsed" | grep '^U|' | sort -t'|' -k3 -rn)
    if [ -n "$user_lines" ]; then
        echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}  ${BOLD}Пользователи${NC}$(printf '%*s' $((W - 14)))${BRIGHT_CYAN}${BOX_V}${NC}"
        while IFS='|' read -r _ uname ucur utot urx utx uips; do
            echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}    ${GREEN}${SYM_OK}${NC} ${BOLD}${uname}${NC}  акт: ${ucur}  всего: ${utot}  ${SYM_DOWN} $(format_bytes "$urx")  ${SYM_UP} $(format_bytes "$utx")  IP: ${uips}$(printf '%*s' 1)${BRIGHT_CYAN}${BOX_V}${NC}"
        done <<< "$user_lines"
        echo -e "  ${BRIGHT_CYAN}${BOX_LT}$(_repeat "$BOX_H" $W)${BOX_RT}${NC}"
    fi

    # ME Health
    echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}  ${BOLD}ME Health${NC}$(printf '%*s' $((W - 11)))${BRIGHT_CYAN}${BOX_V}${NC}"
    echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}    ${DIM}Переподкл.:${NC} ${me_ok:-0}/${me_att:-0} (${me_rate_disp})   ${DIM}Writers:${NC} ${me_wa:-0} акт. / ${me_ww:-0} warm$(printf '%*s' 1)${BRIGHT_CYAN}${BOX_V}${NC}"
    [ "${me_quar:-0}" -gt 0 ] && echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}    ${DIM}Карантин endpoint:${NC} ${YELLOW}${me_quar}${NC}$(printf '%*s' 1)${BRIGHT_CYAN}${BOX_V}${NC}"
    [ "${me_crc:-0}"  -gt 0 ] && echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}    ${DIM}CRC несовпадений:${NC} ${YELLOW}${me_crc}${NC}$(printf '%*s' 1)${BRIGHT_CYAN}${BOX_V}${NC}"
    [ "${pool:-0}"    -gt 0 ] && echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}    ${DIM}Writers draining:${NC} ${pool}$(printf '%*s' 1)${BRIGHT_CYAN}${BOX_V}${NC}"

    # Безопасность (если есть проблемы)
    if [ "${desync:-0}" -gt 0 ] || [ "${padinv:-0}" -gt 0 ]; then
        echo -e "  ${BRIGHT_CYAN}${BOX_LT}$(_repeat "$BOX_H" $W)${BOX_RT}${NC}"
        echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}  ${BOLD}Безопасность${NC}$(printf '%*s' $((W - 14)))${BRIGHT_CYAN}${BOX_V}${NC}"
        [ "${desync:-0}"  -gt 0 ] && echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}    ${DIM}Desync событий:${NC}   ${YELLOW}${desync}${NC}$(printf '%*s' 1)${BRIGHT_CYAN}${BOX_V}${NC}"
        [ "${padinv:-0}"  -gt 0 ] && echo -e "  ${BRIGHT_CYAN}${BOX_V}${NC}    ${DIM}Невалидный padding:${NC} ${YELLOW}${padinv}${NC}$(printf '%*s' 1)${BRIGHT_CYAN}${BOX_V}${NC}"
    fi

    echo -e "  ${BRIGHT_CYAN}${BOX_BL}$(_repeat "$BOX_H" $W)${BOX_BR}${NC}"
    echo ""
}
