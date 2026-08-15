#!/bin/bash
# MTProxyL — телеграм-бот: установка, настройка, служба.
#
# Бот — обёртка над этим же CLI, своей логики управления у него нет. Работает
# от отдельного пользователя без прав, а к mtproxyl ходит через sudo по
# поимённому списку подкоманд: питон с сетевым вводом не должен быть root.

TGBOT_DIR="/opt/mtproxyl-tgbot"
TGBOT_USER="mtproxyl-tgbot"
TGBOT_SERVICE="mtproxyl-tgbot.service"
TGBOT_SUDOERS="/etc/sudoers.d/mtproxyl-tgbot"
TGBOT_CONFIG="${TGBOT_DIR}/config.json"
TGBOT_VENV="${TGBOT_DIR}/venv"

# Файлы бота — тем же порядком, что и lib/*.sh: качаются из ветки установки.
_TGBOT_FILES=(
    "requirements.txt"
    "bot/__init__.py"
    "bot/__main__.py"
    "bot/cli.py"
    "bot/config.py"
    "bot/format.py"
    "bot/keyboards.py"
    "bot/handlers_ops.py"
    "bot/handlers_users.py"
    "bot/notify.py"
    "bot/ui.py"
)

tgbot_installed() {
    [ -x "${TGBOT_VENV}/bin/python" ] && [ -f "${TGBOT_DIR}/bot/__main__.py" ]
}

tgbot_service_active() {
    systemctl is-active "$TGBOT_SERVICE" &>/dev/null
}

tgbot_configured() {
    [ -s "$TGBOT_CONFIG" ] && grep -q '"token"[[:space:]]*:[[:space:]]*"[^"]\+"' "$TGBOT_CONFIG" 2>/dev/null
}

tgbot_status_line() {
    if ! tgbot_installed; then
        echo -e "${DIM}не установлен${NC}"
        return 0
    fi
    if ! tgbot_configured; then
        echo -e "${YELLOW}установлен, не настроен${NC}"
        return 0
    fi
    if tgbot_service_active; then
        echo -e "${GREEN}работает${NC} ${DIM}($(_tgbot_admin_count) админ.)${NC}"
    else
        echo -e "${RED}остановлен${NC}"
    fi
}

_tgbot_admin_count() {
    [ -s "$TGBOT_CONFIG" ] || { echo 0; return 0; }
    if command -v jq &>/dev/null; then
        jq -r '.admins | length' "$TGBOT_CONFIG" 2>/dev/null || echo 0
    else
        echo "?"
    fi
}

_tgbot_admins() {
    [ -s "$TGBOT_CONFIG" ] || return 0
    command -v jq &>/dev/null || return 0
    jq -r '.admins[]?' "$TGBOT_CONFIG" 2>/dev/null
}

# ── Зависимости ───────────────────────────────────────────────

_tgbot_install_deps() {
    local _missing=()
    command -v python3 &>/dev/null || _missing+=("python3")
    # Спрашиваем про ensurepip, а не про venv: в Debian сам модуль venv лежит
    # в python3-minimal и импортируется всегда, а pip внутри venv приносит
    # отдельный пакет — без него `python3 -m venv` падает уже на создании.
    python3 -c "import ensurepip" &>/dev/null || _missing+=("python3-venv")
    command -v curl &>/dev/null || _missing+=("curl")
    # qrencode рисует QR к ссылке. Без него бот пришлёт только ссылку.
    command -v qrencode &>/dev/null || _missing+=("qrencode")

    [ ${#_missing[@]} -eq 0 ] && return 0

    log_info "Ставим зависимости: ${_missing[*]}"
    _tgbot_warn_low_disk
    _wait_apt 2>/dev/null || true
    local _rc=0
    case "$(detect_os)" in
        debian)
            # update отдельно от install: с чужим сломанным репозиторием он
            # вернёт ошибку, а через && установка тогда просто не начнётся.
            apt-get update -qq || log_warn "apt update прошёл с ошибками — ставим из того, что уже в индексе"
            apt-get install -y -qq "${_missing[@]}" || _rc=1 ;;
        rhel)
            # В RHEL venv входит в python3, отдельного пакета нет.
            local _pkgs=("${_missing[@]/python3-venv/python3}")
            yum install -y -q "${_pkgs[@]}" || _rc=1 ;;
        alpine)
            apk add --no-cache python3 py3-pip curl libqrencode-tools || _rc=1 ;;
        *)
            log_warn "Неизвестный дистрибутив — поставьте вручную: ${_missing[*]}"
            return 1 ;;
    esac
    [ "$_rc" -eq 0 ] || log_warn "Менеджер пакетов отчитался об ошибке — проверяем, чего не хватает"

    # Смотрим не на код возврата, а на то, что реально появилось: пакетный
    # менеджер спотыкается о чужой репозиторий или забитый диск и тянет за
    # собой не то, о чём мы просили.
    python3 -c "import ensurepip" &>/dev/null || {
        log_error "python3-venv так и не появился — без него бота не поставить"
        log_info "Поставьте вручную и повторите: apt install python3-venv"
        return 1
    }
    command -v curl &>/dev/null || {
        log_error "curl так и не появился — без него не скачать код бота"
        log_info "Поставьте вручную и повторите: apt install curl"
        return 1
    }
    # QR — не повод отказывать в установке: бот пришлёт саму ссылку.
    command -v qrencode &>/dev/null || {
        log_warn "qrencode не установился — QR-кода к ссылке не будет, только сама ссылка"
        log_info "Поставить можно позже: apt install qrencode"
    }
    return 0
}

