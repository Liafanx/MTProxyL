#!/bin/bash
# MTProxyL — трафик, метрики, статистика

_METRICS_CACHE=""
_METRICS_CACHE_AGE=0

_fetch_metrics() {
    local now; now=$(date +%s)
    if [ -n "$_METRICS_CACHE" ] && [ $((now - _METRICS_CACHE_AGE)) -lt 2 ]; then
        echo "$_METRICS_CACHE"; return 0
    fi
    local _mport="${PROXY_METRICS_PORT:-9090}"
    [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] && _mport=$(_get_telemt_metrics_port)
    _METRICS_CACHE=$(curl -s --max-time 2 "http://127.0.0.1:${_mport}/metrics" 2>/dev/null)
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
# ── История IP пользователей ────────────────────────────────────
# API движка отдаёт только «сейчас» и «недавно» и пустеет при рестарте,
# поэтому здесь накопительная база с отметками появления.
# Сколько адресов держать на пользователя. Значение из настроек, 200 по
# умолчанию: на нём история занимает единицы мегабайт даже на сотне секретов.
_user_ip_history_cap() {
    local _v="${IP_HISTORY_LIMIT:-200}"
    [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 1 ] || _v=200
    echo "$_v"
}

# Мержит "user|ip" пары из stdin в файл истории. Одна функция на оба режима:
# вызывающий передаёт свой путь к базе.
_flush_user_ip_history() {
    local _db_file="$1"
    [ -n "$_db_file" ] || return 0
    mkdir -p "${INSTALL_DIR}/relay_stats" 2>/dev/null
    [ -f "$_db_file" ] || : > "$_db_file"

    local _now; _now=$(date +%s)
    local _tmp="${_db_file}.tmp.$$"

    # Слияние в awk, вытеснение сортировкой: на bash вложенные циклы давали
    # ~40 секунд CPU на флаш. Строки: пользователь|last|ip|first.
    # База читается getline, а не вторым файлом: у пустой базы NR == FNR
    # совпало бы и на stdin, и весь ввод ушёл бы в разбор базы.
    awk -v now="$_now" -v db="$_db_file" '
        BEGIN {
            while ((getline line < db) > 0) {
                if (substr(line, 1, 5) != "USER|") continue
                n = split(line, f, "|")
                if (n < 3 || f[2] == "" || f[3] == "") continue
                k = f[2] SUBSEP f[3]
                if (!(k in first)) { nk++; ku[nk] = f[2]; ki[nk] = f[3]; kk[nk] = k }
                first[k] = (n > 3 && f[4] != "") ? f[4] : 0
                last[k]  = (n > 4 && f[5] != "") ? f[5] : 0
            }
            close(db)
        }
        {
            n = split($0, f, "|")
            if (n < 2 || f[1] == "" || f[2] == "") next
            k = f[1] SUBSEP f[2]
            if (!(k in first)) { nk++; ku[nk] = f[1]; ki[nk] = f[2]; kk[nk] = k; first[k] = now }
            last[k] = now
        }
        END {
            for (i = 1; i <= nk; i++) {
                k = kk[i]
                printf "%s|%s|%s|%s\n", ku[i], last[k], ki[i], first[k]
            }
        }
    ' 2>/dev/null \
        | sort -t'|' -k1,1 -k2,2nr 2>/dev/null \
        | awk -F'|' -v cap="$(_user_ip_history_cap)" '
            $1 != prev { prev = $1; n = 0 }
            { n++; if (n <= cap) printf "USER|%s|%s|%s|%s\n", $1, $3, $4, $2 }
        ' > "$_tmp" 2>/dev/null

    mv "$_tmp" "$_db_file" 2>/dev/null
    chmod 600 "$_db_file" 2>/dev/null
}

# ── Снимки истории по расписанию ────────────────────────────────
# Списки адресов у движка живут недолго, а пополнялась история только когда
# кто-то открывал список пользователей — то есть при открытой панели. Между
# заходами адреса терялись. Снимок делает то же самое, но без сборки JSON.
IP_HISTORY_SERVICE="mtproxyl-ip-history.service"
IP_HISTORY_TIMER="mtproxyl-ip-history.timer"

_ip_history_interval_minutes() {
    local _v="${IP_HISTORY_INTERVAL:-5}"
    [[ "$_v" =~ ^[0-9]+$ ]] || _v=5
    echo "$_v"
}

ip_history_snapshot() {
    local _cfg _db
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        _cfg="${DETECTED_CONFIG_PATH}"
        _db="${_TARGET_USER_IPS_DB}"
    else
        _cfg="$(_engine_config_path 2>/dev/null)"
        _db="${_USER_IPS_DB}"
    fi
    [ -n "$_db" ] || return 1

    local _json
    _json=$(_get_telemt_users_json "$_cfg" 2>/dev/null) || return 1
    _target_user_ip_lists "$_json" | _flush_user_ip_history "$_db"
}

ip_history_timer_active() {
    systemctl is-enabled "$IP_HISTORY_TIMER" &>/dev/null
}

# Таймер появился в 1.4.7, и у обновившихся его нет: установщик своё уже
# отработал, а больше поставить его некому. Проверка — один stat, установка
# случается один раз. Выключение живёт в настройке, иначе таймер возвращался бы
# следующей же командой.
_ensure_ip_history_timer() {
    [ "$(id -u)" -eq 0 ] || return 0
    [ -f "$SETTINGS_FILE" ] || return 0
    [ "$(_ip_history_interval_minutes)" -gt 0 ] || return 0
    [ -f "/etc/systemd/system/${IP_HISTORY_TIMER}" ] && return 0
    command -v systemctl &>/dev/null || return 0
    install_ip_history_timer >/dev/null 2>&1 || true
}

install_ip_history_timer() {
    command -v systemctl &>/dev/null || return 0
    local _min; _min=$(_ip_history_interval_minutes)
    if [ "$_min" -le 0 ]; then
        remove_ip_history_timer
        return 0
    fi

    cat > "/etc/systemd/system/${IP_HISTORY_SERVICE}" << EOF
[Unit]
Description=MTProxyL: снимок IP-адресов пользователей в историю
After=network-online.target

[Service]
Type=oneshot
# «-»: остановленный движок — обычное дело, и падающий каждые несколько минут
# юнит в журнале выглядел бы поломкой.
ExecStart=-${INSTALL_DIR}/mtproxyl.sh ip-history flush
EOF

    cat > "/etc/systemd/system/${IP_HISTORY_TIMER}" << EOF
[Unit]
Description=MTProxyL: снимки истории IP каждые ${_min} мин

[Timer]
OnBootSec=2min
OnUnitActiveSec=${_min}min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload 2>/dev/null
    systemctl enable --now "$IP_HISTORY_TIMER" &>/dev/null
}

remove_ip_history_timer() {
    command -v systemctl &>/dev/null || return 0
    systemctl disable --now "$IP_HISTORY_TIMER" &>/dev/null
    rm -f "/etc/systemd/system/${IP_HISTORY_TIMER}" "/etc/systemd/system/${IP_HISTORY_SERVICE}"
    systemctl daemon-reload 2>/dev/null
}

# Строки истории конкретного пользователя как "ip|first_seen|last_seen".
_user_ip_history() {
    local _label="$1" _db_file="$2"
    [ -f "$_db_file" ] || return 0
    local _t _u _ip _fs _ls
    while IFS='|' read -r _t _u _ip _fs _ls; do
        [ "$_t" = "USER" ] && [ "$_u" = "$_label" ] && printf '%s|%s|%s\n' "$_ip" "${_fs:-0}" "${_ls:-0}"
    done < "$_db_file"
}

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

# Reanimator: собственных счётчиков у нас нет — данные берём из API цели
# (/v1/users), как это делает экран «Логи и трафик».
show_target_traffic() {
    echo ""
    draw_header "ТРАФИК (ЦЕЛЬ)"
    echo ""

    flush_target_traffic_to_disk 2>/dev/null || true

    local _cur; _cur=$(_target_current_table 2>/dev/null) || _cur=""
    local _src; _src=$(_target_table_source "$_cur")
    if [ -z "$_cur" ] || [ -z "$_src" ]; then
        log_warn "Статистика недоступна: $(_telemt_api_unavailable_reason)"
        log_info "Включите [server.api] enabled = true в конфиге цели и перезапустите её"
        echo ""
        return 1
    fi

    declare -A _TDB_IN=() _TDB_OUT=() _TDB_TOTAL=()
    local _TDB_SRC=""
    _load_target_db

    local _ti=0 _to=0 _tt=0
    declare -A _SEEN=()
    local _u _i _o _t
    while IFS='|' read -r _u _i _o _t; do
        [ -z "$_u" ] && continue
        # Первая строка вывода — маркер источника, а не пользователь.
        [ "$_u" = "SOURCE" ] && continue
        _SEEN["$_u"]=1
        _ti=$(( _ti + ${_TDB_IN[$_u]:-0} ))
        _to=$(( _to + ${_TDB_OUT[$_u]:-0} ))
        _tt=$(( _tt + ${_TDB_TOTAL[$_u]:-0} ))
    done <<< "$_cur"

    local _dt=0
    for _u in "${!_TDB_TOTAL[@]}"; do
        [ -n "${_SEEN[$_u]:-}" ] && continue
        _dt=$(( _dt + ${_TDB_TOTAL[$_u]:-0} ))
    done

    echo -e "  ${BOLD}Всего по цели${NC} ${DIM}(накоплено MTProxyL, источник: ${_src})${NC}:"
    if [ "$_src" = "metrics" ]; then
        echo -e "    ${SYM_DOWN} $(format_bytes "$_ti")  ${SYM_UP} $(format_bytes "$_to")"
    fi
    echo -e "    Передано:            $(format_bytes "$(( _tt + _dt ))")"
    echo ""

    while IFS='|' read -r _u _i _o _t; do
        [ -z "$_u" ] && continue
        # Первая строка вывода — маркер источника, а не пользователь.
        [ "$_u" = "SOURCE" ] && continue
        if [ "$_src" = "metrics" ]; then
            echo -e "  ${GREEN}${SYM_OK}${NC} ${BOLD}${_u}${NC}: ${SYM_DOWN} $(format_bytes "${_TDB_IN[$_u]:-0}")  ${SYM_UP} $(format_bytes "${_TDB_OUT[$_u]:-0}")"
        else
            echo -e "  ${GREEN}${SYM_OK}${NC} ${BOLD}${_u}${NC}: $(format_bytes "${_TDB_TOTAL[$_u]:-0}")"
        fi
    done <<< "$_cur"

    # Трафик тех, кого у цели уже нет, был израсходован — прячем его только
    # из списка живых, но не из итога.
    [ "$_dt" -gt 0 ] && \
        echo -e "  ${DIM}${SYM_CROSS} удалённые пользователи: $(format_bytes "$_dt")${NC}"
    echo ""
}

show_traffic() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        show_target_traffic
        return
    fi
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

    # В режиме супер эксперта пользователи заданы в конфиге пользователя
    local _labels=() label
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
    for label in "${_labels[@]}"; do
        local u_in u_out u_conns
        read -r u_in u_out u_conns <<< "$(get_persistent_user_stats "$label")"
        local su_in su_out su_conns
        read -r su_in su_out su_conns <<< "$(get_user_stats "$label")"
        echo -e "  ${GREEN}${SYM_OK}${NC} ${BOLD}${label}${NC}: ${SYM_DOWN} $(format_bytes "$u_in")  ${SYM_UP} $(format_bytes "$u_out")  соед: ${su_conns}"
    done

    # Удалённые пользователи из списка выпадают, а их трафик остаётся в итоге:
    # без этой строки сумма по пользователям не сходится с «всего».
    declare -A _DB_USER_IN=() _DB_USER_OUT=()
    _DB_TOTAL_IN=0; _DB_TOTAL_OUT=0
    _load_traffic_db
    local _gone_in=0 _gone_out=0 _du
    for _du in "${!_DB_USER_IN[@]}"; do
        local _live="false" _l
        for _l in "${_labels[@]}"; do [ "$_l" = "$_du" ] && { _live="true"; break; }; done
        [ "$_live" = "true" ] && continue
        _gone_in=$(( _gone_in + ${_DB_USER_IN[$_du]:-0} ))
        _gone_out=$(( _gone_out + ${_DB_USER_OUT[$_du]:-0} ))
    done
    if [ "$_gone_in" -gt 0 ] || [ "$_gone_out" -gt 0 ]; then
        echo -e "  ${DIM}${SYM_CROSS} удалённые пользователи: ${SYM_DOWN} $(format_bytes "$_gone_in")  ${SYM_UP} $(format_bytes "$_gone_out")${NC}"
    fi
    echo ""
}

