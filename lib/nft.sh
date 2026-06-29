#!/bin/bash
# MTProxyL — NFT SYN limiter + iOS фиксы + Smart режим + доп. правила

NFT_CONF="${INSTALL_DIR}/nft-rules.conf"
NFT_SCRIPT_FILE="/usr/local/sbin/mtproxyl-syn-limit.sh"
NFT_SYSTEMD_UNIT="mtproxyl-syn-limit.service"
IOS_SYSCTL_FILE="/etc/sysctl.d/99-mtproxyl-keepalive.conf"
IOS2_NFT_TABLE="mtproxyl_ios2"

# ── Значения по умолчанию ─────────────────────────────────────
NFT_ENABLED="false"
NFT_MODE="classic"
NFT_RATE="1/second"
NFT_BURST="1"
NFT_METER_TIMEOUT="60s"
NFT_TABLE="mtproxyl_limit"
NFT_SERVER_IP=""
NFT_OTHER_ACTION="icmp-host-unreachable"

# Оптимизация By-MEKO
MEKO_OPT_FILE="/etc/sysctl.d/99-mtproxyl-meko-opt.conf"
MEKO_OPT_APPLIED="false"
MEKO_ORIG_KEEPALIVE_TIME=""
MEKO_ORIG_KEEPALIVE_INTVL=""
MEKO_ORIG_KEEPALIVE_PROBES=""
MEKO_ORIG_SOMAXCONN=""
MEKO_ORIG_TCP_MAX_SYN_BACKLOG=""
MEKO_ORIG_NETDEV_MAX_BACKLOG=""
MEKO_ORIG_TCP_FASTOPEN=""
MEKO_ORIG_FILE_MAX=""
MEKO_ORIG_DEFAULT_QDISC=""
MEKO_ORIG_TCP_CONGESTION=""

# Smart режим (By-MEKO)
NFT_REJECT_MODE="reset"
NFT_IOS_RATE="15/second"
NFT_IOS_BURST="30"
NFT_OTHER_RATE="54/minute"
NFT_OTHER_BURST="1"

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

# ── Сохранение / загрузка настроек ────────────────────────────
save_nft_settings() {
    mkdir -p "$INSTALL_DIR"
    cat > "$NFT_CONF" << EOF
# MTProxyL NFT — настройки
NFT_ENABLED='${NFT_ENABLED}'
NFT_MODE='${NFT_MODE}'
NFT_RATE='${NFT_RATE}'
NFT_BURST='${NFT_BURST}'
NFT_METER_TIMEOUT='${NFT_METER_TIMEOUT}'
NFT_TABLE='${NFT_TABLE}'
NFT_SERVER_IP='${NFT_SERVER_IP}'
NFT_REJECT_MODE='${NFT_REJECT_MODE}'
NFT_IOS_RATE='${NFT_IOS_RATE}'
NFT_IOS_BURST='${NFT_IOS_BURST}'
NFT_OTHER_RATE='${NFT_OTHER_RATE}'
NFT_OTHER_BURST='${NFT_OTHER_BURST}'
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
                NFT_ENABLED|NFT_MODE|NFT_RATE|NFT_BURST|NFT_METER_TIMEOUT|\
                NFT_TABLE|NFT_SERVER_IP|\
                NFT_REJECT_MODE|NFT_IOS_RATE|NFT_IOS_BURST|\
                NFT_OTHER_RATE|NFT_OTHER_BURST|\
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
    # Совместимость со старыми конфигами без NFT_MODE
    [ "$NFT_MODE" != "classic" ] && [ "$NFT_MODE" != "smart" ] && NFT_MODE="classic"
    [ "$NFT_REJECT_MODE" != "reset" ] && [ "$NFT_REJECT_MODE" != "drop" ] && NFT_REJECT_MODE="reset"
}

# ── Применить NFT правила после изменения настроек ────────────
prompt_apply_nft_rules() {
    echo ""
    echo -en "  ${BOLD}Применить новые NFT-правила сейчас? [Y/n]:${NC} "
    local _yn; read -r _yn
    if [[ ! "$_yn" =~ ^[nN]$ ]]; then
        apply_nft_rules || true
        [ "${NFT_ENABLED:-false}" = "true" ] && install_nft_service || true
    fi
}

