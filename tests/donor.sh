#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-donor.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir/opt"
BACKUP_DIR="$test_dir/backups"
VERSION=test
BLUE="" GREEN="" YELLOW="" RED="" NC="" BOLD="" DIM="" CYAN=""
SYM_CHECK="+" SYM_WARN="!" SYM_CROSS="x"
mkdir -p "$INSTALL_DIR"

# shellcheck source=/dev/null
source "$repo/lib/utils.sh"
source "$repo/lib/detect.sh"
source "$repo/lib/donor.sh"

fails() { if "$@" >/dev/null 2>&1; then echo "Должно было не пройти: $*" >&2; exit 1; fi; }
_mktemp() { mktemp "${1:-$test_dir}/.tmp.XXXXXX"; }

# Параметры обфускации: ограничения AWG соблюдаются всегда.
for _ in $(seq 1 200); do
    _donor_gen_params
    eval "$(printf '%s\n' "$_DONOR_PARAMS" | sed 's/ = /=/')"
    [ "$Jc" -ge 4 ] && [ "$Jc" -le 12 ]
    [ "$Jmin" -lt "$Jmax" ] && [ "$Jmax" -le 1280 ]
    [ "$S1" -ge 15 ] && [ "$S1" -le 150 ] && [ "$S2" -ge 15 ] && [ "$S2" -le 150 ]
    [ $((S1 + 56)) -ne "$S2" ]
    for h in "$H1" "$H2" "$H3" "$H4"; do [ "$h" -ge 5 ] && [ "$h" -le 2147483647 ]; done
    [ "$(printf '%s\n' "$H1" "$H2" "$H3" "$H4" | sort -u | wc -l)" = 4 ]
    grep -qE '^I1 = <b 0xc10000000108[0-9a-f]{16}00>$' <<< "$_DONOR_SIGNATURE"
    [ "$(printf '%s\n' "$_DONOR_SIGNATURE" | wc -l)" = 5 ]
done

