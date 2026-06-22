#!/bin/bash
# MTProxyL — NFT SYN limiter + iOS фиксы + доп. правила
# Портировано из MTproxy-reanimation

NFT_CONF="${INSTALL_DIR}/nft-rules.conf"
NFT_SCRIPT_FILE="/usr/local/sbin/mtproxyl-syn-limit.sh"
NFT_SYSTEMD_UNIT="mtproxyl-syn-limit.service"
IOS_SYSCTL_FILE="/etc/sysctl.d/99-mtproxyl-keepalive.conf"
IOS2_NFT_TABLE="mtproxyl_ios2"

# ── Значения по умолчанию NFT ─────────────────────────────────
NFT_ENABLED="false"
NFT_RATE="1/second"
NFT_BURST="1"
NFT_METER_TIMEOUT="60s"
NFT_TABLE="mtproxyl_limit"
NFT_SERVER_IP=""

# iOS Fix v1
IOS_FIX_ENABLED="false"
IOS_KA_TIME="60"
IOS_KA_INTVL="15"
IOS_KA_PROBES="3"
IOS_ORIG_TIME=""
IOS_ORIG_INTVL=""
IOS_ORIG_PROBES=""

# iOS Fix v2
IOS2_FIX_ENABLED="false"
IOS2_EXTERNAL_PORT="4443"
IOS2_TARGET_PORT=""
IOS2_MSS="92"

# Доп. правила
declare -A NFT_EXTRA_PORT
declare -A NFT_EXTRA_IP
declare -A NFT_EXTRA_RATE
declare -A NFT_EXTRA_BURST
NFT_EXTRA_COUNT=0

# ── Сохранение / загрузка NFT настроек ────────────────────────
save_nft_settings() {
    cat > "$NFT_CONF" << EOF
# MTProxyL NFT — настройки
NFT_ENABLED='${NFT_ENABLED}'
NFT_RATE='${NFT_RATE}'
NFT_BURST='${NFT_BURST}'
NFT_METER_TIMEOUT='${NFT_METER_TIMEOUT}'
NFT_TABLE='${NFT_TABLE}'
NFT_SERVER_IP='${NFT_SERVER_IP}'
IOS_FIX_ENABLED='${IOS_FIX_ENABLED}'
IOS_KA_TIME='${IOS_KA_TIME}'
IOS_KA_INTVL='${IOS_KA_INTVL}'
IOS_KA_PROBES='${IOS_KA_PROBES}'
IOS_ORIG_TIME='${IOS_ORIG_TIME}'
IOS_ORIG_INTVL='${IOS_ORIG_INTVL}'
IOS_ORIG_PROBES='${IOS_ORIG_PROBES}'
IOS2_FIX_ENABLED='${IOS2_FIX_ENABLED}'
IOS2_EXTERNAL_PORT='${IOS2_EXTERNAL_PORT}'
IOS2_TARGET_PORT='${IOS2_TARGET_PORT}'
IOS2_MSS='${IOS2_MSS}'
NFT_EXTRA_COUNT='${NFT_EXTRA_COUNT}'
EOF
    local _i
    for _i in $(seq 1 "$NFT_EXTRA_COUNT"); do
        cat >> "$NFT_CONF" << EOF
NFT_EXTRA_${_i}_PORT='${NFT_EXTRA_PORT[$_i]:-}'
NFT_EXTRA_${_i}_IP='${NFT_EXTRA_IP[$_i]:-}'
NFT_EXTRA_${_i}_RATE='${NFT_EXTRA_RATE[$_i]:-1/second}'
NFT_EXTRA_${_i}_BURST='${NFT_EXTRA_BURST[$_i]:-1}'
EOF
    done
    chmod 600 "$NFT_CONF"
}

