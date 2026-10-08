#!/bin/bash
# MTProxyL — доступность дата-центров Telegram.
#
# Считает не сеть вокруг сервера, а то, что видит сам движок: сколько писателей
# он держит к каждому DC и какая доля от нужного числа жива. Данные берутся из
# REST API движка (/v1/stats/dcs) — в Prometheus разбивки по DC нет вовсе.
# Проверка «Доступность из РФ» отвечает на другой вопрос — доходят ли до нас
# пользователи; здесь наоборот: доходим ли мы до Telegram.

# Порог общего покрытия, ниже которого считаем, что связь с DC просела.
# Ноль — предупреждений нет вовсе: таблица остаётся, приговора не выносим.
DC_THRESHOLD_DEFAULT=80

_dc_threshold() {
    local _v="${DC_THRESHOLD:-$DC_THRESHOLD_DEFAULT}"
    [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 0 ] && [ "$_v" -le 100 ] || _v="$DC_THRESHOLD_DEFAULT"
    echo "$_v"
}

# Порог, по которому помечаем строки таблицы. При выключенных предупреждениях
# отмечаем только полностью мёртвый DC: это факт, а не тревога.
_dc_mark_threshold() {
    local _t; _t=$(_dc_threshold)
    [ "$_t" -eq 0 ] && _t=1
    echo "$_t"
}

# GET к API движка текущего режима. Коды: 0 — успех, 2 — API выключен,
# 3 — не отвечает или ответил ошибкой, 4 — отклонил авторизацию
# ([server.api] auth_header).
_engine_api_get() {
    local _path="$1" _cfg; _cfg=$(_engine_config_path 2>/dev/null)
    _telemt_api_enabled "$_cfg" || return 2
    local _port _host _auth _resp _code _json
    _port=$(_get_telemt_api_port "$_cfg")
    _host=$(_telemt_api_host "$_cfg")
    _auth=$(_get_telemt_auth_header "$_cfg")
    local -a _auth_h=()
    [ -n "$_auth" ] && _auth_h=(-H "Authorization: ${_auth}")
    # Как в _get_telemt_users_json: код ответа — последней строкой через -w.
    _resp=$(curl -s --max-time 4 --connect-timeout 2 "${_auth_h[@]}" \
                -w $'\n%{http_code}' "http://${_host}:${_port}${_path}" 2>/dev/null) || return 3
    [ -n "$_resp" ] || return 3
    _code="${_resp##*$'\n'}"
    case "$_code" in
        200) ;;
        401|403) return 4 ;;
        *)       return 3 ;;
    esac
    _json="${_resp%$'\n'*}"
    grep -qE '"ok"[[:space:]]*:[[:space:]]*false' <<< "$_json" && return 3
    grep -q '"data"' <<< "$_json" || return 3
    printf '%s' "$_json"
}

# Строки "dc|rtt_ms|alive|required|coverage|available" из ответа /v1/stats/dcs.
# Разбор тем же приёмом, что и пользователи цели: один awk на весь ответ,
# записи режутся по ключу "dc": (в "dcs": он не попадает — там другой ключ).
_dc_rows() {
    local _json="$1"
    printf '%s' "$_json" | tr -d '\n' | awk '
        function raw_after(s, k,   p) {
            p = index(s, "\"" k "\""); if (!p) return ""
            s = substr(s, p + length(k) + 2)
            p = index(s, ":"); if (!p) return ""
            s = substr(s, p + 1); sub(/^[ \t]+/, "", s)
            return s
        }
        # Числа приходят дробными (rtt_ms 157.8366, coverage_pct 100.0).
        function num(s, k,   v) {
            v = raw_after(s, k)
            if (match(v, /^-?[0-9]+(\.[0-9]+)?/)) return substr(v, RSTART, RLENGTH)
            return ""
        }
        BEGIN { RS = "\"dc\":" }
        NR == 1 { next }
        {
            if (!match($0, /^[ \t]*-?[0-9]+/)) next
            d = substr($0, RSTART, RLENGTH); gsub(/[ \t]/, "", d)
            alive = num($0, "alive_writers") + 0
            required = num($0, "required_writers") + 0
            coverage = required > 0 ? int(100 * (alive < required ? alive : required) / required + .5) : 0
            printf "%s|%s|%s|%s|%s|%s\n", d, \
                num($0, "rtt_ms"), alive, required, coverage, num($0, "available_pct")
        }
    '
}

