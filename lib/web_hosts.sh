#!/bin/bash

# Дополнительные имена используют общие профили, public_addr и снимок заглушки.
web_hostnames() {
    web_domain || return 1
    [ -z "${WEB_HOSTS:-}" ] || printf '%s\n' "${WEB_HOSTS,,}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    return 0
}

web_hostnames_space() { web_hostnames | paste -sd ' ' -; }
web_exact_hostnames() { web_hostnames | awk 'index($0,"*")==0'; }
web_has_wildcard_hosts() { [[ "${WEB_HOSTS:-}" == *'*'* ]]; }

_validate_web_hosts() {
    [ -z "$1" ] && return 0
    [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *, ]] || { echo 'Нужен список доменов через запятую без пустых элементов'; return 1; }
    local _host _name _label _seen=",$(web_domain)," _count=0
    local -a _hosts=() _labels=()
    IFS=',' read -ra _hosts <<< "${1,,}"
    for _host in "${_hosts[@]}"; do
        _host="${_host#"${_host%%[![:space:]]*}"}"; _host="${_host%"${_host##*[![:space:]]}"}"
        _name="${_host#\*.}"
        if [ "$_host" != '*' ]; then
            [[ "$_name" == *.* && ${#_name} -le 253 && "$_name" != *. && "$_name" != *[!a-z0-9.-]* && "$_name" != *..* ]] || {
                echo "Нужен FQDN без порта и пути: ${_host}"; return 1;
            }
            [[ "$_name" =~ ^[0-9.]+$ ]] && { echo 'IP вместо домена не поддерживается'; return 1; }
            IFS='.' read -ra _labels <<< "$_name"
            for _label in "${_labels[@]}"; do
                [[ ${#_label} -ge 1 && ${#_label} -le 63 && "$_label" != -* && "$_label" != *- ]] || { echo "Некорректный домен: ${_host}"; return 1; }
            done
        fi
        [[ "$_seen" != *",${_host},"* ]] || { echo "Повтор домена: ${_host}"; return 1; }
        _seen+="${_host},"; _count=$((_count + 1))
        [ "$_count" -le 100 ] || { echo 'Не больше 100 дополнительных селекторов'; return 1; }
    done
}

web_hosts_toml() {
    if [ -z "${WEB_HOSTS:-}" ]; then printf 'host = "%s"\n' "$(web_domain)"; return; fi
    printf 'hosts = %s\n' "$(web_hostnames | jq -Rsc 'split("\n") | map(select(length > 0))')"
}

# Все условия используют исходный Host: подмена одним именем ломает capability.
web_haproxy_host_acl() {
    local _fetch="$1" _h _re=''
    while IFS= read -r _h; do
        if [ "$_h" = '*' ]; then _re='^[a-z0-9.-]+$'; break
        elif [[ "$_h" == \*.* ]]; then _h="${_h#\*.}"; _h="${_h//./[.]}"; _h="^.+[.]${_h}$"
        else _h="${_h//./[.]}"; _h="^${_h}$"; fi
        _re+=" ${_h}"
    done < <(web_hostnames)
    printf '%s -m reg -i%s' "$_fetch" " ${_re# }"
}

web_hosts_problems() {
    if web_is_reanimator; then local EXPERT_OVERRIDES_FILE="${EXPERT_TARGET_OVERRIDES_FILE:-${INSTALL_DIR}/expert-target.conf}"; fi
    local _error _h _ft _n _lim
    _error=$(_validate_web_hosts "${WEB_HOSTS:-}" 2>&1) || { printf '%s\n' "$_error"; return; }
    [ -n "${WEB_HOSTS:-}" ] || return 0
    web_engine_at_least 3.5.15 || echo 'Список hosts требует telemt 3.5.15+; обновите движок перед применением'
    if mtproto_is_enabled && ! web_layout_is_split; then
        _ft=$(web_faketls_domain 2>/dev/null)
        while IFS= read -r _h; do
            [[ "$_ft" == $_h ]] && echo "WEB-селектор ${_h} пересекается с SNI MTProto ${_ft}: выберите другой домен или split"
        done < <(web_hostnames)
    fi
    if web_has_wildcard_hosts; then
        [ "$(get_expert_override_value web allow_wildcard_hosts)" = true ] || echo 'Для шаблонов нужен expert set web allow_wildcard_hosts true и перезапуск движка'
        web_frontend_is_haproxy || echo 'Автоматические wildcard-домены доступны через внешний HAProxy с вашим сертификатом; управляемый frontend принимает точные домены'
        local _rules _max_rules _profiles _per_request
        _rules=$(web_hostnames | awk 'index($0,"*")>0 {n++} END {print n+0}')
        _max_rules=$(get_expert_override_value web.limits.wildcard max_rules); _max_rules=${_max_rules:-32}
        [ "$_rules" -le "$_max_rules" ] || echo 'Число wildcard-селекторов превышает web.limits.wildcard.max_rules'
        _profiles=$(web_profile_count)
        _per_request=$(get_expert_override_value web.limits.wildcard max_profiles_per_request); _per_request=${_per_request:-256}
        _n=$(web_exact_hostnames | wc -l)
        [ $((_profiles / (_n + 1))) -le "$_per_request" ] || echo 'Число профилей превышает web.limits.wildcard.max_profiles_per_request'
    fi
    _n=$(web_exact_hostnames | wc -l)
    _lim=$(get_expert_override_value web.limits max_vhosts); _lim=${_lim:-8}
    [ "$_n" -le "$_lim" ] || echo "Доменов ${_n}, web.limits.max_vhosts = ${_lim}; увеличьте лимит"
    _lim=$(get_expert_override_value web.limits max_profiles)
    [ -z "$_lim" ] || [ "$(web_profile_count)" -le "$_lim" ] || echo 'WEB-профили всех доменов превышают web.limits.max_profiles; увеличьте лимит'
    return 0
}

web_engine_at_least() {
    declare -F web_engine_version >/dev/null || return 1
    local _v; _v=$(web_engine_version)
    _v="${_v#v}"; _v="${_v%%-*}"
    [[ "$_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
    [ "$(printf '%s\n%s\n' "$1" "$_v" | sort -V | head -n1)" = "$1" ]
}

_expert_min_engine() {
    case "$1.$2" in
        web.retry_jitter.*) echo 3.5.16 ;;
        web.allow_wildcard_hosts|web.limits.wildcard.*|access.user_quota_periods) echo 3.5.15 ;;
        web.timeouts.decoy_resolve_secs) echo 3.5.14 ;;
    esac
}

_expert_supported() {
    local _min; _min=$(_expert_min_engine "$1" "$2")
    [ -z "$_min" ] || web_engine_at_least "$_min"
}

_validate_quota_periods() {
    jq -e 'type == "object" and length <= 65536 and all(to_entries[]; (.key | test("^[a-zA-Z0-9_-]{1,64}$")) and (.value == "daily" or .value == "weekly" or .value == "monthly"))' <<< "$1" >/dev/null 2>&1 || {
        echo 'JSON-объект: {"alice":"monthly"}; периоды daily, weekly, monthly'; return 1;
    }
}

_expert_quota_period_move() {
    declare -F get_expert_override_value >/dev/null || return 0
    local _from="$1" _to="${2:-}" _map
    _map=$(get_expert_override_value access user_quota_periods)
    [ -n "$_map" ] || return 0
    _map=$(jq -c --arg from "$_from" --arg to "$_to" '
        if has($from) then .[$from] as $period | del(.[$from]) |
            if $to != "" then .[$to]=$period else . end
        else . end' <<< "$_map") || return 1
    save_expert_override access user_quota_periods "$_map"
}

web_new_settings_problems() {
    declare -F get_expert_override_value >/dev/null || return 0
    if web_is_reanimator; then local EXPERT_OVERRIDES_FILE="$EXPERT_TARGET_OVERRIDES_FILE"; fi
    local _min _max _peak _dist _burst _profiles _enabled
    _min=$(get_expert_override_value web.retry_jitter min_ms); _min=${_min:-0}
    _max=$(get_expert_override_value web.retry_jitter max_ms); _max=${_max:-250}
    _peak=$(get_expert_override_value web.retry_jitter peak_ms)
    _dist=$(get_expert_override_value web.retry_jitter distribution); _dist=${_dist:-uniform}
    [ "$_min" -le "$_max" ] || echo 'web.retry_jitter.min_ms больше max_ms'
    if [ -n "$_peak" ]; then
        [ "$_dist" = triangular ] && [ "$_peak" -ge "$_min" ] && [ "$_peak" -le "$_max" ] || echo 'web.retry_jitter.peak_ms требует triangular и значение внутри min_ms..max_ms'
    fi
    _enabled=$(get_expert_override_value web allow_wildcard_hosts)
    if [ "$_enabled" = true ]; then
        _burst=$(get_expert_override_value web.limits.wildcard cold_hmac_burst); _burst=${_burst:-65536}
        _profiles=$(get_expert_override_value web.limits.wildcard max_profiles_per_request); _profiles=${_profiles:-256}
        [ "$_burst" -ge "$_profiles" ] || echo 'web.limits.wildcard.cold_hmac_burst меньше max_profiles_per_request'
    fi
    return 0
}

# Квоты удалённых, выключенных или лишённых лимита пользователей не включаем.
_expert_quota_periods_toml() {
    local _label _period _i _pairs='' _ok
    while IFS=$'\t' read -r _label _period; do
        _ok=false
        for _i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_LABELS[$_i]}" = "$_label" ] || continue
            [ "${SECRETS_ENABLED[$_i]}" = true ] && [ "${SECRETS_QUOTA[$_i]:-0}" -gt 0 ] && _ok=true
            break
        done
        if $_ok; then
            [ -z "$_pairs" ] || _pairs+=', '
            _pairs+="\"${_label}\" = \"${_period}\""
        else
            log_warn "Период квоты ${_label} сохранён, но не применяется: нужен включённый пользователь с положительной квотой" >&2
        fi
    done < <(jq -r 'to_entries[] | [.key,.value] | @tsv' <<< "$1")
    printf '{%s}' "$_pairs"
}
