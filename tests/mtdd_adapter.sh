#!/bin/bash
# Адаптер цели mtdd (lib/mtdd.sh) против поддельного API mtdd: пользователи,
# лимиты, перевод скорости, переименование с откатом, экспорт/импорт, старая
# сборка без полного API, правка JSON-конфига с проверкой и защита TOML-писателей.
# Форма ответов взята с настоящих сборок mtdd (main и dev).
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "SKIP mtdd_adapter: нет python3"; exit 0; }
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

# Поддельный бинарник: --check-config проходит, пока нет файла check_fail.
cat > "$t/mtdd" <<EOF
#!/bin/sh
case "\$*" in
  *--check-config*) [ -f "$t/check_fail" ] && { echo "bad key" >&2; exit 1; }; exit 0 ;;
  *--version*) echo "mtdd 0.1.0" ;;
esac
EOF
chmod +x "$t/mtdd"
echo "MTDD_API_TOKEN=${TOKEN}" > "$t/credentials.env"
cat > "$t/config.json" <<EOF
{"proxy_host": "0.0.0.0", "proxy_port": 8443, "public_host": "203.0.113.10",
 "control_host": "127.0.0.1", "control_port": ${port}, "api_token_env": "MTDD_API_TOKEN",
 "tls_domain": "example.org", "ad_tag": "0123456789abcdef0123456789abcdef",
 "users_path": "/nonexistent/users.json"}
EOF

INSTALL_DIR="$t/install"; VERSION=test
mkdir -p "$INSTALL_DIR/relay_stats"
source "$repo/lib/colors.sh" || true
for _lib in utils settings detect mtdd secrets; do source "$repo/lib/$_lib.sh"; done
BACKUP_DIR="$t/backups"; mkdir -p "$BACKUP_DIR"
SECRETS_FILE="$t/secrets.conf"
MTDD_BIN_DEFAULT="$t/mtdd"; MTDD_ENV_DEFAULT="$t/credentials.env"
MTDD_CHANNEL_FILE="$t/mtdd.channel"
_TARGET_USER_IPS_DB="$t/ips.db"
systemctl() { return 1; }
journalctl() { :; }
check_root() { :; }
_mktemp() { mktemp "${1:-$t}/.tmp.XXXXXX"; }
MTPROXYL_MODE=reanimator
DETECTED_MODE=mtdd; DETECTED_CONFIG_PATH="$t/config.json"; DETECTED_NETWORK_MODE=host

# ── Связь и возможности сборки ───────────────────────────────
probe=$(_mtdd_py probe) || fail "probe"
grep -qx 'api=ok' <<< "$probe" || fail "probe: $probe"
grep -qx 'full=1' <<< "$probe" || fail "полная сборка не распознана: $probe"
[ "$(mtdd_cfg_get tls_domain)" = "example.org" ] || fail "cfg-get"
[ "$(mtdd_public_port)" = "8443" ] || fail "порт прокси: $(mtdd_public_port)"
[ "$(mtdd_api_port)" = "$port" ] || fail "порт API"

# ── Пользователи ─────────────────────────────────────────────
BOB=ffeeddccbbaa99887766554433221100
mtdd_user_add bob "$BOB" >/dev/null 2>&1 || fail "add bob"
mtdd_user_add bob2 "$BOB" >/dev/null 2>&1 && fail "повторный ключ принят"
mtdd_user_add 'bad name' >/dev/null 2>&1 && fail "метка с пробелом принята"
# Правило имён mtdd шире, чем у telemt: точка и до 64 символов.
mtdd_user_add ivan.p >/dev/null 2>&1 || fail "метка с точкой (правило mtdd) не принята"
_secret_parse_line "ivan.p|${BOB}|true" || fail "импорт: метка с точкой для цели mtdd"
mtdd_user_remove .. >/dev/null 2>&1 && fail "метка '..' попала в путь API"
mtdd_user_remove ivan.p >/dev/null 2>&1 || fail "remove ivan.p"
[ "$(cli_lock_kind target-api snapshot)" = none ] || fail "снимок для панели берёт замок CLI"
[ "$(_mtdd_py secret-of "$(mtdd_user_link bob)")" = "$BOB" ] || fail "секрет из ссылки"
row=$(_mtdd_py users-tsv | awk -F'|' '$1=="bob"')
[ "$(cut -d'|' -f3 <<< "$row")" = "$BOB" ] || fail "users-tsv: секрет ($row)"

