#!/bin/bash
# MTProxyL — mtdd как движок режима Manager (ENGINE_KIND=mtdd).
#
# Как и с telemt, менеджер сам ставит прокси и владеет его настройками и
# пользователями: бинарник канала main/dev скачивается из оригинальной репы
# ugDeDe/mtdd (сверка sha256), служба, конфиг и токен API — свои. Официальный
# установщик mtdd здесь не запускается: он оставил бы рядом свой менеджер
# mtdd-ctl (второго хозяина пользователей) и свои правки sysctl.
#
# Источник истины по пользователям — secrets.conf. mtdd не перечитывает
# пользователей по SIGHUP (main.cpp), поэтому каждое изменение доносится
# синхронизацией через его API (mtdd_mgr_sync_users), без рестарта.
#
# Работу с API, правку JSON-конфига, смену сборки и медиа-лимиты делает
# адаптер из lib/mtdd.sh: mtdd_mgr_ctx указывает ему на свои пути.

MTDD_MGR_STANDARD="mtproxyl-mtdd"
MTDD_MGR_DIR="${INSTALL_DIR}/mtdd"
MTDD_MGR_STATE="${MTDD_MGR_DIR}/state"
MTDD_MGR_CONFIG="${MTDD_MGR_DIR}/config.json"
MTDD_MGR_ENV="${MTDD_MGR_DIR}/credentials.env"
# Свои ключи конфига mtdd («Тюнинг mtdd», медиа-лимиты): поверх того, что
# менеджер собирает из своих настроек.
MTDD_MGR_TUNE="${MTDD_MGR_DIR}/tune.json"

# Имя службы, бинарника и системного пользователя — одно: стандартно
# mtproxyl-mtdd или случайное — тогда оно лежит в MTDD_SERVICE_NAME.
mtdd_mgr_names() {
    local _n="$MTDD_MGR_STANDARD"
    [ -n "${MTDD_SERVICE_NAME:-}" ] && _n="$MTDD_SERVICE_NAME"
    MTDD_MGR_SERVICE="$_n"
    MTDD_MGR_USER="$_n"
    MTDD_MGR_BIN="${MTDD_MGR_DIR}/${_n}"
    MTDD_MGR_UNIT_FILE="/etc/systemd/system/${_n}.service"
}
mtdd_mgr_names

# Указать адаптеру lib/mtdd.sh на mtdd менеджера. Зовётся после загрузки
# настроек и обнаружения цели (оно бы вернуло путь цели реаниматора).
mtdd_mgr_ctx() {
    if ! mtdd_mgr_active; then
        # Вернуть адаптеру цель Reanimator: иначе детект после ухода из
        # Manager+mtdd нашёл бы mtdd самого менеджера.
        if [ "${_MTDD_MGR_CTX_ON:-false}" = true ]; then
            MTDD_UNIT="$_MTDD_S1_UNIT"; MTDD_BIN_DEFAULT="$_MTDD_S1_BIN"
            MTDD_CONFIG_DEFAULT="$_MTDD_S1_CONFIG"; MTDD_ENV_DEFAULT="$_MTDD_S1_ENV"
            MTDD_ENGINE_DIR="$_MTDD_S1_ENGINE_DIR"
            MTDD_PREV_BIN="${MTDD_ENGINE_DIR}/mtdd.prev"; MTDD_PREV_LABEL="${MTDD_ENGINE_DIR}/mtdd.prev.label"
            _MTDD_MGR_CTX_ON=false
        fi
        [ "${DETECTED_CONFIG_PATH:-}" = "$MTDD_MGR_CONFIG" ] && DETECTED_CONFIG_PATH=""
        return 0
    fi
    if [ "${_MTDD_MGR_CTX_ON:-false}" != true ]; then
        _MTDD_S1_UNIT="$MTDD_UNIT"; _MTDD_S1_BIN="$MTDD_BIN_DEFAULT"
        _MTDD_S1_CONFIG="$MTDD_CONFIG_DEFAULT"; _MTDD_S1_ENV="$MTDD_ENV_DEFAULT"
        _MTDD_S1_ENGINE_DIR="$MTDD_ENGINE_DIR"
        _MTDD_MGR_CTX_ON=true
    fi
    mtdd_mgr_names
    MTDD_UNIT="${MTDD_MGR_SERVICE}.service"
    MTDD_BIN_DEFAULT="$MTDD_MGR_BIN"
    MTDD_CONFIG_DEFAULT="$MTDD_MGR_CONFIG"
    MTDD_ENV_DEFAULT="$MTDD_MGR_ENV"
    MTDD_ENGINE_DIR="${MTDD_MGR_DIR}/prev"
    MTDD_PREV_BIN="${MTDD_ENGINE_DIR}/mtdd.prev"
    MTDD_PREV_LABEL="${MTDD_ENGINE_DIR}/mtdd.prev.label"
    DETECTED_CONFIG_PATH="$MTDD_MGR_CONFIG"
    return 0
}