load_nft_settings() {
    [ -f "$NFT_CONF" ] || return 0
    while IFS= read -r _line; do
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$_line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$_line" =~ ^([A-Z_][A-Z0-9_]*)=\'([^\']*)\'$ ]]; then
            local _key="${BASH_REMATCH[1]}" _val="${BASH_REMATCH[2]}"
            case "$_key" in
                NFT_ENABLED|NFT_RATE|NFT_BURST|NFT_METER_TIMEOUT|\
                NFT_TABLE|NFT_SERVER_IP|\
                IOS_FIX_ENABLED|IOS_KA_TIME|IOS_KA_INTVL|IOS_KA_PROBES|\
                IOS_ORIG_TIME|IOS_ORIG_INTVL|IOS_ORIG_PROBES|\
                IOS2_FIX_ENABLED|IOS2_EXTERNAL_PORT|IOS2_TARGET_PORT|IOS2_MSS|\
                NFT_EXTRA_COUNT)
                    printf -v "$_key" '%s' "$_val" ;;
                NFT_EXTRA_*_PORT)
                    local _idx="${_key#NFT_EXTRA_}"; _idx="${_idx%_PORT}"
                    NFT_EXTRA_PORT[$_idx]="$_val" ;;
                NFT_EXTRA_*_IP)
                    local _idx="${_key#NFT_EXTRA_}"; _idx="${_idx%_IP}"
                    NFT_EXTRA_IP[$_idx]="$_val" ;;
                NFT_EXTRA_*_RATE)
                    local _idx="${_key#NFT_EXTRA_}"; _idx="${_idx%_RATE}"
                    NFT_EXTRA_RATE[$_idx]="$_val" ;;
                NFT_EXTRA_*_BURST)
                    local _idx="${_key#NFT_EXTRA_}"; _idx="${_idx%_BURST}"
                    NFT_EXTRA_BURST[$_idx]="$_val" ;;
            esac
        fi
    done < "$NFT_CONF"
    [[ "$NFT_EXTRA_COUNT" =~ ^[0-9]+$ ]] || NFT_EXTRA_COUNT=0
}

# ── Генерация NFT скрипта ─────────────────────────────────────
generate_nft_script() {
    local _ip="${NFT_SERVER_IP:-}"
    local _port="${PROXY_PORT:-443}"
    local _rate="${NFT_RATE:-1/second}"
    local _burst="${NFT_BURST:-1}"
    local _timeout="${NFT_METER_TIMEOUT:-60s}"
    local _table="${NFT_TABLE:-mtproxyl_limit}"
    local _ios2_table="${IOS2_NFT_TABLE}"
    local _ios2_ext="${IOS2_EXTERNAL_PORT:-4443}"
    local _ios2_target="${IOS2_TARGET_PORT:-${PROXY_PORT:-443}}"
    local _ios2_mss="${IOS2_MSS:-92}"

    # Заголовок
    cat > "$NFT_SCRIPT_FILE" << NFTEOF
#!/bin/sh
set -eu
TABLE="${_table}"
IOS2_TABLE="${_ios2_table}"
nft delete table inet "\$TABLE" 2>/dev/null || true
nft delete table inet "\$IOS2_TABLE" 2>/dev/null || true
nft add table inet "\$TABLE"
nft "add chain inet \$TABLE input { type filter hook input priority 0; policy accept; }"
NFTEOF

    # Основное правило
    if [ -n "$_ip" ]; then
        cat >> "$NFT_SCRIPT_FILE" << MAINIPEOF
nft "add rule inet \$TABLE input ip daddr ${_ip} tcp dport ${_port} tcp flags & (syn | ack) == syn meter mtproxyl_syn_main { ip saddr timeout ${_timeout} limit rate over ${_rate} burst ${_burst} packets } counter drop comment \\"mtproxyl_main\\""
MAINIPEOF
    else
        cat >> "$NFT_SCRIPT_FILE" << MAINNIPEOF
nft "add rule inet \$TABLE input tcp dport ${_port} tcp flags & (syn | ack) == syn meter mtproxyl_syn_main { ip saddr timeout ${_timeout} limit rate over ${_rate} burst ${_burst} packets } counter drop comment \\"mtproxyl_main\\""
MAINNIPEOF
    fi

    # Доп. правила
    local _i
    for _i in $(seq 1 "$NFT_EXTRA_COUNT"); do
        local _eport="${NFT_EXTRA_PORT[$_i]:-}"
        local _eip="${NFT_EXTRA_IP[$_i]:-}"
        local _erate="${NFT_EXTRA_RATE[$_i]:-1/second}"
        local _eburst="${NFT_EXTRA_BURST[$_i]:-1}"
        [ -z "$_eport" ] && continue

        if [ -n "$_eip" ]; then
            cat >> "$NFT_SCRIPT_FILE" << EXTRAIPEOF
nft "add rule inet \$TABLE input ip daddr ${_eip} tcp dport ${_eport} tcp flags & (syn | ack) == syn meter mtproxyl_syn_extra_${_i} { ip saddr timeout ${_timeout} limit rate over ${_erate} burst ${_eburst} packets } counter drop comment \\"mtproxyl_extra_${_i}\\""
EXTRAIPEOF
        else
            cat >> "$NFT_SCRIPT_FILE" << EXTRANIPEOF
nft "add rule inet \$TABLE input tcp dport ${_eport} tcp flags & (syn | ack) == syn meter mtproxyl_syn_extra_${_i} { ip saddr timeout ${_timeout} limit rate over ${_erate} burst ${_eburst} packets } counter drop comment \\"mtproxyl_extra_${_i}\\""
EXTRANIPEOF
        fi
    done

    # iOS Fix v2
    if [ "${IOS2_FIX_ENABLED:-false}" = "true" ]; then
        cat >> "$NFT_SCRIPT_FILE" << IOS2EOF
nft add table inet "\$IOS2_TABLE"
nft "add chain inet \$IOS2_TABLE mangle_pre { type filter hook prerouting priority mangle; policy accept; }"
nft "add chain inet \$IOS2_TABLE nat_pre { type nat hook prerouting priority dstnat; policy accept; }"
IOS2EOF
        if [ -n "$_ip" ]; then
            cat >> "$NFT_SCRIPT_FILE" << IOS2IPEOF
nft "add rule inet \$IOS2_TABLE mangle_pre ip daddr ${_ip} tcp dport ${_ios2_ext} tcp flags & (syn | rst) == syn tcp option maxseg size set ${_ios2_mss} counter comment \\"mtproxyl_ios2_mss\\""
nft "add rule inet \$IOS2_TABLE nat_pre ip daddr ${_ip} tcp dport ${_ios2_ext} counter redirect to :${_ios2_target} comment \\"mtproxyl_ios2_redirect\\""
IOS2IPEOF
        else
            cat >> "$NFT_SCRIPT_FILE" << IOS2NIPEOF
nft "add rule inet \$IOS2_TABLE mangle_pre tcp dport ${_ios2_ext} tcp flags & (syn | rst) == syn tcp option maxseg size set ${_ios2_mss} counter comment \\"mtproxyl_ios2_mss\\""
nft "add rule inet \$IOS2_TABLE nat_pre tcp dport ${_ios2_ext} counter redirect to :${_ios2_target} comment \\"mtproxyl_ios2_redirect\\""
IOS2NIPEOF
        fi
    fi

    cat >> "$NFT_SCRIPT_FILE" << 'TAILEOF'
echo "MTProxyL: NFT правила применены"
nft list table inet "$TABLE" 2>/dev/null || true
nft list table inet "$IOS2_TABLE" 2>/dev/null || true
TAILEOF

    chmod +x "$NFT_SCRIPT_FILE"
}