# Места нужно около 300 МБ: venv с aiogram плюс кэш пакетного менеджера. На
# забитом диске apt и pip падают на полпути, и разбираться в этом потом
# труднее, чем прочитать предупреждение сейчас.
_tgbot_warn_low_disk() {
    local _free
    _free=$(df -Pm "$(dirname "$TGBOT_DIR")" 2>/dev/null | awk 'NR==2{print $4}')
    [[ "$_free" =~ ^[0-9]+$ ]] || return 0
    [ "$_free" -ge 400 ] && return 0
    log_warn "На диске свободно ${_free} МБ, установке нужно около 300 МБ"
    log_info "Освободите место, иначе apt и pip оборвутся на полпути: apt clean, journalctl --vacuum-size=100M"
}

# ── Исходники ─────────────────────────────────────────────────

# Скачивание с проверкой синтаксиса до подмены: битый файл не должен попасть
# в рабочий каталог и уронить службу при следующем перезапуске.
_tgbot_fetch_sources() {
    local _file _url _tmp _failed=0
    mkdir -p "${TGBOT_DIR}/bot"

    # Установка из локальной копии репозитория: MTPROXYL_TGBOT_SRC=/path/to/repo
    # ставит код оттуда, а не из ветки на GitHub.
    if [ -n "${MTPROXYL_TGBOT_SRC:-}" ] && [ -d "${MTPROXYL_TGBOT_SRC}/bot" ]; then
        for _file in "${_TGBOT_FILES[@]}"; do
            [ -f "${MTPROXYL_TGBOT_SRC}/${_file}" ] || { _failed=$((_failed + 1)); continue; }
            install -m 644 "${MTPROXYL_TGBOT_SRC}/${_file}" "${TGBOT_DIR}/${_file}"
        done
        find "${TGBOT_DIR}" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
        [ "$_failed" -eq 0 ] || return 1
        return 0
    fi

    for _file in "${_TGBOT_FILES[@]}"; do
        _url="${GITHUB_RAW}/mtproxyl-tgbot/${_file}"
        _tmp=$(mktemp "${TGBOT_DIR}/.fetch.XXXXXX") || return 1
        if ! curl -fsS --retry 3 --retry-delay 2 --max-time 30 "$_url" -o "$_tmp" 2>/dev/null; then
            rm -f "$_tmp"
            log_error "Не удалось скачать ${_file}"
            _failed=$((_failed + 1))
            continue
        fi
        if [[ "$_file" == *.py ]] && ! python3 -m py_compile "$_tmp" 2>/dev/null; then
            rm -f "$_tmp"
            log_error "Скачанный ${_file} не разбирается питоном — пропускаем"
            _failed=$((_failed + 1))
            continue
        fi
        mv -f "$_tmp" "${TGBOT_DIR}/${_file}"
        chmod 644 "${TGBOT_DIR}/${_file}"
    done

    find "${TGBOT_DIR}" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
    [ "$_failed" -eq 0 ] || return 1
    return 0
}

