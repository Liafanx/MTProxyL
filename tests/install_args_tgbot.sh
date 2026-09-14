#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-install-tgbot.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir/state"
CONFIG_DIR="$INSTALL_DIR/mtproxy"
SETTINGS_FILE="$INSTALL_DIR/settings.conf"
VERSION=dev
GITHUB_RAW="https://example.invalid"
BOLD="" DIM="" NC="" GREEN="" YELLOW="" RED="" BLUE="" CYAN=""
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"
source "$repo/lib/tgbot.sh"
source "$repo/lib/install_args.sh"
source "$repo/lib/migrate.sh"

log_info() { :; }
log_success() { :; }
log_warn() { :; }
log_error() { :; }
fail() { echo "FAIL: $*" >&2; exit 1; }

token='1234567890:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef_123456'
admin='123456789012345'

_install_args_parse --mode manager --tgbot-token "$token" --tgbot-admin "$admin"
[[ "$_IA_TGBOT_TOKEN" == "$token" ]] || fail 'bot token not parsed'
[[ "$_IA_TGBOT_ADMIN" == "$admin" ]] || fail 'bot admin not parsed'
_install_args_validate || fail 'valid bot arguments rejected'

_IA_TGBOT_TOKEN="$token"
_IA_TGBOT_ADMIN=""
if _install_args_validate >/dev/null 2>&1; then
    fail 'token without admin accepted'
fi
_IA_TGBOT_TOKEN="bad-token"
_IA_TGBOT_ADMIN="$admin"
if _install_args_validate >/dev/null 2>&1; then
    fail 'invalid token accepted'
fi

# Переезд аргументами намеренно не показывает токен существующего бота.
if grep -q -- '--tgbot-token\|--bot-token' "$repo/lib/argsgen.sh"; then
    fail 'argument-export menu contains bot token flag'
fi
if grep -qE 'tgbot install[^"]*--token' "$repo/lib/migrate.sh"; then
    fail 'SSH migration puts bot token in command arguments'
fi

# Переезд ставит полный конфиг из защищённого файла, без секрета в argv/stdout.
TGBOT_DIR="$test_dir/tgbot"
TGBOT_CONFIG="$TGBOT_DIR/config.json"
TGBOT_VENV="$TGBOT_DIR/venv"
TGBOT_USER="root"
TGBOT_SERVICE="mtproxyl-tgbot-test.service"
mkdir -p "$TGBOT_DIR"
source_config="$test_dir/source-config.json"
jq -n --arg token "$token" --argjson admin "$admin" \
    '{token:$token,admins:[$admin],notify:{proxy:false},intervals:{proxy:7},autobackup:{enabled:false}}' \
    > "$source_config"
chmod 600 "$source_config"

check_root() { :; }
_tgbot_install_deps() { :; }
_tgbot_check_token() { :; }
_tgbot_ensure_user() { :; }
_tgbot_fetch_sources() { :; }
_tgbot_build_venv() { :; }
_tgbot_write_sudoers() { :; }
_tgbot_write_service() { :; }
tgbot_service_active() { return 0; }
systemctl() { :; }
sleep() { :; }

install_output=$(tgbot_install --config-file "$source_config" 2>&1)
[[ "$install_output" != *"$token"* ]] || fail 'token leaked to installer output'
jq -e --arg token "$token" --argjson admin "$admin" \
    '.token==$token and .admins==[$admin] and .notify.proxy==false and .intervals.proxy==7' \
    "$TGBOT_CONFIG" >/dev/null || fail 'config-file installation lost bot settings'

tgbot_service_active() { return 1; }
journalctl() { :; }
if failed_output=$(tgbot_install --config-file "$source_config" 2>&1); then
    fail 'bot install succeeded while service was down'
fi
[[ "$failed_output" != *"$token"* ]] || fail 'failed install leaked token to output'
tgbot_service_active() { return 0; }

migration_calls="$test_dir/migration-calls"
_mig_scp() { printf 'scp %s %s\n' "$1" "$2" >> "$migration_calls"; }
_mig_ssh() {
    printf 'ssh %s\n' "$*" >> "$migration_calls"
    case "$*" in
        *api.telegram.org*) printf '200\n' ;;
        *'mktemp /tmp/.mtproxyl-tgbot-migrate.XXXXXX'*) printf '/tmp/.mtproxyl-tgbot-migrate.A1b2C3\n' ;;
    esac
}
tgbot_installed() { return 0; }
_mig_push_tgbot
grep -q -- '--config-file /tmp/.mtproxyl-tgbot-migrate.A1b2C3' "$migration_calls" || \
    fail 'migration did not install bot from protected config file'
if grep -Fq "$token" "$migration_calls"; then
    fail 'migration leaked bot token into SSH/scp arguments'
fi

echo 'install args and bot migration tests: OK'