# ── Накопление трафика цели (режим реаниматора) ───────────────
# Счётчики движка обнуляются при рестарте, поэтому нужна своя база. У цели
# она отдельная: чужие числа нельзя смешивать со своими.
_TARGET_TRAFFIC_DB="${INSTALL_DIR}/relay_stats/target_traffic_db"
_TARGET_SNAPSHOT="${INSTALL_DIR}/relay_stats/target_session_snapshot"

# Текущие счётчики цели: "SOURCE|<источник>", дальше "user|in|out|total".
# Источник печатается, а не кладётся в переменную — функцию зовут через $( ).
# Он важен: при смене источника разницу между счётчиками считать нельзя.
_target_current_table() {
    local _table
    if _table=$(_metrics_user_table 2>/dev/null) && [ -n "$_table" ]; then
        echo "SOURCE|metrics"
        declare -A _MET_SEEN=()
        local _u _i _o
        while IFS='|' read -r _u _i _o _; do
            [ -z "$_u" ] && continue
            _MET_SEEN["$_u"]=1
            printf '%s|%s|%s|%s\n' "$_u" "${_i:-0}" "${_o:-0}" "$(( ${_i:-0} + ${_o:-0} ))"
        done <<< "$_table"
        # Метрики знают только тех, кто что-то передал с запуска цели. Молчунов
        # дописываем нулями из конфига: иначе после перезапуска цели список
        # схлопывается до одного активного, а накопленный трафик остальных
        # уходит в строку «удалённые пользователи».
        local _st _lb
        while IFS='|' read -r _st _lb _; do
            [ -n "$_lb" ] || continue
            [ -n "${_MET_SEEN[$_lb]:-}" ] && continue
            printf '%s|0|0|0\n' "$_lb"
        done < <(_target_section_pairs "access.users" 2>/dev/null)
        return 0
    fi

    local _json
    _json=$(_get_telemt_users_json 2>/dev/null) || return 1
    echo "SOURCE|api"
    local _u _en _c _ips _oct
    while IFS='|' read -r _u _en _c _ips _oct; do
        [ -z "$_u" ] && continue
        printf '%s|0|0|%s\n' "$_u" "${_oct:-0}"
    done <<< "$(_target_user_stats "$_json")"
}

