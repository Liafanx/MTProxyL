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
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/main"
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
echo ""
echo "  MTProxyL — установка"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
for lib in colors utils settings secrets config docker engine traffic geoblock upstream backup nft selfmask tui_main tui_proxy tui_secrets tui_links tui_settings tui_security tui_traffic tui_engine tui_backup tui_expert tui_nft tui_selfmask tui_addons expert_catalog expert_mode install; do
    echo "  → lib/${lib}.sh"
    if ! download_file "${SCRIPT_URL}/lib/${lib}.sh" "${INSTALL_DIR}/lib/${lib}.sh" "lib/${lib}.sh"; then
        echo "  Установка прервана. Повторите попытку через 10–30 секунд." >&2
        echo "  Подробности: ${INSTALL_LOG}" >&2
        exit 1
    fi
    sleep 0.2
done

# Симлинк
ln -sf "${INSTALL_DIR}/mtproxyl.sh" /usr/local/bin/mtproxyl

echo ""
echo "  ✓ MTProxyL установлен"
echo "  Запуск: mtproxyl"
echo ""

# Автозапуск
exec /usr/local/bin/mtproxyl
