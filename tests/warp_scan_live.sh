#!/bin/bash
# Read-only WARP scan integration check; does not alter services or routes.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
scan_dir=$(mktemp -d /tmp/mtproxyl-warp-scan.XXXXXX)
trap 'rm -rf -- "$scan_dir"' EXIT
INSTALL_DIR="$scan_dir"
source "$repo/lib/utils.sh"
source "$repo/lib/warp.sh"
_warp_account() { printf '%s\n' "${WARP_ACCOUNT:-/opt/mtproxyl/warp/account.json}"; }
_warp_bin() { printf '%s\n' "${WARPSCOUT_BIN:-/opt/mtproxyl/warp/warpscout}"; }
WARP_MODE=upstream
WARP_PROTO="${WARP_LIVE_PROTO:-awg}"
WARP_LOCATION="${WARP_LIVE_LOCATION:-}"
warp_scan_collect quick
jq -c '{status,depth,proto,count:(.nodes|length),best_endpoint,first:(.nodes[0]|{node,region,location})}' "$(_warp_scan_file)"
