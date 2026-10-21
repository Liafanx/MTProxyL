#!/bin/bash
# Проверка бэкапа перед восстановлением под pipefail: годный архив не должен
# считаться негодным, битый и без settings.conf — должны.
set -uo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir/install"
mkdir -p "$INSTALL_DIR" "$test_dir/src/relay_stats"
source lib/backup.sh
YELLOW=""; BOLD=""; NC=""
log_error() { printf 'ERR %s\n' "$*"; }
log_info() { :; }
read_line() { printf -v "$1" '%s' "no"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

# Длинный список файлов: tar успевает писать после выхода grep -q.
echo "PROXY_PORT='443'" > "$test_dir/src/settings.conf"
for i in $(seq 1 3000); do : > "$test_dir/src/relay_stats/u$i"; done
tar czf "$test_dir/good.tar.gz" -C "$test_dir/src" settings.conf relay_stats
for i in $(seq 1 20); do
    out=$(restore_backup "$test_dir/good.tar.gz")
    [[ "$out" != *ERR* ]] || fail "годный бэкап отвергнут: $out"
done

tar czf "$test_dir/nosettings.tar.gz" -C "$test_dir/src" relay_stats
[[ $(restore_backup "$test_dir/nosettings.tar.gz") == *"нет settings.conf"* ]] || fail 'архив без settings.conf принят'

head -c 4000 "$test_dir/good.tar.gz" > "$test_dir/broken.tar.gz"
[[ $(restore_backup "$test_dir/broken.tar.gz") == *"повреждён"* ]] || fail 'битый архив принят'

echo "backup restore: ok"
