#!/bin/bash
# MTProxyL — «Экспертные параметры» для движка mtdd.
# Каталог ключей JSON-конфига mtdd (умолчания и диапазоны — по парсеру mtdd
# 1.0.0, src/config.cpp) в той же форме, что каталог telemt: команды
# `mtproxyl expert …`, экран эксперта в меню и страница панели работают
# одинаково для обоих движков. Значения пишутся туда же, куда писал `tune`:
# в Manager — tune.json (конфиг собирает MTProxyL), у цели — её config.json.
#
# Формат: "section|key|type|default|hot_reload|validator|hint|description"
# hot_reload ✔ — применяется без обрыва клиентов (SIGHUP), ✘ — перезапуском.

declare -a _MTDD_CATALOG=(
"connections|workers|u32|0|✘|range:0:256|0–256, 0 — авто|Рабочие потоки (reactor); 0 — по числу ядер"
"connections|max_connections|u32|без лимита|✘|range:1:1000000|1–1000000|Общий лимит одновременных подключений к прокси"
"connections|max_handshakes|u32|без лимита|✘|range:1:1000000|1–1000000|Лимит одновременных рукопожатий"
"timeouts|handshake_timeout_seconds|u32|15|✘|range:1:120|1–120 с|Сколько ждать рукопожатие клиента"
"timeouts|idle_timeout_seconds|u32|1800|✘|range:30:86400|30–86400 с|Простой соединения до закрытия"
"timeouts|client_keepalive_seconds|u32|60|✘|range:0:7200|0–7200 с, 0 — выкл|TCP keepalive клиентских сокетов"
"timeouts|client_ack_timeout_seconds|u32|90|✘|custom:_mtdd_valid_ack_timeout|0 или 10–3600 с|TCP_USER_TIMEOUT: когда бросать клиента, который не подтверждает данные; 0 — выкл"
"timeouts|shutdown_timeout_seconds|u32|10|✘|range:1:120|1–120 с|Предел плавной остановки"
"middle_proxy|me_connections_per_dc|u32|16|✔|range:1:24|1–24|Потолок писателей (соединений к middle proxy) на один DC в потоке"
"middle_proxy|me_clients_per_writer|u32|400|✔|range:1:1000000|1–1000000|Клиентов на писателя, после которых пул растёт"
"middle_proxy|metadata_refresh_seconds|u32|3600|✘|range:60:86400|60–86400 с|Как часто обновлять адреса Telegram (getProxyConfig)"
"buffers|global_buffer_bytes|u64|авто|✘|range:65536:68719476736|до 64 GiB|Общий бюджет буферов; MTProxyL ставит ¼ памяти, от 64 MiB до 1 GiB"
"buffers|connection_queue_bytes|u32|262144|✘|range:4096:16777216|4096–16777216 байт|Очередь одного соединения"
"buffers|max_frame_bytes|u32|2097152|✘|range:4096:16777216|4096–16777216 байт|Предел одного кадра"
"buffers|cpu_affinity|bool|true|✘|bool|true / false|Привязывать потоки к ядрам"
"routing|masking|bool|true|✘|bool|true / false|Пробы без ключа уходят на настоящий сайт (маскировка)"
"routing|direct_fallback_enabled|bool|false|✘|bool|true / false|Ходить к выбранным DC напрямую, без middle proxy"
"routing|direct_fallback_dcs|list||✘|custom:_mtdd_valid_dcs|±1…5 через запятую; в панели первым — положительный|DC для прямого маршрута (CDN 203 нельзя)"
"media|media_user_rate_kbps|u64|0|✔|range:0:100000000|0–100000000 кбит/с, 0 — выкл|Скачивание медиа на пользователя (все его IP и устройства вместе)"
"media|media_total_rate_kbps|u64|0|✔|range:0:100000000|0–100000000 кбит/с, 0 — выкл|Скачивание медиа на весь сервер"
"clients|device_window_seconds|u32|900|✘|range:60:86400|60–86400 с|Сколько устройство числится после отключения (для лимита устройств)"
"clients|unique_ip_min_bytes|u64|1048576|✘|range:0:1099511627776|0–2^40 байт|Сколько байт должен передать IP, чтобы считаться активным"
"suspects|suspects|bool|false|✘|bool|true / false|Учёт подозрительных адресов (сканеры, зонды)"
"suspects|fingerprint|bool|false|✘|bool|true / false|Отпечаток SYN и ClientHello в таблице подозрительных"
"suspects|suspect_watch_score|u32|60|✘|range:0:100|0–100|С какого score адрес попадает под наблюдение"
"suspects|suspect_ban_score|u32|0|✘|range:0:100|0–100, 0 — выкл|Теневой бан: с этого score соединения уходят на маскировку"
"suspects|suspect_ttl_hours|u32|168|✘|range:1:720|1–720 ч|Сколько хранить неактивный адрес"
)

