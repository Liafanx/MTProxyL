#!/bin/bash
# WARP: протокол awg31 (AmneziaWG 3.1) — разбор настройки, проверка бинарника,
# передача -p awg31 в службу warpscout.
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
INSTALL_DIR="$t"
mkdir -p "$INSTALL_DIR/warp"
source "$repo/lib/utils.sh"
source "$repo/lib/warp.sh"
fail() { echo "FAIL: $*"; exit 1; }
log_info() { :; }; log_success() { :; }; log_warn() { :; }; log_error() { :; }; check_root() { :; }
save_settings() { :; }; _warp_scan_reexclude() { :; }

WARP_MODE=upstream
WARP_PROTO=awg

# Разбор настройки: awg31 допустим, мусор превращается в awg.
WARP_PROTO=awg31; [ "$(_warp_configured_proto)" = awg31 ] || fail "_warp_configured_proto"
WARP_PROTO=awgs; [ "$(_warp_configured_proto)" = awg ] || fail "мусорный протокол принят"

# Старый бинарник (без awg31) не проходит и выбор отклоняется.
cat > "$(_warp_bin)" <<'BIN'
#!/bin/bash
if [[ "${2:-}" == -h ]]; then echo '-tunnel-mtu N'; echo '-best ADDR -conf FILE -endpoint IP -country CC -node XXX -plain -tun-ping N -port N -table-off -no-dns'; echo '-p, -proto wg|awg|masque|masque-h2'; exit 0; fi
exit 0
BIN
chmod 700 "$(_warp_bin)"
_warp_bin_supports_awg31 && fail "старый бинарник признан с awg31"
WARP_PROTO=awg31; _warp_bin_usable && fail "старый бинарник прошёл _warp_bin_usable"
warp_set_proto awg31 >/dev/null 2>&1 && fail "awg31 выбран на старом warpscout"

# Новый бинарник (0.17.0) — выбор проходит, состояние и runner несут awg31.
cat > "$(_warp_bin)" <<'BIN'
#!/bin/bash
if [[ "${2:-}" == -h ]]; then echo '-tunnel-mtu N'; echo '-best ADDR -conf FILE -endpoint IP -country CC -node XXX -plain -tun-ping N -port N -table-off -no-dns'; echo '-p, -proto wg|awg|awg31|masque|masque-h2'; exit 0; fi
printf '%s\n' "$@"
BIN
chmod 700 "$(_warp_bin)"
_warp_bin_supports_awg31 || fail "новый бинарник без awg31"
WARP_PROTO=awg31; _warp_bin_usable || fail "новый бинарник не прошёл _warp_bin_usable"
warp_set_proto awg31 >/dev/null || fail "awg31 не сохранён"
[ "$WARP_PROTO" = awg31 ] || fail "протокол не применился: $WARP_PROTO"
warp_set_proto nope >/dev/null 2>&1 && fail "неверный протокол принят"

_warp_write_state '188.114.98.58:2408'
[ "$(jq -r .proto "$(_warp_state)")" = awg31 ] || fail "состояние без awg31"
_warp_write_socks_runner
bash "$(_warp_runner)" > "$t/args" 2>/dev/null || true
grep -qx 'awg31' "$t/args" || fail "runner не передал -p awg31: $(cat "$t/args")"
grep -q -- '-tunnel-mtu' "$t/args" || fail "runner потерял MTU"

echo "OK warp_proto"