# Почему mtdd здесь не поставить. Пусто — можно.
mtdd_mgr_unsupported_reason() {
    [ "$(uname -m)" = "x86_64" ] || { echo "сборки mtdd есть только для Linux x86_64, здесь $(uname -m)"; return; }
    command -v systemctl >/dev/null 2>&1 || { echo "mtdd работает службой systemd, а её здесь нет"; return; }
    command -v python3 >/dev/null 2>&1 || { echo "нужен python3"; return; }
    command -v useradd >/dev/null 2>&1 || echo "нужен useradd (пакет passwd)"
}

# ── Каталоги, пользователь, токен ─────────────────────────────
# Каталог движка 0750 root:<служба>: служба читает конфиг и бинарник, но не
# пишет туда. Состояние (users.json, квоты) — 0700 самой службы: mtdd требует
# именно так (UserStore::open).
_mtdd_mgr_prepare_dirs() {
    if ! getent passwd "$MTDD_MGR_USER" >/dev/null 2>&1; then
        useradd --system --user-group --home-dir "$MTDD_MGR_STATE" --shell /usr/sbin/nologin "$MTDD_MGR_USER" \
            || { log_error "Не удалось создать системного пользователя ${MTDD_MGR_USER}"; return 1; }
    fi
    install -d -m 0750 -o root -g "$MTDD_MGR_USER" "$MTDD_MGR_DIR" || return 1
    install -d -m 0700 -o "$MTDD_MGR_USER" -g "$MTDD_MGR_USER" "$MTDD_MGR_STATE" || return 1
    # После смены имени службы users.json остался бы у прежнего пользователя.
    chown -R "$MTDD_MGR_USER:$MTDD_MGR_USER" "$MTDD_MGR_STATE" 2>/dev/null || true
    if [ ! -s "$MTDD_MGR_ENV" ]; then
        local _tok; _tok=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
        [ ${#_tok} -eq 64 ] || { log_error "Не удалось сгенерировать токен API mtdd"; return 1; }
        ( umask 077; printf 'MTDD_API_TOKEN=%s\n' "$_tok" > "$MTDD_MGR_ENV" ) || return 1
    fi
    # systemd читает EnvironmentFile сам, до смены пользователя: файл — только root.
    chown root:root "$MTDD_MGR_ENV" 2>/dev/null; chmod 600 "$MTDD_MGR_ENV"
}

# ── Конфиг ─────────────────────────────────────────────────────
# Ключи, которые собирает менеджер из своих настроек. В tune.json их не
# пускаем: иначе «Тюнинг mtdd» спорил бы с портом, доменом, маскировкой.
MTDD_MGR_MANAGED_KEYS="proxy_host proxy_port public_host public_port control_host control_port allow_remote_control api_token_env api_read_token_env metrics_host metrics_port metrics_token_env tls_domain ad_tag users_path usage_state_path unique_ip_stats_path masking fallback_host fallback_port me_config_path me_secret_path"

# Ключи, без которых сборка всё равно работает: старый main их не знает.
MTDD_MGR_OPTIONAL_KEYS="usage_state_path metrics_host metrics_port"

_mtdd_mgr_is_managed_key() {
    case " ${MTDD_MGR_MANAGED_KEYS} " in *" $1 "*) return 0 ;; esac
    return 1
}

# Кандидат конфига → файл $1. Второй аргумент 0 — без usage_state_path:
# сборка до квот (старый main) такой ключ не знает и не стартует.
_mtdd_mgr_render() {
    local _out="$1" _usage="${2:-1}" _pub="" _fb_host="" _fb_port=""
    # Адрес в ссылках mtdd. Без CUSTOM_IP — прежний из конфига: иначе каждая
    # правка пользователя ходила бы в сеть, а сменившийся ответ давал бы
    # перезапуск. Заново спрашиваем при запуске (MTDD_MGR_REFRESH_IP=1).
    _pub=$(proxy_public_host 2>/dev/null) || _pub=""
    if [ -z "$_pub" ] && [ "${MTDD_MGR_REFRESH_IP:-0}" != 1 ] && [ -f "$MTDD_MGR_CONFIG" ]; then
        _pub=$(jq -r '.public_host // empty' "$MTDD_MGR_CONFIG" 2>/dev/null)
    fi
    [ -n "$_pub" ] || _pub=$(get_public_ip 2>/dev/null) || _pub=""
    case "$_pub" in *:*) _pub="" ;; esac
    # telemt маскирует на mask_host:mask_port (по умолчанию — сам домен:443).
    # У mtdd то же по умолчанию (fallback_port 0 — реальный сервер SNI);
    # свой адрес (Selfmask, свой сайт) пинуется через fallback_host/port.
    local _dom="${PROXY_DOMAIN:-cloudflare.com}"
    if [ -n "${MASKING_HOST:-}" ] && { [ "$MASKING_HOST" != "$_dom" ] || [ "${MASKING_PORT:-443}" != 443 ]; }; then
        _fb_host="$MASKING_HOST"; _fb_port="${MASKING_PORT:-443}"
    fi
    MG_PORT="${PROXY_PORT:-443}" MG_PUB="$_pub" MG_LINK_PORT="$(proxy_link_port 2>/dev/null)" \
    MG_API_PORT="${PROXY_API_PORT:-9091}" MG_METRICS_PORT="${PROXY_METRICS_PORT:-9090}" \
    MG_DOMAIN="$_dom" MG_TAG="${AD_TAG:-}" MG_MASK="${MASKING_ENABLED:-true}" \
    MG_FB_HOST="$_fb_host" MG_FB_PORT="$_fb_port" MG_STATE="$MTDD_MGR_STATE" MG_USAGE="$_usage" \
    MG_MANAGED="$MTDD_MGR_MANAGED_KEYS" \
        python3 -I - "$_out" "$MTDD_MGR_TUNE" <<'PY'
import json, os, sys
e = os.environ
port = int(e["MG_PORT"])
c = {
    "proxy_host": "0.0.0.0", "proxy_port": port,
    "control_host": "127.0.0.1", "control_port": int(e["MG_API_PORT"]),
    "api_token_env": "MTDD_API_TOKEN",
    "metrics_host": "127.0.0.1", "metrics_port": int(e["MG_METRICS_PORT"]),
    "tls_domain": e["MG_DOMAIN"], "ad_tag": e["MG_TAG"],
    "users_path": e["MG_STATE"] + "/users.json",
    "masking": e["MG_MASK"] == "true",
}
if e["MG_PUB"]:
    c["public_host"] = e["MG_PUB"]
lp = e["MG_LINK_PORT"]
if lp.isdigit() and int(lp) != port:
    c["public_port"] = int(lp)
if e["MG_FB_HOST"]:
    c["fallback_host"] = e["MG_FB_HOST"]
    c["fallback_port"] = int(e["MG_FB_PORT"])
if e["MG_USAGE"] == "1":
    c["usage_state_path"] = e["MG_STATE"] + "/usage.json"
# Ёмкость — как у установщика mtdd: бюджет буферов от памяти.
try:
    ram = next(int(l.split()[1]) * 1024 for l in open("/proc/meminfo") if l.startswith("MemTotal:"))
except (OSError, StopIteration, ValueError):
    ram = 0
if ram:
    c["global_buffer_bytes"] = max(64 << 20, min(ram // 4, 1 << 30))
c["me_connections_per_dc"] = 16
managed = set(e["MG_MANAGED"].split())
try:
    with open(sys.argv[2]) as f:
        tune = json.load(f)
except FileNotFoundError:
    tune = {}
except (OSError, ValueError) as ex:
    sys.stderr.write("tune.json не прочитан: %s\n" % ex); sys.exit(1)
for k, v in (tune.items() if isinstance(tune, dict) else []):
    if k not in managed:
        c[k] = v
with open(sys.argv[1], "w") as f:
    f.write(json.dumps(c, indent=2, ensure_ascii=False) + "\n")
PY
}

# Что поменялось между конфигами: same — ничего, hot — только ключи, которые
# mtdd берёт по SIGHUP, restart — остальное.
_mtdd_mgr_diff_kind() {
    python3 -I - "$1" "$2" <<'PY'
import json, sys
try:
    old = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("restart"); sys.exit(0)
new = json.load(open(sys.argv[2]))
hot = {"me_clients_per_writer", "me_connections_per_dc", "media_user_rate_kbps", "media_total_rate_kbps"}
changed = {k for k in set(old) | set(new) if old.get(k) != new.get(k)}
print("same" if not changed else ("hot" if changed <= hot else "restart"))
PY
}

# Собрать конфиг mtdd из настроек менеджера и tune.json, проверить бинарником
# и положить на место. MTDD_MGR_CONFIG_CHANGE: same | hot | restart.
generate_mtdd_config() {
    MTDD_MGR_CONFIG_CHANGE="same"
    mtdd_mgr_names
    [ -n "${AD_TAG:-}" ] || { log_error "mtdd без рекламного тега не запускается: mtproxyl settings set AD_TAG <32 hex от @MTProxybot>"; return 1; }
    [ -x "${MTDD_MGR_CHECK_BIN:-$MTDD_MGR_BIN}" ] || { log_error "mtdd не установлен: нет ${MTDD_MGR_BIN}"; return 1; }
    _mtdd_mgr_prepare_dirs || return 1
    local _cand _why _key _try _ok=false
    _cand=$(mktemp "${MTDD_MGR_DIR}/.config.XXXXXX") || return 1
    _mtdd_mgr_render "$_cand" 1 || { rm -f "$_cand"; log_error "Не удалось собрать конфиг mtdd"; return 1; }
    # Сборки отличаются набором ключей: у main нет метрик Prometheus и квот.
    # Необязательный ключ, которого сборка не знает, снимаем и проверяем снова;
    # любой другой отказ — ошибка (в том числе неизвестный ключ из tune.json).
    for _try in 1 2 3 4; do
        _why=$(MTDD_BIN="${MTDD_MGR_CHECK_BIN:-$MTDD_MGR_BIN}" MTDD_CONFIG="$_cand" MTDD_ENV_FILE="$MTDD_MGR_ENV" \
            python3 -I -c "$(_mtdd_py_src)" cfg-check "$_cand" 2>&1) && { _ok=true; break; }
        _why="${_why:-проверка не прошла}"
        _key=$(sed -n 's/.*unknown configuration option: \([a-z_]*\).*/\1/p' <<< "$_why" | head -1)
        case " ${MTDD_MGR_OPTIONAL_KEYS} " in
            *" ${_key:-—} "*)
                jq --arg k "$_key" 'del(.[$k])' "$_cand" > "${_cand}.n" && mv -f "${_cand}.n" "$_cand" \
                    || { rm -f "$_cand" "${_cand}.n"; log_error "Не удалось собрать конфиг mtdd"; return 1; } ;;
            *)  rm -f "$_cand"; log_error "mtdd не принял конфиг: ${_why}"; return 1 ;;
        esac
    done
    [ "$_ok" = true ] || { rm -f "$_cand"; log_error "mtdd не принял конфиг: ${_why}"; return 1; }
    MTDD_MGR_CONFIG_CHANGE=$(_mtdd_mgr_diff_kind "$MTDD_MGR_CONFIG" "$_cand")
    if [ "$MTDD_MGR_CONFIG_CHANGE" = "same" ]; then
        rm -f "$_cand"; return 0
    fi
    chown root:"$MTDD_MGR_USER" "$_cand" && chmod 640 "$_cand" && mv -f "$_cand" "$MTDD_MGR_CONFIG" \
        || { rm -f "$_cand"; log_error "Не удалось записать ${MTDD_MGR_CONFIG}"; return 1; }
    return 0
}

