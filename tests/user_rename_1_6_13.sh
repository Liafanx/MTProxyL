#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-user-rename.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir/manager"
CONFIG_DIR="$INSTALL_DIR/mtproxy"
SETTINGS_FILE="$INSTALL_DIR/settings.conf"
SECRETS_FILE="$INSTALL_DIR/secrets.conf"
VERSION=1.6.13
BOLD="" DIM="" NC="" GREEN="" YELLOW="" RED="" BLUE=""
mkdir -p "$INSTALL_DIR/relay_stats" "$CONFIG_DIR"

source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"
source "$repo/lib/config.sh"
source "$repo/lib/detect.sh"
source "$repo/lib/secrets.sh"
source "$repo/lib/web.sh"

log_info() { :; }
log_success() { :; }
log_warn() { :; }
log_error() { :; }
_mktemp() { mktemp "${1:-$test_dir}/fixture.XXXXXX"; }
reload_proxy_config() { :; }
backup_target_config() { :; }
_target_users_apply() { :; }
fail() { echo "FAIL: $*" >&2; exit 1; }

SECRETS_LABELS=(alice)
SECRETS_KEYS=(0123456789abcdef0123456789abcdef)
SECRETS_CREATED=(1700000000)
SECRETS_ENABLED=(true)
SECRETS_MAX_CONNS=(4)
SECRETS_MAX_IPS=(2)
SECRETS_QUOTA=(4096)
SECRETS_EXPIRES=(0)
SECRETS_NOTES=(note)
SECRETS_ADTAG=("")
printf 'TOTAL|10|20\nUSER|alice|10|20\n' > "$INSTALL_DIR/relay_stats/traffic_db"
printf 'USER|alice|192.0.2.1|100|200\n' > "$INSTALL_DIR/relay_stats/user_ips_db"
printf 'alice|10|20\n' > "$INSTALL_DIR/relay_stats/user_session_snapshot"

secret_rename alice renamed
grep -q '^renamed|' "$SECRETS_FILE" || fail 'manager secrets label not renamed'
grep -q '^USER|renamed|10|20$' "$INSTALL_DIR/relay_stats/traffic_db" || fail 'manager traffic not moved'
grep -q '^USER|renamed|192.0.2.1|100|200$' "$INSTALL_DIR/relay_stats/user_ips_db" || fail 'manager IP history not moved'
grep -q '^renamed|10|20$' "$INSTALL_DIR/relay_stats/user_session_snapshot" || fail 'manager snapshot not moved'

INSTALL_DIR="$test_dir/reanimator"
mkdir -p "$INSTALL_DIR/relay_stats"
DETECTED_CONFIG_PATH="$INSTALL_DIR/target.toml"
cat > "$DETECTED_CONFIG_PATH" <<'EOF'
[access.users]
alice = "0123456789abcdef0123456789abcdef"

[access.user_data_quota]
alice = 4096

[web]
enabled = true

[[web.vhosts]]
host = "proxy.example.com"

[[web.vhosts.profiles]]
user = "alice"
secret_mode = "ee"
EOF
printf 'SOURCE|api\nUSER|alice|0|0|1234\n' > "$INSTALL_DIR/relay_stats/target_traffic_db"
printf 'USER|alice|198.51.100.2|300|400\n' > "$INSTALL_DIR/relay_stats/target_user_ips_db"
printf 'SOURCE|api\nUSER|alice|0|0|1234\n' > "$INSTALL_DIR/relay_stats/target_session_snapshot"

target_user_rename alice renamed
[[ $(_target_user_state renamed) == on ]] || fail 'target user not renamed'
[[ -z $(_target_user_state alice) ]] || fail 'old target user remained'
[[ $(_target_user_limit renamed access.user_data_quota) == 4096 ]] || fail 'target quota not moved'
[[ $(web_target_profiles) == 'renamed|ee' ]] || fail 'WEB profile name or secret mode not preserved'
grep -q '^USER|renamed|0|0|1234$' "$INSTALL_DIR/relay_stats/target_traffic_db" || fail 'target traffic not moved'
grep -q '^USER|renamed|198.51.100.2|300|400$' "$INSTALL_DIR/relay_stats/target_user_ips_db" || fail 'target IP history not moved'
grep -q '^USER|renamed|0|0|1234$' "$INSTALL_DIR/relay_stats/target_session_snapshot" || fail 'target snapshot not moved'

echo 'user rename tests: OK'
