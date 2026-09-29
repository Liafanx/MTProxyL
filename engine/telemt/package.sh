#!/bin/bash
# package.sh <бинарник> <имя ассета> <target> — архив и sha256 как у релизов telemt
set -euo pipefail

bin="$1" asset="$2" target="$3"
case "$target" in
    aarch64-unknown-linux-gnu)  strip_bin=aarch64-linux-gnu-strip ;;
    aarch64-unknown-linux-musl) strip_bin=aarch64-linux-musl-strip ;;
    *)                          strip_bin=strip ;;
esac

mkdir -p dist
cp "$bin" dist/telemt
"$strip_bin" dist/telemt
cd dist
tar -czf "${asset}.tar.gz" --owner=0 --group=0 --numeric-owner telemt
rm -f telemt
sha256sum "${asset}.tar.gz" > "${asset}.tar.gz.sha256"
cat "${asset}.tar.gz.sha256"
