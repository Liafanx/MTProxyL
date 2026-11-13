#!/bin/bash
# mtdd как движок Manager (lib/mtdd_mgr.sh): конфиг из настроек менеджера и
# tune.json с проверкой бинарником, синхронизация secrets.conf → API mtdd
# (создание с ключами, удаление лишних, политики, ротация, выключение),
# сборка без полного API, метрики пользователей для базы трафика, гарды.
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "SKIP mtdd_manager: нет python3"; exit 0; }
command -v jq >/dev/null || { echo "SKIP mtdd_manager: нет jq"; exit 0; }
t=$(mktemp -d)
mock_pid=""
trap '[ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null; rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
echo full > "$t/mock_mode"
python3 -I "$repo/tests/mtdd_mock_api.py" "$t" "$TOKEN" &
mock_pid=$!
for _ in $(seq 50); do [ -s "$t/mock_port" ] && break; sleep 0.1; done
port=$(cat "$t/mock_port" 2>/dev/null) || fail "mock не поднялся"

INSTALL_DIR="$t/install"; VERSION=test
mkdir -p "$INSTALL_DIR/relay_stats"
source "$repo/lib/colors.sh" || true
for _lib in utils settings detect mtdd mtdd_mgr secrets config docker binengine traffic stats shaping settings_cli; do
    source "$repo/lib/$_lib.sh" || fail "source $_lib"
done
SETTINGS_FILE="$INSTALL_DIR/settings.conf"; SECRETS_FILE="$INSTALL_DIR/secrets.conf"
CONFIG_DIR="$t/cfg"; BACKUP_DIR="$t/backups"; mkdir -p "$BACKUP_DIR"
MTDD_CHANNEL_FILE="$INSTALL_DIR/mtdd.channel"
# Каталог mtdd менеджера — во временной папке; состояние совпадает с каталогом
# мока: там он пишет users.json, по которому помощник берёт секреты.
MTDD_MGR_DIR="$t/mtdd"; MTDD_MGR_STATE="$t"; MTDD_MGR_CONFIG="$t/mtdd/config.json"
MTDD_MGR_ENV="$t/mtdd/credentials.env"; MTDD_MGR_TUNE="$t/mtdd/tune.json"
mkdir -p "$MTDD_MGR_DIR"; echo "MTDD_API_TOKEN=${TOKEN}" > "$MTDD_MGR_ENV"
_mtdd_mgr_prepare_dirs() { mkdir -p "$MTDD_MGR_DIR"; }
chown() { :; }
_running=true
systemctl() {
    case "$1" in
        is-active) [ "$_running" = true ] ;;
        show) return 1 ;;
        *) echo "systemctl $*" >> "$t/systemctl.log"; return 0 ;;
    esac
}
journalctl() { :; }
check_root() { :; }
_mktemp() { mktemp "${1:-$t}/.tmp.XXXXXX"; }
get_public_ip() { echo 203.0.113.10; }
shaping_config() { echo '{"enabled":false}'; }

# Бинарник для --check-config: отказ, пока есть файл check_fail или в конфиге
# есть usage_state_path при файле no_usage (сборка до квот).
cat > "$t/fakebin" <<EOF
#!/bin/sh
case "\$*" in
  *--check-config*)
    [ -f "$t/check_fail" ] && { echo "bad key" >&2; exit 1; }
    cfg=\$(echo "\$*" | sed 's/.*--config \([^ ]*\).*/\1/')
    [ -f "$t/no_usage" ] && grep -q usage_state_path "\$cfg" && { echo "mtdd: unknown configuration option: usage_state_path" >&2; exit 1; }
    [ -f "$t/no_usage" ] && grep -q metrics_host "\$cfg" && { echo "mtdd: unknown configuration option: metrics_host" >&2; exit 1; }
    [ -f "$t/no_usage" ] && grep -q metrics_port "\$cfg" && { echo "mtdd: unknown configuration option: metrics_port" >&2; exit 1; }
    grep -q '"bogus_key"' "\$cfg" && { echo "mtdd: unknown configuration option: bogus_key" >&2; exit 1; }
    exit 0 ;;
  *--version*) echo "mtdd 0.1.0" ;;
esac
EOF
chmod +x "$t/fakebin"

S1_UNIT="$MTDD_UNIT"
MTPROXYL_MODE=manager; ENGINE_KIND=mtdd
PROXY_PORT=443; PROXY_API_PORT="$port"; PROXY_METRICS_PORT=9190; PROXY_DOMAIN=example.org
AD_TAG=0123456789abcdef0123456789abcdef; MASKING_ENABLED=true; MASKING_HOST=""; MASKING_PORT=443
mtdd_mgr_ctx
cp "$t/fakebin" "$MTDD_MGR_BIN"