_tgbot_build_venv() {
    # Наличия python внутри мало: недоделанный venv (сорвалась установка
    # python3-venv) выглядит готовым, но pip в нём нет и install падает.
    if [ ! -x "${TGBOT_VENV}/bin/python" ] || ! "${TGBOT_VENV}/bin/python" -m pip --version &>/dev/null; then
        [ -d "$TGBOT_VENV" ] && rm -rf "$TGBOT_VENV"
        log_info "Создаём venv..."
        python3 -m venv "$TGBOT_VENV" || {
            log_error "Не удалось создать venv в ${TGBOT_VENV}"
            return 1
        }
    fi
    log_info "Ставим aiogram (может занять минуту)..."
    # Проверку «а нет ли pip поновее» отключаем: она ходит в сеть отдельно от
    # установки и на сервере с закрытым исходящим печатает пугающий WARNING,
    # хотя сами зависимости при этом ставятся.
    local -x PIP_DISABLE_PIP_VERSION_CHECK=1
    # Установка зависимостей — самое тяжёлое место во всей установке, а идёт
    # она фоном, пока человек работает в терминале или в панели. Отдаём ей
    # остатки процессора и диска: на VPS с гигабайтом памяти именно это
    # различает «минуту ставится» и «минуту всё не отвечает».
    local _nice=()
    command -v nice   &>/dev/null && _nice+=(nice -n 10)
    command -v ionice &>/dev/null && _nice+=(ionice -c 2 -n 7)
    "${_nice[@]}" "${TGBOT_VENV}/bin/python" -m pip install --quiet --upgrade pip &>/dev/null || true
    if ! "${_nice[@]}" "${TGBOT_VENV}/bin/python" -m pip install --quiet -r "${TGBOT_DIR}/requirements.txt"; then
        log_error "pip не смог поставить зависимости"
        log_info "Повторите вручную: ${TGBOT_VENV}/bin/python -m pip install -r ${TGBOT_DIR}/requirements.txt"
        return 1
    fi
    return 0
}

# ── Пользователь, права, служба ───────────────────────────────

_tgbot_ensure_user() {
    id "$TGBOT_USER" &>/dev/null && return 0
    useradd --system --no-create-home --home-dir "$TGBOT_DIR" \
            --shell /usr/sbin/nologin "$TGBOT_USER" 2>/dev/null || \
    useradd --system --no-create-home --home-dir "$TGBOT_DIR" \
            --shell /sbin/nologin "$TGBOT_USER" 2>/dev/null || {
        log_error "Не удалось завести пользователя ${TGBOT_USER}"
        return 1
    }
    return 0
}

_tgbot_write_sudoers() {
    local _script="${INSTALL_DIR}/mtproxyl.sh" _tmp
    _tmp=$(mktemp) || return 1

    # Разрешены только те подкоманды, которые бот действительно зовёт, — не
    # `mtproxyl` целиком. Арность не фиксируем: хвостовой `*` в sudoers жадный,
    # лишние аргументы отбрасывает уже сам скрипт по своему каталогу.
    cat > "$_tmp" << EOF
Defaults:${TGBOT_USER} env_keep += "MTPROXYL_ASSUME_YES"

# Состояние и управление прокси
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} status --json
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} mode --json
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} traffic --json
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} start
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} stop
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} restart

# Пользователи
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} secret list --json
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} secret add [A-Za-z0-9]*
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} secret remove [A-Za-z0-9]*
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} secret enable [A-Za-z0-9]*
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} secret disable [A-Za-z0-9]*
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} secret rename [A-Za-z0-9]* [A-Za-z0-9]*
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} secret setlimits [A-Za-z0-9]* * * * *
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} secret adtag [A-Za-z0-9]* *
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} secret link [A-Za-z0-9]*

# Доступность из России
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} availability status --json
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} availability details
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} availability check --json
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} availability on
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} availability off

# Бэкапы: только менеджер, но правило одно на оба режима — в реаниматоре
# скрипт откажет сам, и это понятнее, чем отказ sudo.
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} backup
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} backup list --json
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} backup cat mtproxyl-[0-9]*.tar.gz

# Настройки самого MTProxyL (период и порог проверки доступности)
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} settings list --json
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} settings set [A-Z]*
${TGBOT_USER} ALL=(root) NOPASSWD: ${_script} settings set [A-Z]* *
EOF

    if command -v visudo &>/dev/null; then
        visudo -cf "$_tmp" >/dev/null 2>&1 || {
            rm -f "$_tmp"
            log_error "Сгенерированный файл sudoers некорректен"
            log_info "В Ubuntu 26+ по умолчанию sudo-rs: его visudo не принимает * в аргументах."
            log_info "Переключиться на классический: sudo update-alternatives --set sudo /usr/bin/sudo.ws"
            return 1
        }
    fi

    install -m 0440 "$_tmp" "$TGBOT_SUDOERS"
    rm -f "$_tmp"
    return 0
}