# ── Служба ─────────────────────────────────────────────────────
# Как юнит установщика mtdd: свой пользователь, порт ниже 1024 через
# capability, система только для чтения кроме каталога состояния. CPU/RAM —
# те же настройки, что у telemt (PROXY_CPUS, PROXY_MEMORY).
mtdd_mgr_write_unit() {
    mtdd_mgr_names
    local _cpu _mem _limits=""
    _cpu=$(_binengine_cpu_quota 2>/dev/null) && _limits+="CPUQuota=${_cpu}"$'\n'
    _mem=$(_binengine_memory_max 2>/dev/null) && _limits+="MemoryMax=${_mem}"$'\n'
    cat > "${MTDD_MGR_UNIT_FILE}.tmp" <<EOF || return 1
[Unit]
Description=MTProxyL mtdd MTProto proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${MTDD_MGR_USER}
Group=${MTDD_MGR_USER}
EnvironmentFile=${MTDD_MGR_ENV}
ExecStart=${MTDD_MGR_BIN} --config ${MTDD_MGR_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${MTDD_MGR_STATE}
${_limits}
[Install]
WantedBy=multi-user.target
EOF
    mv -f "${MTDD_MGR_UNIT_FILE}.tmp" "$MTDD_MGR_UNIT_FILE" || return 1
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "${MTDD_MGR_SERVICE}.service" >/dev/null 2>&1 || true
}

# ── Бинарник ───────────────────────────────────────────────────
# Свежий бинарник канала из ugDeDe/mtdd (sha256 по SHA256SUMS релиза).
mtdd_mgr_fetch() {
    local _ch="${1:-main}" _tmpd _rc=0
    case "$_ch" in main|dev) ;; *) log_error "У mtdd каналы main и dev"; return 1 ;; esac
    mtdd_mgr_names
    # Не в /tmp: там бывает noexec, а скачанное запускается (--version).
    mkdir -p "$MTDD_MGR_DIR" || return 1
    _tmpd=$(mktemp -d "${MTDD_MGR_DIR}/.dl.XXXXXX") || return 1
    MTDD_FETCH_DATE=""
    if _mtdd_fetch_channel "$_ch" "$_tmpd"; then
        mkdir -p "$MTDD_MGR_DIR"
        install -m 0755 "${_tmpd}/${MTDD_ASSET}" "${MTDD_MGR_BIN}.mtproxyl-new" \
            && mv -f "${MTDD_MGR_BIN}.mtproxyl-new" "$MTDD_MGR_BIN" || _rc=1
        [ $_rc -eq 0 ] && echo "$_ch" > "$MTDD_CHANNEL_FILE" 2>/dev/null
        [ $_rc -eq 0 ] && log_success "mtdd ${_ch} от $(_mtdd_date_ru "$MTDD_FETCH_DATE") скачан: ${MTDD_MGR_BIN}"
    else
        _rc=1
    fi
    rm -rf "$_tmpd"
    return $_rc
}

