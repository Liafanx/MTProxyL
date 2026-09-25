#!/bin/bash
# Ограничение отдачи клиентам по IPv4: отдельный класс tc на каждый IP.
# Собственные файлы MTProxyL; конфиг чужого telemt в reanimator не меняем.

SHAPING_FILE="${INSTALL_DIR}/shaping.json"
SHAPING_STATE_FILE="${INSTALL_DIR}/shaping-state.json"
SHAPING_TC_FILE="${INSTALL_DIR}/shaping-tc.json"
SHAPING_LOCK_FILE="${INSTALL_DIR}/.shaping.lock"
SHAPING_BOOT_UNIT=/etc/systemd/system/mtproxyl-shaping.service
SHAPING_TICK_UNIT=/etc/systemd/system/mtproxyl-shaping-update.service
SHAPING_TIMER_UNIT=/etc/systemd/system/mtproxyl-shaping-update.timer

shaping_default_config() {
    printf '%s\n' '{"enabled":false,"mode":"manual","channel_mbps":1000,"reserve_percent":10,"expected_users":10,"manual_total_mbps":900,"manual_ip_mbps":90,"profile_exempt":[],"ip_exempt":[]}'
}

shaping_config() {
    if [ -f "$SHAPING_FILE" ]; then
        # Настройки до перехода с лимита профиля на лимит IP сохраняют значение.
        jq -c '.manual_ip_mbps = (.manual_ip_mbps // .manual_profile_mbps) | del(.manual_profile_mbps)' "$SHAPING_FILE"
    else
        shaping_default_config
    fi
}

shaping_atomic_json() {
    local target="$1" input="$2" tmp
    mkdir -p "$INSTALL_DIR" || return 1
    tmp=$(mktemp "${INSTALL_DIR}/.shaping.XXXXXX") || return 1
    chmod 600 "$tmp"
    if ! printf '%s\n' "$input" > "$tmp"; then rm -f "$tmp"; return 1; fi
    mv -f "$tmp" "$target"
}

shaping_rename_profile() {
    local old="$1" new="$2" cfg
    [ -f "$SHAPING_FILE" ] || return 0
    cfg=$(jq -c --arg old "$old" --arg new "$new" '.profile_exempt |= map(if . == $old then $new else . end) | .profile_exempt |= unique' "$SHAPING_FILE") || return 1
    shaping_atomic_json "$SHAPING_FILE" "$cfg"
}

