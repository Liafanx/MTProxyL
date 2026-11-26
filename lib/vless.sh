#!/bin/bash
# MTProxyL — исходящий маршрут через VLESS (Xray-core).
#
# Локальный Xray слушает SOCKS5 на 127.0.0.1, движок ходит в него обычным
# upstream socks5 — как вариант C у WARP. Хост и другие службы не затрагиваются.
# Ссылки (vless://) и подписка хранятся отдельно; вторая копия секретов —
# только в бэкапе.

VLESS_VERSION="26.11.9"
VLESS_UNIT="mtproxyl-vless.service"
VLESS_WATCH_UNIT="mtproxyl-vless-watch"
VLESS_USER="mtproxyl-vless"
VLESS_UPSTREAM_NAME="vless"
VLESS_UPSTREAM_LOCAL="vlesslocal"

_vless_dir()     { echo "${INSTALL_DIR:-/opt/mtproxyl}/vless"; }
_vless_bin()     { echo "$(_vless_dir)/xray"; }
_vless_prev()    { echo "$(_vless_dir)/xray.prev"; }
_vless_conf()    { echo "$(_vless_dir)/config.json"; }
_vless_links()   { echo "$(_vless_dir)/links.conf"; }
_vless_subs()    { echo "$(_vless_dir)/subscriptions.conf"; }
_vless_state()   { echo "$(_vless_dir)/state.json"; }
_vless_parser()  {
    local _p
    _p="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vless_parse.py"
    [ -f "$_p" ] || _vless_restore_parser "$_p" || return 1
    echo "$_p"
}

# Комплект 1.8.4 не копировал .py при обновлении: достаём из кэша релиза.
_vless_restore_parser() {
    local _dst="$1" _arc _tmp _url
    [ -n "${VERSION:-}" ] || { log_error "Не найден lib/vless_parse.py"; return 1; }
    _arc="${INSTALL_DIR:-/opt/mtproxyl}/releases/mtproxyl-${VERSION}.tar.gz"
    _tmp=$(mktemp) || return 1
    if [ -f "$_arc" ]; then
        tar -xzOf "$_arc" "mtproxyl-${VERSION}/lib/vless_parse.py" > "$_tmp" 2>/dev/null \
            || { rm -f "$_tmp"; log_error "Не удалось восстановить lib/vless_parse.py из архива ${VERSION}"; return 1; }
    else
        _url="https://raw.githubusercontent.com/${GITHUB_REPO:-Liafanx/MTProxyL}/v${VERSION}/lib/vless_parse.py"
        curl -fsSL --retry 2 --max-time 30 "$_url" -o "$_tmp" 2>/dev/null \
            || { rm -f "$_tmp"; log_error "Не найден lib/vless_parse.py; выполните mtproxyl update или переустановите MTProxyL"; return 1; }
    fi
    python3 -I -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$_tmp" 2>/dev/null \
        || { rm -f "$_tmp"; log_error "Повреждён lib/vless_parse.py для ${VERSION}"; return 1; }
    install -m 644 "$_tmp" "${_dst}.new" && mv -f "${_dst}.new" "$_dst" \
        || { rm -f "$_tmp"; return 1; }
    rm -f "$_tmp"
    printf '  Восстановлен lib/vless_parse.py из версии %s\n' "$VERSION" >&2
}
_vless_port() {
    local _p="${VLESS_PORT:-41100}"
    [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ] || _p=41100
    echo "$_p"
}
_vless_unit_dir() { echo /etc/systemd/system; }

_vless_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        *) return 1 ;;
    esac
}

_vless_core_version() {
    local _b="$(_vless_bin)"
    [ -x "$_b" ] || return 1
    "$_b" version 2>/dev/null | awk 'NR==1 {print $2}'
}

_vless_parse() { python3 -I "$(_vless_parser)" "$@"; }

# ── Ядро ────────────────────────────────────────────────────
_vless_core_usable() {
    local _b="${1:-$(_vless_bin)}"
    [ -x "$_b" ] || return 1
    "$_b" version >/dev/null 2>&1
}

_vless_core_install() {
    local _force="${1:-false}" _dir; _dir=$(_vless_dir)
    mkdir -p "$_dir" || return 1
    chmod 700 "$_dir"
    if [ "$_force" != true ] && [ "$(_vless_core_version)" = "$VLESS_VERSION" ] && _vless_core_usable; then
        log_success "Xray ${VLESS_VERSION} уже установлен"
        return 0
    fi
    local _arch; _arch=$(_vless_arch) || { log_error "Архитектура $(uname -m) не поддерживается"; return 1; }
    local _base="https://github.com/XTLS/Xray-core/releases/download/v${VLESS_VERSION}"
    local _zip="Xray-linux-${_arch}.zip"
    local _tmp; _tmp=$(mktemp -d /tmp/mtproxyl-xray.XXXXXX) || return 1
    log_info "Скачиваем Xray ${VLESS_VERSION} (${_arch})..."
    if ! curl -fsSL --max-time 300 "${_base}/${_zip}" -o "${_tmp}/${_zip}" 2>/dev/null; then
        rm -rf "$_tmp"; log_error "Не удалось скачать Xray ${VLESS_VERSION}"; return 1
    fi
    if ! curl -fsSL --max-time 60 "${_base}/${_zip}.dgst" -o "${_tmp}/${_zip}.dgst" 2>/dev/null; then
        rm -rf "$_tmp"; log_error "Не удалось скачать контрольную сумму Xray"; return 1
    fi
    local _want _got
    _want=$(sed -n 's/^SHA2-256= *//p' "${_tmp}/${_zip}.dgst" | head -1 | tr -d ' \r')
    _got=$(sha256sum "${_tmp}/${_zip}" | awk '{print $1}')
    if [ -z "$_want" ] || [ "$_want" != "$_got" ]; then
        rm -rf "$_tmp"; log_error "SHA256 Xray не совпала"; return 1
    fi
    if ! python3 -I - "${_tmp}/${_zip}" "$_tmp" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extract("xray", sys.argv[2])
PY
    then
        rm -rf "$_tmp"; log_error "Архив Xray не распаковался"; return 1
    fi
    chmod 755 "${_tmp}/xray"
    if ! "${_tmp}/xray" version >/dev/null 2>&1; then
        rm -rf "$_tmp"; log_error "Скачанный Xray не запускается"; return 1
    fi
    # Новый бинарник обязан принять текущий конфиг: иначе откат уже поздно.
    if [ -f "$(_vless_conf)" ] && ! "${_tmp}/xray" run -test -c "$(_vless_conf)" >/dev/null 2>&1; then
        rm -rf "$_tmp"; log_error "Новый Xray не принял текущий конфиг — оставляем прежний"; return 1
    fi
    [ -x "$(_vless_bin)" ] && cp -p "$(_vless_bin)" "$(_vless_prev)" 2>/dev/null
    install -m 755 "${_tmp}/xray" "$(_vless_bin)" || { rm -rf "$_tmp"; return 1; }
    rm -rf "$_tmp"
    log_success "Xray ${VLESS_VERSION} установлен: $(_vless_bin)"
}