# ── Состояние и жизненный цикл ─────────────────────────────────
# Состояние, причина падения, аптайм, остановка — те же функции, что у
# бинарника telemt (lib/binengine.sh), с именем службы mtdd на время вызова.
_mtdd_mgr_as() {
    mtdd_mgr_names
    ENGINE_SERVICE="$MTDD_MGR_SERVICE" ENGINE_UNIT_FILE="$MTDD_MGR_UNIT_FILE" "$@"
}
mtdd_mgr_state()          { _mtdd_mgr_as binengine_state; }
mtdd_mgr_running()        { _mtdd_mgr_as binengine_running; }
mtdd_mgr_problem()        { _mtdd_mgr_as binengine_problem; }
mtdd_mgr_uptime()         { _mtdd_mgr_as binengine_uptime; }
mtdd_mgr_stop()           { _mtdd_mgr_as binengine_stop; }
mtdd_mgr_remove_service() { _mtdd_mgr_as binengine_remove_service; }

# «0.1.0 (main)» — без сети: статус зовёт это часто.
mtdd_mgr_version() {
    mtdd_mgr_names
    local _v _ch
    _v=$("$MTDD_MGR_BIN" --version 2>/dev/null | awk '{print $NF; exit}')
    _ch=$(cat "$MTDD_CHANNEL_FILE" 2>/dev/null)
    echo "${_v:-unknown}${_ch:+ (${_ch})}"
}

