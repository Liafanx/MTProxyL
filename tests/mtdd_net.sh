#!/bin/bash
# Сеть проверяется на подставных proc/sysfs; реальные параметры VPS не меняются.
set -o pipefail
cd "$(dirname "$0")/.." || exit 1
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
INSTALL_DIR="$t/install"; mkdir -p "$INSTALL_DIR"
MTDD_NET_UNIT="$t/etc/systemd/system/mtproxyl-mtdd-net.service"
MTDD_NET_CONF="$t/etc/sysctl.d/99-mtproxyl-mtdd-net.conf"
MTDD_NET_STATE="$t/state"; MTDD_NET_PROC_ROOT="$t/proc"; MTDD_NET_SYS_ROOT="$t/sys"
MTDD_NET_IFACES=eth0,eth1
for f in lib/*.sh; do source "$f" >/dev/null 2>&1; done
fail() { echo "FAIL: $*" >&2; exit 1; }
log_info() { :; }; log_success() { :; }; log_warn() { :; }
check_root() { :; }; ip() { :; }
systemctl() {
    printf '%s\n' "$*" >> "$t/systemctl.log"
    case "$1" in
        is-enabled) [ -f "$t/enabled" ] ;;
        enable) touch "$t/enabled" ;;
        restart) _mtdd_net_worker start ;;
        disable) rm -f "$t/enabled"; _mtdd_net_worker stop ;;
        daemon-reload) return 0 ;;
        *) return 1 ;;
    esac
}
fixture() {
    rm -rf "$MTDD_NET_STATE" "$t/proc" "$t/sys" "$t/etc" "$t/enabled"
    python3 - "$t" <<'PY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1]);(p/'proc').mkdir()
(p/'proc/meminfo').write_text('MemTotal: 2097152 kB\n')
base={'net.core.somaxconn':'4096','net.ipv4.tcp_max_syn_backlog':'4096',
 'net.core.netdev_max_backlog':'1000','net.ipv4.tcp_max_orphans':'16384',
 'net.ipv4.tcp_orphan_retries':'0','net.ipv4.tcp_fin_timeout':'60',
 'net.ipv4.tcp_tw_reuse':'0','net.ipv4.tcp_mem':'100 200 300'}
for key,value in base.items():
 f=p/'proc/sys'/key.replace('.','/');f.parent.mkdir(parents=True,exist_ok=True);f.write_text(value+'\n')
for dev,napi,gro in [('eth0',0,0),('eth1',7,500),('lo',0,0)]:
 d=p/'sys/class/net'/dev;d.mkdir(parents=True)
 (d/'napi_defer_hard_irqs').write_text(str(napi)+'\n');(d/'gro_flush_timeout').write_text(str(gro)+'\n')
(p/'baseline.json').write_text(json.dumps(base))
PY
    MTPROXYL_MODE=manager; ENGINE_KIND=mtdd; MTPROXYL_NONINTERACTIVE=false
    unset MTPROXYL_ASSUME_YES _MTDD_NET_ASKED
}
assert_baseline() {
    python3 - "$t" <<'PY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1])
for k,v in json.loads((p/'baseline.json').read_text()).items():assert (p/'proc/sys'/k.replace('.','/')).read_text().strip()==v,k
assert (p/'sys/class/net/eth0/napi_defer_hard_irqs').read_text().strip()=='0'
assert (p/'sys/class/net/eth0/gro_flush_timeout').read_text().strip()=='0'
PY
}

fixture
read_line() { printf -v "$1" '%s' ''; }
mtdd_net_install_wizard > "$t/wizard.log" || fail 'мастер по умолчанию'
grep -q '\[y/N\]' "$t/wizard.log" || fail 'нет явного значения по умолчанию'
[ ! -f "$MTDD_NET_UNIT" ] && assert_baseline || fail 'Enter включил оптимизацию'
unset _MTDD_NET_ASKED; MTPROXYL_ASSUME_YES=1
mtdd_net_install_wizard || fail 'assume yes'
[ ! -f "$MTDD_NET_UNIT" ] && assert_baseline || fail 'общий yes включил оптимизацию'
unset MTPROXYL_ASSUME_YES; MTPROXYL_NONINTERACTIVE=true
mtdd_net_install_wizard || fail 'неинтерактивный запуск'
[ ! -f "$MTDD_NET_UNIT" ] || fail 'CLI без флага включил оптимизацию'
mtdd_net_install_wizard yes || fail 'явный yes'
mtdd_net_is_enabled || fail 'нет автозапуска'
python3 - "$t" <<'PY' || fail 'значения профиля'
from pathlib import Path
import json,sys
p=Path(sys.argv[1]);s=json.loads((p/'state/state.json').read_text())
assert len(s['sysctl'])==8 and len(s['interfaces'])==2
for key,expected in [('net.core.somaxconn',[16384]),('net.ipv4.tcp_mem',[32768,65536,131072]),('net.ipv4.tcp_max_orphans',[262144]),('net.ipv4.tcp_fin_timeout',[15])]:assert s['sysctl'][key]['new']==expected
assert s['sysctl']['net.ipv4.tcp_orphan_retries']['old']==[0]
assert (p/'sys/class/net/eth0/gro_flush_timeout').read_text().strip()=='1000000'
assert (p/'sys/class/net/eth1/napi_defer_hard_irqs').read_text().strip()=='7'
assert (p/'sys/class/net/lo/napi_defer_hard_irqs').read_text().strip()=='0'
assert (p/'state/state.json').stat().st_mode & 0o777 == 0o600
assert (p/'state').stat().st_mode & 0o777 == 0o700
PY
_mtdd_net_worker start || fail 'повторное применение'
mtdd_net_install_wizard no || fail 'явный no'
assert_baseline || fail 'исходные значения не восстановлены'
[ ! -e "$MTDD_NET_CONF" ] && [ ! -e "$MTDD_NET_UNIT" ] && [ ! -e "$MTDD_NET_STATE" ] || fail 'остатки после отключения'
mtdd_net_disable || fail 'повторное отключение'

fixture
_mtdd_net_worker start || fail 'профиль перед перезагрузкой'
python3 - "$t" <<'PY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1])
for key,value in json.loads((p/'baseline.json').read_text()).items():
    (p/'proc/sys'/key.replace('.','/')).write_text(value+'\n')
for knob in ('napi_defer_hard_irqs','gro_flush_timeout'):
    (p/'sys/class/net/eth0'/knob).write_text('0\n')
PY
_mtdd_net_worker start && _mtdd_net_worker stop && assert_baseline || fail 'применение после перезагрузки и откат'
fixture
rm "$t/proc/sys/net/ipv4/tcp_mem" "$t/sys/class/net/eth0/gro_flush_timeout"
_mtdd_net_worker start && _mtdd_net_worker stop || fail 'ядро без отдельных параметров'
fixture
mkdir -p "$MTDD_NET_STATE"; echo broken > "$MTDD_NET_STATE/state.json"
_mtdd_net_worker start > "$t/error.log" 2>&1 && fail 'повреждённый журнал принят'
grep -q 'не удалось прочитать' "$t/error.log" && assert_baseline || fail 'ошибка журнала не обработана'

fixture
printf '65536\n' > "$t/proc/sys/net/core/somaxconn"
printf '1\n' > "$t/proc/sys/net/ipv4/tcp_tw_reuse"
printf '5\n' > "$t/proc/sys/net/ipv4/tcp_fin_timeout"
_mtdd_net_worker start || fail 'собственные настройки оператора'
[ "$(cat "$t/proc/sys/net/core/somaxconn")" = 65536 ] || fail 'очередь уменьшена'
[ "$(cat "$t/proc/sys/net/ipv4/tcp_tw_reuse")" = 1 ] || fail 'reuse изменён'
[ "$(cat "$t/proc/sys/net/ipv4/tcp_fin_timeout")" = 5 ] || fail 'fin увеличен'
printf '77777\n' > "$t/proc/sys/net/ipv4/tcp_max_syn_backlog"
printf '9\n' > "$t/sys/class/net/eth0/napi_defer_hard_irqs"
_mtdd_net_worker stop || fail 'откат с ручными правками'
[ "$(cat "$t/proc/sys/net/ipv4/tcp_max_syn_backlog")" = 77777 ] || fail 'ручная правка sysctl потеряна'
[ "$(cat "$t/sys/class/net/eth0/napi_defer_hard_irqs")" = 9 ] || fail 'ручная правка NAPI потеряна'

fixture
rm "$t/proc/sys/net/ipv4/tcp_mem"; mkdir "$t/proc/sys/net/ipv4/tcp_mem"
_mtdd_net_worker start > "$t/error.log" 2>&1 && fail 'ошибка применения скрыта'
[ "$(cat "$t/proc/sys/net/core/somaxconn")" = 4096 ] || fail 'частичное применение не откатилось'
fixture
_mtdd_net_worker start || fail 'подготовка сбоя отката'
rm "$t/proc/sys/net/core/somaxconn"; mkdir "$t/proc/sys/net/core/somaxconn"
_mtdd_net_worker stop > "$t/error.log" 2>&1 && fail 'ошибка отката скрыта'
[ -f "$MTDD_NET_STATE/state.json" ] && [ -f "$MTDD_NET_CONF" ] || fail 'журнал/конфиг потерян при сбое'
rmdir "$t/proc/sys/net/core/somaxconn"; printf '16384\n' > "$t/proc/sys/net/core/somaxconn"
_mtdd_net_worker stop || fail 'повторный откат'
assert_baseline || fail 'повторный откат не завершён'

fixture
mkdir -p "${MTDD_NET_CONF%/*}"; echo 'operator' > "$MTDD_NET_CONF"
_mtdd_net_worker start > "$t/error.log" 2>&1 && fail 'чужой конфиг перезаписан'
[ "$(cat "$MTDD_NET_CONF")" = operator ] && assert_baseline || fail 'чужие настройки изменены'
fixture
ENGINE_KIND=telemt
mtdd_net_enable > "$t/error.log" 2>&1 && fail 'включение для telemt разрешено'
[ ! -f "$MTDD_NET_UNIT" ] && assert_baseline || fail 'telemt изменил сеть'
for mode in manager reanimator; do
    source lib/install_args.sh
    if [ "$mode" = manager ]; then target=(--engine mtdd); else target=(--target mtdd); fi
    _install_args_parse --mode "$mode" "${target[@]}" --mtdd-net-opt yes || fail "аргументы $mode"
    _install_args_validate_mtdd_options || fail "проверка $mode"
    [ "$_IA_MTDD_NET_OPT" = yes ] || fail 'флаг потерян'
done
source lib/install_args.sh
_install_args_parse --engine binary --mtdd-net-opt yes
_install_args_validate_mtdd_options > "$t/error.log" 2>&1 && fail 'флаг mtdd принят для telemt'

cat > "$t/installer.sh" <<'SH'
#!/bin/bash
tune_kernel() { echo BAD; }
tune_network() { echo BAD; }
run_install() {
    tune_kernel
    tune_network
    echo installed
}
run_install
SH
_mtdd_installer_skip_network "$t/installer.sh" || fail 'адаптация оригинального установщика'
[ "$(bash "$t/installer.sh")" = installed ] || fail 'оригинальный установщик применил тюнинг'
sed -i 's/: # Network tuning is managed by MTProxyL/tune_kernel/' "$t/installer.sh"
_mtdd_installer_skip_network "$t/installer.sh" > "$t/error.log" 2>&1 && fail 'изменившийся установщик пропущен'

fixture
mtdd_net_enable >/dev/null || fail 'профиль перед удалением цели'
MTPROXYL_MODE=reanimator
MTDD_ENGINE_DIR="$t/target-engine"; MTDD_CHANNEL_FILE="$t/target-channel"
mtdd_unit_exists() { return 0; }
read_line() { printf -v "$1" '%s' y; }
draw_header() { :; }; save_detect_settings() { :; }; run_target_detection() { return 1; }
_mtdd_fetch_installer() { echo "$t/installer.sh"; }
_mtdd_run_installer() { assert_baseline && [ ! -e "$MTDD_NET_UNIT" ]; }
uninstall_original_mtdd > "$t/uninstall.log" 2>&1 || fail 'профиль не снят до удаления цели'
[ ! -e "$MTDD_NET_STATE" ] || fail 'журнал остался после удаления цели'
echo 'OK mtdd_net'