# ── Предикаты ────────────────────────────────────────────────
mtdd_mgr_active || fail "mtdd_mgr_active"
engine_is_mtdd || fail "engine_is_mtdd в Manager"
_target_is_mtdd && fail "_target_is_mtdd в Manager"
[ "$DETECTED_CONFIG_PATH" = "$MTDD_MGR_CONFIG" ] || fail "контекст: путь конфига $DETECTED_CONFIG_PATH"
[ "$MTDD_UNIT" = "mtproxyl-mtdd.service" ] || fail "контекст: служба $MTDD_UNIT"
[ "$(engine_config_path)" = "$MTDD_MGR_CONFIG" ] || fail "engine_config_path"
[ "$(engine_link_modes)" = tls ] || fail "виды ссылок у mtdd: $(engine_link_modes)"
MASKING_ENABLED=false; [ "$(engine_link_modes)" = tls ] || fail "dd-ссылки при выключенной маскировке"; MASKING_ENABLED=true

# ── Конфиг ───────────────────────────────────────────────────
generate_mtdd_config || fail "generate_mtdd_config"
[ "$MTDD_MGR_CONFIG_CHANGE" = restart ] || fail "первая генерация: $MTDD_MGR_CONFIG_CHANGE"
cfg() { jq -r "$1" "$MTDD_MGR_CONFIG"; }
[ "$(cfg .proxy_port)" = 443 ] && [ "$(cfg .tls_domain)" = example.org ] && [ "$(cfg .control_port)" = "$port" ] \
    || fail "ключи конфига: $(cat "$MTDD_MGR_CONFIG")"
[ "$(cfg .ad_tag)" = "$AD_TAG" ] && [ "$(cfg .masking)" = true ] && [ "$(cfg .public_host)" = 203.0.113.10 ] || fail "ad_tag/masking/public_host"
[ "$(cfg .users_path)" = "$t/users.json" ] && [ "$(cfg .usage_state_path)" = "$t/usage.json" ] || fail "пути состояния"
[ "$(cfg '.fallback_port // "нет"')" = нет ] || fail "fallback без своей маскировки"
generate_mtdd_config && [ "$MTDD_MGR_CONFIG_CHANGE" = same ] || fail "повторная генерация без изменений: $MTDD_MGR_CONFIG_CHANGE"
MASKING_HOST=127.0.0.1; MASKING_PORT=8444
generate_mtdd_config && [ "$MTDD_MGR_CONFIG_CHANGE" = restart ] || fail "смена маскировки"
[ "$(cfg .fallback_host):$(cfg .fallback_port)" = 127.0.0.1:8444 ] || fail "fallback Selfmask"
MASKING_HOST=""; MASKING_PORT=443; generate_mtdd_config
touch "$t/no_usage"; generate_mtdd_config || fail "сборка без квот"
[ "$(cfg '.usage_state_path // "нет"')|$(cfg '.metrics_port // "нет"')|$(cfg '.metrics_host // "нет"')" = "нет|нет|нет" ] \
    || fail "ключи, которых не знает старая сборка, остались"
mtdd_config_set 'bogus_key=1' >/dev/null 2>&1 && fail "неизвестный ключ из tune.json принят"
jq -e 'has("bogus_key") | not' "$MTDD_MGR_TUNE" >/dev/null 2>&1 || [ ! -f "$MTDD_MGR_TUNE" ] || fail "tune.json не откатился после bogus_key"
rm -f "$t/no_usage"; generate_mtdd_config
touch "$t/check_fail"; cp "$MTDD_MGR_CONFIG" "$t/cfg.before"; PROXY_PORT=8443
generate_mtdd_config 2>/dev/null && fail "непринятый конфиг записан"
cmp -s "$MTDD_MGR_CONFIG" "$t/cfg.before" || fail "конфиг изменён, хотя бинарник его отверг"
rm -f "$t/check_fail"; PROXY_PORT=443
AD_TAG=""; generate_mtdd_config 2>/dev/null && fail "конфиг без ad-tag"; AD_TAG=0123456789abcdef0123456789abcdef
declare -F _validate_settings_adtag >/dev/null || fail "нет _validate_settings_adtag"
generate_telemt_config || fail "generate_telemt_config при mtdd"
jq -e '.tls_domain == "example.org"' "$MTDD_MGR_CONFIG" >/dev/null 2>&1 || fail "generate_telemt_config записал не JSON mtdd: $(head -3 "$MTDD_MGR_CONFIG")"
_validate_settings_adtag "" >/dev/null && fail "пустой ad-tag для mtdd принят"
_validate_settings_adtag "$AD_TAG" >/dev/null || fail "верный ad-tag для mtdd отвергнут"
_validate_settings_adtag 00000000000000000000000000000000 >/dev/null && fail "нулевой ad-tag для mtdd принят"

