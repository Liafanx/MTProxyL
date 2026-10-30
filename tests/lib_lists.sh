#!/bin/bash
# Списки библиотек в mtproxyl.sh и install.sh должны
# совпадать с lib/*.sh: забытая библиотека ломает установку и обновление.
set -u
cd "$(dirname "$0")/.." || exit 1
want=$(ls lib/*.sh | sed 's#lib/##; s#\.sh$##' | sort)
fail=0
check() {
    local name="$1" list="$2" got
    got=$(tr ' ' '\n' <<< "$list" | sed '/^$/d' | sort)
    if [ "$got" != "$want" ]; then
        echo "FAIL ${name}: расходится с lib/*.sh"
        diff <(echo "$want") <(echo "$got") | sed 's/^/    /'
        fail=1
    fi
}
check mtproxyl.sh "$(grep -oP '^for _lib in \K[^;]+' mtproxyl.sh | head -1)"
check install.sh "$(grep -oP '^for lib in \K[^;]+' install.sh | head -1)"
[ "$fail" = 0 ] && echo "OK списки библиотек совпадают"
exit "$fail"