# Общее покрытие — доля живых писателей от нужного числа по всем DC разом.
# Среднее по столбцу тут врало бы: у DC 4 писателей десять, у остальных три.
_dc_summary() {
    local _rows="$1"
    printf '%s\n' "$_rows" | awk -F'|' '
        NF >= 4 { a += $3 + 0; r += $4 + 0; covered += ($3 < $4 ? $3 : $4); n++ }
        END {
            if (n == 0) { print "0|0|0|0|0"; exit }
            pct = (r > 0) ? (covered * 100 / r) : 0
            if (pct > 100) pct = 100
            printf "%d|%d|%d|%d|%d\n", n, int(pct + .5), a, r, covered
        }
    '
}

# Просят ли ME в конфиге движка. У telemt он включён по умолчанию, поэтому
# «нет строки» — это тоже «включён». Нужно, чтобы отличить выключенный ME от
# ещё не поднятого: первые полминуты после старта API отдаёт
# middle_proxy_enabled=false, пока инициализируется пул писателей.
_dc_me_configured() {
    local _cfg; _cfg=$(_engine_config_path 2>/dev/null)
    [ -n "$_cfg" ] && [ -f "$_cfg" ] || return 0
    grep -qE '^[[:space:]]*use_middle_proxy[[:space:]]*=[[:space:]]*false' "$_cfg" && return 1
    return 0
}

# Машинный отчёт. Всегда печатает документ: «нет данных» — тоже ответ.
dc_status_json() {
    local _json _rc
    _json=$(_engine_api_get "/v1/stats/dcs"); _rc=$?
    local _thr; _thr=$(_dc_threshold)
    if [ $_rc -ne 0 ]; then
        printf '{"available":false,"threshold":%d,"verdict":"unknown","auto_restart":%s,"error":"%s","dcs":[]}\n' \
            "$_thr" "$(dc_restart_json)" "$(json_escape "$(_telemt_api_unavailable_reason 2>/dev/null)")"
        return 0
    fi

    local _me="false"
    grep -qE '"middle_proxy_enabled"[[:space:]]*:[[:space:]]*true' <<< "$_json" && _me="true"

    local _rows; _rows=$(_dc_rows "$_json")
    if [ -z "$_rows" ]; then
        # Middle proxy выключен — движок ходит в Telegram напрямую, и писателей
        # к DC у него просто нет. Это не поломка, а другой режим работы.
        local _verdict_off="off" _err
        if [ "$_me" = "true" ]; then
            _err="движок не отдал ни одного DC"
        elif _dc_me_configured; then
            # В конфиге ME включён, а движок ещё не поднял пул — это старт.
            _verdict_off="warmup"
            _err="middle proxy ещё поднимается — пул писателей инициализируется"
        else
            _err="middle proxy выключен — писателей к DC нет"
        fi
        printf '{"available":false,"middle_proxy":%s,"threshold":%d,"verdict":"%s","auto_restart":%s,' \
            "$_me" "$_thr" "$_verdict_off" "$(dc_restart_json)"
        printf '"error":"%s","dcs":[]}\n' "$_err"
        return 0
    fi

    local _n _pct _alive _req _covered
    IFS='|' read -r _n _pct _alive _req _covered <<< "$(_dc_summary "$_rows")"
    local _zero
    _zero=$(printf '%s\n' "$_rows" | awk -F'|' '$4 > 0 && $3 == 0 { n++ } END { print n+0 }')

    # При нулевом пороге приговора нет: бот молчит, панель ничего не красит.
    local _verdict="ok" _mark; _mark=$(_dc_mark_threshold)
    if [ "$_thr" -gt 0 ]; then
        [ "$_pct" -lt "$_thr" ] && _verdict="degraded"
        [ "$_zero" -gt 0 ] && _verdict="down"
        [ "$_pct" -eq 0 ] && _verdict="down"
    fi

    local _first=1 _out="" _d _rtt _aw _rw _cov _avl _ok
    while IFS='|' read -r _d _rtt _aw _rw _cov _avl; do
        [ -n "$_d" ] || continue
        _ok=true
        [ "${_cov%%.*}" -lt "$_mark" ] 2>/dev/null && _ok=false
        [ $_first -eq 1 ] || _out+=","
        _first=0
        _out+=$(printf '{"dc":%s,"rtt_ms":%.0f,"alive_writers":%d,"required_writers":%d,"coverage_pct":%.0f,"available_pct":%.0f,"ok":%s}' \
            "$_d" "${_rtt:-0}" "${_aw:-0}" "${_rw:-0}" "${_cov:-0}" "${_avl:-0}" "$_ok")
    done <<< "$_rows"

    printf '{"available":true,"middle_proxy":%s,"threshold":%d,"verdict":"%s","auto_restart":%s,' \
        "$_me" "$_thr" "$_verdict" "$(dc_restart_json)"
    printf '"zero_writer_dcs":%d,' "$_zero"
    printf '"coverage_pct":%d,"dc_total":%d,"alive_writers":%d,"covered_writers":%d,"required_writers":%d,"dcs":[%s]}\n' \
        "$_pct" "$_n" "$_alive" "$_covered" "$_req" "$_out"
}