# Порядок и подписи разделов в меню.
_MTDD_SECTIONS="connections timeouts middle_proxy buffers routing media clients suspects"
_mtdd_section_title() {
    case "$1" in
        connections)  echo "Подключения" ;;
        timeouts)     echo "Таймауты" ;;
        middle_proxy) echo "Middle proxy" ;;
        buffers)      echo "Буферы и потоки" ;;
        routing)      echo "Маскировка и маршруты" ;;
        media)        echo "Медиа-лимиты" ;;
        clients)      echo "Устройства и IP" ;;
        suspects)     echo "Подозрительные адреса" ;;
        *)            echo "$1" ;;
    esac
}

_mtdd_valid_ack_timeout() {
    [[ "$1" =~ ^[0-9]+$ ]] || { echo "Должно быть целым числом"; return 1; }
    [ "$1" -eq 0 ] || { [ "$1" -ge 10 ] && [ "$1" -le 3600 ]; } || { echo "0 или 10..3600"; return 1; }
}

# DC через запятую: ±1…5, без 0 и повторов (203 mtdd для прямого маршрута не знает).
_mtdd_valid_dcs() {
    local _v="${1// /}" _d _seen=","
    [ -n "$_v" ] || { echo "Список DC через запятую, например 1,2,-2"; return 1; }
    IFS=',' read -ra _arr <<< "$_v"
    for _d in "${_arr[@]}"; do
        [[ "$_d" =~ ^-?[1-5]$ ]] || { echo "DC — от -5 до 5, без 0: ${_d}"; return 1; }
        [[ "$_seen" == *",${_d},"* ]] && { echo "DC повторяется: ${_d}"; return 1; }
        _seen+="${_d},"
    done
}

_mtdd_expert_find() {
    local _e _k
    for _e in "${_MTDD_CATALOG[@]}"; do
        _k="${_e#*|}"; _k="${_k%%|*}"
        [ "$_k" = "$1" ] && { echo "$_e"; return 0; }
    done
    return 1
}

# Ключ, которым в Manager распоряжается сам MTProxyL: маскировка — из
# настроек прокси, Direct для всех DC — при WARP и AWG без middle proxy.
_mtdd_expert_managed() {
    declare -F mtdd_mgr_active >/dev/null && mtdd_mgr_active || return 1
    case "$1" in
        masking) return 0 ;;
        direct_fallback_enabled|direct_fallback_dcs)
            declare -F _mtdd_mgr_route_state >/dev/null \
                && [ "$(_mtdd_mgr_route_state | cut -d'|' -f1)" = 1 ] && return 0 ;;
    esac
    return 1
}

# Значения одним чтением: _MTDD_EV_CUR — действующий конфиг mtdd, _MTDD_EV_OVR —
# что задано вручную (Manager: tune.json; цель: ключ есть в её конфиге).
# Раньше меню звало python на каждый ключ — 27 процессов на экран.
declare -gA _MTDD_EV_CUR=() _MTDD_EV_OVR=()
_mtdd_expert_values() {
    _MTDD_EV_CUR=(); _MTDD_EV_OVR=()
    local _cfg _tune="" _k _v
    if declare -F mtdd_mgr_active >/dev/null && mtdd_mgr_active; then
        _cfg="$MTDD_MGR_CONFIG"; _tune="$MTDD_MGR_TUNE"
    else
        _cfg="${DETECTED_CONFIG_PATH:-}"
    fi
    local _jq='to_entries[] | "\(.key)\t\(.value | if type == "array" then map(tostring) | join(",") else tostring end)"'
    if [ -n "$_cfg" ] && [ -r "$_cfg" ]; then
        while IFS=$'\t' read -r _k _v; do
            [ -n "$_k" ] && _MTDD_EV_CUR[$_k]="$_v"
        done < <(jq -r "$_jq" "$_cfg" 2>/dev/null)
    fi
    if [ -n "$_tune" ]; then
        [ -r "$_tune" ] || return 0
        while IFS=$'\t' read -r _k _v; do
            [ -n "$_k" ] && _MTDD_EV_OVR[$_k]="$_v"
        done < <(jq -r "$_jq" "$_tune" 2>/dev/null)
    else
        for _k in "${!_MTDD_EV_CUR[@]}"; do _MTDD_EV_OVR[$_k]="${_MTDD_EV_CUR[$_k]}"; done
    fi
    return 0
}

