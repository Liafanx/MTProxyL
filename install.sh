#!/bin/bash
# MTProxyL — быстрая установка
# curl -fsSL https://raw.githubusercontent.com/Liafanx/MTProxyL/main/install.sh | sudo bash

# Защита stdin при curl | bash — ДОЛЖНА БЫТЬ ПЕРВОЙ
if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
    exec < /dev/tty
fi

set -e

REPO="Liafanx/MTProxyL"
INSTALL_DIR="/opt/mtproxyl"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/main"

if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите от root: curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo bash" >&2
    exit 1
fi

echo ""
echo "  MTProxyL — установка"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Создаём структуру директорий
mkdir -p "${INSTALL_DIR}/lib" "${INSTALL_DIR}/mtproxy" "${INSTALL_DIR}/backups"

echo "  Скачивание файлов..."

# Главный скрипт
if ! curl -fsSL --max-time 30 "${SCRIPT_URL}/mtproxyl.sh" -o "${INSTALL_DIR}/mtproxyl.sh"; then
    echo "  ОШИБКА: Не удалось скачать mtproxyl.sh" >&2
    exit 1
fi
chmod +x "${INSTALL_DIR}/mtproxyl.sh"

# Библиотеки
for lib in colors utils settings secrets config docker engine traffic geoblock upstream backup nft tui install; do
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
echo ""

# Запуск главного скрипта
exec "${INSTALL_DIR}/mtproxyl.sh"
