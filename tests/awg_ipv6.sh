#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail
umask 077

# Изолированные сети и /run: ни интерфейсы, ни сокеты стенда не меняются.
if [ "${1:-}" != --inside ]; then
    [ "$(id -u)" = 0 ] || { echo 'SKIP awg_ipv6: нужен root'; exit 0; }
    for tool in unshare ip awg awg-quick curl python3 jq; do
        command -v "$tool" >/dev/null || { echo "SKIP awg_ipv6: нет $tool"; exit 0; }
    done
    exec unshare --mount --net --pid --fork --mount-proc bash "$0" --inside
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/mtproxyl-awg-ipv6.XXXXXX)
trap 'ip netns delete peer 2>/dev/null || true; rm -rf "$tmp"' EXIT
mount --make-rprivate /
mount -t tmpfs tmpfs /run
mkdir -p /run/netns
ip netns add peer
ip link set lo up
ip -n peer link set lo up
ip link add uplink type veth peer name remote netns peer
ip link set uplink up
ip -n peer link set remote up
sysctl -qw net.ipv6.conf.all.disable_ipv6=0
ip netns exec peer sysctl -qw net.ipv6.conf.all.disable_ipv6=0
ip -6 addr add 2001:db8:56::1/64 dev uplink nodad
ip -n peer -6 addr add 2001:db8:56::2/64 dev remote nodad

export WG_QUICK_USERSPACE_IMPLEMENTATION="${MTPROXYL_AWG_GO:-amneziawg-go}"
awg genkey > "$tmp/client.key"
awg genkey > "$tmp/server.key"
chmod 600 "$tmp/"*.key
client_pub=$(awg pubkey < "$tmp/client.key")
server_pub=$(awg pubkey < "$tmp/server.key")
cat > "$tmp/server.conf" <<CONF
[Interface]
PrivateKey = $(cat "$tmp/server.key")
ListenPort = 51820
Jc = 3
Jmin = 10
Jmax = 20
S1 = 0
S2 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4
[Peer]
PublicKey = $client_pub
AllowedIPs = 10.250.20.1/32
CONF
chmod 600 "$tmp/server.conf"
if ! ip -n peer link add awgpeer type amneziawg 2>/dev/null; then
    ip netns exec peer "$WG_QUICK_USERSPACE_IMPLEMENTATION" awgpeer > "$tmp/server.log" 2>&1
fi
ip netns exec peer awg setconf awgpeer "$tmp/server.conf"
ip -n peer addr add 10.250.20.2/32 dev awgpeer
ip -n peer link set awgpeer mtu 1280 up
ip -n peer route add 10.250.20.1/32 dev awgpeer
printf 'IPv4 inside AWG over IPv6\n' > "$tmp/probe.txt"
ip netns exec peer python3 -m http.server 8188 --bind 10.250.20.2 --directory "$tmp" > "$tmp/http.log" 2>&1 &

INSTALL_DIR="$tmp/opt" DONOR_AWG_DIR="$tmp/etc"
BLUE='' GREEN='' YELLOW='' RED='' NC='' BOLD='' DIM='' CYAN=''
SYM_CHECK='+' SYM_WARN='!' SYM_CROSS='x' SYM_OK='+'
# shellcheck source=/dev/null
source "$repo/lib/utils.sh"
source "$repo/lib/awg.sh"
check_root() { :; }
for endpoint in '[2001:db8:56::2]:51820' '2001:db8:56::2:51820'; do
    cat > "$tmp/client.conf" <<CONF
[Interface]
PrivateKey = $(cat "$tmp/client.key")
Address = 10.250.20.1/32
Jc = 3
Jmin = 10
Jmax = 20
S1 = 0
S2 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4
[Peer]
PublicKey = $server_pub
Endpoint = $endpoint
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
CONF
    chmod 600 "$tmp/client.conf"
    awg_import "$tmp/client.conf" --name ipv6 --json > "$tmp/import.json"
    jq -e '.endpoint == "[2001:db8:56::2]:51820" and .endpoint_family == "ipv6"' "$tmp/import.json" >/dev/null
    AWG_ACTIVE=ipv6 AWG_MTU=1280
    _awg_check_endpoint_routes "$(_awg_store)/ipv6.conf"
    _awg_write_sys_conf
    awg-quick up "$(_awg_sys_conf)" > "$tmp/client.log" 2>&1
    ip route add 10.250.20.2/32 dev "$AWG_IFACE"
    for _ in {1..15}; do
        curl -4 -fsS --max-time 1 --interface "$AWG_IFACE" http://10.250.20.2:8188/probe.txt > "$tmp/reply" 2>/dev/null && break
        sleep 1
    done
    cmp "$tmp/probe.txt" "$tmp/reply"
    _awg_handshake_age >/dev/null
    awg show "$AWG_IFACE" endpoints | grep -Fq '[2001:db8:56::2]:51820'
    awg-quick down "$(_awg_sys_conf)" > "$tmp/client.log" 2>&1
    echo "OK IPv6 transport, inner IPv4 HTTP, Endpoint $endpoint"
done
ip -6 route delete 2001:db8:56::/64 dev uplink
if _awg_check_endpoint_routes "$(_awg_store)/ipv6.conf" > "$tmp/error" 2>&1; then
    echo 'Ожидался отказ без IPv6-маршрута' >&2; exit 1
fi
grep -q 'Нет IPv6-маршрута' "$tmp/error"
echo 'OK awg_ipv6: unreachable IPv6 diagnosed'