_tgbot_write_service() {
    cat > "/etc/systemd/system/${TGBOT_SERVICE}" << EOF
[Unit]
Description=MTProxyL Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TGBOT_USER}
WorkingDirectory=${TGBOT_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=${TGBOT_VENV}/bin/python -m bot
Restart=on-failure
RestartSec=10

# Бот — фон, и опросы он ведёт сам по себе. На VPS с одним-двумя ядрами он не
# должен отбирать процессор и диск у человека в терминале или в панели; всё,
# что бот запускает через sudo, наследует ту же уступчивость.
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
# Остановку ждём двадцать секунд, а не полторы минуты по умолчанию: терять
# боту нечего, а перезапуск из панели всё это время выглядел бы зависшим.
TimeoutStopSec=20

# CapabilityBoundingSet и NoNewPrivileges не задаём: они урезали бы sudo,
# которым бот зовёт MTProxyL — тот падает без setuid/setgid.
PrivateTmp=true
ProtectHome=true
ReadWritePaths=${TGBOT_DIR}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null
}

# ── Конфиг ────────────────────────────────────────────────────

_tgbot_write_config() {
    local _token="$1" _admin="$2" _tmp
    _tmp=$(mktemp "${TGBOT_DIR}/.config.XXXXXX") || return 1
    cat > "$_tmp" << EOF
{
  "token": "${_token}",
  "admins": [${_admin}],
  "notify": {"availability": true, "proxy": true, "backup": true, "limits": true},
  "intervals": {"availability": 15, "proxy": 5, "limits": 60},
  "autobackup": {"enabled": false, "time": "05:30", "send_file": true}
}
EOF
    mv -f "$_tmp" "$TGBOT_CONFIG"
    chown "$TGBOT_USER":"$TGBOT_USER" "$TGBOT_CONFIG" 2>/dev/null || true
    chmod 600 "$TGBOT_CONFIG"
}

_tgbot_validate_token() {
    local _token="$1"
    [[ "$_token" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{30,}$ ]]
}

# Спрашиваем сам Telegram: опечатка в токене выяснится сейчас, а не через
# минуту в журнале службы.
_tgbot_check_token() {
    local _token="$1" _resp
    command -v curl &>/dev/null || return 0
    _resp=$(curl -fsS --max-time 10 "https://api.telegram.org/bot${_token}/getMe" 2>/dev/null) || {
        log_warn "Telegram не ответил — проверить токен не вышло, продолжаем"
        return 0
    }
    if command -v jq &>/dev/null; then
        local _ok _name
        _ok=$(jq -r '.ok' <<< "$_resp" 2>/dev/null)
        _name=$(jq -r '.result.username // empty' <<< "$_resp" 2>/dev/null)
        if [ "$_ok" != "true" ]; then
            log_error "Telegram не принял токен: $(jq -r '.description // "неизвестная ошибка"' <<< "$_resp")"
            return 1
        fi
        [ -n "$_name" ] && log_success "Токен принят: @${_name}"
    fi
    return 0
}

# Мастер требует терминала. Из панели его запускать нельзя: read_line там
# возвращает "yes" на каждый вопрос, и цикл переспрашивания становится вечным.
_tgbot_interactive() {
    [ "${MTPROXYL_ASSUME_YES:-}" = "1" ] && return 1
    [ -t 0 ] || return 1
    return 0
}

_tgbot_ask_token() {
    _tgbot_interactive || {
        log_error "Нужны токен бота и Telegram ID администратора"
        log_info "В панели заполните оба поля формы; в терминале — mtproxyl tgbot install"
        return 1
    }
    echo ""
    echo -e "  ${BOLD}Шаг 1. Токен бота${NC}"
    echo -e "  ${DIM}1) В Telegram откройте ${BOLD}@BotFather${NC}${DIM} и отправьте /newbot${NC}"
    echo -e "  ${DIM}2) Придумайте имя и username (должен заканчиваться на bot)${NC}"
    echo -e "  ${DIM}3) BotFather пришлёт строку вида 1234567890:AAH...  — это токен${NC}"
    echo ""

    local _token _try
    for _try in 1 2 3; do
        echo -en "  ${BOLD}Токен:${NC} "
        read_line _token
        _token=$(echo "$_token" | tr -d '[:space:]')
        [ -z "$_token" ] && { log_warn "Без токена бот не запустится"; return 1; }
        if ! _tgbot_validate_token "$_token"; then
            log_error "Не похоже на токен: ожидается 1234567890:AAH..."
            continue
        fi
        _tgbot_check_token "$_token" || continue
        printf '%s' "$_token" > "${TGBOT_DIR}/.token.tmp"
        chmod 600 "${TGBOT_DIR}/.token.tmp"
        return 0
    done
    log_error "Три попытки подряд не подошли — установка прервана"
    return 1
}

