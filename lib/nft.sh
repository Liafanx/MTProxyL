#!/bin/bash
# MTProxyL — NFT SYN limiter + Zapret2 + iOS фиксы + Smart режим + доп. правила

NFT_CONF="${INSTALL_DIR}/nft-rules.conf"
NFT_SCRIPT_FILE="/usr/local/sbin/mtproxyl-syn-limit.sh"
NFT_SYSTEMD_UNIT="mtproxyl-syn-limit.service"
IOS_SYSCTL_FILE="/etc/sysctl.d/99-mtproxyl-keepalive.conf"
IOS2_NFT_TABLE="mtproxyl_ios2"

# Reanimator: watcher IP Docker-bridge цели (только DETECT_BRIDGE_STRATEGY=precise)
BRIDGE_WATCH_SCRIPT="/usr/local/sbin/mtproxyl-bridge-watch.sh"
BRIDGE_WATCH_UNIT="mtproxyl-bridge-watch.service"
BRIDGE_WATCH_INTERVAL="5"

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
NFT_IOS_LIMIT_ENABLED="false"
NFT_OTHER_LIMIT_ENABLED="true"
NFT_IOS_DETECT="fingerprint"

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

# ── Zapret2 MTProto fix ───────────────────────────────────────
ZAPRET2_DIR="/opt/mtproxyl-zapret2"
ZAPRET2_ETC_DIR="/etc/mtproxyl-zapret2"
ZAPRET2_BIN="${ZAPRET2_DIR}/bin/nfqws2"
ZAPRET2_LUA_DIR="${ZAPRET2_DIR}/lua"
ZAPRET2_CONF="${ZAPRET2_ETC_DIR}/mtproto.conf"
ZAPRET2_LUA="${ZAPRET2_LUA_DIR}/mtproto.lua"
ZAPRET2_SERVICE="mtproxyl-zapret2.service"
ZAPRET2_NFT_TABLE="MTProtoL"
# Значения по умолчанию держим одним набором: их же показывает и
# восстанавливает пункт «Сброс к дефолту», иначе сброс уводил настройки
# к значениям, которых нет ни у одной свежей установки.
ZAPRET2_DEFAULT_FWMARK="0x40000000"
ZAPRET2_DEFAULT_QNUM="200"
ZAPRET2_DEFAULT_OUT_RANGE="a"
ZAPRET2_DEFAULT_IN_RANGE="a"
ZAPRET2_DEFAULT_SPLIT_LEN="400"
ZAPRET2_DEFAULT_WIN_SYNACK="1400"
ZAPRET2_DEFAULT_WIN_ACK="10"

ZAPRET2_FWMARK="$ZAPRET2_DEFAULT_FWMARK"
ZAPRET2_QNUM="$ZAPRET2_DEFAULT_QNUM"
ZAPRET2_OUT_RANGE="$ZAPRET2_DEFAULT_OUT_RANGE"
ZAPRET2_IN_RANGE="$ZAPRET2_DEFAULT_IN_RANGE"
ZAPRET2_SPLIT_LEN="$ZAPRET2_DEFAULT_SPLIT_LEN"
ZAPRET2_DEBUG="false"
ZAPRET2_DEBUG_LOG="/var/log/mtproxyl-nfqws2.log"
ZAPRET2_WIN_SYNACK="$ZAPRET2_DEFAULT_WIN_SYNACK"
ZAPRET2_WIN_ACK="$ZAPRET2_DEFAULT_WIN_ACK"
# Доп. порты/диапазоны для --filter-tcp, через запятую (напр. "8443,9000-9100").
# Порт прокси добавляется автоматически и здесь не нужен.
ZAPRET2_EXTRA_PORTS=""
ZAPRET2_APPLIED="false"
ZAPRET2_SERVICE_ENABLED="false"

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
NFT_OTHER_RATE='${NFT_OTHER_RATE}'
NFT_OTHER_BURST='${NFT_OTHER_BURST}'
NFT_IOS_LIMIT_ENABLED='${NFT_IOS_LIMIT_ENABLED}'
NFT_OTHER_LIMIT_ENABLED='${NFT_OTHER_LIMIT_ENABLED}'
NFT_IOS_DETECT='${NFT_IOS_DETECT}'
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
NFT_OTHER_ACTION='${NFT_OTHER_ACTION}'
MEKO_OPT_APPLIED='${MEKO_OPT_APPLIED}'
MEKO_ORIG_KEEPALIVE_TIME='${MEKO_ORIG_KEEPALIVE_TIME}'
MEKO_ORIG_KEEPALIVE_INTVL='${MEKO_ORIG_KEEPALIVE_INTVL}'
MEKO_ORIG_KEEPALIVE_PROBES='${MEKO_ORIG_KEEPALIVE_PROBES}'
MEKO_ORIG_SOMAXCONN='${MEKO_ORIG_SOMAXCONN}'
MEKO_ORIG_TCP_MAX_SYN_BACKLOG='${MEKO_ORIG_TCP_MAX_SYN_BACKLOG}'
MEKO_ORIG_NETDEV_MAX_BACKLOG='${MEKO_ORIG_NETDEV_MAX_BACKLOG}'
MEKO_ORIG_TCP_FASTOPEN='${MEKO_ORIG_TCP_FASTOPEN}'
MEKO_ORIG_FILE_MAX='${MEKO_ORIG_FILE_MAX}'
MEKO_ORIG_DEFAULT_QDISC='${MEKO_ORIG_DEFAULT_QDISC}'
MEKO_ORIG_TCP_CONGESTION='${MEKO_ORIG_TCP_CONGESTION}'
NFT_EXTRA_COUNT='${NFT_EXTRA_COUNT}'
ZAPRET2_APPLIED='${ZAPRET2_APPLIED}'
ZAPRET2_SERVICE_ENABLED='${ZAPRET2_SERVICE_ENABLED}'
ZAPRET2_OUT_RANGE='${ZAPRET2_OUT_RANGE}'
ZAPRET2_IN_RANGE='${ZAPRET2_IN_RANGE}'
ZAPRET2_SPLIT_LEN='${ZAPRET2_SPLIT_LEN}'
ZAPRET2_WIN_SYNACK='${ZAPRET2_WIN_SYNACK}'
ZAPRET2_WIN_ACK='${ZAPRET2_WIN_ACK}'
ZAPRET2_EXTRA_PORTS='${ZAPRET2_EXTRA_PORTS}'
ZAPRET2_QNUM='${ZAPRET2_QNUM}'
ZAPRET2_FWMARK='${ZAPRET2_FWMARK}'
ZAPRET2_DEBUG='${ZAPRET2_DEBUG}'
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
    local _have_ios_detect="false"
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
                NFT_IOS_LIMIT_ENABLED|NFT_OTHER_LIMIT_ENABLED|NFT_IOS_DETECT|\
                IOS_FIX_ENABLED|IOS_KA_TIME|IOS_KA_INTVL|IOS_KA_PROBES|\
                IOS_ORIG_TIME|IOS_ORIG_INTVL|IOS_ORIG_PROBES|\
                IOS2_FIX_ENABLED|IOS2_EXTERNAL_PORT|IOS2_TARGET_PORT|IOS2_MSS|\
                NFT_OTHER_ACTION|\
                MEKO_OPT_APPLIED|\
                MEKO_ORIG_KEEPALIVE_TIME|MEKO_ORIG_KEEPALIVE_INTVL|MEKO_ORIG_KEEPALIVE_PROBES|\
                MEKO_ORIG_SOMAXCONN|MEKO_ORIG_TCP_MAX_SYN_BACKLOG|MEKO_ORIG_NETDEV_MAX_BACKLOG|\
                MEKO_ORIG_TCP_FASTOPEN|MEKO_ORIG_FILE_MAX|\
                MEKO_ORIG_DEFAULT_QDISC|MEKO_ORIG_TCP_CONGESTION|\
                NFT_EXTRA_COUNT|\
                ZAPRET2_APPLIED|ZAPRET2_SERVICE_ENABLED|\
                ZAPRET2_OUT_RANGE|ZAPRET2_IN_RANGE|ZAPRET2_SPLIT_LEN|\
                ZAPRET2_WIN_SYNACK|ZAPRET2_WIN_ACK|ZAPRET2_EXTRA_PORTS|\
                ZAPRET2_QNUM|ZAPRET2_FWMARK|ZAPRET2_DEBUG)
                    printf -v "$_key" '%s' "$_val"
                    [ "$_key" = "NFT_IOS_DETECT" ] && _have_ios_detect="true"
                    ;;
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
    case "$NFT_OTHER_ACTION" in
        reject|drop|icmp-host-unreachable) ;;
        *) NFT_OTHER_ACTION="icmp-host-unreachable" ;;
    esac

    [ "$NFT_IOS_LIMIT_ENABLED" != "true" ] && [ "$NFT_IOS_LIMIT_ENABLED" != "false" ] && NFT_IOS_LIMIT_ENABLED="true"
    [ "$NFT_OTHER_LIMIT_ENABLED" != "true" ] && [ "$NFT_OTHER_LIMIT_ENABLED" != "false" ] && NFT_OTHER_LIMIT_ENABLED="true"

    case "$NFT_IOS_DETECT" in
        fingerprint|ttl) ;;
        *)
            # Обратная совместимость: старые конфиги MTProxyL использовали TTL+Length
            if [ "$_have_ios_detect" != "true" ]; then
                NFT_IOS_DETECT="ttl"
            else
                NFT_IOS_DETECT="fingerprint"
            fi
            ;;
    esac
}

# ── Применить NFT правила после изменения настроек ────────────
prompt_apply_nft_rules() {
    echo ""
    echo -en "  ${BOLD}Применить новые NFT-правила сейчас? [Y/n]:${NC} "
    local _yn; read_line _yn
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
        if [ "$NFT_MODE" = "smart" ]; then
            case "${NFT_OTHER_ACTION:-icmp-host-unreachable}" in
                drop)
                    _extra_action="drop" ;;
                icmp-host-unreachable)
                    _extra_action="reject with icmp type host-unreachable" ;;
                *)
                    _extra_action="reject with tcp reset" ;;
            esac
        fi

        cat >> "$NFT_SCRIPT_FILE" << EXTRAEOF
