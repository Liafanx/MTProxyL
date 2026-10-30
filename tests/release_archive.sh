#!/bin/bash
# Обновление из архива: сборка, проверка, снимок, подмена и откат — без сети.
set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d /tmp/mtproxyl-release.XXXXXX)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

INSTALL_DIR="$t/inst"; LIB_DIR="$INSTALL_DIR/lib"; GITHUB_REPO="x/y"; GITHUB_BRANCH=main
TGBOT_DIR="$t/nobot"
mkdir -p "$LIB_DIR"
BOLD="" DIM="" NC="" GREEN="" YELLOW="" RED="" BLUE=""
source "$repo/lib/release.sh"
log_info() { :; }; log_success() { :; }; log_warn() { :; }; log_error() { echo "  err: $*" >&2; }
_TGBOT_FILES=()

# Две версии из рабочего дерева: «старая» установлена, «новая» — в архиве.
cur=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$repo/mtproxyl.sh")
VERSION="9.0.0"
cp "$repo/mtproxyl.sh" "$INSTALL_DIR/mtproxyl.sh"
sed -i "s/^VERSION=\".*\"/VERSION=\"$VERSION\"/" "$INSTALL_DIR/mtproxyl.sh"
cp "$repo"/lib/*.sh "$LIB_DIR/"
echo "# old" >> "$LIB_DIR/colors.sh"

"$repo/.github/scripts/mtproxyl-archive.sh" build "$repo" "$cur" "$t/dist" >/dev/null || fail "сборка архива"
_release_url() { echo "file://$t/dist/mtproxyl-$1.tar.gz"; }

_release_download "$cur" || fail "скачивание"
[ -f "$(_release_cached "$cur")" ] || fail "архив не в кэше"
_release_unpack "$(_release_cached "$cur")" "$cur" || fail "распаковка"
root=$(_release_root)
[ "$(_release_check "$root")" = "$cur" ] || fail "версия в архиве"

_release_snapshot || fail "снимок"
[ -f "$(_release_local 9.0.0)" ] || fail "нет снимка"
_release_apply "$root" || fail "подмена"
_release_stage_cleanup
grep -q "^VERSION=\"$cur\"" "$INSTALL_DIR/mtproxyl.sh" || fail "mtproxyl.sh не заменён"
grep -q '# old' "$LIB_DIR/colors.sh" && fail "lib не заменена"
[ -z "$(ls -A "$INSTALL_DIR" | grep release-stage)" ] || fail "не убран каталог распаковки"

# Откат из снимка возвращает ровно прежний код.
_release_unpack "$(_release_local 9.0.0)" 9.0.0 || fail "распаковка снимка"
_release_apply "$(_release_root)" || fail "откат"
_release_stage_cleanup
grep -q '^VERSION="9.0.0"' "$INSTALL_DIR/mtproxyl.sh" || fail "откат mtproxyl.sh"
grep -q '# old' "$LIB_DIR/colors.sh" || fail "откат lib"

# Подделанный архив: сумма не сходится.
cp "$t/dist/mtproxyl-$cur.tar.gz" "$t/good.tgz"
echo junk >> "$t/dist/mtproxyl-$cur.tar.gz"
rm -f "$(_release_cached "$cur")"
_release_download "$cur" 2>/dev/null && fail "принят архив с чужой суммой"
cp "$t/good.tgz" "$t/dist/mtproxyl-$cur.tar.gz"

# Файл мимо каталога версии и символьная ссылка — отказ.
mkdir -p "$t/evil/mtproxyl-$cur" && echo x > "$t/evil/evil.sh"
ln -s /etc "$t/evil/mtproxyl-$cur/etc"
tar -czf "$t/evil1.tgz" -C "$t/evil" evil.sh "mtproxyl-$cur" 2>/dev/null
_release_unpack "$t/evil1.tgz" "$cur" 2>/dev/null && fail "принят файл вне каталога"
tar -czf "$t/evil2.tgz" -C "$t/evil" "mtproxyl-$cur" 2>/dev/null
_release_unpack "$t/evil2.tgz" "$cur" 2>/dev/null && fail "принята ссылка"

# Испорченная библиотека после сборки — суммы внутри не сходятся.
mkdir -p "$t/bad" && tar -xzf "$t/good.tgz" -C "$t/bad"
echo 'if' >> "$t/bad/mtproxyl-$cur/lib/utils.sh"
tar -czf "$t/bad.tgz" -C "$t/bad" "mtproxyl-$cur"
_release_unpack "$t/bad.tgz" "$cur" 2>/dev/null && fail "принят архив с изменённым файлом"

# Одинаковый код под другим номером — CI откажет.
"$repo/.github/scripts/mtproxyl-archive.sh" same "$t/good.tgz" "$t/good.tgz" || fail "same на одном архиве"
"$repo/.github/scripts/mtproxyl-archive.sh" same "$t/good.tgz" "$t/bad.tgz" && fail "same не заметил разницу"

# Чистка: последние RELEASE_KEEP, текущая и прошлая остаются.
RELEASE_KEEP=1
for v in 1.0.1 1.0.2 1.0.3; do touch "$RELEASE_CACHE_DIR/mtproxyl-$v.tar.gz"; sleep 0.01; done
touch -d '2000-01-01' "$(_release_local 9.0.0)"
_release_prune 1.0.1 9.0.0
[ -f "$RELEASE_CACHE_DIR/mtproxyl-1.0.1.tar.gz" ] || fail "удалена текущая"
[ -f "$(_release_local 9.0.0)" ] || fail "удалена прошлая"
[ -f "$RELEASE_CACHE_DIR/mtproxyl-1.0.3.tar.gz" ] || fail "удалена свежая"
[ -f "$RELEASE_CACHE_DIR/mtproxyl-1.0.2.tar.gz" ] && fail "лишняя не удалена"

echo "OK release_archive"
