#!/bin/bash
# Ограничение отдачи клиентам: telemt ограничивает профиль, tc — общий канал.
# Файлы принадлежат менеджеру; чужой конфиг в режиме reanimator не меняем.

SHAPING_FILE="${INSTALL_DIR}/shaping.json"
SHAPING_STATE_FILE="${INSTALL_DIR}/shaping-state.json"
SHAPING_TC_FILE="${INSTALL_DIR}/shaping-tc.json"
SHAPING_LOCK_FILE="${INSTALL_DIR}/.shaping.lock"
SHAPING_BOOT_UNIT=/etc/systemd/system/mtproxyl-shaping.service
SHAPING_TICK_UNIT=/etc/systemd/system/mtproxyl-shaping-update.service
SHAPING_TIMER_UNIT=/etc/systemd/system/mtproxyl-shaping-update.timer

shaping_default_config() {
    printf '%s\n' '{"enabled":false,"mode":"manual","channel_mbps":1000,"reserve_percent":10,"expected_users":10,"manual_total_mbps":900,"manual_profile_mbps":90,"profile_exempt":[],"ip_exempt":[]}'
}

shaping_config() {
    if [ -f "$SHAPING_FILE" ]; then cat "$SHAPING_FILE"; else shaping_default_config; fi
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
        (.manual_profile_mbps | type == "number" and . >= 0.1) and
        (.manual_profile_mbps <= .manual_total_mbps) and
        (.profile_exempt | type == "array" and length <= 1000 and all(.[]; type == "string" and test("^[A-Za-z0-9_-]{1,32}$"))) and
        (.ip_exempt | type == "array" and length <= 100 and all(.[]; type == "string"))
    ' >/dev/null 2>&1 || return 1
    while IFS= read -r entry; do
        shaping_valid_ipv4_cidr "$entry" || return 1
    done < <(printf '%s\n' "$input" | jq -r '.ip_exempt[]')
}

shaping_normalize_config() {
    jq -c '{enabled,mode,channel_mbps,reserve_percent,expected_users,manual_total_mbps,manual_profile_mbps,profile_exempt:(.profile_exempt|unique),ip_exempt:(.ip_exempt|unique)}'
}

# Все значения в бит/с. Никакой коэффициент 1024 к сетевым Мбит/с не применяется.
shaping_rates() {
    local cfg="$1" active="${2:-0}"
    [[ "$active" =~ ^[0-9]+$ ]] || active=0
    printf '%s\n' "$cfg" | jq -c --argjson active "$active" '
        if .mode == "manual" then
            {total_bps:(.manual_total_mbps * 1000000 | floor),
             profile_bps:(.manual_profile_mbps * 1000000 | floor), denominator:null}
        else
            (.channel_mbps * (100 - .reserve_percent) * 10000 | floor) as $total |
            (if .mode == "dynamic" then ([.expected_users, $active] | max) else .expected_users end) as $n |
            {total_bps:$total, profile_bps:($total / $n | floor), denominator:$n}
        end'
}

# Вызывается из единственного генератора config.toml, включая при изменении
# других настроек. Состояние IP сохраняется отдельно, поэтому регенерация его
# не сбрасывает. При выключении секция telemt полностью отсутствует.
shaping_emit_user_limits() {
    local output="$1" cfg state active rate i name
    cfg=$(shaping_config) || return 1
    printf '%s\n' "$cfg" | jq -e '.enabled == true' >/dev/null 2>&1 || return 0
    state='{}'
    [ -f "$SHAPING_STATE_FILE" ] && state=$(cat "$SHAPING_STATE_FILE")
    active=$(printf '%s\n' "$state" | jq -r '.active_ips // 0' 2>/dev/null)
    rate=$(shaping_rates "$cfg" "$active" | jq -r '.profile_bps') || return 1
    [ "$rate" -ge 1 ] || return 1
    echo '' >> "$output"
    echo '[access.user_rate_limits]' >> "$output"
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        name="${SECRETS_LABELS[$i]}"
        printf '%s\n' "$cfg" | jq -e --arg user "$name" '.profile_exempt | index($user) == null' >/dev/null 2>&1 || continue
        printf '%s = { up_bps = 0, down_bps = %s }\n' "$name" "$rate" >> "$output"
    done
}

