#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/mtproxyl-args-shaping.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
source lib/shaping.sh
source lib/install_args.sh
log_error() { echo "$*" >&2; }

(
    _install_args_parse --shaping manual --shaping-total 900 --shaping-ip 9 \
        --secret team.alpha:012345 --shaping-exempt-profile team.alpha \
        --shaping-exempt-ip 203.0.113.0/24
    _ia_shaping_validate
    cfg=$(_install_args_shaping_config)
    shaping_validate_config "$cfg"
    [ "$(printf '%s\n' "$cfg" | jq -r '.manual_ip_mbps')" = 9 ]
    [ "$(printf '%s\n' "$cfg" | jq -r '.profile_exempt[0]')" = team.alpha ]
)
(
    _install_args_parse --shaping dynamic --shaping-channel 1000 \
        --shaping-users 100 --shaping-reserve 10
    _ia_shaping_validate
    [ "$(shaping_rates "$(_install_args_shaping_config)" 100 | jq -r '.ip_bps')" = 9000000 ]
)
(
    _install_args_parse --shaping manual --shaping-total 900 --shaping-ip 0
    if _ia_shaping_validate >/dev/null 2>&1; then echo 'zero IP limit accepted' >&2; exit 1; fi
)
(
    _install_args_parse --shaping fixed --shaping-channel 1000 --shaping-users 1
    if _ia_shaping_validate >/dev/null 2>&1; then echo 'unsafe divisor accepted' >&2; exit 1; fi
)
(
    _install_args_parse --shaping manual --shaping-total 900 --shaping-ip 9 \
        --shaping-exempt-profile unknown
    if _ia_shaping_validate >/dev/null 2>&1; then echo 'unknown profile accepted' >&2; exit 1; fi
)
(
    _install_args_parse --shaping off
    _ia_shaping_validate
    touch "$SHAPING_TC_FILE"
    shaping_apply() { jq -e '.enabled == false' > "$test_dir/off-applied"; }
    _install_args_shaping
    [ -f "$test_dir/off-applied" ]
)

# Экспорт аргументами сохраняет лимит и исключения без ручного ввода.
source lib/argsgen.sh
declare -A _AG_ON=() _AG_VAL=()
for key in force engine proxy_mode port ports host sni secrets adtag mask fixes meko selfmask web geoip block shaping; do
    _AG_ON[$key]=no
done
_AG_ON[secrets]=yes
_AG_ON[shaping]=yes
SECRETS_LABELS=(team.alpha)
SECRETS_KEYS=(012345)
shaping_atomic_json "$SHAPING_FILE" "$(shaping_default_config | jq '.enabled=true | .manual_total_mbps=900 | .manual_ip_mbps=9 | .profile_exempt=["team.alpha"] | .ip_exempt=["203.0.113.0/24"]')"
generated=$(_argsgen_build)
(
    eval "set -- $generated"
    _install_args_parse "$@"
    _ia_shaping_validate
    [ "$_IA_SHAPING_MODE" = manual ] && [ "$_IA_SHAPING_IP" = 9 ]
    [ "${_IA_SHAPING_PROFILES[0]}" = team.alpha ]
    [ "${_IA_SHAPING_IPS[0]}" = 203.0.113.0/24 ]
)
echo 'install args shaping tests: ok'
