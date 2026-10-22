#!/bin/bash
# Чужой SNI по умолчанию — reject_handshake; движку старше 3.4.4 он
# незнаком, и туда пишется mask.
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
for f in lib/*.sh; do source "$f" >/dev/null 2>&1; done
fail() { printf '%s\n' "$*" >&2; exit 1; }

[ "$UNKNOWN_SNI_ACTION" = reject_handshake ] || fail "по умолчанию: $UNKNOWN_SNI_ACTION"
check() { [ "$(sni_action_for_engine "$1" "$2")" = "$3" ] || fail "$1 @ '$2': $(sni_action_for_engine "$1" "$2"), ждали $3"; }
check reject_handshake 3.5.14 reject_handshake
check reject_handshake 3.4.4 reject_handshake
check reject_handshake v3.5.8-custom reject_handshake
check reject_handshake 3.4.3 mask
check reject_handshake 3.3.40 mask
check reject_handshake unknown reject_handshake
check reject_handshake "" reject_handshake
check "" 3.5.14 reject_handshake
check drop 3.3.0 drop
check mask 3.5.14 mask
check accept 3.4.3 accept

echo "sni action: ok"