shaping_valid_ipv4_cidr() {
    local address="${1%/*}" mask=32 octet
    local -a octets=()
    if [[ "$1" == */* ]]; then mask="${1##*/}"; fi
    [[ "$mask" =~ ^(0|[1-9][0-9]?)$ ]] && (( mask <= 32 )) || return 1
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( 10#$octet <= 255 )) || return 1
    done
}

shaping_validate_config() {
    local input="$1" entry
    printf '%s\n' "$input" | jq -e '
        type == "object" and
        (.enabled | type == "boolean") and
        (.mode == "manual" or .mode == "fixed" or .mode == "dynamic") and
        (.channel_mbps | type == "number" and . >= 1 and . <= 100000 and . == floor) and
        (.reserve_percent | type == "number" and . >= 0 and . <= 90 and . == floor) and
        (.expected_users | type == "number" and . >= 2 and . <= 100000 and . == floor) and
        (.manual_total_mbps | type == "number" and . >= 1 and . <= 100000 and . == floor) and
        (.manual_ip_mbps | type == "number" and . >= 0.1) and
        (.manual_ip_mbps <= .manual_total_mbps) and
        (.profile_exempt | type == "array" and length <= 1000 and all(.[]; type == "string" and test("^[A-Za-z0-9_.-]{1,64}$"))) and
        (.ip_exempt | type == "array" and length <= 100 and all(.[]; type == "string"))
    ' >/dev/null 2>&1 || return 1
    while IFS= read -r entry; do
        shaping_valid_ipv4_cidr "$entry" || return 1
    done < <(printf '%s\n' "$input" | jq -r '.ip_exempt[]')
}

shaping_normalize_config() {
    jq -c '{enabled,mode,channel_mbps,reserve_percent,expected_users,manual_total_mbps,manual_ip_mbps,profile_exempt:(.profile_exempt|unique),ip_exempt:(.ip_exempt|unique)}'
}

# Все значения в бит/с. Никакой коэффициент 1024 к сетевым Мбит/с не применяется.
shaping_rates() {
    local cfg="$1" active="${2:-0}"
    [[ "$active" =~ ^[0-9]+$ ]] || active=0
    printf '%s\n' "$cfg" | jq -c --argjson active "$active" '
        if .mode == "manual" then
            {total_bps:(.manual_total_mbps * 1000000 | floor),
             ip_bps:(.manual_ip_mbps * 1000000 | floor), denominator:null}
        else
            (.channel_mbps * (100 - .reserve_percent) * 10000 | floor) as $total |
            (if .mode == "dynamic" then ([.expected_users, $active] | max) else .expected_users end) as $n |
            {total_bps:$total, ip_bps:($total / $n | floor), denominator:$n}
        end'
}

shaping_superexpert_mode() {
    [ "${MTPROXYL_MODE:-manager}" = manager ] && [ "${SUPEREXPERT_ENABLED:-false}" = true ]
}

shaping_target_ready() {
    if [ "${MTPROXYL_MODE:-manager}" = reanimator ]; then
        [ -n "${DETECTED_CONFIG_PATH:-}" ] && [ -f "$DETECTED_CONFIG_PATH" ] || {
            log_error 'Конфиг telemt не найден: сначала выполните mtproxyl detect'; return 1; }
        [ "${DETECTED_MODE:-unknown}" != unknown ] || {
            log_error 'Цель telemt не обнаружена: сначала выполните mtproxyl detect'; return 1; }
    elif [ "${MTPROXYL_MODE:-manager}" = manager ]; then
        if [ "${SUPEREXPERT_ENABLED:-false}" = true ]; then
            _superexpert_active || {
                log_error 'Файл конфига Супер эксперта не найден'; return 1; }
            local config_path api_listen api_port
            config_path=$(engine_config_path)
            _telemt_api_enabled "$config_path" || {
                log_error 'В конфиге Супер эксперта нужен включённый локальный API telemt'; return 1; }
            api_listen=$(_toml_get_string_in_section server.api listen "$config_path")
            if [ -n "$api_listen" ] && [[ ! "$api_listen" =~ :[0-9]+$ ]]; then
                log_error 'В конфиге Супер эксперта нужен TCP-порт API telemt'
                return 1
            fi
            api_port=$(_get_telemt_api_port "$config_path")
            [[ "$api_port" =~ ^[1-9][0-9]{0,4}$ ]] && (( api_port <= 65535 )) || {
                log_error 'Некорректный порт API telemt в конфиге Супер эксперта'; return 1; }
        fi
    else
        log_error 'Неизвестный режим MTProxyL'
        return 1
    fi
}

shaping_public_ports() {
    if [ "${MTPROXYL_MODE:-manager}" = reanimator ]; then
        local internal="${DETECTED_PORT:-${PROXY_PORT:-}}" ports
        [[ "$internal" =~ ^[0-9]+$ ]] && (( internal >= 1 && internal <= 65535 )) || {
            log_error 'Публичный порт цели не определён: выполните mtproxyl detect'; return 1; }
        if [ "${DETECTED_NETWORK_MODE:-host}" = bridge ]; then
            [ -n "${DETECTED_CONTAINER:-}" ] && command -v docker >/dev/null || return 1
            ports=$(docker inspect "$DETECTED_CONTAINER" 2>/dev/null | jq -r --arg key "${internal}/tcp" \
                '.[0].HostConfig.PortBindings[$key][]?.HostPort // empty') || return 1
            [ -n "$ports" ] || {
                log_error "У цели в Docker bridge нет опубликованного TCP-порта ${internal}"; return 1; }
            printf '%s\n' "$ports"
        else
            printf '%s\n' "$internal"
        fi
        return
    fi
    if shaping_superexpert_mode; then
        local config_path port
        config_path=$(engine_config_path)
        port=$(_toml_get_string_in_section server port "$config_path")
        [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || {
            log_error 'Порт прокси не найден в рабочем конфиге Супер эксперта'; return 1; }
        printf '%s\n' "$port"
    else
        printf '%s\n' "${PROXY_PORT:-443}"
    fi
    if web_is_enabled 2>/dev/null; then web_public_port; fi
}

shaping_interface() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

shaping_root_kind() {
    tc -j qdisc show dev "$1" 2>/dev/null | jq -r '[.[] | select(.parent == "root" or .root == true)] | first | .kind // empty'
}

shaping_tc_owned() {
    tc -j qdisc show dev "$1" 2>/dev/null | jq -e 'any(.[]; (.parent == "root" or .root == true) and .kind == "htb" and .handle == "a11:")' >/dev/null
}

shaping_restore_original_qdisc() {
    local iface="$1" kind="$2"
    shaping_tc_owned "$iface" || return 0
    tc qdisc del dev "$iface" root >/dev/null 2>&1 || return 1
    case "$kind" in
        fq_codel|fq|pfifo_fast|mq)
            tc qdisc replace dev "$iface" root "$kind" >/dev/null 2>&1 || true ;;
    esac
}

shaping_assign_ips() {
    local map="$1" previous="$2" ip minor exempt next=256
    local -A old_ids=() used_ids=()
    while IFS=$'\t' read -r ip minor; do
        [ -n "$ip" ] || continue
        old_ids["$ip"]="$minor"
        used_ids["$minor"]=1
    done < <(printf '%s\n' "$previous" | jq -r '.ips[]? | [.ip, .minor] | @tsv')
    while IFS=$'\t' read -r ip exempt; do
        [ -n "$ip" ] || continue
        minor="${old_ids[$ip]:-}"
        if [ -z "$minor" ]; then
            while [ "${used_ids[$next]:-}" = 1 ]; do next=$((next + 1)); done
            [ "$next" -le 65534 ] || return 1
            minor="$next"
            used_ids["$minor"]=1
        fi
        printf '{"ip":"%s","minor":%s,"exempt":%s}\n' "$ip" "$minor" "$exempt"
    done < <(printf '%s\n' "$map" | jq -r '.[] | [.ip, .exempt] | @tsv')
}

shaping_tc_add_entry() {
    local iface="$1" ip="$2" minor="$3" exempt="$4" rate="$5" idx=0 port classid handle
    shift 5
    classid="a11:$(printf '%x' "$minor")"
    if [ "$exempt" != true ]; then
        tc class add dev "$iface" parent a11:10 classid "$classid" htb rate "${rate}bit" ceil "${rate}bit" quantum 15140 || return 1
        tc qdisc add dev "$iface" parent "$classid" fq_codel || return 1
    else
        classid=a11:30
    fi
    for port in "$@"; do
        handle=$(printf '0x%x' "$((minor * 8 + idx))")
        tc filter add dev "$iface" parent a11: protocol ip pref 1000 handle "$handle" flower \
            ip_proto tcp src_port "$port" dst_ip "$ip" classid "$classid" || return 1
        idx=$((idx + 1))
    done
}

shaping_tc_del_entry() {
    local iface="$1" minor="$2" exempt="$3" idx=0 port handle
    shift 3
    for port in "$@"; do
        handle=$(printf '0x%x' "$((minor * 8 + idx))")
        tc filter del dev "$iface" parent a11: protocol ip pref 1000 handle "$handle" flower || return 1
        idx=$((idx + 1))
    done
    if [ "$exempt" != true ]; then
        tc class del dev "$iface" parent a11:10 classid "a11:$(printf '%x' "$minor")" || return 1
    fi
}

shaping_tc_apply() {
    local cfg="$1" map="${2:-[]}" override_rate="${3:-}" iface kind previous original total rate port cidr priority=10 max_rate=100000000000
    local entries ports_json ports_raw ip minor exempt new_state
    local -a ports=()
    iface=$(shaping_interface)
    [ -n "$iface" ] && [ "$iface" != lo ] || { log_error 'Не найден внешний IPv4-интерфейс'; return 1; }
    previous='{}'
    [ -f "$SHAPING_TC_FILE" ] && previous=$(cat "$SHAPING_TC_FILE")
    [ "$(printf '%s\n' "$map" | jq 'length')" -le 4096 ] || { log_error 'Более 4096 активных IPv4: безопасное применение невозможно'; return 1; }
    entries=$(shaping_assign_ips "$map" "$previous" | jq -sc '.') || return 1
    rate=$(shaping_rates "$cfg" "$(printf '%s\n' "$map" | jq 'length')" | jq -r '.ip_bps') || return 1
    [ -n "$override_rate" ] && rate="$override_rate"
    [ "$rate" -ge 1 ] || return 1
    ports_raw=$(shaping_public_ports) || return 1
    mapfile -t ports < <(printf '%s\n' "$ports_raw" | sort -un)
    [ "${#ports[@]}" -gt 0 ] && [ "${#ports[@]}" -le 8 ] || return 1
    for port in "${ports[@]}"; do
        [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || return 1
    done
    ports_json=$(printf '%s\n' "${ports[@]}" | jq -Rsc '[split("\n")[] | select(length > 0) | tonumber]') || return 1
    local old_iface old_kind
    old_iface=$(printf '%s\n' "$previous" | jq -r '.interface // empty')
    old_kind=$(printf '%s\n' "$previous" | jq -r '.original_kind // empty')
    if [ -n "$old_iface" ] && [ "$old_iface" != "$iface" ]; then
        shaping_restore_original_qdisc "$old_iface" "$old_kind" || return 1
    fi
    kind=$(shaping_root_kind "$iface")
    if shaping_tc_owned "$iface"; then
        [ "$(printf '%s\n' "$previous" | jq -r '.interface // empty')" = "$iface" ] || {
            log_error "На $iface уже есть чужой HTB с нашим handle; не трогаем"; return 1; }
        original=$(printf '%s\n' "$previous" | jq -r '.original_kind // empty')
    else
        case "$kind" in
            fq_codel|fq|pfifo_fast|mq) original="$kind" ;;
            *) log_error "На $iface уже настроен qdisc '$kind'; автоматическая замена небезопасна"; return 1 ;;
        esac
    fi
    total=$(shaping_rates "$cfg" 0 | jq -r '.total_bps') || return 1
    # root HTB — только наш handle. При изменении списка исключений дерево
    # пересоздаётся; если какая-либо команда не удалась, вернём исходный qdisc.
    if shaping_tc_owned "$iface"; then
        tc qdisc del dev "$iface" root >/dev/null 2>&1 || return 1
    fi
    if ! tc qdisc replace dev "$iface" root handle a11: htb default 20; then
        shaping_restore_original_qdisc "$iface" "$original"
        return 1
    fi
    if ! tc class add dev "$iface" parent a11: classid a11:1 htb rate "${max_rate}bit" ceil "${max_rate}bit" quantum 15140 \
       || ! tc class add dev "$iface" parent a11:1 classid a11:10 htb rate "${total}bit" ceil "${total}bit" quantum 15140 \
       || ! tc class add dev "$iface" parent a11:1 classid a11:20 htb rate "${max_rate}bit" ceil "${max_rate}bit" quantum 15140 \
       || ! tc class add dev "$iface" parent a11:10 classid a11:30 htb rate "${total}bit" ceil "${total}bit" quantum 15140 \
       || ! tc class add dev "$iface" parent a11:10 classid a11:40 htb rate "${rate}bit" ceil "${rate}bit" quantum 15140; then
        shaping_restore_original_qdisc "$iface" "$original"; return 1
    fi
    for port in a11:20 a11:30 a11:40; do
        tc qdisc add dev "$iface" parent "$port" fq_codel >/dev/null 2>&1 || {
            shaping_restore_original_qdisc "$iface" "$original"; return 1; }
    done
    for port in "${ports[@]}"; do
        while IFS= read -r cidr; do
            if ! tc filter add dev "$iface" parent a11: protocol ip pref "$priority" flower \
                    ip_proto tcp src_port "$port" dst_ip "$cidr" classid a11:20; then
                shaping_restore_original_qdisc "$iface" "$original"; return 1
            fi
            priority=$((priority + 1))
        done < <(printf '%s\n' "$cfg" | jq -r '.ip_exempt[]')
    done
    while IFS=$'\t' read -r ip minor exempt; do
        [ -n "$ip" ] || continue
        if ! shaping_tc_add_entry "$iface" "$ip" "$minor" "$exempt" "$rate" "${ports[@]}"; then
            shaping_restore_original_qdisc "$iface" "$original"; return 1
        fi
    done < <(printf '%s\n' "$entries" | jq -r '.[] | [.ip, .minor, .exempt] | @tsv')
    for port in "${ports[@]}"; do
        if ! tc filter add dev "$iface" parent a11: protocol ip pref 10000 flower \
                ip_proto tcp src_port "$port" classid a11:40; then
            shaping_restore_original_qdisc "$iface" "$original"; return 1
        fi
    done
    new_state=$(printf '%s\n' "$entries" | jq -c --arg interface "$iface" --arg original_kind "$original" \
        --argjson rate_bps "$rate" --argjson total_bps "$total" --argjson ports "$ports_json" \
        '{interface:$interface,original_kind:$original_kind,ips:.,rate_bps:$rate_bps,total_bps:$total_bps,ports:$ports}') || {
        shaping_restore_original_qdisc "$iface" "$original"; return 1; }
    if ! shaping_atomic_json "$SHAPING_TC_FILE" "$new_state"; then
        shaping_restore_original_qdisc "$iface" "$original"
        return 1
    fi
}

# Новые IP и изменение лимита обновляем без пересоздания корневого qdisc:
# открытые соединения сохраняют очередь. При ошибке caller восстановит снимок.
shaping_tc_sync() {
    local cfg="$1" map="$2" rate="$3" old iface total old_rate ports_json ports_raw entries ip minor exempt old_minor old_exempt port new_state
    local -a ports=()
    local -A seen=() prior_minor=() prior_exempt=()
    [ "$(printf '%s\n' "$map" | jq 'length')" -le 4096 ] || return 1
    old='{}'; [ -f "$SHAPING_TC_FILE" ] && old=$(cat "$SHAPING_TC_FILE")
    iface=$(shaping_interface)
    ports_raw=$(shaping_public_ports) || return 1
    mapfile -t ports < <(printf '%s\n' "$ports_raw" | sort -un)
    [ "${#ports[@]}" -gt 0 ] && [ "${#ports[@]}" -le 8 ] || return 1
    for port in "${ports[@]}"; do
        [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || return 1
    done
    ports_json=$(printf '%s\n' "${ports[@]}" | jq -Rsc '[split("\n")[] | select(length > 0) | tonumber]') || return 1
    total=$(shaping_rates "$cfg" 0 | jq -r '.total_bps') || return 1
    if ! shaping_tc_owned "$iface" || [ "$(printf '%s\n' "$old" | jq -r '.interface // empty')" != "$iface" ] \
       || [ "$(printf '%s\n' "$old" | jq -c '.ports // []')" != "$ports_json" ] \
       || [ "$(printf '%s\n' "$old" | jq -r '.total_bps // 0')" != "$total" ]; then
        shaping_tc_apply "$cfg" "$map" "$rate"
        return
    fi
    entries=$(shaping_assign_ips "$map" "$old" | jq -sc '.') || return 1
    old_rate=$(printf '%s\n' "$old" | jq -r '.rate_bps // 0')
    if [ "$rate" = "$old_rate" ] && [ "$entries" = "$(printf '%s\n' "$old" | jq -c '.ips // []')" ]; then
        return 0
    fi
    while IFS=$'\t' read -r ip minor exempt; do
        [ -n "$ip" ] || continue
        prior_minor["$ip"]="$minor"
        prior_exempt["$ip"]="$exempt"
    done < <(printf '%s\n' "$old" | jq -r '.ips[]? | [.ip, .minor, .exempt] | @tsv')
    if [ "$rate" != "$old_rate" ]; then
        tc class change dev "$iface" parent a11:10 classid a11:40 htb rate "${rate}bit" ceil "${rate}bit" quantum 15140 || return 1
        for ip in "${!prior_minor[@]}"; do
            [ "${prior_exempt[$ip]}" = true ] && continue
            tc class change dev "$iface" parent a11:10 classid "a11:$(printf '%x' "${prior_minor[$ip]}")" \
                htb rate "${rate}bit" ceil "${rate}bit" quantum 15140 || return 1
        done
    fi
    while IFS=$'\t' read -r ip minor exempt; do
        [ -n "$ip" ] || continue
        seen["$ip"]=1
        old_minor="${prior_minor[$ip]:-}"
        old_exempt="${prior_exempt[$ip]:-}"
        if [ -n "$old_minor" ] && [ "$old_exempt" = "$exempt" ]; then continue; fi
        if [ -n "$old_minor" ]; then
            shaping_tc_del_entry "$iface" "$old_minor" "$old_exempt" "${ports[@]}" || return 1
        fi
        shaping_tc_add_entry "$iface" "$ip" "$minor" "$exempt" "$rate" "${ports[@]}" || return 1
    done < <(printf '%s\n' "$entries" | jq -r '.[] | [.ip, .minor, .exempt] | @tsv')
    for ip in "${!prior_minor[@]}"; do
        [ "${seen[$ip]:-}" = 1 ] && continue
        shaping_tc_del_entry "$iface" "${prior_minor[$ip]}" "${prior_exempt[$ip]}" "${ports[@]}" || return 1
    done
    new_state=$(printf '%s\n' "$old" | jq -c --slurpfile ips <(printf '%s\n' "$entries") \
        --argjson rate "$rate" '.ips=$ips[0] | .rate_bps=$rate') || return 1
    shaping_atomic_json "$SHAPING_TC_FILE" "$new_state"
}

shaping_tc_disable() {
    local state iface kind
    [ -f "$SHAPING_TC_FILE" ] || return 0
    state=$(cat "$SHAPING_TC_FILE")
    iface=$(printf '%s\n' "$state" | jq -r '.interface // empty')
    kind=$(printf '%s\n' "$state" | jq -r '.original_kind // empty')
    [ -n "$iface" ] || return 1
    if shaping_tc_owned "$iface"; then
        shaping_restore_original_qdisc "$iface" "$kind" || return 1
    elif [ -n "$(shaping_root_kind "$iface")" ]; then
        log_warn "qdisc на $iface изменён извне; оставляем его нетронутым"
    fi
    rm -f "$SHAPING_TC_FILE"
}

shaping_stop_runtime() {
    local unit shaping_fd
    systemctl disable --now mtproxyl-shaping-update.timer mtproxyl-shaping-update.service \
        mtproxyl-shaping.service >/dev/null 2>&1 || true
    for unit in mtproxyl-shaping-update.timer mtproxyl-shaping-update.service mtproxyl-shaping.service; do
        if systemctl is-active --quiet "$unit"; then
            log_error "Не удалось остановить $unit; операция остановлена"
            return 1
        fi
    done
    if [ -f "$SHAPING_TC_FILE" ]; then
        exec {shaping_fd}>"$SHAPING_LOCK_FILE" || return 1
        if ! flock -w 30 "$shaping_fd" || ! shaping_tc_disable; then
            exec {shaping_fd}>&-
            log_error 'Не удалось снять ограничения tc; операция остановлена'
            return 1
        fi
        exec {shaping_fd}>&-
    fi
}

shaping_uninstall() {
    shaping_stop_runtime || return 1
    rm -f "$SHAPING_BOOT_UNIT" "$SHAPING_TICK_UNIT" "$SHAPING_TIMER_UNIT" || return 1
    systemctl daemon-reload >/dev/null 2>&1 || true
}

shaping_write_units() {
    cat > "$SHAPING_BOOT_UNIT" <<'UNIT' || return 1
[Unit]
Description=MTProxyL traffic shaping
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mtproxyl shaping restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    cat > "$SHAPING_TICK_UNIT" <<'UNIT' || return 1
[Unit]
Description=MTProxyL per-IP traffic shaping update
After=mtproxyl-shaping.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mtproxyl shaping tick
UNIT
    cat > "$SHAPING_TIMER_UNIT" <<'UNIT' || return 1
[Unit]
Description=Update MTProxyL per-IP speed limits

[Timer]
OnBootSec=45s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=mtproxyl-shaping-update.service

[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload && systemctl enable mtproxyl-shaping.service >/dev/null 2>&1
}

shaping_sync_timer() {
    local cfg="$1"
    if printf '%s\n' "$cfg" | jq -e '.enabled' >/dev/null; then
        systemctl enable --now mtproxyl-shaping-update.timer >/dev/null 2>&1
    else
        systemctl disable --now mtproxyl-shaping-update.timer >/dev/null 2>&1 || true
    fi
}

shaping_signal_telemt() {
    if engine_is_binary; then
        if binengine_running; then
            systemctl kill -s HUP "$ENGINE_SERVICE"
        fi
    elif is_proxy_running; then
        docker kill -s SIGHUP "$CONTAINER_NAME" >/dev/null 2>&1
    fi
}

shaping_reload_telemt() {
    generate_telemt_config || return 1
    shaping_signal_telemt
}

shaping_apply() (
    local input cfg old old_state old_tc old_map map now config_path config_snapshot='' tc_ok=false telemt_ok=false rollback_ok=true manage_config=true
    command -v jq >/dev/null && command -v tc >/dev/null && command -v ip >/dev/null \
        && command -v flock >/dev/null && command -v systemctl >/dev/null || {
        log_error 'Нужны jq, iproute2 (ip/tc), flock и systemd'; return 1; }
    input=$(head -c 65536) || return 1
    shaping_validate_config "$input" || { log_error 'Неверные параметры ограничения скорости'; return 1; }
    cfg=$(printf '%s\n' "$input" | shaping_normalize_config) || return 1
    if printf '%s\n' "$cfg" | jq -e '.enabled' >/dev/null; then
        shaping_target_ready || return 1
        shaping_public_ports >/dev/null || return 1
        map=$(shaping_fetch_active_map "$cfg") || {
            log_error 'API telemt недоступен: нельзя включить персональный лимит IP без списка клиентов'; return 1; }
        [ "$(printf '%s\n' "$map" | jq 'length')" -le 4096 ] || {
            log_error 'Более 4096 активных IPv4: нельзя включить шейпинг'; return 1; }
    fi
    mkdir -p "$INSTALL_DIR" || return 1
    exec {shaping_fd}>"$SHAPING_LOCK_FILE"
    flock -w 30 "$shaping_fd" || { log_error 'Настройка ограничения скорости занята'; return 1; }
    old=$(shaping_config)
    old_state='{}'; [ -f "$SHAPING_STATE_FILE" ] && old_state=$(cat "$SHAPING_STATE_FILE")
    old_tc=''; [ -f "$SHAPING_TC_FILE" ] && old_tc=$(cat "$SHAPING_TC_FILE")
    old_map='[]'; [ -n "$old_tc" ] && old_map=$(printf '%s\n' "$old_tc" | jq -c '[.ips[]? | {ip,exempt}]')
    config_path=''
    if [ "${MTPROXYL_MODE:-manager}" = reanimator ] || shaping_superexpert_mode; then
        manage_config=false
    else
        config_path=$(engine_config_path)
    fi
    if [ -n "$config_path" ] && [ -f "$config_path" ]; then
        config_snapshot=$(mktemp "${INSTALL_DIR}/.shaping-config.XXXXXX") || return 1
        trap '[ -z "$config_snapshot" ] || rm -f "$config_snapshot"' EXIT
        cp -p "$config_path" "$config_snapshot" || return 1
    fi
    shaping_atomic_json "$SHAPING_FILE" "$cfg" || return 1
    if printf '%s\n' "$cfg" | jq -e '.enabled' >/dev/null; then
        if shaping_tc_apply "$cfg" "$map"; then tc_ok=true; fi
        if [ "$tc_ok" = true ]; then
            if [ "$manage_config" = false ] || shaping_reload_telemt; then telemt_ok=true; fi
        fi
        if [ "$telemt_ok" != true ]; then
            shaping_atomic_json "$SHAPING_FILE" "$old" || rollback_ok=false
            if [ -n "$old_tc" ]; then
                shaping_atomic_json "$SHAPING_TC_FILE" "$old_tc" || rollback_ok=false
                if printf '%s\n' "$old" | jq -e '.enabled' >/dev/null; then
                    shaping_tc_apply "$old" "$old_map" || rollback_ok=false
                else
                    shaping_tc_disable || rollback_ok=false
                fi
            else
                shaping_tc_disable || rollback_ok=false
            fi
            if [ "$tc_ok" = true ] && [ -n "$config_snapshot" ]; then
                cp -p "$config_snapshot" "$config_path" && shaping_signal_telemt || rollback_ok=false
            fi
            if [ "$rollback_ok" = true ]; then
                log_error 'Не удалось применить ограничение; прежние настройки восстановлены'
            else
                log_error 'Не удалось применить или полностью восстановить ограничение; проверьте tc и config.toml'
            fi
            return 1
        fi
        now=$(date +%s)
        shaping_atomic_json "$SHAPING_STATE_FILE" "$(printf '%s\n' "$old_state" | jq -c \
            --argjson n "$(printf '%s\n' "$map" | jq 'length')" --argjson now "$now" \
            '. + {active_ips:$n,pending_ips:null,last_sample_epoch:$now,last_update_epoch:$now,last_error:null}')"
        if ! shaping_write_units || ! shaping_sync_timer "$cfg"; then
            log_warn 'Ограничение действует сейчас, но не удалось настроить автозапуск; проверьте systemd'
        fi
    else
        shaping_sync_timer "$cfg"
        if shaping_tc_disable; then tc_ok=true; fi
        if [ "$tc_ok" = true ]; then
            if [ "$manage_config" = false ] || shaping_reload_telemt; then telemt_ok=true; fi
        fi
        if [ "$telemt_ok" != true ]; then
            shaping_atomic_json "$SHAPING_FILE" "$old" || rollback_ok=false
            if [ -n "$old_tc" ]; then
                shaping_atomic_json "$SHAPING_TC_FILE" "$old_tc" || rollback_ok=false
                if printf '%s\n' "$old" | jq -e '.enabled' >/dev/null; then
                    shaping_tc_apply "$old" "$old_map" || rollback_ok=false
                else
                    shaping_tc_disable || rollback_ok=false
                fi
            fi
            if [ "$tc_ok" = true ] && [ -n "$config_snapshot" ]; then
                cp -p "$config_snapshot" "$config_path" && shaping_signal_telemt || rollback_ok=false
            fi
            shaping_sync_timer "$old" || rollback_ok=false
            if [ "$rollback_ok" = true ]; then
                log_error 'Не удалось выключить ограничение; прежние настройки восстановлены'
            else
                log_error 'Не удалось выключить или полностью восстановить ограничение; проверьте tc и config.toml'
            fi
            return 1
        fi
        systemctl disable --now mtproxyl-shaping.service >/dev/null 2>&1 || true
    fi
    log_success "Ограничение скорости $([ "$(printf '%s\n' "$cfg" | jq -r '.enabled')" = true ] && echo включено || echo выключено)"
)

shaping_fetch_active_map() {
    local cfg="$1" auth response port="${PROXY_API_PORT:-9091}" host=127.0.0.1 exempt config_path
    if [ "${MTPROXYL_MODE:-manager}" = reanimator ]; then
        config_path="${DETECTED_CONFIG_PATH:-}"
        _telemt_api_enabled "$config_path" || return 1
        port=$(_get_telemt_api_port "$config_path")
        host=$(_telemt_api_host "$config_path")
    else
        config_path=$(engine_config_path)
        if shaping_superexpert_mode; then
            _telemt_api_enabled "$config_path" || return 1
            port=$(_get_telemt_api_port "$config_path")
        fi
    fi
    auth=$(_get_telemt_auth_header "$config_path" 2>/dev/null)
    local -a headers=()
    [ -n "$auth" ] && headers=(-H "Authorization: $auth")
    response=$(curl -fsS --max-time 5 --connect-timeout 2 "${headers[@]}" \
        "http://${host}:${port}/v1/stats/users/active-ips") || return 1
    exempt=$(printf '%s\n' "$cfg" | jq -c '.profile_exempt') || return 1
    printf '%s\n' "$response" | jq -ce --argjson exempt "$exempt" '
        if .ok == true and (.data | type == "array") then
            [.data[] | select(.username | type == "string") | .username as $user | .active_ips[]? |
                select(type == "string") |
                select(test("^((0|[1-9][0-9]{0,2})\\.){3}(0|[1-9][0-9]{0,2})$") and
                    (split(".") | all(.[]; tonumber <= 255))) |
                {ip:., exempt: ($exempt | index($user) != null)}] |
            group_by(.ip) | map({ip:.[0].ip, exempt:all(.[]; .exempt)})
        else error("invalid telemt response") end
    ' 2>/dev/null
}

shaping_tick() (
    local cfg map active old_rate new_rate target_rate pending now state tc_state old_map last_update
    cfg=$(shaping_config)
    printf '%s\n' "$cfg" | jq -e '.enabled' >/dev/null 2>&1 || return 0
    exec {shaping_fd}>"$SHAPING_LOCK_FILE"
    flock -n "$shaping_fd" || return 0
    state='{}'; [ -f "$SHAPING_STATE_FILE" ] && state=$(cat "$SHAPING_STATE_FILE")
    tc_state='{}'; [ -f "$SHAPING_TC_FILE" ] && tc_state=$(cat "$SHAPING_TC_FILE")
    if ! map=$(shaping_fetch_active_map "$cfg"); then
        shaping_atomic_json "$SHAPING_STATE_FILE" "$(printf '%s\n' "$state" | jq -c '.last_error = "API telemt недоступен; сохранён предыдущий лимит"')"
        return 1
    fi
    active=$(printf '%s\n' "$map" | jq 'length')
    if [ "$active" -gt 4096 ]; then
        shaping_atomic_json "$SHAPING_STATE_FILE" "$(printf '%s\n' "$state" | jq -c '.last_error = "Более 4096 активных IPv4; сохранены предыдущие правила tc"')"
        return 1
    fi
    now=$(date +%s)
    old_rate=$(printf '%s\n' "$tc_state" | jq -r '.rate_bps // 0')
    new_rate=$(shaping_rates "$cfg" "$active" | jq -r '.ip_bps')
    [ "$old_rate" -ge 1 ] || old_rate="$new_rate"
    target_rate="$new_rate"
    pending=$(printf '%s\n' "$state" | jq -r '.pending_ips // -1')
    last_update=$(printf '%s\n' "$state" | jq -r '.last_update_epoch // 0')
    # Рост лимита подтверждаем двумя замерами; уменьшение применяем сразу.
    if (( new_rate > old_rate )) && [ "$pending" != "$active" ]; then
        target_rate="$old_rate"
        pending="$active"
    fi
    if (( new_rate > old_rate && now - last_update < 60 )); then
        target_rate="$old_rate"
    fi
    old_map=$(printf '%s\n' "$tc_state" | jq -c '[.ips[]? | {ip,exempt}]')
    if ! shaping_tc_sync "$cfg" "$map" "$target_rate"; then
        if shaping_tc_apply "$cfg" "$old_map" "$old_rate" >/dev/null 2>&1; then
            shaping_atomic_json "$SHAPING_STATE_FILE" "$(printf '%s\n' "$state" | jq -c '.last_error = "Не удалось обновить классы tc; предыдущие правила восстановлены"')"
        else
            shaping_atomic_json "$SHAPING_STATE_FILE" "$(printf '%s\n' "$state" | jq -c '.last_error = "Не удалось обновить или восстановить классы tc; проверьте journalctl -u mtproxyl-shaping-update.service"')"
        fi
        return 1
    fi
    if [ "$target_rate" != "$old_rate" ]; then last_update="$now"; fi
    [ "$target_rate" = "$new_rate" ] && pending=-1
    shaping_atomic_json "$SHAPING_STATE_FILE" "$(printf '%s\n' "$state" | jq -c \
        --argjson n "$active" --argjson pending "$pending" --argjson now "$now" --argjson updated "$last_update" \
        '. + {active_ips:$n,pending_ips:(if $pending == -1 then null else $pending end),last_sample_epoch:$now,last_update_epoch:$updated,last_error:null}')"
)

shaping_restore() (
    local cfg map state rate
    cfg=$(shaping_config)
    printf '%s\n' "$cfg" | jq -e '.enabled' >/dev/null 2>&1 || return 0
    shaping_target_ready || return 1
    exec {shaping_fd}>"$SHAPING_LOCK_FILE"
    flock -w 30 "$shaping_fd" || return 1
    state='{}'; [ -f "$SHAPING_TC_FILE" ] && state=$(cat "$SHAPING_TC_FILE")
    map=$(shaping_fetch_active_map "$cfg" 2>/dev/null) || map=$(printf '%s\n' "$state" | jq -c '[.ips[]? | {ip,exempt}]')
    rate=$(printf '%s\n' "$state" | jq -r '.rate_bps // 0')
    [ "$rate" -ge 1 ] || rate=$(shaping_rates "$cfg" "$(printf '%s\n' "$map" | jq 'length')" | jq -r '.ip_bps')
    shaping_tc_sync "$cfg" "$map" "$rate" || return 1
    shaping_sync_timer "$cfg" || log_warn 'Не удалось запустить обновление списка IP'
)

shaping_available_profiles() {
    local config_path
    if [ "${MTPROXYL_MODE:-manager}" = reanimator ]; then
        config_path="${DETECTED_CONFIG_PATH:-}"
    else
        config_path=$(engine_config_path)
    fi
    [ -n "$config_path" ] && [ -f "$config_path" ] || { printf '[]\n'; return 0; }
    _target_section_pairs access.users "$config_path" \
        | awk -F'|' '$1 == "on" && $2 ~ /^[A-Za-z0-9_.-]+$/ {print $2}' \
        | LC_ALL=C sort -u \
        | jq -Rsc '[split("\n")[] | select(length > 0)]'
}

shaping_status_json() {
    local cfg state tc_state rates active iface root applied tracked profiles
    cfg=$(shaping_config)
    state='{}'; [ -f "$SHAPING_STATE_FILE" ] && state=$(cat "$SHAPING_STATE_FILE")
    tc_state='{}'; [ -f "$SHAPING_TC_FILE" ] && tc_state=$(cat "$SHAPING_TC_FILE")
    active=$(printf '%s\n' "$state" | jq -r '.active_ips // 0')
    rates=$(shaping_rates "$cfg" "$active")
    applied=$(printf '%s\n' "$tc_state" | jq -r '.rate_bps // 0')
    tracked=$(printf '%s\n' "$tc_state" | jq -r '.ips // [] | length')
    if [ "$applied" -ge 1 ] && [ "$(printf '%s\n' "$cfg" | jq -r '.enabled')" = true ]; then
        rates=$(printf '%s\n' "$rates" | jq -c --argjson applied "$applied" '.ip_bps=$applied')
    fi
    iface=$(printf '%s\n' "$tc_state" | jq -r '.interface // empty')
    profiles=$(shaping_available_profiles) || return 1
    root=false
    if [ -n "$iface" ] && [ "$applied" -ge 1 ] && shaping_tc_owned "$iface"; then root=true; fi
    jq -nc --argjson config "$cfg" --argjson state "$state" --argjson rates "$rates" \
        --argjson available_profiles "$profiles" \
        --argjson tc_active "$root" --argjson tracked_ips "$tracked" --arg interface "$iface" \
        '{config:$config,state:$state,rates:$rates,available_profiles:$available_profiles,tc_active:$tc_active,tracked_ips:$tracked_ips,interface:$interface}'
}

# Главный экран показывает расчёт и фактически применённый лимит раздельно:
# при росте скорости tc ждёт второго замера, а после перезагрузки может быть неактивен.
shaping_home_summary() {
    local cfg status
    cfg=$(shaping_config) || return 1
    printf '%s\n' "$cfg" | jq -e '.enabled == true' >/dev/null 2>&1 || return 0
    status=$(shaping_status_json) || return 1
    printf '%s\n' "$status" | jq -r '
        def mbps: (. / 1000000 | tostring);
        if .config.enabled != true then empty else
        . as $s |
        ($s.rates.total_bps | mbps) as $total |
        ($s.rates.denominator // $s.config.expected_users) as $n |
        (if $s.config.mode == "manual" then
            "вручную: общий потолок \($total) Мбит/с; на IP задано \($s.config.manual_ip_mbps) Мбит/с"
        elif $s.config.mode == "fixed" then
            "канал \($s.config.channel_mbps) Мбит/с − резерв \($s.config.reserve_percent)% = \($total) Мбит/с; \($total) ÷ \($n) ожидаемых IP = \(($s.rates.total_bps / $n | floor) | mbps) Мбит/с/IP"
        else
            "канал \($s.config.channel_mbps) Мбит/с − резерв \($s.config.reserve_percent)% = \($total) Мбит/с; \($total) ÷ max(\($s.config.expected_users) минимум, \($s.state.active_ips // 0) активных по замеру) = \(($s.rates.total_bps / $n | floor) | mbps) Мбит/с/IP"
        end) as $formula |
        (if $s.tc_active then "выставлено: \($s.rates.ip_bps | mbps) Мбит/с/IP"
         else "tc не активен — лимит сейчас не применяется" end) as $applied |
        "\($formula)\t\($applied)"
        end
    '
}

shaping_menu() {
    local cfg mode channel reserve expected ip_limit total answer profiles ips
    cfg=$(shaping_config)
    echo '  Ограничение скорости: отключено по умолчанию; только отдача IPv4 клиентам.'
    shaping_status_json | jq -r '"  Режим: \(.config.mode), активных IP: \(.state.active_ips // 0), лимит одного IP: \(.rates.ip_bps / 1000000) Мбит/с"'
    echo '  [1] Ручной лимит'
    echo '  [2] Формула по ожидаемому числу пользователей'
    echo '  [3] Динамический расчёт по активным IP'
    echo '  [4] Выключить'
    read -r -p 'Выбор [0]: ' answer
    case "$answer" in
        1) mode=manual ;;
        2) mode=fixed ;;
        3) mode=dynamic ;;
        4) printf '%s\n' "$cfg" | jq '.enabled=false' | shaping_apply; return ;;
        *) return 0 ;;
    esac
    if [ "$mode" = manual ]; then
        read -r -p 'Общий потолок, Мбит/с: ' total
        read -r -p 'Лимит одного IPv4, Мбит/с: ' ip_limit
        cfg=$(printf '%s\n' "$cfg" | jq --argjson total "$total" --argjson ip_limit "$ip_limit" '.manual_total_mbps=$total | .manual_ip_mbps=$ip_limit') || return 1
    else
        read -r -p 'Ширина канала, Мбит/с (1 Гбит/с = 1000): ' channel
        read -r -p 'Резерв канала, % [10]: ' reserve
        read -r -p 'Ожидаемое / минимальное число пользователей [10]: ' expected
        cfg=$(printf '%s\n' "$cfg" | jq --argjson channel "$channel" --argjson reserve "${reserve:-10}" --argjson expected "${expected:-10}" '.channel_mbps=$channel | .reserve_percent=$reserve | .expected_users=$expected') || return 1
    fi
    read -r -p 'Профили без персонального лимита (через запятую, пусто — нет): ' profiles
    read -r -p 'IPv4/CIDR без общего потолка (через запятую, пусто — нет): ' ips
    cfg=$(printf '%s\n' "$cfg" | jq --arg mode "$mode" --arg profiles "$profiles" --arg ips "$ips" \
        '.enabled=true | .mode=$mode | .profile_exempt=($profiles|split(",")|map(gsub("^ +| +$";"")|select(length>0))) | .ip_exempt=($ips|split(",")|map(gsub("^ +| +$";"")|select(length>0)))') || return 1
    printf '%s\n' "$cfg" | shaping_apply
}