# ── Применение / удаление NFT правил ─────────────────────────
apply_nft_rules() {
    if ! command -v nft &>/dev/null; then
        log_info "nftables не установлен, устанавливаем..."
        _wait_apt 2>/dev/null || true
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq nftables
        elif command -v yum &>/dev/null; then
            yum install -y -q nftables
        elif command -v dnf &>/dev/null; then
            dnf install -y -q nftables
        elif command -v apk &>/dev/null; then
            apk add --no-cache nftables
        else
            log_error "Не удалось установить nftables — установите вручную: apt install nftables"
            return 1
        fi
        if ! command -v nft &>/dev/null; then
            log_error "nftables не установлен после попытки установки"
            return 1
        fi
        log_success "nftables установлен"
    fi

    generate_nft_script
    if /bin/sh "$NFT_SCRIPT_FILE"; then
        log_success "NFT правила применены"
    else
        log_error "Не удалось применить NFT правила"
        return 1
    fi
}

remove_nft_rules() {
    nft delete table inet "${NFT_TABLE:-mtproxyl_limit}" 2>/dev/null || true
    nft delete table inet "${IOS2_NFT_TABLE}" 2>/dev/null || true
    log_success "NFT правила удалены"
}

# ── Systemd сервис для NFT ────────────────────────────────────
install_nft_service() {
    generate_nft_script
    local _table="${NFT_TABLE:-mtproxyl_limit}"
    local _ios2_table="${IOS2_NFT_TABLE}"

    cat > "/etc/systemd/system/${NFT_SYSTEMD_UNIT}" << SVCEOF
[Unit]
Description=MTProxyL inbound SYN limiter
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh ${NFT_SCRIPT_FILE}
ExecStop=/bin/sh -c '/usr/sbin/nft delete table inet ${_table} 2>/dev/null || true; /usr/sbin/nft delete table inet ${_ios2_table} 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "$NFT_SYSTEMD_UNIT" 2>/dev/null
    systemctl restart "$NFT_SYSTEMD_UNIT" 2>/dev/null
    NFT_ENABLED="true"
    save_nft_settings
    log_success "Служба NFT limiter установлена и запущена"
}

