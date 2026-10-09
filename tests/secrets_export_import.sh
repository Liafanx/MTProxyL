#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"; VERSION=test
source "$repo/lib/colors.sh" || true
for _lib in utils settings detect secrets; do source "$repo/lib/$_lib.sh"; done
SECRETS_FILE="$test_dir/secrets.conf"
backup_target_config() { TARGET_CONFIG_BACKUP=""; }
_target_users_apply() { :; }
web_target_add_profile() { :; }
reload_proxy_config() { :; }
_mktemp() { mktemp "${1:-$test_dir}/.tmp.XXXXXX"; }
k1=0123456789abcdef0123456789abcdef
k2=fedcba9876543210fedcba9876543210
k3=00112233445566778899aabbccddeeff

# Reanimator: limits, expiry, ad tag and the disabled state go into the export.
DETECTED_CONFIG_PATH="$test_dir/target.toml"
cat > "$DETECTED_CONFIG_PATH" <<TOML
[access.users]
alice = "$k1"
#mtproxyl-off bob = "$k2"

[access.user_max_tcp_conns]
alice = 5

[access.user_max_unique_ips]
bob = 2

[access.user_data_quota]
alice = 1073741824

[access.user_expirations]
bob = "2027-01-31T23:59:59Z"

[access.user_ad_tags]
alice = "$k3"
TOML
target_users_export - > "$test_dir/export.csv"
grep -qx "alice|$k1|true|5|0|1073741824|0||$k3" "$test_dir/export.csv"
grep -qx "bob|$k2|false|0|2|0|2027-01-31T23:59:59Z||" "$test_dir/export.csv"

# Manager imports it from stdin with every limit intact.
load_secrets
secret_import_file - < "$test_dir/export.csv" >/dev/null
load_secrets
[ "${#SECRETS_LABELS[@]}" -eq 2 ]
[ "${SECRETS_MAX_CONNS[0]}|${SECRETS_QUOTA[0]}|${SECRETS_ADTAG[0]}" = "5|1073741824|$k3" ]
[ "${SECRETS_ENABLED[1]}|${SECRETS_MAX_IPS[1]}|${SECRETS_EXPIRES[1]}" = "false|2|2027-01-31T23:59:59Z" ]
# Second import skips existing labels.
[[ "$(secret_import_file - < "$test_dir/export.csv")" == *"Импортировано: 0, пропущено дубликатов: 2"* ]]

# Manager export round-trips; notes survive.
SECRETS_NOTES[0]="vip|client"
secret_export_file - > "$test_dir/manager.csv"
grep -qx "alice|$k1|true|5|0|1073741824|0|vip client|$k3" "$test_dir/manager.csv"

# Reanimator import into an empty target keeps limits and the disabled state.
printf '[access.users]\nroot = "%s"\n' "$k3" > "$DETECTED_CONFIG_PATH"
target_users_import "$test_dir/manager.csv" >/dev/null
target_users_export - > "$test_dir/back.csv"
grep -qx "alice|$k1|true|5|0|1073741824|0||$k3" "$test_dir/back.csv"
grep -qx "bob|$k2|false|0|2|0|2027-01-31T23:59:59Z||" "$test_dir/back.csv"
grep -qx "root|$k3|true|0|0|0|0||" "$test_dir/back.csv"
printf 'bad line\n' | target_users_import - | grep -q "строк с ошибкой: 1"

echo 'secrets export/import: ok'