# Источник из вывода _target_current_table.
_target_table_source() {
    local _t _v
    while IFS='|' read -r _t _v _; do
        [ "$_t" = "SOURCE" ] && { printf '%s' "$_v"; return 0; }
    done <<< "$1"
    printf ''
}

# Загрузка накопленного в _TDB_IN/_TDB_OUT/_TDB_TOTAL (объявляются вызывающим).
_load_target_db() {
    _TDB_SRC=""
    [ -f "$_TARGET_TRAFFIC_DB" ] || return 0
    local _t _a _b _c _d
    while IFS='|' read -r _t _a _b _c _d; do
        case "$_t" in
            SOURCE) _TDB_SRC="${_a:-}" ;;
            USER)
                [ -z "$_a" ] && continue
                _TDB_IN["$_a"]="${_b:-0}"; _TDB_OUT["$_a"]="${_c:-0}"; _TDB_TOTAL["$_a"]="${_d:-0}" ;;
        esac
    done < "$_TARGET_TRAFFIC_DB"
}

_save_target_db() {
    mkdir -p "${INSTALL_DIR}/relay_stats" 2>/dev/null
    local _tmp="${_TARGET_TRAFFIC_DB}.tmp.$$"
    {
        echo "SOURCE|${_TDB_SRC:-}"
        local _u
        for _u in "${!_TDB_TOTAL[@]}"; do
            echo "USER|${_u}|${_TDB_IN[$_u]:-0}|${_TDB_OUT[$_u]:-0}|${_TDB_TOTAL[$_u]:-0}"
        done
    } > "$_tmp" 2>/dev/null
    mv "$_tmp" "$_TARGET_TRAFFIC_DB" 2>/dev/null
    chmod 600 "$_TARGET_TRAFFIC_DB" 2>/dev/null
}

