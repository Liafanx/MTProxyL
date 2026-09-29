#!/bin/bash
# MTProxyL — движок MTProxyL-Telemt бинарником, без Docker

ENGINE_BIN_DIR="${INSTALL_DIR}/engine"
ENGINE_BIN_NAME="mtproxyl-telemt"
ENGINE_BIN_PATH="${ENGINE_BIN_DIR}/${ENGINE_BIN_NAME}"
ENGINE_SERVICE="mtproxyl-telemt"
ENGINE_UNIT_FILE="/etc/systemd/system/${ENGINE_SERVICE}.service"
ENGINE_VERSION_FILE="${ENGINE_BIN_DIR}/.version"
ENGINE_PREV_BIN="${ENGINE_BIN_DIR}/${ENGINE_BIN_NAME}.prev"
ENGINE_PREV_VERSION_FILE="${ENGINE_BIN_DIR}/.version.prev"
# Откуда взят бинарник: ссылка на свою сборку. Пусто — официальный релиз.
ENGINE_SOURCE_FILE="${ENGINE_BIN_DIR}/.source"
ENGINE_PREV_SOURCE_FILE="${ENGINE_BIN_DIR}/.source.prev"
TELEMT_RELEASES_URL="https://github.com/${TELEMT_GITHUB:-telemt/telemt}/releases/download"

# ── Общее для обоих движков ───────────────────────────────────

engine_backend() {
    case "${ENGINE_BACKEND:-docker}" in
        binary) echo "binary" ;;
        *)      echo "docker" ;;
    esac
}

engine_is_binary() {
    [ "${MTPROXYL_MODE:-manager}" = "manager" ] && [ "$(engine_backend)" = "binary" ]
}

engine_backend_title() {
    if [ "$(engine_backend)" = "binary" ]; then
        echo "бинарник (MTProxyL-Telemt)"
    else
        echo "Docker-образ"
    fi
}

# Конфиг собственного движка. У бинарника он telemt.toml — так его называет
# сам telemt, и так его ждёт панель.
engine_config_path() {
    if engine_is_binary; then
        echo "${CONFIG_DIR}/telemt.toml"
    else
        echo "${CONFIG_DIR}/config.toml"
    fi
}

# ── Определение платформы ─────────────────────────────────────

binengine_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            if [ -r /proc/cpuinfo ] && grep -q avx2 /proc/cpuinfo 2>/dev/null \
               && grep -q bmi2 /proc/cpuinfo 2>/dev/null; then
                echo "x86_64-v3"
            else
                echo "x86_64"
            fi ;;
        aarch64|arm64) echo "aarch64" ;;
        *) return 1 ;;
    esac
}

binengine_libc() {
    local _f
    for _f in /lib/ld-musl-*.so.* /lib64/ld-musl-*.so.*; do
        [ -e "$_f" ] && { echo "musl"; return 0; }
    done
    grep -qE '^ID="?alpine"?' /etc/os-release 2>/dev/null && { echo "musl"; return 0; }
    if command -v ldd &>/dev/null && (ldd --version 2>&1 || true) | grep -qi musl; then
        echo "musl"; return 0
    fi
    echo "gnu"
}

binengine_asset_name() {
    local _arch; _arch=$(binengine_arch) || return 1
    echo "telemt-${_arch}-linux-$(binengine_libc).tar.gz"
}

# ── Версии ────────────────────────────────────────────────────

binengine_latest_version() {
    local _tag
    _tag=$(curl -fsS --max-time 15 "https://api.github.com/repos/${TELEMT_GITHUB}/releases/latest" 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null)
    [ -n "$_tag" ] && { echo "$_tag"; return 0; }
    # Резерв: latest бывает пустым у репозиториев без «свежего» релиза
    curl -fsS --max-time 15 "https://api.github.com/repos/${TELEMT_GITHUB}/releases?per_page=1" 2>/dev/null \
        | python3 -c "import json,sys; r=json.load(sys.stdin); print(r[0]['tag_name'] if r else '')" 2>/dev/null
}

binengine_installed() {
    [ -x "$ENGINE_BIN_PATH" ]
}

# Версия установленного бинарника: сначала наша отметка, потом сам бинарник
# (его мог подменить апдейтер панели).
binengine_version() {
    local _v=""
    [ -r "$ENGINE_VERSION_FILE" ] && _v=$(tr -d ' \t\r\n' < "$ENGINE_VERSION_FILE" 2>/dev/null)
    if [ -z "$_v" ] && [ -x "$ENGINE_BIN_PATH" ]; then
        _v=$("$ENGINE_BIN_PATH" --version 2>/dev/null | awk '{print $NF}')
    fi
    echo "${_v:-unknown}"
}