nft "add rule inet \$TABLE input ${_extra_ip_match}tcp dport ${_eport} tcp flags & (syn | ack) == syn meter mtproxyl_syn_extra_${_i} { ip saddr timeout ${_timeout} limit rate over ${_erate} burst ${_eburst} packets } counter ${_extra_action} comment \\"mtproxyl_extra_${_i}\\""
EXTRAEOF
    done

    # iOS Fix v2 (только в classic режиме, smart не нуждается)
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
    local _ios_limit="${NFT_IOS_LIMIT_ENABLED:-true}"
    local _other_limit="${NFT_OTHER_LIMIT_ENABLED:-true}"
    local _ios_detect="${NFT_IOS_DETECT:-fingerprint}"

    local _ios_match
    if [ "$_ios_detect" = "ttl" ]; then
        _ios_match="ip ttl < 65 meta length 64"
    else
        _ios_match="@th,108,20 0x2ffff @th,160,16 0x204 @th,192,16 0x103 @th,224,24 0x10108 @th,320,32 0x4020000"
    fi

    if [ "$_ios_limit" = "true" ]; then
        cat >> "$NFT_SCRIPT_FILE" << SMART1EOF
nft "add rule inet \$TABLE input ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn ${_ios_match} meter mtproxyl_ios { ip saddr timeout ${_timeout} limit rate ${_ios_rate} burst ${_ios_burst} packets } counter accept comment \\"mtproxyl_smart_ios_accept\\""
SMART1EOF

        cat >> "$NFT_SCRIPT_FILE" << SMART2EOF
nft "add rule inet \$TABLE input ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn ${_ios_match} counter reject with tcp reset comment \\"mtproxyl_smart_ios_reject\\""
SMART2EOF
    else
        cat >> "$NFT_SCRIPT_FILE" << SMART1NOLIMEOF
nft "add rule inet \$TABLE input ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn ${_ios_match} counter accept comment \\"mtproxyl_smart_ios_accept\\""
SMART1NOLIMEOF
    fi

    local _other_action_cmd
    case "${NFT_OTHER_ACTION:-icmp-host-unreachable}" in
        drop)
            _other_action_cmd="drop" ;;
        icmp-host-unreachable)
            _other_action_cmd="reject with icmp type host-unreachable" ;;
        *)
            _other_action_cmd="reject with tcp reset" ;;
    esac

    if [ "$_other_limit" = "true" ]; then
        cat >> "$NFT_SCRIPT_FILE" << SMART3EOF
nft "add rule inet \$TABLE input ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn meter mtproxyl_other { ip saddr timeout ${_timeout} limit rate ${_other_rate} burst ${_other_burst} packets } counter accept comment \\"mtproxyl_smart_other_accept\\""
SMART3EOF

        cat >> "$NFT_SCRIPT_FILE" << SMART4EOF
nft "add rule inet \$TABLE input ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn counter ${_other_action_cmd} comment \\"mtproxyl_smart_other_reject\\""
SMART4EOF
    else
        cat >> "$NFT_SCRIPT_FILE" << SMART3NOLIMEOF
nft "add rule inet \$TABLE input ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn counter accept comment \\"mtproxyl_smart_other_accept\\""
SMART3NOLIMEOF
    fi
}

# ── Применение / удаление правил ──────────────────────────────
ensure_nftables_installed() {
    command -v nft &>/dev/null && return 0

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
}

apply_nft_rules() {
    ensure_nftables_installed || return 1

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
# ── Reanimator: watcher для точного bridge-режима ──────────────
_bridge_watch_needed() {
    [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] && \
    [ "${DETECTED_NETWORK_MODE:-host}" = "bridge" ] && \
    [ "${DETECT_BRIDGE_STRATEGY:-simple}" = "precise" ]
}

mtproxyl_generate_bridge_watch_script() {
    cat > "$BRIDGE_WATCH_SCRIPT" << EOF
#!/bin/sh
set -eu

CONTAINER="${DETECTED_CONTAINER}"
NFT_SCRIPT="${NFT_SCRIPT_FILE}"
INTERVAL="${BRIDGE_WATCH_INTERVAL}"

LAST_IP=""

echo "MTProxyL reanimator: watching container \$CONTAINER (bridge precise mode)"

while true; do
    RUNNING="\$(docker inspect -f '{{.State.Running}}' "\$CONTAINER" 2>/dev/null || true)"

    if [ "\$RUNNING" = "true" ]; then
        IP="\$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' "\$CONTAINER" 2>/dev/null | awk 'NF {print; exit}')"

        if [ -n "\$IP" ] && [ "\$IP" != "\$LAST_IP" ]; then
            echo "Container IP changed: \${LAST_IP:-none} -> \$IP"
            if systemctl is-active mtproxyl-zapret2.service >/dev/null 2>&1 || systemctl is-enabled mtproxyl-zapret2.service >/dev/null 2>&1; then
                systemctl restart mtproxyl-zapret2.service || true
            elif [ -f "\$NFT_SCRIPT" ]; then
                /bin/sh "\$NFT_SCRIPT" || true
            fi
            LAST_IP="\$IP"
        fi
    else
        if [ -n "\$LAST_IP" ]; then
            echo "Container \$CONTAINER is not running"
            LAST_IP=""
        fi
    fi

    sleep "\$INTERVAL"
done
EOF
    chmod +x "$BRIDGE_WATCH_SCRIPT"
    log_success "Watcher-скрипт создан: ${BRIDGE_WATCH_SCRIPT}"
}

remove_bridge_watch_service() {
    systemctl disable --now "$BRIDGE_WATCH_UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/${BRIDGE_WATCH_UNIT}"
    rm -f "$BRIDGE_WATCH_SCRIPT"
    systemctl daemon-reload 2>/dev/null || true
}

# Watcher нужен и для SYN limiter, и для zapret2: в bridge/precise IP
# контейнера может измениться после его перезапуска, и правила надо
# переналожить. Поэтому вынесено в отдельную функцию.
install_bridge_watch_service() {
    systemctl disable --now "$BRIDGE_WATCH_UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/${BRIDGE_WATCH_UNIT}"

    _bridge_watch_needed || { systemctl daemon-reload 2>/dev/null || true; return 0; }

    mtproxyl_generate_bridge_watch_script

    cat > "/etc/systemd/system/${BRIDGE_WATCH_UNIT}" << EOF
[Unit]
Description=MTProxyL reanimator Docker bridge watcher
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BRIDGE_WATCH_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$BRIDGE_WATCH_UNIT" 2>/dev/null
    systemctl restart "$BRIDGE_WATCH_UNIT" 2>/dev/null
    log_success "Установлена watcher-служба для точного Docker bridge-режима"
}

install_nft_service() {
    generate_nft_script
    local _table="${NFT_TABLE:-mtproxyl_limit}"
    local _ios2_table="${IOS2_NFT_TABLE}"

    install_bridge_watch_service

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
    remove_bridge_watch_service
    systemctl daemon-reload 2>/dev/null || true
    NFT_ENABLED="false"
    save_nft_settings
    log_success "Служба NFT limiter удалена"
}

# ── Пресеты ───────────────────────────────────────────────────
apply_nft_preset() {
    case "$1" in
        # classic — единственный стандартный вариант лимитера (1/second
        # burst 1); всё остальное задаётся вручную. hard оставлен как
        # синоним для совместимости со старыми вызовами CLI.
        classic|hard) NFT_MODE="classic"; NFT_RATE="1/second"; NFT_BURST="1" ;;
        smart)
            NFT_MODE="smart"
            NFT_REJECT_MODE="reset"
            NFT_IOS_RATE="15/second"
            NFT_IOS_BURST="30"
            NFT_OTHER_RATE="54/minute"
            NFT_OTHER_BURST="1"
            NFT_IOS_LIMIT_ENABLED="false"
            NFT_OTHER_LIMIT_ENABLED="true"
            NFT_IOS_DETECT="fingerprint"
            NFT_OTHER_ACTION="icmp-host-unreachable"
            ;;
        *) log_error "Неизвестный пресет: $1"; return 1 ;;
    esac
    save_nft_settings
    if [ "$1" = "smart" ]; then
        log_success "Пресет: Smart By-MEKO (iOS: ${NFT_IOS_RATE} burst ${NFT_IOS_BURST} / Other: ${NFT_OTHER_RATE} burst ${NFT_OTHER_BURST})"
    else
        log_success "Classic лимитер: rate=$NFT_RATE burst=$NFT_BURST"
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
    local _yn; read_line _yn
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
    local _t; read_line _t; [[ "$_t" =~ ^[0-9]+$ ]] && IOS_KA_TIME="$_t"
    echo -en "    tcp_keepalive_intvl  [${IOS_KA_INTVL}]: "
    local _i; read_line _i; [[ "$_i" =~ ^[0-9]+$ ]] && IOS_KA_INTVL="$_i"
    echo -en "    tcp_keepalive_probes [${IOS_KA_PROBES}]: "
    local _p; read_line _p; [[ "$_p" =~ ^[0-9]+$ ]] && IOS_KA_PROBES="$_p"

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
    local _confirm; read_line _confirm
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
        local _confirm; read_line _confirm
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
        local _proceed; read_line _proceed
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
        local _force; read_line _force
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
    local _confirm; read_line _confirm
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
        local _confirm; read_line _confirm
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

# ── Оптимизация By-MEKO ───────────────────────────────────────
meko_opt_status() {
    if [ -f "$MEKO_OPT_FILE" ]; then
        local _ka _ki _kp
        _ka=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
        _ki=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
        _kp=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
        echo -e "${GREEN}применена${NC} (keepalive: ${_ka}s/${_ki}s×${_kp}, BBR)"
    else
        echo -e "${DIM}не применена${NC}"
    fi
}

