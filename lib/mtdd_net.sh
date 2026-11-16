#!/bin/bash
# Опциональный тюнинг mtdd: sysctl и NAPI, с журналом исходных значений.
MTDD_NET_UNIT="${MTDD_NET_UNIT:-/etc/systemd/system/mtproxyl-mtdd-net.service}"
MTDD_NET_CONF="${MTDD_NET_CONF:-/etc/sysctl.d/99-mtproxyl-mtdd-net.conf}"
MTDD_NET_STATE="${MTDD_NET_STATE:-${INSTALL_DIR}/mtdd-net-opt}"

mtdd_net_is_enabled() {
    [ -f "$MTDD_NET_UNIT" ] && systemctl is-enabled --quiet mtproxyl-mtdd-net.service 2>/dev/null
}

_mtdd_net_worker() {
    python3 -I - "$1" "$MTDD_NET_STATE" "${MTDD_NET_PROC_ROOT:-/proc}" \
        "${MTDD_NET_SYS_ROOT:-/sys}" "$MTDD_NET_CONF" "${MTDD_NET_IFACES:-}" <<'PY'
import fcntl, hashlib, json, os, re, subprocess, sys, tempfile
from pathlib import Path

action, directory, proc, sysfs, config, forced_ifaces = sys.argv[1:]
directory, proc, sysfs, config = map(Path, (directory, proc, sysfs, config))
if action == 'stop' and not directory.exists():
    sys.exit(0)
directory.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(directory, 0o700)
lock = (directory / 'lock').open('a')
fcntl.flock(lock, fcntl.LOCK_EX)
path = directory / 'state.json'
try:
    state = json.loads(path.read_text()) if path.exists() else {'sysctl': {}, 'interfaces': {}}
    if not isinstance(state, dict) or any(not isinstance(state.get(k), dict) for k in ('sysctl', 'interfaces')):
        raise ValueError('неверный формат журнала')
except (OSError, ValueError) as error:
    sys.exit(f'Сетевая оптимизация mtdd: не удалось прочитать {path}: {error}')

def atomic(target, data, mode):
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=target.parent, prefix='.mtdd-net-')
    try:
        with os.fdopen(fd, 'w') as out:
            os.fchmod(out.fileno(), mode)
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, target)
    finally:
        if os.path.exists(name): os.unlink(name)

def save():
    atomic(path, json.dumps(state, indent=2) + '\n', 0o600)

def read(target):
    try: return [int(x) for x in target.read_text().split()]
    except FileNotFoundError: return None

def write(target, values):
    target.write_text(' '.join(map(str, values)) + '\n')

def setting(group, key, target, desired):
    current = read(target)
    if current is None: return
    record = state[group].get(key)
    if record:
        if current == record['new']: return
        if current != record['old']:
            del state[group][key]
            save()
            return
    if current == desired: return
    state[group][key] = {'old': record['old'] if record else current, 'new': desired}
    save()
    write(target, desired)

def interface_path(key):
    dev, knob = key.split('/', 1)
    if not re.fullmatch(r'[a-zA-Z0-9_.:@-]+', dev) or knob not in ('napi_defer_hard_irqs', 'gro_flush_timeout'):
        raise ValueError('Некорректный интерфейс в журнале')
    return sysfs / 'class/net' / dev / knob

def stop():
    failed = False
    for group in ('sysctl', 'interfaces'):
        for key, record in list(state[group].items()):
            try:
                target = proc / 'sys' / key.replace('.', '/') if group == 'sysctl' else interface_path(key)
                if read(target) == record['new']: write(target, record['old'])
                del state[group][key]
                save()
            except OSError as error:
                failed = True
                print(f'Не удалось восстановить {key}: {error}', file=sys.stderr)
    if not failed and config.exists():
        if hashlib.sha256(config.read_bytes()).hexdigest() in (state.get('conf_sha256'), state.get('conf_previous_sha256')):
            config.unlink()
        else:
            print(f'{config} изменён вручную, файл сохранён', file=sys.stderr)
    if not failed:
        state.pop('conf_sha256', None)
        state.pop('conf_previous_sha256', None)
        save()
    return not failed