mtdd_mgr_ensure_installed() {
    mtdd_mgr_names
    [ -x "$MTDD_MGR_BIN" ] && return 0
    local _ch; _ch=$(cat "$MTDD_CHANNEL_FILE" 2>/dev/null)
    case "$_ch" in main|dev) ;; *) _ch=main ;; esac
    local _why; _why=$(mtdd_mgr_unsupported_reason)
    [ -z "$_why" ] || { log_error "mtdd здесь не поставить: ${_why}"; return 1; }
    mtdd_mgr_fetch "$_ch"
}

# Конфиг, служба, запуск, ожидание API, пользователи.
mtdd_mgr_launch() {
    mtdd_mgr_ctx
    MTDD_MGR_REFRESH_IP=1 generate_mtdd_config || return 1
    mtdd_mgr_write_unit || { log_error "Не удалось записать ${MTDD_MGR_UNIT_FILE}"; return 1; }
    log_info "Запуск mtdd ($(mtdd_mgr_version))..."
    systemctl restart "$MTDD_MGR_SERVICE" 2>/dev/null || {
        log_error "Не удалось запустить ${MTDD_MGR_SERVICE}"
        journalctl -u "$MTDD_MGR_SERVICE" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    }
    mtdd_wait_api 20 || {
        log_error "mtdd запущен, но API не отвечает: $(mtdd_api_unavailable_reason)"
        journalctl -u "$MTDD_MGR_SERVICE" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    }
    mtdd_mgr_sync_users
}

# То, что у telemt делает перегенерация конфига + SIGHUP: конфиг mtdd
# (горячие ключи — reload, остальное — рестарт), затем пользователи.
mtdd_mgr_reload_config() {
    mtdd_mgr_ctx
    generate_mtdd_config || return 1
    if [ "$(shaping_config 2>/dev/null | jq -r '.enabled' 2>/dev/null)" = true ]; then
        shaping_restore 2>/dev/null || log_warn 'Не удалось обновить правила ограничения скорости'
    fi
    flush_traffic_to_disk 2>/dev/null || true
    # Не запущен — пользователей заведёт запуск.
    mtdd_mgr_running || return 0
    # Сборка без полного API (старый main) SIGHUP не ловит и от него падает.
    [ "$MTDD_MGR_CONFIG_CHANGE" = hot ] && ! _mtdd_py full 2>/dev/null && MTDD_MGR_CONFIG_CHANGE=restart
    case "$MTDD_MGR_CONFIG_CHANGE" in
        hot)     systemctl reload "$MTDD_MGR_SERVICE" 2>/dev/null || true ;;
        restart) log_info "Изменились настройки, которые mtdd применяет только перезапуском"
                 systemctl restart "$MTDD_MGR_SERVICE" 2>/dev/null || { log_error "Не удалось перезапустить ${MTDD_MGR_SERVICE}"; return 1; }
                 mtdd_wait_api 20 || { log_error "mtdd не отвечает после перезапуска"; return 1; } ;;
    esac
    mtdd_mgr_sync_users || return 1
    log_info "Конфиг обновлён"
}

