#!/bin/bash
# Изолированная проверка tc/HTB: не меняет qdisc рабочего интерфейса.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ip >/dev/null && command -v tc >/dev/null && command -v jq >/dev/null || {
    echo 'skip: ip/tc/jq unavailable'; exit 0;
}
namespace="mtproxyl-shaping-test-$$"
test_dir=$(mktemp -d)
cleanup() {
    ip netns del "$namespace" >/dev/null 2>&1 || true
    rm -rf "$test_dir"
}
trap cleanup EXIT
if ! ip netns add "$namespace" 2>/dev/null; then echo 'skip: no CAP_NET_ADMIN'; exit 0; fi
ip -n "$namespace" link add test0 type dummy
ip -n "$namespace" link set test0 up
ip netns exec "$namespace" tc qdisc replace dev test0 root fq

INSTALL_DIR="$test_dir"
PROXY_PORT=443
source lib/shaping.sh
tc() { ip netns exec "$namespace" /usr/sbin/tc "$@"; }
shaping_interface() { echo test0; }
web_is_enabled() { return 1; }
cfg=$(shaping_default_config | jq '.enabled=true | .ip_exempt=["203.0.113.0/24"]')
active='[{"ip":"198.51.100.1","exempt":false},{"ip":"198.51.100.2","exempt":true}]'
shaping_tc_apply "$cfg" "$active"
shaping_tc_owned test0
tc -j filter show dev test0 parent a11: | jq -e 'any(.[]; .options.classid? == "a11:20")' >/dev/null
tc -j filter show dev test0 parent a11: | jq -e 'any(.[]; .options.classid? == "a11:100" and .options.keys.dst_ip? == "198.51.100.1")' >/dev/null
tc -j filter show dev test0 parent a11: | jq -e 'any(.[]; .options.classid? == "a11:30" and .options.keys.dst_ip? == "198.51.100.2")' >/dev/null
tc -j filter show dev test0 parent a11: | jq -e 'any(.[]; .options.classid? == "a11:40")' >/dev/null
[ "$(jq -r '.rate_bps' "$SHAPING_TC_FILE")" = 90000000 ]
web_is_enabled() { return 0; }
web_public_port() { echo 8443; }
shaping_tc_apply "$cfg" "$active"
tc -j filter show dev test0 parent a11: | jq -e 'any(.[]; .options.classid? == "a11:100" and .options.keys.src_port? == 8443)' >/dev/null
updated='[{"ip":"198.51.100.2","exempt":true},{"ip":"198.51.100.3","exempt":false}]'
shaping_tc_sync "$cfg" "$updated" 45000000
shaping_tc_owned test0
tc -j filter show dev test0 parent a11: | jq -e 'any(.[]; .options.classid? == "a11:102" and .options.keys.dst_ip? == "198.51.100.3")' >/dev/null
tc -j filter show dev test0 parent a11: | jq -e 'all(.[]; .options.keys.dst_ip? != "198.51.100.1")' >/dev/null
[ "$(jq -r '.rate_bps' "$SHAPING_TC_FILE")" = 45000000 ]
hundred=$(jq -nc '[range(1;101) | {ip:("198.51.100.\(.)"),exempt:false}]')
hundred_cfg=$(printf '%s\n' "$cfg" | jq '.mode="fixed" | .expected_users=100')
shaping_tc_apply "$hundred_cfg" "$hundred"
[ "$(jq -r '.ips | length' "$SHAPING_TC_FILE")" = 100 ]
[ "$(jq -r '.rate_bps' "$SHAPING_TC_FILE")" = 9000000 ]
tc -j class show dev test0 | jq -e 'any(.[]; .handle == "a11:163")' >/dev/null
shaping_tc_disable
[ "$(shaping_root_kind test0)" = fq ]

# Полный цикл включения/выключения: без реального telemt и systemd.
SHAPING_BOOT_UNIT="$test_dir/boot.service"
SHAPING_TICK_UNIT="$test_dir/tick.service"
SHAPING_TIMER_UNIT="$test_dir/tick.timer"
_superexpert_active() { return 1; }
engine_config_path() { echo "$test_dir/config.toml"; }
shaping_reload_telemt() { :; }
systemctl() { :; }
log_success() { :; }
log_error() { echo "$*" >&2; }
log_warn() { echo "$*" >&2; }
shaping_fetch_active_map() { printf '%s\n' "$active"; }
printf '%s\n' "$cfg" | shaping_apply
shaping_tc_owned test0
printf '%s\n' "$cfg" | jq '.enabled=false' | shaping_apply
[ "$(shaping_root_kind test0)" = fq ]
[ "$(jq -r '.enabled' "$SHAPING_FILE")" = false ]

# Ошибка применения конфигурации движка возвращает прежний файл и qdisc.
printf '%s\n' '[access]' 'legacy = true' > "$test_dir/config.toml"
shaping_reload_telemt() { printf '%s\n' '[access]' 'new = true' > "$test_dir/config.toml"; return 1; }
shaping_signal_telemt() { :; }
if printf '%s\n' "$cfg" | shaping_apply >/dev/null 2>&1; then echo 'failed reload accepted' >&2; exit 1; fi
grep -q '^legacy = true$' "$test_dir/config.toml"
[ "$(shaping_root_kind test0)" = fq ]
[ "$(jq -r '.enabled' "$SHAPING_FILE")" = false ]

# Чужой нестандартный qdisc не заменяем.
tc qdisc replace dev test0 root tbf rate 10mbit burst 16kbit latency 50ms
if shaping_tc_apply "$cfg" >/dev/null 2>&1; then echo 'foreign qdisc overwritten' >&2; exit 1; fi
[ "$(shaping_root_kind test0)" = tbf ]
echo 'shaping tc tests: ok'