# Человеческий вывод: та же таблица, что показывает панель.
dc_show() {
    local _json _rc
    _json=$(_engine_api_get "/v1/stats/dcs"); _rc=$?
    echo ""
    draw_header "ДОСТУПНОСТЬ ДАТА-ЦЕНТРОВ TELEGRAM"
    echo ""
    if [ $_rc -ne 0 ]; then
        log_warn "Данных нет: $(_telemt_api_unavailable_reason 2>/dev/null)"
        _telemt_api_bridge_hint 2>/dev/null || true
        echo ""
        return 1
    fi

    local _rows; _rows=$(_dc_rows "$_json")
    if [ -z "$_rows" ]; then
        if grep -qE '"middle_proxy_enabled"[[:space:]]*:[[:space:]]*false' <<< "$_json"; then
            if _dc_me_configured; then
                log_info "Middle proxy ещё поднимается — пул писателей инициализируется"
                echo -e "  ${DIM}После запуска движка это занимает до минуты. Повторите проверку.${NC}"
            else
                log_info "Middle proxy выключен — движок ходит в Telegram напрямую"
                echo -e "  ${DIM}Писателей к DC в этом режиме нет, проверять нечего.${NC}"
            fi
        else
            log_warn "Движок не отдал ни одного DC"
        fi
        echo ""
        return 1
    fi

    local _thr _lim; _thr=$(_dc_threshold); _lim=$(_dc_mark_threshold)
    printf "     %-8s %6s  %10s  %8s\n" "DC" "RTT" "Писатели" "Покрытие"
    echo -e "  ${DIM}$(_repeat '─' 42)${NC}"
    local _d _rtt _aw _rw _cov _avl _mark
    while IFS='|' read -r _d _rtt _aw _rw _cov _avl; do
        [ -n "$_d" ] || continue
        if [ "${_cov%%.*}" -ge "$_lim" ] 2>/dev/null; then _mark="✅"; else _mark="⚠️"; fi
        printf "  %s %-8s %3.0f мс %5d / %-4d %6.0f%%\n" \
            "$_mark" "DC ${_d}" "${_rtt:-0}" "${_aw:-0}" "${_rw:-0}" "${_cov:-0}"
    done <<< "$_rows"

    local _n _pct _alive _req _covered
    IFS='|' read -r _n _pct _alive _req _covered <<< "$(_dc_summary "$_rows")"
    echo ""
    local _note="порог ${_thr}%, в зачёт ${_covered} из ${_req}, живых всего ${_alive}"
    [ "$_thr" -eq 0 ] && _note="порог выключен, в зачёт ${_covered} из ${_req}, живых всего ${_alive}"
    if [ "$_thr" -gt 0 ] && [ "$_pct" -lt "$_thr" ]; then
        echo -e "  ${YELLOW}Общее покрытие: ${_pct}%${NC} ${DIM}(${_note})${NC}"
    else
        echo -e "  ${GREEN}Общее покрытие: ${_pct}%${NC} ${DIM}(${_note})${NC}"
    fi
    echo ""
}

# Порог покрытия. Ноль (он же off) выключает предупреждения целиком — и в боте,
# и в панели: таблица остаётся, но «просело» больше никто не скажет.
dc_set_threshold() {
    local _v="${1:-}"
    case "$_v" in
        off|OFF|выкл|disable|none) _v=0 ;;
    esac
    if ! [[ "$_v" =~ ^[0-9]+$ ]] || [ "$_v" -gt 100 ]; then
        log_error "Порог: число 0..100 (процент покрытия), 0 или off — без предупреждений"
        return 1
    fi
    DC_THRESHOLD="$_v"
    save_settings
    if [ "$_v" -eq 0 ]; then
        log_success "Предупреждения о просадке DC выключены"
    else
        log_success "Порог покрытия DC: ${_v}%"
    fi
}