vless_core_rollback() {
    check_root
    [ -x "$(_vless_prev)" ] || { log_error "Предыдущей сборки Xray нет"; return 1; }
    "$(_vless_prev)" version >/dev/null 2>&1 || { log_error "Предыдущая сборка Xray не запускается"; return 1; }
    cp -p "$(_vless_bin)" "$(_vless_dir)/xray.bad" 2>/dev/null || true
    install -m 755 "$(_vless_prev)" "$(_vless_bin)" || return 1
    log_success "Xray откатан на $(_vless_core_version)"
    [ "${1:-}" = --restart ] || vless_service_restart
}

# ── Ссылки ──────────────────────────────────────────────────
_vless_uri_id() { printf '%s' "$1" | sha256sum | cut -c1-8; }

_vless_valid_uri() { _vless_parse check "$1" >/dev/null 2>&1; }

_vless_link_row() { awk -F'|' -v id="$1" '$1 == id {print; exit}' "$(_vless_links)" 2>/dev/null; }

_vless_link_uri() { _vless_link_row "$1" | cut -d'|' -f4-; }

_vless_mask_uri() {
    # Оставляем схему, хост, порт и параметры безопасности; id/ключи скрыты.
    local _uri="$1" _host _sec
    _host=$(python3 -I -c '
import sys
from urllib.parse import urlsplit, parse_qs
u = urlsplit(sys.argv[1])
q = parse_qs(u.query)
print("%s:%s" % (u.hostname or "?", u.port or ""))
' "$_uri" 2>/dev/null) || _host="?"
    _sec=$(_vless_parse check "$_uri" 2>/dev/null | python3 -I -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print("%s/%s%s" % (d.get("security","?"), d.get("transport","?"),
                   "+enc" if d.get("encryption") not in (None,"","none") else ""))
' 2>/dev/null)
    echo "vless://***@${_host:-?} (${_sec:-?})"
}

vless_link_add() {
    local _uri="${1:-}" _name="${2:-}" _src="${3:-manual}" _id _exist
    check_root
    [ -n "$_uri" ] || { log_error "Использование: mtproxyl vless link add '<vless://…>' [имя]"; return 1; }
    _vless_parse check "$_uri" >/dev/null 2>&1 || { _vless_parse check "$_uri" 2>&1 | tail -1; return 1; }
    mkdir -p "$(_vless_dir)" || return 1
    _id=$(_vless_uri_id "$_uri")
    _exist=$(_vless_link_row "$_id")
    [ -n "$_exist" ] && { log_warn "Такая ссылка уже есть: ${_id}"; return 0; }
    [ -n "$_name" ] || _name=$(_vless_parse check "$_uri" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null)
    _name=${_name//|//}
    local _f; _f=$(_vless_links)
    local _tmp; _tmp=$(mktemp "${_f}.XXXXXX") || return 1
    { [ -f "$_f" ] && cat "$_f"; printf '%s|%s|%s|%s\n' "$_id" "$_name" "$_src" "$_uri"; } > "$_tmp"
    chmod 600 "$_tmp" && mv -f "$_tmp" "$_f" || return 1
    [ -n "${VLESS_ACTIVE:-}" ] || { VLESS_ACTIVE="$_id"; save_settings; }
    log_success "Ссылка добавлена: ${_id} ${_name}"
}

vless_link_list() {
    local _f; _f=$(_vless_links)
    [ -s "$_f" ] || { log_info "Ссылок нет: mtproxyl vless link add '<vless://…>'"; return 0; }
    echo ""
    draw_header "VLESS: ССЫЛКИ"
    echo ""
    printf "  %-9s %-22s %-8s %s\n" "ID" "Имя" "Тип" "Адрес"
    local _id _name _src _uri _meta
    while IFS='|' read -r _id _name _src _uri; do
        [ -n "$_id" ] || continue
        _meta=$(_vless_parse check "$_uri" 2>/dev/null || echo '{}')
        local _h _sec _tr
        _h=$(python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("%s:%s"%(d.get("host","?"),d.get("port","")))' <<<"$_meta" 2>/dev/null)
        _sec=$(python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("security","?"))' <<<"$_meta" 2>/dev/null)
        _tr=$(python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("transport","?"))' <<<"$_meta" 2>/dev/null)
        printf "  %-9s %-22s %-8s %s%s\n" "$_id" "${_name:0:22}" "${_sec}/${_tr}" "$_h" \
            "$([ "$_id" = "${VLESS_ACTIVE:-}" ] && echo '  ← активная')"
    done < "$_f"
    echo ""
}

vless_link_use() {
    local _id="${1:-}"
    check_root
    [ -n "$(_vless_link_row "$_id")" ] || { log_error "Ссылки ${_id} нет"; return 1; }
    VLESS_ACTIVE="$_id"; save_settings
    log_success "Активная ссылка: ${_id}"
    if [ "${VLESS_ENABLED:-false}" = true ]; then
        vless_reload_active || return 1
    fi
    return 0
}

vless_link_remove() {
    local _id _f _tmp _active_removed=false
    check_root
    [ "$#" -gt 0 ] || { log_error "Использование: mtproxyl vless link remove <ID> [ID…]"; return 1; }
    local -a _ids=()
    for _id in "$@"; do
        [ -n "$_id" ] || continue
        [ -n "$(_vless_link_row "$_id")" ] || { log_error "Ссылки ${_id} нет"; return 1; }
        _ids+=("$_id")
    done
    [ "${#_ids[@]}" -gt 0 ] || { log_error "Не указаны ID ссылок"; return 1; }
    _f=$(_vless_links); _tmp=$(mktemp "${_f}.XXXXXX") || return 1
    awk -F'|' -v ids="${_ids[*]}" '
        BEGIN { n=split(ids, a, " "); for (i=1; i<=n; i++) drop[a[i]]=1 }
        !($1 in drop)
    ' "$_f" > "$_tmp"
    chmod 600 "$_tmp" && mv -f "$_tmp" "$_f" || { rm -f "$_tmp"; return 1; }
    for _id in "${_ids[@]}"; do
        [ "${VLESS_ACTIVE:-}" = "$_id" ] && _active_removed=true
    done
    if [ "$_active_removed" = true ]; then
        VLESS_ACTIVE=$(awk -F'|' 'NR==1 {print $1}' "$_f")
        save_settings
        if [ "${VLESS_ENABLED:-false}" = true ]; then
            if [ -n "$VLESS_ACTIVE" ]; then vless_reload_active; else vless_off; fi
        fi
    fi
    if [ "${#_ids[@]}" = 1 ]; then
        log_success "Ссылка ${_ids[0]} удалена"
    else
        log_success "Удалено ссылок: ${#_ids[@]}"
    fi
}

# ── HWID ────────────────────────────────────────────────────
# Провайдеры (Remnawave, Happ, INCY) считают устройства по x-hwid и отдают
# ссылки только знакомому User-Agent. Идентификатор стабилен для установки:
# иначе каждая проверка подписки считалась бы новым устройством.
_vless_hwid() {
    if [ -n "${VLESS_HWID:-}" ]; then printf '%s\n' "$VLESS_HWID"; return 0; fi
    local _seed=""
    [ -r /etc/machine-id ] && _seed=$(tr -d ' \n' < /etc/machine-id 2>/dev/null)
    [ -n "$_seed" ] || _seed=$(hostname 2>/dev/null)
    VLESS_HWID=$(printf 'mtproxyl-vless:%s' "$_seed" | sha256sum | cut -c1-32)
    save_settings
    printf '%s\n' "$VLESS_HWID"
}

vless_hwid_regen() {
    check_root
    VLESS_HWID=$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    save_settings
    log_success "Новый HWID: ${VLESS_HWID}"
    log_info "Провайдер увидит новое устройство; старые привязки останутся на прежнем"
}

_vless_sub_notice_file() { echo "$(_vless_dir)/sub.notice"; }

_vless_sub_title_file() { echo "$(_vless_dir)/sub.title"; }

_vless_placeholder_host() {
    case "$1" in 0.0.0.0|127.0.0.1|::|::1|localhost|"") return 0 ;; *) return 1 ;; esac
}

# ── Подписка ────────────────────────────────────────────────
_vless_sub_url() { awk -F'|' 'NR==1 {print $2}' "$(_vless_subs)" 2>/dev/null; }

vless_sub_set() {
    local _url="${1:-}"
    check_root
    [[ "$_url" =~ ^https:// ]] || { log_error "Подписка: только https://"; return 1; }
    local _f; _f=$(_vless_subs); mkdir -p "$(_vless_dir)" || return 1
    printf '%s|%s|%s\n' "$(_vless_uri_id "$_url")" "$_url" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_f"
    chmod 600 "$_f"
    log_success "Подписка задана"
    vless_sub_refresh
}

vless_sub_off() {
    check_root
    local _f _tmp _removed=0
    _f=$(_vless_links)
    if [ -f "$_f" ]; then
        _removed=$(awk -F'|' '$3 == "sub" {n++} END {print n+0}' "$_f")
        if [ "$_removed" -gt 0 ]; then
            _tmp=$(mktemp "${_f}.XXXXXX") || return 1
            awk -F'|' '$3 != "sub"' "$_f" > "$_tmp"
            chmod 600 "$_tmp" && mv -f "$_tmp" "$_f" || { rm -f "$_tmp"; return 1; }
        fi
    fi
    rm -f "$(_vless_subs)" "$(_vless_sub_notice_file)" "$(_vless_sub_title_file)"
    if [ -n "${VLESS_ACTIVE:-}" ] && [ -z "$(_vless_link_row "$VLESS_ACTIVE")" ]; then
        VLESS_ACTIVE=$(awk -F'|' 'NR==1 {print $1}' "$_f" 2>/dev/null)
        save_settings
        if [ "${VLESS_ENABLED:-false}" = true ]; then
            if [ -n "$VLESS_ACTIVE" ]; then vless_reload_active; else vless_off; fi
        fi
    fi
    log_success "Подписка отключена; удалено ссылок: ${_removed}"
}

vless_sub_refresh() {
    check_root
    local _url; _url=$(_vless_sub_url)
    [ -n "$_url" ] || { log_error "Подписка не задана: mtproxyl vless sub set <https-url>"; return 1; }
    local _tmp _hdrfile _code _hwid
    _tmp=$(mktemp /tmp/mtproxyl-sub.XXXXXX) || return 1
    _hdrfile=$(mktemp /tmp/mtproxyl-sub-h.XXXXXX) || { rm -f "$_tmp"; return 1; }
    local -a _hh=(-A "${VLESS_SUB_UA:-Happ/3.23.0}" -H "Accept: */*")
    if [ "${VLESS_HWID_ENABLED:-true}" = true ]; then
        _hwid=$(_vless_hwid)
        _hh+=(-H "x-hwid: ${_hwid}" -H "X-Device-ID: ${_hwid}"
              -H "x-device-os: Linux" -H "x-ver-os: $(uname -r)"
              -H "x-device-model: MTProxyL" -H "x-xray-core: ${VLESS_VERSION}")
    fi
    _code=$(curl -sS --compressed --max-time 45 "${_hh[@]}" -D "$_hdrfile" -o "$_tmp" -w '%{http_code}' "$_url" 2>/dev/null) || _code=""
    if [ -z "$_code" ] && [ ! -s "$_tmp" ]; then
        rm -f "$_tmp" "$_hdrfile"; log_error "Подписка не скачалась"; return 1
    fi
    if [ -n "$_code" ] && [ "$_code" != 200 ] && [ "$_code" != 204 ]; then
        rm -f "$_tmp" "$_hdrfile"
        if [ "$_code" = 403 ] || [ "$_code" = 404 ]; then
            log_error "Подписка ответила ${_code}: провайдер ограничивает устройства или требует HWID"
        else
            log_error "Подписка ответила HTTP ${_code}"
        fi
        return 1
    fi
    # Заголовки профиля: title приходит и в base64, и обычным текстом.
    local _title; _title=$(sed -n 's/^[Pp]rofile-[Tt]itle: *//p' "$_hdrfile" | tr -d '\r' | head -1)
    if [ -n "$_title" ]; then
        printf '%s' "$_title" | base64 -d > "$(_vless_sub_title_file)" 2>/dev/null \
            || printf '%s' "$_title" > "$(_vless_sub_title_file)"
    fi
    rm -f "$_hdrfile"
    local _list; _list=$(mktemp /tmp/mtproxyl-sub-list.XXXXXX) || { rm -f "$_tmp"; return 1; }
    if grep -q 'vless://' "$_tmp"; then
        cp "$_tmp" "$_list"
    else
        # Может быть base64 от списка ссылок или JSON (Xray/sing-box).
        local _first; _first=$(head -c 1 "$_tmp" | tr -d '[:space:]')
        if [ "$_first" = "{" ] || [ "$_first" = "[" ]; then
            cp "$_tmp" "$_list"
        else
            python3 -I - "$_tmp" "$_list" <<'PY' || { rm -f "$_tmp" "$_list"; log_error "Подписка не разобрана"; return 1; }
import base64, sys
raw = open(sys.argv[1], "rb").read()
try:
    text = base64.b64decode(b"".join(raw.split()), validate=False).decode("utf-8", "replace")
except Exception:
    text = raw.decode("utf-8", "replace")
open(sys.argv[2], "w", encoding="utf-8").write(text)
PY
        fi
        _first=$(head -c 1 "$_list" | tr -d '[:space:]')
        if [ "$_first" = "{" ] || [ "$_first" = "[" ]; then
            if ! python3 -I "$(_vless_parser)" from-json "$_list" > "${_list}.json" 2>/dev/null; then
                rm -f "$_tmp" "$_list" "${_list}.json"
                log_error "В JSON-подписке нет VLESS-выходов"
                return 1
            fi
            mv -f "${_list}.json" "$_list"
        fi
    fi
    rm -f "$_tmp"

    # Сначала убираем прежние ссылки из подписки, ручные не трогаем.
    local _f; _f=$(_vless_links)
    if [ -f "$_f" ]; then
        local _t; _t=$(mktemp "${_f}.XXXXXX") || { rm -f "$_list"; return 1; }
        awk -F'|' '$3 != "sub"' "$_f" > "$_t" && chmod 600 "$_t" && mv -f "$_t" "$_f"
    fi
    local _added=0 _bad=0 _notice="" _line _meta _host _lname
    while IFS= read -r _line; do
        _line=$(tr -d '\r' <<< "$_line")
        [ -n "$_line" ] || continue
        case "$_line" in vless://*) ;; *) continue ;; esac
        if _vless_valid_uri "$_line"; then
            _meta=$(_vless_parse check "$_line" 2>/dev/null || echo '{}')
            _host=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("host",""))' <<< "$_meta" 2>/dev/null)
            if _vless_placeholder_host "$_host"; then
                # Провайдер вставляет ссылку-подсказку с именем вместо адреса.
                _lname=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' <<< "$_meta" 2>/dev/null)
                [ -n "$_lname" ] && _notice="$_lname"
                _bad=$((_bad + 1))
                continue
            fi
            vless_link_add "$_line" "" sub >/dev/null 2>&1 && _added=$((_added + 1))
        else
            _bad=$((_bad + 1))
        fi
    done < "$_list"
    rm -f "$_list"
    if [ -n "$_notice" ]; then printf '%s\n' "$_notice" > "$(_vless_sub_notice_file)"
    else rm -f "$(_vless_sub_notice_file)"; fi
    local _f2; _f2=$(_vless_subs); _url=$(_vless_sub_url)
    [ -n "$_url" ] && printf '%s|%s|%s\n' "$(_vless_uri_id "$_url")" "$_url" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_f2"
    chmod 600 "$_f2" 2>/dev/null || true
    log_success "Подписка обновлена: добавлено ${_added}, пропущено ${_bad}"
    if [ -z "${VLESS_ACTIVE:-}" ] || [ -z "$(_vless_link_row "$VLESS_ACTIVE")" ]; then
        VLESS_ACTIVE=$(awk -F'|' 'NR==1 {print $1}' "$(_vless_links)" 2>/dev/null)
        save_settings
    fi
    [ "${VLESS_ENABLED:-false}" = true ] && [ -n "${VLESS_ACTIVE:-}" ] && vless_reload_active >/dev/null 2>&1 || true
}

# ── Конфиг и служба ────────────────────────────────────────
_vless_ensure_user() {
    id "$VLESS_USER" &>/dev/null && return 0
    useradd --system --no-create-home --shell /usr/sbin/nologin "$VLESS_USER" 2>/dev/null \
        || useradd -r -M -s /sbin/nologin "$VLESS_USER" 2>/dev/null \
        || { log_error "Не удалось создать пользователя ${VLESS_USER}"; return 1; }
}

vless_config_write() {
    local _id="${VLESS_ACTIVE:-}" _uri _dir _conf
    _dir=$(_vless_dir); _conf=$(_vless_conf)
    [ -n "$_id" ] || { log_error "Не выбрана активная ссылка"; return 1; }
    _uri=$(_vless_link_uri "$_id")
    [ -n "$_uri" ] || { log_error "Ссылка ${_id} не найдена"; return 1; }
    mkdir -p "$_dir" || return 1
    local _tmp="${_conf}.new.json"
    _vless_parse build "$_uri" "$(_vless_port)" "$_tmp" || { rm -f "$_tmp"; return 1; }
    "$(_vless_bin)" run -test -c "$_tmp" >/dev/null 2>&1 \
        || { rm -f "$_tmp"; log_error "Xray не принял конфиг ссылки"; return 1; }
    chmod 640 "$_tmp"
    chown "root:${VLESS_USER}" "$_tmp" 2>/dev/null || chmod 600 "$_tmp"
    mv -f "$_tmp" "$_conf" || return 1
    chmod 750 "$_dir"; chown "root:${VLESS_USER}" "$_dir" 2>/dev/null || true
}

vless_service_write() {
    local _unit="$(_vless_unit_dir)/${VLESS_UNIT}"
    cat > "$_unit" <<EOF
[Unit]
Description=MTProxyL VLESS (Xray-core)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${VLESS_USER}
Group=${VLESS_USER}
ExecStart=$(_vless_bin) run -c $(_vless_conf)
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$_unit"
}

vless_service_restart() {
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$VLESS_UNIT" >/dev/null 2>&1 || true
    systemctl restart "$VLESS_UNIT" || return 1
    return 0
}

vless_apply() {
    local _port; _port=$(_vless_port)
    _vless_core_install || return 1
    _vless_ensure_user || return 1
    vless_config_write || return 1
    vless_service_write || return 1
    vless_service_restart || { log_error "Служба VLESS не запустилась: journalctl -u ${VLESS_UNIT}"; return 1; }
    _vless_apply_upstream || return 1
    _vless_engine_apply
    log_success "VLESS включён: socks5 127.0.0.1:${_port} → $(_vless_mask_uri "$(_vless_link_uri "$VLESS_ACTIVE")")"
}

# Смена ссылки не меняет upstream движка: перезапускаем только Xray, иначе
# панель, опубликованная через движок на 443, пропадает на время рестарта.
vless_reload_active() {
    local _port; _port=$(_vless_port)
    vless_config_write || return 1
    vless_service_write || return 1
    vless_service_restart || { log_error "Служба VLESS не запустилась: journalctl -u ${VLESS_UNIT}"; return 1; }
    log_success "VLESS переключён: socks5 127.0.0.1:${_port} → $(_vless_mask_uri "$(_vless_link_uri "$VLESS_ACTIVE")")"
}

_vless_engine_apply() {
    if declare -F mtdd_mgr_active >/dev/null && mtdd_mgr_active; then
        generate_mtdd_config >/dev/null 2>&1 || true
        mtdd_restart >/dev/null 2>&1 || true
    else
        generate_telemt_config >/dev/null 2>&1 || true
        is_proxy_running 2>/dev/null && restart_proxy_container >/dev/null 2>&1 || true
    fi
}

# ── Upstream движка ────────────────────────────────────────
_vless_local_mask_backend() {
    declare -F _warp_local_mask_backend >/dev/null && _warp_local_mask_backend
}

_vless_apply_upstream() {
    load_upstreams 2>/dev/null || true
    UPSTREAM_DEFER_RESTART="true"
    local _rc=0 _port; _port=$(_vless_port)
    local _others="" _i
    for _i in "${!UPSTREAM_NAMES[@]}"; do
        local _n="${UPSTREAM_NAMES[$_i]}"
        [ "$_n" = "$VLESS_UPSTREAM_NAME" ] || [ "$_n" = "$VLESS_UPSTREAM_LOCAL" ] && continue
        [ "${UPSTREAM_ENABLED[$_i]:-false}" = true ] || continue
        [ -z "${UPSTREAM_SCOPES[$_i]:-}" ] || continue
        _others+="${_others:+,}${_n}"
    done
    if [ -n "$_others" ]; then
        log_warn "Маршруты без области будут выключены на время VLESS: ${_others}"
        local _old="$IFS"; IFS=','; local -a _list=(); read -ra _list <<< "$_others"; IFS="$_old"
        local _name
        for _name in "${_list[@]}"; do
            [ -n "$_name" ] || continue
            upstream_toggle "$_name" disable >/dev/null 2>&1 || { UPSTREAM_DEFER_RESTART=false; return 1; }
            case ",${VLESS_DISABLED_UPSTREAMS:-}," in
                *",${_name},"*) ;;
                *) VLESS_DISABLED_UPSTREAMS+="${VLESS_DISABLED_UPSTREAMS:+,}${_name}" ;;
            esac
        done
        save_settings
    fi
    upstream_remove "$VLESS_UPSTREAM_NAME" >/dev/null 2>&1 || true
    upstream_add "$VLESS_UPSTREAM_NAME" socks5 "127.0.0.1:${_port}" "" "" 1 "" "" >/dev/null \
        || { log_error "Не удалось добавить upstream ${VLESS_UPSTREAM_NAME}"; _rc=1; }
    upstream_remove "$VLESS_UPSTREAM_LOCAL" >/dev/null 2>&1 || true
    if [ $_rc -eq 0 ] && _vless_local_mask_backend; then
        upstream_add "$VLESS_UPSTREAM_LOCAL" direct "" "" "" 1 "" "local" >/dev/null || true
        mtdd_mgr_active || handle_expert_command set censorship tls_fetch_scope local --no-apply >/dev/null 2>&1 \
            || log_warn "Не удалось задать censorship.tls_fetch_scope — маскировка может не подтянуть сертификат"
    fi
    UPSTREAM_DEFER_RESTART="false"
    [ $_rc -eq 0 ] || return 1
    return 0
}

_vless_drop_upstream() {
    load_upstreams 2>/dev/null || true
    UPSTREAM_DEFER_RESTART="true"
    upstream_remove "$VLESS_UPSTREAM_NAME" >/dev/null 2>&1 || true
    upstream_remove "$VLESS_UPSTREAM_LOCAL" >/dev/null 2>&1 || true
    mtdd_mgr_active || handle_expert_command clear censorship tls_fetch_scope --no-apply >/dev/null 2>&1 || true
    local _name _old="$IFS"; IFS=','; local -a _list=(); read -ra _list <<< "${VLESS_DISABLED_UPSTREAMS:-}"; IFS="$_old"
    for _name in "${_list[@]}"; do
        [ -n "$_name" ] || continue
        upstream_toggle "$_name" enable >/dev/null 2>&1 || true
    done
    VLESS_DISABLED_UPSTREAMS=""
    UPSTREAM_DEFER_RESTART="false"
}

# ── Тест ────────────────────────────────────────────────────
_vless_probe() {
    _vless_parse probe "$(_vless_port)" "$1" "$2" >/dev/null 2>&1
}

vless_test_json() {
    local _port; _port=$(_vless_port)
    local _exit="" _tg="fail" _dc="fail"
    if [ "$(systemctl is-active "$VLESS_UNIT" 2>/dev/null)" = active ]; then
        _exit=$(curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:${_port}" https://api.ipify.org 2>/dev/null | tr -dc '0-9a-fA-F.:' | head -c 64)
        curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:${_port}" -o /dev/null https://api.telegram.org 2>/dev/null && _tg="ok"
        _vless_probe 149.154.167.51 443 >/dev/null 2>&1 && _dc="ok"
    fi
    python3 -I - "$_exit" "$_tg" "$_dc" <<'PY'
import json, sys
print(json.dumps({"exit_ip": sys.argv[1], "telegram": sys.argv[2], "dc": sys.argv[3],
                  "ok": sys.argv[2] == "ok" and sys.argv[3] == "ok"}, ensure_ascii=False))
PY
}

vless_test() {
    local _j; _j=$(vless_test_json)
    python3 -I - "$_j" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
print()
print("  VLESS: %s" % ("работает" if d["ok"] else "проверка не прошла"))
print("  Выходной IP: %s" % (d["exit_ip"] or "не определён"))
print("  api.telegram.org: %s · TCP до DC: %s" % (d["telegram"], d["dc"]))
print()
PY
}

# ── Состояние и включение ──────────────────────────────────
_vless_donor_on() {
    declare -F donor_load >/dev/null || return 1
    donor_load 2>/dev/null || return 1
    [ "${DONOR_ENABLED:-false}" = true ]
}

_vless_exit_conflicts() {
    local _out=""
    [ "${WARP_ENABLED:-false}" = true ] && _out+="${_out:+, }WARP"
    _vless_donor_on && _out+="${_out:+, }донор"
    declare -F awg_is_enabled >/dev/null && awg_is_enabled 2>/dev/null && _out+="${_out:+, }свой AWG"
    echo "$_out"
}

# ME и VLESS несовместимы: ключи рукопожатия выводятся из адреса и порта,
# с которых движок пришёл к Telegram, а локальный SOCKS5 отдаёт свой адрес.
# Проверено на mtdd: с VLESS через socks ни один DC не поднимается.
_vless_me_enabled() {
    if declare -F mtdd_mgr_active >/dev/null && mtdd_mgr_active; then return 0; fi
    local _cfg; _cfg=$(_engine_config_path 2>/dev/null)
    [ -n "$_cfg" ] && [ -r "$_cfg" ] || return 1
    grep -qE '^[[:space:]]*use_middle_proxy[[:space:]]*=[[:space:]]*false' "$_cfg" && return 1
    return 0
}

# Что происходит с middle proxy на самом деле: у mtdd при VLESS он не
# выключается, а весь DC-трафик идёт маршрутом Direct через SOCKS5.
_vless_me_state() {
    if [ "${VLESS_ENABLED:-false}" = true ] && declare -F mtdd_mgr_active >/dev/null && mtdd_mgr_active; then
        echo direct; return 0
    fi
    if _vless_me_enabled; then echo enabled; else echo disabled; fi
}

_vless_me_gate() {
    local _assume="${1:-false}" _consent="${2:-false}"
    _vless_me_enabled || return 0
    if declare -F mtdd_mgr_active >/dev/null && mtdd_mgr_active; then
        log_warn "Middle proxy несовместим с VLESS: ключи ME зависят от адреса и порта, а socks5 их не сохраняет"
        log_info "mtdd пойдёт к дата-центрам маршрутом Direct через VLESS; рекламный тег действовать не будет"
        [ "$_consent" = true ] && return 0
        if [ "$_assume" != true ]; then
            local _yn; read_line _yn "  ${BOLD}Продолжить с Direct вместо ME? [y/N]:${NC} "
            [[ "$_yn" =~ ^[yY] ]] || { log_info "Ничего не меняем"; return 1; }
        else
            log_error "Нужно явное согласие: добавьте --allow-disable-me"
            return 1
        fi
        return 0
    fi
    log_warn "Middle proxy несовместим с VLESS: выход не сохраняет адрес:порт, писатели ME не поднимутся"
    log_info "Движок пойдёт к DC напрямую через VLESS; рекламный тег действовать не будет"
    [ "$_consent" = true ] && { _vless_me_disable; return $?; }
    if [ "$_assume" != true ]; then
        local _yn; read_line _yn "  ${BOLD}Выключить middle proxy и продолжить? [y/N]:${NC} "
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Ничего не меняем"; return 1; }
        _vless_me_disable; return $?
    fi
    log_error "Нужно явное согласие на выключение middle proxy: --allow-disable-me"
    return 1
}

_vless_me_disable() {
    handle_expert_command set general use_middle_proxy false --no-apply >/dev/null 2>&1 || {
        log_error "Не удалось выключить middle proxy"; return 1; }
    VLESS_ME_DISABLED="true"
    log_success "Middle proxy выключен на время VLESS"
}

vless_on() {
    local _assume="${MTPROXYL_ASSUME_YES:-false}" _consent=false _arg
    for _arg in "$@"; do
        case "$_arg" in
            --yes) _assume=true ;;
            --allow-disable-me) _consent=true ;;
        esac
    done
    check_root
    [ -n "${VLESS_ACTIVE:-}" ] && [ -n "$(_vless_link_row "$VLESS_ACTIVE")" ] \
        || VLESS_ACTIVE=$(awk -F'|' 'NR==1 {print $1}' "$(_vless_links)" 2>/dev/null)
    [ -n "$VLESS_ACTIVE" ] || { log_error "Сначала добавьте ссылку: mtproxyl vless link add '<vless://…>'"; return 1; }
    local _conflict; _conflict=$(_vless_exit_conflicts)
    if [ -n "$_conflict" ]; then
        if [ "$_assume" != true ]; then
            log_error "Уже включён другой выход: ${_conflict}"
            log_info "Выключите его или повторите с --yes: mtproxyl vless on --yes"
            return 1
        fi
        log_warn "Выключаем прежний выход: ${_conflict}"
        [ "${WARP_ENABLED:-false}" = true ] && warp_disable >/dev/null 2>&1 || true
        _vless_donor_on && donor_disable >/dev/null 2>&1 || true
        declare -F awg_is_enabled >/dev/null && awg_is_enabled 2>/dev/null && awg_disable >/dev/null 2>&1 || true
    fi
    _vless_me_gate "$_assume" "$_consent" || return 1
    # mtdd собирает маршрут по VLESS_ENABLED: Direct вместо ME.
    VLESS_ENABLED="true"
    if vless_apply; then
        save_settings
        vless_watchdog_install
        if declare -F _upstream_me_enabled >/dev/null && _upstream_me_enabled; then
            log_info "Middle proxy включён: проверьте покрытие DC (mtproxyl dc status). Если ME не поднялся, выход VLESS не сохраняет адрес:порт"
        fi
        vless_test
    else
        return 1
    fi
}

