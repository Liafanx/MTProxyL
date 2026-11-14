#!/bin/bash
# Экраны с mtdd: подпись движка (а не «telemt»), список тюнинга без сырых
# escape-кодов, ключи MTProxyL помечены, дашборд метрик и IP-статистика
# в форме лаунчера mtdd, строка о проверке доступности по факту.
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "SKIP mtdd_screens: нет python3"; exit 0; }
command -v jq >/dev/null || { echo "SKIP mtdd_screens: нет jq"; exit 0; }
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

INSTALL_DIR="$t/install"; VERSION=test
mkdir -p "$INSTALL_DIR"
source "$repo/lib/colors.sh" || true
for _lib in utils settings detect mtdd mtdd_mgr mtdd_dash docker binengine traffic; do
    source "$repo/lib/$_lib.sh" || fail "source $_lib"
done

# ── Подпись движка ───────────────────────────────────────────
MTPROXYL_MODE=manager; ENGINE_KIND=mtdd
mtdd_mgr_version() { echo "1.0.0 (main)"; }
[ "$(engine_title --carrier)" = "mtdd 1.0.0 (main)" ] || fail "mtdd: $(engine_title --carrier)"
ENGINE_KIND=telemt
get_telemt_version() { echo "3.5.13"; }
engine_is_binary() { return 0; }
out=$(engine_title --carrier)
[[ "$out" == "telemt v3.5.13"*"(бинарник)"* ]] || fail "telemt: $out"
[ "$(engine_title)" = "telemt v3.5.13" ] || fail "telemt без носителя: $(engine_title)"
# Строк «telemt v$(get_telemt_version)» мимо engine_title больше нет (кроме меню
# самого telemt, куда mtdd не попадает).
left=$(grep -rn 'telemt v\$(get_telemt_version)' "$repo/lib" "$repo/mtproxyl.sh" | grep -v 'lib/binengine.sh' | grep -v 'lib/tui_engine.sh')
[ -z "$left" ] || fail "подпись telemt зашита: $left"

# ── Тюнинг: значения без сырых \033, ключи MTProxyL помечены ──
ENGINE_KIND=mtdd
mtdd_cfg_get() { case "$1" in masking) echo true ;; me_connections_per_dc) echo 16 ;; *) echo "" ;; esac; }
out=$(mtdd_handle_tune list)
grep -qF '\033' <<< "$out" && fail "сырой escape в списке тюнинга: $(grep -F '\033' <<< "$out" | head -2)"
grep -E '^ +masking +true' <<< "$out" | grep -q "задаёт MTProxyL" || fail "masking не помечен: $(grep masking <<< "$out")"
grep -E '^ +workers ' <<< "$out" | grep -q "по умолчанию" || fail "нет «по умолчанию»: $(grep workers <<< "$out")"

# ── Медиа: на пользователя (все его IP), не на IP ─────────────
out=$(mtdd_media_status)
grep -q "все его IP и устройства вместе" <<< "$out" && grep -q "Не на IP" <<< "$out" || fail "медиа: $out"

# ── IP-статистика: seen/active из /v1/status ──────────────────
cat > "$t/status.json" <<'EOF'
{"unique_ips_seen":7,"unique_ips_active":2,"unique_ip_history":{"approximate":true,"collection_started_at":1794648813,
 "day":{"estimate":40,"started_at":1794614400},"day_active":{"estimate":9},"hour":{"estimate":12,"started_at":1794646800},
 "hour_active":{"estimate":3},"min_bytes":1048576,"persistence_enabled":true,"relative_standard_error":0.0325,"timezone":"UTC",
 "week":{"estimate":300,"started_at":1794182400},"week_active":{"estimate":51}}}
EOF
_mtdd_py() { [ "$1 $2" = "get /v1/status" ] && cat "$t/status.json"; }
j=$(mtdd_ip_stats --json) || fail "metrics ips --json"
jq -e '.online == {"seen":7,"active":2} and .hour.seen == 12 and .hour.active == 3 and .week.active == 51
       and .min_bytes == 1048576 and .persistent == true' <<< "$j" >/dev/null || fail "ips json: $j"
out=$(mtdd_ip_stats) && grep -q "seen ≈40" <<< "$out" && grep -q "1 MiB" <<< "$out" || fail "ips текст: $out"