shaping_cli_help() {
    cat <<'EOF'
Использование:
  mtproxyl shaping status [--json]
  mtproxyl shaping set [manual|fixed|dynamic] [параметры]
  mtproxyl shaping off
  mtproxyl shaping exempt add|remove profile|ip ЗНАЧЕНИЕ
  mtproxyl shaping menu

Параметры set (включает шейпинг; неуказанные значения сохраняются):
  --total N       общий потолок, Мбит/с (manual)
  --ip N          лимит одного IPv4, Мбит/с (manual)
  --channel N     ширина канала, Мбит/с (fixed/dynamic)
  --reserve N     резерв 0..90% (fixed/dynamic)
  --users N       ожидаемое/минимальное число IP, от 2 (fixed/dynamic)
  --exempt-profile ИМЯ   повторять для замены списка профилей
  --exempt-ip IPv4/CIDR  повторять для замены списка адресов
  --clear-profiles       очистить список профилей
  --clear-ips            очистить список адресов

Примеры:
  mtproxyl shaping set manual --total 900 --ip 9
  mtproxyl shaping set dynamic --channel 1000 --reserve 10 --users 100
  mtproxyl shaping exempt add profile admin
  mtproxyl shaping exempt remove ip 203.0.113.5

Для автоматизации также доступен: mtproxyl shaping apply < конфиг.json
EOF
}

