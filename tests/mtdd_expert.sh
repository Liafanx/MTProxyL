#!/bin/bash
# «Экспертные параметры» mtdd (lib/mtdd_expert.sh): каталог в форме telemt для
# панели, проверка по диапазонам mtdd, запись в tune.json Manager, отложенное
# применение (--no-apply → apply), сброс, ключи MTProxyL закрыты, tune — синоним.
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "SKIP mtdd_expert: нет python3"; exit 0; }
command -v jq >/dev/null || { echo "SKIP mtdd_expert: нет jq"; exit 0; }
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

INSTALL_DIR="$t/install"; VERSION=test
mkdir -p "$INSTALL_DIR"
source "$repo/lib/colors.sh" || true
for _lib in utils settings detect mtdd mtdd_mgr config docker binengine expert_catalog expert_mode mtdd_expert; do
    source "$repo/lib/$_lib.sh" || fail "source $_lib"
done
SETTINGS_FILE="$INSTALL_DIR/settings.conf"; BACKUP_DIR="$t/backups"; mkdir -p "$BACKUP_DIR"
MTDD_MGR_DIR="$t/mtdd"; MTDD_MGR_STATE="$t"; MTDD_MGR_CONFIG="$t/mtdd/config.json"
MTDD_MGR_ENV="$t/mtdd/credentials.env"; MTDD_MGR_TUNE="$t/mtdd/tune.json"
mkdir -p "$MTDD_MGR_DIR"; echo "MTDD_API_TOKEN=x" > "$MTDD_MGR_ENV"
_mtdd_mgr_prepare_dirs() { mkdir -p "$MTDD_MGR_DIR"; }
chown() { :; }
systemctl() { echo "systemctl $*" >> "$t/systemctl.log"; [ "$1" != is-active ] || return 0; }
journalctl() { :; }
check_root() { :; }
get_public_ip() { echo 203.0.113.10; }
shaping_config() { echo '{"enabled":false}'; }
cat > "$t/fakebin" <<'EOF'
#!/bin/sh
case "$*" in *--version*) echo "mtdd 1.0.0" ;; esac
exit 0
EOF
chmod +x "$t/fakebin"

MTPROXYL_MODE=manager; ENGINE_KIND=mtdd
PROXY_PORT=443; PROXY_API_PORT=9091; PROXY_METRICS_PORT=9190; PROXY_DOMAIN=example.org
AD_TAG=0123456789abcdef0123456789abcdef; MASKING_ENABLED=true; MASKING_HOST=""; MASKING_PORT=443
mtdd_mgr_ctx
cp "$t/fakebin" "$MTDD_MGR_BIN"
mtdd_running() { return 0; }
mtdd_unit_exists() { return 0; }
_mtdd_py() { [ "$1" = full ]; }
generate_mtdd_config || fail "generate_mtdd_config"

# ── Каталог: 27 ключей, без «|» внутри полей, все разделы известны ──
[ "${#_MTDD_CATALOG[@]}" -eq 30 ] || fail "ключей в каталоге: ${#_MTDD_CATALOG[@]}"
for e in "${_MTDD_CATALOG[@]}"; do
    [ "$(tr -cd '|' <<< "$e" | wc -c)" -eq 7 ] || fail "лишний | в записи: $e"
    [[ " $_MTDD_SECTIONS " == *" ${e%%|*} "* ]] || fail "раздел вне списка: $e"
done

# ── JSON для панели — та же форма, что у telemt ──
cat_json=$(handle_expert_command list --catalog)
jq -e 'type == "array" and length > 0 and (.[0] | has("section") and has("key") and has("default") and has("hot_reload") and has("validator") and has("hint") and has("description") and has("override") and has("has_override"))' <<< "$cat_json" >/dev/null \
    || fail "каталог: $(head -c 300 <<< "$cat_json")"
# masking в Manager задаёт MTProxyL — в каталоге панели его нет.
jq -e 'map(.key) | index("masking") == null' <<< "$cat_json" >/dev/null || fail "masking в каталоге Manager"
jq -e '.[] | select(.key == "me_connections_per_dc") | .hot_reload == true and .default == "16" and .validator == "range:1:24"' <<< "$cat_json" >/dev/null \
    || fail "me_connections_per_dc: $(jq -c '.[] | select(.key == "me_connections_per_dc")' <<< "$cat_json")"
[ "$(handle_expert_command list --json)" = "[]" ] || fail "оверрайдов нет, а list --json: $(handle_expert_command list --json)"

# ── Проверка значений ──
handle_expert_command set middle_proxy me_connections_per_dc 25 >/dev/null 2>&1 && fail "25 > 24 пропущено"
handle_expert_command set timeouts client_ack_timeout_seconds 5 >/dev/null 2>&1 && fail "ack 5 пропущено (0 или 10..3600)"
handle_expert_command set routing direct_fallback_dcs 1,203 >/dev/null 2>&1 && fail "DC 203 пропущен"
handle_expert_command set routing direct_fallback_dcs 1,1 >/dev/null 2>&1 && fail "повтор DC пропущен"
handle_expert_command set routing masking false >/dev/null 2>&1 && fail "masking в Manager пропущен"
handle_expert_command set nope 1 >/dev/null 2>&1 && fail "неизвестный ключ пропущен"
[ ! -s "$MTDD_MGR_TUNE" ] || [ "$(jq -c . "$MTDD_MGR_TUNE")" = "{}" ] || fail "отказы записали tune: $(cat "$MTDD_MGR_TUNE")"

