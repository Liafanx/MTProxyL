#!/bin/bash
# Замок изменяющих команд: кто ждёт, кто нет, мёртвый хозяин, вложенный вызов.
set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
INSTALL_DIR="$t"; VERSION=test
source "$repo/lib/colors.sh"; source "$repo/lib/utils.sh"
MTPROXYL_LOCK_DIR="$t/lock"
fail() { echo "FAIL: $*"; exit 1; }
kind() { [ "$(cli_lock_kind "$@")" = "$K" ] || fail "$* → $(cli_lock_kind "$@"), ждали $K"; }

K=none; kind; kind status --json; kind secret list; kind secret link a; kind awg status --json
kind update --list; kind traffic; kind block hits --tsv; kind dc status --json
K=wait; kind secret add a; kind settings set x 1; kind update; kind update --version 1.7.17
kind restore f; kind awg check --json; kind awg on a b; kind start
K=tick; kind awg watch; kind dc watch; kind availability check --quiet
K=none; kind availability check --json

[ "$(id -u)" -eq 0 ] || { echo "SKIP (не root)"; exit 0; }
unset MTPROXYL_LOCK_HELD
cli_lock 1 "secret add a" || fail "свободный замок"
[ "$(cat "$t/lock/pid")" = "$$" ] || fail "pid хозяина"
# Второй процесс ждёт и сдаётся.
( unset MTPROXYL_LOCK_HELD; cli_lock 1 x 2>/dev/null ) && fail "занятый замок взят"
# Вложенный вызов из-под замка не ждёт.
( cli_lock 1 x ) || fail "вложенный вызов ждал"
cli_unlock
[ -d "$t/lock" ] && fail "замок не снят"
# Хозяин умер — замок забирают.
mkdir "$t/lock"; echo 999999 > "$t/lock/pid"
( unset MTPROXYL_LOCK_HELD; cli_lock 1 x && cli_unlock ) || fail "мёртвый хозяин держит"
echo "OK cli_lock"