# secrets.conf → mtdd. Без полного API выключенные не заводятся (и снимаются).
mtdd_mgr_sync_users() {
    mtdd_mgr_ctx
    [ -f "$SECRETS_FILE" ] || { log_warn "Нет ${SECRETS_FILE} — пользователей не к чему приводить"; return 0; }
    local _out _rc
    _out=$(_mtdd_py sync < "$SECRETS_FILE" 2>&1); _rc=$?
    if [ $_rc -ne 0 ] && ! jq -e . >/dev/null 2>&1 <<< "$_out"; then
        log_error "Пользователи не доставлены в mtdd: ${_out}"
        return 1
    fi
    local _skipped _errors
    _skipped=$(jq -r '.skipped | join(", ")' <<< "$_out" 2>/dev/null)
    _errors=$(jq -r '.errors[]' <<< "$_out" 2>/dev/null)
    if [ -n "$_skipped" ]; then
        log_warn "Выключены, а эта сборка mtdd выключать не умеет — в mtdd не заведены: ${_skipped}"
        log_info "Полная сборка: mtproxyl engine update dev"
    fi
    if [ -n "$_errors" ]; then
        log_error "Не все изменения дошли до mtdd:"
        printf '%s\n' "$_errors" | sed 's/^/    /'
        return 1
    fi
    # Сборка без полного API знает только лимит соединений: говорим, у кого
    # из пользователей заданное сейчас не действует, а не про всех подряд.
    if [ "$(jq -r '.full_api' <<< "$_out" 2>/dev/null)" = false ]; then
        local _lost
        _lost=$(awk -F'|' '!/^[[:space:]]*#/ && NF >= 2 && \
            (($6 != "" && $6 != "0") || ($7 != "" && $7 != "0") || ($8 != "" && $8 != "0") || $9 != "" || $11 != "") \
            { printf "%s%s", (n++ ? ", " : ""), $1 }' "$SECRETS_FILE")
        [ -n "$_lost" ] && log_warn "Эта сборка mtdd знает только лимит соединений — лимит IP, квота, срок, заметка и скорость не действуют у: ${_lost} (полная сборка: mtproxyl engine update dev)"
    fi
    return 0
}

