#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/mtproxyl-args-dc.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
source lib/install_args.sh
source lib/argsgen.sh
log_error() { :; }
fails() { if "$@" >/dev/null 2>&1; then echo "Должно было не пройти: $*" >&2; exit 1; fi; }

(
    _install_args_parse --dc-restart 40 --dc-restart-cooldown 10
    _ia_dc_restart_validate
    [ "$_IA_DC_RESTART" = 40 ] && [ "$_IA_DC_RESTART_COOLDOWN" = 10 ]
)
for bad in 0 101 x; do
    ( _install_args_parse --dc-restart "$bad"; fails _ia_dc_restart_validate )
done
( _install_args_parse --dc-restart ON; _ia_dc_restart_validate; [ "$_IA_DC_RESTART" = on ] )
( _install_args_parse --dc-restart-cooldown 0; fails _ia_dc_restart_validate )

# Генератор команды и переезд: включённый перезапуск доезжает теми же ключами.
declare -A _AG_ON=() _AG_VAL=()
for key in force engine proxy_mode port ports host sni secrets adtag mask fixes meko selfmask web geoip block shaping; do
    _AG_ON[$key]=no
done
DC_RESTART_ENABLED=true DC_RESTART_THRESHOLD=35 DC_RESTART_COOLDOWN=7
_AG_ON[dcrestart]=yes
generated=$(_argsgen_build)
(
    eval "set -- $generated"
    _install_args_parse "$@"
    [ "$_IA_DC_RESTART" = 35 ] && [ "$_IA_DC_RESTART_COOLDOWN" = 7 ]
)
_AG_ON[dcrestart]=no
case "$(_argsgen_build)" in *dc-restart*) echo "выключенный перезапуск попал в команду" >&2; exit 1 ;; esac
echo 'install args dc restart: ok'