# --no-links: один запрос списка вместо запроса на каждого.
echo 0 > "$t/mock_count"
_mtdd_py users-tsv --no-links >/dev/null || fail "users-tsv --no-links"
[ "$(cat "$t/mock_count")" = 1 ] || fail "--no-links сделал $(cat "$t/mock_count") запросов"
[ -z "$(_mtdd_py users-tsv --no-links | awk -F'|' '$1=="bob" {print $3}')" ] || fail "--no-links отдал секрет"

# Скорость: MTProxyL считает в бит/с, mtdd — в байт/с от 1024.
mtdd_user_setrate bob 8M 0 >/dev/null 2>&1 || fail "setrate 8M"
row=$(_mtdd_py users-tsv --no-links | awk -F'|' '$1=="bob"')
[ "$(cut -d'|' -f9 <<< "$row")" = "8000000" ] || fail "скорость вверх: $(cut -d'|' -f9 <<< "$row")"
[ "$(cut -d'|' -f10 <<< "$row")" = "0" ] || fail "скорость вниз должна быть снята"
mtdd_user_setrate bob 4k 0 >/dev/null 2>&1 && fail "4 кбит/с (меньше 1024 байт/с) принято"

# Лимиты: 0 снимает, пусто не трогает.
mtdd_user_setlimits bob 5 3 1073741824 2030-01-01 >/dev/null 2>&1 || fail "setlimits"
row=$(_mtdd_py users-tsv --no-links | awk -F'|' '$1=="bob"')
[ "$(cut -d'|' -f4-6 <<< "$row")" = "5|3|1073741824" ] || fail "лимиты: $row"
[[ "$(cut -d'|' -f7 <<< "$row")" == 2030-01-01* ]] || fail "срок: $row"
mtdd_user_setlimits bob 0 "" "" >/dev/null 2>&1 || fail "снять лимит соединений"
row=$(_mtdd_py users-tsv --no-links | awk -F'|' '$1=="bob"')
[ "$(cut -d'|' -f4-6 <<< "$row")" = "0|3|1073741824" ] || fail "снятие лимита задело другие: $row"

mtdd_user_toggle bob disable >/dev/null 2>&1 || fail "disable"
[ "$(_mtdd_py users-tsv --no-links | awk -F'|' '$1=="bob" {print $2}')" = false ] || fail "не выключен"
mtdd_user_toggle bob enable >/dev/null 2>&1 || fail "enable"
mtdd_user_note bob "Иван | 123" >/dev/null 2>&1 || fail "note"
[ "$(mtdd_user_note bob)" = "Иван   123" ] || fail "заметка: '$(mtdd_user_note bob)'"

# Переименование: DELETE + POST с тем же ключом и политикой.
mtdd_user_rename bob robert >/dev/null 2>&1 || fail "rename"
_mtdd_user_exists bob && fail "старое имя осталось"
row=$(_mtdd_py users-tsv | awk -F'|' '$1=="robert"')
[ "$(cut -d'|' -f3 <<< "$row")" = "$BOB" ] || fail "ключ не сохранился при переименовании: $row"
[ "$(cut -d'|' -f9 <<< "$row")" = "8000000" ] || fail "скорость потерялась при переименовании"
[ "$(cut -d'|' -f8 <<< "$row")" = "Иван   123" ] || fail "заметка потерялась при переименовании"
# Сбой создания под новым именем — прежний пользователь возвращается.
echo 1 > "$t/mock_fail_post"
mtdd_user_rename robert rob >/dev/null 2>&1 && fail "rename со сбоем вернул успех"
_mtdd_user_exists rob && fail "rob создан, хотя POST упал"
row=$(_mtdd_py users-tsv | awk -F'|' '$1=="robert"')
[ "$(cut -d'|' -f3 <<< "$row")" = "$BOB" ] || fail "откат не вернул robert с ключом: $row"

mtdd_user_rotate robert 0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f >/dev/null 2>&1 || fail "rotate"
[ "$(_mtdd_py secret-of "$(mtdd_user_link robert)")" = 0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f ] || fail "rotate: ключ"

# Шим /v1/users в форме telemt: его читают меню, бот и шейпинг.
uj=$(_get_telemt_users_json "$DETECTED_CONFIG_PATH") || fail "_get_telemt_users_json"
python3 -I - "$uj" <<'PY' || fail "форма users-telemt"
import json, sys
d = json.loads(sys.argv[1])
assert d["ok"] is True
r = {u["username"]: u for u in d["data"]}["robert"]
assert r["rate_limit_up_bps"] == 8000000, r
assert r["total_octets"] == 300 and r["current_connections"] == 1, r
assert r["links"]["tls"][0].startswith("tg://proxy?"), r
assert r["active_unique_ips_list"] == ["198.51.100.7"], r
PY
aj=$(_mtdd_py active-ips) || fail "active-ips"
grep -q '"198.51.100.7"' <<< "$aj" || fail "active-ips: $aj"