def start():
    if config.exists() and hashlib.sha256(config.read_bytes()).hexdigest() not in (state.get('conf_sha256'), state.get('conf_previous_sha256')):
        raise ValueError(f'{config} не принадлежит текущему журналу; файл не изменён')
    pages = 0
    for line in (proc / 'meminfo').read_text().splitlines():
        if line.startswith('MemTotal:'): pages = int(line.split()[1]) * 1024 // os.sysconf('SC_PAGE_SIZE')
    wanted = {
        'net.core.somaxconn': ('max', [16384]),
        'net.ipv4.tcp_max_syn_backlog': ('max', [16384]),
        'net.core.netdev_max_backlog': ('max', [16384]),
        'net.ipv4.tcp_max_orphans': ('max', [max(65536, min(pages // 2, 262144)) if pages else 65536]),
        'net.ipv4.tcp_orphan_retries': ('low', [3]),
        'net.ipv4.tcp_fin_timeout': ('min', [15]),
        'net.ipv4.tcp_tw_reuse': ('reuse', [2]),
    }
    if pages: wanted['net.ipv4.tcp_mem'] = ('max', [pages // 16, pages // 8, pages // 4])
    for key, (mode, values) in wanted.items():
        target = proc / 'sys' / key.replace('.', '/')
        current = read(target)
        if current is None or len(current) != len(values): continue
        if mode == 'max': desired = [max(c, v) for c, v in zip(current, values)]
        elif mode == 'min': desired = [min(current[0], values[0])]
        elif mode == 'low': desired = values if current[0] == 0 or current[0] > values[0] else current
        else: desired = values if current[0] == 0 else current
        setting('sysctl', key, target, desired)
    devices = set(forced_ifaces.split(',')) if forced_ifaces else set()
    if not forced_ifaces:
        for family in ('-4', '-6'):
            rows = json.loads(subprocess.check_output(['ip', family, '-j', 'route', 'show', 'default'], text=True))
            devices.update(row['dev'] for row in rows if row.get('dev'))
    for dev in sorted(devices):
        for knob, value in (('napi_defer_hard_irqs', 2), ('gro_flush_timeout', 1000000)):
            key = f'{dev}/{knob}'
            target = interface_path(key)
            current = read(target)
            if current == [0] or key in state['interfaces']:
                setting('interfaces', key, target, [value])
    data = '# Managed by MTProxyL mtdd network optimization\n'
    data += ''.join(f"{key} = {' '.join(map(str, record['new']))}\n" for key, record in sorted(state['sysctl'].items()))
    state['conf_previous_sha256'] = state.get('conf_sha256')
    state['conf_sha256'] = hashlib.sha256(data.encode()).hexdigest()
    save()
    atomic(config, data, 0o644)
    state.pop('conf_previous_sha256', None)
    save()

try:
    if action == 'start':
        try: start()
        except Exception:
            stop()
            raise
    elif action == 'stop':
        if not stop(): sys.exit(1)
    elif action == 'status':
        print(json.dumps({'sysctl': state['sysctl'], 'interfaces': state['interfaces']}))
    else: raise ValueError('Команда: start, stop или status')
except (OSError, ValueError, subprocess.SubprocessError) as error:
    print(f'Сетевая оптимизация mtdd: {error}', file=sys.stderr)
    sys.exit(1)
PY
}

mtdd_net_enable() {
    engine_is_mtdd || { log_error 'Сетевая оптимизация доступна только для mtdd'; return 1; }
    check_root || return 1
    command -v python3 >/dev/null && command -v ip >/dev/null && command -v systemctl >/dev/null || {
        log_error 'Нужны python3, iproute2 и systemd'; return 1; }
    mkdir -p "${MTDD_NET_UNIT%/*}" || return 1
    cat > "$MTDD_NET_UNIT" <<EOF
[Unit]
Description=MTProxyL mtdd network optimization
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_DIR}/mtproxyl.sh engine net-opt apply
ExecStop=${INSTALL_DIR}/mtproxyl.sh engine net-opt restore

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$MTDD_NET_UNIT"
    systemctl daemon-reload || return 1
    if ! systemctl enable mtproxyl-mtdd-net.service || ! systemctl restart mtproxyl-mtdd-net.service; then
        mtdd_net_disable || true
        log_error 'Оптимизация mtdd не применена; проверьте journalctl -u mtproxyl-mtdd-net.service'
        return 1
    fi
    log_success 'Сетевая оптимизация mtdd включена'
}

mtdd_net_disable() {
    check_root || return 1
    if [ -f "$MTDD_NET_UNIT" ]; then
        systemctl disable --now mtproxyl-mtdd-net.service >/dev/null 2>&1 || true
    fi
    _mtdd_net_worker stop || { log_error 'Не все значения восстановлены; журнал оставлен для повторного отключения'; return 1; }
    rm -f "$MTDD_NET_UNIT"
    rm -rf "$MTDD_NET_STATE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
}

mtdd_net_status() {
    echo -e "  ${BOLD}Сетевая оптимизация mtdd:${NC} $(mtdd_net_is_enabled && echo включена || echo выключена)"
    if [ -f "${MTDD_NET_STATE}/state.json" ]; then _mtdd_net_worker status || return 1; fi
    return 0
}

handle_mtdd_net_command() {
    case "${1:-status}" in
        on) mtdd_net_enable ;;
        off) mtdd_net_disable ;;
        status) mtdd_net_status ;;
        apply) engine_is_mtdd && _mtdd_net_worker start ;;
        restore) _mtdd_net_worker stop ;;
        *) log_error 'Использование: mtproxyl engine net-opt on|off|status'; return 1 ;;
    esac
}

