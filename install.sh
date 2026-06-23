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
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/dev"

if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите от root:" >&2
    echo "  wget -qO /tmp/mtproxyl-install.sh https://raw.githubusercontent.com/${REPO}/main/install.sh && sudo bash /tmp/mtproxyl-install.sh" >&2
    exit 1
fi

echo ""
echo "  MTProxyL — установка"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

mkdir -p "${INSTALL_DIR}/lib" "${INSTALL_DIR}/mtproxy" "${INSTALL_DIR}/backups"

echo "  Скачивание файлов..."

# Главный скрипт
echo "  → mtproxyl.sh"
if ! curl -fsSL --max-time 30 "${SCRIPT_URL}/mtproxyl.sh" -o "${INSTALL_DIR}/mtproxyl.sh"; then
    echo "  ОШИБКА: Не удалось скачать mtproxyl.sh" >&2
    echo "  Проверьте интернет и доступность github.com" >&2
    exit 1
fi
chmod +x "${INSTALL_DIR}/mtproxyl.sh"

# Библиотеки
for lib in colors utils settings secrets config docker engine traffic geoblock upstream backup nft tui_main tui_proxy tui_secrets tui_links tui_settings tui_security tui_traffic tui_engine tui_backup tui_expert tui_nft install; do
    echo "  → lib/${lib}.sh"
    if ! curl -fsSL --max-time 30 "${SCRIPT_URL}/lib/${lib}.sh" -o "${INSTALL_DIR}/lib/${lib}.sh"; then
        echo "  ОШИБКА: Не удалось скачать lib/${lib}.sh" >&2
        exit 1
    fi
done

# Симлинк
ln -sf "${INSTALL_DIR}/mtproxyl.sh" /usr/local/bin/mtproxyl

echo ""
echo "  ✓ MTProxyL установлен"
echo "  Запуск: mtproxyl"
echo ""

# Автозапуск
exec /usr/local/bin/mtproxyl