shaping_public_ports() {
    printf '%s\n' "${PROXY_PORT:-443}"
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

shaping_tc_apply() {
    local cfg="$1" iface kind previous original total port cidr priority=10 max_rate=100000000000
    iface=$(shaping_interface)
    [ -n "$iface" ] && [ "$iface" != lo ] || { log_error 'Не найден внешний IPv4-интерфейс'; return 1; }
    previous='{}'
    [ -f "$SHAPING_TC_FILE" ] && previous=$(cat "$SHAPING_TC_FILE")
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
       || ! tc class add dev "$iface" parent a11:1 classid a11:20 htb rate "${max_rate}bit" ceil "${max_rate}bit" quantum 15140; then
        shaping_restore_original_qdisc "$iface" "$original"; return 1
    fi
    tc qdisc add dev "$iface" parent a11:10 fq_codel >/dev/null 2>&1 || true
    tc qdisc add dev "$iface" parent a11:20 fq_codel >/dev/null 2>&1 || true
    while IFS= read -r port; do
        [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || continue
        while IFS= read -r cidr; do
            if ! tc filter add dev "$iface" parent a11: protocol ip pref "$priority" flower \
                    ip_proto tcp src_port "$port" dst_ip "$cidr" classid a11:20; then
                shaping_restore_original_qdisc "$iface" "$original"; return 1
            fi
            priority=$((priority + 1))
        done < <(printf '%s\n' "$cfg" | jq -r '.ip_exempt[]')
        if ! tc filter add dev "$iface" parent a11: protocol ip pref 10000 flower \
                ip_proto tcp src_port "$port" classid a11:10; then
            shaping_restore_original_qdisc "$iface" "$original"; return 1
        fi
    done < <(shaping_public_ports | sort -u)
    if ! shaping_atomic_json "$SHAPING_TC_FILE" "$(jq -nc --arg interface "$iface" --arg original_kind "$original" '{interface:$interface,original_kind:$original_kind}')"; then
        shaping_restore_original_qdisc "$iface" "$original"
        return 1
    fi
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
Description=MTProxyL dynamic traffic shaping update
After=mtproxyl-shaping.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mtproxyl shaping tick
UNIT
    cat > "$SHAPING_TIMER_UNIT" <<'UNIT' || return 1
[Unit]
Description=Update MTProxyL per-profile speed limits

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
    if printf '%s\n' "$cfg" | jq -e '.enabled and .mode == "dynamic"' >/dev/null; then
        systemctl enable --now mtproxyl-shaping-update.timer >/dev/null 2>&1
    else
        systemctl disable --now mtproxyl-shaping-update.timer >/dev/null 2>&1 || true
    fi
}

shaping_reload_telemt() {
    generate_telemt_config || return 1
    if engine_is_binary; then
        if binengine_running; then
            systemctl kill -s HUP "$ENGINE_SERVICE"
        fi
    elif is_proxy_running; then
        docker kill -s SIGHUP "$CONTAINER_NAME" >/dev/null 2>&1
    fi
}

shaping_apply() (
    local input cfg old old_state old_tc
    [ "${MTPROXYL_MODE:-manager}" = manager ] && ! _superexpert_active || {
        log_error 'Ограничение скорости доступно только менеджеру без режима супер эксперта'; return 1; }
    command -v jq >/dev/null && command -v tc >/dev/null && command -v ip >/dev/null \
        && command -v flock >/dev/null && command -v systemctl >/dev/null || {
        log_error 'Нужны jq, iproute2 (ip/tc), flock и systemd'; return 1; }
    input=$(head -c 65536) || return 1
    shaping_validate_config "$input" || { log_error 'Неверные параметры ограничения скорости'; return 1; }
    cfg=$(printf '%s\n' "$input" | shaping_normalize_config) || return 1
    mkdir -p "$INSTALL_DIR" || return 1
    exec {shaping_fd}>"$SHAPING_LOCK_FILE"
    flock -w 30 "$shaping_fd" || { log_error 'Настройка ограничения скорости занята'; return 1; }
    old=$(shaping_config)
    old_state='{}'; [ -f "$SHAPING_STATE_FILE" ] && old_state=$(cat "$SHAPING_STATE_FILE")
    old_tc=''; [ -f "$SHAPING_TC_FILE" ] && old_tc=$(cat "$SHAPING_TC_FILE")
    shaping_atomic_json "$SHAPING_FILE" "$cfg" || return 1
    if printf '%s\n' "$cfg" | jq -e '.enabled' >/dev/null; then
        if ! shaping_tc_apply "$cfg" || ! shaping_reload_telemt; then
            shaping_atomic_json "$SHAPING_FILE" "$old"
            if [ -n "$old_tc" ]; then
                shaping_atomic_json "$SHAPING_TC_FILE" "$old_tc"
                if printf '%s\n' "$old" | jq -e '.enabled' >/dev/null; then shaping_tc_apply "$old" || true; fi
            else
                shaping_tc_disable || true
            fi
            shaping_reload_telemt || true
            log_error 'Не удалось применить ограничение; прежние настройки восстановлены'
            return 1
        fi
        shaping_atomic_json "$SHAPING_STATE_FILE" "$(printf '%s\n' "$old_state" | jq -c --argjson now "$(date +%s)" '. + {last_update_epoch:$now,last_error:null}')"
        if ! shaping_write_units || ! shaping_sync_timer "$cfg"; then
            log_warn 'Ограничение действует сейчас, но не удалось настроить автозапуск; проверьте systemd'
        fi
    else
        shaping_sync_timer "$cfg"
        if ! shaping_tc_disable || ! shaping_reload_telemt; then
            shaping_atomic_json "$SHAPING_FILE" "$old"
            if [ -n "$old_tc" ]; then
                shaping_atomic_json "$SHAPING_TC_FILE" "$old_tc"
                shaping_tc_apply "$old" || true
            fi
            shaping_reload_telemt || true
            shaping_sync_timer "$old"
            log_error 'Не удалось выключить ограничение; прежние настройки восстановлены'
            return 1
        fi
        systemctl disable --now mtproxyl-shaping.service >/dev/null 2>&1 || true
    fi
    log_success "Ограничение скорости $([ "$(printf '%s\n' "$cfg" | jq -r '.enabled')" = true ] && echo включено || echo выключено)"
)

shaping_fetch_active_ips() {
    local auth response port="${PROXY_API_PORT:-9091}"
    auth=$(_get_telemt_auth_header "$(engine_config_path)" 2>/dev/null)
    local -a headers=()
    [ -n "$auth" ] && headers=(-H "Authorization: $auth")
    response=$(curl -fsS --max-time 5 --connect-timeout 2 "${headers[@]}" \
        "http://127.0.0.1:${port}/v1/stats/users/active-ips") || return 1
    printf '%s\n' "$response" | jq -e '
        if .ok == true and (.data | type == "array") then
            [.data[].active_ips[]? | select(type == "string" and (contains(":") | not))] | unique | length
        else error("invalid telemt response") end
    ' 2>/dev/null
}

shaping_tick() (
    local cfg active old old_rate new_rate pending now state
    cfg=$(shaping_config)
    printf '%s\n' "$cfg" | jq -e '.enabled and .mode == "dynamic"' >/dev/null 2>&1 || return 0
    exec {shaping_fd}>"$SHAPING_LOCK_FILE"
    flock -n "$shaping_fd" || return 0
    state='{}'; [ -f "$SHAPING_STATE_FILE" ] && state=$(cat "$SHAPING_STATE_FILE")
    if ! active=$(shaping_fetch_active_ips); then
        shaping_atomic_json "$SHAPING_STATE_FILE" "$(printf '%s\n' "$state" | jq -c '.last_error = "API telemt недоступен; сохранён предыдущий лимит"')"
        return 1
    fi
    now=$(date +%s)
    old=$(printf '%s\n' "$state" | jq -r '.active_ips // 0')
    old_rate=$(shaping_rates "$cfg" "$old" | jq -r '.profile_bps')
    new_rate=$(shaping_rates "$cfg" "$active" | jq -r '.profile_bps')
    pending=$(printf '%s\n' "$state" | jq -r '.pending_ips // -1')
    # Рост лимита подтверждаем двумя замерами; уменьшение применяем сразу.
    if (( new_rate > old_rate )) && [ "$pending" != "$active" ]; then
        shaping_atomic_json "$SHAPING_STATE_FILE" "$(printf '%s\n' "$state" | jq -c --argjson n "$active" --argjson now "$now" '. + {pending_ips:$n,last_sample_epoch:$now,last_error:null}')"
        return 0
    fi
    if [ "$new_rate" != "$old_rate" ] && (( now - $(printf '%s\n' "$state" | jq -r '.last_update_epoch // 0') < 60 )); then
        return 0
    fi
    shaping_atomic_json "$SHAPING_STATE_FILE" "$(printf '%s\n' "$state" | jq -c --argjson n "$active" --argjson now "$now" '. + {active_ips:$n,pending_ips:null,last_sample_epoch:$now,last_update_epoch:$now,last_error:null}')" || return 1
    if [ "$new_rate" != "$old_rate" ]; then
        if ! shaping_reload_telemt; then
            shaping_atomic_json "$SHAPING_STATE_FILE" "$state"
            return 1
        fi
    fi
)

shaping_restore() {
    local cfg
    [ "${MTPROXYL_MODE:-manager}" = manager ] && ! _superexpert_active || return 0
    cfg=$(shaping_config)
    printf '%s\n' "$cfg" | jq -e '.enabled' >/dev/null 2>&1 || return 0
    shaping_tc_apply "$cfg"
}

shaping_status_json() {
    local cfg state tc_state rates active iface root
    cfg=$(shaping_config)
    state='{}'; [ -f "$SHAPING_STATE_FILE" ] && state=$(cat "$SHAPING_STATE_FILE")
    tc_state='{}'; [ -f "$SHAPING_TC_FILE" ] && tc_state=$(cat "$SHAPING_TC_FILE")
    active=$(printf '%s\n' "$state" | jq -r '.active_ips // 0')
    rates=$(shaping_rates "$cfg" "$active")
    iface=$(printf '%s\n' "$tc_state" | jq -r '.interface // empty')
    root=false; [ -n "$iface" ] && shaping_tc_owned "$iface" && root=true
    jq -nc --argjson config "$cfg" --argjson state "$state" --argjson rates "$rates" \
        --argjson tc_active "$root" --arg interface "$iface" \
        '{config:$config,state:$state,rates:$rates,tc_active:$tc_active,interface:$interface}'
}

shaping_menu() {
    local cfg mode channel reserve expected profile total answer profiles ips
    cfg=$(shaping_config)
    echo '  Ограничение скорости: отключено по умолчанию; только отдача IPv4 клиентам.'
    shaping_status_json | jq -r '"  Режим: \(.config.mode), активных IP: \(.state.active_ips // 0), лимит профиля: \(.rates.profile_bps / 1000000) Мбит/с"'
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
        read -r -p 'Лимит на профиль, Мбит/с: ' profile
        cfg=$(printf '%s\n' "$cfg" | jq --argjson total "$total" --argjson profile "$profile" '.manual_total_mbps=$total | .manual_profile_mbps=$profile') || return 1
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

handle_shaping_command() {
    case "${1:-status}" in
        status) if [ "${2:-}" = --json ]; then shaping_status_json; else shaping_status_json | jq .; fi ;;
        apply) shaping_apply ;;
        disable) shaping_config | jq '.enabled=false' | shaping_apply ;;
        tick) shaping_tick ;;
        restore) shaping_restore ;;
        menu) shaping_menu ;;
        *) log_error 'Использование: mtproxyl shaping [status --json|apply|disable|tick|restore|menu]'; return 1 ;;
    esac
}