# ── Загрузка и установка ──────────────────────────────────────

# binengine_fetch <версия|latest> — кладёт бинарник в ENGINE_BIN_PATH
binengine_fetch() {
    local _want="${1:-latest}"
    local _ver="$_want"

    if [ -z "$_ver" ] || [ "$_ver" = "latest" ]; then
        log_info "Определяем последнюю версию telemt..."
        _ver=$(binengine_latest_version)
        [ -n "$_ver" ] || { log_error "Не удалось узнать последнюю версию telemt"; return 1; }
    fi

    local _asset; _asset=$(binengine_asset_name) || {
        log_error "Архитектура $(uname -m) не поддерживается сборками telemt"
        return 1
    }

    local _tmpd
    _tmpd=$(mktemp -d "${TMPDIR:-/tmp}/mtproxyl-engine.XXXXXX") || return 1

    local _rc=0
    _binengine_fetch_into "$_tmpd" "$_ver" "$_asset" || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        rm -rf "$_tmpd"
        return "$_rc"
    fi

    _binengine_put "${_tmpd}/telemt" || { rm -rf "$_tmpd"; return 1; }
    rm -rf "$_tmpd"

    printf '%s\n' "$_ver" > "$ENGINE_VERSION_FILE"
    rm -f "$ENGINE_SOURCE_FILE"
    ENGINE_CUSTOM_URL=""; ENGINE_CUSTOM_SHA256=""
    log_success "MTProxyL-Telemt ${_ver} установлен: ${ENGINE_BIN_PATH}"
}

# Кладёт новый бинарник на место. Прошлый держим рядом вместе с его версией и
# источником: откат не требует сети.
_binengine_put() {
    local _new="$1"
    mkdir -p "$ENGINE_BIN_DIR"; chmod 750 "$ENGINE_BIN_DIR"
    if [ -x "$ENGINE_BIN_PATH" ]; then
        cp -f "$ENGINE_BIN_PATH" "$ENGINE_PREV_BIN" 2>/dev/null || true
        cp -f "$ENGINE_VERSION_FILE" "$ENGINE_PREV_VERSION_FILE" 2>/dev/null || rm -f "$ENGINE_PREV_VERSION_FILE"
        cp -f "$ENGINE_SOURCE_FILE" "$ENGINE_PREV_SOURCE_FILE" 2>/dev/null || rm -f "$ENGINE_PREV_SOURCE_FILE"
    fi
    install -m 0755 "$_new" "$ENGINE_BIN_PATH" || {
        log_error "Не удалось положить бинарник в ${ENGINE_BIN_PATH}"
        return 1
    }
}

# ── Свой бинарник ─────────────────────────────────────────────

binengine_source() {
    [ -r "$ENGINE_SOURCE_FILE" ] && head -1 "$ENGINE_SOURCE_FILE"
}

binengine_is_custom() {
    [ -n "$(binengine_source 2>/dev/null)" ]
}