meko_opt_apply() {
    echo ""
    echo -e "  ${BRIGHT_CYAN}${BOLD}Оптимизация системы By-MEKO${NC}"
    echo ""
    echo -e "  ${DIM}Применяет набор sysctl-параметров из проекта MTPROTO-FIX-By-MEKO:${NC}"
    echo ""
    echo -e "  ${BOLD}TCP keepalive${NC} — ускоряет обнаружение мёртвых сокетов:"
    echo -e "    tcp_keepalive_time   = ${YELLOW}45${NC}      ${DIM}(текущее: $(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null), дефолт: 7200)${NC}"
    echo -e "    tcp_keepalive_intvl  = ${YELLOW}15${NC}      ${DIM}(текущее: $(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null), дефолт: 75)${NC}"
    echo -e "    tcp_keepalive_probes = ${YELLOW}3${NC}       ${DIM}(текущее: $(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null), дефолт: 9)${NC}"
    echo ""
    echo -e "  ${BOLD}Сетевые очереди:${NC}"
    echo -e "    net.core.somaxconn           = ${YELLOW}65535${NC}   ${DIM}(текущее: $(sysctl -n net.core.somaxconn 2>/dev/null))${NC}"
    echo -e "    net.ipv4.tcp_max_syn_backlog  = ${YELLOW}65535${NC}   ${DIM}(текущее: $(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null))${NC}"
    echo -e "    net.core.netdev_max_backlog   = ${YELLOW}65535${NC}   ${DIM}(текущее: $(sysctl -n net.core.netdev_max_backlog 2>/dev/null))${NC}"
    echo ""
    echo -e "  ${BOLD}Производительность:${NC}"
    echo -e "    net.ipv4.tcp_fastopen           = ${YELLOW}3${NC}       ${DIM}(текущее: $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null))${NC}"
    echo -e "    fs.file-max                     = ${YELLOW}2097152${NC} ${DIM}(текущее: $(sysctl -n fs.file-max 2>/dev/null))${NC}"
    echo -e "    net.core.default_qdisc          = ${YELLOW}fq${NC}      ${DIM}(текущее: $(sysctl -n net.core.default_qdisc 2>/dev/null))${NC}"
    echo -e "    net.ipv4.tcp_congestion_control = ${YELLOW}bbr${NC}     ${DIM}(текущее: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null))${NC}"
    echo ""
    echo -e "  ${DIM}Все текущие значения будут сохранены для полного отката.${NC}"
    echo ""

    if [ -f "$MEKO_OPT_FILE" ]; then
        echo -e "  ${YELLOW}Оптимизация уже применена. Применить заново?${NC}"
        echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
    else
        echo -en "  ${BOLD}Применить оптимизацию? [Y/n]:${NC} "
    fi
    local _confirm; read_line _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }

    if [ -z "$MEKO_ORIG_KEEPALIVE_TIME" ]; then
        MEKO_ORIG_KEEPALIVE_TIME=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "7200")
        MEKO_ORIG_KEEPALIVE_INTVL=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo "75")
        MEKO_ORIG_KEEPALIVE_PROBES=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo "9")
        MEKO_ORIG_SOMAXCONN=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "4096")
        MEKO_ORIG_TCP_MAX_SYN_BACKLOG=$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo "512")
        MEKO_ORIG_NETDEV_MAX_BACKLOG=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "1000")
        MEKO_ORIG_TCP_FASTOPEN=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "1")
        MEKO_ORIG_FILE_MAX=$(sysctl -n fs.file-max 2>/dev/null || echo "65536")
        MEKO_ORIG_DEFAULT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "pfifo_fast")
        MEKO_ORIG_TCP_CONGESTION=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
        log_info "Сохранены оригинальные значения для отката"
    fi

    cat > "$MEKO_OPT_FILE" << 'SYSEOF'
# MTProxyL: оптимизация By-MEKO
# Источник: github.com/Mekotofeuka/MTPR-FIX-By-MEKO
net.ipv4.tcp_keepalive_time = 45
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_fastopen = 3
fs.file-max = 2097152
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSEOF

    if sysctl --system &>/dev/null; then
        log_success "sysctl применён"
    else
        log_warn "sysctl --system вернул ошибку, применяем вручную"
        sysctl -w net.ipv4.tcp_keepalive_time=45 2>/dev/null || true
        sysctl -w net.ipv4.tcp_keepalive_intvl=15 2>/dev/null || true
        sysctl -w net.ipv4.tcp_keepalive_probes=3 2>/dev/null || true
        sysctl -w net.core.somaxconn=65535 2>/dev/null || true
        sysctl -w net.ipv4.tcp_max_syn_backlog=65535 2>/dev/null || true
        sysctl -w net.core.netdev_max_backlog=65535 2>/dev/null || true
        sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null || true
        sysctl -w fs.file-max=2097152 2>/dev/null || true
        sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
        sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
    fi

    echo ""
    echo -e "  ${BOLD}Применённые значения:${NC}"
    echo -e "    tcp_keepalive_time   = $(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)"
    echo -e "    tcp_keepalive_intvl  = $(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)"
    echo -e "    tcp_keepalive_probes = $(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)"
    echo -e "    somaxconn            = $(sysctl -n net.core.somaxconn 2>/dev/null)"
    echo -e "    congestion_control   = $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

    MEKO_OPT_APPLIED="true"
    save_nft_settings
    echo ""
    log_success "Оптимизация By-MEKO применена"
    echo -e "  ${DIM}Для отката: меню NFT → [m] Оптимизация By-MEKO → Откатить${NC}"
}

meko_opt_remove() {
    echo ""
    if [ ! -f "$MEKO_OPT_FILE" ]; then
        log_info "Оптимизация By-MEKO не установлена"
        MEKO_OPT_APPLIED="false"
        save_nft_settings
        return 0
    fi

    echo -e "  ${BOLD}Откат оптимизации By-MEKO${NC}"; echo ""
    echo -e "  ${DIM}Будет удалён: ${MEKO_OPT_FILE}${NC}"
    echo -e "  ${DIM}Значения будут восстановлены к тем, что были до применения:${NC}"
    echo ""
    echo -e "    tcp_keepalive_time   → ${MEKO_ORIG_KEEPALIVE_TIME:-7200}"
    echo -e "    tcp_keepalive_intvl  → ${MEKO_ORIG_KEEPALIVE_INTVL:-75}"
    echo -e "    tcp_keepalive_probes → ${MEKO_ORIG_KEEPALIVE_PROBES:-9}"
    echo -e "    somaxconn            → ${MEKO_ORIG_SOMAXCONN:-4096}"
    echo -e "    tcp_max_syn_backlog  → ${MEKO_ORIG_TCP_MAX_SYN_BACKLOG:-512}"
    echo -e "    netdev_max_backlog   → ${MEKO_ORIG_NETDEV_MAX_BACKLOG:-1000}"
    echo -e "    tcp_fastopen         → ${MEKO_ORIG_TCP_FASTOPEN:-1}"
    echo -e "    file-max             → ${MEKO_ORIG_FILE_MAX:-65536}"
    echo -e "    default_qdisc        → ${MEKO_ORIG_DEFAULT_QDISC:-pfifo_fast}"
    echo -e "    congestion_control   → ${MEKO_ORIG_TCP_CONGESTION:-cubic}"
    echo ""
    echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
    local _confirm; read_line _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }

    rm -f "$MEKO_OPT_FILE"
    sysctl -w "net.ipv4.tcp_keepalive_time=${MEKO_ORIG_KEEPALIVE_TIME:-7200}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_keepalive_intvl=${MEKO_ORIG_KEEPALIVE_INTVL:-75}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_keepalive_probes=${MEKO_ORIG_KEEPALIVE_PROBES:-9}" &>/dev/null || true
    sysctl -w "net.core.somaxconn=${MEKO_ORIG_SOMAXCONN:-4096}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_max_syn_backlog=${MEKO_ORIG_TCP_MAX_SYN_BACKLOG:-512}" &>/dev/null || true
    sysctl -w "net.core.netdev_max_backlog=${MEKO_ORIG_NETDEV_MAX_BACKLOG:-1000}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_fastopen=${MEKO_ORIG_TCP_FASTOPEN:-1}" &>/dev/null || true
    sysctl -w "fs.file-max=${MEKO_ORIG_FILE_MAX:-65536}" &>/dev/null || true
    sysctl -w "net.core.default_qdisc=${MEKO_ORIG_DEFAULT_QDISC:-pfifo_fast}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_congestion_control=${MEKO_ORIG_TCP_CONGESTION:-cubic}" &>/dev/null || true
    sysctl --system &>/dev/null || true

    MEKO_ORIG_KEEPALIVE_TIME=""; MEKO_ORIG_KEEPALIVE_INTVL=""; MEKO_ORIG_KEEPALIVE_PROBES=""
    MEKO_ORIG_SOMAXCONN=""; MEKO_ORIG_TCP_MAX_SYN_BACKLOG=""; MEKO_ORIG_NETDEV_MAX_BACKLOG=""
    MEKO_ORIG_TCP_FASTOPEN=""; MEKO_ORIG_FILE_MAX=""
    MEKO_ORIG_DEFAULT_QDISC=""; MEKO_ORIG_TCP_CONGESTION=""
    MEKO_OPT_APPLIED="false"
    save_nft_settings

    echo ""
    echo -e "  ${BOLD}Текущие значения после отката:${NC}"
    echo -e "    tcp_keepalive_time   = $(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)"
    echo -e "    tcp_keepalive_intvl  = $(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)"
    echo -e "    congestion_control   = $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo ""
    log_success "Оптимизация By-MEKO откачена"
}