# ── Генерация NFT скрипта ─────────────────────────────────────
generate_nft_script() {
    local _ip="${NFT_SERVER_IP:-}"
    local _port="${PROXY_PORT:-443}"
    local _timeout="${NFT_METER_TIMEOUT:-60s}"
    local _table="${NFT_TABLE:-mtproxyl_limit}"
    local _ios2_table="${IOS2_NFT_TABLE}"
    local _ios2_ext="${IOS2_EXTERNAL_PORT:-4443}"
    local _ios2_target="${IOS2_TARGET_PORT:-${PROXY_PORT:-443}}"
    local _ios2_mss="${IOS2_MSS:-92}"

    # IP match fragment
    local _ip_match=""
    [ -n "$_ip" ] && _ip_match="ip daddr ${_ip} "

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

    if [ "$NFT_MODE" = "smart" ]; then
        _generate_smart_rules "$_ip_match" "$_port" "$_timeout"
    else
        _generate_classic_rules "$_ip_match" "$_port" "$_timeout"
    fi

    # Доп. правила (работают в обоих режимах)
    local _i
    for _i in $(seq 1 "$NFT_EXTRA_COUNT"); do
        local _eport="${NFT_EXTRA_PORT[$_i]:-}"
        local _eip="${NFT_EXTRA_IP[$_i]:-}"
        local _erate="${NFT_EXTRA_RATE[$_i]:-1/second}"
        local _eburst="${NFT_EXTRA_BURST[$_i]:-1}"
        [ -z "$_eport" ] && continue

        local _extra_ip_match=""
        [ -n "$_eip" ] && _extra_ip_match="ip daddr ${_eip} "

        local _extra_action="drop"
        [ "$NFT_MODE" = "smart" ] && _extra_action="reject with tcp reset"

        cat >> "$NFT_SCRIPT_FILE" << EXTRAEOF
nft "add rule inet \$TABLE input ${_extra_ip_match}tcp dport ${_eport} tcp flags & (syn | ack) == syn meter mtproxyl_syn_extra_${_i} { ip saddr timeout ${_timeout} limit rate over ${_erate} burst ${_eburst} packets } counter ${_extra_action} comment \\"mtproxyl_extra_${_i}\\""
EXTRAEOF
    done

    # iOS Fix v2 (только в classic режиме, smart не нуждается)
    if [ "${IOS2_FIX_ENABLED:-false}" = "true" ] && [ "$NFT_MODE" = "classic" ]; then
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

# ── Генерация Classic правил ──────────────────────────────────
_generate_classic_rules() {
    local _ip_match="$1" _port="$2" _timeout="$3"
    local _rate="${NFT_RATE:-1/second}"
    local _burst="${NFT_BURST:-1}"

    cat >> "$NFT_SCRIPT_FILE" << CLASSICEOF
nft "add rule inet \$TABLE input ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn meter mtproxyl_syn_main { ip saddr timeout ${_timeout} limit rate over ${_rate} burst ${_burst} packets } counter drop comment \\"mtproxyl_main\\""
CLASSICEOF
}

# ── Генерация Smart правил (By-MEKO) ─────────────────────────
_generate_smart_rules() {
    local _ip_match="$1" _port="$2" _timeout="$3"
    local _ios_rate="${NFT_IOS_RATE:-15/second}"
    local _ios_burst="${NFT_IOS_BURST:-30}"
    local _other_rate="${NFT_OTHER_RATE:-54/minute}"
    local _other_burst="${NFT_OTHER_BURST:-1}"

    # Правило 1: iOS SYN (TTL < 65, length 64) → мягкий лимит → accept
    cat >> "$NFT_SCRIPT_FILE" << SMART1EOF
nft "add rule inet \$TABLE input ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn ip ttl < 65 meta length 64 meter mtproxyl_ios { ip saddr timeout ${_timeout} limit rate ${_ios_rate} burst ${_ios_burst} packets } accept comment \\"mtproxyl_smart_ios_accept\\""
SMART1EOF

    # Правило 2: iOS SYN сверх лимита → REJECT
    cat >> "$NFT_SCRIPT_FILE" << SMART2EOF
nft "add rule inet \$TABLE input ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn ip ttl < 65 meta length 64 counter reject with tcp reset comment \\"mtproxyl_smart_ios_reject\\""
SMART2EOF

    # Правило 3: Остальные SYN → строгий лимит → accept
    cat >> "$NFT_SCRIPT_FILE" << SMART3EOF
nft "add rule inet \$TABLE input ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn meter mtproxyl_other { ip saddr timeout ${_timeout} limit rate ${_other_rate} burst ${_other_burst} packets } accept comment \\"mtproxyl_smart_other_accept\\""
SMART3EOF

    # Правило 4: Остальные SYN сверх лимита → REJECT
    cat >> "$NFT_SCRIPT_FILE" << SMART4EOF
nft "add rule inet \$TABLE input ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn counter reject with tcp reset comment \\"mtproxyl_smart_other_reject\\""
SMART4EOF
}

# ── Применение / удаление правил ──────────────────────────────
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
        command -v nft &>/dev/null || { log_error "nftables не установлен после попытки установки"; return 1; }
        log_success "nftables установлен"
    fi

    generate_nft_script
    if /bin/sh "$NFT_SCRIPT_FILE"; then
        log_success "NFT правила применены (режим: ${NFT_MODE})"
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

# ── Systemd сервис ────────────────────────────────────────────
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
    log_success "Служба NFT limiter установлена и запущена (режим: ${NFT_MODE})"
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

# ── Пресеты ───────────────────────────────────────────────────
apply_nft_preset() {
    case "$1" in
        hard)   NFT_MODE="classic"; NFT_RATE="1/second"; NFT_BURST="1" ;;
        medium) NFT_MODE="classic"; NFT_RATE="1/second"; NFT_BURST="3" ;;
        soft)   NFT_MODE="classic"; NFT_RATE="2/second"; NFT_BURST="5" ;;
        smart)
            NFT_MODE="smart"
            NFT_REJECT_MODE="reset"
            NFT_IOS_RATE="15/second"
            NFT_IOS_BURST="30"
            NFT_OTHER_RATE="54/minute"
            NFT_OTHER_BURST="1"
            ;;
        *) log_error "Неизвестный пресет: $1"; return 1 ;;
    esac
    save_nft_settings
    if [ "$1" = "smart" ]; then
        log_success "Пресет: Smart By-MEKO (iOS: ${NFT_IOS_RATE} burst ${NFT_IOS_BURST} / Other: ${NFT_OTHER_RATE} burst ${NFT_OTHER_BURST})"
    else
        log_success "Пресет: $1 (rate=$NFT_RATE burst=$NFT_BURST)"
    fi
}

