#!/bin/bash
# MTProxyL — туннель AmneziaWG до сервера-донора. Движок выходит к Telegram
# через SOCKS5 донора внутри туннеля: адрес выхода один, поэтому ME работает.

DONOR_IFACE="mtpdonor"
DONOR_UPSTREAM_NAME="donor"
DONOR_UPSTREAM_LOCAL="donorlocal"
DONOR_SOCKS_PORT_DEFAULT="1080"
# С 1420 туннель теряет крупные пакеты там, где путь между серверами уже 1500.
DONOR_MTU_DEFAULT="1280"
DONOR_AWG_DIR="/etc/amnezia/amneziawg"
DONOR_PPA_FPR="75C9DD72C799870E310542E24166F2C257290828"
DONOR_TARGET_BEGIN="# mtproxyl-donor begin"
DONOR_TARGET_END="# mtproxyl-donor end"
DONOR_TARGET_MARK="# mtproxyl-donor"

_donor_dir()         { echo "${INSTALL_DIR:-/opt/mtproxyl}/donor"; }
_donor_state_file()  { echo "$(_donor_dir)/donor.conf"; }
_donor_known_hosts() { echo "$(_donor_dir)/known_hosts"; }
_donor_script_file() { echo "$(_donor_dir)/donor-setup.sh"; }
_donor_awg_conf()    { echo "${DONOR_AWG_DIR}/${DONOR_IFACE}.conf"; }
_donor_awg_key()     { echo "${DONOR_AWG_DIR}/${DONOR_IFACE}.key"; }

# ── Состояние ───────────────────────────────────────────────────────────────

_DONOR_KEYS="DONOR_ENABLED DONOR_STAGE DONOR_SETUP_MODE DONOR_HOST DONOR_SSH_PORT DONOR_SSH_USER
DONOR_AWG_PORT DONOR_NET DONOR_MTU DONOR_REMOTE_IFACE DONOR_SOCKS_PORT DONOR_REMOTE_PUB DONOR_EGRESS_IP
DONOR_PUBLIC_IP DONOR_IPV6 DONOR_DISABLED_UPSTREAMS DONOR_ENGINE_ROUTED DONOR_TARGET_TLS_SCOPE
DONOR_SETUP_AT DONOR_CHECK_AT DONOR_CHECK_RESULT DONOR_CHECK_EGRESS DONOR_CHECK_RTT DONOR_CHECK_ERROR"

_donor_reset_vars() {
    local _k
    for _k in $_DONOR_KEYS; do printf -v "$_k" '%s' ""; done
    DONOR_ENABLED="false"; DONOR_SSH_PORT="22"; DONOR_SSH_USER="root"
    DONOR_SOCKS_PORT="$DONOR_SOCKS_PORT_DEFAULT"; DONOR_MTU="$DONOR_MTU_DEFAULT"
}

donor_load() {
    _donor_reset_vars
    local _f; _f=$(_donor_state_file)
    [ -f "$_f" ] || return 0
    local _line _key _val
    while IFS= read -r _line; do
        [[ "$_line" =~ ^(DONOR_[A-Z0-9_]+)=\'([^\']*)\'$ ]] || continue
        _key="${BASH_REMATCH[1]}"; _val="${BASH_REMATCH[2]}"
        case " ${_DONOR_KEYS//$'\n'/ } " in
            *" ${_key} "*) printf -v "$_key" '%s' "$_val" ;;
        esac
    done < "$_f"
    [[ "$DONOR_SSH_PORT" =~ ^[0-9]{1,5}$ ]] || DONOR_SSH_PORT="22"
    [[ "$DONOR_SOCKS_PORT" =~ ^[0-9]{1,5}$ ]] || DONOR_SOCKS_PORT="$DONOR_SOCKS_PORT_DEFAULT"
    local _n
    for _n in DONOR_AWG_PORT DONOR_SETUP_AT DONOR_CHECK_AT DONOR_CHECK_RTT; do
        [[ "${!_n}" =~ ^[0-9]{1,12}$ ]] || printf -v "$_n" '%s' ""
    done
    [[ "$DONOR_NET" =~ ^10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || DONOR_NET=""
    _donor_valid_mtu "$DONOR_MTU" || DONOR_MTU="$DONOR_MTU_DEFAULT"
    return 0
}

donor_save() {
    local _dir; _dir=$(_donor_dir)
    install -d -m 700 "$_dir" || return 1
    local _tmp; _tmp=$(mktemp "$_dir/.donor.XXXXXX") || return 1
    local _k _v
    for _k in $_DONOR_KEYS; do
        _v="${!_k:-}"; _v="${_v//\'/}"; _v="${_v//$'\n'/ }"
        printf "%s='%s'\n" "$_k" "$_v"
    done > "$_tmp"
    chmod 600 "$_tmp" && mv "$_tmp" "$(_donor_state_file)"
}

donor_configured() { donor_load; [ -n "$DONOR_HOST" ] && [ -n "$DONOR_NET" ]; }

_donor_local_ip()  { echo "${DONOR_NET%.*}.$(( ${DONOR_NET##*.} + 2 ))"; }
_donor_remote_ip() { echo "${DONOR_NET%.*}.$(( ${DONOR_NET##*.} + 1 ))"; }
_donor_socks_addr() { echo "$(_donor_remote_ip):${DONOR_SOCKS_PORT}"; }

# ── Проверка ввода ──────────────────────────────────────────────────────────

_donor_valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local _o
    for _o in "${BASH_REMATCH[@]:1}"; do [ "$((10#$_o))" -le 255 ] || return 1; done
    case "$1" in 0.*|127.*|255.*) return 1 ;; esac
    return 0
}
_donor_valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]; }
_donor_valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]]; }
_donor_valid_pubkey() { [[ "$1" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; }
_donor_valid_fp() { [[ "$1" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]; }
_donor_valid_mtu() { [[ "$1" =~ ^[0-9]{4}$ ]] && [ "$1" -ge 1200 ] && [ "$1" -le 1420 ]; }

# ── Агент: одна и та же программа ставит AWG у нас и настраивает донор ─────
# Выполняется через `bash -s`: всё завёрнуто в функции, а вызов идёт с
# </dev/null, иначе apt съел бы остаток скрипта со стандартного ввода.

_donor_agent_script() {
    cat <<'AGENT'
_mtpd_say()  { echo "  → $*"; }
_mtpd_fail() { echo "MTPD:error=$2"; echo "  ✗ $2"; exit "$1"; }
_mtpd_apt()  { DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 -y -q "$@"; }

_mtpd_os() {
    [ -r /etc/os-release ] || _mtpd_fail 10 "Не удалось определить систему: нет /etc/os-release"
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" debian "*|*" ubuntu "*) ;;
        *) _mtpd_fail 10 "Поддерживаются Debian и Ubuntu, здесь ${PRETTY_NAME:-неизвестная система}" ;;
    esac
    command -v apt-get >/dev/null 2>&1 || _mtpd_fail 10 "Нет apt-get"
    command -v systemctl >/dev/null 2>&1 || _mtpd_fail 10 "Нужен systemd"
}

_mtpd_ppa_dist() {
    local _c="${UBUNTU_CODENAME:-}"
    [ -z "$_c" ] && [ "${ID:-}" = ubuntu ] && _c="${VERSION_CODENAME:-}"
    if [ -n "$_c" ]; then
        curl -fsI -m 15 "https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/${_c}/Release" \
            >/dev/null 2>&1 && { echo "$_c"; return; }
        echo noble; return
    fi
    case "${VERSION_ID%%.*}" in
        10|11) echo focal ;;
        12) echo jammy ;;
        *) echo noble ;;
    esac
}

_mtpd_awg_ready() {
    command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1 && modprobe amneziawg 2>/dev/null
}

_mtpd_install_awg() {
    if _mtpd_awg_ready; then _mtpd_say "AmneziaWG уже установлен"; return 0; fi
    local _virt; _virt=$(systemd-detect-virt 2>/dev/null || true)
    case "$_virt" in
        openvz|lxc|lxc-libvirt|systemd-nspawn|docker|podman|wsl)
            _mtpd_fail 11 "Виртуализация ${_virt}: модуль ядра AmneziaWG здесь не загрузить, нужен KVM или выделенный сервер" ;;
    esac
    _mtpd_say "Ставим AmneziaWG: модуль ядра собирается через DKMS, это до нескольких минут"
    command -v curl >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1 \
        || _mtpd_apt install ca-certificates curl gnupg >/dev/null 2>&1 \
        || _mtpd_fail 12 "Не удалось поставить curl и gnupg"
    install -d -m 755 /etc/apt/keyrings
    curl -fsS -m 60 "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${MTPD_FPR}" \
        | gpg --dearmor > /etc/apt/keyrings/amnezia-ppa.gpg.tmp 2>/dev/null \
        && [ -s /etc/apt/keyrings/amnezia-ppa.gpg.tmp ] \
        || _mtpd_fail 12 "Не удалось скачать ключ репозитория AmneziaWG"
    chmod 644 /etc/apt/keyrings/amnezia-ppa.gpg.tmp
    mv /etc/apt/keyrings/amnezia-ppa.gpg.tmp /etc/apt/keyrings/amnezia-ppa.gpg
    echo "deb [signed-by=/etc/apt/keyrings/amnezia-ppa.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu $(_mtpd_ppa_dist) main" \
        > /etc/apt/sources.list.d/amnezia-ppa.list
    _mtpd_apt update >/tmp/mtpd-apt.log 2>&1 || _mtpd_fail 12 "apt update не прошёл, лог: /tmp/mtpd-apt.log"
    _mtpd_apt install "linux-headers-$(uname -r)" >>/tmp/mtpd-apt.log 2>&1 \
        || _mtpd_say "Заголовков для ядра $(uname -r) в репозитории нет, модуль может не собраться"
    _mtpd_apt install amneziawg >>/tmp/mtpd-apt.log 2>&1 \
        || _mtpd_fail 12 "Не удалось поставить amneziawg, лог: /tmp/mtpd-apt.log"
    if ! modprobe amneziawg 2>/dev/null; then
        command -v dkms >/dev/null 2>&1 && dkms autoinstall -k "$(uname -r)" >>/tmp/mtpd-apt.log 2>&1
        modprobe amneziawg 2>/dev/null \
            || _mtpd_fail 13 "Модуль amneziawg не загрузился: нет заголовков ядра $(uname -r) или включён Secure Boot. Лог: /tmp/mtpd-apt.log"
    fi
    _mtpd_say "AmneziaWG установлен: $(awg --version 2>/dev/null | awk '{print $2}')"
}

_mtpd_install_dante() {
    command -v danted >/dev/null 2>&1 && return 0
    _mtpd_say "Ставим dante-server — SOCKS5 внутри туннеля"
    _mtpd_apt install dante-server >>/tmp/mtpd-apt.log 2>&1 \
        || _mtpd_fail 12 "Не удалось поставить dante-server, лог: /tmp/mtpd-apt.log"
    # Штатной службе нужен свой конфиг, у нас он отдельный.
    systemctl disable --now danted >/dev/null 2>&1 || true
    systemctl reset-failed danted >/dev/null 2>&1 || true
}

_mtpd_ip2int() { local IFS=.; set -- $1; echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )); }

