#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir"
EXPERT_OVERRIDES_FILE="$test_dir/expert.conf"

# shellcheck source=../lib/utils.sh
source "$repo/lib/utils.sh"
# shellcheck source=../lib/expert_catalog.sh
source "$repo/lib/expert_catalog.sh"
# shellcheck source=../lib/expert_mode.sh
source "$repo/lib/expert_mode.sh"

printf '%s\n' 'general|log_level|debug' > "$EXPERT_OVERRIDES_FILE"
expert_catalog_json > "$test_dir/catalog.json"

jq -e 'length > 200' "$test_dir/catalog.json" >/dev/null
jq -e '.[] | select(.section == "general" and .key == "config_strict") | .hot_reload == false' \
    "$test_dir/catalog.json" >/dev/null
jq -e '.[] | select(.section == "general" and .key == "log_level") |
    .hot_reload == true and .has_override == true and .override == "debug"' \
    "$test_dir/catalog.json" >/dev/null

echo "expert_catalog: ok"
