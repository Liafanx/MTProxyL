#!/bin/bash
# MTProxyL — выход к Telegram: напрямую, через WARP, донор или свой AWG.
# Одновременно включён только один.

_egress_donor_on() { declare -F donor_load >/dev/null && ( donor_load; [ "$DONOR_ENABLED" = true ] ); }

# Включённые выходы, кроме своего.
egress_others() {
    local _self="${1:-}"
    if [ "$_self" != warp ] && [ "${WARP_ENABLED:-false}" = true ]; then echo warp; fi
    if [ "$_self" != donor ] && _egress_donor_on; then echo donor; fi
    if [ "$_self" != awg ] && awg_is_enabled 2>/dev/null; then echo awg; fi
    return 0
}

egress_label() {
    case "$1" in
        warp)  echo "маршрут через WARP" ;;
        donor) echo "туннель до донора" ;;
        awg)   echo "выход через свой AWG" ;;
    esac
}

_egress_off() {
    case "$1" in
        warp)  ( handle_warp_command off ) || return 1; WARP_ENABLED="false" ;;
        donor) ( donor_disable ) ;;
        awg)   ( handle_awg_command off ) ;;
    esac
}

# Включён другой выход: спросить, можно ли выключить; из панели и скриптов — только с --replace.
egress_confirm() {
    local _self="$1" _replace="${2:-false}" _o
    local -a _list=()
    mapfile -t _list < <(egress_others "$_self")
    [ ${#_list[@]} -gt 0 ] || return 0
    for _o in "${_list[@]}"; do
        log_warn "Сейчас включён $(egress_label "$_o") — одновременно работает только один выход"
    done
    [ "$_replace" = true ] && return 0
    if [ "${MTPROXYL_ASSUME_YES:-}" = 1 ] || [ "${MTPROXYL_NONINTERACTIVE:-false}" = true ] || [ ! -t 0 ]; then
        log_error "Выключите: $(for _o in "${_list[@]}"; do printf 'mtproxyl %s off; ' "$_o"; done)или повторите с --replace"
        return 1
    fi
    local _yn; read_line _yn "  ${BOLD}Выключить и включить $(egress_label "$_self")? [y/N]:${NC} "
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Ничего не меняли"; return 1; }
}

# Выключить другие выходы. Выключенные запоминаются, чтобы вернуть их, если новый не поднимется.
egress_take_over() {
    local _self="$1" _replace="${2:-false}" _o
    _EGRESS_REPLACED=""
    egress_confirm "$_self" "$_replace" || return 1
    for _o in $(egress_others "$_self"); do
        if ! _egress_off "$_o"; then
            log_error "Не удалось выключить: $(egress_label "$_o")"
            egress_restore
            return 1
        fi
        _EGRESS_REPLACED+="${_o} "
    done
    [ -n "$_EGRESS_REPLACED" ] || return 0
    # Выключали в подпроцессах — настройки перечитываем.
    load_settings
    declare -F load_upstreams >/dev/null && load_upstreams
    return 0
}

# Новый выход не поднялся — возвращаем выключенные.
egress_restore() {
    local _o _list="${_EGRESS_REPLACED:-}"
    _EGRESS_REPLACED=""
    [ -n "$_list" ] || return 0
    for _o in $_list; do
        log_info "Возвращаем $(egress_label "$_o")..."
        case "$_o" in
            warp)  ( export MTPROXYL_ASSUME_YES=1; handle_warp_command on ) ;;
            donor) ( export MTPROXYL_ASSUME_YES=1; donor_enable --yes ) ;;
            awg)   ( export MTPROXYL_ASSUME_YES=1; handle_awg_command on --yes ) ;;
        esac >/dev/null 2>&1 || log_warn "Не удалось вернуть $(egress_label "$_o") — включите вручную: mtproxyl ${_o} on"
    done
    load_settings
    declare -F load_upstreams >/dev/null && load_upstreams
    return 0
}

