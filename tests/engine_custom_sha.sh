#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-engine-custom.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir/opt"
CONFIG_DIR="$test_dir/config"
SETTINGS_FILE="$test_dir/settings.conf"
VERSION=test
BLUE="" GREEN="" YELLOW="" RED="" NC="" BOLD="" DIM=""
SYM_CHECK="+" SYM_WARN="!" SYM_CROSS="x"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

# shellcheck source=/dev/null
source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"
source "$repo/lib/binengine.sh"

command -v gcc >/dev/null || { echo "Нет gcc — тест пропущен"; exit 0; }
fails() { if "$@" >/dev/null 2>&1; then echo "Должно было не пройти: $*" >&2; exit 1; fi; }

# Поддельный telemt: настоящий ELF, отвечает на --version.
mkdir -p "$test_dir/src"
printf '#include <stdio.h>\nint main(void){puts("telemt 3.5.7");return 0;}\n' > "$test_dir/src/t.c"
gcc -o "$test_dir/src/telemt" "$test_dir/src/t.c"
tar czf "$test_dir/src/telemt.tar.gz" -C "$test_dir/src" telemt
tar_sha=$(sha256sum "$test_dir/src/telemt.tar.gz" | awk '{print $1}')

# curl отдаёт локальные файлы. На <ссылка>.sha256 — чужой хеш: если его
# запросят и сверят, установка без хеша упадёт.
curl_log="$test_dir/curl.log"
curl() {
    local _out="" _url=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -o) _out="$2"; shift ;;
            https://*) _url="$1" ;;
        esac
        shift
    done
    echo "$_url" >> "$curl_log"
    case "$_url" in
        *.sha256) printf '%064d  x\n' 0 > "$_out" ;;
        *.tar.gz) cp "$test_dir/src/telemt.tar.gz" "$_out" ;;
        *) cp "$test_dir/src/telemt" "$_out" ;;
    esac
}
binengine_state() { echo absent; }

url_bin=https://example.com/dl/telemt
url_tar=https://example.com/dl/telemt.tar.gz

# Без хеша: ставится, хеш не сохраняется, .sha256 не запрашивается.
binengine_install_custom "$url_bin" >/dev/null
[ "$ENGINE_CUSTOM_URL" = "$url_bin" ]
[ -z "$ENGINE_CUSTOM_SHA256" ]
[ "$(cat "$ENGINE_VERSION_FILE")" = "3.5.7-custom" ]
if grep -q '\.sha256$' "$curl_log"; then echo "Запрошен .sha256" >&2; exit 1; fi

# С верным хешем: сверяется и сохраняется.
binengine_install_custom "$url_tar" "${tar_sha^^}" >/dev/null
[ "$ENGINE_CUSTOM_URL" = "$url_tar" ]
[ "$ENGINE_CUSTOM_SHA256" = "$tar_sha" ]
[ "$(binengine_source)" = "$url_tar" ]

# Чужой хеш и мусор вместо хеша — отказ, установленное не трогается.
fails binengine_install_custom "$url_tar" "$(printf '%064d' 1)"
fails binengine_install_custom "$url_tar" nothex
[ "$ENGINE_CUSTOM_SHA256" = "$tar_sha" ]

# Откат возвращает прежний источник и сбрасывает хеш.
binengine_rollback --yes >/dev/null
[ "$ENGINE_CUSTOM_URL" = "$url_bin" ]
[ -z "$ENGINE_CUSTOM_SHA256" ]

echo "engine_custom_sha: ok"