remove_nft_service() {
    systemctl disable --now "$NFT_SYSTEMD_UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/${NFT_SYSTEMD_UNIT}"
    rm -f "$NFT_SCRIPT_FILE"
    systemctl daemon-reload 2>/dev/null || true
    NFT_ENABLED="false"
    save_nft_settings
    log_success "Служба NFT limiter удалена"
}

# ── Пресеты NFT ──────────────────────────────────────────────
apply_nft_preset() {
    case "$1" in
        hard)   NFT_RATE="1/second"; NFT_BURST="1" ;;
        medium) NFT_RATE="1/second"; NFT_BURST="3" ;;
        soft)   NFT_RATE="2/second"; NFT_BURST="5" ;;
        *) log_error "Неизвестный пресет: $1"; return 1 ;;
    esac
    save_nft_settings
    log_success "Пресет: $1 (rate=$NFT_RATE burst=$NFT_BURST)"
}

# ── iOS Fix v1 — TCP keepalive ────────────────────────────────
ios_fix_apply() {
    # Сохраняем оригиналы
    if [ -z "$IOS_ORIG_TIME" ]; then
        IOS_ORIG_TIME=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "7200")
        IOS_ORIG_INTVL=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo "75")
        IOS_ORIG_PROBES=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo "9")
    fi

    cat > "$IOS_SYSCTL_FILE" << SYSEOF
# MTProxyL: iOS Fix v1 — TCP keepalive
net.ipv4.tcp_keepalive_time = ${IOS_KA_TIME}
net.ipv4.tcp_keepalive_intvl = ${IOS_KA_INTVL}
net.ipv4.tcp_keepalive_probes = ${IOS_KA_PROBES}
SYSEOF

    if sysctl --system &>/dev/null; then
        log_success "sysctl применён"
    else
        sysctl -w "net.ipv4.tcp_keepalive_time=${IOS_KA_TIME}" 2>/dev/null || true
        sysctl -w "net.ipv4.tcp_keepalive_intvl=${IOS_KA_INTVL}" 2>/dev/null || true
        sysctl -w "net.ipv4.tcp_keepalive_probes=${IOS_KA_PROBES}" 2>/dev/null || true
    fi

    IOS_FIX_ENABLED="true"
    save_nft_settings
    local _detect=$(( IOS_KA_TIME + IOS_KA_INTVL * IOS_KA_PROBES ))
    log_success "iOS Fix v1 применён (обнаружение мёртвого коннекта: ~${_detect}с)"
}

ios_fix_remove() {
    [ ! -f "$IOS_SYSCTL_FILE" ] && { log_info "iOS Fix v1 не установлен"; return 0; }

    rm -f "$IOS_SYSCTL_FILE"
    local _rt="${IOS_ORIG_TIME:-7200}" _ri="${IOS_ORIG_INTVL:-75}" _rp="${IOS_ORIG_PROBES:-9}"
    sysctl -w "net.ipv4.tcp_keepalive_time=${_rt}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_keepalive_intvl=${_ri}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_keepalive_probes=${_rp}" &>/dev/null || true
    sysctl --system &>/dev/null || true

    IOS_FIX_ENABLED="false"
    IOS_ORIG_TIME=""; IOS_ORIG_INTVL=""; IOS_ORIG_PROBES=""
    save_nft_settings
    log_success "iOS Fix v1 откачен (восстановлены: time=${_rt} intvl=${_ri} probes=${_rp})"
}

# ── iOS Fix v2 — MSS + redirect ──────────────────────────────
ios2_fix_apply() {
    local _target="${IOS2_TARGET_PORT:-${PROXY_PORT:-443}}"
    [ "${IOS2_EXTERNAL_PORT}" = "${_target}" ] && { log_error "iOS-порт не должен совпадать с основным"; return 1; }

    IOS2_FIX_ENABLED="true"
    IOS2_TARGET_PORT="${_target}"
    save_nft_settings
    apply_nft_rules || return 1
    [ "${NFT_ENABLED:-false}" = "true" ] && install_nft_service
    log_success "iOS Fix v2: порт ${IOS2_EXTERNAL_PORT} → ${_target} (MSS=${IOS2_MSS})"
}