# Занята ли подсеть /30: чужие адреса и маршруты, свой интерфейс не в счёт.
_mtpd_net_busy() {
    local _n _e _cidr _ip _len _s _end
    _n=$(_mtpd_ip2int "$1"); _e=$((_n + 3))
    while read -r _cidr; do
        [[ "$_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || continue
        _ip=${_cidr%/*}; _len=32
        [ "$_ip" != "$_cidr" ] && _len=${_cidr#*/}
        [ "$_len" -ge 1 ] || continue
        _s=$(( $(_mtpd_ip2int "$_ip") & ((0xFFFFFFFF << (32 - _len)) & 0xFFFFFFFF) ))
        _end=$(( _s + (1 << (32 - _len)) - 1 ))
        [ "$_s" -le "$_e" ] && [ "$_n" -le "$_end" ] && return 0
    done < <(ip -4 -o addr show 2>/dev/null | awk -v own="$2" '$2 != own {print $4}'
             ip -4 route show 2>/dev/null | awk -v own="$2" '$0 !~ ("dev " own "( |$)") {print $1}')
    return 1
}

_mtpd_udp_busy() { ss -Hlun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }

_mtpd_tg_reachable() {
    local _ip
    for _ip in 149.154.175.50 149.154.167.51 149.154.175.100 91.108.56.130; do
        timeout 5 bash -c "exec 3<>/dev/tcp/${_ip}/443" 2>/dev/null && return 0
    done
    return 1
}

_mtpd_ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; }

_mtpd_firewall_open() {
    local _from="${MTPD_CLIENT_IP:-any}"
    if _mtpd_ufw_active; then
        ufw allow proto udp from "$_from" to any port "$1" comment mtproxyl-donor >/dev/null
        ufw allow in on "$MTPD_IFACE" proto tcp to any port "$MTPD_SOCKS_PORT" comment mtproxyl-donor >/dev/null
        _mtpd_say "ufw: открыт UDP ${1} для ${_from}"
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd -q --permanent --add-port="${1}/udp"
        firewall-cmd -q --permanent --zone=trusted --add-interface="$MTPD_IFACE"
        firewall-cmd -q --reload
        _mtpd_say "firewalld: открыт UDP ${1}"
    fi
}

_mtpd_firewall_close() {
    [ -n "$1" ] || return 0
    local _from="${MTPD_CLIENT_IP:-any}"
    if _mtpd_ufw_active; then
        ufw delete allow proto udp from "$_from" to any port "$1" >/dev/null 2>&1
        ufw delete allow in on "$MTPD_IFACE" proto tcp to any port "$MTPD_SOCKS_PORT" >/dev/null 2>&1
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd -q --permanent --remove-port="${1}/udp" 2>/dev/null
        firewall-cmd -q --permanent --zone=trusted --remove-interface="$MTPD_IFACE" 2>/dev/null
        firewall-cmd -q --reload 2>/dev/null
    fi
    return 0
}

# Адрес сервера с прокси для фаервола: при автонастройке — тот, с которого
# пришли по SSH (под sudo переменная теряется — тогда присланный).
_mtpd_client_ip() {
    local _ip="${SSH_CLIENT%% *}"
    if [ "${MTPD_CLIENT_FROM_SSH:-0}" = 1 ] && [[ "$_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        MTPD_CLIENT_IP="$_ip"
    fi
}

_mtpd_setup() {
    [ "${MTPD_CLIENT_FROM_SSH:-0}" = 1 ] && _mtpd_say "Вход на донор выполнен: $(hostname 2>/dev/null)"
    _mtpd_client_ip
    _mtpd_os
    [ -n "${MTPD_PEER_PUB:-}" ] || _mtpd_fail 20 "Не передан ключ сервера с прокси"
    _mtpd_say "Проверяем, открывается ли Telegram с донора"
    _mtpd_tg_reachable || _mtpd_fail 16 "С донора не открываются дата-центры Telegram, туннель ничего не даст"
    _mtpd_install_awg
    _mtpd_install_dante

    local _dir=/etc/amnezia/amneziawg _conf _key _own_port _port="${MTPD_PORT:-0}" _net="" _cand
    _conf="${_dir}/${MTPD_IFACE}.conf"; _key="${_dir}/${MTPD_IFACE}.key"
    _own_port=$(awg show "$MTPD_IFACE" listen-port 2>/dev/null || true)
    # Кандидаты свободны на сервере с прокси; берём первый свободный и здесь.
    for _cand in $MTPD_NET; do
        _mtpd_net_busy "$_cand" "$MTPD_IFACE" || { _net="$_cand"; break; }
    done
    [ -n "$_net" ] || _mtpd_fail 15 "Подсети ${MTPD_NET// /, } (/30) на доноре уже заняты"
    if [ "$_port" = 0 ]; then
        [ -n "$_own_port" ] && _port="$_own_port"
        local _try=0
        while [ "$_port" = 0 ] && [ "$_try" -lt 50 ]; do
            _port=$(( 20000 + RANDOM % 40000 )); _try=$((_try + 1))
            _mtpd_udp_busy "$_port" && _port=0
        done
        [ "$_port" != 0 ] || _mtpd_fail 14 "Не нашлось свободного UDP-порта"
    elif [ "$_port" != "$_own_port" ] && _mtpd_udp_busy "$_port"; then
        _mtpd_fail 14 "UDP-порт ${_port} на доноре занят"
    fi

    install -d -m 700 "$_dir"
    umask 077
    [ -s "$_key" ] || awg genkey > "$_key"
    local _pub _ext _src
    _pub=$(awg pubkey < "$_key")
    read -r _ext _src < <(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i < NF; i++) { if ($i == "dev") d = $(i + 1); if ($i == "src") s = $(i + 1) }} END {print d, s}')
    [ -n "$_ext" ] || _mtpd_fail 17 "У донора нет маршрута в интернет по IPv4"
    local _self="${_net%.*}.$(( ${_net##*.} + 1 ))" _peer="${_net%.*}.$(( ${_net##*.} + 2 ))"

    local _fw=""
    if ! _mtpd_ufw_active && ! systemctl is-active --quiet firewalld 2>/dev/null \
        && iptables -S INPUT 2>/dev/null | grep -q '^-P INPUT DROP'; then
        _fw="PostUp = iptables -I INPUT -p udp --dport ${_port} -j ACCEPT; iptables -I INPUT -i %i -p tcp --dport ${MTPD_SOCKS_PORT} -j ACCEPT
PostDown = iptables -D INPUT -p udp --dport ${_port} -j ACCEPT; iptables -D INPUT -i %i -p tcp --dport ${MTPD_SOCKS_PORT} -j ACCEPT"
    fi
    {
        echo "# MTProxyL: туннель от ${MTPD_CLIENT_IP:-сервера с прокси}"
        echo "[Interface]"
        echo "Address = ${_self}/30"
        echo "ListenPort = ${_port}"
        echo "MTU = ${MTPD_MTU:-1280}"
        echo "PrivateKey = $(cat "$_key")"
        printf '%s\n' "$MTPD_PARAMS"
        [ -z "$_fw" ] || printf '%s\n' "$_fw"
        echo ""
        echo "[Peer]"
        echo "PublicKey = ${MTPD_PEER_PUB}"
        echo "AllowedIPs = ${_peer}/32"
    } > "$_conf"

    install -d -m 755 "/etc/mtproxyl-donor/${MTPD_IFACE}"
    cat > "/etc/mtproxyl-donor/${MTPD_IFACE}/danted.conf" <<EOF
# MTProxyL: SOCKS5 только внутри туннеля и только для сервера с прокси
logoutput: stderr
internal: ${_self} port = ${MTPD_SOCKS_PORT}
external: ${_ext}
socksmethod: none
clientmethod: none
user.privileged: root
user.unprivileged: nobody
client pass { from: ${_peer}/32 to: 0.0.0.0/0 }
client block { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks pass { from: ${_peer}/32 to: 0.0.0.0/0 command: connect }
socks pass { from: ${_peer}/32 to: ::/0 command: connect }
socks block { from: 0.0.0.0/0 to: 0.0.0.0/0 }
EOF
    chmod 644 "/etc/mtproxyl-donor/${MTPD_IFACE}/danted.conf"
    cat > /etc/systemd/system/mtproxyl-donor-socks@.service <<'EOF'
[Unit]
Description=MTProxyL donor SOCKS5 for %i
Requires=awg-quick@%i.service
After=awg-quick@%i.service
PartOf=awg-quick@%i.service

[Service]
ExecStart=/usr/sbin/danted -f /etc/mtproxyl-donor/%i/danted.conf -p /run/mtproxyl-donor-%i.pid
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "awg-quick@${MTPD_IFACE}" >/dev/null 2>&1
    systemctl restart "awg-quick@${MTPD_IFACE}" \
        || _mtpd_fail 17 "Интерфейс не поднялся: journalctl -u awg-quick@${MTPD_IFACE}"
    systemctl enable "mtproxyl-donor-socks@${MTPD_IFACE}" >/dev/null 2>&1
    systemctl restart "mtproxyl-donor-socks@${MTPD_IFACE}" \
        || _mtpd_fail 17 "SOCKS5 не запустился: journalctl -u mtproxyl-donor-socks@${MTPD_IFACE}"
    local _i
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        ss -Htln 2>/dev/null | awk '{print $4}' | grep -qx "${_self}:${MTPD_SOCKS_PORT}" && break
        sleep 1
    done
    ss -Htln 2>/dev/null | awk '{print $4}' | grep -qx "${_self}:${MTPD_SOCKS_PORT}" \
        || _mtpd_fail 17 "SOCKS5 не слушает ${_self}:${MTPD_SOCKS_PORT}: journalctl -u mtproxyl-donor-socks@${MTPD_IFACE}"
    _mtpd_firewall_open "$_port"
    local _public _v6=no
    _public=$(curl -4 -fsS -m 10 https://api.ipify.org 2>/dev/null || true)
    ip -6 route get 2001:67c:4e8:f004::a 2>/dev/null | grep -q " src " && _v6=yes
    _mtpd_say "Донор готов: UDP ${_port}, SOCKS5 ${_self}:${MTPD_SOCKS_PORT}"
    echo ""
    echo "  Публичный ключ донора: ${_pub}"
    echo "  Порт AmneziaWG: ${_port}"
    echo "MTPD:pub=${_pub}"
    echo "MTPD:port=${_port}"
    echo "MTPD:net=${_net}"
    echo "MTPD:egress=${_src}"
    echo "MTPD:public=${_public}"
    echo "MTPD:ipv6=${_v6}"
}

_mtpd_remove() {
    _mtpd_client_ip
    local _conf="/etc/amnezia/amneziawg/${MTPD_IFACE}.conf" _port=""
    [ -f "$_conf" ] && _port=$(awk -F' *= *' '$1 == "ListenPort" {print $2}' "$_conf")
    systemctl disable --now "mtproxyl-donor-socks@${MTPD_IFACE}" >/dev/null 2>&1
    systemctl disable --now "awg-quick@${MTPD_IFACE}" >/dev/null 2>&1
    _mtpd_firewall_close "$_port"
    rm -f "$_conf" "/etc/amnezia/amneziawg/${MTPD_IFACE}.key"
    rm -rf "/etc/mtproxyl-donor/${MTPD_IFACE}"
    if [ -z "$(ls -A /etc/mtproxyl-donor 2>/dev/null)" ]; then
        rm -rf /etc/mtproxyl-donor
        rm -f /etc/systemd/system/mtproxyl-donor-socks@.service
    fi
    systemctl daemon-reload
    _mtpd_say "Туннель ${MTPD_IFACE} на доноре удалён, пакеты оставлены"
    echo "MTPD:removed=1"
}

_mtpd_main() {
    case "${MTPD_ACTION:-}" in
        install) _mtpd_os; _mtpd_install_awg ;;
        setup)   _mtpd_setup ;;
        remove)  _mtpd_remove ;;
        *)       _mtpd_fail 2 "Неизвестное действие агента: ${MTPD_ACTION:-}" ;;
    esac
}
AGENT
}