mtdd_net_install_wizard() {
    if ! engine_is_mtdd; then
        if [ -f "$MTDD_NET_UNIT" ] || [ -d "$MTDD_NET_STATE" ]; then mtdd_net_disable; return; fi
        return 0
    fi
    local _answer="${1:-}"
    case "$_answer" in
        yes) mtdd_net_enable; return ;;
        no) mtdd_net_disable; return ;;
    esac
    mtdd_net_is_enabled && return 0
    if [ "${MTPROXYL_ASSUME_YES:-}" = 1 ] || [ "${MTPROXYL_NONINTERACTIVE:-false}" = true ]; then
        return 0
    fi
    [ "${_MTDD_NET_ASKED:-false}" != true ] || return 0
    _MTDD_NET_ASKED=true
    echo -e "  ${BOLD}Сетевая оптимизация mtdd${NC}"
    echo -e "  ${DIM}Очереди TCP, лимиты ядра и NAPI (меньше сетевых прерываний).${NC}"
    echo -e "  ${DIM}Исходные значения сохраняются для отключения. Меню: Движок → Сетевая оптимизация.${NC}"
    echo -en "  ${BOLD}Применить сетевую оптимизацию mtdd? [y/N]:${NC} "
    _fix_read _answer n
    [[ "$_answer" =~ ^[yYдД] ]] || return 0
    mtdd_net_enable
}

tui_mtdd_net_menu() {
    engine_is_mtdd || return 1
    while true; do
        clear_screen; draw_header 'СЕТЕВАЯ ОПТИМИЗАЦИЯ MTDD'
        mtdd_net_status
        echo -e "  ${DIM}[1]${NC} Применить"
        echo -e "  ${DIM}[2]${NC} Отключить и восстановить свои изменения"
        echo -e "  ${DIM}[0]${NC} Назад"
        local _c; _c=$(read_choice выбор 0)
        case "$_c" in
            1) mtdd_net_enable; press_any_key ;;
            2) mtdd_net_disable; press_any_key ;;
            0|'') return 0 ;;
        esac
    done
}

# Оригинальный установщик меняет сеть без вопроса; профиль применяет MTProxyL.
_mtdd_installer_skip_network() {
    python3 -I - "$1" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
if not re.search(r'(?m)^tune_(kernel|network)\s*\(\)', text):
    if re.search(r'sysctl|napi_defer_hard_irqs|gro_flush_timeout', text):
        sys.exit('Неизвестный формат сетевого тюнинга установщика mtdd, установка отменена')
    sys.exit(0)
pattern = r'(?m)^([ \t]*)tune_kernel[ \t]*\n\1tune_network[ \t]*$'
text, count = re.subn(pattern, r'\1: # Network tuning is managed by MTProxyL', text)
if count != 1:
    sys.exit('Формат установщика mtdd изменился: автоматический сетевой тюнинг не отключён, установка отменена')
path.write_text(text)
PY
}
