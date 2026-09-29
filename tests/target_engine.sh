#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-target-engine.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir/opt"
VERSION=test
BLUE="" GREEN="" YELLOW="" RED="" NC="" BOLD="" DIM="" CYAN=""
SYM_CHECK="+" SYM_WARN="!" SYM_CROSS="x"
mkdir -p "$INSTALL_DIR" "$test_dir/bin" "$test_dir/src"

# shellcheck source=/dev/null
source "$repo/lib/utils.sh"
source "$repo/lib/binengine.sh"
source "$repo/lib/engine.sh"

command -v gcc >/dev/null || { echo "Нет gcc — тест пропущен"; exit 0; }
fails() { if "$@" >/dev/null 2>&1; then echo "Должно было не пройти: $*" >&2; exit 1; fi; }

# Поддельные сборки telemt: 9.9.9 «не поднимается с конфигом цели».
for v in 3.5.7 3.5.9 9.9.9; do
    printf '#include <stdio.h>\nint main(void){puts("telemt %s");return 0;}\n' "$v" > "$test_dir/src/$v.c"
    gcc -o "$test_dir/src/$v" "$test_dir/src/$v.c"
done
bin="$test_dir/bin/telemt"
cp "$test_dir/src/3.5.7" "$bin"

MTPROXYL_MODE=reanimator
DETECTED_MODE=local
DETECTED_CONFIG_PATH=/etc/telemt/telemt.toml
setcap_log="$test_dir/setcap.log"

check_root() { :; }
sleep() { :; }
journalctl() { :; }
_telemt_unit_exists() { return 0; }
_telemt_host_pids() { return 1; }
_telemt_api_enabled() { return 1; }
binengine_asset_name() { echo telemt-test.tar.gz; }
binengine_latest_version() { echo 3.5.9; }
_binengine_fetch_into() { cp "$test_dir/src/${2#v}" "$1/telemt"; }
getcap() { echo "$1 cap_net_admin,cap_net_bind_service=ep"; }
setcap() { echo "$1 $2" >> "$setcap_log"; }
systemctl() {
    case "$*" in
        "show telemt.service -p ExecStart --value")
            echo "{ path=$bin ; argv[]=$bin /etc/telemt/telemt.toml ; ignore_errors=no }" ;;
        "show telemt.service -p MainPID --value") echo 4242 ;;
        "is-active --quiet telemt.service")
            [ "$("$bin" --version)" != "telemt 9.9.9" ] ;;
        *) return 0 ;;
    esac
}
ver() { "$bin" --version | awk '{print $NF}'; }

[ -z "$(target_engine_unsupported_reason)" ]
[ "$(target_engine_version)" = "3.5.7" ]

# Обновление: бинарник заменён, прежний — для отката, capabilities перенесены.
target_engine_update 3.5.9 >/dev/null 2>&1
[ "$(ver)" = "3.5.9" ]
[ "$(cat "$TARGET_ENGINE_PREV_VERSION")" = "3.5.7" ]
[ "$("$TARGET_ENGINE_PREV" --version)" = "telemt 3.5.7" ]
grep -q "cap_net_admin,cap_net_bind_service=ep ${bin}.mtproxyl-new" "$setcap_log"
[ ! -e "${bin}.mtproxyl-new" ]

# Та же версия — ничего не меняется.
target_engine_update 3.5.9 >/dev/null 2>&1
[ "$(cat "$TARGET_ENGINE_PREV_VERSION")" = "3.5.7" ]

# Версия, которая не поднялась, откатывается сама; запас для отката прежний.
fails target_engine_update 9.9.9
[ "$(ver)" = "3.5.9" ]
[ "$(cat "$TARGET_ENGINE_PREV_VERSION")" = "3.5.7" ]
[ ! -e "$TARGET_ENGINE_DIR/telemt.cur" ]

# Откат на предыдущую и обратно тегом, который лежит на диске.
target_engine_rollback --yes >/dev/null 2>&1
[ "$(ver)" = "3.5.7" ]
[ "$(cat "$TARGET_ENGINE_PREV_VERSION")" = "3.5.9" ]
target_engine_rollback 3.5.9 >/dev/null 2>&1
[ "$(ver)" = "3.5.9" ]

# Для панели: поддержка, версия, что лежит на диске.
engine_list_releases() { echo "3.5.9|3.5.9|2026-09-28"; }
json=$(engine_versions_json)
python3 - "$json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["target"] and d["supported"] and d["binary"], d
assert d["current"] == "3.5.9" and d["local"] == ["3.5.9", "3.5.7"], d
assert d["releases"][0]["tag"] == "3.5.9", d
PY

# Цель в Docker версию не меняет.
DETECTED_MODE=docker
[ -n "$(target_engine_unsupported_reason)" ]
fails target_engine_update 3.5.7
[ "$(ver)" = "3.5.9" ]
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert not d["supported"] and d["releases"] == [], d' "$(engine_versions_json)"

echo "target_engine: ok"