vless_off() {
    check_root
    systemctl disable --now "${VLESS_WATCH_UNIT}.timer" >/dev/null 2>&1 || true
    systemctl disable --now "$VLESS_UNIT" >/dev/null 2>&1 || true
    _vless_drop_upstream
    _vless_engine_apply
    VLESS_ENABLED="false"
    save_settings
    log_success "VLESS выключен — трафик движка идёт по прежним маршрутам"
    if [ "${VLESS_ME_DISABLED:-false}" = true ]; then
        log_info "Middle proxy остался выключенным: вернуть — mtproxyl expert clear general use_middle_proxy"
        VLESS_ME_DISABLED="false"; save_settings
    fi
}

_vless_links_json() {
    local _f; _f=$(_vless_links)
    [ -s "$_f" ] || { echo '[]'; return 0; }
    local _id _name _src _uri _meta _arr="[]"
    _arr=$(python3 -I - "$_f" "$(_vless_parser)" "${VLESS_ACTIVE:-}" <<'PY'
import json, subprocess, sys
path, parser, active = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
for line in open(path, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        continue
    f = (line.split("|") + ["", "", "", ""])[:4]
    meta = {}
    try:
        r = subprocess.run([sys.executable, "-I", parser, "check", f[3]],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            meta = json.loads(r.stdout)
    except Exception:
        pass
    out.append({
        "id": f[0], "name": f[1], "source": f[2] or "manual",
        "host": meta.get("host", ""), "port": meta.get("port", 0),
        "security": meta.get("security", ""), "transport": meta.get("transport", ""),
        "encryption": meta.get("encryption", "none"),
        "active": f[0] == active,
    })
print(json.dumps(out, ensure_ascii=False))
PY
)
    printf '%s' "${_arr:-[]}"
}

vless_status_json() {
    local _ver="-" _sid="${VLESS_ACTIVE:-}" _meta="{}" _uri="" _active="null"
    _ver=$(_vless_core_version 2>/dev/null || echo "-")
    if [ -n "$_sid" ] && [ -n "$(_vless_link_row "$_sid")" ]; then
        _uri=$(_vless_link_uri "$_sid")
        _meta=$(_vless_parse check "$_uri" 2>/dev/null || echo '{}')
        _active=$(python3 -I - "$_sid" "$_meta" <<'PY'
import json, sys
d = json.loads(sys.argv[2])
d["id"] = sys.argv[1]
print(json.dumps(d, ensure_ascii=False))
PY
)
    fi
    python3 -I - \
        "${VLESS_ENABLED:-false}" "$(systemctl is-active "$VLESS_UNIT" 2>/dev/null | head -1)" \
        "$_ver" "$(_vless_port)" "$_active" \
        "$(_vless_links_json)" \
        "$([ -s "$(_vless_subs)" ] && echo true || echo false)" \
        "${VLESS_WATCHDOG_ENABLED:-true}" "$(_vless_hwid 2>/dev/null)" "${VLESS_HWID_ENABLED:-true}" \
        "${VLESS_SUB_UA:-}" "$(cat "$(_vless_sub_notice_file)" 2>/dev/null | head -1)" \
        "$(_vless_me_state)" <<'PY'
import json, sys
active = json.loads(sys.argv[5]) if sys.argv[5] else None
links = json.loads(sys.argv[6]) if sys.argv[6] else []
print(json.dumps({
    "enabled": sys.argv[1] == "true",
    "service": sys.argv[2],
    "core_version": sys.argv[3],
    "socks_port": int(sys.argv[4]),
    "active": active,
    "links": links,
    "links_count": len(links),
    "subscription": sys.argv[7] == "true",
    "watchdog": sys.argv[8] == "true",
    "hwid": sys.argv[9] if len(sys.argv) > 9 else "",
    "hwid_enabled": sys.argv[10] == "true" if len(sys.argv) > 10 else True,
    "sub_ua": sys.argv[11] if len(sys.argv) > 11 else "",
    "sub_notice": sys.argv[12] if len(sys.argv) > 12 else "",
    "me_state": sys.argv[13] if len(sys.argv) > 13 else "enabled",
}, ensure_ascii=False))
PY
}

vless_status() {
    local _j; _j=$(vless_status_json)
    python3 -I - "$_j" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
print()
print("  VLESS: %s · служба %s · Xray %s" % ("включён" if d["enabled"] else "выключен", d["service"], d["core_version"]))
if d["active"]:
    a = d["active"]
    print("  Ссылка: %s %s → %s:%s (%s/%s%s)" % (a.get("id",""), a.get("name",""), a.get("host",""), a.get("port",""),
          a.get("security",""), a.get("transport",""), "+enc" if a.get("encryption") not in (None,"","none") else ""))
else:
    print("  Активная ссылка не выбрана")
print("  SOCKS5: 127.0.0.1:%s · ссылок: %s · подписка: %s" % (d["socks_port"], d.get("links_count", 0), "да" if d["subscription"] else "нет"))
_me = d.get("me_state", "enabled")
print("  Middle proxy: %s" % {"direct": "mtdd: весь DC-трафик через Direct", "disabled": "выключен", "enabled": "включён"}.get(_me, _me))
if d.get("hwid"):
    print("  HWID: %s%s · клиент подписки: %s" % (d["hwid"], "" if d.get("hwid_enabled", True) else " (не отправляется)", d.get("sub_ua") or "MTProxyL"))
if d.get("sub_notice"):
    print("  Подписка: %s" % d["sub_notice"])
print()
PY
}

# ── Watchdog ────────────────────────────────────────────────
vless_watchdog_install() {
    local _unit="$(_vless_unit_dir)/${VLESS_WATCH_UNIT}"
    cat > "${_unit}.service" <<EOF
[Unit]
Description=MTProxyL VLESS health check

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR:-/opt/mtproxyl}/mtproxyl.sh vless watch
EOF
    cat > "${_unit}.timer" <<EOF
[Unit]
Description=MTProxyL VLESS health timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=3min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now "${VLESS_WATCH_UNIT}.timer" >/dev/null 2>&1 || true
}

_vless_next_link() {
    local _cur="${VLESS_ACTIVE:-}" _next
    _next=$(awk -F'|' -v cur="$_cur" 'BEGIN{seen=0} $1==cur{seen=1; next} seen && $1!=""{print $1; exit} END{if(!seen) exit}' "$(_vless_links)" 2>/dev/null)
    [ -n "$_next" ] || _next=$(awk -F'|' -v cur="$_cur" '$1 != cur && $1 != "" {print $1; exit}' "$(_vless_links)" 2>/dev/null)
    echo "$_next"
}

vless_watch() {
    [ "${VLESS_ENABLED:-false}" = true ] || return 0
    local _st; _st=$(vless_test_json)
    local _ok; _ok=$(python3 -I -c 'import json,sys; print("1" if json.loads(sys.argv[1])["ok"] else "")' "$_st")
    local _f; _f=$(_vless_state)
    if [ -n "$_ok" ]; then
        echo '{"fails":0}' > "$_f" 2>/dev/null || true
        return 0
    fi
    local _n=0
    [ -s "$_f" ] && _n=$(python3 -I -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("fails",0)))' "$_f" 2>/dev/null || echo 0)
    _n=$((_n + 1))
    printf '{"fails":%d}\n' "$_n" > "$_f" 2>/dev/null || true
    if [ "$_n" -eq 2 ]; then
        log_warn "VLESS не отвечает — перезапускаем Xray"
        vless_service_restart >/dev/null 2>&1 || true
    elif [ "$_n" -ge 4 ]; then
        local _next; _next=$(_vless_next_link)
        if [ -n "$_next" ] && [ "$_next" != "${VLESS_ACTIVE:-}" ]; then
            log_warn "Переключаем VLESS на ссылку ${_next}"
            VLESS_ACTIVE="$_next"; save_settings
            vless_reload_active >/dev/null 2>&1 || true
        else
            vless_service_restart >/dev/null 2>&1 || true
        fi
        echo '{"fails":0}' > "$_f" 2>/dev/null || true
    fi
}

