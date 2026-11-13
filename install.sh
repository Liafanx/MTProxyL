#!/bin/bash
# MTProxyL — быстрая установка
# Использование:
#   wget -qO /tmp/mtproxyl-install.sh https://raw.githubusercontent.com/Liafanx/MTProxyL/main/install.sh && sudo bash /tmp/mtproxyl-install.sh
#
# Или одной строкой:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Liafanx/MTProxyL/main/install.sh)

set -e

REPO="Liafanx/MTProxyL"
INSTALL_DIR="/opt/mtproxyl"
# Ветка репозитория, из которой скачиваются скрипт и библиотеки
BRANCH="${MTPROXYL_BRANCH:-main}"
# Версия релиза: пусто — последняя. Ставится из архива релиза целиком.
WANT_VERSION="${MTPROXYL_VERSION:-}"
FORCE_REPAIR=false
# Аргументы после «--» уходят установщику: переезд на новый сервер одной строкой.
INSTALL_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--branch)
            [ -n "${2:-}" ] || { echo "ОШИБКА: --branch требует имя ветки" >&2; exit 1; }
            BRANCH="$2"; shift 2 ;;
        --branch=*) BRANCH="${1#*=}"; shift ;;
        -v|--version)
            [ -n "${2:-}" ] || { echo "ОШИБКА: --version требует номер, например 1.7.17" >&2; exit 1; }
            WANT_VERSION="${2#v}"; shift 2 ;;
        --version=*) WANT_VERSION="${1#*=}"; WANT_VERSION="${WANT_VERSION#v}"; shift ;;
        --force|--forced) FORCE_REPAIR=true; shift ;;
        -h|--help)
            echo "Использование: install.sh [--version X.Y.Z | --branch <ветка>] [--force] [-- <аргументы установки>]"
            echo "  --version  поставить конкретную версию из архива релиза"
            echo "  --force    восстановить повреждённый код, сохранив его отдельной копией"
            echo "  Всё после -- уходит в 'mtproxyl install' — установка без вопросов."
            echo "  Список аргументов: mtproxyl install --help"
            exit 0 ;;
        --) shift; INSTALL_ARGS=("$@"); break ;;
        *) echo "ОШИБКА: неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
SCRIPT_URL_REFS="https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}"
INSTALL_LOG="/tmp/mtproxyl-install.log"

