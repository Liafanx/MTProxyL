#!/bin/bash
# MTProxyL — сброс накопленной статистики.
#
# Показанное число — это база на диске плюс дельта от последнего снимка
# метрик. Поэтому сброс всегда идёт в два шага: сначала слить дельту (чтобы
# снимок стал текущим), потом обнулить базу. Обратный порядок вернул бы
# накопленное первым же опросом.

_stats_dir() { echo "${INSTALL_DIR}/relay_stats"; }

_stats_traffic_db() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        echo "${INSTALL_DIR}/relay_stats/target_traffic_db"
    else
        echo "${INSTALL_DIR}/relay_stats/traffic_db"
    fi
}

_stats_ips_db() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        echo "${INSTALL_DIR}/relay_stats/target_user_ips_db"
    else
        echo "${INSTALL_DIR}/relay_stats/user_ips_db"
    fi
}

# Метки живых пользователей — по ним отличаем записи удалённых.
_stats_known_labels() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        [ -f "${DETECTED_CONFIG_PATH:-}" ] || return 0
        _target_section_pairs "users" | cut -d'|' -f2
    else
        local _i
        for _i in "${!SECRETS_LABELS[@]}"; do
            echo "${SECRETS_LABELS[$_i]}"
        done
    fi
}

_stats_label_known() {
    local _l="$1" _k
    while IFS= read -r _k; do
        [ "$_k" = "$_l" ] && return 0
    done <<< "$(_stats_known_labels)"
    return 1
}

# Снимок сессии должен указывать на «сейчас», иначе следующий опрос вернёт
# обнулённое обратно.
_stats_sync_snapshot() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        flush_target_traffic_to_disk 2>/dev/null || true
        return 0
    fi
    if _fetch_metrics >/dev/null 2>&1; then
        flush_traffic_to_disk 2>/dev/null || true
    else
        # Движок молчит: снимок всё равно протух, а после запуска метрики
        # пойдут с нуля — обнуляем его вместе с базой.
        : > "${INSTALL_DIR}/relay_stats/session_snapshot" 2>/dev/null || true
        : > "${INSTALL_DIR}/relay_stats/user_session_snapshot" 2>/dev/null || true
    fi
}

# scope: all | user | orphans
stats_reset_traffic() {
    local _scope="${1:-all}" _label="${2:-}"
    mkdir -p "$(_stats_dir)" 2>/dev/null
    _stats_sync_snapshot

    local _removed=0
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        declare -A _TDB_IN=() _TDB_OUT=() _TDB_TOTAL=()
        local _TDB_SRC=""
        _load_target_db
        local _u
        for _u in "${!_TDB_TOTAL[@]}"; do
            case "$_scope" in
                all) ;;
                user)    [ "$_u" = "$_label" ] || continue ;;
                orphans) _stats_label_known "$_u" && continue ;;
            esac
            unset '_TDB_IN[$_u]' '_TDB_OUT[$_u]' '_TDB_TOTAL[$_u]'
            _removed=$((_removed + 1))
        done
        _save_target_db
    else
        declare -A _DB_USER_IN=() _DB_USER_OUT=()
        local _DB_TOTAL_IN=0 _DB_TOTAL_OUT=0
        _load_traffic_db
        local _u _sub_in=0 _sub_out=0
        for _u in "${!_DB_USER_IN[@]}"; do
            case "$_scope" in
                all) ;;
                user)    [ "$_u" = "$_label" ] || continue ;;
                orphans) _stats_label_known "$_u" && continue ;;
            esac
            _sub_in=$((_sub_in + ${_DB_USER_IN[$_u]:-0}))
            _sub_out=$((_sub_out + ${_DB_USER_OUT[$_u]:-0}))
            unset '_DB_USER_IN[$_u]' '_DB_USER_OUT[$_u]'
            _removed=$((_removed + 1))
        done
        if [ "$_scope" = "all" ]; then
            _DB_TOTAL_IN=0; _DB_TOTAL_OUT=0
        else
            # Итог сервера — сумма пользователей, поэтому вычитаем ровно
            # столько, сколько сняли, а не обнуляем всё.
            _DB_TOTAL_IN=$(( _DB_TOTAL_IN > _sub_in ? _DB_TOTAL_IN - _sub_in : 0 ))
            _DB_TOTAL_OUT=$(( _DB_TOTAL_OUT > _sub_out ? _DB_TOTAL_OUT - _sub_out : 0 ))
        fi
        _save_traffic_db
    fi
    echo "$_removed"
}

stats_reset_ips() {
    local _scope="${1:-all}" _label="${2:-}"
    local _db; _db=$(_stats_ips_db)
    [ -f "$_db" ] || { echo 0; return 0; }

    local _before _after
    _before=$(grep -c '^USER|' "$_db" 2>/dev/null || echo 0)
    case "$_scope" in
        all)
            : > "$_db"
            _after=0 ;;
        user)
            local _tmp; _tmp=$(_mktemp "$(dirname "$_db")") || return 1
            grep -v "^USER|${_label}|" "$_db" > "$_tmp" 2>/dev/null || true
            mv "$_tmp" "$_db"
            _after=$(grep -c '^USER|' "$_db" 2>/dev/null || echo 0) ;;
        orphans)
            local _tmp; _tmp=$(_mktemp "$(dirname "$_db")") || return 1
            local _line _lbl
            while IFS= read -r _line; do
                case "$_line" in USER\|*) ;; *) continue ;; esac
                _lbl="${_line#USER|}"; _lbl="${_lbl%%|*}"
                _stats_label_known "$_lbl" && printf '%s\n' "$_line"
            done < "$_db" > "$_tmp"
            mv "$_tmp" "$_db"
            _after=$(grep -c '^USER|' "$_db" 2>/dev/null || echo 0) ;;
    esac
    chmod 600 "$_db" 2>/dev/null
    echo $(( _before > _after ? _before - _after : 0 ))
}