# Каталог для панели — та же форма, что expert_catalog_json у telemt.
mtdd_expert_catalog_json() {
    _mtdd_expert_values
    local _e _first=1 _ovr _hot
    printf '['
    for _e in "${_MTDD_CATALOG[@]}"; do
        _expert_parse "$_e"
        _mtdd_expert_managed "$EXPERT_P_KEY" && continue
        _ovr="${_MTDD_EV_OVR[$EXPERT_P_KEY]:-}"
        _hot=false; [ "$EXPERT_P_HOT" = "✔" ] && _hot=true
        [ $_first -eq 1 ] || printf ','
        _first=0
        printf '{"section":"%s","key":"%s","type":"%s","default":"%s","hot_reload":%s,"validator":"%s","hint":"%s","description":"%s","override":"%s","has_override":%s}' \
            "$(json_escape "$EXPERT_P_SECTION")" "$(json_escape "$EXPERT_P_KEY")" "$(json_escape "$EXPERT_P_TYPE")" \
            "$(json_escape "$EXPERT_P_DEFAULT")" "$_hot" "$(json_escape "$EXPERT_P_VALIDATOR")" \
            "$(json_escape "$EXPERT_P_HINT")" "$(json_escape "$EXPERT_P_DESC")" "$(json_escape "$_ovr")" \
            "$([ -n "$_ovr" ] && echo true || echo false)"
    done
    printf ']\n'
}

mtdd_expert_overrides_json() {
    _mtdd_expert_values
    local _e _first=1 _ovr
    printf '['
    for _e in "${_MTDD_CATALOG[@]}"; do
        _expert_parse "$_e"
        _ovr="${_MTDD_EV_OVR[$EXPERT_P_KEY]:-}"
        [ -n "$_ovr" ] || continue
        _mtdd_expert_managed "$EXPERT_P_KEY" && continue
        [ $_first -eq 1 ] || printf ','
        _first=0
        printf '{"section":"%s","key":"%s","value":"%s"}' \
            "$(json_escape "$EXPERT_P_SECTION")" "$(json_escape "$EXPERT_P_KEY")" "$(json_escape "$_ovr")"
    done
    printf ']\n'
}

# Текстовый список: раздел, ключ, значение (или умолчание), диапазон.
mtdd_expert_show() {
    _mtdd_expert_values
    echo ""; draw_header "ЭКСПЕРТНЫЕ ПАРАМЕТРЫ MTDD"; echo ""
    local _sec _e _v _mark _n=0
    for _sec in $_MTDD_SECTIONS; do
        echo -e "  ${BOLD}$(_mtdd_section_title "$_sec")${NC}"
        for _e in "${_MTDD_CATALOG[@]}"; do
            [ "${_e%%|*}" = "$_sec" ] || continue
            _expert_parse "$_e"; _n=$((_n + 1))
            _v="${_MTDD_EV_OVR[$EXPERT_P_KEY]:-}"
            _mark=""; [ "$EXPERT_P_HOT" = "✔" ] && _mark=" ${DIM}⚡${NC}"
            if _mtdd_expert_managed "$EXPERT_P_KEY"; then
                printf "  %3s  %-28s %s %b\n" "$_n" "$EXPERT_P_KEY" "${_MTDD_EV_CUR[$EXPERT_P_KEY]:-—}" "${DIM}(задаёт MTProxyL)${NC}"
            elif [ -n "$_v" ]; then
                printf "  %3s  %-28s %b %b%b\n" "$_n" "$EXPERT_P_KEY" "${GREEN}${_v}${NC}" "${DIM}(умолч. ${EXPERT_P_DEFAULT:-нет}; ${EXPERT_P_HINT})${NC}" "$_mark"
            else
                printf "  %3s  %-28s %b%b\n" "$_n" "$EXPERT_P_KEY" "${DIM}${EXPERT_P_DEFAULT:-нет} · ${EXPERT_P_HINT}${NC}" "$_mark"
            fi
        done
    done
    echo ""
    if declare -F mtdd_mgr_active >/dev/null && mtdd_mgr_active; then
        echo -e "  ${DIM}Зелёным — задано вами, серым — умолчание mtdd и допустимые значения.${NC}"
    else
        echo -e "  ${DIM}Зелёным — ключ есть в конфиге цели (его мог записать и её установщик), серым — умолчание mtdd.${NC}"
    fi
    echo -e "  ${DIM}⚡ — применяется без обрыва клиентов, остальное — перезапуском mtdd.${NC}"
    echo ""
}

