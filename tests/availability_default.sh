#!/bin/bash
# Проверка доступности по расписанию после установки выключена.
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
for f in lib/*.sh; do source "$f" >/dev/null 2>&1; done
fail() { printf '%s\n' "$*" >&2; exit 1; }

[ "$AVAILABILITY_ENABLED" = false ] || fail "по умолчанию: $AVAILABILITY_ENABLED"
availability_enabled && fail 'по умолчанию включена'
AVAILABILITY_ENABLED=""; availability_enabled && fail 'пустое значение включает'
AVAILABILITY_ENABLED=true; availability_enabled || fail 'true не включает'
echo "availability default: ok"