_stats_bytes() {
    local _n="${1:-0}"
    [[ "$_n" =~ ^[0-9]+$ ]] || _n=0
    format_bytes "$_n" 2>/dev/null || echo "${_n} Б"
}

# Что накоплено: сколько записей и на какой объём.
stats_overview() {
    local _tdb _idb
    _tdb=$(_stats_traffic_db); _idb=$(_stats_ips_db)

    local _users=0 _orphan_users=0 _in=0 _out=0
    if [ -f "$_tdb" ]; then
        local _line _lbl
        while IFS= read -r _line; do
            case "$_line" in
                TOTAL\|*) IFS='|' read -r _ _in _out <<< "$_line" ;;
                USER\|*)
                    _users=$((_users + 1))
                    _lbl="${_line#USER|}"; _lbl="${_lbl%%|*}"
                    _stats_label_known "$_lbl" || _orphan_users=$((_orphan_users + 1)) ;;
            esac
        done < "$_tdb"
    fi
    [[ "$_in" =~ ^[0-9]+$ ]] || _in=0
    [[ "$_out" =~ ^[0-9]+$ ]] || _out=0

    local _ips=0 _orphan_ips=0
    if [ -f "$_idb" ]; then
        local _line _lbl
        while IFS= read -r _line; do
            case "$_line" in USER\|*) ;; *) continue ;; esac
            _ips=$((_ips + 1))
            _lbl="${_line#USER|}"; _lbl="${_lbl%%|*}"
            _stats_label_known "$_lbl" || _orphan_ips=$((_orphan_ips + 1))
        done < "$_idb"
    fi

    if [ "${1:-}" = "--json" ]; then
        printf '{"mode":"%s","traffic":{"users":%d,"orphans":%d,"in_bytes":%d,"out_bytes":%d},' \
            "$(json_escape "${MTPROXYL_MODE:-manager}")" "$_users" "$_orphan_users" "$_in" "$_out"
        printf '"ips":{"records":%d,"orphans":%d}}\n' "$_ips" "$_orphan_ips"
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}Накоплено${NC}"
    echo ""
    echo -e "  ${BOLD}Трафик:${NC}      ${_users} пользователей"
    [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] || \
        echo -e "  ${BOLD}Всего:${NC}       ↓ $(_stats_bytes "$_in")  ↑ $(_stats_bytes "$_out")"
    echo -e "  ${BOLD}История IP:${NC}  ${_ips} записей"
    if [ $((_orphan_users + _orphan_ips)) -gt 0 ]; then
        echo -e "  ${BOLD}Удалённые:${NC}   ${_orphan_users} в трафике, ${_orphan_ips} в истории IP"
    fi
    echo ""
    echo -e "  ${DIM}Сброс: mtproxyl stats reset all | traffic | ips | orphans${NC}"
    echo -e "  ${DIM}По одному: mtproxyl stats reset user <метка>${NC}"
    echo ""
}

handle_stats_command() {
    local _cmd="${1:-show}"
    case "$_cmd" in
        show|status|"")
            stats_overview "${2:-}" ;;
        --json)
            stats_overview --json ;;
        reset)
            check_root
            local _what="${2:-all}"
            case "$_what" in
                all)
                    local _t _i
                    _t=$(stats_reset_traffic all)
                    _i=$(stats_reset_ips all)
                    log_success "Статистика сброшена: трафик ${_t} пользователей, история IP ${_i} записей"
                    ;;
                traffic)
                    local _t; _t=$(stats_reset_traffic all)
                    log_success "Трафик сброшен: ${_t} пользователей" ;;
                ips)
                    local _i; _i=$(stats_reset_ips all)
                    log_success "История IP очищена: ${_i} записей" ;;
                orphans|deleted)
                    local _t _i
                    _t=$(stats_reset_traffic orphans)
                    _i=$(stats_reset_ips orphans)
                    log_success "Данные удалённых пользователей убраны: трафик ${_t}, история IP ${_i}" ;;
                user)
                    local _label="${3:-}"
                    [ -n "$_label" ] || { log_error "Использование: mtproxyl stats reset user <метка>"; return 1; }
                    local _t _i
                    _t=$(stats_reset_traffic user "$_label")
                    _i=$(stats_reset_ips user "$_label")
                    log_success "Статистика ${_label} сброшена: трафик ${_t}, история IP ${_i}" ;;
                *)
                    log_error "Сброс: all | traffic | ips | orphans | user <метка>"
                    return 1 ;;
            esac
            ;;
        *)
            echo -e "  ${BOLD}Накопленная статистика:${NC}"
            echo -e "    ${GREEN}stats${NC}                  Что накоплено (--json для машинного вывода)"
            echo -e "    ${GREEN}stats reset all${NC}        Сбросить всё"
            echo -e "    ${GREEN}stats reset traffic${NC}    Только счётчики трафика"
            echo -e "    ${GREEN}stats reset ips${NC}        Только историю адресов"
            echo -e "    ${GREEN}stats reset orphans${NC}    Только данные удалённых пользователей"
            echo -e "    ${GREEN}stats reset user${NC} M     Всё по одному пользователю"
            ;;
    esac
}