# Тюнинг: свои ключи — в tune.json; ключи менеджера — отказ; отказ бинарника — откат.
mtdd_config_set "me_clients_per_writer=300" >/dev/null 2>&1 || fail "tune me_clients_per_writer"
[ "$(cfg .me_clients_per_writer)" = 300 ] && [ "$(jq -r .me_clients_per_writer "$MTDD_MGR_TUNE")" = 300 ] || fail "tune не дошёл до конфига"
[ "$MTDD_MGR_CONFIG_CHANGE" = hot ] || fail "me_clients_per_writer — горячий ключ: $MTDD_MGR_CONFIG_CHANGE"
mtdd_config_set "proxy_port=1" >/dev/null 2>&1 && fail "tune пустил ключ менеджера"
touch "$t/check_fail"
mtdd_config_set "workers=4" >/dev/null 2>&1 && fail "tune при отказе бинарника прошёл"
rm -f "$t/check_fail"
jq -e 'has("workers") | not' "$MTDD_MGR_TUNE" >/dev/null || fail "tune.json не откатился"
mtdd_media_set 2.5 500 >/dev/null 2>&1 || fail "media set"
[ "$(cfg .media_user_rate_kbps)" = 2500 ] || fail "медиа-лимит не в конфиге"
generate_mtdd_config; [ "$(cfg .media_user_rate_kbps)" = 2500 ] || fail "медиа-лимит пропал при перегенерации"

# ── Синхронизация пользователей ──────────────────────────────
ALICE=0123456789abcdef0123456789abcdef; BOB=fedcba9876543210fedcba9876543210
cat > "$SECRETS_FILE" <<EOF
# MTProxyL — база секретов
alice|${ALICE}|1700000000|true|0|0|0|0||||
bob|${BOB}|1700000000|true|5|2|1073741824|2030-01-01T23:59:59+03:00|заметка||8192000:16384000
EOF
mtdd_mgr_sync_users || fail "sync"
rows=$(_mtdd_py users-tsv)
grep -q '^admin|' <<< "$rows" && fail "лишний пользователь mtdd не удалён"
[ "$(awk -F'|' '$1=="alice"{print $3}' <<< "$rows")" = "$ALICE" ] || fail "alice: ключ ($rows)"
[ "$(awk -F'|' '$1=="bob"{print $3"|"$4"|"$5"|"$6"|"$7"|"$8"|"$9"|"$10}' <<< "$rows")" = "${BOB}|5|2|1073741824|2030-01-01T20:59:59Z|заметка|8192000|16384000" ] \
    || fail "bob: политики ($(awk -F'|' '$1=="bob"' <<< "$rows"))"
echo 0 > "$t/mock_count"; mtdd_mgr_sync_users || fail "повторный sync"
[ "$(cat "$t/mock_count")" -le 3 ] || fail "повторный sync без изменений сделал $(cat "$t/mock_count") запросов"

NEWKEY=11111111111111111111111111111111
cat > "$SECRETS_FILE" <<EOF
alice|${NEWKEY}|1700000000|false|0|0|0|0||||
bob|${BOB}|1700000000|true|0|0|0|0||||
dave|22222222222222222222222222222222|1700000000|true|0|0|0|2030-01-01T23:59:59+0300|||
EOF
mtdd_mgr_sync_users || fail "sync изменений"
[ "$(_mtdd_py users-tsv --no-links | awk -F'|' '$1=="dave"{print $7}')" = 2030-01-01T20:59:59Z ] || fail "срок с +0300 не разобран"
rows=$(_mtdd_py users-tsv)
[ "$(awk -F'|' '$1=="alice"{print $2"|"$3}' <<< "$rows")" = "false|${NEWKEY}" ] || fail "alice: выключение/ротация ($rows)"
[ "$(awk -F'|' '$1=="bob"{print $4"|"$5"|"$6"|"$7"|"$8"|"$9}' <<< "$rows")" = "0|0|0|||0" ] || fail "bob: лимиты не сняты ($(awk -F'|' '$1=="bob"' <<< "$rows"))"