# ── Секреты из users.json вместо запроса ссылки на каждого ───
n_users=$(_mtdd_py users-tsv --no-links | wc -l)
echo 0 > "$t/mock_count"; _mtdd_py users-tsv >/dev/null
slow=$(cat "$t/mock_count")
[ "$slow" = $((n_users + 1)) ] || fail "без users.json: $slow запросов на $n_users пользователей"
mtdd_config_set "users_path=$t/users.json" >/dev/null 2>&1 || fail "users_path"
echo 0 > "$t/mock_count"; fast_rows=$(_mtdd_py users-tsv)
[ "$(cat "$t/mock_count")" = 2 ] || fail "с users.json: $(cat "$t/mock_count") запросов (ждали 2)"
[ "$fast_rows" = "$(mtdd_config_set "users_path=/nonexistent/users.json" >/dev/null 2>&1; _mtdd_py users-tsv)" ] \
    || fail "быстрый и медленный путь разошлись"
mtdd_config_set "users_path=$t/users.json" >/dev/null 2>&1
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["revision"]-=1; json.dump(d,open(p,"w"))' "$t/users.json"
echo 0 > "$t/mock_count"; _mtdd_py users-tsv >/dev/null
[ "$(cat "$t/mock_count")" = $((n_users + 1)) ] || fail "устаревший users.json использован"

# ── Снимок для панели ────────────────────────────────────────
snap=$(_mtdd_py snapshot) || fail "snapshot"
python3 -I - "$snap" <<'PY' || fail "форма снимка"
import json, sys
s = json.loads(sys.argv[1])
assert s["engine"] == "mtdd" and s["full_api"] is True
names = {u["username"] for u in s["users"]}
assert "robert" in names and "admin" in names, names
sm = s["summary"]
assert sm["connections_total"] == 10 and sm["connections_bad_total"] == 3, sm
assert sm["handshake_timeouts_total"] == 2, sm
assert {c["class"] for c in sm["handshake_failures_by_class"]} == {"replay"}, sm
assert sm["configured_users"] == len(s["users"]), sm
assert s["health"]["status"] == "ok" and s["system_info"]["version"] == "0.1.0"
assert [d["dc"] for d in s["dcs"]["dcs"]] == [2], s["dcs"]
assert s["dcs"]["dcs"][0]["coverage_pct"] == 100.0
assert s["active_ips"] and s["active_ips"][0]["active_ips"] == ["198.51.100.7"], s["active_ips"]
assert any(q["username"] == "robert" for q in s["quota"]["users"]), s["quota"]
PY

# ── Экспорт и импорт ─────────────────────────────────────────
mtdd_users_export "$t/export.csv" >/dev/null 2>&1 || fail "export"
grep -q "^robert|0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f|true|" "$t/export.csv" || fail "export: $(cat "$t/export.csv")"
mtdd_user_remove robert >/dev/null 2>&1 || fail "remove"
mtdd_users_import "$t/export.csv" >/dev/null 2>&1 || fail "import"
row=$(_mtdd_py users-tsv | awk -F'|' '$1=="robert"')
[ "$(cut -d'|' -f3 <<< "$row")" = 0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f ] || fail "import: ключ ($row)"
[ "$(cut -d'|' -f5 <<< "$row")" = 3 ] || fail "import: лимит IP ($row)"
out=$(mtdd_users_import "$t/export.csv" 2>&1)
grep -q "пропущено дубликатов: 2" <<< "$out" || fail "повторный импорт: $out"

