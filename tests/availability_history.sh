#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-availability-history.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir/state"
SETTINGS_FILE="$INSTALL_DIR/settings.conf"
AVAILABILITY_HISTORY_LIMIT=3
mkdir -p "$INSTALL_DIR"

source "$repo/lib/availability.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

result() {
    jq -nc \
        --arg at "$1" --argjson ok "$2" --argjson total "$3" --arg error "${4:-}" '
        {
            checked_at: $at,
            target: "proxy.example.com:443 (SNI: mask.example.com)",
            level: (if $error != "" or $total == 0 then "red" elif ($ok * 100 / $total) >= 80 then "green" else "yellow" end),
            percentage: (if $total > 0 then ($ok * 100 / $total) else 0 end),
            success_probes: $ok,
            total_probes: $total,
            measurement_id: "measurement",
            probes: [{city:"Москва",tls_success:true}],
            error: $error
        }'
}

_availability_write_state "$(result 2026-09-12T00:00:00Z 12 15)"
_availability_write_state "$(result 2026-09-12T00:15:00Z 18 24)"
_availability_write_state "$(result 2026-09-12T00:30:00Z 20 20)"
_availability_write_state "$(result 2026-09-12T00:45:00Z 0 0 'сервис проверки не отвечает')"

history=$(availability_history_json)
jq -e '.limit == 3 and (.points | length) == 3' <<< "$history" >/dev/null || fail 'history limit not retained'
jq -e '.points[0].total_probes == 24 and .points[0].success_probes == 18' <<< "$history" >/dev/null || fail 'per-check probe count lost'
jq -e '.points[1].total_probes == 20 and .points[2].error != ""' <<< "$history" >/dev/null || fail 'success/error points malformed'
jq -e '[.points[] | has("probes")] | any | not' <<< "$history" >/dev/null || fail 'heavy probe list stored in history'
[[ $(stat -c '%a' "$INSTALL_DIR/availability/history.jsonl") == 600 ]] || fail 'history is not mode 600'

# Уменьшение применяется сразу, без ожидания следующей проверки.
AVAILABILITY_HISTORY_LIMIT=2
availability_history_compact
history=$(availability_history_json)
jq -e '.limit == 2 and (.points | length) == 2 and .points[0].checked_at == "2026-09-12T00:30:00Z"' \
    <<< "$history" >/dev/null || fail 'history did not compact immediately'

# Оборванная строка не ломает чтение остальных точек.
printf '%s\n' '{broken' >> "$INSTALL_DIR/availability/history.jsonl"
history=$(availability_history_json)
jq -e '(.points | length) == 2' <<< "$history" >/dev/null || fail 'broken line broke history JSON'

# При обновлении существующий last.json сразу виден, а первая новая проверка
# переносит его в файл истории ровно один раз.
INSTALL_DIR="$test_dir/legacy"
mkdir -p "$INSTALL_DIR/availability"
AVAILABILITY_HISTORY_LIMIT=1000
result 2026-09-11T23:45:00Z 15 15 > "$INSTALL_DIR/availability/last.json"
jq -e '(.points | length) == 1' <<< "$(availability_history_json)" >/dev/null || fail 'legacy last result not exposed'
_availability_write_state "$(result 2026-09-12T00:00:00Z 19 20)"
history=$(availability_history_json)
jq -e '(.points | length) == 2 and .points[0].total_probes == 15 and .points[1].total_probes == 20' \
    <<< "$history" >/dev/null || fail 'legacy result migration duplicated or lost a point'

# Последний результат и график переживают обычный бэкап и экспорт миграции.
BACKUP_DIR="$test_dir/backups"
STATS_DIR="$test_dir/no-stats"
GEOBLOCK_CACHE_DIR="$test_dir/no-geoblock"
VERSION=dev
SECRETS_FILE="$INSTALL_DIR/secrets.conf"
printf 'settings\n' > "$INSTALL_DIR/settings.conf"
printf 'secrets\n' > "$SECRETS_FILE"
_mktemp() { mktemp "$test_dir/file.XXXXXX"; }
_warp_account() { printf '%s\n' "$test_dir/no-warp-account"; }
log_success() { :; }
log_error() { :; }
source "$repo/lib/backup.sh"
backup_file=$(create_backup)
backup_listing=$(tar tzf "$backup_file")
grep -qx 'availability/last.json' <<< "$backup_listing" || fail 'last result missing from backup'
grep -qx 'availability/history.jsonl' <<< "$backup_listing" || fail 'history missing from backup'
migration_file="$test_dir/migration.tar.gz"
migrate_export "$migration_file"
migration_listing=$(tar tzf "$migration_file")
grep -qx './availability/last.json' <<< "$migration_listing" || fail 'last result missing from migration export'
grep -qx './availability/history.jsonl' <<< "$migration_listing" || fail 'history missing from migration export'

echo 'availability history tests: OK'