# ── Полная очистка при удалении MTProxyL ──────────────────────
nft_full_cleanup() {
    remove_nft_rules 2>/dev/null || true
    remove_nft_service 2>/dev/null || true
    ios_fix_remove true 2>/dev/null || true
    ios2_fix_remove true 2>/dev/null || true
    zapret2_full_cleanup 2>/dev/null || true
    # Откат оптимизации By-MEKO при удалении
    if [ -f "${MEKO_OPT_FILE}" ]; then
        rm -f "$MEKO_OPT_FILE"
        sysctl -w "net.ipv4.tcp_keepalive_time=${MEKO_ORIG_KEEPALIVE_TIME:-7200}" &>/dev/null || true
        sysctl -w "net.ipv4.tcp_keepalive_intvl=${MEKO_ORIG_KEEPALIVE_INTVL:-75}" &>/dev/null || true
        sysctl -w "net.ipv4.tcp_keepalive_probes=${MEKO_ORIG_KEEPALIVE_PROBES:-9}" &>/dev/null || true
        sysctl -w "net.core.somaxconn=${MEKO_ORIG_SOMAXCONN:-4096}" &>/dev/null || true
        sysctl -w "net.ipv4.tcp_max_syn_backlog=${MEKO_ORIG_TCP_MAX_SYN_BACKLOG:-512}" &>/dev/null || true
        sysctl -w "net.core.netdev_max_backlog=${MEKO_ORIG_NETDEV_MAX_BACKLOG:-1000}" &>/dev/null || true
        sysctl -w "net.ipv4.tcp_fastopen=${MEKO_ORIG_TCP_FASTOPEN:-1}" &>/dev/null || true
        sysctl -w "fs.file-max=${MEKO_ORIG_FILE_MAX:-65536}" &>/dev/null || true
        sysctl -w "net.core.default_qdisc=${MEKO_ORIG_DEFAULT_QDISC:-pfifo_fast}" &>/dev/null || true
        sysctl -w "net.ipv4.tcp_congestion_control=${MEKO_ORIG_TCP_CONGESTION:-cubic}" &>/dev/null || true
        sysctl --system &>/dev/null || true
        log_info "Оптимизация By-MEKO откачена"
    fi
    rm -f "$NFT_CONF"
}

show_nft_drop_counter() {
    local _table="${NFT_TABLE:-mtproxyl_limit}"
    local _ios2_table="${IOS2_NFT_TABLE:-mtproxyl_ios2}"
    local _z_table="${ZAPRET2_NFT_TABLE:-MTProtoL}"

    local _limiter_active="false"
    local _zapret_active="false"
    local _ios2_active="false"

    nft list table inet "$_table" &>/dev/null 2>&1 && _limiter_active="true"
    nft list table ip "$_z_table" &>/dev/null 2>&1 && _zapret_active="true"
    nft list table inet "$_ios2_table" &>/dev/null 2>&1 && _ios2_active="true"

    if [ "$_limiter_active" != "true" ] && [ "$_zapret_active" != "true" ] && [ "$_ios2_active" != "true" ]; then
        log_warn "Активных NFT правил не найдено"
        return 1
    fi

    echo ""
    if [ "$_zapret_active" = "true" ] && [ "$_limiter_active" = "true" ]; then
        echo -e "  ${BOLD}Счётчики всех активных правил (Zapret2 + SYN limiter) (Ctrl+C для выхода):${NC}"
    elif [ "$_zapret_active" = "true" ]; then
        echo -e "  ${BOLD}Счётчик правил Zapret2 (Ctrl+C для выхода):${NC}"
    elif [ "$NFT_MODE" = "smart" ]; then
        echo -e "  ${BOLD}Счётчик правил Smart By-MEKO (Ctrl+C для выхода):${NC}"
    else
        echo -e "  ${BOLD}Счётчик правил Classic (Ctrl+C для выхода):${NC}"
    fi
    echo ""

    local _watch_script
    _watch_script=$(mktemp /tmp/mtproxyl-watch.XXXXXX.sh)
    chmod +x "$_watch_script"

    cat > "$_watch_script" << WATCHEOF
#!/bin/sh
TABLE="${_table}"
IOS2_TABLE="${_ios2_table}"
ZTABLE="${_z_table}"

_has_output="false"

if nft list table ip "\$ZTABLE" >/dev/null 2>&1; then
    echo "=== Zapret2 (ip \$ZTABLE) ==="
    nft list table ip "\$ZTABLE" 2>/dev/null | grep -E 'counter|queue|notrack|ct mark' | sed 's/^/  /'
    _has_output="true"
fi

if nft list table inet "\$TABLE" >/dev/null 2>&1; then
    [ "\$_has_output" = "true" ] && echo ""
    echo "=== SYN limiter (inet \$TABLE / chain input) ==="
    nft list chain inet "\$TABLE" input 2>/dev/null | grep -E 'counter|comment' | sed 's/^/  /'
    _has_output="true"
fi

if nft list table inet "\$IOS2_TABLE" >/dev/null 2>&1; then
    [ "\$_has_output" = "true" ] && echo ""
    echo "=== iOS Fix v2 (inet \$IOS2_TABLE) ==="
    nft list table inet "\$IOS2_TABLE" 2>/dev/null | grep -E 'counter|comment' | sed 's/^/  /'
fi
WATCHEOF

    watch -n 2 "/bin/sh $_watch_script"
    rm -f "$_watch_script"
}

# ══════════════════════════════════════════════════════════════
#  Zapret2 MTProto fix для MTProxyL
# ══════════════════════════════════════════════════════════════

# Кто держит NFQUEUE: во второй колонке /proc/net/netfilter/nfnetlink_queue
# лежит netlink portid, который у nfqws/nfqws2 совпадает с PID процесса.
zapret2_queue_holder() {
    local _q="${1:-200}" _portid _pid _comm
    _portid=$(awk -v q="$_q" '$1 == q { print $2; exit }' /proc/net/netfilter/nfnetlink_queue 2>/dev/null)
    [ -n "$_portid" ] || return 1
    _pid="$_portid"
    if [ -r "/proc/${_pid}/comm" ]; then
        _comm=$(tr -d '\n' < "/proc/${_pid}/comm" 2>/dev/null)
        echo "${_comm:-?} (pid ${_pid})"
    else
        echo "процесс с portid ${_portid}"
    fi
}

# Снимаем СВОЙ экземпляр zapret2 перед проверкой занятости очереди.
# Иначе при повторной установке (и при «первой» установке поверх остатков
# прошлой попытки) работающий nfqws2 держит свою же очередь, проверка
# считает её занятой чужим процессом и установка молча переезжает на
# другой номер.
zapret2_free_own_queue() {
    zapret2_has_residue || return 0
    log_info "Найден работающий/остаточный экземпляр zapret2 — останавливаем перед установкой"
    zapret2_stop
    # Процессы вне systemd (запуск руками, оборванная установка)
    if pgrep -x nfqws2 >/dev/null 2>&1 || pgrep -f "$ZAPRET2_BIN" >/dev/null 2>&1; then
        pkill -x nfqws2 2>/dev/null || true
        pkill -f "$ZAPRET2_BIN" 2>/dev/null || true
        sleep 1
    fi
}

zapret2_find_free_queue() {
    local _start="${1:-200}"
    local _end="${2:-299}"
    local _q

    modprobe nfnetlink_queue 2>/dev/null || true

    for ((_q=_start; _q<=_end; _q++)); do
        if ! awk -v q="$_q" '$1 == q { found=1 } END { exit found ? 0 : 1 }' /proc/net/netfilter/nfnetlink_queue 2>/dev/null; then
            echo "$_q"
            return 0
        fi
    done
    return 1
}

zapret2_queue_in_use() {
    local _q="${1:-200}"
    modprobe nfnetlink_queue 2>/dev/null || true
    awk -v q="$_q" '$1 == q { found=1 } END { exit found ? 0 : 1 }' /proc/net/netfilter/nfnetlink_queue 2>/dev/null
}

zapret2_has_residue() {
    nft list table ip "${ZAPRET2_NFT_TABLE}" &>/dev/null 2>&1 && return 0
    systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null 2>&1 && return 0
    systemctl is-enabled "$ZAPRET2_SERVICE" &>/dev/null 2>&1 && return 0
    [ -f "/etc/systemd/system/${ZAPRET2_SERVICE}" ] && return 0
    [ -f "/usr/local/sbin/mtproxyl-zapret2-start.sh" ] && return 0
    [ -d "$ZAPRET2_DIR" ] && return 0
    [ -d "$ZAPRET2_ETC_DIR" ] && return 0
    pgrep -f "$ZAPRET2_BIN" >/dev/null 2>&1 && return 0
    pgrep -x nfqws2 >/dev/null 2>&1 && return 0
    return 1
}

zapret2_status() {
    if [ "${ZAPRET2_APPLIED:-false}" != "true" ]; then
        echo -e "${DIM}не установлен${NC}"
        return
    fi
    if ! [ -x "$ZAPRET2_BIN" ]; then
        echo -e "${YELLOW}бинарник не найден${NC}"
        return
    fi
    if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null 2>&1; then
        local _dbg=""
        [ "${ZAPRET2_DEBUG:-false}" = "true" ] && _dbg=" ${YELLOW}debug${NC}"
        local _extra=""
        [ -n "${ZAPRET2_EXTRA_PORTS:-}" ] && _extra=" ports=$(zapret2_filter_ports)"
        local _br=""
        zapret2_is_bridge_target && _br=" bridge/${DETECT_BRIDGE_STRATEGY:-simple}"
        echo -e "${GREEN}активен${NC} (out-range=${ZAPRET2_OUT_RANGE} len=${ZAPRET2_SPLIT_LEN} win=${ZAPRET2_WIN_SYNACK}/${ZAPRET2_WIN_ACK}${_extra}${_br})${_dbg}"
    else
        echo -e "${YELLOW}установлен, остановлен${NC}"
    fi
}

zapret2_detect_arch() {
    local _arch
    _arch=$(uname -m)
    case "$_arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        arm64)   echo "arm64" ;;
        *)       echo "" ;;
    esac
}