ios2_fix_remove() {
    IOS2_FIX_ENABLED="false"
    save_nft_settings
    apply_nft_rules || true
    [ "${NFT_ENABLED:-false}" = "true" ] && install_nft_service
    nft delete table inet "${IOS2_NFT_TABLE}" 2>/dev/null || true
    log_success "iOS Fix v2 отключён"
}

# ── Доп. правила ─────────────────────────────────────────────
nft_extra_add() {
    local _port="$1" _ip="${2:-}" _rate="${3:-1/second}" _burst="${4:-1}"
    [[ "$_port" =~ ^[0-9]+$ ]] && [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] || {
        log_error "Некорректный порт"; return 1; }
    NFT_EXTRA_COUNT=$((NFT_EXTRA_COUNT + 1))
    local _idx=$NFT_EXTRA_COUNT
    NFT_EXTRA_PORT[$_idx]="$_port"
    NFT_EXTRA_IP[$_idx]="$_ip"
    NFT_EXTRA_RATE[$_idx]="$_rate"
    NFT_EXTRA_BURST[$_idx]="$_burst"
    save_nft_settings
    log_success "Доп. правило #${_idx}: порт=${_port}"
}

nft_extra_remove() {
    local _idx="$1"
    [[ "$_idx" =~ ^[0-9]+$ ]] && [ "$_idx" -ge 1 ] && [ "$_idx" -le "$NFT_EXTRA_COUNT" ] || {
        log_error "Некорректный номер"; return 1; }
    local _i
    for _i in $(seq "$_idx" $((NFT_EXTRA_COUNT - 1))); do
        local _next=$((_i + 1))
        NFT_EXTRA_PORT[$_i]="${NFT_EXTRA_PORT[$_next]:-}"
        NFT_EXTRA_IP[$_i]="${NFT_EXTRA_IP[$_next]:-}"
        NFT_EXTRA_RATE[$_i]="${NFT_EXTRA_RATE[$_next]:-}"
        NFT_EXTRA_BURST[$_i]="${NFT_EXTRA_BURST[$_next]:-}"
    done
    unset "NFT_EXTRA_PORT[$NFT_EXTRA_COUNT]" "NFT_EXTRA_IP[$NFT_EXTRA_COUNT]"
    unset "NFT_EXTRA_RATE[$NFT_EXTRA_COUNT]" "NFT_EXTRA_BURST[$NFT_EXTRA_COUNT]"
    NFT_EXTRA_COUNT=$((NFT_EXTRA_COUNT - 1))
    save_nft_settings
    log_success "Доп. правило удалено"
}

# ── Полная очистка NFT при удалении ───────────────────────────
nft_full_cleanup() {
    remove_nft_rules 2>/dev/null || true
    remove_nft_service 2>/dev/null || true
    ios_fix_remove 2>/dev/null || true
    rm -f "$NFT_CONF"
}

# ── Счётчик дропов ────────────────────────────────────────────
show_nft_drop_counter() {
    local _table="${NFT_TABLE:-mtproxyl_limit}"
    if ! nft list table inet "$_table" &>/dev/null; then
        log_warn "Активных NFT правил не найдено"
        return 1
    fi
    echo ""
    echo -e "  ${BOLD}Счётчик дропов (Ctrl+C для выхода):${NC}"
    echo ""
    watch -n 2 "nft list chain inet $_table input 2>/dev/null | grep -E 'counter|comment'"
}

# ── Статусы для шапки ─────────────────────────────────────────
nft_status_line() {
    if nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null; then
        echo -e "${GREEN}активно${NC} (${NFT_RATE} burst ${NFT_BURST})"
    else
        echo -e "${DIM}неактивно${NC}"
    fi
}

ios_fix_status_line() {
    if [ -f "$IOS_SYSCTL_FILE" ]; then
        local _t _i _p
        _t=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
        _i=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
        _p=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
        echo -e "${GREEN}v1 активен${NC} (${_t}/${_i}/${_p})"
    else
        echo -e "${DIM}не применён${NC}"
    fi
}

ios2_fix_status_line() {
    if [ "${IOS2_FIX_ENABLED:-false}" = "true" ]; then
        echo -e "${GREEN}v2 активен${NC} (${IOS2_EXTERNAL_PORT}→${IOS2_TARGET_PORT:-${PROXY_PORT:-443}} mss=${IOS2_MSS})"
    else
        echo -e "${DIM}не применён${NC}"
    fi
}