# Переменные для агента: printf %q, чтобы ничего не раскрылось на той стороне.
_donor_agent_env() {
    local _action="$1" _port="${2:-0}" _peer_pub="${3:-}" _client_ip="${4:-}"
    printf 'MTPD_ACTION=%q\n' "$_action"
    printf 'MTPD_IFACE=%q\n' "${DONOR_REMOTE_IFACE:-}"
    printf 'MTPD_NET=%q\n' "${_DONOR_NET_CANDIDATES:-${DONOR_NET:-}}"
    printf 'MTPD_PORT=%q\n' "$_port"
    printf 'MTPD_PEER_PUB=%q\n' "$_peer_pub"
    printf 'MTPD_CLIENT_IP=%q\n' "$_client_ip"
    printf 'MTPD_SOCKS_PORT=%q\n' "${DONOR_SOCKS_PORT:-$DONOR_SOCKS_PORT_DEFAULT}"
    printf 'MTPD_FPR=%q\n' "$DONOR_PPA_FPR"
    printf 'MTPD_MTU=%q\n' "${DONOR_MTU:-$DONOR_MTU_DEFAULT}"
    printf 'MTPD_CLIENT_FROM_SSH=%q\n' "${_DONOR_CLIENT_FROM_SSH:-0}"
    printf 'MTPD_PARAMS=%q\n' "${_DONOR_PARAMS:-}"
}

_donor_agent_program() {
    _donor_agent_env "$@"
    _donor_agent_script
    echo '_mtpd_main </dev/null'
}

# Вывод агента: строки MTPD:ключ=значение — ответ, остальное — для человека.
_DONOR_AGENT_OUT=""
_donor_run_agent() {
    local _where="$1"; shift
    local _log; _log=$(mktemp) || return 1
    local _rc
    if [ "$_where" = local ]; then
        _donor_agent_program "$@" | bash -s 2>&1 | tee "$_log" | grep -v '^MTPD:'
        _rc=${PIPESTATUS[1]}
    else
        _donor_agent_program "$@" | _donor_ssh "$(_donor_remote_shell)" 2>&1 | tee "$_log" | grep -v '^MTPD:'
        _rc=${PIPESTATUS[1]}
    fi
    _DONOR_AGENT_OUT=$(grep '^MTPD:' "$_log")
    rm -f "$_log"
    return "$_rc"
}

_donor_agent_value() { printf '%s\n' "$_DONOR_AGENT_OUT" | sed -n "s/^MTPD:$1=//p" | tail -1; }

# ── SSH до донора ───────────────────────────────────────────────────────────

_DONOR_PW=""
_donor_remote_shell() { [ "${DONOR_SSH_USER:-root}" = root ] && echo "bash -s" || echo "sudo -n bash -s"; }

_donor_kh_name() {
    if [ "${DONOR_SSH_PORT:-22}" = 22 ]; then echo "$DONOR_HOST"; else echo "[${DONOR_HOST}]:${DONOR_SSH_PORT}"; fi
}

_donor_ssh() {
    local -a _o=(-p "${DONOR_SSH_PORT:-22}" -o "UserKnownHostsFile=$(_donor_known_hosts)"
        -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o ConnectTimeout=15
        -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o LogLevel=ERROR)
    if [ -n "$_DONOR_PW" ]; then
        _o+=(-o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no
             -o NumberOfPasswordPrompts=1)
        SSHPASS="$_DONOR_PW" sshpass -e ssh "${_o[@]}" "${DONOR_SSH_USER:-root}@${DONOR_HOST}" "$@"
    else
        _o+=(-o BatchMode=yes)
        ssh "${_o[@]}" "${DONOR_SSH_USER:-root}@${DONOR_HOST}" "$@"
    fi
}

_donor_ssh_explain() {
    case "$1" in
        5) log_error "Донор не принял логин или пароль" ;;
        6) log_error "Ключ хоста донора не подтверждён" ;;
        255) log_error "Не удалось подключиться к ${DONOR_HOST}:${DONOR_SSH_PORT} по SSH"
             echo -e "  ${DIM}Если донор переустанавливали, у него новый ключ хоста — забудьте старый:${NC}"
             echo -e "  ${DIM}ssh-keygen -R '$(_donor_kh_name)' -f $(_donor_known_hosts)${NC}"
             echo -e "  ${DIM}Защита от перебора на доноре тоже рвёт соединения — подождите несколько минут.${NC}" ;;
        *) log_error "SSH до донора завершился с кодом $1" ;;
    esac
}

_donor_need_tools() {
    local -a _pkgs=()
    command -v ssh >/dev/null 2>&1 || _pkgs+=(openssh-client)
    command -v curl >/dev/null 2>&1 || _pkgs+=(curl)
    [ -n "$_DONOR_PW" ] && ! command -v sshpass >/dev/null 2>&1 && _pkgs+=(sshpass)
    [ "${#_pkgs[@]}" -eq 0 ] && return 0
    log_info "Ставим: ${_pkgs[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -q "${_pkgs[@]}" >/dev/null 2>&1 \
        || { log_error "Не удалось поставить ${_pkgs[*]}"; return 1; }
}

_donor_fps_of() {
    [ -n "$1" ] || return 0
    ssh-keygen -lf <(printf '%s\n' "$1") -E sha256 2>/dev/null | awk '{print $2, $NF}'
}

# Ключи хоста — в _DONOR_SCAN, отпечатки «SHA256:… (ТИП)» — в _DONOR_FPS.
# ssh-keyscan открывает соединение на каждый тип ключа, а защита от перебора
# на доноре считает соединения: берём один тип, следующий — только если
# сервер ответил, но такого ключа у него нет.
_donor_scan_host() {
    local _t _out
    _DONOR_SCAN=""; _DONOR_FPS=""
    for _t in ed25519 ecdsa rsa; do
        _out=$(ssh-keyscan -T 10 -t "$_t" -p "${DONOR_SSH_PORT:-22}" "$DONOR_HOST" 2>&1)
        _DONOR_SCAN=$(grep -E '^[^#[:space:]]+ (ssh-|ecdsa-)' <<< "$_out" || true)
        [ -n "$_DONOR_SCAN" ] && break
        grep -q 'SSH-2.0' <<< "$_out" || return 1
    done
    _DONOR_FPS=$(_donor_fps_of "$_DONOR_SCAN")
    [ -n "$_DONOR_FPS" ]
}

_donor_scan_cache() { echo "$(_donor_dir)/hostkey.scan"; }

_donor_scan_save() {
    install -d -m 700 "$(_donor_dir)" || return 0
    { echo "# ${DONOR_HOST} ${DONOR_SSH_PORT:-22} $(date +%s)"; printf '%s\n' "$_DONOR_SCAN"; } > "$(_donor_scan_cache)"
    chmod 600 "$(_donor_scan_cache)"
}

# Ключи, полученные шагом «Получить ключ хоста» не раньше часа назад.
_donor_scan_load() {
    local _f; _f=$(_donor_scan_cache)
    [ -f "$_f" ] || return 1
    local _h _p _ts
    read -r _ _h _p _ts < "$_f"
    [ "$_h" = "$DONOR_HOST" ] && [ "$_p" = "${DONOR_SSH_PORT:-22}" ] || return 1
    [[ "$_ts" =~ ^[0-9]+$ ]] && [ $(( $(date +%s) - _ts )) -lt 3600 ] || return 1
    _DONOR_SCAN=$(grep -v '^#' "$_f" || true)
    _DONOR_FPS=$(_donor_fps_of "$_DONOR_SCAN")
    [ -n "$_DONOR_FPS" ]
}

_donor_known_fps() {
    local _kh; _kh=$(_donor_known_hosts)
    [ -s "$_kh" ] || return 0
    ssh-keygen -F "$(_donor_kh_name)" -f "$_kh" 2>/dev/null | grep -v '^#' \
        | ssh-keygen -lf - -E sha256 2>/dev/null | awk '{print $2, $NF}'
}

# Ключ хоста проверяем до пароля: пароль уходит только подтверждённому серверу.
_donor_trust_host() {
    local _expected="${1:-}" _fps _known _fp _match=false
    _known=$(_donor_known_fps)
    # Ключ уже известен — сверит сам ssh, лишнее соединение не нужно.
    if [ -n "$_known" ] && { [ -z "$_expected" ] || grep -qF "$_expected " <<< "$_known"; }; then
        return 0
    fi
    if ! { [ -n "$_expected" ] && _donor_scan_load && grep -qF "$_expected " <<< "$_DONOR_FPS"; }; then
        _donor_scan_host || { log_error "Донор ${DONOR_HOST}:${DONOR_SSH_PORT} не ответил по SSH"; return 1; }
    fi
    _fps="$_DONOR_FPS"
    while read -r _fp _; do
        [ -n "$_fp" ] && grep -qF "$_fp " <<< "$_fps" && _match=true
    done <<< "$_known"
    if [ "$_match" = true ]; then
        [ -z "$_expected" ] && return 0
        grep -qF "$_expected " <<< "$_fps" && return 0
    elif [ -n "$_known" ]; then
        log_warn "Ключ хоста донора сменился с прошлого подключения"
    fi
    if [ -n "$_expected" ]; then
        grep -qF "$_expected " <<< "$_fps" || {
            log_error "Ключ хоста донора не совпал с подтверждённым: ${_expected}"
            return 1
        }
    else
        echo ""
        echo -e "  ${BOLD}Ключ хоста ${DONOR_HOST}:${NC}"
        printf '%s\n' "$_fps" | sed 's/^/    /'
        echo -e "  ${DIM}Сверьте с выводом на доноре: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub${NC}"
        local _yn; read_line _yn "  ${BOLD}Доверять этому серверу? [y/N]:${NC} "
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 1; }
    fi
    local _kh; _kh=$(_donor_known_hosts)
    install -d -m 700 "$(_donor_dir)"
    [ -f "$_kh" ] && ssh-keygen -R "$(_donor_kh_name)" -f "$_kh" >/dev/null 2>&1
    rm -f "${_kh}.old"
    printf '%s\n' "$_DONOR_SCAN" >> "$_kh"
    chmod 600 "$_kh"
}

donor_hostkey() {
    local _host="${1:-}" _port="${2:-22}" _json="${3:-}"
    [ "$_port" = "--json" ] && { _json="--json"; _port=22; }
    _donor_valid_ipv4 "$_host" || { log_error "Нужен IPv4-адрес донора"; return 1; }
    _donor_valid_port "$_port" || { log_error "Неверный порт SSH"; return 1; }
    DONOR_HOST="$_host"; DONOR_SSH_PORT="$_port"
    _donor_scan_host || { log_error "Донор ${_host}:${_port} не ответил по SSH"; return 1; }
    _donor_scan_save
    local _fps="$_DONOR_FPS"
    if [ "$_json" = "--json" ]; then
        printf '%s\n' "$_fps" | awk 'BEGIN { printf "{\"fingerprints\":[" }
            NF >= 2 { t = $2; gsub(/[()]/, "", t); printf "%s{\"fingerprint\":\"%s\",\"type\":\"%s\"}", (n++ ? "," : ""), $1, t }
            END { print "]}" }'
    else
        printf '%s\n' "$_fps"
    fi
}

# ── Параметры туннеля ──────────────────────────────────────────────────────

_donor_rand31() { echo $(( ((RANDOM << 16) | (RANDOM << 1) | (RANDOM & 1)) % 2147483643 + 5 )); }