zapret2_download_bundle() {
    ensure_nftables_installed || return 1

    local _arch
    _arch=$(zapret2_detect_arch)
    if [ -z "$_arch" ]; then
        log_error "Неподдерживаемая архитектура: $(uname -m)"
        return 1
    fi

    local _zapret_arch
    case "$_arch" in
        amd64) _zapret_arch="linux-x86_64" ;;
        arm64) _zapret_arch="linux-arm64" ;;
        *) log_error "Неподдерживаемая архитектура: $_arch"; return 1 ;;
    esac

    local _ver="v1.0.3"
    local _url="https://github.com/bol-van/zapret2/releases/download/${_ver}/zapret2-${_ver}.tar.gz"
    local _tmp="/tmp/zapret2-release.tar.gz"
    local _tmpdir="/tmp/zapret2-unpack-$$"

    log_info "Архитектура: ${_arch} (${_zapret_arch})"
    log_info "Скачивание: ${_url}"

    if ! curl -fsSL --max-time 120 -o "$_tmp" "$_url"; then
        log_error "Не удалось скачать zapret2 релиз"
        rm -f "$_tmp"
        return 1
    fi

    log_info "Распаковка..."
    rm -rf "$_tmpdir"
    mkdir -p "$_tmpdir"
    if ! tar xzf "$_tmp" -C "$_tmpdir"; then
        log_error "Не удалось распаковать архив"
        rm -f "$_tmp"; rm -rf "$_tmpdir"
        return 1
    fi
    rm -f "$_tmp"

    local _root
    _root=$(find "$_tmpdir" -maxdepth 1 -mindepth 1 -type d | head -1)
    if [ -z "$_root" ]; then
        log_error "Не удалось найти корень архива"
        rm -rf "$_tmpdir"; return 1
    fi

    local _bindir="${_root}/binaries/${_zapret_arch}"
    if [ ! -d "$_bindir" ] || [ ! -f "${_bindir}/nfqws2" ]; then
        log_error "nfqws2 не найден для архитектуры ${_zapret_arch}"
        rm -rf "$_tmpdir"; return 1
    fi

    local _luasrc=""
    local _lua_candidates=("${_root}/nfq2/lua" "${_root}/lua" "${_root}/nfq/lua")
    for _candidate in "${_lua_candidates[@]}"; do
        if [ -d "$_candidate" ] && ls "$_candidate"/zapret-lib.lua* &>/dev/null; then
            _luasrc="$_candidate"; break
        fi
    done

    if [ -z "$_luasrc" ]; then
        log_error "Lua файлы не найдены в архиве"
        rm -rf "$_tmpdir"; return 1
    fi

    mkdir -p "${ZAPRET2_DIR}/bin" "${ZAPRET2_LUA_DIR}" "${ZAPRET2_ETC_DIR}"

    cp -f "${_bindir}/nfqws2" "${ZAPRET2_DIR}/bin/"
    [ -f "${_bindir}/mdig" ]   && cp -f "${_bindir}/mdig"   "${ZAPRET2_DIR}/bin/"
    [ -f "${_bindir}/ip2net" ] && cp -f "${_bindir}/ip2net" "${ZAPRET2_DIR}/bin/"
    chmod +x "${ZAPRET2_DIR}/bin/"*

    local _lua_files="zapret-lib zapret-antidpi zapret-auto"
    for _name in $_lua_files; do
        if [ -f "${_luasrc}/${_name}.lua" ]; then
            cp -f "${_luasrc}/${_name}.lua" "${ZAPRET2_LUA_DIR}/"
        elif [ -f "${_luasrc}/${_name}.lua.gz" ]; then
            cp -f "${_luasrc}/${_name}.lua.gz" "${ZAPRET2_LUA_DIR}/"
        else
            log_warn "Lua файл ${_name}.lua не найден"
        fi
    done

    echo "zapret2 ${_ver} ($(date -u +%Y-%m-%d))" > "${ZAPRET2_DIR}/version"
    rm -rf "$_tmpdir"

    if [ -x "$ZAPRET2_BIN" ]; then
        local _version_out
        _version_out=$("$ZAPRET2_BIN" --version 2>&1 | head -1 || echo "ok")
        log_success "nfqws2 установлен: ${_version_out}"
    else
        log_error "Бинарник nfqws2 не работает"
        return 1
    fi

    log_success "zapret2 ${_ver} установлен в ${ZAPRET2_DIR}"
    return 0
}

# Список портов для --filter-tcp: порт прокси + ZAPRET2_EXTRA_PORTS.
# Формат nfqws2: port1[-port2] через запятую, количество не ограничено.
zapret2_filter_ports() {
    local _port="${PROXY_PORT:-443}"
    local _list="$_port"
    local _p
    if [ -n "${ZAPRET2_EXTRA_PORTS:-}" ]; then
        IFS=',' read -r -a _arr <<< "$ZAPRET2_EXTRA_PORTS"
        for _p in "${_arr[@]}"; do
            _p="${_p// /}"
            [ -z "$_p" ] && continue
            # не дублируем порт прокси
            [ "$_p" = "$_port" ] && continue
            _list="${_list},${_p}"
        done
    fi
    echo "$_list"
}

# Валидация одного элемента списка: порт или диапазон порт-порт
zapret2_validate_port_item() {
    local _item="${1// /}"
    if [[ "$_item" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
        local _a="${BASH_REMATCH[1]}" _b="${BASH_REMATCH[2]}"
        [ "$_a" -ge 1 ] && [ "$_a" -le 65535 ] && [ "$_b" -ge 1 ] && [ "$_b" -le 65535 ] && [ "$_a" -le "$_b" ]
        return $?
    fi
    if [[ "$_item" =~ ^[0-9]{1,5}$ ]]; then
        [ "$_item" -ge 1 ] && [ "$_item" -le 65535 ]
        return $?
    fi
    return 1
}

# Валидация всего списка ZAPRET2_EXTRA_PORTS
zapret2_validate_extra_ports() {
    local _spec="$1" _p
    [ -z "$_spec" ] && return 0
    IFS=',' read -r -a _arr <<< "$_spec"
    for _p in "${_arr[@]}"; do
        [ -z "${_p// /}" ] && continue
        zapret2_validate_port_item "$_p" || return 1
    done
    return 0
}

# Порты для NFT-правил: разворачиваем список в nft-синтаксис
# ("443" -> "443", "443,8443,9000-9100" -> "{ 443, 8443, 9000-9100 }")
zapret2_nft_port_spec() {
    local _list; _list=$(zapret2_filter_ports)
    case "$_list" in
        *,*) echo "{ ${_list//,/, } }" ;;
        *)   echo "$_list" ;;
    esac
}

zapret2_write_conf() {
    local _port; _port=$(zapret2_filter_ports)
    mkdir -p "$ZAPRET2_ETC_DIR"
    local _debug_line=""
    [ "${ZAPRET2_DEBUG:-false}" = "true" ] && _debug_line="--debug=@${ZAPRET2_DEBUG_LOG}"

    cat > "$ZAPRET2_CONF" << EOF
--qnum ${ZAPRET2_QNUM}
--fwmark=${ZAPRET2_FWMARK}
--server
${_debug_line}
--lua-init=@${ZAPRET2_LUA_DIR}/zapret-lib.lua
--lua-init=@${ZAPRET2_LUA_DIR}/zapret-antidpi.lua
--lua-init=@${ZAPRET2_LUA_DIR}/mtproto.lua
--filter-tcp=${_port}
--out-range=${ZAPRET2_OUT_RANGE}
--in-range=${ZAPRET2_IN_RANGE}
--payload-disable=all
--lua-desync=lets_resend
--new
EOF
    log_success "Конфиг записан: ${ZAPRET2_CONF} (порты=${_port})"
}

zapret2_write_lua() {
    mkdir -p "$ZAPRET2_LUA_DIR"
    cat > "$ZAPRET2_LUA" << LUAEOF
-- Zapret2 MTProto fix — MTProxyL
-- Серверный обход: disorder + badsum + window control + iOS fwmark bypass
-- https://github.com/Liafanx/MTProxyL

function lets_resend(ctx, desync)
    -- iOS fingerprint bypass: пропускаем через fwmark без обработки
    if bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == TH_SYN then
        if desync.dis.tcp.th_win == 65535 and
           #desync.dis.tcp.options == 8 and
           desync.dis.tcp.options[1].kind == 2 and
           desync.dis.tcp.options[2].kind == 1 and
           desync.dis.tcp.options[3].kind == 3 and
           desync.dis.tcp.options[4].kind == 1 and
           desync.dis.tcp.options[5].kind == 1 and
           desync.dis.tcp.options[6].kind == 8 and
           desync.dis.tcp.options[7].kind == 4 and
           desync.dis.tcp.options[8].kind == 0 then
            instance_cutoff(ctx, nil)
            desync.arg.fwmark = 0x40000
            rawsend_dissect_segmented(desync)
            return VERDICT_DROP
        end
    end

    -- SYN+ACK: запоминаем ack и зажимаем окно
    if bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == (TH_SYN + TH_ACK) then
        desync.track.lua_state["ack0"] = desync.dis.tcp.th_ack
        desync.dis.tcp.th_win = ${ZAPRET2_WIN_SYNACK}
        return VERDICT_MODIFY
    end

    -- Пустые ACK: зажимаем окно, отпускаем после первого payload
    if direction_check(desync) and bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == (TH_ACK) then
        local ack0 = desync.track and desync.track.lua_state["ack0"]
        if ack0 and (desync.dis.tcp.th_ack - ack0 >= ${ZAPRET2_WIN_SYNACK}) then
            instance_cutoff(ctx, true)
            desync.arg.fwmark = 0x40000
            rawsend_dissect_segmented(desync)
            return VERDICT_DROP
        end
        desync.dis.tcp.th_win = ${ZAPRET2_WIN_ACK}
        return VERDICT_MODIFY
    end

    -- Только первый data-пакет клиента
    if #desync.dis.payload == 0 or desync.track == nil or desync.track.pos.client.tcp.rseq ~= 1 then
        return VERDICT_PASS
    end

    -- Split на 3 части, средняя с badsum (disorder)
    local len = ${ZAPRET2_SPLIT_LEN}
    local first  = string.sub(desync.dis.payload, 1, len)
    local second = string.sub(desync.dis.payload, len + 1, 2 * len)
    local third  = string.sub(desync.dis.payload, 2 * len + 1)
    rawsend_payload_segmented(desync, first)
    rawsend_payload_segmented(desync, third, 2 * len)
    desync.arg["badsum"] = true
    rawsend_payload_segmented(desync, second, len)
    instance_cutoff(ctx, false)
    return VERDICT_DROP
end
LUAEOF
    log_success "Lua скрипт записан: ${ZAPRET2_LUA}"
}