_binengine_url_valid() {
    [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[^[:space:]\"\'\`\\\$]+$ ]]
}

# e_machine ELF: 0x3e — x86_64, 0xb7 — aarch64.
_binengine_elf_arch_ok() {
    local _m; _m=$(od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n')
    case "$(uname -m):${_m}" in
        x86_64:3e00|amd64:3e00|aarch64:b700|arm64:b700) return 0 ;;
    esac
    return 1
}

# binengine_install_custom <https-ссылка> [sha256] — бинарник telemt или архив
# .tar.gz с ним. sha256 сверяется, только если передан: без него сборка — на
# ответственности пользователя.
binengine_install_custom() {
    local _url="$1" _sha="${2:-}"
    _binengine_url_valid "$_url" || {
        log_error "Нужна ссылка https://… на бинарник telemt или архив .tar.gz с ним"
        return 1
    }
    [ -z "$_sha" ] || [[ "$_sha" =~ ^[0-9a-fA-F]{64}$ ]] || {
        log_error "sha256 — 64 шестнадцатеричных символа"
        return 1
    }
    local _tmpd
    _tmpd=$(mktemp -d "${TMPDIR:-/tmp}/mtproxyl-engine.XXXXXX") || return 1
    local _rc=0
    _binengine_custom_into "$_tmpd" "$_url" "${_sha,,}" || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        rm -rf "$_tmpd"
        return "$_rc"
    fi
    local _ver
    _ver=$(cat "${_tmpd}/version")
    _binengine_put "${_tmpd}/telemt" || { rm -rf "$_tmpd"; return 1; }
    rm -rf "$_tmpd"
    printf '%s-custom\n' "$_ver" > "$ENGINE_VERSION_FILE"
    printf '%s\n' "$_url" > "$ENGINE_SOURCE_FILE"
    chmod 600 "$ENGINE_SOURCE_FILE" 2>/dev/null || true
    ENGINE_CUSTOM_URL="$_url"; ENGINE_CUSTOM_SHA256="${_sha,,}"; ENGINE_VERSION="${_ver}-custom"
    save_settings 2>/dev/null || true
    log_success "Свой бинарник telemt ${_ver} установлен: ${ENGINE_BIN_PATH}"
}

_binengine_custom_into() {
    local _dir="$1" _url="$2" _sha="$3" _got
    log_info "Загрузка: ${_url}"
    if ! curl -fsSL --proto '=https' --connect-timeout 20 --max-time 600 --retry 3 --retry-delay 3 \
            --max-filesize 209715200 "$_url" -o "${_dir}/dl"; then
        log_error "Не удалось скачать — проверьте ссылку и доступ к сайту"
        return 1
    fi
    _got=$(sha256sum "${_dir}/dl" | awk '{print $1}')
    if [ -n "$_sha" ]; then
        if [ "$_sha" != "$_got" ]; then
            log_error "sha256 не совпала: ожидали ${_sha}, скачано ${_got}"
            log_info "Если файл по ссылке обновлён намеренно — поставьте его заново без хеша: mtproxyl engine custom <ссылка>"
            return 1
        fi
        log_success "Контрольная сумма sha256 совпала"
    else
        log_warn "sha256 не указан — файл не проверяется, за сборку отвечаете вы. sha256 скачанного: ${_got}"
    fi

    case "$(od -An -tx1 -N4 "${_dir}/dl" | tr -d ' \n')" in
        7f454c46)
            mv -f "${_dir}/dl" "${_dir}/telemt" ;;
        1f8b*)
            mkdir -p "${_dir}/x"
            tar xzf "${_dir}/dl" -C "${_dir}/x" 2>/dev/null || { log_error "Не удалось распаковать архив"; return 1; }
            local _f _found=""
            while IFS= read -r _f; do
                [ "$(od -An -tx1 -N4 "$_f" | tr -d ' \n')" = "7f454c46" ] && { _found="$_f"; break; }
            done < <(find "${_dir}/x" -type f -name 'telemt*' ! -name '*.sha256' 2>/dev/null)
            [ -n "$_found" ] || { log_error "В архиве нет бинарника telemt"; return 1; }
            mv -f "$_found" "${_dir}/telemt" ;;
        *)
            log_error "По ссылке не бинарник Linux и не архив .tar.gz"
            return 1 ;;
    esac
    chmod 0755 "${_dir}/telemt"

    _binengine_elf_arch_ok "${_dir}/telemt" || {
        log_error "Бинарник собран под другую архитектуру, а сервер — $(uname -m)"
        return 1
    }
    local _out _ver
    _out=$(timeout 10 "${_dir}/telemt" --version 2>&1) || true
    _ver=$(awk 'tolower($0) ~ /telemt/ {print $NF; exit}' <<< "$_out")
    _ver="${_ver#v}"
    if ! [[ "$_ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([.-][0-9A-Za-z.-]+)?$ ]]; then
        log_error "Бинарник не запустился или это не telemt: --version не вернул «telemt X.Y.Z»"
        [ -n "$_out" ] && printf '%s\n' "$_out" | head -3 | sed 's/^/    /'
        log_info "Частые причины: сборка под glibc на системе с musl или слишком старый glibc, инструкции x86-64-v3 на старом CPU"
        return 1
    fi
    printf '%s' "${_ver%-custom}" > "${_dir}/version"
}

_binengine_fetch_into() {
    local _dir="$1" _ver="$2" _asset="$3"

    # Тег бывает и «3.4.25», и «v3.4.25» — какой из них настоящий, спрашиваем
    # заранее: иначе таймаут на медленной сети не отличить от «нет такой версии».
    local _base="" _try
    local _alt="${_ver#v}"; [ "$_alt" = "$_ver" ] && _alt="v${_ver}"
    for _try in "$_ver" "$_alt"; do
        if curl -fsSLI --max-time 20 -o /dev/null "${TELEMT_RELEASES_URL}/${_try}/${_asset}" 2>/dev/null; then
            _base="${TELEMT_RELEASES_URL}/${_try}"
            break
        fi
    done
    if [ -z "$_base" ]; then
        log_error "Сборки telemt ${_ver} (${_asset}) на GitHub нет"
        log_info "Список версий: mtproxyl engine list"
        return 1
    fi

    log_info "Загрузка ${_asset} (${_ver})..."
    if ! curl -fsSL --connect-timeout 20 --max-time 600 --retry 3 --retry-delay 3 \
            "${_base}/${_asset}" -o "${_dir}/a.tar.gz"; then
        log_error "Не удалось скачать сборку telemt ${_ver} — сеть или GitHub недоступны"
        return 1
    fi

    # Контрольная сумма: файл рядом с архивом, формат «хеш  имя»
    if curl -fsSL --max-time 30 "${_base}/${_asset}.sha256" -o "${_dir}/a.sha256" 2>/dev/null; then
        local _want _got
        _want=$(awk 'NF{print $1; exit}' "${_dir}/a.sha256")
        _got=$(sha256sum "${_dir}/a.tar.gz" 2>/dev/null | awk '{print $1}')
        if [ -n "$_want" ] && [ -n "$_got" ] && [ "$_want" != "$_got" ]; then
            log_error "Контрольная сумма не сошлась — архив повреждён или подменён"
            return 1
        fi
        [ -n "$_want" ] && log_success "Контрольная сумма sha256 совпала"
    else
        log_warn "Файл контрольной суммы недоступен — проверку пропускаем"
    fi

    tar xzf "${_dir}/a.tar.gz" -C "$_dir" 2>/dev/null || {
        log_error "Не удалось распаковать архив telemt"
        return 1
    }
    if [ ! -f "${_dir}/telemt" ]; then
        local _found
        _found=$(find "$_dir" -type f -name 'telemt*' ! -name '*.tar.gz' ! -name '*.sha256' | head -1)
        [ -n "$_found" ] && mv -f "$_found" "${_dir}/telemt"
    fi
    [ -f "${_dir}/telemt" ] || { log_error "В архиве нет бинарника telemt"; return 1; }
    chmod 0755 "${_dir}/telemt"
}

binengine_ensure_installed() {
    binengine_installed && return 0
    if [ -n "${ENGINE_CUSTOM_URL:-}" ]; then
        binengine_install_custom "$ENGINE_CUSTOM_URL" "${ENGINE_CUSTOM_SHA256:-}"
        return
    fi
    binengine_fetch "${ENGINE_VERSION:-latest}"
}

# ── systemd ───────────────────────────────────────────────────

# Лимиты у службы задаёт systemd, а не docker: ядра переводим в проценты
# (одно ядро = 100%), суффикс памяти приводим к виду, который понимает systemd.
_binengine_cpu_quota() {
    local _c="${PROXY_CPUS:-}"
    [ -n "$_c" ] || return 1
    awk -v v="$_c" 'BEGIN{ q = v * 100; if (q <= 0) exit 1; printf "%d%%\n", (q < 1 ? 1 : q) }' 2>/dev/null
}

_binengine_memory_max() {
    local _m="${PROXY_MEMORY:-}"
    [ -n "$_m" ] || return 1
    _m="${_m//[[:space:]]/}"
    if [[ "$_m" =~ ^([0-9]+)([kKmMgG]?)[bB]?$ ]]; then
        local _n="${BASH_REMATCH[1]}" _s="${BASH_REMATCH[2]}"
        case "${_s,,}" in
            k) echo "${_n}K" ;;
            m) echo "${_n}M" ;;
            g) echo "${_n}G" ;;
            *) echo "$_n" ;;
        esac
        return 0
    fi
    return 1
}