# Подсеть: пересечения с адресами и маршрутами, свой интерфейс не в счёт.
eval "$(_donor_agent_script)"
ip() {
    case "$*" in
        "-4 -o addr show") printf '2: eth0    inet 10.201.5.9/24 brd x\n3: mtpdonor    inet 10.240.0.2/30 scope global\n' ;;
        "-4 route show") printf 'default via 1.1.1.1 dev eth0\n10.0.0.1 dev eth0 scope link\n172.16.0.0/12 dev br0\nblackhole 10.230.0.0/16\n10.240.0.0/30 dev mtpdonor\n' ;;
    esac
}
_mtpd_net_busy 10.201.5.0 mtpdonor
_mtpd_net_busy 10.0.0.0 mtpdonor
fails _mtpd_net_busy 10.201.6.0 mtpdonor
fails _mtpd_net_busy 10.240.0.0 mtpdonor
_mtpd_net_busy 10.240.0.0 other
unset -f ip
net=$(ip() { :; }; _donor_pick_net)
[[ "$net" =~ ^10\.(2[0-4][0-9])\.[0-9]+\.[0-9]+$ ]]
[ $(( ${net##*.} % 4 )) = 0 ]

# Проверка ввода.
_donor_valid_ipv4 31.76.78.135
fails _donor_valid_ipv4 127.0.0.1
fails _donor_valid_ipv4 300.1.1.1
fails _donor_valid_ipv4 "1.2.3.4; rm -rf /"
_donor_valid_pubkey "QZcNc85hYh8MVnlMymhaUFy28PXqWauJ0s9SLRvRZ3c="
fails _donor_valid_pubkey "QZcNc85hYh8MVnlMymhaUFy28PXqWauJ0s9SLRvRZ3d="
_donor_valid_fp "SHA256:$(printf 'a%.0s' $(seq 1 43))"
fails _donor_valid_user "root; id"

# Состояние: круг сохранения, мусор в числах отбрасывается.
_donor_reset_vars
DONOR_HOST=31.76.78.135; DONOR_NET=10.222.3.8; DONOR_AWG_PORT=47321; DONOR_STAGE=ready
DONOR_DISABLED_UPSTREAMS="direct,backup"; DONOR_CHECK_RTT="abc"
donor_save
[ "$(stat -c %a "$(_donor_state_file)")" = 600 ]
donor_load
[ "$DONOR_HOST" = 31.76.78.135 ] && [ "$DONOR_AWG_PORT" = 47321 ] && [ -z "$DONOR_CHECK_RTT" ]
[ "$DONOR_DISABLED_UPSTREAMS" = "direct,backup" ]
[ "$(_donor_local_ip)" = 10.222.3.10 ] && [ "$(_donor_remote_ip)" = 10.222.3.9 ]
[ "$(_donor_socks_addr)" = 10.222.3.9:1080 ]
echo "DONOR_HOST='1.1.1.1'; touch $test_dir/pwned" >> "$(_donor_state_file)"
donor_load; [ ! -e "$test_dir/pwned" ]

# Агент собирается в корректную программу.
_donor_gen_params
bash -n <(_donor_agent_program setup 0 "QZcNc85hYh8MVnlMymhaUFy28PXqWauJ0s9SLRvRZ3c=" 2.27.21.167)
[ "$(_donor_agent_program setup 0 KEY 1.2.3.4 | tail -1)" = '_mtpd_main </dev/null' ]
_DONOR_AGENT_OUT=$'MTPD:pub=abc\nMTPD:port=123\nMTPD:port=456'
[ "$(_donor_agent_value port)" = 456 ]

# Конфиг цели: маршрут добавляется, чужие без области выключаются с пометкой,
# откат возвращает файл как был.
cfg="$test_dir/telemt.toml"
cat > "$cfg" <<'EOF'
[general]
use_middle_proxy = true

[censorship]
tls_domain = "example.com"

[[upstreams]]
type = "direct"
weight = 10

[[upstreams]]
type = "socks5"
address = "127.0.0.1:9050"
enabled = true

[[upstreams]]
type = "direct"
scopes = "local"

[[upstreams]]
type = "direct"
interface = "eth1"
enabled = false

[access.users]
alice = "00112233445566778899aabbccddeeff"
EOF
cp "$cfg" "$test_dir/orig.toml"
MTPROXYL_MODE=reanimator; DETECTED_MODE=local; DETECTED_CONFIG_PATH="$cfg"
[ "$(_donor_target_default_upstreams)" = "direct,socks5" ]
_donor_target_rewrite apply "$(_donor_target_block)"
grep -q '^address = "10.222.3.9:1080"$' "$cfg"
[ "$(grep -c '^enabled = false  # mtproxyl-donor' "$cfg")" = 2 ]
[ -z "$(_donor_target_default_upstreams)" ]
[ "$(awk '/^\[\[upstreams\]\]/{n++} n==3 && /scopes/' "$cfg")" = 'scopes = "local"' ]
first=$(md5sum < "$cfg")
_donor_target_rewrite apply "$(_donor_target_block)"
[ "$(md5sum < "$cfg")" = "$first" ]
_donor_target_rewrite revert
cmp "$cfg" "$test_dir/orig.toml"
if grep -q mtproxyl-donor "$cfg"; then echo "метки остались" >&2; exit 1; fi

# Локальная заглушка: к маршруту добавляется прямой для TLS-метаданных.
_toml_safe_set mask_host '"127.0.0.1"' censorship "$cfg"
grep -q 'scopes = "local"' <<< "$(_donor_target_block)"

# Менеджер: чужие маршруты выключаются и возвращаются.
MTPROXYL_MODE=manager; TOOLS_ONLY=false
_superexpert_active() { return 1; }
calls="$test_dir/calls"; : > "$calls"
UPSTREAM_NAMES=(direct warp-old scoped); UPSTREAM_ENABLED=(true true true); UPSTREAM_SCOPES=("" "" "me")
load_upstreams() { :; }
upstream_toggle() { echo "toggle $*" >> "$calls"; }
upstream_remove() { echo "remove $*" >> "$calls"; }
upstream_add() { echo "add $*" >> "$calls"; }
handle_expert_command() { echo "expert $* mode=${MTPROXYL_MODE}" >> "$calls"; }
generate_telemt_config() { echo generate >> "$calls"; }
is_proxy_running() { return 0; }
restart_proxy_container() { echo restart >> "$calls"; }
SELFMASK_ENABLED=true
[ "$(_donor_foreign_default_upstreams)" = "direct,warp-old" ]
DONOR_DISABLED_UPSTREAMS=""
fails _donor_apply_manager false <<< "n"
MTPROXYL_ASSUME_YES=1
fails _donor_apply_manager false
_donor_apply_manager true >/dev/null
grep -q "^toggle direct disable$" "$calls" && grep -q "^toggle warp-old disable$" "$calls"
grep -q "^add donor socks5 10.222.3.9:1080" "$calls"
grep -q "^add donorlocal direct" "$calls" && grep -q "^expert set censorship tls_fetch_scope local" "$calls"
[ "$(grep -c '^restart$' "$calls")" = 1 ]
donor_load; [ "$DONOR_DISABLED_UPSTREAMS" = "direct,warp-old" ] && [ "$DONOR_ENGINE_ROUTED" = manager ]
: > "$calls"
_donor_drop_manager >/dev/null
grep -q "^toggle direct enable$" "$calls" && grep -q "^remove donor$" "$calls"
donor_load; [ -z "$DONOR_DISABLED_UPSTREAMS" ] && [ -z "$DONOR_ENGINE_ROUTED" ]

# Маршрут менеджера снимается и из реаниматора: без перезапуска движка,
# настройки expert чистятся как у менеджера.
DONOR_DISABLED_UPSTREAMS="direct"; donor_save; : > "$calls"
MTPROXYL_MODE=reanimator
_donor_drop_manager >/dev/null
grep -q "^expert clear censorship tls_fetch_scope --no-apply mode=manager$" "$calls"
grep -q "^toggle direct enable$" "$calls"
if grep -qE "^(generate|restart)$" "$calls"; then echo "движок тронут в реаниматоре" >&2; exit 1; fi
[ "$MTPROXYL_MODE" = reanimator ]
MTPROXYL_MODE=manager
unset MTPROXYL_ASSUME_YES

# Ключ хоста: одно соединение на тип ключа, повторный скан не нужен, если
# ключ уже подтверждён (защита от перебора на доноре считает соединения).
ssh-keygen -q -t ed25519 -N "" -f "$test_dir/hk" >/dev/null
hk_line="31.76.78.135 $(cut -d' ' -f1,2 "$test_dir/hk.pub")"
hk_fp=$(ssh-keygen -lf "$test_dir/hk.pub" -E sha256 | awk '{print $2}')
scans="$test_dir/scans"; : > "$scans"; scan_mode=ok
ssh-keyscan() {
    echo "$*" >> "$scans"
    case "$scan_mode" in
        ok) echo "# 31.76.78.135:22 SSH-2.0-OpenSSH_9.6"; [[ "$*" == *"-t ed25519"* ]] && echo "$hk_line" ;;
        noed) echo "# 31.76.78.135:22 SSH-2.0-OpenSSH_9.6"; [[ "$*" == *"-t ecdsa"* ]] && echo "$hk_line" ;;
        down) : ;;
    esac
    return 0
}
DONOR_HOST=31.76.78.135; DONOR_SSH_PORT=22
_donor_scan_host; [ "$(wc -l < "$scans")" = 1 ]; grep -qF "$hk_fp (ED25519)" <<< "$_DONOR_FPS"
: > "$scans"; scan_mode=noed; _donor_scan_host; [ "$(wc -l < "$scans")" = 2 ]
: > "$scans"; scan_mode=down; fails _donor_scan_host; [ "$(wc -l < "$scans")" = 1 ]
# Шаг «Получить ключ хоста» сохраняет скан — настройка его не повторяет.
scan_mode=ok; rm -f "$(_donor_known_hosts)"
donor_hostkey 31.76.78.135 --json | grep -qF "$hk_fp"
: > "$scans"
_donor_trust_host "$hk_fp" >/dev/null; [ "$(wc -l < "$scans")" = 0 ]
grep -qF "$(cut -d' ' -f2 "$test_dir/hk.pub")" "$(_donor_known_hosts)"
# Ключ уже в known_hosts — без сети; чужой отпечаток не принимается.
rm -f "$(_donor_scan_cache)"
_donor_trust_host "$hk_fp" >/dev/null; [ "$(wc -l < "$scans")" = 0 ]
_donor_trust_host "" >/dev/null; [ "$(wc -l < "$scans")" = 0 ]
fails _donor_trust_host "SHA256:$(printf 'b%.0s' $(seq 1 43))"
unset -f ssh-keyscan

# MTU туннеля — на обеих сторонах, по умолчанию 1280.
_donor_reset_vars; [ "$DONOR_MTU" = 1280 ]
_donor_agent_env setup 0 KEY 1.2.3.4 | grep -qx "MTPD_MTU=1280"
DONOR_MTU=1500; _donor_valid_mtu "$DONOR_MTU" && exit 1
DONOR_MTU=1360; _donor_agent_env setup 0 KEY 1.2.3.4 | grep -qx "MTPD_MTU=1360"
grep -q 'echo "MTU = ${MTPD_MTU:-1280}"' <<< "$(_donor_agent_script)"
donor_load

# WARP и донор одновременно — нельзя.
WARP_ENABLED=true; fails _donor_guard_conflicts; WARP_ENABLED=false

# Статус для панели — корректный JSON.
awg() { return 1; }; ip() { return 1; }
json=$(donor_status_json)
python3 - "$json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["configured"] and d["stage"] == "ready" and d["host"] == "31.76.78.135", d
assert d["socks"] == "10.222.3.9:1080" and d["awg_port"] == 47321, d
assert d["engine_mode"] == "manager" and d["tunnel_up"] is False and d["check"]["rtt_ms"] is None, d
PY

# Хук DKMS: макросы udp_tunnel зависят от заголовков ядра, повторный запуск
# ничего не дублирует, чужие исходники не ломает.
hookdir=$(mktemp -d); mkdir -p "$hookdir/compat"
sed -n "/<<'HOOK'$/,/^HOOK$/p" <<< "$(_donor_agent_script)" | sed '1d;$d' > "$hookdir/hook.sh"
printf 'ccflags-y := -DX\n' > "$hookdir/Kbuild"
printf '%s\n' '#if LINUX_VERSION_CODE < KERNEL_VERSION(7, 1, 5)' '#include <net/udp_tunnel.h>' \
    '#define setup_udp_tunnel_sock(net, sk, sock_cfg) setup_udp_tunnel_sock(net, sk->sk_socket, sock_cfg)' \
    '#define udp_tunnel_sock_release(sk) udp_tunnel_sock_release(sk->sk_socket)' '#endif' > "$hookdir/compat/compat.h"
(cd "$hookdir" && sh hook.sh && sh hook.sh)
[ "$(grep -c '^#ifndef MTPL_UDP_TUNNEL_SETUP_SK$' "$hookdir/compat/compat.h")" = 1 ]
[ "$(grep -c '^#ifndef MTPL_UDP_TUNNEL_RELEASE_SK$' "$hookdir/compat/compat.h")" = 1 ]
[ "$(grep -c 'MTPL_UDP_TUNNEL_SETUP_SK' "$hookdir/Kbuild")" = 1 ]
# make считает скобки внутри $(shell): в шаблонах их быть не должно.
! grep 'grep -qsE' "$hookdir/Kbuild" | grep -q "'[^']*[(),][^']*'"
grep -q 'PRE_BUILD="../../../../../..%s"' <<< "$(_donor_agent_script)"
rm -rf "$hookdir"

echo "donor: ok"
