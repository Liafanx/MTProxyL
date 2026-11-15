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
# tune — синоним «Экспертных параметров mtdd»: значения из конфига одним jq.
source "$repo/lib/expert_catalog.sh"; source "$repo/lib/mtdd_expert.sh"
MTDD_MGR_CONFIG="$t/mtdd-config.json"; MTDD_MGR_TUNE="$t/mtdd-tune.json"
echo '{"masking":true,"me_connections_per_dc":16}' > "$MTDD_MGR_CONFIG"
echo '{"me_connections_per_dc":16}' > "$MTDD_MGR_TUNE"
out=$(mtdd_handle_tune list)
grep -qF '\033' <<< "$out" && fail "сырой escape в списке тюнинга: $(grep -F '\033' <<< "$out" | head -2)"
grep -E ' masking +true' <<< "$out" | grep -q "задаёт MTProxyL" || fail "masking не помечен: $(grep masking <<< "$out")"
grep -E ' workers ' <<< "$out" | grep -q "0–256" || fail "нет умолчания и диапазона: $(grep workers <<< "$out")"
grep -E ' me_connections_per_dc ' <<< "$out" | grep -q "умолч. 16" || fail "заданное значение: $(grep me_conn <<< "$out")"

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

# ── suspects block: записи в общей «Блокировке IP», снятие — только своих ──
source "$repo/lib/ipblock.sh" || fail "source ipblock"
IPBLOCK_FILE="$t/ipblock.list"; IPBLOCK_HITS="$t/hits.tsv"; IPBLOCK_SNAP="$t/hits.snap"
printf '# свой список\n9.9.9.9\n5.6.7.8\n' > "$IPBLOCK_FILE"
nft() { echo "nft $*" >> "$t/nft.log"; return 0; }
ipblock_hits_sample() { :; }
ipblock_apply() { echo apply >> "$t/ipapply.log"; }
# Вход — уже приведённый помощником (suspects-ips, см. mtdd_adapter): адрес и
# накрывающая его подсеть, адрес из списка, адреса SSH и панели, клиент прокси.
_mtdd_py() { [ "$1" = suspects-ips ] && printf '%s\n' 1.2.3.4 1.2.3.0/24 5.6.7.8 2001:db8::1 198.51.100.9 203.0.113.0/28 192.0.2.7 'мусор' ''; }
# Соединения сервера: панель (8080) и клиент прокси (порт прокси 443).
PROXY_PORT=443
ss() { printf '%s\n' '0 0 10.0.0.1:8080 [::ffff:203.0.113.5]:51000' '0 0 10.0.0.1:443 192.0.2.7:40000'; }
SSH_CONNECTION="198.51.100.9 50000 10.0.0.1 22"; IPBLOCK_ENABLED=false
out=$(mtdd_suspects_block 60 2>&1) || fail "suspects block: $out"
grep -q "198.51.100.9" "$IPBLOCK_FILE" && fail "адрес SSH-сессии заблокирован"
grep -q "203.0.113.0/28" "$IPBLOCK_FILE" && fail "подсеть с адресом панели заблокирована"
grep -q "внутри ваш адрес 203.0.113.5" <<< "$out" && grep -q "внутри ваш адрес 198.51.100.9" <<< "$out" || fail "нет предупреждения про свои адреса: $out"
# Пересечения: /24 накрывает 1.2.3.4 — остаётся одна запись (nft отверг бы обе).
[ "$(mtdd_suspects_blocked | sort | tr '\n' ' ')" = "1.2.3.0/24 192.0.2.7 2001:db8::1 " ] \
    || fail "помеченные записи: $(mtdd_suspects_blocked | tr '\n' ' ')"
