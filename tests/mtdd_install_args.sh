#!/bin/bash
# Установка реаниматора с mtdd аргументами и «Перенос аргументами» для цели
# mtdd: отказ на ключи, которых у mtdd нет; перенос пользователей с их ключами
# (служебный пользователь установщика удаляется только когда заведены все);
# команда переноса разбирается той же установкой обратно.
# Без -u: save_settings пишет все настройки разом, а здесь подключены не все библиотеки.
set -o pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "SKIP mtdd_install_args: нет python3"; exit 0; }
t=$(mktemp -d)
mock_pid=""
trap '[ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null; rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
start_mock() {
    [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null && wait "$mock_pid" 2>/dev/null
    rm -f "$t/mock_port" "$t/mock_fail_post"
    echo "$1" > "$t/mock_mode"
    python3 -I "$repo/tests/mtdd_mock_api.py" "$t" "$TOKEN" &
    mock_pid=$!
    for _ in $(seq 50); do [ -s "$t/mock_port" ] && break; sleep 0.1; done
    port=$(cat "$t/mock_port" 2>/dev/null) || fail "mock не поднялся"
    cat > "$t/config.json" <<EOF
{"proxy_host": "0.0.0.0", "proxy_port": 8443, "control_host": "127.0.0.1", "control_port": ${port},
 "api_token_env": "MTDD_API_TOKEN", "tls_domain": "example.org",
 "ad_tag": "0123456789abcdef0123456789abcdef", "users_path": "/var/lib/mtdd/users.json"}
EOF
}
printf '#!/bin/sh\nexit 0\n' > "$t/mtdd"; chmod +x "$t/mtdd"
echo "MTDD_API_TOKEN=${TOKEN}" > "$t/credentials.env"

INSTALL_DIR="$t/install"; VERSION=test
mkdir -p "$INSTALL_DIR"
source "$repo/lib/colors.sh" || true
for _lib in utils settings detect mtdd secrets tgbot shaping install_args argsgen; do
    source "$repo/lib/$_lib.sh" || fail "source $_lib"
done
SETTINGS_FILE="$INSTALL_DIR/settings.conf"; SECRETS_FILE="$INSTALL_DIR/secrets.conf"
CONFIG_DIR="$t/cfg"; STATS_DIR="$t/stats"; BACKUP_DIR="$t/backups"
MTDD_BIN_DEFAULT="$t/mtdd"; MTDD_ENV_DEFAULT="$t/credentials.env"; MTDD_CHANNEL_FILE="$INSTALL_DIR/mtdd.channel"
systemctl() { return 1; }
uname() { [ "${1:-}" = "-m" ] && echo x86_64 || command uname "$@"; }
check_root() { :; }
_mktemp() { mktemp "${1:-$t}/.tmp.XXXXXX"; }
show_banner() { :; }
stub_ia() { _install_args_deps() { :; }; _install_args_shaping() { return 0; }; }
stub_ia
is_port_available() { return 0; }
_own_install_exists() { return 1; }
run_fix_arsenal_wizard() { :; }
install_ip_history_timer() { :; }
install_availability_timer() { :; }
mtdd_restart() { :; }
mtdd_build_label() { echo "main"; }
ln() { :; }
zapret2_in_effect() { return 1; }
_unit=false
mtdd_unit_exists() { [ "$_unit" = true ]; }
run_target_detection() { DETECTED_MODE=mtdd; DETECTED_CONFIG_PATH="$t/config.json"; DETECTED_NETWORK_MODE=host; DETECTED_PORT=8443; }
# «Установщик mtdd»: проверяет, что ему передали, и заводит своего пользователя.
install_original_mtdd() {
    printf '%s\n' "$@" > "$t/installer_args"
    local _user="" _a
    while [ $# -gt 0 ]; do _a="$1"; shift; [ "$_a" = "--user" ] && _user="$1"; done
    run_target_detection
    _unit=true
    _mtdd_call POST /v1/users "{\"name\":\"${_user}\"}" >/dev/null || return 1
    echo main > "$MTDD_CHANNEL_FILE"
}
wipe_admin() { DETECTED_CONFIG_PATH="$t/config.json" _mtdd_call DELETE /v1/users/admin >/dev/null || fail "admin не удалён"; }
reset_state() {
    _unit=false; rm -rf "$INSTALL_DIR"; mkdir -p "$INSTALL_DIR"
    SECRETS_LABELS=(); SECRETS_KEYS=()
    # Все _IA_* — заново, как в новом процессе: иначе ключи прошлого
    # запуска (--web-domain, --engine) протекают в следующий.
    source "$repo/lib/install_args.sh"; stub_ia
    MTPROXYL_MODE=manager; DETECTED_MODE=unknown; DETECTED_CONFIG_PATH=""
}
run_ia() { reset_state; run_installer_args "$@" > "$t/out" 2>&1; }

ALICE=0123456789abcdef0123456789abcdef
BOBK=fedcba9876543210fedcba9876543210

# ── Отказы до любых действий ──────────────────────────────────
start_mock full
wipe_admin   # пустой «сервер»
run_ia --mode reanimator --target telemt --ad-tag "$ALICE" && fail "target telemt принят"
run_ia --mode reanimator --ad-tag "$ALICE" && fail "без --target принято"
run_ia --mode reanimator --target mtdd --ad-tag "$ALICE" --web-domain w.example.org && fail "--web-domain принят"
grep -q -- "--web-domain: у mtdd этого нет" "$t/out" || fail "нет причины про web: $(cat "$t/out")"
run_ia --mode reanimator --target mtdd --ad-tag "$ALICE" --engine binary && fail "--engine принят"
run_ia --mode reanimator --target mtdd --ad-tag 00000000000000000000000000000000 && fail "нулевой тег принят"
run_ia --mode reanimator --target mtdd --ad-tag "$ALICE" --mtdd-channel beta && fail "канал beta принят"
[ -f "$t/installer_args" ] && fail "установщик запускался при отказе"
reset_state; _IA_MODE=reanimator; _IA_TARGET=mtdd
_install_args_validate_mtdd > "$t/out" 2>&1 || fail "без --ad-tag отвергнуто: $(cat "$t/out")"

# ── Свежая установка с ключами (полная сборка) ───────────────
run_ia --mode reanimator --target mtdd --mtdd-channel dev --ad-tag "$ALICE" --sni example.org --port 8443 \
    --secret "alice:${ALICE}" --user "bob|${BOBK}|1700000000|true|5|2|0|0|заметка||" \
    || fail "установка: $(cat "$t/out")"
grep -qx -- "--channel" "$t/installer_args" && grep -qx dev "$t/installer_args" || fail "канал не передан"
grep -qx "mtproxyl-init" "$t/installer_args" || fail "установщику не дали служебного пользователя"
grep -qx -- "--yes" "$t/installer_args" || fail "установщик запущен без --yes"
rows=$(_mtdd_py users-tsv)
[ "$(awk -F'|' '$1=="alice" {print $3}' <<< "$rows")" = "$ALICE" ] || fail "alice: ключ ($rows)"
[ "$(awk -F'|' '$1=="bob" {print $3"|"$4"|"$5}' <<< "$rows")" = "${BOBK}|5|2" ] || fail "bob: ключ/лимиты ($rows)"
grep -q '^mtproxyl-init|' <<< "$rows" && fail "служебный пользователь остался ($rows)"
[ "$MTPROXYL_MODE" = reanimator ] || fail "режим не reanimator"
grep -q "^MTPROXYL_MODE=.\{0,1\}reanimator" "$SETTINGS_FILE" || fail "режим не сохранён"
grep -q "^PROXY_PORT=.\{0,1\}8443" "$SETTINGS_FILE" || fail "порт фиксов не взят у mtdd"
grep -q '^admin|' <<< "$rows" && fail "на пустом сервере появился admin"

# ── «Перенос аргументами» и обратный разбор ──────────────────
cmd=$(_argsgen_defaults >/dev/null 2>&1; _argsgen_build)
[[ "$cmd" == "--mode reanimator --target mtdd --mtdd-channel main "* ]] || fail "начало команды: $cmd"
for want in "--port 8443" "--sni example.org" "--ad-tag 0123456789abcdef0123456789abcdef" "--mask on"; do
    [[ "$cmd" == *"$want"* ]] || fail "в команде нет '$want': $cmd"
done
eval "args=($cmd)"
printf '%s\n' "${args[@]}" | grep -q "^alice|${ALICE}|" || fail "alice не перенесена: $cmd"
printf '%s\n' "${args[@]}" | grep -q "^bob|${BOBK}|[0-9]*|true|5|2|0|0|заметка|" || fail "bob не перенесён: $cmd"
for bad in --web --sni-policy --engine --proxy-mode --metrics-port --dc-restart; do
    [[ " $cmd " == *" $bad "* ]] && fail "в команде для mtdd есть $bad: $cmd"
done
eval "set -- $cmd"
reset_state
_install_args_parse "$@" >/dev/null 2>&1 || fail "разбор команды переноса"
_install_args_validate_mtdd >/dev/null 2>&1 || fail "проверка команды переноса"
[ "${#_IA_SECRETS[@]}" = 2 ] || fail "пользователей в команде: ${#_IA_SECRETS[@]}"
set --

# ── Старая сборка: создание и удаление есть, ключи переносятся ─
start_mock old
wipe_admin
run_ia --mode reanimator --target mtdd --ad-tag "$ALICE" --secret "alice:${ALICE}" || fail "установка на старой сборке: $(cat "$t/out")"
rows=$(_mtdd_py users-tsv)
[ "$(awk -F'|' '$1=="alice" {print $3}' <<< "$rows")" = "$ALICE" ] || fail "старая сборка: ключ alice ($rows)"
grep -q '^mtproxyl-init|' <<< "$rows" && fail "старая сборка: служебный пользователь остался"

# ── Сбой создания: служебный остаётся, причина видна ─────────
start_mock full
wipe_admin
reset_state
echo 2 > "$t/mock_fail_post"   # первый POST — служебный пользователь, он проходит
install_original_mtdd() {
    printf '%s\n' "$@" > "$t/installer_args"
    run_target_detection; _unit=true
    rm -f "$t/mock_fail_post"
    _mtdd_call POST /v1/users '{"name":"mtproxyl-init"}' >/dev/null || return 1
    echo 1 > "$t/mock_fail_post"
}
run_installer_args --mode reanimator --target mtdd --ad-tag "$ALICE" --secret "alice:${ALICE}" > "$t/out" 2>&1
rows=$(_mtdd_py users-tsv)
grep -q '^mtproxyl-init|' <<< "$rows" || fail "служебный удалён, хотя alice не заведена ($rows)"
grep -q "Не заведены: alice" "$t/out" || fail "нет предупреждения о незаведённых: $(cat "$t/out")"

# ── Уже стоящий mtdd не переставляется ───────────────────────
reset_state; _unit=true; run_target_detection
rm -f "$t/installer_args" "$t/mock_fail_post"
MTPROXYL_MODE=reanimator
run_installer_args --mode reanimator --target mtdd --secret "carol:${BOBK}" --port 9443 > "$t/out" 2>&1 || fail "дозаведение: $(cat "$t/out")"
[ -f "$t/installer_args" ] && fail "установщик запущен поверх стоящего mtdd"
grep -q -- "--port: у стоящего mtdd не меняется" "$t/out" || fail "нет предупреждения про --port"
[ "$(_mtdd_py users-tsv | awk -F'|' '$1=="carol" {print $3}')" = "$BOBK" ] || fail "carol не заведена"

echo "OK mtdd_install_args"