# ── Smart режим: включение ────────────────────────────────────
enable_smart_mode() {
    echo ""
    echo -e "  ${BOLD}NFT Smart By-MEKO${NC}"
    echo ""
    echo -e "  ${DIM}Как работает:${NC}"
    echo -e "  ${DIM}  • iOS и Android/Desktop разделяются автоматически по TTL${NC}"
    echo -e "  ${DIM}  • iOS (TTL<65): мягкий лимит ${NFT_IOS_RATE} burst ${NFT_IOS_BURST}${NC}"
    echo -e "  ${DIM}  • Остальные:    строгий лимит ${NFT_OTHER_RATE} burst ${NFT_OTHER_BURST}${NC}"
    echo -e "  ${DIM}  • REJECT вместо DROP — клиент получает RST и${NC}"
    echo -e "  ${DIM}    переподключается мгновенно (3-8 сек вместо 10-20)${NC}"
    echo -e "  ${DIM}  • Один порт для всех клиентов — iOS Fix v2 не нужен${NC}"
    echo -e "  ${DIM}  • MSS (client_mss) не нужен${NC}"
    echo ""

    # Предупреждение если iOS Fix v2 активен
    if [ "${IOS2_FIX_ENABLED:-false}" = "true" ]; then
        echo -e "  ${YELLOW}⚠ iOS Fix v2 сейчас активен (порт ${IOS2_EXTERNAL_PORT}).${NC}"
        echo -e "  ${YELLOW}  Smart режим заменяет его — iOS Fix v2 будет отключён.${NC}"
        echo ""
    fi

    echo -en "  ${BOLD}Включить Smart режим? [Y/n]:${NC} "
    local _yn; read -r _yn
    [[ "$_yn" =~ ^[nN]$ ]] && { log_info "Отменено"; return 0; }

    # Отключаем iOS Fix v2 если был
    if [ "${IOS2_FIX_ENABLED:-false}" = "true" ]; then
        IOS2_FIX_ENABLED="false"
        nft delete table inet "${IOS2_NFT_TABLE}" 2>/dev/null || true
        log_info "iOS Fix v2 отключён (Smart режим его заменяет)"
    fi

    apply_nft_preset smart
    save_nft_settings
    apply_nft_rules || { log_error "Не удалось применить правила"; return 1; }
    install_nft_service || true

    echo ""
    log_success "Smart режим активирован"
    echo ""
    echo -e "  ${BOLD}Что изменилось:${NC}"
    echo -e "    ${GREEN}${SYM_CHECK}${NC} iOS и Android на одном порту ${PROXY_PORT}"
    echo -e "    ${GREEN}${SYM_CHECK}${NC} REJECT вместо DROP — быстрый reconnect"
    echo -e "    ${GREEN}${SYM_CHECK}${NC} iOS Fix v2 / отдельный порт не нужен"
    echo -e "    ${GREEN}${SYM_CHECK}${NC} client_mss в конфиге не нужен"
    echo ""
}

