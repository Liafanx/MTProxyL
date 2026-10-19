#!/bin/bash
# Быстрые пути для больших баз: разбор secrets.conf одним awk и
# форматирование без форков дают то же, что прежние циклы bash.
# Проверяется на всех awk, что есть в системе (gawk, mawk, busybox).
set -u
cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/secrets.conf" <<'EOF'
# заголовок
  # комментарий с отступом

good1|0123456789abcdef0123456789ABCDEF|1700000000|true|5|3|1000|2026-12-21T23:59:59Z|note 'q' \b $x `y`	tab||100:200
good2|0123456789abcdef0123456789abcdef|abc|maybe|x|y|z|garbage|n2|0123456789abcdef0123456789abcdef|1:2|extra
good3|0123456789abcdef0123456789abcdef||false|||||||
bad label|0123456789abcdef0123456789abcdef|1|true
short|0123|1|true
nosecret||1|true
good4|0123456789abcdef0123456789abcdef|1|true|0|0|0|2026-01-01|||
good5|0123456789abcdef0123456789abcdef
good6|0123456789abcdef0123456789abcdef|1|true|0|0|0|0|n|zz|5:5
EOF

fail=0
for impl in gawk mawk "busybox awk"; do
    command -v ${impl%% *} >/dev/null 2>&1 || continue
    out=$(IMPL="$impl" SECRETS_FILE="$TMP/secrets.conf" bash -c '
        awk() { $IMPL "$@"; }
        source lib/utils.sh 2>/dev/null; source lib/secrets.sh 2>/dev/null
        unset EPOCHSECONDS
        dump() { local a; for a in LABELS KEYS CREATED ENABLED MAX_CONNS MAX_IPS QUOTA EXPIRES NOTES ADTAG RATE; do
            declare -n r=SECRETS_$a; printf "%s=" $a; printf "[%s]" "${r[@]}"; echo; done; }
        date() { echo 1800000000; }
        load_secrets; dump > "'"$TMP"'/new"
        _load_secrets_awk() { return 1; }
        load_secrets; dump > "'"$TMP"'/old"
        cmp -s "'"$TMP"'/old" "'"$TMP"'/new" && echo SAME')
    if [ "$out" = "SAME" ]; then echo "OK load_secrets ($impl)"; else echo "FAIL load_secrets ($impl)"; diff "$TMP/old" "$TMP/new"; fail=1; fi
done

old_fb() {
    local bytes=$1
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} Б"
    elif [ "$bytes" -lt 1048576 ]; then echo "$(awk -v b="$bytes" 'BEGIN {printf "%.1f", b/1024}') КБ"
    elif [ "$bytes" -lt 1073741824 ]; then echo "$(awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1048576}') МБ"
    else echo "$(awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1073741824}') ГБ"; fi
}
source lib/utils.sh 2>/dev/null
for b in 0 5 1023 1024 1536 52428 104857 1048575 1048576 5000000 1073741823 1073741824 4552106981 10737418240 999999999999 1099511627776; do
    [ "$(format_bytes "$b")" = "$(old_fb "$b")" ] || { echo "FAIL format_bytes $b: $(format_bytes "$b") != $(old_fb "$b")"; fail=1; }
done
[ "$fail" = 0 ] && echo "OK format_bytes"
exit "$fail"