# ── Перезапуск движка при падении DC ──────────────────────────
# Таймер раз в минуту сверяет общее покрытие с порогом. Два замера подряд
# ниже порога — перезапуск. После старта движка DC поднимаются не сразу,
# поэтому в охлаждение (по умолчанию 5 минут) не перезапускаем. Если DC так и
# не поднялись, пауза до следующего перезапуска удваивается, до часа.
DC_WATCH_UNIT="mtproxyl-dc-watch"
DC_WATCH_STATE="${INSTALL_DIR:-/opt/mtproxyl}/dc-watch.state"
DC_RESTART_CONFIRM=2
DC_RESTART_MAX_PAUSE=60

_dc_restart_threshold() {
    local _v="${DC_RESTART_THRESHOLD:-50}"
    [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 1 ] && [ "$_v" -le 100 ] || _v=50
    echo "$_v"
}

_dc_restart_cooldown() {
    local _v="${DC_RESTART_COOLDOWN:-5}"
    [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 1 ] && [ "$_v" -le 1440 ] || _v=5
    echo "$_v"
}

_dc_watch_load() {
    DCW_LOW=0; DCW_LAST=0; DCW_STREAK=0; DCW_RESTARTS=0; DCW_CHECKED=0
    DCW_COV=""; DCW_LAST_COV=""; DCW_RESULT=""
    [ -r "$DC_WATCH_STATE" ] || return 0
    local _k _v
    while IFS='=' read -r _k _v; do
        case "$_k" in
            low|last|streak|restarts|checked) [[ "$_v" =~ ^[0-9]+$ ]] || _v=0 ;;
            cov|last_cov) [[ "$_v" =~ ^[0-9]*$ ]] || _v="" ;;
            result) [[ "$_v" =~ ^[a-z_]*$ ]] || _v="" ;;
            *) continue ;;
        esac
        case "$_k" in
            low) DCW_LOW=$_v ;;
            last) DCW_LAST=$_v ;;
            streak) DCW_STREAK=$_v ;;
            restarts) DCW_RESTARTS=$_v ;;
            checked) DCW_CHECKED=$_v ;;
            cov) DCW_COV=$_v ;;
            last_cov) DCW_LAST_COV=$_v ;;
            result) DCW_RESULT=$_v ;;
        esac
    done < "$DC_WATCH_STATE"
}

_dc_watch_save() {
    local _tmp; _tmp=$(_mktemp "$INSTALL_DIR") || return 1
    printf 'low=%s\nlast=%s\nstreak=%s\nrestarts=%s\nchecked=%s\ncov=%s\nlast_cov=%s\nresult=%s\n' \
        "$DCW_LOW" "$DCW_LAST" "$DCW_STREAK" "$DCW_RESTARTS" "$DCW_CHECKED" \
        "$DCW_COV" "$DCW_LAST_COV" "$DCW_RESULT" > "$_tmp"
    chmod 600 "$_tmp"
    mv -f "$_tmp" "$DC_WATCH_STATE"
}

# Пауза до следующего перезапуска, минут: охлаждение, удвоенное за каждый
# перезапуск, после которого DC так и не поднялись.
_dc_restart_pause() {
    local _c _p _s="${DCW_STREAK:-0}"
    _c=$(_dc_restart_cooldown); _p=$_c
    while [ "$_s" -gt 1 ] && [ "$_p" -lt "$DC_RESTART_MAX_PAUSE" ]; do
        _p=$((_p * 2)); _s=$((_s - 1))
    done
    [ "$_p" -gt "$DC_RESTART_MAX_PAUSE" ] && _p=$DC_RESTART_MAX_PAUSE
    [ "$_p" -lt "$_c" ] && _p=$_c
    echo "$_p"
}

dc_restart_json() {
    _dc_watch_load
    printf '{"enabled":%s,"threshold":%d,"cooldown_min":%d,"pause_min":%d,"restarts":%d,"last_restart_at":%d,"last_restart_coverage":%s,"checked_at":%d,"result":"%s"}' \
        "$([ "${DC_RESTART_ENABLED:-false}" = "true" ] && echo true || echo false)" \
        "$(_dc_restart_threshold)" "$(_dc_restart_cooldown)" "$(_dc_restart_pause)" \
        "$DCW_RESTARTS" "$DCW_LAST" "${DCW_LAST_COV:-null}" "$DCW_CHECKED" "$DCW_RESULT"
}