# Обфускация AWG: S1..S4 и H1..H4 обязаны совпадать на обеих сторонах,
# I1..I5 (сигнатура первых пакетов) задаются только у клиента.
_donor_gen_params() {
    local _jc=$((4 + RANDOM % 5)) _jmin=$((10 + RANDOM % 30)) _jmax _s1 _s2 _s3
    _jmax=$((_jmin + 30 + RANDOM % 50))
    _s1=$((15 + RANDOM % 136))
    while :; do _s2=$((15 + RANDOM % 136)); [ $((_s1 + 56)) -ne "$_s2" ] && break; done
    _s3=$((10 + RANDOM % 55))
    local -a _h=()
    local _v _x _dup
    while [ "${#_h[@]}" -lt 4 ]; do
        _v=$(_donor_rand31); _dup=0
        for _x in "${_h[@]}"; do [ "$_x" = "$_v" ] && _dup=1; done
        [ "$_dup" = 0 ] && _h+=("$_v")
    done
    _DONOR_PARAMS="Jc = ${_jc}
Jmin = ${_jmin}
Jmax = ${_jmax}
S1 = ${_s1}
S2 = ${_s2}
S3 = ${_s3}
S4 = 0
H1 = ${_h[0]}
H2 = ${_h[1]}
H3 = ${_h[2]}
H4 = ${_h[3]}"
    local _id; _id=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    _DONOR_SIGNATURE="I1 = <b 0xc10000000108${_id}00>
I2 = <b 0xc20000000108${_id}00>
I3 = <b 0xc30000000108${_id}00>
I4 = <b 0x43${_id}>
I5 = <b 0x43${_id}>"
}

# Подсети /30 в 10.200.0.0–10.249.255.0, свободные здесь; донор возьмёт
# первую свободную у себя — без повторных подключений.
_donor_pick_nets() {
    local _want="${1:-1}" _try _net _out=""
    for _try in $(seq 1 60); do
        _net="10.$((200 + RANDOM % 50)).$((RANDOM % 256)).$(( (RANDOM % 64) * 4 ))"
        case " $_out " in *" $_net "*) continue ;; esac
        ( eval "$(_donor_agent_script)"; ! _mtpd_net_busy "$_net" "$DONOR_IFACE" ) || continue
        _out+="${_out:+ }${_net}"
        [ "$(wc -w <<< "$_out")" -ge "$_want" ] && break
    done
    [ -n "$_out" ] && echo "$_out"
}
_donor_pick_net() { _donor_pick_nets 1; }

_donor_new_iface_name() { echo "mtpl$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"; }

_donor_ensure_key() {
    install -d -m 700 "$DONOR_AWG_DIR"
    [ -s "$(_donor_awg_key)" ] || ( umask 077; awg genkey > "$(_donor_awg_key)" )
    awg pubkey < "$(_donor_awg_key)"
}

# Адрес, с которого мы приходим к донору: для правила фаервола на нём.
_donor_client_ip() {
    local _ip
    _ip=$(curl -4 -fsS -m 8 https://api.ipify.org 2>/dev/null)
    _donor_valid_ipv4 "$_ip" && { echo "$_ip"; return 0; }
    _ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
    _donor_valid_ipv4 "$_ip" && echo "$_ip"
}

# ── Наша сторона туннеля ───────────────────────────────────────────────────

_donor_write_local_conf() {
    local _key; _key=$(cat "$(_donor_awg_key)") || return 1
    local _tmp; _tmp=$(mktemp "${DONOR_AWG_DIR}/.${DONOR_IFACE}.XXXXXX") || return 1
    {
        echo "# MTProxyL: туннель до донора ${DONOR_HOST}"
        echo "[Interface]"
        echo "Address = $(_donor_local_ip)/30"
        echo "MTU = ${DONOR_MTU:-$DONOR_MTU_DEFAULT}"
        echo "PrivateKey = ${_key}"
        printf '%s\n' "$_DONOR_PARAMS" "$_DONOR_SIGNATURE"
        echo ""
        echo "[Peer]"
        echo "PublicKey = ${DONOR_REMOTE_PUB}"
        echo "Endpoint = ${DONOR_HOST}:${DONOR_AWG_PORT}"
        echo "AllowedIPs = $(_donor_remote_ip)/32"
        echo "PersistentKeepalive = 25"
    } > "$_tmp"
    chmod 600 "$_tmp" && mv "$_tmp" "$(_donor_awg_conf)"
}

# Параметры обфускации для повторной сборки конфига берём из него же.
_donor_read_local_params() {
    local _conf; _conf=$(_donor_awg_conf)
    [ -f "$_conf" ] || return 1
    _DONOR_PARAMS=$(grep -E '^(Jc|Jmin|Jmax|S[1-4]|H[1-4]) = ' "$_conf")
    _DONOR_SIGNATURE=$(grep -E '^I[1-5] = ' "$_conf")
    [ -n "$_DONOR_PARAMS" ]
}

_donor_handshake_age() {
    local _ts; _ts=$(awg show "$DONOR_IFACE" latest-handshakes 2>/dev/null | awk 'NR == 1 {print $2}')
    [[ "$_ts" =~ ^[0-9]+$ ]] && [ "$_ts" -gt 0 ] || { echo ""; return 1; }
    echo $(( $(date +%s) - _ts ))
}

_donor_tunnel_up() {
    systemctl enable "awg-quick@${DONOR_IFACE}" >/dev/null 2>&1
    systemctl restart "awg-quick@${DONOR_IFACE}" >/dev/null 2>&1 || {
        log_error "Интерфейс ${DONOR_IFACE} не поднялся"
        journalctl -u "awg-quick@${DONOR_IFACE}" -n 5 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    }
    local _i
    for _i in $(seq 1 20); do
        _donor_handshake_age >/dev/null && return 0
        ping -c 1 -W 1 "$(_donor_remote_ip)" >/dev/null 2>&1 || true
        sleep 1
    done
    log_error "Донор не ответил на рукопожатие AmneziaWG за 20 секунд"
    echo -e "  ${DIM}Проверьте, что UDP ${DONOR_AWG_PORT} на доноре открыт снаружи (фаервол хостера).${NC}"
    return 1
}

_donor_tunnel_down() {
    systemctl disable --now "awg-quick@${DONOR_IFACE}" >/dev/null 2>&1 || true
}

_donor_socks_curl() {
    local _url="$1" _t="${2:-10}"
    shift 2 2>/dev/null || shift $#
    curl -s -m "$_t" --socks5 "$(_donor_socks_addr)" "$@" "$_url" 2>/dev/null
}

# Выход через донора: IP и живой ответ Telegram.
_donor_probe() {
    _DONOR_PROBE_EGRESS=""; _DONOR_PROBE_TG=""; _DONOR_PROBE_RTT=""
    _DONOR_PROBE_RTT=$(ping -c 3 -W 2 -q "$(_donor_remote_ip)" 2>/dev/null \
        | awk -F'/' '/^rtt|^round-trip/ {printf "%.0f", $5}')
    _DONOR_PROBE_EGRESS=$(_donor_socks_curl https://api.ipify.org 10)
    _donor_valid_ipv4 "$_DONOR_PROBE_EGRESS" || _DONOR_PROBE_EGRESS=""
    _DONOR_PROBE_TG=$(curl -s -m 15 -o /dev/null -w '%{http_code}' --socks5 "$(_donor_socks_addr)" \
        https://core.telegram.org/getProxyConfig 2>/dev/null)
    [ "$_DONOR_PROBE_TG" = 200 ]
}

# ── Маршрут движка ─────────────────────────────────────────────────────────

_donor_owns_engine_config() {
    [ "${MTPROXYL_MODE:-manager}" = "manager" ] || return 1
    [ "${TOOLS_ONLY:-false}" = "true" ] && return 1
    _superexpert_active 2>/dev/null && return 1
    return 0
}

_donor_target_editable() {
    [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] || return 1
    [ "${DETECTED_MODE:-}" = "mtproxymax" ] && return 1
    [ -n "${DETECTED_CONFIG_PATH:-}" ] && [ -f "$DETECTED_CONFIG_PATH" ]
}

_donor_local_mask_backend() {
    if _donor_owns_engine_config; then
        [ "${SELFMASK_ENABLED:-false}" = "true" ] && return 0
        case "${MASKING_HOST:-}" in 127.0.0.1|localhost|::1) return 0 ;; esac
        return 1
    fi
    local _h; _h=$(_toml_get_string_in_section censorship mask_host "$DETECTED_CONFIG_PATH" 2>/dev/null)
    case "$_h" in 127.0.0.1|localhost|::1|\[::1\]) return 0 ;; esac
    return 1
}

_donor_foreign_default_upstreams() {
    load_upstreams 2>/dev/null
    local _i _out=""
    for _i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_ENABLED[$_i]}" = "true" ] || continue
        [ -n "${UPSTREAM_SCOPES[$_i]:-}" ] && continue
        case "${UPSTREAM_NAMES[$_i]}" in "$DONOR_UPSTREAM_NAME"|"$DONOR_UPSTREAM_LOCAL") continue ;; esac
        _out+="${_out:+,}${UPSTREAM_NAMES[$_i]}"
    done
    printf '%s' "$_out"
}