# ── CLI ─────────────────────────────────────────────────────
vless_sub_set_ua() {
    local _ua="$*"
    [ -n "$_ua" ] || { log_error "Укажите User-Agent, например Happ/3.23.0"; return 1; }
    VLESS_SUB_UA="$_ua"; save_settings
    log_success "User-Agent подписки: ${VLESS_SUB_UA}"
}

handle_vless_command() {
    local _sub="${1:-status}"
    case "$_sub" in
        on|enable)   shift; vless_on "$@" ;;
        off|disable) vless_off ;;
        status|"")
            if [ "${2:-}" = --json ]; then vless_status_json; else vless_status; fi ;;
        link)
            case "${2:-list}" in
                list|"") vless_link_list ;;
                add)     vless_link_add "${3:-}" "${4:-}" ;;
                use)     vless_link_use "${3:-}" ;;
                remove|rm) shift 2; vless_link_remove "$@" ;;
                *) log_error "vless link [list|add|use|remove]"; return 1 ;;
            esac ;;
        sub)
            case "${2:-}" in
                set)     vless_sub_set "${3:-}" ;;
                refresh) vless_sub_refresh ;;
                off)     vless_sub_off ;;
                ua)      vless_sub_set_ua "${3:-}" ;;
                *) log_error "vless sub [set <url>|refresh|off|ua <строка>]"; return 1 ;;
            esac ;;
        hwid)
            case "${2:-show}" in
                show|"") _vless_hwid ;;
                regen|new) vless_hwid_regen ;;
                on|enable)  VLESS_HWID_ENABLED="true"; save_settings; log_success "HWID отправляется в подписке" ;;
                off|disable) VLESS_HWID_ENABLED="false"; save_settings; log_success "HWID не отправляется" ;;
                *) log_error "vless hwid [show|regen|on|off]"; return 1 ;;
            esac ;;
        test)
            if [ "${2:-}" = --json ]; then vless_test_json; else vless_test; fi ;;
        update)   check_root; _vless_core_install true && { [ "${VLESS_ENABLED:-false}" = true ] && vless_service_restart; } ;;
        rollback) check_root; vless_core_rollback ;;
        recover)
            check_root
            [ "${VLESS_ENABLED:-false}" = true ] || { log_error "VLESS выключен"; return 1; }
            vless_apply ;;
        watch)    vless_watch ;;
        help|*)
            echo -e "  ${BOLD}VLESS (Xray-core):${NC}"
            echo -e "    ${GREEN}vless on${NC} [--yes] [--allow-disable-me]  Включить: весь трафик движка через VLESS"
            echo -e "    ${GREEN}vless off${NC}              Выключить, вернуть прежние маршруты"
            echo -e "    ${GREEN}vless status${NC} [--json]  Состояние, активная ссылка, ядро"
            echo -e "    ${GREEN}vless link add${NC} <URI> [имя]  Добавить ссылку vless://"
            echo -e "    ${GREEN}vless link list|use|remove${NC} <ID…>  Список, выбор и удаление ссылок"
            echo -e "    ${GREEN}vless sub set${NC} <URL>     Подписка (base64 или список ссылок)"
            echo -e "    ${GREEN}vless sub refresh|off${NC}   Обновить; off удаляет ссылки подписки"
            echo -e "    ${GREEN}vless sub ua${NC} <строка>   User-Agent подписки (Happ/3.23.0 по умолчанию)"
            echo -e "    ${GREEN}vless hwid${NC} [show|regen|on|off]  Идентификатор устройства для подписки"
            echo -e "    ${GREEN}vless test${NC} [--json]     Выходной IP, Telegram, DC"
            echo -e "    ${GREEN}vless update${NC}            Обновить Xray-core"
            echo -e "    ${GREEN}vless rollback${NC}          Предыдущая сборка Xray"
            echo -e "    ${GREEN}vless recover${NC}           Перезапустить и переприменить"
            ;;
    esac
}