# ── «Тюнинг mtdd» в Manager ────────────────────────────────────
# ключ=JSON|@unset → tune.json, затем конфиг пересобирается и проверяется
# бинарником; не принят — tune.json возвращается как был. Ключи, которые
# менеджер собирает из своих настроек, сюда не пускаем.
mtdd_mgr_tune_pairs() {
    mtdd_mgr_names
    local _pair _key
    for _pair in "$@"; do
        _key="${_pair%%=*}"
        if _mtdd_mgr_is_managed_key "$_key"; then
            log_error "${_key} — настройка MTProxyL, а не тюнинг mtdd (порт, домен, маскировка, ad-tag — mtproxyl settings)"
            return 1
        fi
    done
    _mtdd_mgr_prepare_dirs || return 1
    local _bak=""
    [ -f "$MTDD_MGR_TUNE" ] && { _bak=$(mktemp "${MTDD_MGR_DIR}/.tune.XXXXXX") && cp -p "$MTDD_MGR_TUNE" "$_bak"; }
    python3 -I - "$MTDD_MGR_TUNE" "$@" <<'PY' || { [ -n "$_bak" ] && rm -f "$_bak"; log_error "Значение — JSON: число, true/false или \"строка\""; return 1; }
import json, os, sys
path = sys.argv[1]
try:
    tune = json.load(open(path))
except FileNotFoundError:
    tune = {}
for pair in sys.argv[2:]:
    k, v = pair.split("=", 1)
    if v == "@unset":
        tune.pop(k, None)
    else:
        tune[k] = json.loads(v)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write(json.dumps(tune, indent=2, ensure_ascii=False) + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
    if ! generate_mtdd_config; then
        if [ -n "$_bak" ]; then mv -f "$_bak" "$MTDD_MGR_TUNE"; else rm -f "$MTDD_MGR_TUNE"; fi
        return 1
    fi
    [ -n "$_bak" ] && rm -f "$_bak"
    return 0
}

# ── Смена движка Manager: telemt ⇄ mtdd ────────────────────────
# Пользователи живут в secrets.conf, поэтому ключи и ссылки переезжают сами:
# новый движок получает тот же список при запуске. Чего у mtdd нет — то
# мешает переходу, а не теряется молча.
mtdd_mgr_switch_blockers() {
    local _why; _why=$(mtdd_mgr_unsupported_reason)
    [ -n "$_why" ] && echo "$_why"
    [[ "${AD_TAG:-}" =~ ^[0-9a-fA-F]{32}$ ]] && [ "$AD_TAG" != "00000000000000000000000000000000" ] \
        || echo "нужен рекламный тег: mtdd без него не запускается (mtproxyl settings set AD_TAG <32 hex от @MTProxybot>)"
    { [ "${WEB_ENABLED:-false}" = true ] || [ "${PROXY_MODE:-mtproto}" != mtproto ]; } \
        && echo "включён WEB-режим — у mtdd его нет"
    [ "${SUPEREXPERT_ENABLED:-false}" = true ] && echo "включён Супер эксперт — это конфиг telemt"
    [ "${PROXY_PROTOCOL:-false}" = true ] && echo "включён PROXY protocol — mtdd его не принимает"
    [ -n "${MASKING_HOST:-}" ] && [ "$MASKING_HOST" != "${PROXY_DOMAIN:-}" ] && [ "${MASKING_PORT:-443}" = "${PROXY_PORT:-443}" ] \
        && echo "mask backend ${MASKING_HOST}:${MASKING_PORT:-443} на порту прокси — у mtdd порт маскировки должен отличаться от порта прокси"
    [ "${WARP_ENABLED:-false}" = true ] && echo "включён WARP — для mtdd пока не поддержан"
    if declare -F donor_load >/dev/null; then
        donor_load 2>/dev/null; [ "${DONOR_ENABLED:-false}" = true ] && echo "включён донор — для mtdd пока не поддержан"
    fi
    declare -F awg_is_enabled >/dev/null && awg_is_enabled && echo "включён AmneziaWG — для mtdd пока не поддержан"
    if declare -F load_upstreams >/dev/null; then
        load_upstreams 2>/dev/null
        local _i _up=""
        for _i in "${!UPSTREAM_NAMES[@]}"; do
            [ "${UPSTREAM_TYPES[$_i]}" != direct ] && [ "${UPSTREAM_ENABLED[$_i]:-true}" = true ] && _up+="${UPSTREAM_NAMES[$_i]} "
        done
        [ -n "$_up" ] && echo "включены upstream-маршруты (${_up% }) — у mtdd их нет"
    fi
    # Скорость mtdd считает в байтах/с и не ниже 1024.
    local _n _r _a _b _slow=""
    for _n in "${!SECRETS_LABELS[@]}"; do
        _r="${SECRETS_RATE[$_n]:-}"; [ -n "$_r" ] || continue
        IFS=: read -r _a _b <<< "$_r"
        { [[ "${_a:-0}" =~ ^[0-9]+$ ]] && [ "${_a:-0}" -gt 0 ] && [ "$_a" -lt 8192 ]; } \
            || { [[ "${_b:-0}" =~ ^[0-9]+$ ]] && [ "${_b:-0}" -gt 0 ] && [ "$_b" -lt 8192 ]; } \
            && _slow+="${SECRETS_LABELS[$_n]} "
    done
    [ -n "$_slow" ] && echo "скорость ниже 8192 бит/с у: ${_slow% } — mtdd такую не принимает"
    return 0
}

_engine_kind_set() {
    ENGINE_KIND="$1"
    mtdd_mgr_ctx
}

engine_switch_kind() {
    local _to="${1:-}" _yes="${2:-}"
    _require_manager_mode || return 1
    if [ -z "$_to" ]; then
        echo -e "  ${DIM}Движок Manager:${NC} ${ENGINE_KIND:-telemt}"
        echo -e "  ${DIM}Сменить: mtproxyl engine kind telemt|mtdd${NC}"
        return 0
    fi
    case "$_to" in telemt|mtdd) ;; *) log_error "Движок: telemt или mtdd"; return 1 ;; esac
    check_root
    [ "${ENGINE_KIND:-telemt}" = "$_to" ] && { log_info "Движок уже ${_to}"; return 0; }
    load_secrets
    if [ "$_to" = mtdd ]; then
        local _b; _b=$(mtdd_mgr_switch_blockers)
        if [ -n "$_b" ]; then
            log_error "Перейти на mtdd сейчас нельзя:"
            sed 's/^/    • /' <<< "$_b"
            return 1
        fi
        local _i _tags=""
        for _i in "${!SECRETS_LABELS[@]}"; do
            [ -n "${SECRETS_ADTAG[$_i]:-}" ] && _tags+="${SECRETS_LABELS[$_i]} "
        done
        [ -n "$_tags" ] && log_warn "Свой рекламный тег у: ${_tags% } — у mtdd тег один на сервер, эти теги не действуют"
    fi
    local _from="${ENGINE_KIND:-telemt}"
    if [ "$_yes" != "--yes" ]; then
        echo ""
        echo -e "  ${BOLD}Смена движка: ${_from} → ${_to}${NC}"
        echo -e "  ${DIM}Ключи, ссылки, лимиты и статистика сохранятся; прокси перезапустится.${NC}"
        echo -e "  ${DIM}Не поднимется — вернётся ${_from}.${NC}"
        local _yn; read_line _yn "  ${BOLD}Продолжить? [y/N]:${NC} "
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
    fi
    # Бинарник mtdd — до остановки telemt: сеть подведёт, а прокси не упадёт.
    if [ "$_to" = mtdd ]; then
        # Случайное имя службы у telemt — значит, его хотят и у mtdd.
        [ "${ENGINE_SERVICE_NAMING:-}" = random ] && [ -z "${MTDD_SERVICE_NAME:-}" ] \
            && MTDD_SERVICE_NAME=$(binengine_random_name)
        _engine_kind_set mtdd
        if ! mtdd_mgr_ensure_installed; then
            _engine_kind_set "$_from"
            log_error "Движок не сменён: mtdd не скачался"
            return 1
        fi
        _engine_kind_set "$_from"
    else
        # Обратно на telemt. Docker мог не ставиться вовсе (установка сразу с
        # mtdd) — тогда бинарник, если он здесь возможен.
        if [ "${ENGINE_BACKEND:-docker}" = docker ] && ! command -v docker >/dev/null 2>&1 \
            && command -v systemctl >/dev/null 2>&1 && binengine_arch >/dev/null 2>&1; then
            ENGINE_BACKEND=binary
            binengine_resolve_naming
        fi
        if [ "${ENGINE_BACKEND:-docker}" = binary ] && ! binengine_ensure_installed; then
            log_error "Движок не сменён: бинарник telemt не скачался"
            return 1
        fi
    fi
    remove_own_container || true
    # Счётчики сессии у нового движка начнутся с нуля.
    rm -f "${INSTALL_DIR}/relay_stats/session_snapshot" "${INSTALL_DIR}/relay_stats/user_session_snapshot" 2>/dev/null
    _engine_kind_set "$_to"
    save_settings
    # Автозапуск — до запуска, как при установке: снятие mtproxyl.service
    # зовёт «mtproxyl stop», и после старта оно остановило бы новый движок.
    install_autostart_unit >/dev/null 2>&1 || log_warn "Не удалось обновить автозапуск"
    if run_proxy_container; then
        shaping_restore 2>/dev/null || log_warn 'Не удалось восстановить ограничение скорости'
        log_success "Движок сменён: ${_from} → ${_to}"
        return 0
    fi
    log_error "${_to} не поднялся — возвращаем ${_from}"
    remove_own_container >/dev/null 2>&1 || true
    _engine_kind_set "$_from"
    save_settings
    install_autostart_unit >/dev/null 2>&1 || true
    if run_proxy_container; then
        shaping_restore 2>/dev/null || true
        log_info "Прокси снова работает на ${_from}"
    else
        log_error "${_from} тоже не поднялся — mtproxyl logs"
    fi
    return 1
}