# ID узнаём у самого Telegram: человеку не нужно искать сторонних ботов, а
# опечатка в шестнадцати цифрах молча оставила бы бота без хозяина.
_tgbot_ask_admin() {
    local _token="$1" _id="" _name=""
    echo ""
    echo -e "  ${BOLD}Шаг 2. Кто управляет ботом${NC}"
    echo -e "  ${DIM}Откройте своего бота в Telegram и отправьте ему ${BOLD}/start${NC}${DIM}.${NC}"
    echo -e "  ${DIM}Ждём до 90 секунд, ID определится сам.${NC}"
    echo ""

    if command -v jq &>/dev/null && command -v curl &>/dev/null; then
        local _deadline=$(( $(date +%s) + 90 )) _resp
        echo -en "  ${DIM}Ожидание"
        while [ "$(date +%s)" -lt "$_deadline" ]; do
            _resp=$(curl -fsS --max-time 15 \
                "https://api.telegram.org/bot${_token}/getUpdates?timeout=10&limit=1" 2>/dev/null) || true
            _id=$(jq -r '[.result[]?.message.from.id] | last // empty' <<< "$_resp" 2>/dev/null)
            if [ -n "$_id" ]; then
                _name=$(jq -r '[.result[]?.message.from.username] | last // empty' <<< "$_resp" 2>/dev/null)
                echo -e "${NC}"
                log_success "Нашли: ${_id}${_name:+ (@${_name})}"
                break
            fi
            echo -n "."
        done
        [ -z "$_id" ] && echo -e "${NC}"
    fi

    if [ -z "$_id" ]; then
        echo -e "  ${DIM}Автоматически не вышло. Узнать ID можно у бота @userinfobot${NC}"
        local _try
        for _try in 1 2 3; do
            echo -en "  ${BOLD}Ваш Telegram ID:${NC} "
            read_line _id
            _id=$(echo "$_id" | tr -cd '0-9')
            [ -n "$_id" ] && break
            log_warn "Нужны только цифры"
        done
    fi
    [ -n "$_id" ] || { log_error "Без Telegram ID бот никого не пустит"; return 1; }
    printf '%s' "$_id" > "${TGBOT_DIR}/.admin.tmp"
    chmod 600 "${TGBOT_DIR}/.admin.tmp"
}

# Состояние бота одной строкой JSON — его читает панель.
tgbot_status_json() {
    local _installed="false" _configured="false" _active="false" _enabled="false"
    tgbot_installed && _installed="true"
    tgbot_configured && _configured="true"
    tgbot_service_active && _active="true"
    systemctl is-enabled "$TGBOT_SERVICE" &>/dev/null && _enabled="true"

    local _cfg='{}'
    if [ -s "$TGBOT_CONFIG" ] && command -v jq &>/dev/null; then
        # Токен наружу не отдаём — только признак, что он есть.
        _cfg=$(jq -c '{admins: (.admins // []),
                       notify: (.notify // {}),
                       intervals: (.intervals // {}),
                       autobackup: (.autobackup // {}),
                       has_token: ((.token // "") != "")}' "$TGBOT_CONFIG" 2>/dev/null) || _cfg='{}'
    fi

    printf '{"installed":%s,"configured":%s,"active":%s,"enabled":%s,"dir":"%s","service":"%s","config":%s}\n' \
        "$_installed" "$_configured" "$_active" "$_enabled" \
        "$TGBOT_DIR" "$TGBOT_SERVICE" "$_cfg"
}

# Последние строки журнала службы — панель показывает их как есть.
tgbot_logs_json() {
    local _n="${1:-50}"
    [[ "$_n" =~ ^[0-9]+$ ]] || _n=50
    [ "$_n" -gt 500 ] && _n=500
    local _out
    _out=$(journalctl -u "$TGBOT_SERVICE" -n "$(( _n * 4 ))" --no-pager -o short-iso 2>/dev/null \
           | grep -vE "sudo\[|pam_unix|COMMAND=" | tail -n "$_n")
    printf '{"lines":"%s"}\n' "$(json_escape "$_out")"
}

# Изменить одну настройку бота. Ключи те же, что в config.json.
tgbot_set_param() {
    local _key="$1" _val="$2"
    command -v jq &>/dev/null || { log_error "Нужен jq"; return 1; }
    tgbot_installed || { log_error "Бот не установлен"; return 1; }
    [ -s "$TGBOT_CONFIG" ] || printf '{}' > "$TGBOT_CONFIG"

    local _expr=""
    case "$_key" in
        notify.availability|notify.proxy|notify.limits|notify.backup)
            case "$_val" in
                true|false) ;;
                *) log_error "Ожидается true или false"; return 1 ;;
            esac
            _expr=".${_key} = ${_val}" ;;
        intervals.availability|intervals.proxy|intervals.limits)
            [[ "$_val" =~ ^[0-9]+$ ]] && [ "$_val" -ge 1 ] && [ "$_val" -le 1440 ] || {
                log_error "Ожидается число от 1 до 1440"; return 1; }
            _expr=".${_key} = ${_val}" ;;
        autobackup.enabled|autobackup.send_file)
            case "$_val" in
                true|false) ;;
                *) log_error "Ожидается true или false"; return 1 ;;
            esac
            _expr=".${_key} = ${_val}" ;;
        autobackup.time)
            [[ "$_val" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || {
                log_error "Ожидается время в формате ЧЧ:ММ"; return 1; }
            _expr=".${_key} = \"${_val}\"" ;;
        *)
            log_error "Неизвестная настройка: ${_key}"
            log_info "Доступны: notify.*, intervals.*, autobackup.*"
            return 1 ;;
    esac

    local _tmp; _tmp=$(mktemp "${TGBOT_DIR}/.config.XXXXXX") || return 1
    if ! jq "$_expr" "$TGBOT_CONFIG" > "$_tmp" 2>/dev/null; then
        rm -f "$_tmp"; log_error "Не удалось изменить настройку"; return 1
    fi
    mv -f "$_tmp" "$TGBOT_CONFIG"
    chown "$TGBOT_USER":"$TGBOT_USER" "$TGBOT_CONFIG" 2>/dev/null || true
    chmod 600 "$TGBOT_CONFIG"
    log_success "${_key} = ${_val}"
}

