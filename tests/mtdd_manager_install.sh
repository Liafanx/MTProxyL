#!/bin/bash
# Установка Manager с движком mtdd аргументами: отказ на то, чего у mtdd нет,
# «Перенос аргументами» и переезд на другой сервер дают команду, которую эта
# же установка принимает обратно; бинарник и имя службы выбираются как надо.
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
for f in lib/*.sh; do source "$f" >/dev/null 2>&1; done
set -o pipefail
log_error() { printf 'ERR %s\n' "$*"; }
log_info() { :; }; log_success() { :; }; log_warn() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
uname() { [ "${1:-}" = -m ] && echo x86_64 || command uname "$@"; }
systemctl() { return 1; }; useradd() { :; }
SETTINGS_FILE="$test_dir/settings.conf"; MTDD_CHANNEL_FILE="$test_dir/mtdd.channel"
TAG=0123456789abcdef0123456789abcdef

ia() {
    source lib/install_args.sh >/dev/null 2>&1
    _install_args_parse "$@" >/dev/null 2>&1 || { echo "PARSE"; return 1; }
    _install_args_validate 2>&1
}

# ── Проверки ────────────────────────────────────────────────
out=$(ia --mode manager --engine mtdd --ad-tag "$TAG") || fail "годный --engine mtdd отвергнут: $out"
source lib/install_args.sh >/dev/null 2>&1; _install_args_parse --engine mtdd --ad-tag "$TAG" >/dev/null 2>&1
[ "$_IA_ENGINE_KIND" = mtdd ] && [ -z "$_IA_ENGINE" ] || fail "--engine mtdd разобран как носитель"
out=$(ia --mode manager --engine mtdd) || fail "без --ad-tag отвергнуто: $out"
out=$(ia --mode manager --engine mtdd --ad-tag 00000000000000000000000000000000) && fail "нулевой тег принят"
for bad in "--engine-version 3.5.5" "--sni-policy drop" "--dc-restart 50" "--engine-url https://example.org/t"; do
    # shellcheck disable=SC2086
    out=$(ia --mode manager --engine mtdd --ad-tag "$TAG" $bad) && fail "принят ${bad}"
    [[ "$out" == *"у mtdd этого нет"* ]] || fail "${bad}: нет причины: $out"
done
out=$(ia --mode manager --engine mtdd --ad-tag "$TAG" --web yes --web-domain w.example.org) && fail "--web принят"
out=$(ia --mode manager --engine mtdd --ad-tag "$TAG" --proxy-mode combined --web-domain w.example.org) && fail "--proxy-mode combined принят"
out=$(ia --mode manager --engine mtdd --ad-tag "$TAG" --user "slow|${TAG}|1700000000|true|0|0|0|0|||4000:0") && fail "скорость 4000 бит/с принята"
[[ "$out" == *"8192"* ]] || fail "нет причины про скорость: $out"
out=$(ia --mode manager --engine mtdd --ad-tag "$TAG" --user "ok|${TAG}|1700000000|true|0|0|0|0|||16384:0") || fail "скорость 16384 отвергнута: $out"
out=$(ia --mode manager --engine binary --mtdd-channel dev) && fail "--mtdd-channel без --engine mtdd принят"
out=$(ia --mode manager --engine mtdd --ad-tag "$TAG" --mtdd-channel dev --service-name standard) || fail "канал и имя службы: $out"
uname() { [ "${1:-}" = -m ] && echo aarch64 || command uname "$@"; }
out=$(ia --mode manager --engine mtdd --ad-tag "$TAG") && fail "mtdd на aarch64 принят"
uname() { [ "${1:-}" = -m ] && echo x86_64 || command uname "$@"; }
# Установка поверх mtdd без --engine берёт тег из настроек.
AD_TAG="$TAG"
out=$(ia --mode manager --engine mtdd) || fail "тег из настроек не засчитан: $out"
AD_TAG=""

# ── Бинарник и имя службы ───────────────────────────────────
mtdd_mgr_fetch() { echo "$1" > "$test_dir/fetched"; }
binengine_random_name() { echo netrelayd; }
source lib/install_args.sh >/dev/null 2>&1
_install_args_parse --engine mtdd --ad-tag "$TAG" --mtdd-channel dev >/dev/null 2>&1
MTPROXYL_MODE=manager; MTDD_SERVICE_NAME=""; rm -f "$SETTINGS_FILE"
_install_args_engine_mtdd || fail "_install_args_engine_mtdd"
[ "$(cat "$test_dir/fetched")" = dev ] || fail "скачан не тот канал"
[ "$ENGINE_KIND" = mtdd ] && mtdd_mgr_active && [ "$MTDD_MGR_SERVICE" = netrelayd ] \
    || fail "новая установка: служба ${MTDD_MGR_SERVICE}, вид ${ENGINE_KIND}"
source lib/install_args.sh >/dev/null 2>&1
_install_args_parse --engine mtdd --ad-tag "$TAG" --service-name standard >/dev/null 2>&1
echo main > "$MTDD_CHANNEL_FILE"
_install_args_engine_mtdd || fail "standard"
[ "$MTDD_MGR_SERVICE" = mtproxyl-mtdd ] && [ "$(cat "$test_dir/fetched")" = main ] || fail "стандартное имя/канал из файла: $MTDD_MGR_SERVICE"
touch "$SETTINGS_FILE"; MTDD_SERVICE_NAME=oldname
source lib/install_args.sh >/dev/null 2>&1
_install_args_parse --engine mtdd --ad-tag "$TAG" >/dev/null 2>&1
_install_args_engine_mtdd; [ "$MTDD_MGR_SERVICE" = oldname ] || fail "прежнее имя службы не сохранено: $MTDD_MGR_SERVICE"

# ── Перенос аргументами ─────────────────────────────────────
MTDD_SERVICE_NAME=netrelayd; ENGINE_KIND=mtdd; MTPROXYL_MODE=manager; mtdd_mgr_ctx
echo dev > "$MTDD_CHANNEL_FILE"; AD_TAG="$TAG"; PROXY_MODE=mtproto; UNKNOWN_SNI_ACTION=drop
DC_RESTART_ENABLED=true; WEB_ENABLED=false
SECRETS_LABELS=(alice); SECRETS_KEYS=("$TAG"); SECRETS_CREATED=(1700000000); SECRETS_ENABLED=(true)
SECRETS_MAX_CONNS=(0); SECRETS_MAX_IPS=(0); SECRETS_QUOTA=(0); SECRETS_EXPIRES=(0); SECRETS_NOTES=(""); SECRETS_ADTAG=(""); SECRETS_RATE=("")
zapret2_in_effect() { return 1; }
_argsgen_defaults >/dev/null 2>&1
_AG_ON[dcrestart]=yes; _AG_ON[adtag]=no
cmd=$(_argsgen_build)
[[ "$cmd" == *"--engine mtdd --mtdd-channel dev --service-name random"* ]] || fail "argsgen: движок: $cmd"
[[ "$cmd" == *"--ad-tag $TAG"* ]] || fail "argsgen: тег mtdd обязателен: $cmd"
[[ "$cmd" != *"--sni-policy"* && "$cmd" != *"--dc-restart"* && "$cmd" != *"--web"* ]] || fail "argsgen: лишние флаги: $cmd"
eval "args=($cmd)"
out=$(ia "${args[@]}") || fail "argsgen: команда не принимается установкой: $out"
source lib/install_args.sh >/dev/null 2>&1; _install_args_parse "${args[@]}" >/dev/null 2>&1
[ "$_IA_MTDD_CHANNEL" = dev ] && [ "$_IA_SERVICE_NAME" = random ] && [ "$_IA_ENGINE_KIND" = mtdd ] || fail "argsgen: обратный разбор"

# ── Переезд ─────────────────────────────────────────────────
binengine_is_custom() { return 1; }
m=$(_mig_build_args | tr '\n' ' ')
[[ "$m" == *"--engine mtdd --mtdd-channel dev --service-name random"* ]] || fail "migrate: движок: $m"
[[ "$m" != *"--sni-policy"* && "$m" != *"--dc-restart"* ]] || fail "migrate: лишние флаги: $m"

# telemt не задет: та же команда без mtdd.
ENGINE_KIND=telemt; mtdd_mgr_ctx
engine_backend() { echo docker; }
_argsgen_defaults >/dev/null 2>&1
cmd=$(_argsgen_build)
[[ "$cmd" != *"mtdd"* ]] || fail "argsgen telemt: $cmd"

echo "OK mtdd_manager_install"
