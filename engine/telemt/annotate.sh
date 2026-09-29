#!/bin/bash
# annotate.sh <лог>... — ошибки сборки и тестов в аннотации GitHub: так их
# видно без доступа к логам. По 10 на уровень, всего до 30 строк.
set -uo pipefail

esc() { local s="$1"; s="${s//'%'/%25}"; s="${s//$'\r'/%0D}"; printf '%s' "${s//$'\n'/%0A}"; }

mapfile -t lines < <(
    cat "$@" 2>/dev/null | awk '
        /: error(\[E[0-9]+\])?: / { print; next }
        /^error(\[E[0-9]+\])?: / { e = $0; getline n; print e " " n; next }
        /panicked at / { p = $0; getline m; print p " — " m; next }
        /^test .* FAILED$/ { print; next }
        /^    [a-z_:]+$/ && failures { print "FAILED " $0; next }
        /^failures:$/ { failures = 1 }
        /^test result: FAILED/ { print; failures = 0 }
    ' | awk '!seen[$0]++' | head -30
)
[ "${#lines[@]}" -gt 0 ] || { echo "::error::Сборка упала, строк с ошибками в логе нет"; tail -20 "$@" 2>/dev/null; exit 0; }
for i in "${!lines[@]}"; do
    if [ "$i" -lt 10 ]; then lvl=error; elif [ "$i" -lt 20 ]; then lvl=warning; else lvl=notice; fi
    echo "::${lvl}::$(esc "${lines[$i]}")"
done