# ── Установка ─────────────────────────────────────────────────

# --token/--admin — установка без вопросов, ими пользуется панель: терминала
# у неё нет, а мастер с ожиданием /start там негде показать.
tgbot_install() {
    check_root
    local _opt_token="" _opt_admin=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --token) _opt_token="${2:-}"; shift 2 ;;
            --admin) _opt_admin="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done
    echo ""
    echo -e "  ${BOLD}Установка телеграм-бота MTProxyL${NC}"
    echo -e "  ${DIM}Каталог: ${TGBOT_DIR}, служба: ${TGBOT_SERVICE}${NC}"
    echo ""

    mkdir -p "${TGBOT_DIR}/bot"

    # Про токен спрашиваем до тяжёлой части: иначе венв с aiogram ставится две
    # минуты, и только потом выясняется, что заводить бота нечем.
    # Переустановка поверх настроенного не спрашивает — токен уже есть.
    local _token="" _admin="" _write_config="false"
    if [ -n "$_opt_token" ]; then
        _token=$(printf '%s' "$_opt_token" | tr -d '[:space:]')
        _admin=$(printf '%s' "$_opt_admin" | tr -cd '0-9')
        _tgbot_validate_token "$_token" || {
            log_error "Не похоже на токен: ожидается 1234567890:AAH..."
            return 1
        }
        [ -n "$_admin" ] || { log_error "Нужен числовой Telegram ID администратора"; return 1; }
        _tgbot_check_token "$_token" || return 1
        _write_config="true"
    elif tgbot_configured; then
        log_info "Токен и администраторы уже заданы — оставляем как есть"
        log_info "Изменить: меню бота → Настроить, или mtproxyl tgbot setup"
    else
        _tgbot_ask_token || return 1
        _token=$(cat "${TGBOT_DIR}/.token.tmp")
        _tgbot_ask_admin "$_token" || { rm -f "${TGBOT_DIR}/.token.tmp"; return 1; }
        _admin=$(cat "${TGBOT_DIR}/.admin.tmp")
        rm -f "${TGBOT_DIR}/.token.tmp" "${TGBOT_DIR}/.admin.tmp"
        _write_config="true"
    fi

    _tgbot_install_deps || return 1
    _tgbot_ensure_user || return 1

    log_info "Качаем код бота..."
    _tgbot_fetch_sources || { log_error "Исходники бота скачать не удалось"; return 1; }
    _tgbot_build_venv || return 1

    [ "$_write_config" = "true" ] && { _tgbot_write_config "$_token" "$_admin" || return 1; }

    _tgbot_write_sudoers || return 1
    _tgbot_write_service
    chown -R "$TGBOT_USER":"$TGBOT_USER" "$TGBOT_DIR" 2>/dev/null || true
    chmod 750 "$TGBOT_DIR"
    chmod 600 "$TGBOT_CONFIG" 2>/dev/null || true

    systemctl enable "$TGBOT_SERVICE" &>/dev/null
    systemctl restart "$TGBOT_SERVICE"
    sleep 3

    if tgbot_service_active; then
        log_success "Бот запущен"
        # Повторяем в итоге: предупреждение о qrencode осталось в самом начале
        # длинной установки, а из панели её читают уже свёрнутой.
        command -v qrencode &>/dev/null || \
            log_warn "qrencode отсутствует: ссылки придут без QR-кода (apt install qrencode)"
        echo ""
        echo -e "  ${DIM}Откройте бота в Telegram и отправьте /start${NC}"
        echo -e "  ${DIM}Логи: journalctl -u ${TGBOT_SERVICE} -f${NC}"
    else
        log_error "Служба не поднялась"
        journalctl -u "$TGBOT_SERVICE" -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
    fi
    echo ""
}