# Маршруты без области в конфиге цели, которые мы бы выключили.
_donor_target_default_upstreams() {
    [ -f "${DETECTED_CONFIG_PATH:-}" ] || return 0
    awk -v mark="$DONOR_TARGET_BEGIN" -v endm="$DONOR_TARGET_END" '
        function flush() { if (blk && def && en) { n++; printf "%s%s", (n > 1 ? "," : ""), (typ != "" ? typ : "direct") } blk = 0 }
        index($0, mark) == 1 { flush(); ours = 1; next }
        ours { if (index($0, endm) == 1) ours = 0; next }
        /^[[:space:]]*\[/ { flush(); if ($0 ~ /^[[:space:]]*\[\[upstreams\]\]/) { blk = 1; def = 1; en = 1; typ = "" }; next }
        blk && /^[[:space:]]*scopes[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*#.*/, "", v); gsub(/["\047[:space:]]/, "", v); if (v != "") def = 0 }
        blk && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*false/ { en = 0 }
        blk && /^[[:space:]]*type[[:space:]]*=/ { t = $0; sub(/^[^=]*=[[:space:]]*/, "", t); gsub(/["\047[:space:]]/, "", t); typ = t }
        END { flush(); print "" }
    ' "$DETECTED_CONFIG_PATH"
}

_donor_confirm_default_upstreams() {
    local _others="$1" _allow="${2:-false}"
    [ -n "$_others" ] || return 0
    echo ""
    log_warn "Есть другие маршруты без области: ${_others}"
    echo -e "  ${DIM}Движок раскладывает трафик между всеми такими маршрутами по весу —${NC}"
    echo -e "  ${DIM}часть соединений пошла бы мимо донора. Их нужно выключить.${NC}"
    if [ "${MTPROXYL_ASSUME_YES:-}" = "1" ]; then
        [ "$_allow" = "true" ] && return 0
        log_error "Нужно явное согласие на отключение маршрутов: ${_others}"
        log_info "CLI: добавьте --allow-disable-default-upstreams; в панели отметьте согласие"
        return 1
    fi
    [ "$_allow" = "true" ] && return 0
    local _yn; read_line _yn "  ${BOLD}Выключить их на время работы через донора? [Y/n]:${NC} "
    [[ "$_yn" =~ ^[nN] ]] && { log_error "Без этого движок не пойдёт через донора целиком"; return 1; }
    return 0
}

_donor_apply_manager() {
    local _allow="$1" _others
    _others=$(_donor_foreign_default_upstreams)
    _donor_confirm_default_upstreams "$_others" "$_allow" || return 1

    UPSTREAM_DEFER_RESTART="true"
    local _rc=0 _name
    local -a _list=()
    IFS=',' read -ra _list <<< "$_others"
    for _name in "${_list[@]}"; do
        [ -n "$_name" ] || continue
        upstream_toggle "$_name" disable >/dev/null 2>&1 || { UPSTREAM_DEFER_RESTART="false"; return 1; }
        case ",${DONOR_DISABLED_UPSTREAMS:-}," in
            *",${_name},"*) ;;
            *) DONOR_DISABLED_UPSTREAMS+="${DONOR_DISABLED_UPSTREAMS:+,}${_name}" ;;
        esac
    done
    upstream_remove "$DONOR_UPSTREAM_NAME" >/dev/null 2>&1 || true
    upstream_add "$DONOR_UPSTREAM_NAME" socks5 "$(_donor_socks_addr)" "" "" 10 "" "" >/dev/null \
        || { log_error "Не удалось добавить upstream ${DONOR_UPSTREAM_NAME}"; _rc=1; }
    upstream_remove "$DONOR_UPSTREAM_LOCAL" >/dev/null 2>&1 || true
    # Локальную заглушку донор не видит: TLS-метаданные берём напрямую.
    if [ $_rc -eq 0 ] && _donor_local_mask_backend; then
        upstream_add "$DONOR_UPSTREAM_LOCAL" direct "" "" "" 1 "" "local" >/dev/null || true
        handle_expert_command set censorship tls_fetch_scope local --no-apply >/dev/null 2>&1 \
            || log_warn "Не удалось задать censorship.tls_fetch_scope — маскировка может не подтянуть сертификат"
    fi
    UPSTREAM_DEFER_RESTART="false"
    [ $_rc -eq 0 ] || return 1
    DONOR_ENGINE_ROUTED="manager"
    donor_save
    generate_telemt_config >/dev/null || { log_error "Не удалось пересобрать конфиг движка"; return 1; }
    if is_proxy_running; then restart_proxy_container >/dev/null 2>&1 || return 1; fi
    log_success "Маршрут движка: socks5 $(_donor_socks_addr) через донор"
    [ -n "$_others" ] && log_info "Выключены на время работы через донора: ${_others}"
    return 0
}

_donor_drop_manager() {
    load_upstreams 2>/dev/null
    UPSTREAM_DEFER_RESTART="true"
    upstream_remove "$DONOR_UPSTREAM_NAME" >/dev/null 2>&1 || true
    upstream_remove "$DONOR_UPSTREAM_LOCAL" >/dev/null 2>&1 || true
    # В реаниматоре expert отказывает, а чистить нужно настройки менеджера.
    MTPROXYL_MODE=manager handle_expert_command clear censorship tls_fetch_scope --no-apply >/dev/null 2>&1 || true
    local _name
    local -a _list=()
    IFS=',' read -ra _list <<< "${DONOR_DISABLED_UPSTREAMS:-}"
    for _name in "${_list[@]}"; do
        [ -n "$_name" ] || continue
        upstream_toggle "$_name" enable >/dev/null 2>&1 && log_info "Маршрут '${_name}' включён обратно"
    done
    DONOR_DISABLED_UPSTREAMS=""
    UPSTREAM_DEFER_RESTART="false"
    [ "$DONOR_ENGINE_ROUTED" = manager ] && DONOR_ENGINE_ROUTED=""
    donor_save
    # В реаниматоре конфиг менеджера пересоберётся при возврате в менеджер.
    _donor_owns_engine_config || return 0
    generate_telemt_config >/dev/null 2>&1 || true
    if is_proxy_running; then restart_proxy_container >/dev/null 2>&1 || true; fi
}

_donor_manager_has_route() {
    [ -n "${DONOR_DISABLED_UPSTREAMS:-}" ] && return 0
    load_upstreams 2>/dev/null
    local _n
    for _n in "${UPSTREAM_NAMES[@]}"; do
        case "$_n" in "$DONOR_UPSTREAM_NAME"|"$DONOR_UPSTREAM_LOCAL") return 0 ;; esac
    done
    return 1
}

# Правка чужого конфига: наш блок между метками, чужие маршруты без области
# выключаются с пометкой — по ней же и возвращаются.
_donor_target_rewrite() {
    local _mode="$1" _cfg="$DETECTED_CONFIG_PATH" _block="${2:-}"
    local _tmp; _tmp=$(_mktemp "$(dirname "$_cfg")") || return 1
    DONOR_BLOCK="$_block" awk -v mode="$_mode" -v mark="$DONOR_TARGET_BEGIN" -v endm="$DONOR_TARGET_END" \
        -v tag="$DONOR_TARGET_MARK" '
        function flush(   i, done) {
            if (!blk) return
            done = 0
            for (i = 1; i <= n; i++) {
                if (mode == "apply" && def && en && !done && buf[i] ~ /^[[:space:]]*enabled[[:space:]]*=/) {
                    print "enabled = false  " tag; done = 1; lb = 0; continue
                }
                if (mode == "revert" && index(buf[i], tag) && buf[i] ~ /^[[:space:]]*enabled[[:space:]]*=/) {
                    if (!index(buf[i], tag ": added")) { print "enabled = true"; lb = 0 }
                    continue
                }
                print buf[i]; lb = (buf[i] ~ /^[[:space:]]*$/)
                if (i == 1 && mode == "apply" && def && en && !has_en) { print "enabled = false  " tag ": added"; done = 1; lb = 0 }
            }
            blk = 0; n = 0
        }
        index($0, mark) == 1 { flush(); ours = 1; next }
        ours { if (index($0, endm) == 1) ours = 0; next }
        /^[[:space:]]*\[/ {
            flush()
            if ($0 ~ /^[[:space:]]*\[\[upstreams\]\]/) { blk = 1; def = 1; en = 1; has_en = 0; n = 0; buf[++n] = $0; next }
            print; lb = 0; next
        }
        blk {
            buf[++n] = $0
            if ($0 ~ /^[[:space:]]*scopes[[:space:]]*=/) { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*#.*/, "", v); gsub(/["\047[:space:]]/, "", v); if (v != "") def = 0 }
            if ($0 ~ /^[[:space:]]*enabled[[:space:]]*=/) { has_en = 1; if ($0 ~ /=[[:space:]]*false/) en = 0 }
            next
        }
        { print; lb = ($0 ~ /^[[:space:]]*$/) }
        END {
            flush()
            if (mode == "apply") { if (!lb) print ""; print mark; printf "%s\n", ENVIRON["DONOR_BLOCK"]; print endm }
        }
    ' "$_cfg" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    # Пустые строки, оставшиеся в конце от прежнего блока, не копим.
    local _clean; _clean=$(_mktemp "$(dirname "$_cfg")") || { rm -f "$_tmp"; return 1; }
    awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (i = 1; i <= last; i++) print lines[i] }' \
        "$_tmp" > "$_clean"
    rm -f "$_tmp"
    [ -s "$_clean" ] || { rm -f "$_clean"; return 1; }
    cat "$_clean" > "$_cfg" || { rm -f "$_clean"; return 1; }
    rm -f "$_clean"
}

_donor_target_block() {
    printf '[[upstreams]]\ntype = "socks5"\naddress = "%s"\nweight = 10\nenabled = true' "$(_donor_socks_addr)"
    if _donor_local_mask_backend; then
        printf '\n\n[[upstreams]]\ntype = "direct"\nscopes = "local"\nweight = 1\nenabled = true'
    fi
}

_donor_apply_target() {
    local _allow="$1" _others
    _others=$(_donor_target_default_upstreams)
    _donor_confirm_default_upstreams "$_others" "$_allow" || return 1
    echo ""
    log_info "В конфиг цели ${DETECTED_CONFIG_PATH} будет добавлен маршрут socks5 $(_donor_socks_addr)"
    if [ "${MTPROXYL_ASSUME_YES:-}" != "1" ]; then
        local _yn; read_line _yn "  ${BOLD}Править конфиг цели? Резервная копия будет сделана [Y/n]:${NC} "
        [[ "$_yn" =~ ^[nN] ]] && { _donor_manual_engine_hint; return 2; }
    fi
    backup_target_config "donor" "true" || return 1
    local _bak="$TARGET_CONFIG_BACKUP"
    if ! _donor_target_rewrite apply "$(_donor_target_block)"; then
        log_error "Не удалось изменить конфиг цели"
        cp "$_bak" "$DETECTED_CONFIG_PATH" 2>/dev/null
        return 1
    fi
    DONOR_TARGET_TLS_SCOPE=""
    if _donor_local_mask_backend \
        && [ -z "$(_toml_get_string_in_section censorship tls_fetch_scope "$DETECTED_CONFIG_PATH" 2>/dev/null)" ]; then
        _toml_safe_set tls_fetch_scope '"local"' censorship "$DETECTED_CONFIG_PATH" && DONOR_TARGET_TLS_SCOPE="added"
    fi
    DONOR_ENGINE_ROUTED="target"
    donor_save
    log_success "Конфиг цели изменён, копия: ${_bak}"
    restart_target >/dev/null 2>&1
    sleep 2
    if ! is_proxy_running; then
        log_error "Цель не поднялась с новым маршрутом — возвращаем прежний конфиг"
        cp "$_bak" "$DETECTED_CONFIG_PATH"
        DONOR_ENGINE_ROUTED=""; DONOR_TARGET_TLS_SCOPE=""; donor_save
        restart_target >/dev/null 2>&1
        return 1
    fi
    log_success "Цель перезапущена и идёт к Telegram через донор"
    return 0
}

_donor_drop_target() {
    _donor_target_editable || return 0
    grep -qF "$DONOR_TARGET_BEGIN" "$DETECTED_CONFIG_PATH" 2>/dev/null \
        || grep -qF "$DONOR_TARGET_MARK" "$DETECTED_CONFIG_PATH" 2>/dev/null || return 0
    backup_target_config "donor-off" "true" || true
    _donor_target_rewrite revert || { log_error "Не удалось вернуть конфиг цели"; return 1; }
    if [ "$DONOR_TARGET_TLS_SCOPE" = "added" ]; then
        local _tmp; _tmp=$(_mktemp "$(dirname "$DETECTED_CONFIG_PATH")") || return 1
        awk '
            /^[[:space:]]*\[/ { insect = ($0 ~ /^[[:space:]]*\[censorship\]/) }
            insect && $0 ~ /^tls_fetch_scope = "local"$/ { next }
            { print }
        ' "$DETECTED_CONFIG_PATH" > "$_tmp" && [ -s "$_tmp" ] && cat "$_tmp" > "$DETECTED_CONFIG_PATH"
        rm -f "$_tmp"
    fi
    DONOR_TARGET_TLS_SCOPE=""
    [ "$DONOR_ENGINE_ROUTED" = target ] && DONOR_ENGINE_ROUTED=""
    donor_save
    log_success "Маршрут через донора убран из конфига цели"
    is_proxy_running && restart_target >/dev/null 2>&1
    return 0
}

_donor_manual_engine_hint() {
    local _cfg; _cfg=$(_engine_config_path 2>/dev/null)
    echo ""
    log_info "Туннель поднят, осталось направить движок через донор"
    echo -e "  ${BOLD}1.${NC} Допишите в ${_cfg:-конфиг движка}:"
    echo ""
    echo -e "  ${DIM}[[upstreams]]${NC}"
    echo -e "  ${DIM}type = \"socks5\"${NC}"
    echo -e "  ${DIM}address = \"$(_donor_socks_addr)\"${NC}"
    echo -e "  ${DIM}weight = 10${NC}"
    echo -e "  ${DIM}enabled = true${NC}"
    echo ""
    echo -e "  ${BOLD}2.${NC} Выключите там же остальные [[upstreams]] без ${DIM}scopes${NC} (enabled = false)."
    echo -e "  ${BOLD}3.${NC} Если заглушка (mask_host) локальная, добавьте:"
    echo -e "  ${DIM}[censorship] tls_fetch_scope = \"local\"${NC} и маршрут"
    echo -e "  ${DIM}[[upstreams]] type = \"direct\", scopes = \"local\"${NC}"
    echo -e "  ${BOLD}4.${NC} Перезапустите движок и проверьте: ${GREEN}mtproxyl donor check${NC}"
    echo ""
}

# Направить движок через донор — чем позволяет режим.
_donor_route_engine() {
    local _allow="${1:-false}"
    if _donor_owns_engine_config; then
        _donor_apply_manager "$_allow"
    elif _donor_target_editable; then
        _donor_apply_target "$_allow"
        local _rc=$?
        [ $_rc -eq 2 ] && return 0
        return $_rc
    else
        _donor_manual_engine_hint
        return 0
    fi
}

# Маршрут мог остаться в обоих местах, если режим меняли при включённом туннеле.
_donor_unroute_engine() {
    local _did=false
    if _donor_target_editable && grep -qF "$DONOR_TARGET_MARK" "$DETECTED_CONFIG_PATH" 2>/dev/null; then
        _donor_drop_target; _did=true
    fi
    if _donor_manager_has_route; then
        _donor_drop_manager; _did=true
    fi
    if [ "$_did" = false ] && ! _donor_owns_engine_config && ! _donor_target_editable; then
        log_info "Уберите socks5 $(_donor_socks_addr) из конфига движка и перезапустите его"
    fi
    DONOR_ENGINE_ROUTED=""; donor_save
    return 0
}

# Без IPv6 у донора соединения движка к DC по IPv6 через него не пройдут.
_donor_ipv6_hint() {
    [ "${DONOR_IPV6:-}" = "yes" ] && return 0
    local _cfg; _cfg=$(_engine_config_path 2>/dev/null)
    [ -n "$_cfg" ] && [ -r "$_cfg" ] || return 0
    grep -qE '^[[:space:]]*(ipv6[[:space:]]*=[[:space:]]*true|prefer[[:space:]]*=[[:space:]]*6)' "$_cfg" || return 0
    log_warn "У движка включён IPv6, а у донора IPv6 нет — к DC стоит ходить по IPv4"
    echo -e "  ${DIM}В [network] конфига движка: ipv6 = false (или prefer = 4)${NC}"
}

# После перезапуска ME поднимается десятки секунд: ждём покрытие DC.
_donor_wait_dc() {
    declare -F _engine_api_get >/dev/null || return 0
    local _i _json _sum _pct=""
    echo -e "  ${DIM}Ждём, пока движок поднимет связь с дата-центрами (до 90 секунд)...${NC}"
    for _i in $(seq 1 18); do
        sleep 5
        _json=$(_engine_api_get "/v1/stats/dcs" 2>/dev/null) || continue
        grep -qE '"middle_proxy_enabled"[[:space:]]*:[[:space:]]*true' <<< "$_json" || continue
        _sum=$(_dc_summary "$(_dc_rows "$_json")")
        _pct=$(cut -d'|' -f2 <<< "$_sum")
        [ "${_pct:-0}" -ge 80 ] && break
    done
    if [ -n "$_pct" ]; then
        if [ "$_pct" -ge 50 ]; then
            log_success "Покрытие дата-центров через донор: ${_pct}%"
        else
            log_warn "Покрытие дата-центров пока ${_pct}% — проверьте позже: mtproxyl dc"
        fi
    else
        log_info "Middle proxy выключен или ещё поднимается — проверьте: mtproxyl dc"
    fi
}

# ── Команды ────────────────────────────────────────────────────────────────

_donor_guard_conflicts() {
    if [ "${WARP_ENABLED:-false}" = "true" ]; then
        log_error "Включён маршрут через WARP — сначала выключите его: mtproxyl warp off"
        return 1
    fi
    return 0
}

donor_setup() (
    check_root
    local _host="" _port="22" _user="root" _awg_port="0" _fp="" _mtu="" _pw_stdin=false _allow=false _arg
    while [ $# -gt 0 ]; do
        _arg="$1"; shift
        case "$_arg" in
            --ssh-port) _port="${1:-}"; shift ;;
            --user) _user="${1:-}"; shift ;;
            --awg-port) _awg_port="${1:-}"; shift ;;
            --host-key) _fp="${1:-}"; shift ;;
            --mtu) _mtu="${1:-}"; shift ;;
            --password-stdin) _pw_stdin=true ;;
            --allow-disable-default-upstreams) _allow=true ;;
            --yes) MTPROXYL_ASSUME_YES=1 ;;
            -*) log_error "Неизвестный параметр: ${_arg}"; return 1 ;;
            *) [ -z "$_host" ] && _host="$_arg" || { log_error "Лишний аргумент: ${_arg}"; return 1; } ;;
        esac
    done
    _donor_valid_ipv4 "$_host" || { log_error "Нужен IPv4-адрес донора"; return 1; }
    _donor_valid_port "$_port" || { log_error "Неверный порт SSH: ${_port}"; return 1; }
    _donor_valid_user "$_user" || { log_error "Неверное имя пользователя: ${_user}"; return 1; }
    [ "$_awg_port" = 0 ] || _donor_valid_port "$_awg_port" || { log_error "Неверный порт AmneziaWG: ${_awg_port}"; return 1; }
    [ -z "$_fp" ] || _donor_valid_fp "$_fp" || { log_error "Отпечаток ключа хоста: SHA256:…"; return 1; }
    [ -z "$_mtu" ] || _donor_valid_mtu "$_mtu" || { log_error "MTU туннеля: 1200–1420"; return 1; }
    # Пароль со stdin читаем первым: подтверждение ниже тоже читает stdin.
    if [ "$_pw_stdin" = true ]; then
        IFS= read -r _DONOR_PW || true
        _DONOR_PW="${_DONOR_PW%$'\r'}"
    fi
    _donor_guard_conflicts || return 1
    _donor_plan "$_host"
    local _go; read_line _go "  ${BOLD}Начинаем? [Y/n]:${NC} "
    [[ "$_go" =~ ^[nN] ]] && { log_info "Отменено"; return 1; }
    if [ "$_pw_stdin" != true ] && [ "${MTPROXYL_ASSUME_YES:-}" != "1" ] && [ -t 0 ]; then
        IFS= read -rsp "$(echo -e "  ${BOLD}Пароль ${_user}@${_host} (пусто — вход по ключу):${NC} ")" _DONOR_PW || true
        echo ""
    fi

    donor_load
    local _same_host=false
    [ "$DONOR_HOST" = "$_host" ] && [ -n "$DONOR_REMOTE_IFACE" ] && _same_host=true
    if [ -n "$DONOR_HOST" ] && [ "$_same_host" = false ]; then
        log_warn "Прежний донор ${DONOR_HOST} останется настроенным — удалить на нём: mtproxyl donor remove --remote"
    fi
    DONOR_HOST="$_host"; DONOR_SSH_PORT="$_port"; DONOR_SSH_USER="$_user"
    [ -n "$_mtu" ] && DONOR_MTU="$_mtu"
    [ "$_same_host" = true ] || { DONOR_REMOTE_IFACE=$(_donor_new_iface_name); DONOR_NET=""; DONOR_AWG_PORT=""; }
    [ "$_awg_port" = 0 ] && [ "$_same_host" = true ] && [ -n "$DONOR_AWG_PORT" ] && _awg_port="$DONOR_AWG_PORT"

    _donor_need_tools || return 1
    echo ""
    log_info "Шаг 1/4: ключ хоста донора"
    _donor_trust_host "$_fp" || return 1

    echo ""
    log_info "Шаг 2/4: AmneziaWG на этом сервере"
    _donor_run_agent local install || { log_error "AmneziaWG на этом сервере не установлен"; return 1; }
    local _pub; _pub=$(_donor_ensure_key) || { log_error "Не удалось создать ключ AmneziaWG"; return 1; }
    _donor_gen_params
    # Прежняя подсеть — первой: при перенастройке адреса не меняются.
    _DONOR_NET_CANDIDATES=$(_donor_pick_nets 5) || { log_error "Не нашлось свободной подсети 10.200–249.x.x/30"; return 1; }
    if [ -n "$DONOR_NET" ] && ! ( eval "$(_donor_agent_script)"; _mtpd_net_busy "$DONOR_NET" "$DONOR_IFACE" ); then
        _DONOR_NET_CANDIDATES="$DONOR_NET $_DONOR_NET_CANDIDATES"
    fi

    # Вход и вся настройка донора — одним SSH-подключением.
    echo ""
    log_info "Шаг 3/4: донор — вход, AmneziaWG, SOCKS5 внутри туннеля"
    local _rc=0
    _DONOR_CLIENT_FROM_SSH=1
    _donor_run_agent remote setup "$_awg_port" "$_pub" "$(_donor_client_ip)" || _rc=$?
    if [ "$_rc" != 0 ]; then
        case "$_rc" in 5|6|255) _donor_ssh_explain "$_rc" ;; esac
        log_error "Донор не настроен"
        return 1
    fi
    DONOR_REMOTE_PUB=$(_donor_agent_value pub)
    DONOR_AWG_PORT=$(_donor_agent_value port)
    DONOR_NET=$(_donor_agent_value net)
    DONOR_EGRESS_IP=$(_donor_agent_value egress)
    DONOR_PUBLIC_IP=$(_donor_agent_value public)
    DONOR_IPV6=$(_donor_agent_value ipv6)
    _donor_valid_pubkey "$DONOR_REMOTE_PUB" && _donor_valid_port "$DONOR_AWG_PORT" \
        || { log_error "Донор не вернул ключ и порт"; return 1; }
    case " $_DONOR_NET_CANDIDATES " in
        *" $DONOR_NET "*) ;;
        *) log_error "Донор вернул чужую подсеть: ${DONOR_NET:-пусто}"; return 1 ;;
    esac
    DONOR_SETUP_MODE="auto"
    echo ""
    log_info "Шаг 4/4: туннель и маршрут движка"
    _donor_finish_local "$_allow"
)