# ── Дашборд: тот же рендер, что у mtdd-ctl metrics ────────────
_mtdd_py() {
    [ "$1" = dash-input ] || return 1
    printf '{"ok":true,"data":%s}' "$(cat "$t/status.json")" > "$2/status.json"
    printf 'mtdd_unique_ips_seen 7\n' > "$2/metrics.txt"
}
out=$(NO_COLOR=1 mtdd_metrics_dashboard) || fail "дашборд: $out"
grep -q "Уникальные IP" <<< "$out" && grep -q "mtproxyl metrics engine live" <<< "$out" || fail "дашборд: $(head -20 <<< "$out")"
grep -q "mtdd-ctl" <<< "$out" && fail "в дашборде подсказка mtdd-ctl"
grep -q "MIT License" "$repo/lib/mtdd_dash.sh" && grep -q "ugDeDe/mtdd" "$repo/lib/mtdd_dash.sh" || fail "нет лицензии и источника рендера"

# ── suspects block: правила nft собираются и проходят nft -c ──
# Вход — уже приведённый помощником (suspects-ips, см. mtdd_adapter).
_mtdd_suspects_nft_rules 8443 "$(printf '%s\n' 1.2.3.4 1.2.3.0/24 5.6.7.8 2001:db8::1 'мусор' '')" > "$t/nft"; r=$(cat "$t/nft")
[ "$MTDD_SUSPECTS_COUNT" = 4 ] || fail "suspects: адресов $MTDD_SUSPECTS_COUNT, ждали 4"
grep -q 'elements = { 1.2.3.4, 1.2.3.0/24, 5.6.7.8 };' <<< "$r" || fail "suspects v4: $r"
grep -q 'elements = { 2001:db8::1 };' <<< "$r" || fail "suspects v6: $r"
[ "$(grep -c 'tcp dport 8443 ' <<< "$r")" = 2 ] || fail "suspects: блок не привязан к порту прокси: $r"
grep -q '}}' <<< "$r" && fail "suspects: лишняя скобка: $r"
_mtdd_suspects_nft_rules 443 "" > "$t/nft"; r0=$(cat "$t/nft")
[ "$MTDD_SUSPECTS_COUNT" = 0 ] && ! grep -q elements <<< "$r0" || fail "suspects пусто: $r0"
if command -v nft >/dev/null 2>&1 && nft -c -f - <<< 'table inet mtproxyl_probe { }' >/dev/null 2>&1; then
    # delete table несуществующей таблицы nft -c не проверит — только сама таблица.
    nft -c -f - <<< "$(sed 1,2d <<< "$r")" || fail "nft отверг правила: $r"
    nft -c -f - <<< "$(sed 1,2d <<< "$r0")" || fail "nft отверг пустые правила: $r0"
fi

# ── health у Manager-mtdd: бинарник и служба mtdd, без Docker ──
MTPROXYL_MODE=manager; ENGINE_KIND=mtdd; MTDD_MGR_BIN="$t/fakemtdd"; MTDD_UNIT=x.service
printf '#!/bin/sh\n' > "$MTDD_MGR_BIN"; chmod +x "$MTDD_MGR_BIN"
mtdd_running() { return 0; }; _mtdd_py() { [ "$1" = full ]; }; curl() { return 1; }
SECRETS_ENABLED=(true)
out=$(health_check 2>&1)
grep -q "Бинарник mtdd на месте" <<< "$out" && grep -q "API mtdd отвечает" <<< "$out" || fail "health mtdd: $out"
grep -qi "docker\|контейнер" <<< "$out" && fail "health mtdd говорит о Docker: $out"
unset -f curl

# ── Перенос аргументами цели mtdd: свой тег пользователя (поле 19) ──
source "$repo/lib/argsgen.sh" || fail "source argsgen"
_mtdd_py() { [ "$1" = users-tsv ] && echo "bob|true|0123456789abcdef0123456789abcde2|0|0|0|||0|0|0|0|0|0|0||3|1|fedcba9876543210fedcba9876543210"; }
mtdd_cfg_get() { :; }
_AG_ON=(); _AG_VAL=(); _argsgen_defaults_mtdd >/dev/null 2>&1
[ "$(cut -d'|' -f10 <<< "${_AG_MTDD_USERS[0]:-}")" = fedcba9876543210fedcba9876543210 ] \
    || fail "argsgen: тег пользователя mtdd не перенесён: ${_AG_MTDD_USERS[0]:-}"
[[ "${_AG_VAL[engine]}" == mtdd:main ]] || fail "argsgen: канал по умолчанию: ${_AG_VAL[engine]}"

# ── Проверка доступности при установке: строка по факту ───────
grep -B2 -A6 'install_availability_timer$' "$repo/lib/install.sh" | grep -q 'availability_enabled' \
    || fail "install.sh пишет о проверке доступности без учёта AVAILABILITY_ENABLED"

echo "OK mtdd_screens"
