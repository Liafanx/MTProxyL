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
# Аргументы после «--» уходят установщику: переезд на новый сервер одной строкой.
INSTALL_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--branch)
            [ -n "${2:-}" ] || { echo "ОШИБКА: --branch требует имя ветки" >&2; exit 1; }
            BRANCH="$2"; shift 2 ;;
        --branch=*) BRANCH="${1#*=}"; shift ;;
        -h|--help)
            echo "Использование: install.sh [--branch <ветка>] [-- <аргументы установки>]"
            echo "  Всё после -- уходит в 'mtproxyl install' — установка без вопросов."
            echo "  Список аргументов: mtproxyl install --help"
            exit 0 ;;
        --) shift; INSTALL_ARGS=("$@"); break ;;
        *) echo "ОШИБКА: неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
INSTALL_LOG="/tmp/mtproxyl-install.log"

download_file() {
    local url="$1"
    local dest="$2"
    local label="$3"

    local tmp
    tmp=$(mktemp "/tmp/.mtproxyl-download.XXXXXX") || {
        echo "  ОШИБКА: Не удалось создать временный файл для ${label}" >&2
        return 1
    }

    # Несколько попыток скачать файл
    if curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --max-time 45 "$url" -o "$tmp" 2>>"$INSTALL_LOG"; then
        # Для shell-файлов дополнительно проверяем синтаксис
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
    else
        rm -f "$tmp"
        echo "  ОШИБКА: Не удалось скачать ${label}" >&2
        echo "  Подробности: ${INSTALL_LOG}" >&2
        return 1
    fi
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

echo "  Скачивание файлов..."

# Главный скрипт
echo "  → mtproxyl.sh"
if ! download_file "${SCRIPT_URL}/mtproxyl.sh" "${INSTALL_DIR}/mtproxyl.sh" "mtproxyl.sh"; then
    echo "  Проверьте интернет, лимиты GitHub Raw и доступность github.com" >&2
    echo "  Подробности: ${INSTALL_LOG}" >&2
    exit 1
fi
chmod +x "${INSTALL_DIR}/mtproxyl.sh"

# Библиотеки
for lib in colors utils settings secrets config docker binengine engine traffic availability dc warp geoblock geoip upstream backup nft selfmask panel tgbot detect tui_main tui_proxy tui_secrets tui_links tui_settings tui_security tui_traffic tui_engine tui_backup tui_expert tui_nft tui_selfmask tui_addons tui_tgbot tui_warp tui_detect expert_catalog expert_mode settings_cli install install_args migrate argsgen; do
    echo "  → lib/${lib}.sh"
    if ! download_file "${SCRIPT_URL}/lib/${lib}.sh" "${INSTALL_DIR}/lib/${lib}.sh" "lib/${lib}.sh"; then
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
if [ ${#INSTALL_ARGS[@]} -gt 0 ]; then
    exec /usr/local/bin/mtproxyl install "${INSTALL_ARGS[@]}"
fi

if [ ! -t 0 ] && [ -e /dev/tty ]; then
    exec < /dev/tty || true
fi
exec /usr/local/bin/mtproxyl
