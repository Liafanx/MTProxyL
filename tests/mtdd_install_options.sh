#!/bin/bash
# Медиа и каталог mtdd: установка, сохранение соседних полей, перенос и откат.
set -o pipefail
cd "$(dirname "$0")/.." || exit 1
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
INSTALL_DIR="$t/install"; mkdir -p "$INSTALL_DIR"
for f in lib/*.sh; do source "$f" >/dev/null 2>&1; done
fail() { echo "FAIL: $*" >&2; exit 1; }
log_error() { echo "ERR: $*" >&2; }; log_info() { :; }; log_success() { :; }; log_warn() { :; }
systemctl() { return 1; }; chown() { :; }; useradd() { :; }
get_public_ip() { echo 203.0.113.10; }
uname() { [ "${1:-}" = -m ] && echo x86_64 || command uname "$@"; }
mtdd_restart() { echo restart >> "$t/applied"; }
mtdd_reload() { echo reload >> "$t/applied"; }
MTPROXYL_MODE=manager; ENGINE_KIND=mtdd; mtdd_mgr_ctx
_mtdd_mgr_prepare_dirs() { mkdir -p "$MTDD_MGR_DIR" "$MTDD_MGR_STATE"; }
SETTINGS_FILE="$INSTALL_DIR/settings.conf"; BACKUP_DIR="$t/backups"; mkdir -p "$BACKUP_DIR"
PROXY_PORT=8443; PROXY_API_PORT=9091; PROXY_METRICS_PORT=9190; PROXY_DOMAIN=example.org
MASKING_ENABLED=true; MASKING_HOST=""; MASKING_PORT=443; AD_TAG=""
_mtdd_mgr_prepare_dirs
install_test_bin() {
    if [ -n "${MTDD_TEST_BIN:-}" ]; then cp "$MTDD_TEST_BIN" "$MTDD_MGR_BIN"
    else printf '#!/bin/sh\nexit 0\n' > "$MTDD_MGR_BIN"; fi
    chmod +x "$MTDD_MGR_BIN"
}
install_test_bin
generate_mtdd_config || fail 'начальный конфиг'

parse() {
    source lib/install_args.sh
    _install_args_parse "$@" && _install_args_validate
}
parse --engine mtdd --mtdd-media-user-mbps 20,125 --mtdd-media-total-mbps 500 \
    --mtdd-tune workers=4 --mtdd-tune cpu_affinity=false \
    --mtdd-tune 'watch_ips=192.0.2.10,198.51.100.0/24' || fail 'годные параметры'
_install_args_apply_mtdd_options || fail 'применение Manager'
jq -e '.media_user_rate_kbps == 20125 and .media_total_rate_kbps == 500000 and .workers == 4 and .cpu_affinity == false and .watch_ips == ["192.0.2.10","198.51.100.0/24"]' "$MTDD_MGR_CONFIG" >/dev/null || fail 'конфиг Manager'
[ ! -e "$t/applied" ] || fail 'Manager запустил движок до завершения установки'
[ "$(stat -c %a "$MTDD_MGR_TUNE")" = 600 ] || fail 'права tune.json'

parse --engine mtdd --mtdd-media-user-mbps 0 || fail 'ноль'
_install_args_apply_mtdd_options || fail 'отключение одного лимита'
jq -e '.media_user_rate_kbps == 0 and .media_total_rate_kbps == 500000 and .workers == 4' "$MTDD_MGR_CONFIG" >/dev/null || fail 'соседний лимит или workers сброшен'
parse --engine mtdd || fail 'без настроек'
[ ${#_IA_MTDD_PAIRS[@]} -eq 0 ] || fail 'пропущенные параметры перезаписываются'

before=$(sha256sum "$MTDD_MGR_CONFIG" "$MTDD_MGR_TUNE")
for v in -1 nan 100000.001 999999999999999999999999999999 1.0001; do
    parse --engine mtdd --mtdd-media-user-mbps "$v" >/dev/null 2>&1 && fail "принят лимит $v"
done
for v in workers=257 workers=18446744073709551617 cpu_affinity=maybe \
    direct_fallback_dcs=203 unknown=1 api_token_env=secret proxy_port=9443 masking=false; do
    parse --engine mtdd --mtdd-tune "$v" >/dev/null 2>&1 && fail "принят $v"
done
parse --engine mtdd --mtdd-media-user-mbps '' >/dev/null 2>&1 && fail 'пустой лимит'
parse --engine binary --mtdd-media-user-mbps 20 >/dev/null 2>&1 && fail 'медиа с telemt'
parse --mode manager --target mtdd >/dev/null 2>&1 && fail 'target в Manager'
parse --engine mtdd --mtdd-tune workers=4 --mtdd-tune workers=2 >/dev/null 2>&1 && fail 'повтор ключа'
parse --engine mtdd --mtdd-media-user-mbps 20 --mtdd-tune media_user_rate_kbps=20000 >/dev/null 2>&1 && fail 'повтор медиа-ключа'
[ "$before" = "$(sha256sum "$MTDD_MGR_CONFIG" "$MTDD_MGR_TUNE")" ] || fail 'валидация меняет файлы'
parse --engine mtdd --mtdd-media-total-mbps 100000 || fail 'верхняя граница'
[ "${_IA_MTDD_PAIRS[0]}" = media_total_rate_kbps=100000000 ] || fail 'единицы верхней границы'
parse --engine mtdd --mtdd-tune=workers=04 --mtdd-tune watch_ips= || fail 'ключ=значение и пустой список'
[ "${_IA_MTDD_PAIRS[0]}" = workers=4 ] && [ "${_IA_MTDD_PAIRS[1]}" = 'watch_ips=[]' ] || fail 'приведение типов'

# Все доступные ключи каталога принимаются тем же валидатором установки.
for e in "${_MTDD_CATALOG[@]}"; do
    _expert_parse "$e"; key="$EXPERT_P_KEY"; value="$EXPERT_P_DEFAULT"
    _mtdd_mgr_is_managed_key "$key" && continue
    case "$EXPERT_P_VALIDATOR" in
        range:*) bounds="${EXPERT_P_VALIDATOR#range:}"; value="${bounds%%:*}" ;;
        custom:_mtdd_valid_dcs) value='1,-1' ;;
        custom:_mtdd_valid_addrs) value='192.0.2.0/24,2001:db8::/32' ;;
    esac
    parse --engine mtdd --mtdd-tune "${key}=${value}" || fail "каталог: $key"
done

# Настройки переносятся в аргументы, закрытые ключи туда не попадают.
_mtdd_install_export_args || fail 'экспорт'
exported=("${_MTDD_INSTALL_ARGS[@]}")
parse --engine mtdd "${exported[@]}" || fail 'обратный разбор'
[[ " ${exported[*]} " == *' --mtdd-media-total-mbps 500.000 '* ]] || fail 'медиа в экспорте'
[[ " ${exported[*]} " == *' workers=4 '* ]] || fail 'workers в экспорте'
[[ " ${exported[*]} " != *'api_token_env='* ]] || fail 'токен в экспорте'
printf '#!/bin/sh\nexit 1\n' > "$MTDD_MGR_BIN"
parse --engine mtdd --mtdd-media-total-mbps 100 || fail 'параметры отката'
_install_args_apply_mtdd_options >/dev/null 2>&1 && fail 'бинарник отклонил конфиг, успех'
[ "$before" = "$(sha256sum "$MTDD_MGR_CONFIG" "$MTDD_MGR_TUNE")" ] || fail 'конфиг/tune не откатились'
install_test_bin

# Reanimator меняет конфиг цели; горячие ключи — reload, холодные — restart.
cp "$MTDD_MGR_CONFIG" "$t/target.json"
MTPROXYL_MODE=reanimator; DETECTED_MODE=mtdd; DETECTED_CONFIG_PATH="$t/target.json"
mtdd_mgr_ctx
MTDD_BIN_DEFAULT="$MTDD_MGR_BIN"
parse --mode reanimator --target mtdd --mtdd-media-user-mbps 0.001 || fail 'параметры цели'
_install_args_apply_mtdd_options || fail 'применение цели'
jq -e '.media_user_rate_kbps == 1 and .media_total_rate_kbps == 500000' "$t/target.json" >/dev/null || fail 'конфиг цели'
[ "$(cat "$t/applied")" = reload ] || fail 'горячее применение'
rm "$t/applied"
parse --mode reanimator --target mtdd --mtdd-tune workers=2 || fail 'холодный ключ'
_install_args_apply_mtdd_options || fail 'холодное применение'
[ "$(cat "$t/applied")" = restart ] || fail 'нет перезапуска'
mtdd_reload() { return 1; }
parse --mode reanimator --target mtdd --mtdd-media-user-mbps 2 || fail 'параметры отказа reload'
_install_args_apply_mtdd_options >/dev/null 2>&1 && fail 'ошибка reload скрыта'
echo 'OK mtdd_install_options'