# Значение из ввода → JSON для конфига mtdd.
_mtdd_expert_json() {
    local _type="$1" _v="$2"
    case "$_type" in
        list) echo "[${_v// /}]" ;;
        bool) echo "$_v" ;;
        u32|u64) echo "$((10#$_v))" ;;
        *) python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$_v" ;;
    esac
}

_MTDD_EXPERT_PENDING() { echo "${INSTALL_DIR}/cache/mtdd-expert-pending"; }

# Отложенное применение (--no-apply, как у панели): что-то «холодное» —
# перезапуск, только «горячие» — reload без обрыва.
_mtdd_expert_mark_pending() {
    local _f; _f=$(_MTDD_EXPERT_PENDING)
    mkdir -p "${_f%/*}" 2>/dev/null
    echo "$1" >> "$_f"
}

mtdd_expert_apply() {
    local _f; _f=$(_MTDD_EXPERT_PENDING)
    if [ ! -s "$_f" ]; then log_info "Применять нечего — изменения уже действуют"; return 0; fi
    local _restart=false
    grep -qx restart "$_f" && _restart=true
    rm -f "$_f"
    if [ "$_restart" = true ]; then
        _mtdd_mgr_stopped 2>/dev/null || mtdd_restart || return 1
        log_success "mtdd перезапущен с новыми параметрами"
    else
        mtdd_reload || return 1
        log_success "Применено без обрыва клиентов (reload)"
    fi
}

_mtdd_expert_apply_one() {
    local _hot="$1" _apply="$2"
    if [ "$_apply" != true ]; then
        _mtdd_expert_mark_pending "$([ "$_hot" = "✔" ] && echo hot || echo restart)"
        return 0
    fi
    if [ "$_hot" = "✔" ]; then
        mtdd_reload || return 1
        # Сборка без SIGHUP или остановленная служба — reload ушёл в перезапуск
        # или ждёт запуска: это не ошибка.
        [ "${MTDD_RELOAD_HOT:-false}" = true ] && log_info "Применено без обрыва клиентов (reload)"
        return 0
    fi
    _mtdd_mgr_stopped 2>/dev/null || mtdd_restart
}

# expert set <раздел> <ключ> <значение> [--no-apply]; раздел можно опустить.
mtdd_expert_set() {
    local _apply=true _a; local -a _pos=()
    for _a in "$@"; do
        case "$_a" in --no-apply) _apply=false ;; --raw) ;; *) _pos+=("$_a") ;; esac
    done
    local _key _val
    if [ "${#_pos[@]}" -ge 3 ]; then _key="${_pos[1]}"; _val="${_pos[2]}"
    else _key="${_pos[0]:-}"; _val="${_pos[1]:-}"; fi
    [ -n "$_key" ] && [ -n "$_val" ] || { log_error "Использование: mtproxyl expert set [раздел] <ключ> <значение>"; return 1; }
    local _e; _e=$(_mtdd_expert_find "$_key") || {
        log_error "Параметра ${_key} нет в каталоге mtdd"
        log_info "Список: mtproxyl expert list"; return 1; }
    _expert_parse "$_e"
    if _mtdd_expert_managed "$_key"; then
        case "$_key" in
            masking) log_error "Маскировку задаёт MTProxyL: mtproxyl settings set MASKING_ENABLED true|false" ;;
            *)       log_error "${_key} задаёт MTProxyL, пока включены WARP или свой AWG без middle proxy" ;;
        esac
        return 1
    fi
    local _verr; _verr=$(_expert_validate "$EXPERT_P_VALIDATOR" "$_val" 2>&1)
    [ -z "$_verr" ] || { log_error "${_key}: ${_verr}"; return 1; }
    local _hot="$EXPERT_P_HOT" _json
    _json=$(_mtdd_expert_json "$EXPERT_P_TYPE" "$_val") || return 1
    mtdd_config_set "${_key}=${_json}" || return 1
    log_success "${_key} = ${_val}"
    _mtdd_expert_apply_one "$_hot" "$_apply"
}