zapret2_write_service() {
    local _nft_script="/usr/local/sbin/mtproxyl-zapret2-start.sh"
    local _ct_mark="0x00040000"
    local _combined_mark
    printf -v _combined_mark '0x%08x' "$(( ZAPRET2_FWMARK | _ct_mark ))"

    local _is_bridge="false"
    zapret2_is_bridge_target && _is_bridge="true"
    local _is_precise="false"
    [ "${DETECT_BRIDGE_STRATEGY:-simple}" = "precise" ] && _is_precise="true"

    cat > "$_nft_script" << NFTSTART
#!/bin/bash
set -e

TABLE="${ZAPRET2_NFT_TABLE}"
FWMARK="${ZAPRET2_FWMARK}"
PORT="$(zapret2_nft_port_spec)"
QNUM="${ZAPRET2_QNUM}"
CT_MARK="${_ct_mark}"
COMBINED_MARK="${_combined_mark}"
IS_BRIDGE="${_is_bridge}"
IS_PRECISE="${_is_precise}"
CONTAINER="${DETECTED_CONTAINER}"

nft delete table ip "\$TABLE" 2>/dev/null || true
nft add table ip "\$TABLE"

nft "add chain ip \$TABLE predefrag { type filter hook output priority -401; policy accept; }"
nft "add rule ip \$TABLE predefrag meta mark \$COMBINED_MARK counter accept"
nft "add rule ip \$TABLE predefrag meta mark and \$FWMARK != 0x00000000 counter notrack"

nft "add chain ip \$TABLE output { type route hook output priority mangle; policy accept; }"
nft "add rule ip \$TABLE output meta mark and \$COMBINED_MARK == \$COMBINED_MARK ct mark set \$CT_MARK counter accept"

if [ "\$IS_BRIDGE" = "true" ]; then
    # Docker bridge: трафик до контейнера идёт через forward.
    DADDR_MATCH=""
    SADDR_MATCH=""
    if [ "\$IS_PRECISE" = "true" ] && [ -n "\$CONTAINER" ]; then
        # Контейнер после перезагрузки может подняться позже нас —
        # ждём его IP до 30 секунд.
        CIP=""
        for i in \$(seq 1 30); do
            RUNNING="\$(docker inspect -f '{{.State.Running}}' "\$CONTAINER" 2>/dev/null || true)"
            if [ "\$RUNNING" = "true" ]; then
                CIP="\$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' "\$CONTAINER" 2>/dev/null | awk 'NF {print; exit}')"
                [ -n "\$CIP" ] && break
            fi
            sleep 1
        done
        if [ -n "\$CIP" ]; then
            DADDR_MATCH="ip daddr \$CIP "
            SADDR_MATCH="ip saddr \$CIP "
            echo "MTProxyL: zapret2 bridge precise mode, container IP \$CIP"
        else
            echo "MTProxyL: warning - container IP for \$CONTAINER not detected, applying without IP match" >&2
        fi
    fi

    nft "add chain ip \$TABLE forward { type filter hook forward priority mangle; policy accept; }"
    nft "add rule ip \$TABLE forward ct state invalid counter drop"
    nft "add rule ip \$TABLE forward ct mark \$CT_MARK counter accept"
    nft "add rule ip \$TABLE forward \${DADDR_MATCH}meta mark and \$FWMARK == 0x00000000 tcp dport \$PORT counter queue num \$QNUM bypass"
    nft "add rule ip \$TABLE forward \${SADDR_MATCH}meta mark and \$FWMARK == 0x00000000 tcp sport \$PORT counter queue num \$QNUM bypass"
else
    nft "add chain ip \$TABLE postrouting { type filter hook postrouting priority srcnat + 1; policy accept; }"
    nft "add rule ip \$TABLE postrouting ct mark \$CT_MARK counter accept"
    nft "add rule ip \$TABLE postrouting meta mark and \$FWMARK == 0x00000000 tcp sport \$PORT counter queue num \$QNUM bypass"

    nft "add chain ip \$TABLE prerouting { type filter hook prerouting priority mangle; policy accept; }"
    nft "add rule ip \$TABLE prerouting ct state invalid counter drop"
    nft "add rule ip \$TABLE prerouting ct mark \$CT_MARK counter accept"
    nft "add rule ip \$TABLE prerouting meta mark and \$FWMARK == 0x00000000 tcp dport \$PORT counter queue num \$QNUM bypass"
fi

echo "MTProxyL: NFT table \$TABLE applied (ports=\$PORT qnum=\$QNUM bridge=\$IS_BRIDGE precise=\$IS_PRECISE)"

exec ${ZAPRET2_BIN} @${ZAPRET2_CONF}
NFTSTART
    chmod +x "$_nft_script"

    # В bridge-режиме стартовый скрипт опрашивает docker inspect —
    # значит служба должна подниматься после docker.
    local _unit_after="network-online.target nftables.service"
    local _unit_wants="network-online.target"
    if [ "$_is_bridge" = "true" ]; then
        _unit_after="${_unit_after} docker.service"
        _unit_wants="${_unit_wants} docker.service"
    fi

    cat > "/etc/systemd/system/${ZAPRET2_SERVICE}" << EOF
[Unit]
Description=MTProxyL Zapret2 MTProto fix
After=${_unit_after}
Wants=${_unit_wants}

[Service]
Type=simple
ExecStart=$_nft_script
ExecStop=/usr/sbin/nft delete table ip ${ZAPRET2_NFT_TABLE}
Restart=on-failure
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "/etc/systemd/system/${ZAPRET2_SERVICE}"
    systemctl daemon-reload
    systemctl reset-failed "${ZAPRET2_SERVICE}" 2>/dev/null || true
    log_success "Служба создана: ${ZAPRET2_SERVICE}"

    # В bridge/precise IP контейнера может смениться — watcher переналожит
    # правила (он перезапускает именно zapret2-службу, если она активна).
    install_bridge_watch_service
}

# true, если цель живёт в Docker bridge и трафик до неё идёт через forward,
# а не через локальные pre/postrouting хуки хоста.
# Zapret2 и SYN limiter взаимоисключающи. Вместо того чтобы блокировать
# переключение, предлагаем отключить активный механизм и перейти на другой.
# Возвращает 0, если путь свободен (zapret2 отключён либо и не был активен).
offer_disable_zapret2() {
    local _reason="${1:-SYN limiter}"
    nft list table ip "${ZAPRET2_NFT_TABLE:-MTProtoL}" &>/dev/null 2>&1 || \
        [ "${ZAPRET2_APPLIED:-false}" = "true" ] || return 0

    echo ""
    log_warn "Сейчас активен Zapret2 fix — вместе с ${_reason} он не работает"
    echo -e "  ${DIM}[1]${NC} Отключить Zapret2 и перейти на ${_reason} ${DIM}(рекомендуется)${NC}"
    echo -e "  ${DIM}[2]${NC} Оставить Zapret2, отменить переключение"
    local _c; _c=$(read_choice "выбор" "1")
    [ "$_c" = "1" ] || { log_info "Отменено — Zapret2 остаётся активным"; return 1; }

    zapret2_stop
    ZAPRET2_SERVICE_ENABLED="false"
    save_nft_settings
    log_success "Zapret2 отключён — можно включать ${_reason}"
    return 0
}


zapret2_is_bridge_target() {
    [ "${DETECTED_NETWORK_MODE:-host}" = "bridge" ] || [ "${NFT_HOOK:-input}" = "forward" ]
}

zapret2_apply_nft() {
    ensure_nftables_installed || return 1

    local _table="${ZAPRET2_NFT_TABLE}"
    local _fwmark="${ZAPRET2_FWMARK}"
    local _port; _port=$(zapret2_nft_port_spec)
    local _ct_mark="0x00040000"
    local _combined_mark

    printf -v _combined_mark '0x%08x' "$(( _fwmark | _ct_mark ))"

    if [ -z "${PROXY_PORT:-}" ]; then
        log_error "Порт не задан — невозможно применить NFT правила zapret2"
        return 1
    fi

    nft delete table ip "$_table" 2>/dev/null || true
    nft add table ip "$_table"

    nft "add chain ip $_table predefrag { type filter hook output priority -401; policy accept; }"
    nft "add rule ip $_table predefrag meta mark ${_combined_mark} counter accept"
    nft "add rule ip $_table predefrag meta mark and $_fwmark != 0x00000000 counter notrack"

    nft "add chain ip $_table output { type route hook output priority mangle; policy accept; }"
    nft "add rule ip $_table output meta mark and ${_combined_mark} == ${_combined_mark} ct mark set ${_ct_mark} counter accept"

    if zapret2_is_bridge_target; then
        # Docker bridge: пакеты до контейнера проходят forward, а не
        # prerouting/postrouting хоста. В precise-режиме дополнительно
        # сужаем правило до IP контейнера (его отслеживает watcher).
        local _daddr_match="" _saddr_match=""
        if [ "${DETECT_BRIDGE_STRATEGY:-simple}" = "precise" ]; then
            local _cip
            _cip=$(docker_container_ip "$DETECTED_CONTAINER" 2>/dev/null || true)
            if [ -n "$_cip" ]; then
                _daddr_match="ip daddr ${_cip} "
                _saddr_match="ip saddr ${_cip} "
                log_info "Zapret2 bridge/precise: IP контейнера ${_cip}"
            else
                log_warn "Zapret2 bridge/precise: IP контейнера не определён — правила без фильтра по IP"
            fi
        fi

        nft "add chain ip $_table forward { type filter hook forward priority mangle; policy accept; }"
        nft "add rule ip $_table forward ct state invalid counter drop"
        nft "add rule ip $_table forward ct mark ${_ct_mark} counter accept"
        nft "add rule ip $_table forward ${_daddr_match}meta mark and $_fwmark == 0x00000000 tcp dport ${_port} counter queue num ${ZAPRET2_QNUM} bypass"
        nft "add rule ip $_table forward ${_saddr_match}meta mark and $_fwmark == 0x00000000 tcp sport ${_port} counter queue num ${ZAPRET2_QNUM} bypass"
        log_success "NFT таблица ${_table} применена для Docker bridge (forward: порты=${_port} qnum=${ZAPRET2_QNUM} strategy=${DETECT_BRIDGE_STRATEGY:-simple})"
        return 0
    fi

    nft "add chain ip $_table postrouting { type filter hook postrouting priority srcnat + 1; policy accept; }"
    nft "add rule ip $_table postrouting ct mark ${_ct_mark} counter accept"
    nft "add rule ip $_table postrouting meta mark and $_fwmark == 0x00000000 tcp sport ${_port} counter queue num ${ZAPRET2_QNUM} bypass"

    nft "add chain ip $_table prerouting { type filter hook prerouting priority mangle; policy accept; }"
    nft "add rule ip $_table prerouting ct state invalid counter drop"
    nft "add rule ip $_table prerouting ct mark ${_ct_mark} counter accept"
    nft "add rule ip $_table prerouting meta mark and $_fwmark == 0x00000000 tcp dport ${_port} counter queue num ${ZAPRET2_QNUM} bypass"

    log_success "NFT таблица ${_table} применена (порты=${_port} qnum=${ZAPRET2_QNUM})"
}