: > "$SECRETS_FILE"; echo "# пусто" > "$SECRETS_FILE"
mtdd_mgr_sync_users >/dev/null 2>&1 && fail "пустой secrets.conf снял всех пользователей"
[ "$(_mtdd_py users-tsv --no-links | wc -l)" -eq 3 ] || fail "пользователи удалены при пустом secrets.conf"

# Сборка без полного API: выключенный не заводится и снимается.
echo old > "$t/mock_mode"
cat > "$SECRETS_FILE" <<EOF
alice|${NEWKEY}|1700000000|false|0|0|0|0||||
bob|${BOB}|1700000000|true|3|0|0|0||||
carol|${ALICE}|1700000000|true|0|0|0|0||||
EOF
out=$(mtdd_mgr_sync_users 2>&1) || fail "sync на старой сборке: $out"
grep -q "в mtdd не заведены: alice" <<< "$out" || fail "нет предупреждения о выключенном: $out"
rows=$(_mtdd_py users-tsv)
grep -q '^alice|' <<< "$rows" && fail "выключенный остался на старой сборке"
[ "$(awk -F'|' '$1=="carol"{print $3}' <<< "$rows")" = "$ALICE" ] || fail "carol на старой сборке ($rows)"
[ "$(awk -F'|' '$1=="bob"{print $4}' <<< "$rows")" = 3 ] || fail "bob: лимит соединений пересозданием ($rows)"
echo full > "$t/mock_mode"

# ── Метрики пользователей в форме telemt (база трафика) ──────
_METRICS_CACHE=""
m=$(_fetch_metrics) || fail "_fetch_metrics для mtdd"
grep -q '^telemt_user_octets_from_client{user="bob"} ' <<< "$m" || fail "метрики: $m"
grep -q '^telemt_connections_current ' <<< "$m" || fail "нет суммы соединений: $m"

# ── Гарды функций, которых у mtdd нет ────────────────────────
load_secrets
secret_set_adtag bob "$ALICE" >/dev/null 2>&1 && fail "ad-tag на пользователя для mtdd принят"
secret_set_adtag bob remove >/dev/null 2>&1 || fail "снять тег у пользователя mtdd нельзя"
long=$(printf 'я%.0s' $(seq 150))
secret_set_note bob "$long" >/dev/null 2>&1 && fail "заметка 300 байт принята для mtdd"
secret_set_note bob "коротко" >/dev/null 2>&1 || fail "заметка"
[ "$(_mtdd_py users-tsv --no-links | awk -F'|' '$1=="bob"{print $8}')" = коротко ] || fail "заметка не дошла до mtdd"
secret_set_rate bob 1000 0 >/dev/null 2>&1 && fail "скорость ниже 8192 бит/с принята"
_target_toml_guard 2>/dev/null && fail "TOML-писатель пропущен для mtdd"

# telemt-путь Manager не задет: без ENGINE_KIND=mtdd предикаты ложны.
ENGINE_KIND=telemt; mtdd_mgr_ctx
mtdd_mgr_active && fail "mtdd_mgr_active при telemt"
engine_is_mtdd && fail "engine_is_mtdd при telemt"
[ -z "$DETECTED_CONFIG_PATH" ] || fail "контекст mtdd не снят: $DETECTED_CONFIG_PATH"
[ "$MTDD_UNIT" = "$S1_UNIT" ] || fail "адаптер не вернулся к цели Reanimator: $MTDD_UNIT"
MASKING_ENABLED=false; [ "$(engine_link_modes | tr '\n' ' ')" = "secure tls " ] || fail "виды ссылок telemt: $(engine_link_modes)"