shaping_cli_check_number() {
    local flag="$1" value="$2" min max
    case "$flag" in
        --total|--channel) min=1; max=100000 ;;
        --users) min=2; max=100000 ;;
        --reserve) min=0; max=90 ;;
        --ip)
            [[ "$value" =~ ^(0\.[0-9]{1,6}|[1-9][0-9]{0,5}(\.[0-9]{1,6})?)$ ]] \
                && awk -v v="$value" 'BEGIN { exit !(v >= 0.1 && v <= 100000) }' && return 0
            log_error '--ip: ожидается число от 0.1 до 100000 Мбит/с'
            return 1 ;;
    esac
    [[ "$value" =~ ^(0|[1-9][0-9]{0,5})$ ]] && (( value >= min && value <= max )) && return 0
    log_error "$flag: ожидается целое число ${min}..${max}"
    return 1
}

shaping_cli_apply_config() {
    local cfg="$1" ensure="${2:-false}" current
    shaping_validate_config "$cfg" || {
        log_error 'Неверные параметры шейпинга: проверьте лимиты и исключения'
        return 1
    }
    cfg=$(printf '%s\n' "$cfg" | shaping_normalize_config) || return 1
    current=$(shaping_config | shaping_normalize_config) || return 1
    if [ "$cfg" = "$current" ]; then
        if [ "$ensure" = true ] && [ "$(printf '%s\n' "$cfg" | jq -r '.enabled')" = true ]; then
            shaping_restore
        elif [ -f "$SHAPING_TC_FILE" ] && [ "$(printf '%s\n' "$cfg" | jq -r '.enabled')" = false ]; then
            printf '%s\n' "$cfg" | shaping_apply
        else
            log_info 'Настройки шейпинга не изменились'
        fi
        return
    fi
    printf '%s\n' "$cfg" | shaping_apply
}

