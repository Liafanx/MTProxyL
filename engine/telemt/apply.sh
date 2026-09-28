#!/bin/bash
# apply.sh <тег или коммит telemt> <каталог набора патчей> <каталог исходников>
set -euo pipefail

ref="$1"
set_dir=$(cd "$2" && pwd)
dst="$3"

git clone --quiet https://github.com/telemt/telemt "$dst"
cd "$dst"
git checkout --quiet "$ref"

mapfile -t patches < <(grep -v '^[[:space:]]*\(#\|$\)' "${set_dir}/series")
for p in "${patches[@]}"; do
    if ! git -c user.name=mtproxyl -c user.email=build@mtproxyl.local am --quiet --3way "${set_dir}/${p}"; then
        echo "::error title=Патч не наложился::${p} на telemt ${ref}"
        git am --show-current-patch=diff | head -40 || true
        git status --short | sed 's/^/::error title=Конфликт::/' | head -10
        exit 1
    fi
    echo "Наложен: ${p}"
done
git log --oneline -n "$(( ${#patches[@]} + 1 ))"