# Дельта от прошлого снимка → в базу. Вызывается перед показом трафика.
flush_target_traffic_to_disk() {
    [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] || return 0

    local _cur; _cur=$(_target_current_table) || return 0
    [ -n "$_cur" ] || return 0
    local _src; _src=$(_target_table_source "$_cur")
    [ -n "$_src" ] || return 0

    declare -A _TDB_IN=() _TDB_OUT=() _TDB_TOTAL=()
    local _TDB_SRC=""
    _load_target_db

    # Прошлый снимок
    declare -A _PREV_IN=() _PREV_OUT=() _PREV_TOTAL=()
    local _prev_src="" _have_prev="false" _t _a _b _c _d
    if [ -f "$_TARGET_SNAPSHOT" ]; then
        _have_prev="true"
        while IFS='|' read -r _t _a _b _c _d; do
            case "$_t" in
                SOURCE) _prev_src="${_a:-}" ;;
                USER)
                    [ -z "$_a" ] && continue
                    _PREV_IN["$_a"]="${_b:-0}"; _PREV_OUT["$_a"]="${_c:-0}"; _PREV_TOTAL["$_a"]="${_d:-0}" ;;
            esac
        done < "$_TARGET_SNAPSHOT"
    fi

    # Разницу считаем только между снимками одного источника. Первый опыт —
    # точка отсчёта, а не дельта: цель могла работать месяц до нас.
    local _same_src="true"
    { [ "$_have_prev" != "true" ] || [ "$_prev_src" != "$_src" ]; } && _same_src="false"

    local _u _i _o _tt
    while IFS='|' read -r _u _i _o _tt; do
        [ -z "$_u" ] && continue
        # Первая строка вывода — маркер источника, а не пользователь.
        [ "$_u" = "SOURCE" ] && continue
        if [ "$_same_src" = "true" ]; then
            local _pi="${_PREV_IN[$_u]:-0}" _po="${_PREV_OUT[$_u]:-0}" _pt="${_PREV_TOTAL[$_u]:-0}"
            [[ "$_pi" =~ ^[0-9]+$ ]] || _pi=0
            [[ "$_po" =~ ^[0-9]+$ ]] || _po=0
            [[ "$_pt" =~ ^[0-9]+$ ]] || _pt=0
            # Счётчик меньше прошлого — цель перезапустили, дельта = текущее.
            local _di _do _dt
            [ "${_i:-0}" -ge "$_pi" ] 2>/dev/null && _di=$(( ${_i:-0} - _pi )) || _di="${_i:-0}"
            [ "${_o:-0}" -ge "$_po" ] 2>/dev/null && _do=$(( ${_o:-0} - _po )) || _do="${_o:-0}"
            [ "${_tt:-0}" -ge "$_pt" ] 2>/dev/null && _dt=$(( ${_tt:-0} - _pt )) || _dt="${_tt:-0}"
            _TDB_IN["$_u"]=$(( ${_TDB_IN[$_u]:-0} + _di ))
            _TDB_OUT["$_u"]=$(( ${_TDB_OUT[$_u]:-0} + _do ))
            _TDB_TOTAL["$_u"]=$(( ${_TDB_TOTAL[$_u]:-0} + _dt ))
        else
            # Заводим пользователя, если его ещё нет: иначе он появится в базе
            # только после второго опроса.
            _TDB_IN["$_u"]="${_TDB_IN[$_u]:-0}"
            _TDB_OUT["$_u"]="${_TDB_OUT[$_u]:-0}"
            _TDB_TOTAL["$_u"]="${_TDB_TOTAL[$_u]:-0}"
        fi
    done <<< "$_cur"

    _TDB_SRC="$_src"
    _save_target_db

    mkdir -p "${INSTALL_DIR}/relay_stats" 2>/dev/null
    {
        echo "SOURCE|${_src}"
        while IFS='|' read -r _u _i _o _tt; do
            [ -z "$_u" ] && continue
            # Первая строка вывода — маркер источника, а не пользователь.
            [ "$_u" = "SOURCE" ] && continue
            echo "USER|${_u}|${_i}|${_o}|${_tt}"
        done <<< "$_cur"
    } > "${_TARGET_SNAPSHOT}.tmp.$$" 2>/dev/null
    mv "${_TARGET_SNAPSHOT}.tmp.$$" "$_TARGET_SNAPSHOT" 2>/dev/null
    chmod 600 "$_TARGET_SNAPSHOT" 2>/dev/null
}

# Накопленное у цели для одного пользователя — "in out total". Копит перед
# чтением, иначе база отстаёт на один опрос.
# total не равен in+out: у источника api направления неизвестны.
get_persistent_target_user_stats() {
    local _label="$1"
    flush_target_traffic_to_disk 2>/dev/null || true
    declare -A _TDB_IN=() _TDB_OUT=() _TDB_TOTAL=()
    local _TDB_SRC=""
    _load_target_db
    echo "${_TDB_IN[$_label]:-0} ${_TDB_OUT[$_label]:-0} ${_TDB_TOTAL[$_label]:-0}"
}

# ── Машинный список трафика для панели ────────────────────────
# Один документ на оба режима. directional — разделён ли трафик по
# направлениям, persistent — переживают ли числа перезапуск движка.