[ "$(grep -c '^5.6.7.8' "$IPBLOCK_FILE")" = 1 ] || fail "уже бывший в списке адрес продублирован"
grep -q "мусор" "$IPBLOCK_FILE" && fail "мусор попал в список"
grep -qE '^1\.2\.3\.0/24 +# mtdd suspects score>=60 [0-9]{4}-' "$IPBLOCK_FILE" || fail "формат записи: $(cat "$IPBLOCK_FILE")"
grep -q "Блокировка IP» выключена" <<< "$out" || fail "нет предупреждения о выключенной блокировке: $out"
grep -q "delete table inet mtproxyl_suspects" "$t/nft.log" || fail "старая таблица не снимается"
# Подсеть, в которую попадает уже заблокированный вручную адрес, не добавляется.
_mtdd_py() { [ "$1" = suspects-ips ] && printf '%s\n' 9.9.9.0/24; }
mtdd_suspects_block 60 >/dev/null 2>&1; grep -q '^9.9.9.0/24' "$IPBLOCK_FILE" && fail "подсеть поверх ручного 9.9.9.9 добавлена"
_mtdd_py() { [ "$1" = suspects-ips ] && printf '%s\n' 1.2.3.4 1.2.3.0/24 5.6.7.8 2001:db8::1 198.51.100.9 203.0.113.0/28 192.0.2.7; }
# Повтор не дублирует.
mtdd_suspects_block 60 >/dev/null 2>&1; [ "$(grep -c 'mtdd suspects' "$IPBLOCK_FILE")" = 3 ] || fail "повтор продублировал: $(cat "$IPBLOCK_FILE")"
mtdd_suspects_block 0 >/dev/null 2>&1 && fail "score 0 пропущен"
# Снятие — только своих: ручные записи и комментарии остаются.
mtdd_suspects_unblock >/dev/null 2>&1 || fail "unblock"
[ -z "$(mtdd_suspects_blocked)" ] && grep -q '^9.9.9.9' "$IPBLOCK_FILE" && grep -q '^5.6.7.8' "$IPBLOCK_FILE" \
    && grep -q '^# свой список' "$IPBLOCK_FILE" || fail "unblock задел чужое: $(cat "$IPBLOCK_FILE")"
[ "$(grep -c apply "$t/ipapply.log")" = 2 ] || fail "ipblock_apply: $(grep -c apply "$t/ipapply.log") раз, ждали 2 (блок и снятие)"
# Сводка для панели: одним чтением конфига, число записей в блоке.
mtdd_suspects_block 60 >/dev/null 2>&1
echo '{"suspects":true,"fingerprint":false,"suspect_ban_score":70,"proxy_protocol":false}' > "$t/sus-cfg.json"
DETECTED_CONFIG_PATH="$t/sus-cfg.json"
_mtdd_call() { echo '{"total":2,"watched":1,"shadow_banned":0,"by_matches":{"2":1},"suspects":[{"ip":"1.2.3.4","score":80,"matches":2}]}'; }
j=$(handle_suspects_command status --json) || fail "suspects status --json"
jq -e '.available and .enabled and (.fingerprint | not) and .ban_score == 70 and .watch_score == 60 and .blocked == 3
       and (.ipblock_enabled | not) and .total == 2 and (.suspects | length) == 1' <<< "$j" >/dev/null || fail "status json: $j"
_mtdd_call() { MTDD_LAST_ERROR="не знает маршрут"; return 1; }
j=$(handle_suspects_command status --json)
jq -e '(.available | not) and .error == "не знает маршрут" and .suspects == []' <<< "$j" >/dev/null || fail "status без API: $j"
unset -f nft ss _mtdd_call ipblock_apply ipblock_hits_sample; unset SSH_CONNECTION

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

# ── Мастер установки: у mtdd нет только WEB, WARP и upstream есть ──
grep -q 'служба systemd; без WEB-режима' "$repo/lib/install.sh" || fail "строка mtdd в мастере установки"
grep -Eq 'mtdd .*без (WEB, )?WARP|mtdd .*без .*upstream' "$repo/lib/install.sh" && fail "мастер всё ещё пишет, что у mtdd нет WARP/upstream"

echo "OK mtdd_screens"