zapret2_remove_nft() {
    nft delete table ip "${ZAPRET2_NFT_TABLE}" 2>/dev/null || true
    log_success "NFT таблица ${ZAPRET2_NFT_TABLE} удалена"
}

zapret2_start() {
    if [ ! -x "$ZAPRET2_BIN" ]; then
        log_error "Бинарник nfqws2 не найден: ${ZAPRET2_BIN}"
        return 1
    fi
    systemctl daemon-reload
    systemctl enable "$ZAPRET2_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$ZAPRET2_SERVICE" 2>/dev/null || true
    sleep 1
    if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null; then
        ZAPRET2_SERVICE_ENABLED="true"
        save_nft_settings
        log_success "zapret2 запущен и добавлен в автозапуск"
    else
        log_error "zapret2 не запустился"
        journalctl -u "$ZAPRET2_SERVICE" -n 10 --no-pager 2>/dev/null || true
        return 1
    fi
}

zapret2_stop() {
    systemctl stop "$ZAPRET2_SERVICE" 2>/dev/null || true
    systemctl disable "$ZAPRET2_SERVICE" 2>/dev/null || true
    nft delete table ip "${ZAPRET2_NFT_TABLE}" 2>/dev/null || true
    log_success "zapret2 остановлен"
}

zapret2_cleanup_failed_install() {
    systemctl stop "$ZAPRET2_SERVICE" 2>/dev/null || true
    systemctl disable "$ZAPRET2_SERVICE" 2>/dev/null || true

    pkill -9 -f "$ZAPRET2_BIN" 2>/dev/null || true
    pkill -9 -x nfqws2 2>/dev/null || true

    nft delete table ip "${ZAPRET2_NFT_TABLE}" 2>/dev/null || true

    rm -f "/etc/systemd/system/${ZAPRET2_SERVICE}"
    rm -f "/usr/local/sbin/mtproxyl-zapret2-start.sh"
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "$ZAPRET2_SERVICE" 2>/dev/null || true

    ZAPRET2_APPLIED="false"
    ZAPRET2_SERVICE_ENABLED="false"
    save_nft_settings

    log_success "Следы неудачной установки zapret2 очищены"
}

zapret2_start_existing() {
    if [ "${ZAPRET2_APPLIED:-false}" != "true" ] || [ ! -x "$ZAPRET2_BIN" ]; then
        log_error "Zapret2 не установлен — используйте [1] Установить"
        return 1
    fi
    zapret2_apply_nft || return 1
    systemctl daemon-reload
    systemctl enable "$ZAPRET2_SERVICE" >/dev/null 2>&1 || true
    systemctl start "$ZAPRET2_SERVICE" 2>/dev/null || true
    sleep 1
    if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null; then
        ZAPRET2_SERVICE_ENABLED="true"
        save_nft_settings
        log_success "zapret2 запущен"
    else
        log_error "zapret2 не запустился"
        journalctl -u "$ZAPRET2_SERVICE" -n 10 --no-pager 2>/dev/null || true
        return 1
    fi
}

zapret2_update_config() {
    if [ "${ZAPRET2_APPLIED:-false}" != "true" ]; then
        log_warn "Zapret2 не установлен"
        return 1
    fi

    # Останавливаем текущий экземпляр перед проверкой занятости NFQUEUE —
    # иначе он сам же держит свою очередь, и она ложно кажется занятой.
    systemctl stop "$ZAPRET2_SERVICE" 2>/dev/null || true
    pkill -x nfqws2 2>/dev/null || true

    # Проверяем занятость NFQUEUE и подбираем свободную
    if zapret2_queue_in_use "${ZAPRET2_QNUM}"; then
        local _old_q="${ZAPRET2_QNUM}"
        local _new_q

        # сначала пробуем 250..299, потом 201..249
        _new_q=$(zapret2_find_free_queue 250 299)
        [ -z "$_new_q" ] && _new_q=$(zapret2_find_free_queue 201 249)

        local _holder; _holder=$(zapret2_queue_holder "$_old_q" 2>/dev/null)
        if [ -n "$_new_q" ]; then
            log_warn "NFQUEUE ${_old_q} занята${_holder:+: ${_holder}}"
            ZAPRET2_QNUM="$_new_q"
            save_nft_settings
            log_success "Автоматически выбрана свободная очередь: ${ZAPRET2_QNUM}"
        else
            log_error "Не удалось найти свободную NFQUEUE в диапазоне 201..299"
            log_info "Проверьте занятые очереди: cat /proc/net/netfilter/nfnetlink_queue"
            return 1
        fi
    fi

    zapret2_write_conf
    zapret2_write_lua
    zapret2_write_service
    zapret2_apply_nft
    systemctl daemon-reload
    systemctl enable "$ZAPRET2_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$ZAPRET2_SERVICE" 2>/dev/null || true
    sleep 1
    if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null; then
        log_success "Конфигурация обновлена, zapret2 перезапущен"
    else
        log_error "zapret2 не запустился после обновления"
        journalctl -u "$ZAPRET2_SERVICE" -n 10 --no-pager 2>/dev/null || true
    fi
}

zapret2_install() {
    echo ""
    echo -e "  ${BRIGHT_CYAN}${BOLD}Zapret2 MTProto fix${NC}"
    echo ""
    echo -e "  ${DIM}Серверный обход для MTProto прокси.${NC}"
    echo -e "  ${DIM}Метод: disorder + badsum + TCP window control.${NC}"
    echo -e "  ${DIM}Работает на сервере — клиент ничего не ставит.${NC}"
    echo ""
    echo -e "  ${BOLD}Текущие параметры:${NC}"
    echo -e "    out-range:   ${ZAPRET2_OUT_RANGE}"
    echo -e "    split len:   ${ZAPRET2_SPLIT_LEN}"
    echo -e "    win SYN+ACK: ${ZAPRET2_WIN_SYNACK}"
    echo -e "    win ACK:     ${ZAPRET2_WIN_ACK}"
    echo ""

    local _reinstall="false"
    if [ "${ZAPRET2_APPLIED:-false}" = "true" ] && [ -x "$ZAPRET2_BIN" ]; then
        echo -e "  ${YELLOW}Zapret2 уже установлен. Переустановить?${NC}"
        echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
        local _yn; read_line _yn
        [[ "$_yn" =~ ^[nN]$ ]] && { log_info "Отменено"; return 0; }
        _reinstall="true"
    fi

    echo -en "  ${BOLD}Скачать и установить zapret2? [Y/n]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[nN]$ ]] && { log_info "Отменено"; return 0; }

    # Свой экземпляр снимаем до проверки очереди в любом случае: и при
    # переустановке, и когда настройки говорят «не установлен», а служба
    # или процесс от прошлой попытки ещё живы.
    zapret2_free_own_queue

    zapret2_download_bundle || return 1

    # Проверяем занятость NFQUEUE и подбираем свободную
    if zapret2_queue_in_use "${ZAPRET2_QNUM}"; then
        local _old_q="${ZAPRET2_QNUM}"
        local _new_q

        _new_q=$(zapret2_find_free_queue 250 299)
        [ -z "$_new_q" ] && _new_q=$(zapret2_find_free_queue 201 249)

        if [ -n "$_new_q" ]; then
            log_warn "NFQUEUE ${_old_q} уже занята другим процессом"
            ZAPRET2_QNUM="$_new_q"
            save_nft_settings
            log_success "Автоматически выбрана свободная очередь: ${ZAPRET2_QNUM}"
        else
            log_error "Не удалось найти свободную NFQUEUE в диапазоне 201..299"
            log_info "Проверьте занятые очереди: cat /proc/net/netfilter/nfnetlink_queue"
            return 1
        fi
    fi

    local _restore_limiter="false"
    local _restore_limiter_service="false"

    # Отключаем SYN limiter если активен
    if [ "${NFT_ENABLED:-false}" = "true" ] || nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null 2>&1; then
        _restore_limiter="true"
        [ "${NFT_ENABLED:-false}" = "true" ] && _restore_limiter_service="true"

        echo ""
        echo -e "  ${YELLOW}⚠ SYN limiter активен — zapret2 его заменит.${NC}"
        echo -en "  ${BOLD}Отключить SYN limiter? [Y/n]:${NC} "
        local _yn_syn; read_line _yn_syn
        if [[ ! "$_yn_syn" =~ ^[nN]$ ]]; then
            remove_nft_rules 2>/dev/null || true
            remove_nft_service 2>/dev/null || true
            log_success "SYN limiter отключён"
        else
            _restore_limiter="false"
            _restore_limiter_service="false"
        fi
    fi

    zapret2_write_conf
    zapret2_write_lua
    zapret2_write_service

    if ! zapret2_start; then
        log_warn "zapret2 не запустился — выполняю откат"

        zapret2_cleanup_failed_install || true

        if [ "$_restore_limiter" = "true" ]; then
            log_info "Возвращаю SYN limiter..."
            apply_nft_rules || true
            if [ "$_restore_limiter_service" = "true" ]; then
                install_nft_service || true
            fi
        fi

        return 1
    fi

    ZAPRET2_APPLIED="true"
    ZAPRET2_SERVICE_ENABLED="true"
    save_nft_settings

    zapret2_check_wscale "false"

    echo ""
    log_success "Zapret2 MTProto fix установлен и запущен"
    echo ""
    echo -e "  ${BOLD}Что было сделано:${NC}"
    echo -e "    ${GREEN}${SYM_CHECK}${NC} nfqws2 установлен в ${ZAPRET2_DIR}"
    echo -e "    ${GREEN}${SYM_CHECK}${NC} Конфиг: ${ZAPRET2_CONF}"
    echo -e "    ${GREEN}${SYM_CHECK}${NC} Lua: ${ZAPRET2_LUA}"
    echo -e "    ${GREEN}${SYM_CHECK}${NC} Служба: ${ZAPRET2_SERVICE}"
    echo -e "    ${GREEN}${SYM_CHECK}${NC} NFT таблица ip ${ZAPRET2_NFT_TABLE}"
}