# telemt 3.5.8+ ведёт правила conntrack сам и на старте чистит и nft, и
# iptables. В 3.5.8 helper iptables запускался без имени applet'а («No valid
# subcommand given», telemt #932); в 3.5.9 это исправили, но iptables-nft 1.8.10+
# сообщает об отсутствии цепочки «Chain '…' does not exist», и telemt считает
# это ошибкой. Итог один: сверка падает и повторяется бесконечно. При наличии
# nft iptables движку не нужен, поэтому multi-бинарники от процесса прячем.
# Без mount namespace (часть LXC) такой юнит не стартует — сначала systemd-run.
_binengine_hidden_helpers() {
    local _b _t _seen=" " _lines="" _v _nft=""
    _v=$(binengine_version 2>/dev/null); _v="${_v#v}"; _v="${_v%%-*}"
    [ -n "$_v" ] && _version_ge "$_v" "3.5.8" || return 1
    for _b in /usr/sbin/nft /usr/bin/nft /sbin/nft /bin/nft; do
        [ -x "$_b" ] && { _nft=1; break; }
    done
    [ -n "$_nft" ] || return 1
    [ "$(get_expert_override_value server.conntrack_control backend 2>/dev/null)" != "iptables" ] || return 1
    for _b in iptables ip6tables iptables-restore ip6tables-restore; do
        _t=$(readlink -f "/usr/sbin/${_b}" 2>/dev/null) || continue
        [ -f "$_t" ] || continue
        case "${_t##*/}" in xtables-*-multi) ;; *) continue ;; esac
        case "$_seen" in *" ${_t} "*) continue ;; esac
        _seen+="${_t} "
        _lines+="InaccessiblePaths=-${_t}"$'\n'
    done
    [ -n "$_lines" ] || return 1
    command -v systemd-run >/dev/null 2>&1 || return 1
    local _probe=(systemd-run --quiet --wait --collect)
    while IFS= read -r _b; do
        [ -n "$_b" ] && _probe+=(-p "$_b")
    done <<< "$_lines"
    timeout 20 "${_probe[@]}" /bin/true >/dev/null 2>&1 || return 1
    printf '%s' "$_lines"
}