dc_install_watch() {
    command -v systemctl &>/dev/null || return 0
    if [ "${DC_RESTART_ENABLED:-false}" != "true" ]; then
        remove_dc_watch_timer
        return 0
    fi
    cat > "/etc/systemd/system/${DC_WATCH_UNIT}.service" <<UNIT
[Unit]
Description=MTProxyL: перезапуск движка при падении DC

[Service]
Type=oneshot
LogLevelMax=notice
SyslogLevel=notice
ExecStart=${INSTALL_DIR}/mtproxyl.sh dc watch
TimeoutStartSec=5min
UMask=0077
UNIT
    cat > "/etc/systemd/system/${DC_WATCH_UNIT}.timer" <<UNIT
[Unit]
Description=MTProxyL: проверка покрытия DC

[Timer]
OnBootSec=2min
OnUnitInactiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload || return 1
    systemctl enable --now "${DC_WATCH_UNIT}.timer" >/dev/null 2>&1
}

remove_dc_watch_timer() {
    command -v systemctl &>/dev/null || return 0
    [ -f "/etc/systemd/system/${DC_WATCH_UNIT}.timer" ] || [ -f "/etc/systemd/system/${DC_WATCH_UNIT}.service" ] || return 0
    systemctl disable --now "${DC_WATCH_UNIT}.timer" >/dev/null 2>&1 || true
    systemctl stop "${DC_WATCH_UNIT}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${DC_WATCH_UNIT}.timer" "/etc/systemd/system/${DC_WATCH_UNIT}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

# Из load_settings: перезапуск включён, а таймера нет (переезд, бэкап) — ставим.
_ensure_dc_watch_timer() {
    [ "${DC_RESTART_ENABLED:-false}" = "true" ] || return 0
    [ "${EUID:-$(id -u)}" -eq 0 ] || return 0
    [ -f "/etc/systemd/system/${DC_WATCH_UNIT}.timer" ] && return 0
    dc_install_watch >/dev/null 2>&1 || true
}

# Запуск таймером. Остановленный прокси не поднимаем: его остановили
# намеренно. Без данных о DC (API выключен, ME выключен или ещё поднимается)
# не перезапускаем — судить не по чему.
dc_watch() {
    [ "${DC_RESTART_ENABLED:-false}" = "true" ] || return 0
    [ "${TOOLS_ONLY:-false}" = "true" ] && return 0
    exec 9>"${DC_WATCH_STATE}.lock"
    if command -v flock &>/dev/null; then flock -n 9 || return 0; fi
    _dc_watch_load
    local _now; _now=$(date +%s)
    DCW_CHECKED=$_now; DCW_COV=""
    if ! is_proxy_running; then
        DCW_LOW=0; DCW_RESULT="stopped"; _dc_watch_save; return 0
    fi
    local _json _rows=""
    _json=$(_engine_api_get "/v1/stats/dcs") && _rows=$(_dc_rows "$_json")
    if [ -z "$_rows" ]; then
        DCW_LOW=0; DCW_RESULT="no_data"; _dc_watch_save; return 0
    fi
    local _n _pct _rest _thr
    IFS='|' read -r _n _pct _rest <<< "$(_dc_summary "$_rows")"
    DCW_COV=$_pct
    _thr=$(_dc_restart_threshold)
    if [ "$_pct" -ge "$_thr" ]; then
        DCW_LOW=0; DCW_STREAK=0; DCW_RESULT="ok"; _dc_watch_save; return 0
    fi
    DCW_LOW=$((DCW_LOW + 1))

    local _up _cool _pause
    _cool=$(( $(_dc_restart_cooldown) * 60 ))
    _pause=$(( $(_dc_restart_pause) * 60 ))
    _up=$(get_proxy_uptime 2>/dev/null)
    if [[ "$_up" =~ ^[0-9]+$ ]] && [ "$_up" -gt 0 ] && [ "$_up" -lt "$_cool" ]; then
        DCW_RESULT="warmup"; _dc_watch_save; return 0
    fi
    if [ "$DCW_LAST" -gt 0 ] && [ $((_now - DCW_LAST)) -lt "$_pause" ]; then
        DCW_RESULT="cooldown"; _dc_watch_save; return 0
    fi
    if [ "$DCW_LOW" -lt "$DC_RESTART_CONFIRM" ]; then
        DCW_RESULT="low"; _dc_watch_save; return 0
    fi

    # Состояние пишем до перезапуска: оборвись он — охлаждение уже идёт.
    DCW_LAST=$_now; DCW_LAST_COV=$_pct; DCW_LOW=0
    DCW_RESTARTS=$((DCW_RESTARTS + 1)); DCW_STREAK=$((DCW_STREAK + 1))
    DCW_RESULT="restarted"
    _dc_watch_save
    log_warn "Покрытие DC ${_pct}% ниже порога ${_thr}% — перезапуск движка"
    load_secrets 2>/dev/null || true
    load_upstreams 2>/dev/null || true
    restart_target
}

dc_restart_show() {
    _dc_watch_load
    local _state="${DIM}выключен${NC}"
    [ "${DC_RESTART_ENABLED:-false}" = "true" ] && _state="${GREEN}включён${NC}"
    echo -e "  ${BOLD}Перезапуск движка в случае падения DC:${NC} ${_state}"
    echo -e "  ${DIM}Порог: покрытие ниже $(_dc_restart_threshold)%, охлаждение $(_dc_restart_cooldown) мин${NC}"
    if [ "$DCW_LAST" -gt 0 ]; then
        echo -e "  ${DIM}Последний перезапуск: $(date -d "@${DCW_LAST}" '+%d.%m %H:%M' 2>/dev/null) при покрытии ${DCW_LAST_COV:-?}%, всего ${DCW_RESTARTS}${NC}"
    fi
    if [ "${DCW_STREAK:-0}" -gt 1 ]; then
        echo -e "  ${DIM}DC не поднялись после ${DCW_STREAK} перезапусков подряд — пауза $(_dc_restart_pause) мин${NC}"
    fi
}

# dc autorestart [on|off | threshold <1-100> | cooldown <мин>]
dc_restart_set() {
    local _what="${1:-}" _v="${2:-}"
    case "$_what" in
        ""|status) dc_restart_show; return 0 ;;
        on|off)
            check_root
            DC_RESTART_ENABLED=false; [ "$_what" = on ] && DC_RESTART_ENABLED=true
            save_settings || return 1
            dc_install_watch || { log_error "Не удалось поставить таймер ${DC_WATCH_UNIT}"; return 1; }
            if [ "$_what" = on ]; then
                log_success "Перезапуск движка при падении DC включён: ниже $(_dc_restart_threshold)%, охлаждение $(_dc_restart_cooldown) мин"
            else
                log_success "Перезапуск движка при падении DC выключен"
            fi ;;
        threshold)
            [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 1 ] && [ "$_v" -le 100 ] || {
                log_error "Порог перезапуска: число 1..100 — процент покрытия DC"; return 1; }
            check_root
            DC_RESTART_THRESHOLD="$_v"; save_settings || return 1
            log_success "Порог перезапуска: покрытие DC ниже ${_v}%" ;;
        cooldown)
            [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 1 ] && [ "$_v" -le 1440 ] || {
                log_error "Охлаждение: число минут 1..1440"; return 1; }
            check_root
            DC_RESTART_COOLDOWN="$_v"; save_settings || return 1
            log_success "Охлаждение после перезапуска: ${_v} мин" ;;
        *)
            log_error "dc autorestart [on|off | threshold <1-100> | cooldown <мин>]"
            return 1 ;;
    esac
}

handle_dc_command() {
    case "${1:-status}" in
        status|"")
            if [ "${2:-}" = "--json" ]; then dc_status_json; else dc_show; fi ;;
        threshold) check_root; dc_set_threshold "${2:-}" ;;
        autorestart) dc_restart_set "${2:-}" "${3:-}" ;;
        watch) dc_watch ;;
        *)
            echo -e "  ${BOLD}Доступность дата-центров Telegram:${NC}"
            echo -e "    ${GREEN}dc status${NC}          Таблица DC: RTT, писатели, покрытие"
            echo -e "    ${GREEN}dc status --json${NC}   То же машинным форматом"
            echo -e "    ${GREEN}dc threshold${NC} <N>   Порог покрытия, % — 0 или off без предупреждений (сейчас $(_dc_threshold))"
            echo -e "    ${GREEN}dc autorestart${NC} on|off         Перезапуск движка в случае падения DC"
            echo -e "    ${GREEN}dc autorestart threshold${NC} <N>  Перезапуск, если покрытие ниже N% (сейчас $(_dc_restart_threshold))"
            echo -e "    ${GREEN}dc autorestart cooldown${NC} <мин> Охлаждение после перезапуска (сейчас $(_dc_restart_cooldown))"
            ;;
    esac
}