zapret2_remove() {
    if [ "${ZAPRET2_APPLIED:-false}" != "true" ]; then
        log_info "Zapret2 не установлен"; return 0
    fi
    echo ""
    echo -e "  ${RED}${BOLD}Удаление Zapret2 MTProto fix${NC}"
    echo ""
    echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[yY]$ ]] || { log_info "Отменено"; return 0; }

    zapret2_stop
    systemctl disable "$ZAPRET2_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${ZAPRET2_SERVICE}"
    rm -f "/usr/local/sbin/mtproxyl-zapret2-start.sh"
    # Watcher bridge-режима живёт только ради правил zapret2
    remove_bridge_watch_service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$ZAPRET2_CONF"
    rm -f "$ZAPRET2_LUA"
    rm -rf "$ZAPRET2_DIR"
    rm -rf "$ZAPRET2_ETC_DIR"

    ZAPRET2_APPLIED="false"
    ZAPRET2_SERVICE_ENABLED="false"
    save_nft_settings

    log_success "Zapret2 MTProto fix удалён"
}

zapret2_check_wscale() {
    local _show_only="${1:-false}"
    local _max_allowed=1399

    local _rmem_max
    _rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "212992")
    local _tcp_rmem_max
    _tcp_rmem_max=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    [ -z "$_tcp_rmem_max" ] && _tcp_rmem_max="$_rmem_max"

    local _buf_size
    if [ "$_tcp_rmem_max" -gt "$_rmem_max" ]; then
        _buf_size="$_tcp_rmem_max"
    else
        _buf_size="$_rmem_max"
    fi

    local _wscale=0
    local _shifted="$_buf_size"
    while [ "$_shifted" -gt 65535 ]; do
        _wscale=$((_wscale + 1))
        _shifted=$((_buf_size >> _wscale))
    done

    local _scale=$((1 << _wscale))
    local _win_ack_rec=$(( _max_allowed / _scale ))
    [ "$_win_ack_rec" -lt 1 ] && _win_ack_rec=1
    local _real_win=$((_win_ack_rec * _scale))

    local _impossible="false"
    if [ $(( 1 * _scale )) -ge 1400 ]; then
        _impossible="true"
        _win_ack_rec=1
        _real_win=$(( 1 * _scale ))
    fi

    echo ""
    echo -e "  ${BOLD}=== Проверка TCP буфера / wscale ===${NC}"
    echo ""
    echo -e "  net.core.rmem_max:        ${_rmem_max}"
    echo -e "  net.ipv4.tcp_rmem (max):  ${_tcp_rmem_max}"
    echo -e "  Буфер для расчёта:        ${_buf_size}"
    echo ""
    echo -e "  Рассчитанный wscale:      ${_wscale}"
    echo -e "  2^wscale (гранулярность): ${_scale} байт"
    echo -e "  Целевое окно:             < 1400 байт"
    echo ""

    local _current_win_ack="${ZAPRET2_WIN_ACK:-10}"
    local _current_real=$((_current_win_ack * _scale))

    echo -e "  Текущий win ACK:          ${_current_win_ack}  → реальное окно: ${_current_real} байт"
    echo -e "  Рекомендуемый win ACK:    ${_win_ack_rec}  → реальное окно: ${_real_win} байт"
    echo ""

    if [ "$_impossible" = "true" ]; then
        echo -e "  ${RED}⚠ КРИТИЧНО: 2^wscale = ${_scale} >= 1400 байт${NC}"
        echo -e "  ${RED}  Дробление ClientHello невозможно!${NC}"
        echo -e "  ${RED}  Уменьшите net.core.rmem_max / net.ipv4.tcp_rmem${NC}"
        echo ""
        echo -e "  ${YELLOW}Пример (wscale=7):${NC}"
        echo -e "  ${DIM}  sysctl -w net.core.rmem_max=8388608${NC}"
        echo -e "  ${DIM}  sysctl -w net.ipv4.tcp_rmem='4096 131072 8388608'${NC}"
    elif [ "$_current_real" -ge 1400 ]; then
        echo -e "  ${RED}⚠ Реальное окно (${_current_real} байт) >= 1400 — дробление не работает!${NC}"
    elif [ "$_current_real" -lt 1400 ]; then
        echo -e "  ${GREEN}✓ Реальное окно (${_current_real} байт) < 1400 — дробление работает${NC}"
    fi

    if [ "$_impossible" != "true" ] && [ "$_show_only" != "true" ]; then
        if [ "$_current_real" -ge 1400 ] && [ "$_win_ack_rec" != "$_current_win_ack" ]; then
            echo ""
            echo -e "  ${BOLD}Необходимо изменить win ACK: ${_current_win_ack} → ${_win_ack_rec}${NC}"
            echo -en "  Применить? [Y/n]: "
            local _yn; read_line _yn
            if [[ ! "$_yn" =~ ^[nN]$ ]]; then
                ZAPRET2_WIN_ACK="$_win_ack_rec"
                save_nft_settings
                log_success "win ACK установлен: ${_win_ack_rec} (реальное окно: ${_real_win} байт)"
                zapret2_update_config
            fi
        elif [ "$_win_ack_rec" != "$_current_win_ack" ] && [ "$_current_real" -lt 1400 ]; then
            echo ""
            echo -e "  ${DIM}Текущее значение работает. Оптимизировать?${NC}"
            echo -e "  ${DIM}win ACK ${_current_win_ack} (${_current_real} байт) → ${_win_ack_rec} (${_real_win} байт)${NC}"
            echo -en "  Оптимизировать? [y/N]: "
            local _yn; read_line _yn
            if [[ "$_yn" =~ ^[yY]$ ]]; then
                ZAPRET2_WIN_ACK="$_win_ack_rec"
                save_nft_settings
                log_success "win ACK установлен: ${_win_ack_rec}"
                zapret2_update_config
            fi
        fi
    fi
}

# ── Полная очистка zapret2 при удалении MTProxyL ──────────────
zapret2_full_cleanup() {
    if [ "${ZAPRET2_APPLIED:-false}" = "true" ] || systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null; then
        systemctl stop "$ZAPRET2_SERVICE" 2>/dev/null || true
        systemctl disable "$ZAPRET2_SERVICE" 2>/dev/null || true
        rm -f "/etc/systemd/system/${ZAPRET2_SERVICE}"
        rm -f "/usr/local/sbin/mtproxyl-zapret2-start.sh"
        systemctl daemon-reload 2>/dev/null || true
        zapret2_remove_nft
        rm -f "$ZAPRET2_CONF" "$ZAPRET2_LUA"
        rm -rf "$ZAPRET2_DIR" "$ZAPRET2_ETC_DIR"
        log_info "Zapret2 MTProto fix удалён"
    fi
    # Watcher нужен только правилам zapret2 в bridge-режиме: без этого он
    # оставался в systemd и продолжал переналагать правила несуществующей
    # таблицы.
    remove_bridge_watch_service 2>/dev/null || true
}

# ── Статусы для шапки ─────────────────────────────────────────
nft_status_line() {
    if nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null; then
        if [ "$NFT_MODE" = "smart" ]; then
            local _ip_info=""
            [ -n "${NFT_SERVER_IP:-}" ] && _ip_info=" ip=${NFT_SERVER_IP}"

            local _ios_info _other_info _action_info="" _detect_info
            if [ "${NFT_IOS_LIMIT_ENABLED:-true}" = "true" ]; then
                _ios_info="iOS:${NFT_IOS_RATE}/${NFT_IOS_BURST}"
            else
                _ios_info="iOS:unlimited"
            fi

            if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" = "true" ]; then
                _other_info="Other:${NFT_OTHER_RATE}/${NFT_OTHER_BURST}"
                case "${NFT_OTHER_ACTION:-icmp-host-unreachable}" in
                    icmp-host-unreachable) _action_info=" action:icmp" ;;
                    drop) _action_info=" action:drop" ;;
                    *) _action_info=" action:rst" ;;
                esac
            else
                _other_info="Other:unlimited"
            fi

            if [ "${NFT_IOS_DETECT:-fingerprint}" = "ttl" ]; then
                _detect_info=" detect:ttl"
            else
                _detect_info=" detect:fp"
            fi

            echo -e "${GREEN}Smart By-MEKO${NC} (${_ios_info} ${_other_info}${_action_info}${_detect_info}${_ip_info})"
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
