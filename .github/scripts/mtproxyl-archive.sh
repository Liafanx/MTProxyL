#!/bin/bash
# Архив релиза MTProxyL: то, что скрипт ставит на сервер, одним файлом.
#   mtproxyl-archive.sh build <каталог исходников> <версия> <куда положить>
#   mtproxyl-archive.sh same <архив A> <архив B>   — 0, если код одинаковый
set -euo pipefail

# Файлы из git, а не всё подряд: в рабочем каталоге раннера бывает мусор.
_files() {
    git -C "$1" ls-files -- mtproxyl.sh version install.sh LICENSE 'lib/*.sh' \
        mtproxyl-tgbot/requirements.txt 'mtproxyl-tgbot/bot/*.py'
}

build() {
    local src="$1" ver="$2" out="$3" tmp root f
    [[ "$ver" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "Неверная версия: $ver" >&2; return 1; }
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    root="$tmp/mtproxyl-$ver"
    mkdir -p "$root"
    while IFS= read -r f; do
        mkdir -p "$root/$(dirname "$f")"
        cp "$src/$f" "$root/$f"
    done < <(_files "$src")
    [ -f "$root/mtproxyl.sh" ] || { echo "Нет mtproxyl.sh в $src" >&2; return 1; }
    local sv; sv=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$root/mtproxyl.sh" | head -1)
    [ "$sv" = "$ver" ] || { echo "VERSION в mtproxyl.sh = $sv, ждали $ver" >&2; return 1; }
    while IFS= read -r f; do bash -n "$root/$f" || { echo "Синтаксис: $f" >&2; return 1; }; done \
        < <(cd "$root" && find . -name '*.sh' -printf '%P\n')
    (cd "$root" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum > SHA256SUMS)
    mkdir -p "$out"
    local arc="$out/mtproxyl-$ver.tar.gz"
    # Одинаковые владелец и время: архив зависит только от содержимого.
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='@0' \
        -C "$tmp" -czf "$arc" "mtproxyl-$ver"
    (cd "$out" && sha256sum "mtproxyl-$ver.tar.gz" > "mtproxyl-$ver.tar.gz.sha256")
    echo "$arc"
}

# Код без номера версии: строка VERSION= и файл version не в счёт.
_normalized() {
    local arc="$1" dir="$2" root
    tar -xzf "$arc" -C "$dir"
    root=$(find "$dir" -mindepth 1 -maxdepth 1 -type d | head -1)
    rm -f "$root/version" "$root/SHA256SUMS"
    sed -i '/^VERSION="/d' "$root/mtproxyl.sh"
    echo "$root"
}

same() {
    local a b ra rb
    a=$(mktemp -d); b=$(mktemp -d); trap 'rm -rf "$a" "$b"' RETURN
    ra=$(_normalized "$1" "$a"); rb=$(_normalized "$2" "$b")
    diff -rq "$ra" "$rb" >/dev/null
}

case "${1:-}" in
    build) shift; build "$@" ;;
    same)  shift; same "$@" ;;
    *) echo "Использование: $0 build <src> <версия> <out> | same <A> <B>" >&2; exit 2 ;;
esac
