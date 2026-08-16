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
# 3 — не отвечает или ответил ошибкой.
_engine_api_get() {
    local _path="$1" _cfg; _cfg=$(_engine_config_path 2>/dev/null)
    _telemt_api_enabled "$_cfg" || return 2
    local _port _host _json
    _port=$(_get_telemt_api_port "$_cfg")
    _host=$(_telemt_api_host "$_cfg")
    _json=$(curl -s --max-time 4 --connect-timeout 2 "http://${_host}:${_port}${_path}" 2>/dev/null) || return 3
    [ -n "$_json" ] || return 3
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
            printf "%s|%s|%s|%s|%s|%s\n", d, \
                num($0, "rtt_ms"), num($0, "alive_writers"), num($0, "required_writers"), \
                num($0, "coverage_pct"), num($0, "available_pct")
        }
    '
}

# Общее покрытие — доля живых писателей от нужного числа по всем DC разом.
# Среднее по столбцу тут врало бы: у DC 4 писателей десять, у остальных три.
_dc_summary() {
    local _rows="$1"
    printf '%s\n' "$_rows" | awk -F'|' '
        { a += $3 + 0; r += $4 + 0; n++ }
        END {
            if (n == 0) { print "0|0|0|0"; exit }
            pct = (r > 0) ? (a * 100 / r) : 100
            if (pct > 100) pct = 100
            printf "%d|%.0f|%d|%d\n", n, pct, a, r
        }
    '
}

# Машинный отчёт. Всегда печатает документ: «нет данных» — тоже ответ.
dc_status_json() {
    local _json _rc
    _json=$(_engine_api_get "/v1/stats/dcs"); _rc=$?
    local _thr; _thr=$(_dc_threshold)
    if [ $_rc -ne 0 ]; then
        printf '{"available":false,"threshold":%d,"verdict":"unknown","error":"%s","dcs":[]}\n' \
            "$_thr" "$(json_escape "$(_telemt_api_unavailable_reason 2>/dev/null)")"
        return 0
    fi

    local _me="false"
    grep -qE '"middle_proxy_enabled"[[:space:]]*:[[:space:]]*true' <<< "$_json" && _me="true"

    local _rows; _rows=$(_dc_rows "$_json")
    if [ -z "$_rows" ]; then
        # Middle proxy выключен — движок ходит в Telegram напрямую, и писателей
        # к DC у него просто нет. Это не поломка, а другой режим работы.
        printf '{"available":false,"middle_proxy":%s,"threshold":%d,"verdict":"off",' "$_me" "$_thr"
        printf '"error":"%s","dcs":[]}\n' \
            "$([ "$_me" = "true" ] && echo "движок не отдал ни одного DC" || echo "middle proxy выключен — писателей к DC нет")"
        return 0
    fi

    local _n _pct _alive _req
    IFS='|' read -r _n _pct _alive _req <<< "$(_dc_summary "$_rows")"

    # При нулевом пороге приговора нет: бот молчит, панель ничего не красит.
    local _verdict="ok" _mark; _mark=$(_dc_mark_threshold)
    if [ "$_thr" -gt 0 ]; then
        [ "$_pct" -lt "$_thr" ] && _verdict="degraded"
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

    printf '{"available":true,"middle_proxy":%s,"threshold":%d,"verdict":"%s",' "$_me" "$_thr" "$_verdict"
    printf '"coverage_pct":%d,"dc_total":%d,"alive_writers":%d,"required_writers":%d,"dcs":[%s]}\n' \
        "$_pct" "$_n" "$_alive" "$_req" "$_out"
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
            log_info "Middle proxy выключен — движок ходит в Telegram напрямую"
            echo -e "  ${DIM}Писателей к DC в этом режиме нет, проверять нечего.${NC}"
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

    local _n _pct _alive _req
    IFS='|' read -r _n _pct _alive _req <<< "$(_dc_summary "$_rows")"
    echo ""
    local _note="порог ${_thr}%, писателей ${_alive} из ${_req}"
    [ "$_thr" -eq 0 ] && _note="порог выключен, писателей ${_alive} из ${_req}"
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

handle_dc_command() {
    case "${1:-status}" in
        status|"")
            if [ "${2:-}" = "--json" ]; then dc_status_json; else dc_show; fi ;;
        threshold) check_root; dc_set_threshold "${2:-}" ;;
        *)
            echo -e "  ${BOLD}Доступность дата-центров Telegram:${NC}"
            echo -e "    ${GREEN}dc status${NC}          Таблица DC: RTT, писатели, покрытие"
            echo -e "    ${GREEN}dc status --json${NC}   То же машинным форматом"
            echo -e "    ${GREEN}dc threshold${NC} <N>   Порог покрытия, % — 0 или off без предупреждений (сейчас $(_dc_threshold))"
            ;;
    esac
}