_donor_plan() {
    echo ""
    echo -e "  ${BOLD}Что будет сделано:${NC}"
    echo -e "  ${DIM}•${NC} донор ${1}: AmneziaWG (модуль ядра через DKMS) и dante-server,"
    echo -e "    свой UDP-порт для туннеля и SOCKS5 только внутри туннеля;"
    echo -e "  ${DIM}•${NC} этот сервер: AmneziaWG и интерфейс ${DONOR_IFACE};"
    echo -e "  ${DIM}•${NC} ключи и параметры обфускации генерируются заново для этой пары;"
    echo -e "  ${DIM}•${NC} после проверки движок пойдёт к Telegram через донор, прямые"
    echo -e "    маршруты движка выключаются (вернутся при выключении туннеля)."
    echo -e "  ${DIM}Остальные службы донора не трогаются, пароль нигде не сохраняется.${NC}"
    echo ""
}

# Общий хвост авто- и ручной настройки: наша сторона, проверка, движок.
_donor_finish_local() {
    local _allow="${1:-false}"
    [ -n "$_DONOR_PARAMS" ] || _donor_read_local_params || { log_error "Нет параметров туннеля"; return 1; }
    _donor_write_local_conf || { log_error "Не удалось записать ${DONOR_IFACE}.conf"; return 1; }
    DONOR_STAGE="ready"; DONOR_SETUP_AT=$(date +%s)
    donor_save
    _donor_tunnel_up || return 1
    log_success "Туннель поднят: $(_donor_local_ip) ⇄ $(_donor_remote_ip)"
    if ! _donor_probe; then
        log_error "Через SOCKS5 донора Telegram не ответил (код ${_DONOR_PROBE_TG:-нет})"
        # Мелкий ответ проходит, крупный — нет: между серверами путь уже MTU туннеля.
        if [ "$(_donor_socks_curl http://example.com 8 -o /dev/null -w '%{http_code}')" = 200 ]; then
            echo -e "  ${DIM}Мелкие ответы проходят, крупные теряются — похоже на MTU пути между серверами.${NC}"
            echo -e "  ${DIM}Повторите настройку с меньшим MTU: --mtu $(( ${DONOR_MTU:-1280} - 80 ))${NC}"
        else
            echo -e "  ${DIM}Служба на доноре: systemctl status mtproxyl-donor-socks@${DONOR_REMOTE_IFACE}${NC}"
        fi
        return 1
    fi
    log_success "Telegram отвечает через донор, выход: ${_DONOR_PROBE_EGRESS:-?}"
    if [ -n "$DONOR_EGRESS_IP" ] && [ -n "$_DONOR_PROBE_EGRESS" ] && [ "$DONOR_EGRESS_IP" != "$_DONOR_PROBE_EGRESS" ]; then
        log_warn "У донора адрес интерфейса ${DONOR_EGRESS_IP}, а наружу он выходит с ${_DONOR_PROBE_EGRESS}"
        echo -e "  ${DIM}Донор за NAT: middle proxy (ME) через него может не подняться.${NC}"
    fi
    DONOR_CHECK_EGRESS="$_DONOR_PROBE_EGRESS"; DONOR_CHECK_RTT="$_DONOR_PROBE_RTT"
    DONOR_CHECK_AT=$(date +%s); DONOR_CHECK_RESULT="ok"; DONOR_CHECK_ERROR=""
    donor_save
    rm -f "$(_donor_dir)/params.pending"
    _donor_route_engine "$_allow" || { log_error "Туннель работает, но движок не переключён"; return 1; }
    _donor_ipv6_hint
    DONOR_ENABLED="true"
    donor_save
    [ -n "${DONOR_ENGINE_ROUTED:-}" ] && _donor_wait_dc
    echo ""
    log_success "Готово: движок выходит к Telegram через донор ${DONOR_HOST}"
    return 0
}