shaping_cli_set() {
    local cfg mode flag value field profiles_changed=false ips_changed=false manual_arg=false formula_arg=false
    local profiles_json ips_json
    local -a profiles=() ips=()
    cfg=$(shaping_config) || return 1
    mode=$(printf '%s\n' "$cfg" | jq -r '.mode') || return 1
    if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then mode="$1"; shift; fi
    while [ "$#" -gt 0 ]; do
        flag="$1"
        case "$flag" in
            --help|-h) shaping_cli_help; return 0 ;;
            --clear-profiles) profiles_changed=true; profiles=(); shift; continue ;;
            --clear-ips) ips_changed=true; ips=(); shift; continue ;;
            --mode|--total|--ip|--channel|--reserve|--users|--exempt-profile|--exempt-ip)
                [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || {
                    log_error "$flag: укажите значение"; return 1; }
                value="$2"; shift 2 ;;
            *) log_error "Неизвестный параметр шейпинга: $flag"; return 1 ;;
        esac
        case "$flag" in
            --mode) mode="$value" ;;
            --total|--ip|--channel|--reserve|--users)
                shaping_cli_check_number "$flag" "$value" || return 1
                case "$flag" in
                    --total) field=manual_total_mbps; manual_arg=true ;;
                    --ip) field=manual_ip_mbps; manual_arg=true ;;
                    --channel) field=channel_mbps; formula_arg=true ;;
                    --reserve) field=reserve_percent; formula_arg=true ;;
                    --users) field=expected_users; formula_arg=true ;;
                esac
                cfg=$(printf '%s\n' "$cfg" | jq -c --arg value "$value" ".${field} = (\$value | tonumber)") || return 1 ;;
            --exempt-profile)
                [[ "$value" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || {
                    log_error "Недопустимое имя профиля: $value"; return 1; }
                profiles_changed=true; profiles+=("$value") ;;
            --exempt-ip)
                shaping_valid_ipv4_cidr "$value" || {
                    log_error "Недопустимый IPv4/CIDR: $value"; return 1; }
                ips_changed=true; ips+=("$value") ;;
        esac
    done
    case "$mode" in
        manual) [ "$formula_arg" = false ] || {
            log_error 'В manual используйте --total и --ip, не параметры формулы'; return 1; } ;;
        fixed|dynamic) [ "$manual_arg" = false ] || {
            log_error 'В fixed/dynamic используйте --channel, --reserve и --users'; return 1; } ;;
        *) log_error 'Режим шейпинга: manual, fixed или dynamic'; return 1 ;;
    esac
    if [ "$profiles_changed" = true ]; then
        profiles_json=$(printf '%s\n' "${profiles[@]}" | jq -Rsc '[split("\n")[] | select(length > 0)] | unique') || return 1
        cfg=$(printf '%s\n' "$cfg" | jq -c --argjson list "$profiles_json" '.profile_exempt=$list') || return 1
    fi
    if [ "$ips_changed" = true ]; then
        ips_json=$(printf '%s\n' "${ips[@]}" | jq -Rsc '[split("\n")[] | select(length > 0)] | unique') || return 1
        cfg=$(printf '%s\n' "$cfg" | jq -c --argjson list "$ips_json" '.ip_exempt=$list') || return 1
    fi
    cfg=$(printf '%s\n' "$cfg" | jq -c --arg mode "$mode" '.enabled=true | .mode=$mode') || return 1
    shaping_cli_apply_config "$cfg" true
}

