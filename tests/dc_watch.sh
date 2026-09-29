#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-dc-watch.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir"
VERSION=test
BLUE="" GREEN="" YELLOW="" RED="" NC="" BOLD="" DIM="" CYAN=""
SYM_CHECK="+" SYM_WARN="!" SYM_CROSS="x"

# shellcheck source=/dev/null
source "$repo/lib/utils.sh"
source "$repo/lib/dc.sh"

_mktemp() { mktemp "$1/.tmp.XXXXXX"; }
load_secrets() { :; }
load_upstreams() { :; }
running=1; uptime=3600; now=1000000; alive=10; api=0
restarts="$test_dir/restarts"; : > "$restarts"
is_proxy_running() { [ "$running" -eq 1 ]; }
get_proxy_uptime() { echo "$uptime"; }
date() { if [ "${1:-}" = "+%s" ]; then echo "$now"; else command date "$@"; fi; }
restart_target() { echo restart >> "$restarts"; }
_engine_api_get() {
    [ "$api" -eq 0 ] || return 3
    printf '{"ok":true,"data":{"middle_proxy_enabled":true,"dcs":[{"dc":1,"rtt_ms":12.5,"alive_writers":%d,"required_writers":10,"available_pct":100.0}]}}' "$alive"
}
tick() { now=$((now + 60)); dc_watch >/dev/null 2>&1; }
count() { wc -l < "$restarts" | tr -d ' '; }
state() { _dc_watch_load; echo "$DCW_RESULT"; }

# Выключено — ничего не делает.
DC_RESTART_ENABLED=false; alive=0
tick; [ "$(count)" = 0 ]; [ ! -f "$DC_WATCH_STATE" ]

DC_RESTART_ENABLED=true; DC_RESTART_THRESHOLD=50; DC_RESTART_COOLDOWN=5

# Покрытие в норме.
alive=10; tick; [ "$(state)" = ok ]

# Ниже порога: первый замер — только отметка, второй — перезапуск.
alive=3; tick; [ "$(state)" = low ]; [ "$(count)" = 0 ]
tick; [ "$(state)" = restarted ]; [ "$(count)" = 1 ]
first=$now

# Движок только что поднялся — охлаждение, даже если DC ещё нет.
uptime=60; tick; [ "$(state)" = warmup ]; [ "$(count)" = 1 ]
tick; tick; tick; [ "$(count)" = 1 ]

# Всё охлаждение DC лежали — по его окончании перезапуск сразу.
uptime=3600; now=$((first + 300 - 60))
tick; [ "$(state)" = restarted ]; [ "$(count)" = 2 ]
second=$now

# Второй перезапуск подряд без толку — пауза уже 10 минут.
_dc_watch_load; [ "$DCW_STREAK" = 2 ]; [ "$(_dc_restart_pause)" = 10 ]
now=$((second + 300)); dc_watch >/dev/null 2>&1; [ "$(state)" = cooldown ]; [ "$(count)" = 2 ]
now=$((second + 600)); dc_watch >/dev/null 2>&1; [ "$(count)" = 3 ]

# Пауза растёт не дальше часа, а при охлаждении больше часа — берётся оно.
DCW_STREAK=10; [ "$(_dc_restart_pause)" = 60 ]
DC_RESTART_COOLDOWN=90; [ "$(_dc_restart_pause)" = 90 ]
DC_RESTART_COOLDOWN=5

# DC поднялись — серия сброшена.
alive=10; tick; [ "$(state)" = ok ]; _dc_watch_load; [ "$DCW_STREAK" = 0 ]

# Остановленный прокси не трогаем, без данных не судим.
alive=0; running=0; tick; tick; [ "$(state)" = stopped ]; [ "$(count)" = 3 ]
running=1; api=1; tick; tick; [ "$(state)" = no_data ]; [ "$(count)" = 3 ]

# Порог и охлаждение — в JSON для панели и бота.
json=$(dc_restart_json)
python3 - "$json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["enabled"] is True and d["threshold"] == 50 and d["cooldown_min"] == 5, d
assert d["restarts"] == 3 and d["last_restart_coverage"] == 30, d
PY

# Команды проверяют значения.
check_root() { :; }
save_settings() { :; }
dc_install_watch() { :; }
fails() { if "$@" >/dev/null 2>&1; then echo "Должно было не пройти: $*" >&2; exit 1; fi; }
fails dc_restart_set threshold 0
fails dc_restart_set threshold 101
fails dc_restart_set cooldown 0
fails dc_restart_set bogus
dc_restart_set threshold 70 >/dev/null; [ "$DC_RESTART_THRESHOLD" = 70 ]
dc_restart_set cooldown 15 >/dev/null; [ "$DC_RESTART_COOLDOWN" = 15 ]
dc_restart_set off >/dev/null; [ "$DC_RESTART_ENABLED" = false ]

echo "dc_watch: ok"