binengine_write_unit() {
    command -v systemctl &>/dev/null || {
        log_error "Нет systemd — бинарным движком некому управлять"
        return 1
    }
    local _limits="" _q _mm _hide
    _q=$(_binengine_cpu_quota) && _limits+="CPUQuota=${_q}"$'\n'
    _mm=$(_binengine_memory_max) && _limits+="MemoryMax=${_mm}"$'\n'
    _hide=$(_binengine_hidden_helpers) && _limits+="${_hide}"
    cat > "$ENGINE_UNIT_FILE" << UNIT_EOF
[Unit]
Description=MTProxyL-Telemt proxy engine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ENGINE_BIN_PATH} run ${CONFIG_DIR}/telemt.toml
ExecReload=/bin/kill -HUP \$MAINPID
WorkingDirectory=${ENGINE_BIN_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65535
KillSignal=SIGINT
${_limits}
[Install]
WantedBy=multi-user.target
UNIT_EOF
    chmod 644 "$ENGINE_UNIT_FILE"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$ENGINE_SERVICE" &>/dev/null || true
}

binengine_unit_exists() {
    [ -f "$ENGINE_UNIT_FILE" ]
}

# absent|running|restarting|exited — те же слова, что у контейнера: их читает
# панель и меню, и заводить второй словарь состояний незачем.
binengine_state() {
    binengine_unit_exists || { echo "absent"; return; }
    local _st; _st=$(systemctl is-active "$ENGINE_SERVICE" 2>/dev/null)
    case "$_st" in
        active)     echo "running" ;;
        activating|reloading|deactivating) echo "restarting" ;;
        *)
            # auto-restart — это падение в цикле, а не чистая остановка
            local _sub; _sub=$(systemctl show "$ENGINE_SERVICE" -p SubState --value 2>/dev/null)
            [ "$_sub" = "auto-restart" ] && { echo "restarting"; return; }
            echo "exited" ;;
    esac
}

binengine_running() {
    systemctl is-active --quiet "$ENGINE_SERVICE" 2>/dev/null
}

binengine_problem() {
    local _st; _st=$(binengine_state)
    case "$_st" in
        running|absent) return 1 ;;
    esac
    local _code _res
    _code=$(systemctl show "$ENGINE_SERVICE" -p ExecMainStatus --value 2>/dev/null)
    _res=$(systemctl show "$ENGINE_SERVICE" -p Result --value 2>/dev/null)
    [ "$_st" = "exited" ] && [ "${_code:-0}" = "0" ] && [ "${_res:-success}" = "success" ] && return 1

    # Собственные строки systemd («Failed with result…») отбрасываем: причина
    # падения — в том, что написал сам движок, а не в отчёте о падении.
    local _log _err
    _log=$(journalctl -u "$ENGINE_SERVICE" -n 30 --no-pager -o cat 2>/dev/null \
        | tr -d '\r' \
        | grep -vE "^(${ENGINE_SERVICE}\.service:|Started |Stopped |Stopping |Starting )")
    _err=$(grep -iE 'error|panic|fatal|denied|refused|in use|failed' <<< "$_log" | tail -1)
    [ -z "$_err" ] && _err=$(grep -v '^[[:space:]]*$' <<< "$_log" | tail -1)
    _err=$(sed 's/^[[:space:]]*//' <<< "$_err" | cut -c1-120)

    echo "${_st} (exit=${_code:-?})${_err:+: ${_err}}"
}