# Пары "пользователь|in|out|conns" из Prometheus одним проходом.
# lbl() написан на переносимом awk: match() с третьим аргументом есть только
# в gawk, а на сервере может стоять mawk.
_metrics_user_table() {
    local m
    m=$(_fetch_metrics 2>/dev/null) || return 1
    printf '%s\n' "$m" | awk '
        function lbl(s, k,    p, q) {
            p = index(s, k "=\""); if (!p) return ""
            s = substr(s, p + length(k) + 2)
            q = index(s, "\""); return q ? substr(s, 1, q-1) : ""
        }
        /^telemt_user_octets_from_client\{/ { u=lbl($0,"user"); if(u){rx[u]+=$NF; seen[u]=1} }
        /^telemt_user_octets_to_client\{/   { u=lbl($0,"user"); if(u){tx[u]+=$NF; seen[u]=1} }
        /^telemt_user_connections_current\{/{ u=lbl($0,"user"); if(u){cn[u]+=$NF; seen[u]=1} }
        END { for (u in seen) printf "%s|%.0f|%.0f|%.0f\n", u, rx[u]+0, tx[u]+0, cn[u]+0 }
    '
}

_traffic_json_manager() {
    local t_in t_out conns s_in s_out s_conns
    read -r t_in t_out conns <<< "$(get_persistent_stats)"
    read -r s_in s_out s_conns <<< "$(get_proxy_stats)"

    # Список пользователей — тот же, что показывает экран трафика: в режиме
    # супер эксперта он живёт в конфиге пользователя, иначе в наших секретах.
    local _labels=() label
    if _superexpert_active; then
        local _su _sk
        while IFS='|' read -r _su _sk; do
            [ -n "$_su" ] && _labels+=("$_su")
        done <<< "$(_superexpert_users)"
    else
        local i
        for i in "${!SECRETS_LABELS[@]}"; do
            _labels+=("${SECRETS_LABELS[$i]}")
        done
    fi

    # Всё общее — один раз на весь список: раньше на каждого пользователя шли
    # docker inspect, запрос метрик и по три awk.
    declare -A _DB_USER_IN=() _DB_USER_OUT=()
    _DB_TOTAL_IN=0; _DB_TOTAL_OUT=0
    _load_traffic_db

    local _running=false
    is_proxy_running 2>/dev/null && _running=true

    declare -A _CUR_IN=() _CUR_OUT=() _CUR_CONNS=()
    if $_running; then
        local _mu _mi _mo _mc
        while IFS='|' read -r _mu _mi _mo _mc; do
            [ -n "$_mu" ] || continue
            _CUR_IN["$_mu"]="${_mi:-0}"; _CUR_OUT["$_mu"]="${_mo:-0}"; _CUR_CONNS["$_mu"]="${_mc:-0}"
        done < <(_metrics_user_table 2>/dev/null)
    fi

    # Уникальные IP знает только API движка — в Prometheus такой метрики нет.
    declare -A _IPS=()
    if $_running; then
        local _au _aen _ac _aips _aoct
        while IFS='|' read -r _au _aen _ac _aips _aoct; do
            [ -n "$_au" ] && _IPS["$_au"]="${_aips:-0}"
        done < <(_engine_user_stats 2>/dev/null)
    fi

    declare -A _SNAP_IN=() _SNAP_OUT=()
    local _user_snap_file="${INSTALL_DIR}/relay_stats/user_session_snapshot"
    if [ -f "$_user_snap_file" ]; then
        local _pu _pi _po
        while IFS='|' read -r _pu _pi _po; do
            [ -n "$_pu" ] || continue
            _SNAP_IN["$_pu"]="${_pi:-0}"; _SNAP_OUT["$_pu"]="${_po:-0}"
        done < "$_user_snap_file"
    fi

    # Метка → включён ли: поиск по массиву на каждого давал квадрат.
    local _se_active=false
    _superexpert_active && _se_active=true
    declare -A _ENABLED_BY_LABEL=()
    if ! $_se_active; then
        local _idx
        for _idx in "${!SECRETS_LABELS[@]}"; do
            _ENABLED_BY_LABEL["${SECRETS_LABELS[$_idx]}"]="${SECRETS_ENABLED[$_idx]}"
        done
    fi

    local _rows="" _first=1 _tot_ips=0
    local _si _so _ui _uo _unsaved_in _unsaved_out _en _label_esc _row
    declare -A _KNOWN=()
    for label in "${_labels[@]}"; do
        _KNOWN["$label"]=1

        _si="${_SNAP_IN[$label]:-0}"; [[ "$_si" =~ ^[0-9]+$ ]] || _si=0
        _so="${_SNAP_OUT[$label]:-0}"; [[ "$_so" =~ ^[0-9]+$ ]] || _so=0
        local _ci="${_CUR_IN[$label]:-0}" _co="${_CUR_OUT[$label]:-0}"

        if [ "${_ci:-0}" -ge "$_si" ] 2>/dev/null; then
            _unsaved_in=$(( ${_ci:-0} - _si ))
        else
            _unsaved_in="${_ci:-0}"
        fi
        if [ "${_co:-0}" -ge "$_so" ] 2>/dev/null; then
            _unsaved_out=$(( ${_co:-0} - _so ))
        else
            _unsaved_out="${_co:-0}"
        fi

        _ui=$(( ${_DB_USER_IN[$label]:-0} + _unsaved_in ))
        _uo=$(( ${_DB_USER_OUT[$label]:-0} + _unsaved_out ))

        if $_se_active; then
            _en="true"
        elif [ "${_ENABLED_BY_LABEL[$label]:-false}" = "true" ]; then
            _en="true"
        else
            _en="false"
        fi

        json_escape_fast "$label"; _label_esc="$_JSON_ESCAPE_OUT"
        [ $_first -eq 1 ] || _rows+=","
        _first=0
        printf -v _row '{"user":"%s","in":%s,"out":%s,"total":%s,"session_in":%s,"session_out":%s,"connections":%s,"unique_ips":%s,"enabled":%s,"deleted":false}' \
            "$_label_esc" "$_ui" "$_uo" "$(( _ui + _uo ))" \
            "${_ci:-0}" "${_co:-0}" "${_CUR_CONNS[$label]:-0}" "${_IPS[$label]:-0}" "$_en"
        _rows+="$_row"
        _tot_ips=$(( _tot_ips + ${_IPS[$label]:-0} ))
    done

    # Трафик удалённых пользователей учтён в TOTAL: собираем остаток отдельной
    # помеченной строкой, иначе сумма не сходится с «всего».
    local _di=0 _do=0 _u
    for _u in "${!_DB_USER_IN[@]}"; do
        [ -n "${_KNOWN[$_u]:-}" ] && continue
        _di=$(( _di + ${_DB_USER_IN[$_u]:-0} ))
        _do=$(( _do + ${_DB_USER_OUT[$_u]:-0} ))
    done
    if [ "$_di" -gt 0 ] || [ "$_do" -gt 0 ]; then
        [ $_first -eq 1 ] || _rows+=","
        _first=0
        _rows+=$(printf '{"user":"%s","in":%d,"out":%d,"total":%d,"session_in":0,"session_out":0,"connections":0,"unique_ips":0,"enabled":false,"deleted":true}' \
            "Удалённые пользователи" "$_di" "$_do" "$(( _di + _do ))")
    fi

    printf '{"mode":"manager","source":"db","directional":true,"persistent":true,'
    printf '"totals":{"in":%d,"out":%d,"total":%d,"session_in":%d,"session_out":%d,"connections":%d,"unique_ips":%d},' \
        "${t_in:-0}" "${t_out:-0}" "$(( ${t_in:-0} + ${t_out:-0} ))" \
        "${s_in:-0}" "${s_out:-0}" "${conns:-0}" "${_tot_ips:-0}"
    printf '"users":[%s]}\n' "$_rows"
}

_traffic_json_reanimator() {
    # Сначала копим: без этого «всего» означало бы «с последнего перезапуска
    # цели», а перезапускает её кто-то другой и когда угодно.
    flush_target_traffic_to_disk 2>/dev/null || true

    local _cur; _cur=$(_target_current_table 2>/dev/null) || _cur=""
    local _src; _src=$(_target_table_source "$_cur")

    if [ -z "$_cur" ] || [ -z "$_src" ]; then
        printf '{"mode":"reanimator","source":"none","directional":false,"persistent":false,'
        printf '"error":"%s","totals":{"in":0,"out":0,"total":0,"session_in":0,"session_out":0,"connections":0},"users":[]}\n' \
            "$(json_escape "$(_telemt_api_unavailable_reason)")"
        return 0
    fi

    # Соединения и уникальные IP — величины «прямо сейчас», их не копят.
    declare -A _CONNS=() _IPS=() _ENABLED=()
    if [ "$_src" = "metrics" ]; then
        local _u _i _o _c
        while IFS='|' read -r _u _i _o _c; do
            [ -n "$_u" ] && _CONNS["$_u"]="${_c:-0}"
        done <<< "$(_metrics_user_table 2>/dev/null)"
        # Выключенных метрики не показывают вовсе, поэтому статус берём из
        # конфига цели: там отключённый пользователь помечен, а не удалён.
        local _st _lb
        while IFS='|' read -r _st _lb _; do
            [ -n "$_lb" ] || continue
            [ "$_st" = "off" ] && _ENABLED["$_lb"]="false"
        done < <(_target_section_pairs "access.users" 2>/dev/null)
        # Уникальные адреса есть только у API — метрики их не считают.
        local _json _au _aen _ac _aips _aoct
        if _json=$(_get_telemt_users_json 2>/dev/null); then
            while IFS='|' read -r _au _aen _ac _aips _aoct; do
                [ -n "$_au" ] && _IPS["$_au"]="${_aips:-0}"
            done <<< "$(_target_user_stats "$_json")"
        fi
    else
        local _json _u _en _c _ips _oct
        if _json=$(_get_telemt_users_json 2>/dev/null); then
            while IFS='|' read -r _u _en _c _ips _oct; do
                [ -z "$_u" ] && continue
                _CONNS["$_u"]="${_c:-0}"; _IPS["$_u"]="${_ips:-0}"
                [ "$_en" = "false" ] && _ENABLED["$_u"]="false"
            done <<< "$(_target_user_stats "$_json")"
        fi
    fi

    declare -A _TDB_IN=() _TDB_OUT=() _TDB_TOTAL=()
    local _TDB_SRC=""
    _load_target_db

    local _directional="false"
    [ "$_src" = "metrics" ] && _directional="true"

    local _ti=0 _to=0 _tt=0 _tc=0 _tp=0
    local _si=0 _so=0
    local _rows="" _first=1
    declare -A _SEEN=()

    local _u _i _o _t
    while IFS='|' read -r _u _i _o _t; do
        [ -z "$_u" ] && continue
        # Первая строка вывода — маркер источника, а не пользователь.
        [ "$_u" = "SOURCE" ] && continue
        _SEEN["$_u"]=1
        # Накопленное уже включает текущую сессию: flush прошёл выше.
        local _ai="${_TDB_IN[$_u]:-0}" _ao="${_TDB_OUT[$_u]:-0}" _at="${_TDB_TOTAL[$_u]:-0}"
        _ti=$(( _ti + _ai )); _to=$(( _to + _ao )); _tt=$(( _tt + _at ))
        _si=$(( _si + ${_i:-0} )); _so=$(( _so + ${_o:-0} ))
        _tc=$(( _tc + ${_CONNS[$_u]:-0} ))
        _tp=$(( _tp + ${_IPS[$_u]:-0} ))
        [ $_first -eq 1 ] || _rows+=","
        _first=0
        # Без "$(...)" на каждого пользователя: три подстановки в строке — это
        # три подшелла, и на нескольких десятках секретов они стоили больше,
        # чем вся остальная сборка ответа.
        local _u_esc _en_str _row
        json_escape_fast "$_u"; _u_esc="$_JSON_ESCAPE_OUT"
        if [ "${_ENABLED[$_u]:-true}" = "false" ]; then _en_str=false; else _en_str=true; fi
        printf -v _row '{"user":"%s","in":%s,"out":%s,"total":%s,"session_in":%s,"session_out":%s,"connections":%s,"unique_ips":%s,"enabled":%s,"deleted":false}' \
            "$_u_esc" "$_ai" "$_ao" "$_at" "${_i:-0}" "${_o:-0}" \
            "${_CONNS[$_u]:-0}" "${_IPS[$_u]:-0}" "$_en_str"
        _rows+="$_row"
    done <<< "$_cur"

    # Пользователи, которых у цели больше нет: трафик они израсходовали, и
    # молча вычесть его из итога значило бы показать сумму строк меньше «всего».
    local _di=0 _do=0 _dt=0
    for _u in "${!_TDB_TOTAL[@]}"; do
        [ -n "${_SEEN[$_u]:-}" ] && continue
        _di=$(( _di + ${_TDB_IN[$_u]:-0} ))
        _do=$(( _do + ${_TDB_OUT[$_u]:-0} ))
        _dt=$(( _dt + ${_TDB_TOTAL[$_u]:-0} ))
    done
    if [ "$_dt" -gt 0 ] || [ "$_di" -gt 0 ] || [ "$_do" -gt 0 ]; then
        _ti=$(( _ti + _di )); _to=$(( _to + _do )); _tt=$(( _tt + _dt ))
        [ $_first -eq 1 ] || _rows+=","
        _first=0
        _rows+=$(printf '{"user":"%s","in":%d,"out":%d,"total":%d,"session_in":0,"session_out":0,"connections":0,"unique_ips":0,"enabled":false,"deleted":true}' \
            "Удалённые пользователи" "$_di" "$_do" "$_dt")
    fi

    printf '{"mode":"reanimator","source":"%s","directional":%s,"persistent":true,' \
        "$_src" "$_directional"
    printf '"totals":{"in":%d,"out":%d,"total":%d,"session_in":%d,"session_out":%d,"connections":%d,"unique_ips":%d},' \
        "$_ti" "$_to" "$_tt" "$_si" "$_so" "$_tc" "$_tp"
    printf '"users":[%s]}\n' "$_rows"
}

traffic_list_json() {
    # Снимок в базу здесь намеренно не пишем: get_persistent_* и так
    # прибавляют несохранённую дельту к накопленному, а панель опрашивает
    # раздел часто — каждый опрос превращался бы в запись на диск.
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        _traffic_json_reanimator
    else
        _traffic_json_manager
    fi
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
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        # В реаниматоре ни движок, ни домен, ни счётчики не наши: движок —
        # чужой, домен лежит в конфиге цели, статистика приходит из её API.
        local _st _up="—"
        if is_proxy_running; then
            _st=$(draw_status running)
            _up=$(format_duration "$(get_proxy_uptime)")
        else
            _st=$(draw_status stopped)
        fi
        echo -e "  ${BOLD}Режим:${NC}       Reanimator  ${BOLD}Статус:${NC} ${_st}"
        echo -e "  ${BOLD}Цель:${NC}        ${DETECTED_MODE:-unknown}$([ -n "${DETECTED_CONTAINER:-}" ] && echo " (${DETECTED_CONTAINER})")"
        echo -e "  ${BOLD}Конфиг цели:${NC} ${DETECTED_CONFIG_PATH:-не найден}"
        echo -e "  ${BOLD}Порт:${NC}        ${PROXY_PORT}            ${BOLD}Время работы:${NC} ${_up}"
        echo -e "  ${BOLD}Домен(SNI):${NC}  $(_current_sni_domain 2>/dev/null || echo '?')"
        if fetch_target_stats 2>/dev/null; then
            echo -e "  ${BOLD}Трафик:${NC}      $(format_bytes "${TARGET_STATS_OCTETS:-0}")"
            echo -e "  ${BOLD}Соединения:${NC}  ${TARGET_STATS_CONNS:-0}  ${BOLD}Уник. IP:${NC} ${TARGET_STATS_IPS:-0}"
            echo -e "  ${BOLD}Пользователи:${NC} ${TARGET_STATS_ACTIVE:-0} активных / ${TARGET_STATS_DISABLED:-0} выключенных"
        else
            echo -e "  ${BOLD}Трафик:${NC}      ${DIM}н/д — $(_telemt_api_unavailable_reason 2>/dev/null)${NC}"
        fi
        echo ""
        return
    fi
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
    echo -e "  ${BOLD}Соединения:${NC}  ${connections}  ${BOLD}Уник. IP:${NC} $(_engine_unique_ips 2>/dev/null || echo 'н/д')"
    echo -e "  ${BOLD}Секреты:${NC}     ${active} активных / ${disabled} выключенных"
    echo ""
}

show_status_json() {
    local status="stopped" uptime_secs=0 traffic_in=0 traffic_out=0 connections=0
    if is_proxy_running; then
        status="running"
        uptime_secs=$(get_proxy_uptime 2>/dev/null) || uptime_secs=0
        [ "${MTPROXYL_MODE:-manager}" = "manager" ] && \
            read -r traffic_in traffic_out connections <<< "$(get_proxy_stats)"
    fi

    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        # Направления трафика API цели не разделяет — отдаём одну сумму,
        # чтобы не выдавать чужие данные за in/out.
        local _octets=0 _ips=0
        if fetch_target_stats 2>/dev/null; then
            _octets="${TARGET_STATS_OCTETS:-0}"
            connections="${TARGET_STATS_CONNS:-0}"
            _ips="${TARGET_STATS_IPS:-0}"
        fi
        printf '{"version":"%s","mode":"reanimator","status":"%s","target":"%s","config":"%s","port":%d,"domain":"%s","uptime":%d,"connections":%d,"unique_ips":%d,"traffic_total":%d}\n' \
            "$VERSION" "$status" "${DETECTED_MODE:-unknown}" "${DETECTED_CONFIG_PATH:-}" \
            "$PROXY_PORT" "$(_current_sni_domain 2>/dev/null)" "$uptime_secs" "${connections:-0}" \
            "${_ips:-0}" "${_octets:-0}"
        return
    fi

    # traffic_total дублирует сумму направлений: потребители статуса (бот,
    # панель) читают одно поле в обоих режимах, а не гадают по mode.
    local _mips=0
    [ "$status" = "running" ] && _mips=$(_engine_unique_ips 2>/dev/null || echo 0)
    printf '{"version":"%s","mode":"manager","status":"%s","port":%d,"domain":"%s","uptime":%d,"connections":%d,"unique_ips":%d,"traffic_in":%d,"traffic_out":%d,"traffic_total":%d}\n' \
        "$VERSION" "$status" "$PROXY_PORT" "$PROXY_DOMAIN" "$uptime_secs" "${connections:-0}" \
        "${_mips:-0}" "${traffic_in:-0}" "${traffic_out:-0}" "$(( ${traffic_in:-0} + ${traffic_out:-0} ))"
}

show_config() {
    local config; config=$(engine_config_path)
    [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] && config="${DETECTED_CONFIG_PATH:-$config}"
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

    # В reanimator-режиме проверяем цель, а не собственный контейнер/конфиг:
    # Docker может быть вообще не нужен (systemd-юнит или голый процесс),
    # а секреты и config.toml принадлежат чужой установке.
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        _health_check_reanimator
        return
    fi

    if engine_is_binary; then
        binengine_installed && echo -e "  ${GREEN}${SYM_CHECK}${NC} Бинарник движка на месте (v$(binengine_version))" || echo -e "  ${RED}${SYM_CROSS}${NC} Бинарник движка не найден"
        binengine_running && echo -e "  ${GREEN}${SYM_CHECK}${NC} Служба ${ENGINE_SERVICE} запущена" || echo -e "  ${RED}${SYM_CROSS}${NC} Служба ${ENGINE_SERVICE} не запущена"
    else
        command -v docker &>/dev/null && echo -e "  ${GREEN}${SYM_CHECK}${NC} Docker установлен" || echo -e "  ${RED}${SYM_CROSS}${NC} Docker не установлен"
        is_proxy_running && echo -e "  ${GREEN}${SYM_CHECK}${NC} Контейнер запущен" || echo -e "  ${RED}${SYM_CROSS}${NC} Контейнер не запущен"
    fi
    curl -s --max-time 2 "http://127.0.0.1:${PROXY_METRICS_PORT}/metrics" &>/dev/null && echo -e "  ${GREEN}${SYM_CHECK}${NC} Метрики доступны" || echo -e "  ${RED}${SYM_CROSS}${NC} Метрики недоступны"
    [ -f "$(engine_config_path)" ] && echo -e "  ${GREEN}${SYM_CHECK}${NC} Конфиг существует" || echo -e "  ${RED}${SYM_CROSS}${NC} Конфиг не найден"
    local active=0 i; for i in "${!SECRETS_ENABLED[@]}"; do [ "${SECRETS_ENABLED[$i]}" = "true" ] && active=$((active+1)); done
    [ $active -gt 0 ] && echo -e "  ${GREEN}${SYM_CHECK}${NC} ${active} активных секретов" || echo -e "  ${RED}${SYM_CROSS}${NC} Нет активных секретов"
    echo ""
}

_health_check_reanimator() {
    local _tgt="${DETECTED_MODE:-unknown}"
    echo -e "  ${BOLD}Цель:${NC} ${_tgt}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
    echo ""

    # Тип цели и способ управления
    case "$_tgt" in
        docker|mtproxymax)
            if command -v docker &>/dev/null; then
                echo -e "  ${GREEN}${SYM_CHECK}${NC} Docker установлен (цель — контейнер)"
            else
                echo -e "  ${RED}${SYM_CROSS}${NC} Docker не найден, хотя цель — контейнер"
            fi ;;
        local)
            if systemctl is-active telemt.service &>/dev/null 2>&1; then
                echo -e "  ${GREEN}${SYM_CHECK}${NC} Управление: systemd (telemt.service)"
            else
                echo -e "  ${GREEN}${SYM_CHECK}${NC} Управление: процесс telemt (без systemd-юнита)"
            fi ;;
        *)
            echo -e "  ${YELLOW}!${NC} Тип цели не определён — выполните ${BOLD}mtproxyl detect${NC}" ;;
    esac

    is_proxy_running \
        && echo -e "  ${GREEN}${SYM_CHECK}${NC} Цель запущена" \
        || echo -e "  ${RED}${SYM_CROSS}${NC} Цель не запущена"

    # Конфиг цели
    if [ -n "${DETECTED_CONFIG_PATH:-}" ] && [ -f "$DETECTED_CONFIG_PATH" ]; then
        echo -e "  ${GREEN}${SYM_CHECK}${NC} Конфиг цели: ${DETECTED_CONFIG_PATH}"
        local _d; _d=$(_target_tls_domain 2>/dev/null)
        [ -n "$_d" ] && echo -e "  ${GREEN}${SYM_CHECK}${NC} SNI-домен цели: ${_d}"
    else
        echo -e "  ${RED}${SYM_CROSS}${NC} Конфиг цели не найден"
    fi

    # Порт прокси
    if command -v ss &>/dev/null; then
        ss -ltn 2>/dev/null | grep -q ":${PROXY_PORT} " \
            && echo -e "  ${GREEN}${SYM_CHECK}${NC} Порт ${PROXY_PORT} слушается" \
            || echo -e "  ${RED}${SYM_CROSS}${NC} Порт ${PROXY_PORT} не слушается"
    fi

    # API управления цели
    local _json _rc
    _json=$(_get_telemt_users_json 2>/dev/null); _rc=$?
    if [ $_rc -eq 0 ]; then
        local _act _dis
        _act=$(_json_count_bool_field "$_json" "enabled" "true")
        _dis=$(_json_count_bool_field "$_json" "enabled" "false")
        echo -e "  ${GREEN}${SYM_CHECK}${NC} API цели отвечает (127.0.0.1:$(_get_telemt_api_port))"
        echo -e "  ${GREEN}${SYM_CHECK}${NC} Пользователей: ${_act} активных / ${_dis} выключенных"
    else
        echo -e "  ${RED}${SYM_CROSS}${NC} API цели: $(_telemt_api_unavailable_reason)"
        _telemt_api_bridge_hint
    fi

    # Метрики цели (Prometheus)
    curl -s --max-time 2 "http://127.0.0.1:$(_get_telemt_metrics_port)/metrics" &>/dev/null \
        && echo -e "  ${GREEN}${SYM_CHECK}${NC} Метрики цели доступны (127.0.0.1:$(_get_telemt_metrics_port))" \
        || echo -e "  ${DIM}—${NC} Метрики цели недоступны ${DIM}(metrics_listen в конфиге цели)${NC}"

    # Наши фиксы
    echo ""
    echo -e "  ${BOLD}Применённые фиксы${NC}"
    echo -e "    Zapret2:  $(zapret2_status 2>/dev/null || echo "${DIM}—${NC}")"
    echo -e "    MEKO:     $(meko_opt_status 2>/dev/null || echo "${DIM}—${NC}")"
    echo -e "    Selfmask: $(selfmask_status_line 2>/dev/null || echo "${DIM}—${NC}")"
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
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        echo -e "  ${BOLD}Прокси (цель)${NC}"
        echo -e "    Скрипт:       v${VERSION} ${DIM}(режим: reanimator)${NC}"
        echo -e "    Цель:         ${DETECTED_MODE:-unknown}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
        echo -e "    Конфиг цели:  ${DETECTED_CONFIG_PATH:-не найден}"
        echo -e "    Домен(SNI):   $(_current_sni_domain 2>/dev/null || echo '?')"
        echo -e "    Порт:         ${PROXY_PORT}"
        local _mh _mp
        _mh=$(_toml_get_string_in_section "censorship" "mask_host" "${DETECTED_CONFIG_PATH:-}" 2>/dev/null)
        _mp=$(_toml_get_string_in_section "censorship" "mask_port" "${DETECTED_CONFIG_PATH:-}" 2>/dev/null)
        if [ -n "$_mh" ] || [ -n "$_mp" ]; then
            echo -e "    Маскировка:   ${_mh:-—}:${_mp:-443}"
        else
            echo -e "    Маскировка:   ${DIM}не задана в конфиге цели${NC}"
        fi
        echo -e "    API цели:     $(_telemt_api_enabled 2>/dev/null && echo "127.0.0.1:$(_get_telemt_api_port)" || echo "выключено")"
        echo -e "    Статус:       $(is_proxy_running && echo "запущена" || echo "остановлена")"
        echo ""
        return
    fi

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