# ── iOS Fix v1 — TCP keepalive ────────────────────────────────
ios_fix_apply() {
    echo ""
    echo -e "  ${BOLD}Фикс для iOS (вариант 1) — TCP keepalive${NC}"; echo ""
    echo -e "  ${DIM}Ускоряет обнаружение мёртвых сокетов через sysctl.${NC}"
    echo -e "  ${DIM}Подходит если iOS-клиенты после фона не могут переподключиться.${NC}"; echo ""

    local _cur_time _cur_intvl _cur_probes
    _cur_time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
    _cur_intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
    _cur_probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)

    echo -e "  ${BOLD}Текущие значения ядра:${NC}"
    echo -e "    tcp_keepalive_time   = ${_cur_time:-?}  ${DIM}(дефолт: 7200)${NC}"
    echo -e "    tcp_keepalive_intvl  = ${_cur_intvl:-?}  ${DIM}(дефолт: 75)${NC}"
    echo -e "    tcp_keepalive_probes = ${_cur_probes:-?}  ${DIM}(дефолт: 9)${NC}"; echo ""

    echo -e "  ${BOLD}Параметры фикса (Enter = оставить текущее):${NC}"
    echo -en "    tcp_keepalive_time   [${IOS_KA_TIME}]: "
    local _t; read -r _t; [[ "$_t" =~ ^[0-9]+$ ]] && IOS_KA_TIME="$_t"
    echo -en "    tcp_keepalive_intvl  [${IOS_KA_INTVL}]: "
    local _i; read -r _i; [[ "$_i" =~ ^[0-9]+$ ]] && IOS_KA_INTVL="$_i"
    echo -en "    tcp_keepalive_probes [${IOS_KA_PROBES}]: "
    local _p; read -r _p; [[ "$_p" =~ ^[0-9]+$ ]] && IOS_KA_PROBES="$_p"

    local _detect=$(( IOS_KA_TIME + IOS_KA_INTVL * IOS_KA_PROBES ))
    echo ""
    echo -e "  ${DIM}Мёртвый коннект будет рваться за ~${_detect} сек${NC}"
    echo -e "  ${DIM}  ${IOS_KA_TIME}с тишины → проба каждые ${IOS_KA_INTVL}с × ${IOS_KA_PROBES} попыток → RST${NC}"; echo ""

    if [ -f "$IOS_SYSCTL_FILE" ]; then
        echo -e "  ${YELLOW}Файл ${IOS_SYSCTL_FILE} уже существует.${NC}"
        echo -en "  ${BOLD}Перезаписать? [Y/n]:${NC} "
    else
        echo -en "  ${BOLD}Применить фикс? [Y/n]:${NC} "
    fi
    local _confirm; read -r _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }

    # Сохраняем оригиналы если ещё не сохранены
    if [ -z "$IOS_ORIG_TIME" ]; then
        IOS_ORIG_TIME=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "7200")
        IOS_ORIG_INTVL=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo "75")
        IOS_ORIG_PROBES=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo "9")
        log_info "Сохранены оригинальные значения: time=${IOS_ORIG_TIME} intvl=${IOS_ORIG_INTVL} probes=${IOS_ORIG_PROBES}"
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
        log_warn "sysctl --system вернул ошибку, применяем вручную"
        sysctl -w "net.ipv4.tcp_keepalive_time=${IOS_KA_TIME}" 2>/dev/null || true
        sysctl -w "net.ipv4.tcp_keepalive_intvl=${IOS_KA_INTVL}" 2>/dev/null || true
        sysctl -w "net.ipv4.tcp_keepalive_probes=${IOS_KA_PROBES}" 2>/dev/null || true
    fi

    local _new_time _new_intvl _new_probes
    _new_time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
    _new_intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
    _new_probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
    echo ""
    echo -e "  ${BOLD}Новые значения ядра:${NC}"
    echo -e "    tcp_keepalive_time   = ${_new_time}"
    echo -e "    tcp_keepalive_intvl  = ${_new_intvl}"
    echo -e "    tcp_keepalive_probes = ${_new_probes}"

    if [ "${_new_time}" = "${IOS_KA_TIME}" ] && [ "${_new_intvl}" = "${IOS_KA_INTVL}" ] && [ "${_new_probes}" = "${IOS_KA_PROBES}" ]; then
        log_success "iOS Fix v1 применён"
    else
        log_warn "Значения не совпадают с ожидаемыми — проверьте вручную"
    fi

    IOS_FIX_ENABLED="true"
    save_nft_settings
}