# ── Запись: горячий ключ → reload, холодный → restart ──
: > "$t/systemctl.log"
handle_expert_command set middle_proxy me_connections_per_dc 20 >/dev/null 2>&1 || fail "set me_connections_per_dc"
[ "$(jq -r .me_connections_per_dc "$MTDD_MGR_TUNE")" = 20 ] && [ "$(jq -r .me_connections_per_dc "$MTDD_MGR_CONFIG")" = 20 ] || fail "20 не дошло до tune/config"
grep -q "systemctl reload" "$t/systemctl.log" && ! grep -q "systemctl restart" "$t/systemctl.log" || fail "горячий ключ: $(cat "$t/systemctl.log")"
: > "$t/systemctl.log"
handle_expert_command set routing direct_fallback_dcs "2, -2" >/dev/null 2>&1 || fail "set direct_fallback_dcs"
[ "$(jq -c .direct_fallback_dcs "$MTDD_MGR_TUNE")" = "[2,-2]" ] || fail "список DC: $(jq -c .direct_fallback_dcs "$MTDD_MGR_TUNE")"
grep -q "systemctl restart" "$t/systemctl.log" || fail "холодный ключ без restart: $(cat "$t/systemctl.log")"
# Ключ без раздела и старый синтаксис tune.
handle_expert_command set cpu_affinity false >/dev/null 2>&1 || fail "set без раздела"
[ "$(jq -r .cpu_affinity "$MTDD_MGR_TUNE")" = false ] || fail "cpu_affinity"
mtdd_handle_tune set direct_fallback_dcs "[1,3]" >/dev/null 2>&1 || fail "tune set [1,3]"
[ "$(jq -c .direct_fallback_dcs "$MTDD_MGR_TUNE")" = "[1,3]" ] || fail "tune [1,3]: $(jq -c .direct_fallback_dcs "$MTDD_MGR_TUNE")"

# ── Значения видны в list --json и каталоге (массив — через запятую) ──
ov=$(handle_expert_command list --json)
jq -e 'map({(.key): .value}) | add | .me_connections_per_dc == "20" and .direct_fallback_dcs == "1,3" and .cpu_affinity == "false"' <<< "$ov" >/dev/null \
    || fail "list --json: $ov"
handle_expert_command list --catalog | jq -e '.[] | select(.key == "cpu_affinity") | .has_override == true and .override == "false"' >/dev/null || fail "override в каталоге"

# ── --no-apply (панель) → apply: холодное перезапускает один раз ──
: > "$t/systemctl.log"
handle_expert_command set media media_user_rate_kbps 5000 --no-apply >/dev/null 2>&1 || fail "--no-apply горячий"
handle_expert_command set connections workers 4 --no-apply >/dev/null 2>&1 || fail "--no-apply холодный"
[ ! -s "$t/systemctl.log" ] || fail "--no-apply трогал службу: $(cat "$t/systemctl.log")"
handle_expert_command apply >/dev/null 2>&1 || fail "apply"
[ "$(grep -c "systemctl restart" "$t/systemctl.log")" = 1 ] && ! grep -q reload "$t/systemctl.log" || fail "apply: $(cat "$t/systemctl.log")"
: > "$t/systemctl.log"
handle_expert_command apply >/dev/null 2>&1 || fail "повторный apply"
[ ! -s "$t/systemctl.log" ] || fail "повторный apply трогал службу"
handle_expert_command set media media_total_rate_kbps 9000 --no-apply >/dev/null 2>&1
handle_expert_command apply >/dev/null 2>&1
grep -q "systemctl reload" "$t/systemctl.log" && ! grep -q restart "$t/systemctl.log" || fail "только горячее → reload: $(cat "$t/systemctl.log")"

# Сборка без SIGHUP: горячий ключ применяется перезапуском — это успех.
_mtdd_py() { return 1; }
: > "$t/systemctl.log"
handle_expert_command set middle_proxy me_clients_per_writer 300 >/dev/null 2>&1 || fail "горячий set без SIGHUP вернул ошибку"
grep -q "systemctl restart" "$t/systemctl.log" || fail "без SIGHUP не перезапущен: $(cat "$t/systemctl.log")"
_mtdd_py() { [ "$1" = full ]; }

# ── Сброс ──
handle_expert_command clear connections workers >/dev/null 2>&1 || fail "clear workers"
jq -e 'has("workers") | not' "$MTDD_MGR_TUNE" >/dev/null || fail "workers остался"
handle_expert_command clear all >/dev/null 2>&1 || fail "clear all"
[ "$(jq -c . "$MTDD_MGR_TUNE")" = "{}" ] || fail "clear all: $(cat "$MTDD_MGR_TUNE")"

# ── Текстовый список: без сырых \033, masking помечен, умолчания видны ──
out=$(handle_expert_command list)
grep -qF '\033' <<< "$out" && fail "сырой escape в списке"
grep -E ' masking ' <<< "$out" | grep -q "задаёт MTProxyL" || fail "masking не помечен: $(grep masking <<< "$out")"
grep -E ' workers ' <<< "$out" | grep -q "0–256" || fail "нет диапазона у workers: $(grep workers <<< "$out")"
# Значения читаются одним jq, а не python на каждый ключ.
mtdd_cfg_get() { echo "mtdd_cfg_get вызван" >> "$t/calls"; }
handle_expert_command list >/dev/null
[ ! -s "$t/calls" ] || fail "список зовёт mtdd_cfg_get на ключ"

# ── WARP: direct_fallback задаёт MTProxyL ──
WARP_ENABLED=true
handle_expert_command set routing direct_fallback_enabled true >/dev/null 2>&1 && fail "direct_fallback при WARP пропущен"
handle_expert_command list --catalog | jq -e 'map(.key) | index("direct_fallback_dcs") == null' >/dev/null || fail "direct_fallback_dcs в каталоге при WARP"
WARP_ENABLED=false

echo "OK mtdd_expert"