tgbot_setup() {
    check_root
    tgbot_installed || { log_error "Бот не установлен"; return 1; }

    _tgbot_ask_token || return 1
    local _token _admin
    _token=$(cat "${TGBOT_DIR}/.token.tmp")
    _tgbot_ask_admin "$_token"
    _admin=$(cat "${TGBOT_DIR}/.admin.tmp")
    rm -f "${TGBOT_DIR}/.token.tmp" "${TGBOT_DIR}/.admin.tmp"

    _tgbot_write_config "$_token" "$_admin" || return 1
    systemctl restart "$TGBOT_SERVICE" 2>/dev/null
    log_success "Настройки сохранены, бот перезапущен"
}

# Добавить ещё одного администратора, не трогая остальных.
tgbot_add_admin() {
    check_root
    tgbot_configured || { log_error "Бот ещё не настроен"; return 1; }
    command -v jq &>/dev/null || { log_error "Нужен jq"; return 1; }

    local _id="$1"
    if [ -z "$_id" ]; then
        echo -en "  ${BOLD}Telegram ID нового администратора:${NC} "
        read_line _id
    fi
    _id=$(echo "$_id" | tr -cd '0-9')
    [ -n "$_id" ] || { log_warn "Пусто, ничего не меняем"; return 1; }

    local _tmp; _tmp=$(mktemp "${TGBOT_DIR}/.config.XXXXXX") || return 1
    jq --argjson id "$_id" '.admins = ((.admins // []) + [$id] | unique)' \
        "$TGBOT_CONFIG" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$TGBOT_CONFIG"
    chown "$TGBOT_USER":"$TGBOT_USER" "$TGBOT_CONFIG" 2>/dev/null || true
    chmod 600 "$TGBOT_CONFIG"
    log_success "Администратор ${_id} добавлен"
}

tgbot_remove_admin() {
    check_root
    tgbot_configured || { log_error "Бот ещё не настроен"; return 1; }
    command -v jq &>/dev/null || { log_error "Нужен jq"; return 1; }

    local _id="$1"
    if [ -z "$_id" ]; then
        echo -e "  ${BOLD}Сейчас в списке:${NC}"
        _tgbot_admins | sed 's/^/    /'
        echo -en "  ${BOLD}Кого убрать (ID):${NC} "
        read_line _id
    fi
    _id=$(echo "$_id" | tr -cd '0-9')
    [ -n "$_id" ] || return 1

    local _tmp; _tmp=$(mktemp "${TGBOT_DIR}/.config.XXXXXX") || return 1
    jq --argjson id "$_id" '.admins = ((.admins // []) - [$id])' \
        "$TGBOT_CONFIG" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$TGBOT_CONFIG"
    chown "$TGBOT_USER":"$TGBOT_USER" "$TGBOT_CONFIG" 2>/dev/null || true
    chmod 600 "$TGBOT_CONFIG"
    log_success "Администратор ${_id} убран"
    # Не `[ … ] && log_warn`: последней строкой функции такая связка вернула бы
    # 1, когда админы остались, и вызывающий счёл бы удаление неудачным.
    if [ "$(_tgbot_admin_count)" = "0" ]; then
        log_warn "Администраторов не осталось — бот никого не пустит"
    fi
    return 0
}

# Обновление кода бота отдельно от venv: зависимости меняются редко, а
# перекачать десяток файлов быстро.
tgbot_update_sources() {
    tgbot_installed || return 0
    _tgbot_fetch_sources || return 1
    # Права переписываем вместе с кодом: новая версия бота может звать
    # подкоманду, которой в старом списке нет, и упереться в отказ sudo.
    _tgbot_write_sudoers || log_warn "Права sudo обновить не удалось"
    chown -R "$TGBOT_USER":"$TGBOT_USER" "$TGBOT_DIR" 2>/dev/null || true
    chmod 600 "$TGBOT_CONFIG" 2>/dev/null || true
    systemctl restart "$TGBOT_SERVICE" 2>/dev/null || true
    return 0
}