# Ручная настройка: скрипт для донора и ключ, который надо вернуть сюда.
donor_manual() (
    check_root
    local _host="" _awg_port="" _mtu="" _arg
    while [ $# -gt 0 ]; do
        _arg="$1"; shift
        case "$_arg" in
            --mtu) _mtu="${1:-}"; shift ;;
            --yes) MTPROXYL_ASSUME_YES=1 ;;
            -*) log_error "Неизвестный параметр: ${_arg}"; return 1 ;;
            *) if [ -z "$_host" ]; then _host="$_arg"; else _awg_port="$_arg"; fi ;;
        esac
    done
    _donor_valid_ipv4 "$_host" || { log_error "Нужен IPv4-адрес донора"; return 1; }
    [ -z "$_mtu" ] || _donor_valid_mtu "$_mtu" || { log_error "MTU туннеля: 1200–1420"; return 1; }
    if [ -n "$_awg_port" ]; then
        _donor_valid_port "$_awg_port" || { log_error "Неверный порт AmneziaWG"; return 1; }
    else
        _awg_port=$(( 20000 + RANDOM % 40000 ))
    fi
    _donor_guard_conflicts || return 1
    command -v awg >/dev/null 2>&1 || {
        log_info "Сначала ставим AmneziaWG на этот сервер"
        _donor_run_agent local install || { log_error "AmneziaWG на этом сервере не установлен"; return 1; }
    }
    donor_load
    if [ "$DONOR_HOST" != "$_host" ] || [ -z "$DONOR_REMOTE_IFACE" ]; then
        DONOR_REMOTE_IFACE=$(_donor_new_iface_name); DONOR_NET=""
    fi
    DONOR_HOST="$_host"; DONOR_AWG_PORT="$_awg_port"; DONOR_SETUP_MODE="manual"; DONOR_STAGE="pending"
    DONOR_REMOTE_PUB=""
    [ -n "$_mtu" ] && DONOR_MTU="$_mtu"
    [ -n "$DONOR_NET" ] || DONOR_NET=$(_donor_pick_net) || { log_error "Не нашлось свободной подсети"; return 1; }
    # Скрипт запускают со своего компьютера: SSH_CLIENT там не наш адрес.
    _DONOR_CLIENT_FROM_SSH=0; _DONOR_NET_CANDIDATES="$DONOR_NET"
    local _pub; _pub=$(_donor_ensure_key) || return 1
    _donor_gen_params
    install -d -m 700 "$(_donor_dir)"
    printf '%s\n' "$_DONOR_PARAMS" > "$(_donor_dir)/params.pending"
    printf '%s\n' "$_DONOR_SIGNATURE" >> "$(_donor_dir)/params.pending"
    chmod 600 "$(_donor_dir)/params.pending"
    {
        echo "#!/bin/bash"
        echo "# MTProxyL: настройка донора для сервера $(_donor_client_ip). Запускать от root."
        _donor_agent_program setup "$_awg_port" "$_pub" "$(_donor_client_ip)"
    } > "$(_donor_script_file)"
    chmod 600 "$(_donor_script_file)"
    donor_save
    _donor_manual_instructions
)

_donor_manual_instructions() {
    echo ""
    log_success "Скрипт для донора: $(_donor_script_file)"
    echo ""
    echo -e "  ${BOLD}1.${NC} Скопируйте его на донор и запустите от root:"
    echo -e "     ${GREEN}scp $(_donor_script_file) root@${DONOR_HOST}:/root/${NC}"
    echo -e "     ${GREEN}ssh root@${DONOR_HOST} bash /root/donor-setup.sh${NC}"
    echo -e "     ${DIM}Или откройте файл, скопируйте текст и выполните его в консоли донора.${NC}"
    echo -e "  ${BOLD}2.${NC} Скрипт поставит AmneziaWG и dante, поднимет UDP ${DONOR_AWG_PORT} и в конце"
    echo -e "     напечатает строку «Публичный ключ донора: …»."
    echo -e "  ${BOLD}3.${NC} Верните ключ сюда: ${GREEN}mtproxyl donor finish <ключ>${NC}"
    echo ""
    echo -e "  ${DIM}Порт UDP ${DONOR_AWG_PORT} должен быть открыт на доноре снаружи; туннель ${DONOR_NET}/30.${NC}"
}

donor_finish() (
    check_root
    local _key="" _allow=false _arg
    for _arg in "$@"; do
        case "$_arg" in
            --allow-disable-default-upstreams) _allow=true ;;
            --yes) MTPROXYL_ASSUME_YES=1 ;;
            *) _key="$_arg" ;;
        esac
    done
    donor_load
    [ "$DONOR_STAGE" = "pending" ] || { log_error "Ручная настройка не начата: mtproxyl donor manual <IP>"; return 1; }
    _donor_valid_pubkey "$_key" || { log_error "Это не ключ AmneziaWG (44 символа base64)"; return 1; }
    _donor_guard_conflicts || return 1
    _DONOR_PARAMS=$(grep -E '^(Jc|Jmin|Jmax|S[1-4]|H[1-4]) = ' "$(_donor_dir)/params.pending" 2>/dev/null)
    _DONOR_SIGNATURE=$(grep -E '^I[1-5] = ' "$(_donor_dir)/params.pending" 2>/dev/null)
    [ -n "$_DONOR_PARAMS" ] || { log_error "Параметры ручной настройки потерялись — начните заново"; return 1; }
    DONOR_REMOTE_PUB="$_key"
    echo ""
    log_info "Туннель и маршрут движка"
    _donor_finish_local "$_allow" || return 1
    rm -f "$(_donor_dir)/params.pending"
)

donor_check() {
    local _json="${1:-}"
    donor_load
    if ! donor_configured || [ "$DONOR_STAGE" != "ready" ]; then
        [ "$_json" = "--json" ] && { donor_status_json; return 0; }
        log_error "Туннель до донора не настроен"; return 1
    fi
    local _res="ok" _err="" _age
    if ! ip link show "$DONOR_IFACE" >/dev/null 2>&1; then
        _res="down"; _err="интерфейс ${DONOR_IFACE} не поднят"
    elif ! _age=$(_donor_handshake_age) || [ "$_age" -gt 180 ]; then
        _res="down"; _err="нет рукопожатия с донором"
    elif ! _donor_probe; then
        _res="degraded"; _err="через SOCKS5 донора Telegram не отвечает"
    fi
    DONOR_CHECK_AT=$(date +%s); DONOR_CHECK_RESULT="$_res"; DONOR_CHECK_ERROR="$_err"
    DONOR_CHECK_EGRESS="${_DONOR_PROBE_EGRESS:-}"; DONOR_CHECK_RTT="${_DONOR_PROBE_RTT:-}"
    [ "$(id -u)" = 0 ] && donor_save
    if [ "$_json" = "--json" ]; then donor_status_json; return 0; fi
    case "$_res" in
        ok) log_success "Туннель работает: выход ${DONOR_CHECK_EGRESS:-?}, пинг до донора ${DONOR_CHECK_RTT:-?} мс" ;;
        *) log_error "Туннель: ${_err}"; return 1 ;;
    esac
}

donor_enable() (
    check_root
    local _allow=false _arg
    for _arg in "$@"; do
        case "$_arg" in
            --allow-disable-default-upstreams) _allow=true ;;
            --yes) MTPROXYL_ASSUME_YES=1 ;;
            *) log_error "Неизвестный параметр: ${_arg}"; return 1 ;;
        esac
    done
    donor_load
    [ "$DONOR_STAGE" = "ready" ] || { log_error "Туннель до донора не настроен: mtproxyl donor setup <IP>"; return 1; }
    _donor_guard_conflicts || return 1
    _donor_tunnel_up || return 1
    _donor_probe || { log_error "Через SOCKS5 донора Telegram не ответил — движок не переключаем"; return 1; }
    _donor_route_engine "$_allow" || return 1
    DONOR_ENABLED="true"; donor_save
    [ -n "${DONOR_ENGINE_ROUTED:-}" ] && _donor_wait_dc
    log_success "Движок снова выходит через донор ${DONOR_HOST}"
)

donor_disable() {
    check_root
    donor_load
    donor_configured || { log_info "Туннель до донора не настроен"; return 0; }
    _donor_unroute_engine
    _donor_tunnel_down
    DONOR_ENABLED="false"; donor_save
    log_success "Туннель до донора выключен — движок ходит к Telegram напрямую"
}