# Через что сейчас идёт Telegram. ok: true/false, null — давно не проверяли.
egress_status_json() {
    local _via="direct" _name="" _ip="" _ok="null" _err="" _since=0 _now _extra=""
    _now=$(date +%s)
    if awg_is_enabled 2>/dev/null; then
        awg_load
        _via="awg"; _name="$AWG_ACTIVE"; _ip="$AWG_EGRESS_IP"
        if [ -n "$AWG_FAIL_SINCE" ]; then
            _ok=false; _since="$AWG_FAIL_SINCE"; _err="${AWG_CHECK_ERROR:-не отвечает}"
        elif ip link show "$AWG_IFACE" >/dev/null 2>&1; then
            _ok=true
        else
            _ok=false; _err="интерфейс не поднят"
        fi
        local _order; _order=$(_awg_order_list | while IFS= read -r _o; do printf '"%s",' "$(json_escape "$_o")"; done)
        _extra=$(printf ',"awg":{"order":[%s],"failover_after":%s,"failback_every":%s,"last_switch":{"at":%s,"from":"%s","to":"%s","reason":"%s"},"primary_check":{"at":%s,"result":"%s"}}' \
            "${_order%,}" "$(_awg_failover_after)" "$(_awg_failback_every)" \
            "${AWG_SWITCH_AT:-0}" "$(json_escape "$AWG_SWITCH_FROM")" "$(json_escape "$AWG_SWITCH_TO")" \
            "$(json_escape "$AWG_SWITCH_REASON")" "${AWG_PRIMARY_AT:-0}" "$(json_escape "$AWG_PRIMARY_RESULT")")
    elif _egress_donor_on; then
        donor_load
        _via="donor"; _name="$DONOR_HOST"; _ip="${DONOR_CHECK_EGRESS:-$DONOR_EGRESS_IP}"
        if [[ "${DONOR_CHECK_AT:-}" =~ ^[0-9]+$ ]] && [ $(( _now - DONOR_CHECK_AT )) -lt 1800 ]; then
            if [ "$DONOR_CHECK_RESULT" = ok ]; then _ok=true; else _ok=false; _err="$DONOR_CHECK_ERROR"; fi
        fi
    elif [ "${WARP_ENABLED:-false}" = true ]; then
        _via="warp"; _name="${WARP_LOCATION:-}"
        local _h _res _at
        _h=$(jq -r '"\(.result // "")|\(.checked_at // 0)|\(.error // "")"' "$(_warp_health_file)" 2>/dev/null)
        IFS='|' read -r _res _at _err <<< "$_h"
        if [[ "${_at:-}" =~ ^[0-9]+$ ]] && [ $(( _now - _at )) -lt 1800 ]; then
            case "$_res" in
                healthy|recovered) _ok=true; _err="" ;;
                "") ;;
                *) _ok=false ;;
            esac
        else
            _err=""
        fi
    fi
    printf '{"via":"%s","label":"%s","name":"%s","egress_ip":"%s","ok":%s,"error":"%s","fail_since":%s%s}\n' \
        "$_via" "$(json_escape "$(egress_label "$_via")")" "$(json_escape "$_name")" "$(json_escape "$_ip")" \
        "$_ok" "$(json_escape "$_err")" "${_since:-0}" "$_extra"
}

egress_status() {
    local _j; _j=$(egress_status_json)
    local _via _name _ip _ok
    IFS='|' read -r _via _name _ip _ok < <(jq -r '[.via, .name, .egress_ip, (.ok | tostring)] | join("|")' <<< "$_j")
    case "$_via" in
        direct) echo -e "  ${BOLD}Выход к Telegram:${NC} напрямую" ;;
        warp)   echo -e "  ${BOLD}Выход к Telegram:${NC} WARP${_name:+ (${_name})}" ;;
        donor)  echo -e "  ${BOLD}Выход к Telegram:${NC} донор ${_name}${_ip:+, адрес ${_ip}}" ;;
        awg)    echo -e "  ${BOLD}Выход к Telegram:${NC} свой AWG «${_name}»${_ip:+, адрес ${_ip}}" ;;
    esac
    case "$_ok" in
        true)  echo -e "  ${BOLD}Состояние:${NC}        ${GREEN}работает${NC}" ;;
        false) echo -e "  ${BOLD}Состояние:${NC}        ${RED}не отвечает${NC}" ;;
    esac
}

handle_egress_command() {
    case "${1:-status}:${2:-}" in
        --json:|status:--json) egress_status_json ;;
        status:) egress_status ;;
        *) log_error "mtproxyl egress [--json] — через что идёт трафик к Telegram"; return 1 ;;
    esac
}