# Удаление MTProxyL: служба, каталог движка с состоянием, системный пользователь.
# Пользователь — наш: заводил его _mtdd_mgr_prepare_dirs под имя службы.
mtdd_mgr_purge() {
    mtdd_mgr_names
    local _had=false
    [ -f "$MTDD_MGR_UNIT_FILE" ] && _had=true
    [ -d "$MTDD_MGR_DIR" ] && _had=true
    [ "$_had" = true ] || return 0
    log_info "Удаление движка mtdd (${MTDD_MGR_SERVICE})..."
    systemctl disable --now "$MTDD_MGR_SERVICE" &>/dev/null || true
    rm -f "$MTDD_MGR_UNIT_FILE"
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$MTDD_MGR_DIR"
    if getent passwd "$MTDD_MGR_USER" >/dev/null 2>&1; then
        userdel "$MTDD_MGR_USER" >/dev/null 2>&1 || log_warn "Не удалось удалить пользователя ${MTDD_MGR_USER}"
    fi
    rm -f "$MTDD_CHANNEL_FILE" 2>/dev/null
}

# Имя службы mtdd сменилось (переустановка): прежняя служба держала бы порт.
# Снимаются её юнит, бинарник и пользователь; состояние остаётся новой службе.
mtdd_mgr_drop_old_service() {
    local _old="$1"
    [ -n "$_old" ] && [ "$_old" != "${MTDD_MGR_SERVICE:-}" ] || return 0
    [ -f "/etc/systemd/system/${_old}.service" ] || return 0
    log_info "Снимаем прежнюю службу mtdd ${_old}"
    systemctl disable --now "$_old" &>/dev/null || true
    rm -f "/etc/systemd/system/${_old}.service" "${MTDD_MGR_DIR}/${_old}"
    systemctl daemon-reload 2>/dev/null || true
    getent passwd "$_old" >/dev/null 2>&1 && { userdel "$_old" >/dev/null 2>&1 || true; }
    return 0
}