binengine_uptime() {
    binengine_running || { echo "0"; return; }
    local _since _now
    _since=$(systemctl show "$ENGINE_SERVICE" -p ActiveEnterTimestamp --value 2>/dev/null \
        | xargs -I{} date -d {} +%s 2>/dev/null)
    _now=$(date +%s)
    if [ -n "$_since" ] && [ "$_since" -gt 0 ] 2>/dev/null; then
        echo $(( _now - _since ))
    else
        echo "0"
    fi
}

# ── Жизненный цикл ────────────────────────────────────────────

binengine_launch() {
    binengine_write_unit || return 1
    log_info "Запуск MTProxyL-Telemt: $(proxy_transport_mode_title 2>/dev/null || echo MTProto)..."
    systemctl restart "$ENGINE_SERVICE" 2>/dev/null || {
        log_error "Не удалось запустить ${ENGINE_SERVICE}"
        journalctl -u "$ENGINE_SERVICE" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    }
}

binengine_start() {
    binengine_running && { log_info "Прокси уже запущен"; return 0; }
    run_proxy_container
}

binengine_stop() {
    if binengine_running; then
        flush_traffic_to_disk 2>/dev/null || true
        systemctl stop "$ENGINE_SERVICE" 2>/dev/null \
            && log_success "Прокси остановлен" \
            || { log_error "Не удалось остановить ${ENGINE_SERVICE}"; return 1; }
    else
        log_info "Прокси не запущен"
    fi
}

binengine_restart() {
    binengine_stop 2>/dev/null || true
    run_proxy_container
}

binengine_reload() {
    binengine_running && systemctl kill -s HUP "$ENGINE_SERVICE" 2>/dev/null || true
}

# Снять службу, бинарник и конфиг оставить — аналог remove_own_container.
binengine_remove_service() {
    binengine_unit_exists || { log_info "Служба ${ENGINE_SERVICE} отсутствует"; return 0; }
    flush_traffic_to_disk 2>/dev/null || true
    systemctl disable --now "$ENGINE_SERVICE" &>/dev/null || true
    rm -f "$ENGINE_UNIT_FILE"
    systemctl daemon-reload 2>/dev/null || true
    log_success "Служба ${ENGINE_SERVICE} остановлена и снята"
    log_info "Бинарник и конфиг сохранены — движок поднимется заново при запуске"
}

# Убрать движок целиком: службу, бинарники, отметки версий.
binengine_purge() {
    systemctl disable --now "$ENGINE_SERVICE" &>/dev/null || true
    rm -f "$ENGINE_UNIT_FILE"
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$ENGINE_BIN_DIR"
}

# Установка поверх могла сменить носитель: прежний остался бы держать порт,
# и новый движок просто не поднялся бы.
engine_clear_other_carrier() {
    if engine_is_binary; then
        _docker_remove_own_container 2>/dev/null || true
    elif binengine_unit_exists; then
        binengine_remove_service
    fi
}

# ── Обновление и откат ────────────────────────────────────────

binengine_update_to() {
    local _tag="${1:-latest}"
    local _cur; _cur=$(binengine_version)
    log_info "Текущая версия: ${_cur}"
    binengine_is_custom && log_warn "Свой бинарник будет заменён официальной сборкой telemt; вернуться — mtproxyl engine rollback"
    binengine_fetch "$_tag" || return 1
    ENGINE_VERSION=$(binengine_version)
    save_settings 2>/dev/null || true
    binengine_write_unit || return 1
    if binengine_running || [ "$(binengine_state)" != "absent" ]; then
        local _yn; read_line _yn "  ${BOLD}Перезапустить прокси? [Y/n]:${NC} "
        if [[ ! "$_yn" =~ ^[nN] ]]; then
            load_secrets
            restart_proxy_container
        fi
    fi
}