# ── Конфиг: правка через проверку бинарником ─────────────────
mtdd_config_set media_user_rate_kbps=20000 >/dev/null 2>&1 || fail "cfg-set"
[ "$(mtdd_cfg_get media_user_rate_kbps)" = 20000 ] || fail "cfg-set не записал"
ls "$BACKUP_DIR"/* >/dev/null 2>&1 || fail "нет резервной копии конфига"
touch "$t/check_fail"
mtdd_config_set masking=false >/dev/null 2>&1 && fail "проверка конфига провалилась, а запись прошла"
[ "$(mtdd_cfg_get masking 2>/dev/null)" != false ] || fail "отклонённый конфиг записан"
rm -f "$t/check_fail"
mtdd_reload() { :; }
mtdd_media_set 2.5 500 >/dev/null 2>&1 || fail "media set"
[ "$(mtdd_cfg_get media_user_rate_kbps)" = 2500 ] || fail "media: $(mtdd_cfg_get media_user_rate_kbps)"
[ "$(mtdd_cfg_get media_total_rate_kbps)" = 500000 ] || fail "media total"
mtdd_tune_set api_token_env X >/dev/null 2>&1 && fail "tune пустил ключ токена"

# Писатели TOML для цели mtdd должны отказывать, а не портить JSON.
cp "$t/config.json" "$t/config.before"
_toml_safe_set "$DETECTED_CONFIG_PATH" general.links public_host '"x"' >/dev/null 2>&1 && fail "_toml_safe_set прошёл для mtdd"
cmp -s "$t/config.json" "$t/config.before" || fail "TOML-писатель изменил config.json"

# ── Selfmask: повторное применение не затирает снимок «до» ────
read_line() { printf -v "$1" '%s' y; }
SELFMASK_NGINX_BACKEND_PORT=8443; SELFMASK_PREV_SAVED=false
mtdd_config_set masking=false >/dev/null 2>&1 || fail "masking=false"
SELFMASK_DOMAIN=mask1.example; mtdd_selfmask_apply >/dev/null 2>&1 || fail "selfmask 1"
SELFMASK_DOMAIN=mask2.example; mtdd_selfmask_apply >/dev/null 2>&1 || fail "selfmask 2"
[ "$SELFMASK_PREV_DOMAIN" = example.org ] || fail "второй selfmask затёр снимок: $SELFMASK_PREV_DOMAIN"
mtdd_selfmask_restore >/dev/null 2>&1 || fail "selfmask restore"
[ "$(mtdd_cfg_get tls_domain)" = example.org ] || fail "restore: tls_domain $(mtdd_cfg_get tls_domain)"
[ "$(mtdd_cfg_get masking)" = false ] || fail "restore: masking $(mtdd_cfg_get masking)"
[ "$(mtdd_cfg_get public_host)" = 203.0.113.10 ] || fail "restore: public_host"
mtdd_cfg_get fallback_port >/dev/null 2>&1 && fail "restore: fallback_port остался"
unset -f read_line

# ── Старая сборка (main): чтение работает, мутации объясняют отказ ──
echo old > "$t/mock_mode"
probe=$(_mtdd_py probe) || fail "probe old"
grep -qx 'full=0' <<< "$probe" || fail "старая сборка не распознана: $probe"
_mtdd_py users-tsv >/dev/null || fail "чтение на старой сборке"
out=$(mtdd_user_setrate robert 8M 0 2>&1) && fail "PATCH на старой сборке прошёл"
grep -q "engine update" <<< "$out" || fail "нет подсказки про обновление: $out"
body=$(mtdd_user_body carol 0123456789abcdef0123456789abcdef true 3 2 100 0 "note" "8000:8000")
[ "$body" = '{"name": "carol", "secret": "0123456789abcdef0123456789abcdef", "max_connections": 3}' ] \
    || fail "тело для старой сборки: $body"
mtdd_user_body dave 0123456789abcdef0123456789abcdef false 0 0 0 0 "" "" >/dev/null 2>&1 \
    && fail "выключенный пользователь заводится на сборке, которая не умеет выключать"
mtdd_user_add carol 0123456789abcdef0123456789abcdef >/dev/null 2>&1 || fail "add на старой сборке"
# Панель после создания шлёт нулевые лимиты и пустую заметку — это не правка.
mtdd_user_setlimits carol 0 0 0 0 >/dev/null 2>&1 || fail "нулевые лимиты на старой сборке отклонены"
mtdd_user_note carol "" >/dev/null 2>&1 || fail "пустая заметка на старой сборке отклонена"
mtdd_user_setrate carol 0 0 >/dev/null 2>&1 || fail "нулевая скорость на старой сборке отклонена"
mtdd_user_setlimits carol 0 5 >/dev/null 2>&1 && fail "настоящая правка лимита на старой сборке прошла"
mtdd_user_remove carol >/dev/null 2>&1 || fail "DELETE на старой сборке"

# ── Токен ────────────────────────────────────────────────────
echo full > "$t/mock_mode"
echo "MTDD_API_TOKEN=wrong" > "$t/credentials.env"
_mtdd_py users-tsv >/dev/null 2>&1; [ $? -eq 4 ] || fail "чужой токен: ожидался код 4"
_target_section_pairs access.users >/dev/null 2>&1 && fail "сбой API выдан за пустой список пользователей"
grep -q "отклонил токен" <<< "$(mtdd_api_unavailable_reason)" || fail "причина про токен"

echo "OK mtdd_adapter"