mtdd_expert_clear() {
    local _apply=true _a; local -a _pos=()
    for _a in "$@"; do
        case "$_a" in --no-apply) _apply=false ;; *) _pos+=("$_a") ;; esac
    done
    local _key=""
    [ "${#_pos[@]}" -gt 0 ] && _key="${_pos[$(( ${#_pos[@]} - 1 ))]}"
    [ -n "$_key" ] || { log_error "Использование: mtproxyl expert clear [раздел] <ключ> | all"; return 1; }
    if [ "$_key" = all ]; then
        _mtdd_expert_values
        local _e _pairs=() _hotall=✔
        for _e in "${_MTDD_CATALOG[@]}"; do
            _expert_parse "$_e"
            _mtdd_expert_managed "$EXPERT_P_KEY" && continue
            [ -n "${_MTDD_EV_OVR[$EXPERT_P_KEY]:-}" ] || continue
            _pairs+=("${EXPERT_P_KEY}=@unset")
            [ "$EXPERT_P_HOT" = "✔" ] || _hotall=✘
        done
        [ "${#_pairs[@]}" -gt 0 ] || { log_info "Своих значений нет"; return 0; }
        mtdd_config_set "${_pairs[@]}" || return 1
        log_success "Сброшено к умолчаниям mtdd: ${#_pairs[@]}"
        _mtdd_expert_apply_one "$_hotall" "$_apply"
        return
    fi
    local _e; _e=$(_mtdd_expert_find "$_key") || { log_error "Параметра ${_key} нет в каталоге mtdd"; return 1; }
    _expert_parse "$_e"
    _mtdd_expert_managed "$_key" && { log_error "${_key} задаёт MTProxyL"; return 1; }
    mtdd_config_set "${_key}=@unset" || return 1
    log_success "${_key} снят (умолчание mtdd: ${EXPERT_P_DEFAULT:-нет})"
    _mtdd_expert_apply_one "$EXPERT_P_HOT" "$_apply"
}

handle_mtdd_expert_command() {
    local _sub="${1:-list}"; shift 2>/dev/null || true
    case "$_sub" in
        list|status)
            case "${1:-}" in
                --json)    mtdd_expert_overrides_json ;;
                --catalog) mtdd_expert_catalog_json ;;
                *)         mtdd_expert_show ;;
            esac ;;
        set)   check_root; mtdd_expert_set "$@" ;;
        clear) check_root; mtdd_expert_clear "$@" ;;
        apply) check_root; mtdd_expert_apply ;;
        *)
            echo -e "  ${BOLD}Экспертные параметры mtdd:${NC}"
            echo -e "    ${GREEN}expert list${NC}                          Параметры, умолчания и диапазоны"
            echo -e "    ${GREEN}expert list --catalog${NC}                Каталог (JSON)"
            echo -e "    ${GREEN}expert set${NC} [раздел] <ключ> <значение>  Задать"
            echo -e "    ${GREEN}expert clear${NC} [раздел] <ключ> | all     Вернуть умолчание mtdd"
            echo -e "    ${GREEN}expert apply${NC}                         Применить отложенное (--no-apply)"
            echo -e "    ${DIM}mtproxyl tune … — то же самое, старое имя${NC}" ;;
    esac
}

# Меню: список с номерами, выбор — карточка параметра и ввод.
tui_mtdd_expert_menu() {
    while true; do
        clear_screen
        mtdd_expert_show
        local -a _keys=()
        local _e _sec
        for _sec in $_MTDD_SECTIONS; do
            for _e in "${_MTDD_CATALOG[@]}"; do
                [ "${_e%%|*}" = "$_sec" ] || continue
                _expert_parse "$_e"; _keys+=("$EXPERT_P_KEY")
            done
        done
        echo -e "  ${DIM}[номер] — изменить · [r номер] — вернуть умолчание · [0] — назад${NC}"
        local _sel; read_line _sel "  Выбор: "
        case "$_sel" in
            0|"") return ;;
            r\ *|R\ *)
                local _n="${_sel#* }"
                [[ "$_n" =~ ^[0-9]+$ ]] && [ "$_n" -ge 1 ] && [ "$_n" -le "${#_keys[@]}" ] \
                    && { mtdd_expert_clear "${_keys[$((_n - 1))]}" || true; press_any_key; } ;;
            *)
                [[ "$_sel" =~ ^[0-9]+$ ]] && [ "$_sel" -ge 1 ] && [ "$_sel" -le "${#_keys[@]}" ] || continue
                local _k="${_keys[$((_sel - 1))]}"
                _e=$(_mtdd_expert_find "$_k"); _expert_parse "$_e"
                echo ""
                echo -e "  ${BOLD}${_k}${NC} — ${EXPERT_P_DESC}"
                echo -e "  ${DIM}Умолчание: ${EXPERT_P_DEFAULT:-нет} · допустимо: ${EXPERT_P_HINT} · $([ "$EXPERT_P_HOT" = "✔" ] && echo "без обрыва клиентов" || echo "перезапуск mtdd")${NC}"
                echo -e "  ${DIM}Сейчас: ${_MTDD_EV_OVR[$_k]:-умолчание}${NC}"
                local _v; read_line _v "  ${BOLD}Новое значение (Enter — отмена):${NC} "
                [ -n "$_v" ] && { mtdd_expert_set "$_k" "$_v" || true; press_any_key; } ;;
        esac
    done
}