tgbot_uninstall() {
    check_root
    if [ "${1:-}" != "--yes" ]; then
        echo ""
        log_warn "Будут удалены служба, каталог ${TGBOT_DIR} и права sudo бота"
        echo -en "  ${BOLD}Удалить телеграм-бота? (y/N):${NC} "
        local _c; read_line _c
        [[ "$_c" =~ ^[yYдД] ]] || { log_info "Отменено"; return 0; }
    fi

    systemctl disable --now "$TGBOT_SERVICE" &>/dev/null
    rm -f "/etc/systemd/system/${TGBOT_SERVICE}" "$TGBOT_SUDOERS"
    systemctl daemon-reload 2>/dev/null
    rm -rf "$TGBOT_DIR"
    userdel "$TGBOT_USER" 2>/dev/null || true
    log_success "Телеграм-бот удалён"
}

# ── CLI ───────────────────────────────────────────────────────

tgbot_show_status() {
    echo ""
    echo -e "  ${BOLD}Телеграм-бот${NC}"
    echo ""
    echo -e "  ${BOLD}Состояние:${NC}   $(tgbot_status_line)"
    if tgbot_installed; then
        echo -e "  ${BOLD}Каталог:${NC}     ${TGBOT_DIR}"
        echo -e "  ${BOLD}Служба:${NC}      ${TGBOT_SERVICE}"
        local _admins; _admins=$(_tgbot_admins | tr '\n' ' ')
        echo -e "  ${BOLD}Админы:${NC}      ${_admins:-${DIM}никого${NC}}"
        if ! tgbot_service_active && [ -f "/etc/systemd/system/${TGBOT_SERVICE}" ]; then
            echo ""
            journalctl -u "$TGBOT_SERVICE" -n 5 --no-pager 2>/dev/null | sed 's/^/    /'
        fi
    fi
    echo ""
}

handle_tgbot_command() {
    local _sub="${1:-status}"; shift 2>/dev/null || true
    case "$_sub" in
        install)    tgbot_install "$@" ;;
        setup)      tgbot_setup ;;
        uninstall)  tgbot_uninstall "${1:-}" ;;
        set)        check_root; tgbot_set_param "${1:-}" "${2:-}" ;;
        update)     check_root; tgbot_update_sources && log_success "Код бота обновлён" ;;
        start)      check_root; systemctl start "$TGBOT_SERVICE" && log_success "Запущен" ;;
        stop)       check_root; systemctl stop "$TGBOT_SERVICE" && log_success "Остановлен" ;;
        restart)    check_root; systemctl restart "$TGBOT_SERVICE" && log_success "Перезапущен" ;;
        logs)
            if [ "${1:-}" = "--json" ]; then
                check_root; tgbot_logs_json "${2:-50}"
            else
                journalctl -u "$TGBOT_SERVICE" -n "$(( ${1:-50} * 4 ))" --no-pager \
                    | grep -vE "sudo\[|pam_unix|COMMAND=" | tail -n "${1:-50}"
            fi ;;
        admin-add)  tgbot_add_admin "${1:-}" ;;
        admin-rm)   tgbot_remove_admin "${1:-}" ;;
        status)
            if [ "${1:-}" = "--json" ]; then
                check_root; tgbot_status_json
            else
                tgbot_show_status
            fi ;;
        *)
            echo -e "  ${BOLD}Телеграм-бот:${NC}"
            echo -e "    ${GREEN}tgbot install${NC}      Установить или переустановить"
            echo -e "    ${GREEN}tgbot setup${NC}        Задать токен и администратора заново"
            echo -e "    ${GREEN}tgbot status${NC}       Состояние (--json для машинного вывода)"
            echo -e "    ${GREEN}tgbot set${NC} K V      Уведомления и таймеры (notify.*, intervals.*, autobackup.*)"
            echo -e "    ${GREEN}tgbot start|stop|restart${NC}"
            echo -e "    ${GREEN}tgbot logs${NC} [N]     Журнал службы"
            echo -e "    ${GREEN}tgbot admin-add${NC} ID Добавить администратора"
            echo -e "    ${GREEN}tgbot admin-rm${NC} ID  Убрать администратора"
            echo -e "    ${GREEN}tgbot update${NC}       Перекачать код бота"
            echo -e "    ${GREEN}tgbot uninstall${NC}    Удалить"
            ;;
    esac
}