# Аргумент --yes снимает вопрос: панель уже спросила у пользователя.
binengine_rollback() {
    local _assume="${1:-}"
    if [ ! -x "$ENGINE_PREV_BIN" ]; then
        log_error "Предыдущей версии на диске нет — откатывать не к чему"
        log_info "Поставьте нужную версию: mtproxyl engine update <версия>"
        return 1
    fi
    local _cur _prev
    _cur=$(binengine_version)
    _prev=$(tr -d ' \t\r\n' < "$ENGINE_PREV_VERSION_FILE" 2>/dev/null)
    [ -n "$_prev" ] || _prev=$("$ENGINE_PREV_BIN" --version 2>/dev/null | awk '{print $NF}')

    if [ "$_assume" != "--yes" ]; then
        echo ""
        echo -e "  ${BOLD}Текущая:${NC}    ${_cur}"
        echo -e "  ${BOLD}Предыдущая:${NC} ${_prev:-неизвестна}"
        local _yn; read_line _yn "  ${BOLD}Откатиться? [y/N]:${NC} "
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
    fi

    local _tmp="${ENGINE_BIN_DIR}/.swap.$$"
    cp -f "$ENGINE_BIN_PATH" "$_tmp" 2>/dev/null || true
    install -m 0755 "$ENGINE_PREV_BIN" "$ENGINE_BIN_PATH" || { log_error "Не удалось заменить бинарник"; return 1; }
    [ -f "$_tmp" ] && mv -f "$_tmp" "$ENGINE_PREV_BIN"
    printf '%s\n' "${_prev:-unknown}" > "$ENGINE_VERSION_FILE"
    printf '%s\n' "$_cur" > "$ENGINE_PREV_VERSION_FILE"
    # Источник переезжает вместе с бинарником: свой остаётся своим.
    local _src_cur _src_prev
    _src_cur=$(cat "$ENGINE_SOURCE_FILE" 2>/dev/null); _src_prev=$(cat "$ENGINE_PREV_SOURCE_FILE" 2>/dev/null)
    if [ -n "$_src_prev" ]; then printf '%s\n' "$_src_prev" > "$ENGINE_SOURCE_FILE"; else rm -f "$ENGINE_SOURCE_FILE"; fi
    if [ -n "$_src_cur" ]; then printf '%s\n' "$_src_cur" > "$ENGINE_PREV_SOURCE_FILE"; else rm -f "$ENGINE_PREV_SOURCE_FILE"; fi
    # Хеш относился к скачанной сборке, у прежней он неизвестен.
    ENGINE_CUSTOM_URL="$_src_prev"; ENGINE_CUSTOM_SHA256=""
    ENGINE_VERSION="${_prev:-}"
    save_settings 2>/dev/null || true
    log_success "Версия переключена на ${_prev:-предыдущую}"

    if [ "$(binengine_state)" != "absent" ]; then
        load_secrets
        restart_proxy_container
    fi
}

# ── Смена движка на живой установке ───────────────────────────

# Образ движка после перехода на бинарник — это сотни мегабайт, ради которых
# на бинарник и уходят. Предлагаем убрать; сам Docker не трогаем.
_binengine_offer_image_cleanup() {
    command -v docker &>/dev/null || return 0
    local _imgs
    _imgs=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -E "^(${DOCKER_IMAGE_BASE}|${REGISTRY_IMAGE}):" || true)
    [ -n "$_imgs" ] || return 0
    echo ""
    echo -e "  ${DIM}Образы движка больше не нужны:${NC}"
    printf '    %s\n' $_imgs
    local _yn; read_line _yn "  ${BOLD}Удалить их? [Y/n]:${NC} "
    [[ "$_yn" =~ ^[nN] ]] && { log_info "Образы оставлены"; return 0; }
    local _i
    for _i in $_imgs; do docker rmi "$_i" >/dev/null 2>&1 || true; done
    log_success "Образы движка удалены"
}

