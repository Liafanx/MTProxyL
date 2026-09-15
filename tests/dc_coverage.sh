#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/dc.sh"
got=$(_dc_summary $'1|0|20|10|100|100\n2|0|0|10|0|0')
[[ "$got" == '2|50|20|20|10' ]] || { echo "Surplus masked failed DC: $got"; exit 1; }
got=$(_dc_summary $'1|0|20|10|100|100\n2|0|10|10|100|100')
[[ "$got" == '2|100|30|20|20' ]] || exit 1
[[ $(_dc_summary '') == '0|0|0|0|0' ]] || exit 1

_engine_api_get() {
    printf '%s' '{"data":{"middle_proxy_enabled":true,"dcs":[{"dc":1,"rtt_ms":10,"alive_writers":20,"required_writers":10,"coverage_pct":200,"available_pct":100},{"dc":2,"rtt_ms":20,"alive_writers":0,"required_writers":10,"coverage_pct":0,"available_pct":0}]}}'
}
json_escape() { printf '%s' "$1"; }
DC_THRESHOLD=80
report=$(dc_status_json)
jq -e '.coverage_pct == 50 and .covered_writers == 10 and .alive_writers == 20 and .zero_writer_dcs == 1 and .verdict == "down"' <<< "$report" >/dev/null
echo 'DC coverage: OK'