donor_remove() (
    check_root
    local _remote=false _pw_stdin=false _arg
    for _arg in "$@"; do
        case "$_arg" in
            --remote) _remote=true ;;
            --password-stdin) _pw_stdin=true ;;
            --yes) MTPROXYL_ASSUME_YES=1 ;;
            *) log_error "Неизвестный параметр: ${_arg}"; return 1 ;;
        esac
    done
    donor_load
    if ! donor_configured && [ ! -f "$(_donor_awg_conf)" ]; then
        log_info "Туннель до донора не настроен"; return 0
    fi
    if [ "$_remote" = true ] && [ -n "$DONOR_REMOTE_IFACE" ]; then
        if [ "$_pw_stdin" = true ]; then
            IFS= read -r _DONOR_PW || true; _DONOR_PW="${_DONOR_PW%$'\r'}"
        elif [ "${MTPROXYL_ASSUME_YES:-}" != "1" ] && [ -t 0 ]; then
            IFS= read -rsp "$(echo -e "  ${BOLD}Пароль ${DONOR_SSH_USER}@${DONOR_HOST} (пусто — по ключу):${NC} ")" _DONOR_PW || true
            echo ""
        fi
        if _donor_need_tools && [ -s "$(_donor_known_hosts)" ]; then
            _DONOR_CLIENT_FROM_SSH=1
            _donor_run_agent remote remove 0 "" "$(_donor_client_ip)" || log_warn "На доноре убрать не вышло — удалите вручную: systemctl disable --now awg-quick@${DONOR_REMOTE_IFACE} mtproxyl-donor-socks@${DONOR_REMOTE_IFACE}"
        else
            log_warn "До донора не достучаться — на нём остался интерфейс ${DONOR_REMOTE_IFACE}"
        fi
    fi
    _donor_unroute_engine
    donor_purge_local
    log_success "Туннель до донора удалён с этого сервера"
    [ "$_remote" = true ] || [ -z "$DONOR_REMOTE_IFACE" ] \
        || log_info "На доноре ${DONOR_HOST} остался интерфейс ${DONOR_REMOTE_IFACE}: mtproxyl donor remove --remote перед удалением"
)

# Без вопросов и без движка — для удаления MTProxyL.
donor_purge_local() {
    systemctl disable --now "awg-quick@${DONOR_IFACE}" >/dev/null 2>&1 || true
    rm -f "$(_donor_awg_conf)" "$(_donor_awg_key)"
    rm -rf "$(_donor_dir)"
}

# ── Состояние для меню и панели ────────────────────────────────────────────

donor_state_label() {
    donor_load
    if ! donor_configured; then echo "не настроен"; return; fi
    if [ "$DONOR_STAGE" = "pending" ]; then echo "ждёт ключ донора"; return; fi
    if [ "$DONOR_ENABLED" = "true" ]; then
        if ip link show "$DONOR_IFACE" >/dev/null 2>&1; then echo "через ${DONOR_HOST}"; else echo "включён, туннель лежит"; fi
    else
        echo "выключен (${DONOR_HOST})"
    fi
}

# Строка в шапке главного меню — только когда движок идёт через донор.
donor_menu_line() {
    [ -f "$(_donor_state_file)" ] || return 0
    donor_load
    [ "$DONOR_ENABLED" = "true" ] || return 0
    local _state="${RED}туннель лежит${NC}" _age
    if _age=$(_donor_handshake_age) && [ "$_age" -lt 180 ]; then _state="${GREEN}работает${NC}"; fi
    echo -e "  ${BOLD}Донор (AWG):${NC}  ${DONOR_HOST}, ${_state}"
}

donor_status_json() {
    donor_load
    local _up=false _age="null" _rx=0 _tx=0 _installed=false _routed="${DONOR_ENGINE_ROUTED:-}"
    command -v awg >/dev/null 2>&1 && _installed=true
    if ip link show "$DONOR_IFACE" >/dev/null 2>&1; then
        _up=true
        local _a; _a=$(_donor_handshake_age) && _age="$_a"
        read -r _rx _tx < <(awg show "$DONOR_IFACE" transfer 2>/dev/null | awk 'NR == 1 {print $2, $3}')
    fi
    local _mode_engine="manual"
    if _donor_owns_engine_config; then _mode_engine="manager"
    elif _donor_target_editable; then _mode_engine="target"; fi
    local _socks=""; [ -n "$DONOR_NET" ] && _socks=$(_donor_socks_addr)
    local _others=""
    if [ "$_mode_engine" = manager ]; then _others=$(_donor_foreign_default_upstreams 2>/dev/null)
    elif [ "$_mode_engine" = target ]; then _others=$(_donor_target_default_upstreams 2>/dev/null); fi
    printf '{"configured":%s,"stage":"%s","enabled":%s,"setup_mode":"%s","host":"%s","ssh_port":%s,"ssh_user":"%s",' \
        "$(donor_configured && echo true || echo false)" "$(json_escape "${DONOR_STAGE:-}")" \
        "$([ "$DONOR_ENABLED" = true ] && echo true || echo false)" "$(json_escape "${DONOR_SETUP_MODE:-}")" \
        "$(json_escape "$DONOR_HOST")" "${DONOR_SSH_PORT:-22}" "$(json_escape "${DONOR_SSH_USER:-root}")"
    printf '"awg_port":%s,"mtu":%s,"net":"%s","iface":"%s","remote_iface":"%s","socks":"%s","awg_installed":%s,' \
        "${DONOR_AWG_PORT:-0}" "${DONOR_MTU:-$DONOR_MTU_DEFAULT}" "$(json_escape "$DONOR_NET")" "$DONOR_IFACE" \
        "$(json_escape "$DONOR_REMOTE_IFACE")" "$(json_escape "$_socks")" "$_installed"
    printf '"tunnel_up":%s,"handshake_age":%s,"rx_bytes":%s,"tx_bytes":%s,"egress_ip":"%s","public_ip":"%s","ipv6":%s,' \
        "$_up" "$_age" "${_rx:-0}" "${_tx:-0}" "$(json_escape "$DONOR_EGRESS_IP")" "$(json_escape "$DONOR_PUBLIC_IP")" \
        "$([ "$DONOR_IPV6" = yes ] && echo true || echo false)"
    printf '"engine_mode":"%s","engine_routed":"%s","disabled_upstreams":"%s","default_upstreams":"%s","warp_enabled":%s,' \
        "$_mode_engine" "$(json_escape "$_routed")" "$(json_escape "$DONOR_DISABLED_UPSTREAMS")" \
        "$(json_escape "$_others")" "$([ "${WARP_ENABLED:-false}" = true ] && echo true || echo false)"
    printf '"setup_at":%s,"check":{"at":%s,"result":"%s","egress_ip":"%s","rtt_ms":%s,"error":"%s"},"manual_script":%s}\n' \
        "${DONOR_SETUP_AT:-0}" "${DONOR_CHECK_AT:-0}" "$(json_escape "$DONOR_CHECK_RESULT")" \
        "$(json_escape "$DONOR_CHECK_EGRESS")" "${DONOR_CHECK_RTT:-null}" "$(json_escape "$DONOR_CHECK_ERROR")" \
        "$([ -f "$(_donor_script_file)" ] && [ "$DONOR_STAGE" = pending ] && echo true || echo false)"
}

donor_status() {
    donor_load
    echo ""
    if ! donor_configured; then
        log_info "Туннель до донора не настроен: mtproxyl donor setup <IP донора>"
        return 0
    fi
    echo -e "  ${BOLD}Донор:${NC}        ${DONOR_SSH_USER}@${DONOR_HOST} (SSH ${DONOR_SSH_PORT}), AWG UDP ${DONOR_AWG_PORT:-?}"
    echo -e "  ${BOLD}Туннель:${NC}      ${DONOR_IFACE} $(_donor_local_ip) ⇄ $(_donor_remote_ip) (${DONOR_REMOTE_IFACE} на доноре), MTU ${DONOR_MTU}"
    if [ "$DONOR_STAGE" = "pending" ]; then
        echo -e "  ${BOLD}Состояние:${NC}    ${YELLOW}ждёт публичный ключ донора${NC}"
        _donor_manual_instructions
        return 0
    fi
    local _age
    if ! ip link show "$DONOR_IFACE" >/dev/null 2>&1; then
        echo -e "  ${BOLD}Состояние:${NC}    ${YELLOW}интерфейс не поднят${NC}"
    elif _age=$(_donor_handshake_age); then
        echo -e "  ${BOLD}Состояние:${NC}    ${GREEN}поднят${NC}, рукопожатие ${_age} с назад"
    else
        echo -e "  ${BOLD}Состояние:${NC}    ${RED}нет рукопожатия с донором${NC}"
    fi
    echo -e "  ${BOLD}SOCKS5:${NC}       $(_donor_socks_addr)"
    case "${DONOR_ENGINE_ROUTED:-}" in
        manager) echo -e "  ${BOLD}Движок:${NC}       ${GREEN}через донор${NC} (upstream ${DONOR_UPSTREAM_NAME})" ;;
        target)  echo -e "  ${BOLD}Движок:${NC}       ${GREEN}через донор${NC} (конфиг цели)" ;;
        *)       echo -e "  ${BOLD}Движок:${NC}       ${YELLOW}не переключён автоматически${NC}" ;;
    esac
    [ -n "$DONOR_DISABLED_UPSTREAMS" ] && echo -e "  ${BOLD}Выключены:${NC}    ${DONOR_DISABLED_UPSTREAMS}"
    [ -n "$DONOR_CHECK_EGRESS" ] && echo -e "  ${BOLD}Выход:${NC}        ${DONOR_CHECK_EGRESS}"
    if [ -n "$DONOR_CHECK_AT" ] && [ "$DONOR_CHECK_AT" != 0 ]; then
        echo -e "  ${BOLD}Проверка:${NC}     ${DONOR_CHECK_RESULT} ($(date -d "@${DONOR_CHECK_AT}" '+%d.%m %H:%M' 2>/dev/null))${DONOR_CHECK_ERROR:+ — ${DONOR_CHECK_ERROR}}"
    fi
    echo ""
}

donor_help() {
    echo -e "  ${BOLD}Туннель AWG до сервера-донора:${NC}"
    echo -e "    ${GREEN}donor status${NC} [--json]                       Состояние"
    echo -e "    ${GREEN}donor setup${NC} <IP> [--user root] [--ssh-port 22] [--awg-port N]"
    echo -e "                  [--mtu 1280] [--password-stdin] [--host-key SHA256:…] [--allow-disable-default-upstreams]"
    echo -e "                                                  Настроить донор и туннель автоматически"
    echo -e "    ${GREEN}donor hostkey${NC} <IP> [порт SSH] [--json]      Отпечаток ключа хоста донора"
    echo -e "    ${GREEN}donor manual${NC} <IP> [порт AWG] [--mtu N]      Ручная настройка: скрипт для донора"
    echo -e "    ${GREEN}donor manual-script${NC}                        Показать этот скрипт"
    echo -e "    ${GREEN}donor finish${NC} <ключ донора>                  Завершить ручную настройку"
    echo -e "    ${GREEN}donor check${NC} [--json]                        Проверить туннель и выход"
    echo -e "    ${GREEN}donor on${NC} | ${GREEN}off${NC}                             Включить или выключить"
    echo -e "    ${GREEN}donor remove${NC} [--remote] [--password-stdin]  Удалить (--remote — и на доноре)"
}

handle_donor_command() {
    local _sub="${1:-status}"; shift 2>/dev/null || true
    case "$_sub" in
        status)
            if [ "${1:-}" = "--json" ]; then donor_status_json; else donor_status; fi ;;
        setup)         donor_setup "$@" ;;
        hostkey)       donor_hostkey "$@" ;;
        manual)        donor_manual "$@" ;;
        manual-script)
            donor_load
            [ "$DONOR_STAGE" = pending ] && [ -f "$(_donor_script_file)" ] \
                || { log_error "Ручная настройка не начата"; return 1; }
            cat "$(_donor_script_file)" ;;
        finish)        donor_finish "$@" ;;
        check)         donor_check "$@" ;;
        on|enable)     donor_enable "$@" ;;
        off|disable)   donor_disable ;;
        remove)        donor_remove "$@" ;;
        help|-h|--help) donor_help ;;
        *) log_error "Неизвестная команда: donor ${_sub}"; donor_help; return 1 ;;
    esac
}