ios_fix_remove() {
    local force="${1:-false}"

    echo ""
    if [ ! -f "$IOS_SYSCTL_FILE" ]; then
        log_info "iOS Fix v1 не установлен"
        IOS_FIX_ENABLED="false"
        save_nft_settings
        return 0
    fi

    if [ "$force" != "true" ]; then
        echo -e "  ${BOLD}Откат фикса для iOS (вариант 1)${NC}"; echo ""
        echo -e "  ${DIM}Будет удалён: ${IOS_SYSCTL_FILE}${NC}"
        echo -e "  ${DIM}Значения ядра будут восстановлены к тем, которые были до применения фикса.${NC}"; echo ""
        echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
        local _confirm; read -r _confirm
        [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }
    fi

    rm -f "$IOS_SYSCTL_FILE"

    local _rt="${IOS_ORIG_TIME:-7200}"
    local _ri="${IOS_ORIG_INTVL:-75}"
    local _rp="${IOS_ORIG_PROBES:-9}"

    log_info "Восстановление значений: time=${_rt} intvl=${_ri} probes=${_rp}"
    sysctl -w "net.ipv4.tcp_keepalive_time=${_rt}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_keepalive_intvl=${_ri}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_keepalive_probes=${_rp}" &>/dev/null || true
    sysctl --system &>/dev/null || true

    if [ "$force" != "true" ]; then
        local _time _intvl _probes
        _time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
        _intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
        _probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
        echo ""
        echo -e "  ${BOLD}Текущие значения ядра:${NC}"
        echo -e "    tcp_keepalive_time   = ${_time}"
        echo -e "    tcp_keepalive_intvl  = ${_intvl}"
        echo -e "    tcp_keepalive_probes = ${_probes}"
    fi

    log_success "iOS Fix v1 откачен (восстановлены: time=${_rt} intvl=${_ri} probes=${_rp})"
    IOS_FIX_ENABLED="false"
    IOS_ORIG_TIME=""; IOS_ORIG_INTVL=""; IOS_ORIG_PROBES=""
    save_nft_settings
}

