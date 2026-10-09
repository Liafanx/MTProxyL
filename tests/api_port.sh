#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"; VERSION=test; GITHUB_RAW=http://x
source "$repo/lib/colors.sh" || true
for _lib in utils settings detect secrets panel settings_cli; do source "$repo/lib/$_lib.sh"; done
_mktemp() { mktemp "${1:-$test_dir}/.tmp.XXXXXX"; }
backup_target_config() { TARGET_CONFIG_BACKUP=""; }
restarted=0
restart_target() { restarted=$((restarted + 1)); }
is_port_available() { [ "$1" != 9999 ]; }
systemctl() { :; }
systemd-run() { echo "$*" > "$test_dir/systemd-run"; }
panel_installed() { return 0; }
PANEL_CONFIG_DIR="$test_dir/panel"
mkdir -p "$PANEL_CONFIG_DIR"
printf '[server]\nlisten = "127.0.0.1:8080"\n\n[telemt]\nurl = "http://127.0.0.1:9093"\ncontainer_name = "x"\n' > "$PANEL_CONFIG_DIR/config.toml"

# Reanimator: the port lands in the target's [server.api], host kept.
MTPROXYL_MODE=reanimator
DETECTED_MODE=local
DETECTED_CONFIG_PATH="$test_dir/telemt.toml"
printf '[server]\nport = 443\n\n[server.api]\nenabled = true\nlisten = "0.0.0.0:9093"\n\n[access.users]\na = "0123456789abcdef0123456789abcdef"\n' > "$DETECTED_CONFIG_PATH"
[ "$(api_port_current)" = 9093 ]
api_port_set 9200 >/dev/null
[ "$(_toml_get_string_in_section server.api listen "$DETECTED_CONFIG_PATH")" = "0.0.0.0:9200" ]
[ "$restarted" -eq 1 ]
grep -qx 'url = "http://127.0.0.1:9200"' "$PANEL_CONFIG_DIR/config.toml"
grep -qx 'listen = "127.0.0.1:8080"' "$PANEL_CONFIG_DIR/config.toml"
grep -q -- '--on-active=3' "$test_dir/systemd-run"

# No [server.api] in the target: the section is appended.
printf '[access.users]\na = "0123456789abcdef0123456789abcdef"\n' > "$DETECTED_CONFIG_PATH"
api_port_set 9201 >/dev/null
[ "$(_toml_get_string_in_section server.api listen "$DETECTED_CONFIG_PATH")" = "127.0.0.1:9201" ]

# Busy or invalid port changes nothing.
if api_port_set 9999 2>/dev/null; then exit 1; fi
if api_port_set 70000 2>/dev/null; then exit 1; fi
[ "$(api_port_current)" = 9201 ]

# Same port: only the panel is resynced.
rm -f "$test_dir/systemd-run"
sed -i 's|^url = .*|url = "http://127.0.0.1:9091"|' "$PANEL_CONFIG_DIR/config.toml"
api_port_set 9201 >/dev/null
grep -qx 'url = "http://127.0.0.1:9201"' "$PANEL_CONFIG_DIR/config.toml"
[ "$restarted" -eq 2 ]

echo 'api port: ok'