# ── Смена движка telemt ⇄ mtdd ───────────────────────────────
for _lib in engine utils; do source "$repo/lib/$_lib.sh" || fail "source $_lib"; done
uname() { [ "${1:-}" = -m ] && echo x86_64 || command uname "$@"; }
save_settings() { echo "ENGINE_KIND=$ENGINE_KIND" >> "$t/saved"; }
read_line() { printf -v "$1" '%s' y; }
remove_own_container() { echo "remove:$ENGINE_KIND" >> "$t/switch.log"; }
shaping_restore() { :; }
_run_fail=""
run_proxy_container() {
    echo "run:$ENGINE_KIND:$(mtdd_mgr_active && echo mgr || echo tm)" >> "$t/switch.log"
    [ "$_run_fail" = "$ENGINE_KIND" ] && return 1; return 0
}
mtdd_mgr_ensure_installed() { echo "fetch:$ENGINE_KIND" >> "$t/switch.log"; }
binengine_ensure_installed() { echo "fetch-telemt:$ENGINE_BACKEND" >> "$t/switch.log"; }
binengine_arch() { echo x86_64; }; binengine_resolve_naming() { :; }
install_autostart_unit() { echo "autostart:$ENGINE_KIND" >> "$t/switch.log"; }
ENGINE_BACKEND=docker
cat > "$SECRETS_FILE" <<EOF2
alice|${ALICE}|1700000000|true|0|0|0|0||||
bob|${BOB}|1700000000|true|0|0|0|0||${ALICE}|4000:0
EOF2
ENGINE_KIND=telemt; mtdd_mgr_ctx
WEB_ENABLED=true; PROXY_PROTOCOL=true
out=$(engine_switch_kind mtdd --yes 2>&1) && fail "переход при WEB/PROXY protocol: $out"
grep -q "WEB" <<< "$out" && grep -q "PROXY protocol" <<< "$out" && grep -q "8192 бит/с у: bob" <<< "$out" \
    || fail "причины отказа: $out"
[ "$ENGINE_KIND" = telemt ] && [ ! -s "$t/switch.log" ] || fail "отказ всё же что-то сделал"
WEB_ENABLED=false; PROXY_PROTOCOL=false
sed -i 's/4000:0/16384:0/' "$SECRETS_FILE"
out=$(AD_TAG="" engine_switch_kind mtdd --yes 2>&1) && fail "переход без ad-tag"
grep -q "рекламный тег" <<< "$out" || fail "нет причины про ad-tag: $out"
engine_switch_kind mtdd --yes > "$t/out" 2>&1 || fail "переход на mtdd: $(cat "$t/out")"
grep -q "тег один на сервер" "$t/out" || fail "нет предупреждения о своих тегах: $(cat "$t/out")"
[ "$(tr '\n' ' ' < "$t/switch.log")" = "fetch:mtdd remove:telemt autostart:mtdd run:mtdd:mgr " ] || fail "порядок перехода: $(cat "$t/switch.log")"
[ "$ENGINE_KIND" = mtdd ] && mtdd_mgr_active && [ "$(tail -1 "$t/saved")" = ENGINE_KIND=mtdd ] || fail "вид движка после перехода"
: > "$t/switch.log"; _run_fail=telemt
# Без Docker в PATH telemt ставится бинарником, с Docker — остаётся в нём.
_no_docker=""; command -v docker >/dev/null 2>&1 || _no_docker="fetch-telemt:binary "
engine_switch_kind telemt --yes >/dev/null 2>&1 && fail "провал telemt не замечен"
[ "$(tr '\n' ' ' < "$t/switch.log")" = "${_no_docker}remove:mtdd autostart:telemt run:telemt:tm remove:telemt autostart:mtdd run:mtdd:mgr " ] || fail "откат: $(cat "$t/switch.log")"
[ -z "$_no_docker" ] || [ "$ENGINE_BACKEND" = binary ] || fail "без Docker telemt не ушёл на бинарник: $ENGINE_BACKEND"
[ "$ENGINE_KIND" = mtdd ] && [ "$(tail -1 "$t/saved")" = ENGINE_KIND=mtdd ] || fail "после отката вид не mtdd"
: > "$t/switch.log"; _run_fail=""
engine_switch_kind telemt --yes >/dev/null 2>&1 || fail "обратно на telemt"
[ "$ENGINE_KIND" = telemt ] && ! mtdd_mgr_active && [ -z "$DETECTED_CONFIG_PATH" ] || fail "контекст после возврата на telemt"
ENGINE_KIND=mtdd; mtdd_mgr_ctx
mkdir -p "$INSTALL_DIR/cache"; printf 'main|2026-10-29T00:00:00Z|1|u|s\n' > "$INSTALL_DIR/cache/mtdd_channels"
j=$(handle_engine_command status --json 2>/dev/null) || fail "engine status --json"
jq -e '.backend == "mtdd" and .target == false and .engine_kind == "mtdd" and .service == "mtproxyl-mtdd" and .supported == false and (.reason|test("Нет службы"))' <<< "$j" >/dev/null \
    || fail "JSON движка для панели: $j"
ENGINE_KIND=telemt; mtdd_mgr_ctx
MTPROXYL_MODE=reanimator; engine_switch_kind mtdd --yes >/dev/null 2>&1 && fail "смена движка в Reanimator"
MTPROXYL_MODE=manager

echo "OK mtdd_manager"
