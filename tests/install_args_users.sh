#!/bin/bash
# Перенос аргументами: пользователи с лимитами переезжают через --user
# строкой secrets.conf и разбираются обратно без потерь.
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
for f in lib/*.sh; do source "$f" >/dev/null 2>&1; done
set -o pipefail
log_error() { printf 'ERR %s\n' "$*"; }
log_info() { :; }; log_success() { :; }; log_warn() { :; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

SECRETS_LABELS=(plain limited off)
SECRETS_KEYS=(0123456789abcdef0123456789abcdef 11112222333344445555666677778888 aaaabbbbccccddddeeeeffff00001111)
SECRETS_CREATED=(1700000000 1700000001 1700000002)
SECRETS_ENABLED=(true true false)
SECRETS_MAX_CONNS=(0 5 0); SECRETS_MAX_IPS=(0 2 0); SECRETS_QUOTA=(0 10737418240 0)
SECRETS_EXPIRES=(0 2027-01-31T23:59:59Z 0)
SECRETS_NOTES=("" "Иван \"VIP\" \$100 it's" "")
SECRETS_ADTAG=("" 89abcdef0123456789abcdef01234567 ""); SECRETS_RATE=("" "10:20" "")

want=$(for i in 1 2; do echo "${SECRETS_LABELS[$i]}|${SECRETS_KEYS[$i]}|${SECRETS_CREATED[$i]}|${SECRETS_ENABLED[$i]}|${SECRETS_MAX_CONNS[$i]}|${SECRETS_MAX_IPS[$i]}|${SECRETS_QUOTA[$i]}|${SECRETS_EXPIRES[$i]}|${SECRETS_NOTES[$i]}|${SECRETS_ADTAG[$i]}|${SECRETS_RATE[$i]}"; done)

declare -A _AG_ON=([secrets]=yes) _AG_VAL=()
cmd=$(_argsgen_build)
[[ "$cmd" == *"--secret plain:0123456789abcdef0123456789abcdef"* ]] || fail "plain не через --secret: $cmd"
[ "$(grep -o -- '--user ' <<< "$cmd" | wc -l)" -eq 2 ] || fail "ждали два --user: $cmd"

eval "args=($cmd)"
_IA_SECRETS=()
_install_args_parse "${args[@]}" >/dev/null 2>&1 || fail 'разбор не прошёл'
out=$(_install_args_validate 2>&1) || fail "проверка не прошла: $out"
_install_args_secrets
got=$(for i in 1 2; do echo "${SECRETS_LABELS[$i]}|${SECRETS_KEYS[$i]}|${SECRETS_CREATED[$i]}|${SECRETS_ENABLED[$i]}|${SECRETS_MAX_CONNS[$i]}|${SECRETS_MAX_IPS[$i]}|${SECRETS_QUOTA[$i]}|${SECRETS_EXPIRES[$i]}|${SECRETS_NOTES[$i]}|${SECRETS_ADTAG[$i]}|${SECRETS_RATE[$i]}"; done)
[ "$got" = "$want" ] || fail "после переноса: $got"
[ "${SECRETS_LABELS[0]}" = plain ] && [ "${SECRETS_MAX_CONNS[0]}" = 0 ] || fail 'plain потерян'

_IA_SECRETS=('bad|nothex')
[[ $(_install_args_validate 2>&1) == *"--user 'bad'"* ]] || fail 'кривой --user принят'
_IA_SECRETS=('a:0123456789abcdef0123456789abcdef' 'a|11112222333344445555666677778888|1700000000|true')
[[ $(_install_args_validate 2>&1) == *"задан дважды"* ]] || fail 'дубликат метки принят'

echo "install args users: ok"
