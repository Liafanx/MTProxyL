#!/bin/bash
# Экземпляры nfqws2: число по ядрам или вручную, ряд очередей, конфиг на
# каждый экземпляр и запуск всех из одной службы.
set -u
cd "$(dirname "$0")/.." || exit 1
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
INSTALL_DIR="$d"
source lib/colors.sh 2>/dev/null; source lib/utils.sh 2>/dev/null; source lib/nft.sh 2>/dev/null
ZAPRET2_ETC_DIR="$d/etc"; ZAPRET2_CONF="$d/etc/mtproto.conf"
zapret2_filter_ports() { echo 443; }
log_success() { :; }
fail=0
ok() { if eval "$2"; then echo "OK $1"; else echo "FAIL $1"; fail=1; fi; }

nproc() { echo 4; }
ZAPRET2_INSTANCES=auto; ZAPRET2_QNUM=200
ok "auto по ядрам" '[ "$(zapret2_instance_count)" = 4 ] && [ "$(zapret2_queue_spec)" = 200-203 ]'
nproc() { echo 32; }
ok "auto не больше 8" '[ "$(zapret2_instance_count)" = 8 ]'
nproc() { echo 1; }
ok "одно ядро — прежняя очередь" '[ "$(zapret2_queue_spec)" = 200 ]'
ok "один экземпляр — exec, как раньше" '[ "$(zapret2_start_exec_lines)" = "exec ${ZAPRET2_BIN} @${ZAPRET2_CONF}" ]'

ZAPRET2_INSTANCES=3
zapret2_write_conf
ok "конфиг на каждый экземпляр" '[ -f "$d/etc/mtproto.conf" ] && [ -f "$d/etc/mtproto-1.conf" ] && [ -f "$d/etc/mtproto-2.conf" ]'
ok "свой номер очереди" 'grep -qx -- "--qnum 202" "$d/etc/mtproto-2.conf" && grep -qx -- "--qnum 200" "$d/etc/mtproto.conf"'
ok "запуск всех в фоне" '[ "$(zapret2_start_exec_lines | grep -c "&$")" = 3 ] && zapret2_start_exec_lines | grep -qx "wait -n"'
ZAPRET2_INSTANCES=2
zapret2_write_conf
ok "лишние конфиги убраны" '[ ! -e "$d/etc/mtproto-2.conf" ] && [ -f "$d/etc/mtproto-1.conf" ]'

zapret2_queue_in_use() { [ "$1" = 251 ]; }
ok "ряд очередей обходит занятую" '[ "$(zapret2_find_free_range 2)" = 252 ]'
ok "занятость ряда" 'zapret2_range_in_use 250 2 && ! zapret2_range_in_use 252 2'
ZAPRET2_QUEUE_LIMIT=64
ok "потолок пакетов в очереди" '[ "$(zapret2_limit_match)" = "tcp flags & (fin | syn | rst) == 0 ct packets > 64" ]'
ZAPRET2_QUEUE_LIMIT=0
ok "потолок выключается нулём" '[ -z "$(zapret2_limit_match)" ]'
exit "$fail"