# ── iOS Fix v2 — MSS + redirect ──────────────────────────────
_ios2_check_client_mss() {
    local _cfg="${CONFIG_DIR}/config.toml"
    if [ -f "$_cfg" ] && grep -qE '^client_mss[[:space:]]*=' "$_cfg" 2>/dev/null; then
        echo ""
        echo -e "  ${RED}${BOLD}⚠ ВНИМАНИЕ!${NC}"
        echo -e "  ${RED}В конфиге обнаружен параметр client_mss${NC}"
        echo -e "  ${YELLOW}Fix v2 использует MSS через nftables.${NC}"
        echo -e "  ${YELLOW}client_mss в конфиге задаёт MSS на ВСЕ соединения — конфликт!${NC}"
        echo ""
        echo -e "  ${BOLD}Решение:${NC} уберите client_mss из конфига через:"
        echo -e "  ${CYAN}mtproxyl expert clear client_mss${NC}"
        echo -e "  ${CYAN}mtproxyl restart${NC}"
        echo ""
        echo -en "  ${BOLD}Продолжить всё равно? [y/N]:${NC} "
        local _proceed; read -r _proceed
        [[ "$_proceed" =~ ^[yY] ]] || return 1
    fi
    return 0
}

ios2_fix_apply() {
    # Предупреждение если Smart режим
    if [ "$NFT_MODE" = "smart" ]; then
        echo ""
        echo -e "  ${YELLOW}⚠ Smart режим активен — iOS Fix v2 не нужен.${NC}"
        echo -e "  ${DIM}Smart режим автоматически разделяет iOS и Android на одном порту.${NC}"
        echo ""
        echo -en "  ${BOLD}Всё равно включить iOS Fix v2? [y/N]:${NC} "
        local _force; read -r _force
        [[ "$_force" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
    fi

    local _target="${IOS2_TARGET_PORT:-${PROXY_PORT:-443}}"
    [ -z "${PROXY_PORT:-}" ] && { log_error "Порт прокси не определён — запустите прокси хотя бы раз"; return 1; }
    [[ "${IOS2_EXTERNAL_PORT}" =~ ^[0-9]+$ ]] && [ "${IOS2_EXTERNAL_PORT}" -ge 1 ] && [ "${IOS2_EXTERNAL_PORT}" -le 65535 ] || { log_error "Некорректный iOS-порт"; return 1; }
    [ "${IOS2_EXTERNAL_PORT}" = "${_target}" ] && { log_error "iOS-порт не должен совпадать с основным"; return 1; }
    [[ "${IOS2_MSS}" =~ ^[0-9]+$ ]] && [ "${IOS2_MSS}" -ge 88 ] && [ "${IOS2_MSS}" -le 4096 ] || { log_error "MSS должен быть в диапазоне 88..4096"; return 1; }

    echo ""
    echo -e "  ${BOLD}Фикс для iOS вариант 2 (MSS + redirect)${NC}"; echo ""
    echo -e "  ${DIM}Создаёт отдельный порт для iOS-клиентов.${NC}"
    echo -e "  ${DIM}Входящий SYN получает MSS=${IOS2_MSS},${NC}"
    echo -e "  ${DIM}затем трафик редиректится на основной порт.${NC}"; echo ""
    echo -e "    Внешний порт iOS: ${BOLD}${IOS2_EXTERNAL_PORT}${NC}"
    echo -e "    Основной порт:    ${_target}"
    echo -e "    MSS:              ${IOS2_MSS}"; echo ""

    _ios2_check_client_mss || return 0

    echo -en "  ${BOLD}Применить? [Y/n]:${NC} "
    local _confirm; read -r _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }

    IOS2_FIX_ENABLED="true"
    IOS2_TARGET_PORT="${_target}"
    save_nft_settings
    apply_nft_rules || return 1
    [ "${NFT_ENABLED:-false}" = "true" ] && install_nft_service

    log_success "iOS Fix v2 применён: порт ${IOS2_EXTERNAL_PORT} → ${_target} (MSS=${IOS2_MSS})"
    echo ""
    echo -e "  ${BOLD}═══════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}Инструкция для пользователей iOS:${NC}"
    echo -e "  ${DIM}───────────────────────────────────────────${NC}"
    echo -e "  Замените порт ${_target} на ${IOS2_EXTERNAL_PORT} в ссылке:"
    echo ""
    echo -e "  ${DIM}Было:${NC}  tg://proxy?server=IP&${RED}port=${_target}${NC}&secret=..."
    echo -e "  ${DIM}Стало:${NC} tg://proxy?server=IP&${GREEN}port=${IOS2_EXTERNAL_PORT}${NC}&secret=..."
    echo ""
    echo -e "  ${DIM}Secret и IP остаются прежними.${NC}"
    echo -e "  ${DIM}Android и Desktop — основной порт ${_target}.${NC}"
    echo -e "  ${BOLD}═══════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠ Откройте порт ${IOS2_EXTERNAL_PORT} в фаерволе!${NC}"
}

ios2_fix_remove() {
    local force="${1:-false}"

    echo ""
    if [ "${IOS2_FIX_ENABLED:-false}" != "true" ]; then
        log_info "iOS Fix v2 не установлен"; return 0; fi

    if [ "$force" != "true" ]; then
        echo -e "  ${BOLD}Отключение iOS Fix v2${NC}"; echo ""
        echo -e "  ${DIM}Редирект ${IOS2_EXTERNAL_PORT} → ${IOS2_TARGET_PORT:-${PROXY_PORT:-443}} будет удалён.${NC}"; echo ""
        echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
        local _confirm; read -r _confirm
        [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }
    fi

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
    log_success "Доп. правило #${_idx}: порт=${_port}$([ -n "$_ip" ] && echo " ip=${_ip}") rate=${_rate} burst=${_burst}"
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

# ── Полная очистка при удалении MTProxyL ──────────────────────
nft_full_cleanup() {
    remove_nft_rules 2>/dev/null || true
    remove_nft_service 2>/dev/null || true
    ios_fix_remove true 2>/dev/null || true
    ios2_fix_remove true 2>/dev/null || true
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
    echo -e "  ${BOLD}Счётчик правил (Ctrl+C для выхода):${NC}"; echo ""
    watch -n 2 "nft list chain inet $_table input 2>/dev/null | grep -E 'counter|comment'"
}

# ── Статусы для шапки ─────────────────────────────────────────
nft_status_line() {
    if nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null; then
        if [ "$NFT_MODE" = "smart" ]; then
            local _ip_info=""
            [ -n "${NFT_SERVER_IP:-}" ] && _ip_info=" ip=${NFT_SERVER_IP}"
            echo -e "${GREEN}Smart By-MEKO${NC} (iOS: ${NFT_IOS_RATE}/${NFT_IOS_BURST} Other: ${NFT_OTHER_RATE}/${NFT_OTHER_BURST}${_ip_info})"
        else
            if [ -n "${NFT_SERVER_IP:-}" ]; then
                echo -e "${GREEN}Classic${NC} (${NFT_RATE} burst ${NFT_BURST} ip=${NFT_SERVER_IP})"
            else
                echo -e "${GREEN}Classic${NC} (${NFT_RATE} burst ${NFT_BURST} все IP)"
            fi
        fi
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
        if [ "$NFT_MODE" = "smart" ]; then
            echo -e "${YELLOW}v2 активен${NC} (${IOS2_EXTERNAL_PORT}→${IOS2_TARGET_PORT:-${PROXY_PORT:-443}}) ${DIM}[Smart делает это ненужным]${NC}"
        else
            echo -e "${GREEN}v2 активен${NC} (${IOS2_EXTERNAL_PORT}→${IOS2_TARGET_PORT:-${PROXY_PORT:-443}} mss=${IOS2_MSS})"
        fi
    else
        if [ "$NFT_MODE" = "smart" ]; then
            echo -e "${DIM}не нужен (Smart режим)${NC}"
        else
            echo -e "${DIM}не применён${NC}"
        fi
    fi
}
