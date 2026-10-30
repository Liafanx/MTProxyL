#!/bin/bash
# Сводка для issue: адреса, ключи, токены и свои домены не утекают.
set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
INSTALL_DIR="$t"; VERSION=test
source "$repo/lib/colors.sh"; source "$repo/lib/utils.sh"; source "$repo/lib/report.sh"
fail() { echo "FAIL: $*"; cat "$t/r"; exit 1; }
CUSTOM_IP=203.0.113.7 SERVER_IPS="198.51.100.1,198.51.100.2" PROXY_DOMAIN=proxy.example.net
SELFMASK_DOMAIN=site.example.org
cat > "$t/r" <<'TXT'
peer 192.0.2.44:51234 closed
v6 2001:db8::1 and [2001:db8:0:1::5]:443
key 0123456789abcdef0123456789abcdef secret ee0123456789abcdef0123456789abcdef7777772e676f
bot 1234567890:AAEhBOweik6ad9r_QXMENQjcrGbqCdK_abc
link tg://proxy?server=x&port=443&secret=dd00 next
host proxy.example.net and site.example.org, 203.0.113.7, 198.51.100.2
time 2026-10-30T12:34:56 version 1.7.18 port 443
TXT
_report_mask "$t/r"
grep -qE '192\.0\.2|2001:db8|0123456789abcdef|AAEhBO|tg://|example\.(net|org)|203\.0|198\.51' "$t/r" && fail "утечка"
grep -q '2026-10-30T12:34:56' "$t/r" || fail "время испорчено"
grep -q 'version 1.7.18 port 443' "$t/r" || fail "версия испорчена"
echo "OK report_mask"