download_file() {
    local url="$1"
    local dest="$2"
    local label="$3"

    local tmp fallback_url rel_path
    tmp=$(mktemp "/tmp/.mtproxyl-download.XXXXXX") || {
        echo "  ОШИБКА: Не удалось создать временный файл для ${label}" >&2
        return 1
    }

    # Сначала используем привычный GitHub Raw URL:
    #   /<repo>/<branch>/<path>
    # Если GitHub/CDN отвечает ошибкой даже после retry, пробуем канонический:
    #   /<repo>/refs/heads/<branch>/<path>
    if ! curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        --max-time 45 "$url" -o "$tmp" 2>>"$INSTALL_LOG"; then

        rel_path="${url#"$SCRIPT_URL"/}"
        fallback_url="${SCRIPT_URL_REFS}/${rel_path}"
        : > "$tmp"

        echo "  ↳ основной GitHub Raw недоступен, пробуем refs/heads..." >&2

        if ! curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
            --max-time 45 "$fallback_url" -o "$tmp" 2>>"$INSTALL_LOG"; then
            rm -f "$tmp"
            echo "  ОШИБКА: Не удалось скачать ${label}" >&2
            echo "  Подробности: ${INSTALL_LOG}" >&2
            return 1
        fi
     fi

    # Для shell-файлов дополнительно проверяем синтаксис.
    if [[ "$dest" == *.sh ]]; then
        if ! bash -n "$tmp" 2>/dev/null; then
            echo "  ОШИБКА: Скачанный файл ${label} содержит синтаксическую ошибку" >&2
            rm -f "$tmp"
            return 1
        fi
    fi

    mkdir -p "$(dirname "$dest")"
    mv "$tmp" "$dest"
    return 0
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите от root:" >&2
    echo "  wget -qO /tmp/mtproxyl-install.sh https://raw.githubusercontent.com/${REPO}/main/install.sh && sudo bash /tmp/mtproxyl-install.sh" >&2
    exit 1
fi

: > "$INSTALL_LOG"

# Проверка и установка curl
if ! command -v curl &>/dev/null; then
    echo "  curl не найден, устанавливаю..."
    if command -v apt-get &>/dev/null; then
        # Ждём если apt занят
        local_waited=0
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
            [ "$local_waited" -eq 0 ] && echo "  apt занят, ждём..."
            sleep 3; local_waited=$((local_waited + 3))
            [ "$local_waited" -ge 60 ] && break
        done
        apt-get update -qq >>"$INSTALL_LOG" 2>&1 && apt-get install -y -qq curl >>"$INSTALL_LOG" 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q curl >>"$INSTALL_LOG" 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl >>"$INSTALL_LOG" 2>&1
    elif command -v apk &>/dev/null; then
        apk add --no-cache curl >>"$INSTALL_LOG" 2>&1
    fi
    if ! command -v curl &>/dev/null; then
        echo "  ОШИБКА: Не удалось установить curl. Установите вручную: apt install curl" >&2
        exit 1
    fi
    echo "  ✓ curl установлен"
fi

echo ""
echo "  MTProxyL — установка"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Ветка: ${BRANCH}"
echo ""

mkdir -p "${INSTALL_DIR}/lib" "${INSTALL_DIR}/mtproxy" "${INSTALL_DIR}/backups"

_INSTALL_STAGE='' _INSTALL_ROOT='' _INSTALL_ARCHIVE=''
_install_cleanup() {
    declare -F cli_unlock >/dev/null && cli_unlock
    [ -z "$_INSTALL_STAGE" ] || rm -rf "$_INSTALL_STAGE"
    return 0
}
trap _install_cleanup EXIT

# Архив релиза: все файлы одной версии, сверенные с опубликованной суммой.
install_from_archive() {
    local ver="$1" url tmp sum got root f
    url="https://github.com/${REPO}/releases/download/v${ver}/mtproxyl-${ver}.tar.gz"
    tmp=$(mktemp -d "${INSTALL_DIR}/.install.XXXXXX") || return 1
    sum=$(curl -fsSL --retry 3 --max-time 30 "${url}.sha256" 2>>"$INSTALL_LOG") || { rm -rf "$tmp"; return 1; }
    sum=$(awk 'NR==1{print $1}' <<< "$sum")
    [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo '  ОШИБКА: некорректная сумма архива' >&2; rm -rf "$tmp"; return 2; }
    if ! curl -fsSL --retry 3 --max-time 180 "$url" -o "${tmp}/a.tar.gz" 2>>"$INSTALL_LOG"; then
        rm -rf "$tmp"; return 1
    fi
    got=$(sha256sum "${tmp}/a.tar.gz" | awk '{print $1}')
    [ "$got" = "$sum" ] || { echo "  ОШИБКА: сумма архива не совпала" >&2; rm -rf "$tmp"; return 2; }
    if tar -tzf "${tmp}/a.tar.gz" | grep -vqE "^mtproxyl-${ver//./\\.}(/|$)" \
        || tar -tzf "${tmp}/a.tar.gz" | grep -qE '(^|/)\.\.(/|$)' \
        || tar -tvzf "${tmp}/a.tar.gz" | grep -vqE '^[-d]'; then
        echo "  ОШИБКА: в архиве лишние файлы" >&2; rm -rf "$tmp"; return 2
    fi
    tar -xzf "${tmp}/a.tar.gz" -C "$tmp" --no-same-owner --no-same-permissions || { rm -rf "$tmp"; return 2; }
    root="${tmp}/mtproxyl-${ver}"
    (cd "$root" && sha256sum -c --quiet --strict SHA256SUMS >/dev/null 2>&1) \
        || { echo "  ОШИБКА: суммы внутри архива не сходятся" >&2; rm -rf "$tmp"; return 2; }
    for f in "${root}/mtproxyl.sh" "${root}"/lib/*.sh; do
        bash -n "$f" 2>/dev/null || { echo "  ОШИБКА: синтаксис ${f#"${root}"/}" >&2; rm -rf "$tmp"; return 2; }
    done
    _INSTALL_STAGE="$tmp" _INSTALL_ROOT="$root" _INSTALL_ARCHIVE="${tmp}/a.tar.gz"
}

ARCHIVE_DONE=false
if [ -n "$WANT_VERSION" ] || [ "$BRANCH" = "main" ]; then
    ver="$WANT_VERSION"
    if [ -z "$ver" ]; then
        ver=$(curl -fsSL --retry 3 --max-time 15 "${SCRIPT_URL}/version" 2>>"$INSTALL_LOG" | tr -d '[:space:]')
    fi
    if [[ "$ver" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
        echo "  Скачивание архива v${ver}..."
        _archive_rc=0
        install_from_archive "$ver" || _archive_rc=$?
        if [ "$_archive_rc" -eq 0 ]; then
            ARCHIVE_DONE=true
            echo "  ✓ MTProxyL v${ver} из архива релиза"
        elif [ -n "$WANT_VERSION" ] || [ "$_archive_rc" -eq 2 ]; then
            echo "  ОШИБКА: архива v${ver} нет или он не прошёл проверку" >&2
            echo "  Версии с архивом: https://github.com/${REPO}/releases" >&2
            exit 1
        else
            echo "  Архива v${ver} пока нет — качаем файлы ветки"
        fi
    elif [ -n "$WANT_VERSION" ]; then
        echo "ОШИБКА: неверный номер версии: ${WANT_VERSION}" >&2
        exit 1
    fi
fi

if [ "$ARCHIVE_DONE" != true ]; then
echo "  Скачивание файлов..."
_sha=$(curl -fsS --max-time 15 -H 'Accept: application/vnd.github.sha' \
    "https://api.github.com/repos/${REPO}/commits/${BRANCH}" 2>>"$INSTALL_LOG") || _sha=''
[[ "$_sha" =~ ^[0-9a-f]{40}$ ]] || { echo '  ОШИБКА: не удалось закрепить ветку, файлы не изменены — повторите позже' >&2; exit 1; }
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${_sha}"
SCRIPT_URL_REFS="$SCRIPT_URL"
_INSTALL_STAGE=$(mktemp -d "${INSTALL_DIR}/.install.XXXXXX")
_INSTALL_ROOT="${_INSTALL_STAGE}/branch"
mkdir -p "${_INSTALL_ROOT}/lib"

# Главный скрипт
echo "  → mtproxyl.sh"
if ! download_file "${SCRIPT_URL}/mtproxyl.sh" "${_INSTALL_ROOT}/mtproxyl.sh" "mtproxyl.sh"; then
    echo "  Проверьте интернет, лимиты GitHub Raw и доступность github.com" >&2
    echo "  Подробности: ${INSTALL_LOG}" >&2
    exit 1
fi
chmod +x "${_INSTALL_ROOT}/mtproxyl.sh"
download_file "${SCRIPT_URL}/version" "${_INSTALL_ROOT}/version" version

# Библиотеки
for lib in colors utils settings mtdd secrets config docker binengine engine traffic stats availability dc warp donor awg egress geoblock geoip upstream backup release report nft ipblock shaping selfmask web web_hosts panel tgbot detect api front tui_main tui_proxy tui_secrets tui_links tui_settings tui_security tui_traffic tui_engine tui_backup tui_expert tui_nft tui_ipblock tui_selfmask tui_web tui_addons tui_tgbot tui_warp tui_donor tui_awg tui_detect expert_catalog expert_mode settings_cli install install_args migrate argsgen; do
    echo "  → lib/${lib}.sh"
    if ! download_file "${SCRIPT_URL}/lib/${lib}.sh" "${_INSTALL_ROOT}/lib/${lib}.sh" "lib/${lib}.sh"; then
        # 404 у отдельного файла — это почти всегда несовпадение веток: список
        # библиотек взят из этого install.sh, а качаем мы из другой ветки.
        # Без -f: с ним curl печатает код и выходит с ошибкой, а запасное
        # «|| echo 000» дописывало вторую строку и сравнение не совпадало.
        _code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
            "${SCRIPT_URL}/lib/${lib}.sh" 2>/dev/null | tail -1 | tr -cd '0-9')
        if [ "$_code" = "404" ]; then
            echo "" >&2
            echo "  В ветке '${BRANCH}' файла lib/${lib}.sh нет." >&2
            echo "  Похоже, install.sh взят из другой ветки. Укажите ту же ветку явно:" >&2
            echo "    sudo bash $0 --branch <ветка> [-- <аргументы установки>]" >&2
        else
            echo "  Установка прервана. Повторите попытку через 10–30 секунд." >&2
        fi
        echo "  Подробности: ${INSTALL_LOG}" >&2
        exit 1
    fi
    sleep 0.2
done
_bot_files=$(sed -n '/^_TGBOT_FILES=(/,/^)/{s/^ *"\(.*\)"$/\1/p}' "${_INSTALL_ROOT}/lib/tgbot.sh")
for _file in $_bot_files; do
    mkdir -p "${_INSTALL_ROOT}/mtproxyl-tgbot/$(dirname "$_file")"
    download_file "${SCRIPT_URL}/mtproxyl-tgbot/${_file}" "${_INSTALL_ROOT}/mtproxyl-tgbot/${_file}" "bot/${_file}"
done
fi

# Проверяем комплект до замены, в том числе при установке без архива.
_new_ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "${_INSTALL_ROOT}/mtproxyl.sh" | head -1)
[[ "$_new_ver" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] && \
    [ "$(tr -d '[:space:]' < "${_INSTALL_ROOT}/version")" = "$_new_ver" ] && \
    { [ -z "$WANT_VERSION" ] || [ "$WANT_VERSION" = "$_new_ver" ]; } || { echo '  ОШИБКА: номера версий не совпадают' >&2; exit 1; }
_libs=$(sed -n 's/^for _lib in \(.*\); do$/\1/p' "${_INSTALL_ROOT}/mtproxyl.sh" | head -1)
[ -n "$_libs" ] || { echo '  ОШИБКА: нет списка библиотек' >&2; exit 1; }
for lib in $_libs; do
    [ -f "${_INSTALL_ROOT}/lib/${lib}.sh" ] || { echo "  ОШИБКА: нет lib/${lib}.sh" >&2; exit 1; }
done
if command -v python3 >/dev/null && [ -d "${_INSTALL_ROOT}/mtproxyl-tgbot/bot" ]; then
    for _file in "${_INSTALL_ROOT}"/mtproxyl-tgbot/bot/*.py; do
        python3 -m py_compile "$_file" || { echo "  ОШИБКА: код бота ${_file}" >&2; exit 1; }
    done
    find "${_INSTALL_ROOT}/mtproxyl-tgbot" -type d -name __pycache__ -exec rm -rf {} +
fi

source "${_INSTALL_ROOT}/lib/utils.sh"
if declare -F cli_lock >/dev/null; then cli_lock 300 install || exit 1; fi
_old="${_INSTALL_STAGE}/previous"
mkdir -p "${_old}/lib"
for _file in mtproxyl.sh version; do
    [ ! -f "${INSTALL_DIR}/${_file}" ] || cp -p "${INSTALL_DIR}/${_file}" "${_old}/${_file}"
done
for _file in "${INSTALL_DIR}"/lib/*.sh; do
    [ ! -f "$_file" ] || cp -p "$_file" "${_old}/lib/"
done
_install_save_recovery() {
    local recovery bot_dir=/opt/mtproxyl-tgbot
    mkdir -p "${INSTALL_DIR}/releases" && chmod 700 "${INSTALL_DIR}/releases" || return 1
    recovery=$(mktemp -d "${INSTALL_DIR}/releases/recovery-$(date -u +%Y%m%d-%H%M%S).XXXXXX") || return 1
    mv "$_old" "${recovery}/code" || return 1
    _old="${recovery}/code"
    if [ -d "${bot_dir}/bot" ]; then
        mkdir -p "${recovery}/mtproxyl-tgbot" && cp -a "${bot_dir}/bot" "${recovery}/mtproxyl-tgbot/" || return 1
        if [ -f "${bot_dir}/requirements.txt" ]; then
            cp -p "${bot_dir}/requirements.txt" "${recovery}/mtproxyl-tgbot/" || return 1
        fi
    fi
    echo "  Повреждённый код сохранён: ${recovery}"
    echo '  Эта копия не предлагается как рабочая версия для --rollback'
    echo '  Восстанавливаем код из проверенного комплекта; настройки и пользователи сохраняются'
}

_old_ver=''
if [ "$FORCE_REPAIR" = true ]; then
    _install_save_recovery || { echo '  ОШИБКА: не удалось сохранить копию, установка отменена' >&2; exit 1; }
elif [ -f "${_old}/mtproxyl.sh" ] && [ -f "${_INSTALL_ROOT}/lib/release.sh" ]; then
    source "${_INSTALL_ROOT}/lib/release.sh"
    VERSION=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "${_old}/mtproxyl.sh" | head -1)
    LIB_DIR="${INSTALL_DIR}/lib" TGBOT_DIR=/opt/mtproxyl-tgbot
    _TGBOT_FILES=()
    if [ -f "${LIB_DIR}/tgbot.sh" ]; then
        while IFS= read -r _file; do _TGBOT_FILES+=("$_file"); done < <(
            sed -n '/^_TGBOT_FILES=(/,/^)/{s/^ *"\(.*\)"$/\1/p}' "${LIB_DIR}/tgbot.sh")
    fi
    if _release_snapshot; then
        _old_ver="$VERSION"
    else
        echo '  ОШИБКА: не удалось сохранить рабочую копию, установка отменена' >&2
        echo '  Если прежнее обновление прервалось и код повреждён, повторите install.sh с --force' >&2
        exit 1
    fi
fi

_install_apply_files() {
    local root="$1" f
    for f in "${root}"/lib/*.sh; do
        [ -f "$f" ] || continue
        install -m 644 "$f" "${INSTALL_DIR}/lib/.$(basename "$f").new" \
            && mv -f "${INSTALL_DIR}/lib/.$(basename "$f").new" "${INSTALL_DIR}/lib/$(basename "$f")" || return 1
    done
    if [ -f "${root}/version" ]; then
        install -m 644 "${root}/version" "${INSTALL_DIR}/.version.new" \
            && mv -f "${INSTALL_DIR}/.version.new" "${INSTALL_DIR}/version" || return 1
    fi
    [ ! -f "${root}/mtproxyl.sh" ] || {
        install -m 755 "${root}/mtproxyl.sh" "${INSTALL_DIR}/.mtproxyl.sh.new" \
            && mv -f "${INSTALL_DIR}/.mtproxyl.sh.new" "${INSTALL_DIR}/mtproxyl.sh" || return 1
    }
}
if ! _install_apply_files "$_INSTALL_ROOT"; then
    echo '  ОШИБКА: замена прервалась, восстанавливаем прежний код' >&2
    for _file in "${_INSTALL_ROOT}"/lib/*.sh; do
        [ -f "${_old}/lib/$(basename "$_file")" ] || rm -f "${INSTALL_DIR}/lib/$(basename "$_file")"
    done
    if ! _install_apply_files "$_old"; then
        echo "  ОШИБКА: восстановление не удалось, копия: ${_old}" >&2
        _INSTALL_STAGE=''
    fi
    exit 1
fi
if [ -n "$_old_ver" ] && [ "$_old_ver" != "$_new_ver" ]; then
    printf '%s\n' "$_old_ver" > "${INSTALL_DIR}/releases/previous"
fi
if [ -n "$_INSTALL_ARCHIVE" ]; then
    mkdir -p "${INSTALL_DIR}/releases"; chmod 700 "${INSTALL_DIR}/releases"
    mv -f "$_INSTALL_ARCHIVE" "${INSTALL_DIR}/releases/mtproxyl-${_new_ver}.tar.gz"
fi
if [ -x /opt/mtproxyl-tgbot/venv/bin/python ] && [ -d "${_INSTALL_ROOT}/mtproxyl-tgbot/bot" ]; then
    MTPROXYL_TGBOT_SRC="${_INSTALL_ROOT}/mtproxyl-tgbot" "${INSTALL_DIR}/mtproxyl.sh" tgbot update \
        || echo '  Бот: повторите mtproxyl tgbot update' >&2
fi
_install_cleanup

# Ветку запоминаем, только если она не релизная: тогда и обновления
# продолжат приходить из неё же.
if [ "$BRANCH" = "main" ]; then
    rm -f "${INSTALL_DIR}/.branch"
else
    echo "$BRANCH" > "${INSTALL_DIR}/.branch"
    chmod 600 "${INSTALL_DIR}/.branch"
    echo "  → обновления будут браться из ветки ${BRANCH}"
fi

# Симлинк
ln -sf "${INSTALL_DIR}/mtproxyl.sh" /usr/local/bin/mtproxyl

# ── Алиас mtproxyl → sudo mtproxyl ───────────────────────────────────────────
# Для root не определяется: условие проверяется при запуске шелла, а не
# установки — один файл читают и root, и обычный пользователь.
ALIAS_MARK="# MTProxyL: запуск без ручного sudo"
ALIAS_BODY='if [ "$(id -u)" -ne 0 ]; then alias mtproxyl='"'"'sudo mtproxyl'"'"'; fi'

add_alias_to_rc() {
    local rc="$1" owner="$2"
    [ -f "$rc" ] || return 0
    grep -qF "$ALIAS_MARK" "$rc" 2>/dev/null && return 0
    {
        echo ""
        echo "$ALIAS_MARK"
        echo "$ALIAS_BODY"
    } >> "$rc" || return 0
    [ -n "$owner" ] && chown "$owner" "$rc" 2>/dev/null || true
    echo "  → алиас добавлен в ${rc}"
}

# Всем будущим сессиям: /etc/profile.d читают логин-шеллы, в том числе ssh.
cat > /etc/profile.d/mtproxyl.sh << PROFILE_EOF
${ALIAS_MARK}
${ALIAS_BODY}
PROFILE_EOF
chmod 644 /etc/profile.d/mtproxyl.sh

# Тому, кто прямо сейчас запустил установку через sudo, — ещё и в его rc,
# чтобы 'source ~/.bashrc' в текущей сессии сразу дал результат.
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    _u_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    if [ -n "$_u_home" ] && [ -d "$_u_home" ]; then
        _u_group=$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")
        add_alias_to_rc "${_u_home}/.bashrc" "${SUDO_USER}:${_u_group}"
        add_alias_to_rc "${_u_home}/.zshrc" "${SUDO_USER}:${_u_group}"
    fi
fi

echo ""
echo "  ✓ MTProxyL установлен"
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    echo "  Запуск: mtproxyl  (алиас на 'sudo mtproxyl')"
    echo "  В текущей сессии он появится после: source ~/.bashrc"
else
    echo "  Запуск: mtproxyl"
fi
echo ""

# Автозапуск. Если скрипт запускали через пайп или подстановку процесса,
# stdin у нас не терминал — интерактивное меню в таком случае сразу
# «проваливается». Возвращаем ввод на терминал, пока он есть.
if [ -f "${INSTALL_DIR}/settings.conf" ] && grep -q '^warp_refresh()' "${INSTALL_DIR}/lib/warp.sh"; then
    "${INSTALL_DIR}/mtproxyl.sh" warp refresh || echo "  WARP: выполните mtproxyl warp refresh после установки"
fi
if [ ${#INSTALL_ARGS[@]} -gt 0 ]; then
    exec /usr/local/bin/mtproxyl install "${INSTALL_ARGS[@]}"
fi

if [ ! -t 0 ] && [ -e /dev/tty ]; then
    exec < /dev/tty || true
fi
exec /usr/local/bin/mtproxyl