shaping_cli_exempt() {
    [ "$#" -eq 3 ] || { log_error 'Использование: shaping exempt add|remove profile|ip ЗНАЧЕНИЕ'; return 1; }
    local action="$1" kind="$2" value="$3" field cfg
    case "$action" in add|remove) ;; *) log_error 'Исключение: add или remove'; return 1 ;; esac
    case "$kind" in
        profile)
            [[ "$value" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { log_error "Недопустимое имя профиля: $value"; return 1; }
            field=profile_exempt ;;
        ip)
            shaping_valid_ipv4_cidr "$value" || { log_error "Недопустимый IPv4/CIDR: $value"; return 1; }
            field=ip_exempt ;;
        *) log_error 'Тип исключения: profile или ip'; return 1 ;;
    esac
    cfg=$(shaping_config) || return 1
    if [ "$action" = add ]; then
        cfg=$(printf '%s\n' "$cfg" | jq -c --arg value "$value" ".${field} |= (. + [\$value] | unique)") || return 1
    else
        cfg=$(printf '%s\n' "$cfg" | jq -c --arg value "$value" ".${field} |= map(select(. != \$value))") || return 1
    fi
    shaping_cli_apply_config "$cfg"
}

handle_shaping_command() {
    case "${1:-status}" in
        status) if [ "${2:-}" = --json ]; then shaping_status_json; else shaping_status_json | jq .; fi ;;
        apply) shaping_apply ;;
        set|on) shift; shaping_cli_set "$@" ;;
        exempt) shift; shaping_cli_exempt "$@" ;;
        off|disable) shaping_cli_apply_config "$(shaping_config | jq -c '.enabled=false')" ;;
        tick) shaping_tick ;;
        restore) shaping_restore ;;
        menu) shaping_menu ;;
        help|-h|--help) shaping_cli_help ;;
        *) shaping_cli_help >&2; return 1 ;;
    esac
}