# mtproxyl engine custom <ссылка> [--sha256 <хеш>] [--yes]. Свой бинарник живёт
# в бинарном движке: с Docker-образа сначала переезжаем.
engine_install_custom() {
    local _url="" _sha="" _yes=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --sha256) _sha="${2:-}"; shift ;;
            --sha256=*) _sha="${1#*=}" ;;
            --yes|-y) _yes="--yes" ;;
            *) [ -z "$_url" ] && _url="$1" ;;
        esac
        shift
    done
    _require_manager_mode || return 1
    check_root
    if [ -z "$_url" ]; then
        echo -e "  ${BOLD}Использование:${NC} mtproxyl engine custom <ссылка> [--sha256 <хеш>] [--yes]"
        echo -e "  ${DIM}Ссылка https на бинарник telemt или архив .tar.gz с ним, например:${NC}"
        echo -e "  ${DIM}https://github.com/telemt/telemt/releases/download/3.5.7/telemt-x86_64-linux-musl.tar.gz${NC}"
        return 1
    fi
    _binengine_url_valid "$_url" || {
        log_error "Нужна ссылка https://… на бинарник telemt или архив .tar.gz с ним"
        return 1
    }
    command -v systemctl &>/dev/null || {
        log_error "Свой бинарник работает службой systemd, а systemd здесь нет"
        return 1
    }
    log_warn "Бинарник запускается от root: ставьте только сборки, которым доверяете"

    if ! engine_is_binary; then
        echo ""
        log_info "Свой бинарник работает в бинарном движке, сейчас — Docker-образ"
        if [ "$_yes" != "--yes" ]; then
            local _yn; read_line _yn "  ${BOLD}Перевести движок на бинарник и поставить свой? [y/N]:${NC} "
            [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
        fi
        binengine_install_custom "$_url" "$_sha" || return 1
        engine_switch_backend binary --yes
        return
    fi

    binengine_install_custom "$_url" "$_sha" || return 1
    binengine_write_unit || return 1
    if [ "$(binengine_state)" != "absent" ]; then
        load_secrets
        restart_proxy_container
    fi
}

engine_switch_backend() {
    local _to="${1:-}" _assume="${2:-}"
    _require_manager_mode || return 1
    check_root
    case "$_to" in
        docker|binary) ;;
        *) log_error "Использование: mtproxyl engine backend <docker|binary>"; return 1 ;;
    esac
    if [ "$_to" = "binary" ]; then
        command -v systemctl &>/dev/null || {
            log_error "Бинарный движок работает службой systemd, а systemd здесь нет"
            return 1
        }
        binengine_arch >/dev/null 2>&1 || {
            log_error "Сборок telemt под архитектуру $(uname -m) нет"
            return 1
        }
    fi
    if [ "$(engine_backend)" = "$_to" ]; then
        log_info "Движок уже: $(engine_backend_title)"
        return 0
    fi

    local _was_running="false"
    is_proxy_running && _was_running="true"

    if [ "$_to" = "binary" ]; then
        echo ""
        log_warn "Движок переедет из контейнера в бинарник MTProxyL-Telemt"
        echo -e "  ${DIM}Секреты, настройки и порт сохранятся: конфиг генерируется заново${NC}"
        echo -e "  ${DIM}в ${CONFIG_DIR}/telemt.toml, контейнер ${CONTAINER_NAME} будет удалён.${NC}"
        echo -e "  ${DIM}Сам Docker остаётся в системе — его мы не ставили и не убираем.${NC}"
        if [ "$_assume" != "--yes" ]; then
            local _yn; read_line _yn "  ${BOLD}Продолжить? [y/N]:${NC} "
            [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
        fi

        ENGINE_BACKEND="binary"
        if ! binengine_ensure_installed; then
            ENGINE_BACKEND="docker"
            return 1
        fi
        ENGINE_VERSION=$(binengine_version)
        _docker_remove_own_container 2>/dev/null || true
        save_settings
        rm -f "${CONFIG_DIR}/config.toml"
        _binengine_offer_image_cleanup
    else
        echo ""
        log_warn "Движок переедет из бинарника в Docker-контейнер"
        echo -e "  ${DIM}Понадобится Docker: если его нет, он будет установлен.${NC}"
        if [ "$_assume" != "--yes" ]; then
            local _yn; read_line _yn "  ${BOLD}Продолжить? [y/N]:${NC} "
            [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
        fi

        install_docker || { log_error "Без Docker перейти не получится"; return 1; }
        wait_for_docker || return 1
        binengine_remove_service
        ENGINE_BACKEND="docker"
        save_settings
        rm -f "${CONFIG_DIR}/telemt.toml"
    fi

    log_success "Движок: $(engine_backend_title)"
    install_autostart_unit
    generate_telemt_config || { log_error "Ошибка генерации конфига"; return 1; }
    if [ "$_was_running" = "true" ]; then
        load_secrets
        run_proxy_container || return 1
    else
        log_info "Прокси был остановлен — запустите его из меню, когда понадобится"
    fi
    return 0
}
