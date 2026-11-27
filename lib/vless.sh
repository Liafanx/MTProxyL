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

# Разбор ссылок — lib/vless_parse.sh (bash + jq). При обычном запуске он уже
# загружен диспетчером; при прямом source подтягиваем соседний файл.
if ! declare -F vless_parse_main >/dev/null 2>&1; then
    _vless_parser_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vless_parse.sh"
    # shellcheck source=/dev/null
    [ ! -f "$_vless_parser_file" ] || source "$_vless_parser_file"
    unset _vless_parser_file
fi

_vless_parse() {
    declare -F vless_parse_main >/dev/null 2>&1 || {
        log_error "Не найден lib/vless_parse.sh; выполните mtproxyl update"
        return 1
    }
    vless_parse_main "$@"
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
    if ! command -v unzip >/dev/null 2>&1; then
        rm -rf "$_tmp"; log_error "Для распаковки Xray нужен unzip: apt install unzip"; return 1
    fi
    if ! unzip -p "${_tmp}/${_zip}" xray > "${_tmp}/xray" 2>/dev/null; then
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
    local _uri="$1" _meta _host _port _sec _tr _enc
    _meta=$(_vless_parse check "$_uri" 2>/dev/null) || _meta='{}'
    _host=$(jq -r '.host // "?"' <<< "$_meta" 2>/dev/null)
    _port=$(jq -r '.port // ""' <<< "$_meta" 2>/dev/null)
    _sec=$(jq -r '.security // "?"' <<< "$_meta" 2>/dev/null)
    _tr=$(jq -r '.transport // "?"' <<< "$_meta" 2>/dev/null)
    _enc=$(jq -r '.encryption // "none"' <<< "$_meta" 2>/dev/null)
    [ "$_enc" = none ] && _enc="" || _enc="+enc"
    echo "vless://***@${_host:-?}:${_port} (${_sec:-?}/${_tr:-?}${_enc})"
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
    [ -n "$_name" ] || _name=$(_vless_parse check "$_uri" 2>/dev/null | jq -r '.name // ""' 2>/dev/null)
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
        _h=$(jq -r 'if .host then "\(.host):\(.port // "")" else "?" end' <<< "$_meta" 2>/dev/null)
        _sec=$(jq -r '.security // "?"' <<< "$_meta" 2>/dev/null)
        _tr=$(jq -r '.transport // "?"' <<< "$_meta" 2>/dev/null)
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
            local _b64
            _b64=$(tr -d ' \t\r\n' < "$_tmp" | tr '_-' '/+')
            case $(( ${#_b64} % 4 )) in
                2) _b64+="==" ;;
                3) _b64+="=" ;;
            esac
            printf '%s' "$_b64" | base64 -d > "$_list" 2>/dev/null || cp "$_tmp" "$_list"
            [ -s "$_list" ] || cp "$_tmp" "$_list"
        fi
        _first=$(head -c 1 "$_list" | tr -d '[:space:]')
        if [ "$_first" = "{" ] || [ "$_first" = "[" ]; then
            if ! _vless_parse from-json "$_list" > "${_list}.json" 2>/dev/null; then
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
            _host=$(jq -r '.host // ""' <<< "$_meta" 2>/dev/null)
            if _vless_placeholder_host "$_host"; then
                # Провайдер вставляет ссылку-подсказку с именем вместо адреса.
                _lname=$(jq -r '.name // ""' <<< "$_meta" 2>/dev/null)
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

_vless_start_xray() {
    _vless_core_install || return 1
    _vless_ensure_user || return 1
    vless_config_write || return 1
    vless_service_write || return 1
    vless_service_restart || { log_error "Служба VLESS не запустилась: journalctl -u ${VLESS_UNIT}"; return 1; }
}

_vless_route_engine() {
    _vless_apply_upstream || return 1
    _vless_engine_apply "$@"
}

vless_apply() {
    _vless_start_xray && _vless_route_engine && save_settings || return 1
    log_success "Маршрут через VLESS применён"
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
    if [ "${VLESS_DEFER_RESTART:-false}" = true ]; then
        VLESS_ENGINE_PENDING=true
        return 0
    fi
    load_secrets || return 1
    load_upstreams || return 1
    if declare -F mtdd_mgr_active >/dev/null && mtdd_mgr_active; then
        generate_mtdd_config || return 1
        mtdd_restart
    else
        generate_telemt_config || return 1
        if [ "${1:-false}" = true ] || is_proxy_running 2>/dev/null; then restart_proxy_container; fi
    fi
}

# Панель публикуется через движок на 443: синхронный рестарт обрывает ответ
# на запрос. Откладываем применение, чтобы сначала вернуть результат.
_vless_schedule_engine_apply() {
    [ "${VLESS_ENGINE_PENDING:-false}" = true ] || return 0
    VLESS_ENGINE_PENDING=false
    local _unit="mtproxyl-vless-apply-$(date +%s)-${RANDOM}"
    if systemd-run --quiet --collect --on-active=3 --unit="$_unit" \
        "${INSTALL_DIR}/mtproxyl.sh" vless engine-apply >/dev/null 2>&1; then
        return 0
    fi
    log_warn "Не удалось отложить перезапуск движка, применяю сразу"
    VLESS_DEFER_RESTART=false
    _vless_engine_apply
}

# ── Upstream движка ────────────────────────────────────────
_vless_local_mask_backend() {
    declare -F _warp_local_mask_backend >/dev/null && _warp_local_mask_backend
}

_vless_apply_upstream() {
    load_upstreams || return 1
    local UPSTREAM_DEFER_RESTART=true
    local _port _others="" _i; _port=$(_vless_port)
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
            upstream_toggle "$_name" disable >/dev/null 2>&1 || return 1
            case ",${VLESS_DISABLED_UPSTREAMS:-}," in
                *",${_name},"*) ;;
                *) VLESS_DISABLED_UPSTREAMS+="${VLESS_DISABLED_UPSTREAMS:+,}${_name}" ;;
            esac
        done
    fi
    upstream_remove "$VLESS_UPSTREAM_NAME" >/dev/null 2>&1 || true
    upstream_add "$VLESS_UPSTREAM_NAME" socks5 "127.0.0.1:${_port}" "" "" 1 "" "" >/dev/null \
        || { log_error "Не удалось добавить upstream ${VLESS_UPSTREAM_NAME}"; return 1; }
    upstream_remove "$VLESS_UPSTREAM_LOCAL" >/dev/null 2>&1 || true
    if _vless_local_mask_backend; then
        upstream_add "$VLESS_UPSTREAM_LOCAL" direct "" "" "" 1 "" "local" >/dev/null \
            || { log_error "Не удалось добавить локальный маршрут для маскировки"; return 1; }
        mtdd_mgr_active || handle_expert_command set censorship tls_fetch_scope local --no-apply >/dev/null 2>&1 \
            || log_warn "Не удалось задать censorship.tls_fetch_scope — маскировка может не подтянуть сертификат"
    fi
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
    if [ "$(systemctl is-active "$VLESS_UNIT" 2>/dev/null)" = active ] &&
        timeout 4 bash -c 'until (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; do sleep 0.2; done' _ "$_port"; then
        _exit=$(curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:${_port}" https://api.ipify.org 2>/dev/null | tr -dc '0-9a-fA-F.:' | head -c 64)
        curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:${_port}" -o /dev/null https://api.telegram.org 2>/dev/null && _tg="ok"
        _vless_probe 149.154.167.51 443 >/dev/null 2>&1 && _dc="ok"
    fi
    jq -nc --arg exit_ip "$_exit" --arg telegram "$_tg" --arg dc "$_dc" \
        '{exit_ip:$exit_ip, telegram:$telegram, dc:$dc,
          ok:($telegram == "ok" and $dc == "ok")}'
}

vless_test() {
    local _j="${1:-}"; [ -n "$_j" ] || _j=$(vless_test_json)
    jq -r '
      "",
      "  VLESS: \(if .ok then "работает" else "проверка не прошла" end)",
      "  Выходной IP: \(if .exit_ip != "" then .exit_ip else "не определён" end)",
      "  api.telegram.org: \(.telegram) · TCP до DC: \(.dc)",
      ""
    ' <<< "$_j"
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

_vless_me_needs_consent() {
    _vless_me_enabled && return 0
    # При отключении собственного AWG может восстановиться ME.
    awg_is_enabled 2>/dev/null && (awg_load; [ -n "${AWG_ME_DISABLED:-}" ])
}

_vless_me_gate() {
    local _assume="${1:-false}" _consent="${2:-false}"
    _vless_me_needs_consent || return 0
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
    [ "$_consent" = true ] && return 0
    if [ "$_assume" != true ]; then
        local _yn; read_line _yn "  ${BOLD}Выключить middle proxy и продолжить? [y/N]:${NC} "
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Ничего не меняем"; return 1; }
        return 0
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

_vless_snapshot_route() {
    local _backup _file
    _backup=$(mktemp -d "$INSTALL_DIR/vless-transition.XXXXXX") || return 1
    for _file in "$@"; do
        if [ -e "$_file" ] && ! cp -p "$_file" "$_backup/"; then
            rm -rf -- "$_backup"
            return 1
        fi
    done
    printf '%s\n' "$_backup"
}

_vless_restore_route() {
    local _backup="$1" _engine_running="$2" _file _rc=0
    shift 2
    for _file in "$@"; do
        if [ -f "$_backup/${_file##*/}" ]; then
            cp -p "$_backup/${_file##*/}" "$_file" || _rc=1
        else
            rm -f "$_file" || _rc=1
        fi
    done
    save_settings || _rc=1
    _vless_engine_apply "$_engine_running" || _rc=1
    egress_restore || _rc=1
    return "$_rc"
}

_vless_cancel_xray() {
    systemctl disable --now "$VLESS_UNIT" >/dev/null 2>&1 ||
        log_warn "Не удалось остановить Xray: journalctl -u ${VLESS_UNIT}"
}

vless_on() {
    check_root
    if [ -n "${MTPROXYL_LOCK_HELD:-}" ]; then
        _vless_on "$@"
        return
    fi

    # Меню и отложенный запуск systemd не получают блокировку от CLI.
    local _rc=0
    cli_lock "${MTPROXYL_LOCK_WAIT:-300}" vless || return 1
    load_settings
    _vless_on "$@" || _rc=$?
    cli_unlock
    return "$_rc"
}

_vless_on() {
    local _assume="${MTPROXYL_ASSUME_YES:-false}" _consent=false _defer=false _arg
    for _arg in "$@"; do
        case "$_arg" in
            --yes) _assume=true ;;
            --allow-disable-me) _consent=true ;;
            --defer-restart) _defer=true ;;
        esac
    done
    VLESS_DEFER_RESTART="$_defer"
    VLESS_ENGINE_PENDING=false
    local _selected="${VLESS_ACTIVE:-}"
    [ -n "$_selected" ] && [ -n "$(_vless_link_row "$_selected")" ] \
        || _selected=$(awk -F'|' 'NR==1 {print $1}' "$(_vless_links)" 2>/dev/null)
    [ -n "$_selected" ] || { log_error "Сначала добавьте ссылку: mtproxyl vless link add '<vless://…>'"; return 1; }
    local _conflict; _conflict=$(_vless_exit_conflicts)
    if [ -n "$_conflict" ] && [ "$_assume" != true ]; then
        log_error "Уже включён другой выход: ${_conflict}"
        log_info "Выключите его или повторите с --yes: mtproxyl vless on --yes"
        return 1
    fi
    if [ "${VLESS_ENABLED:-false}" = true ]; then
        log_info "VLESS уже включён. Для повторного применения: mtproxyl vless recover"
        return 0
    fi
    _vless_me_gate "$_assume" "$_consent" || return 1
    if [ "$_defer" = true ]; then
        local -a _args=()
        [ "$_assume" = true ] && _args+=(--yes)
        if [ "$_consent" = true ] || _vless_me_needs_consent; then _args+=(--allow-disable-me); fi
        if ! systemd-run --quiet --collect --on-active=3 --unit="mtproxyl-vless-on-$(date +%s)-${RANDOM}" \
            "${INSTALL_DIR}/mtproxyl.sh" vless on "${_args[@]}" >/dev/null 2>&1; then
            log_error "Не удалось запланировать включение VLESS"
            return 1
        fi
        log_info "Включение VLESS запланировано"
        return 0
    fi

    local _engine_running=false _check _backup _EGRESS_REPLACED=""
    local -a _files=("$UPSTREAMS_FILE" "$EXPERT_OVERRIDES_FILE")
    local _active_before="${VLESS_ACTIVE:-}" _me_before="${VLESS_ME_DISABLED:-false}"
    local _disabled_before="${VLESS_DISABLED_UPSTREAMS:-}"
    is_proxy_running 2>/dev/null && _engine_running=true
    load_secrets && load_upstreams || return 1
    VLESS_ACTIVE="$_selected"
    if ! _vless_start_xray; then
        VLESS_ACTIVE="$_active_before"
        _vless_cancel_xray
        log_error "Не удалось подготовить Xray. Действующий маршрут сохранён"
        return 1
    fi
    if ! _check=$(vless_test_json) || ! jq -e '.ok == true' <<< "$_check" >/dev/null; then
        VLESS_ACTIVE="$_active_before"
        _vless_cancel_xray
        log_error "Через VLESS не удалось проверить Telegram и DC. Действующий маршрут сохранён"
        return 1
    fi
    vless_test "$_check"
    if ! egress_take_over vless "$_assume"; then
        VLESS_ACTIVE="$_active_before"
        _vless_cancel_xray
        return 1
    fi
    _conflict=$(_vless_exit_conflicts)
    if [ -n "$_conflict" ]; then
        log_error "Не удалось выключить прежний выход: ${_conflict}"
        VLESS_ACTIVE="$_active_before"
        _vless_cancel_xray
        egress_restore
        return 1
    fi
    VLESS_ACTIVE="$_selected"
    if ! _backup=$(_vless_snapshot_route "${_files[@]}"); then
        log_error "Не удалось сохранить настройки для отката VLESS"
        VLESS_ACTIVE="$_active_before"
        _vless_cancel_xray
        egress_restore
        return 1
    fi

    # mtdd собирает маршрут по VLESS_ENABLED: Direct вместо ME.
    VLESS_ENABLED="true"
    if { mtdd_mgr_active || ! _vless_me_enabled || _vless_me_disable; } &&
        _vless_route_engine "$_engine_running" && save_settings; then
        rm -rf -- "$_backup"
        vless_watchdog_install
        log_success "Выход через VLESS включён"
        return 0
    fi

    VLESS_ENABLED=false VLESS_ACTIVE="$_active_before"
    VLESS_ME_DISABLED="$_me_before" VLESS_DISABLED_UPSTREAMS="$_disabled_before"
    if _vless_restore_route "$_backup" "$_engine_running" "${_files[@]}"; then
        rm -rf -- "$_backup"
        log_error "VLESS не применён. Прежний маршрут восстановлен"
    else
        log_error "VLESS не применён. Откат завершился с ошибкой. Копия настроек: $_backup"
    fi
    _vless_cancel_xray
    return 1
}

vless_off() {
    local _defer=false _arg
    for _arg in "$@"; do
        [ "$_arg" = "--defer-restart" ] && _defer=true
    done
    VLESS_DEFER_RESTART="$_defer"
    VLESS_ENGINE_PENDING=false
    check_root
    systemctl disable --now "${VLESS_WATCH_UNIT}.timer" >/dev/null 2>&1 || true
    _vless_drop_upstream
    VLESS_ENABLED="false"
    save_settings
    _vless_engine_apply || return 1
    systemctl disable --now "$VLESS_UNIT" >/dev/null 2>&1 || true
    log_success "VLESS выключен — трафик движка идёт по прежним маршрутам"
    if [ "${VLESS_ME_DISABLED:-false}" = true ]; then
        log_info "Middle proxy остался выключенным: вернуть — mtproxyl expert clear general use_middle_proxy"
        VLESS_ME_DISABLED="false"; save_settings
    fi
    _vless_schedule_engine_apply
}

_vless_links_json() {
    local _f; _f=$(_vless_links)
    [ -s "$_f" ] || { echo '[]'; return 0; }
    local _id _name _src _uri _meta
    while IFS='|' read -r _id _name _src _uri; do
        [ -n "$_id" ] || continue
        _meta=$(_vless_parse check "$_uri" 2>/dev/null) || _meta='{}'
        jq -nc --arg id "$_id" --arg name "$_name" --arg source "${_src:-manual}" \
            --argjson meta "$_meta" --arg active "${VLESS_ACTIVE:-}" '
            {id:$id, name:$name, source:$source,
             host:($meta.host // ""), port:($meta.port // 0),
             security:($meta.security // ""), transport:($meta.transport // ""),
             encryption:($meta.encryption // "none"),
             active:($id == $active)}'
    done < "$_f" | jq -s -c '.'
}

vless_status_json() {
    local _ver="-" _sid="${VLESS_ACTIVE:-}" _meta="{}" _uri="" _active="null"
    local _enabled=false _service="" _subscription=false _watchdog=false _hwid_enabled=true
    local _hwid="" _ua="" _notice="" _me="" _links="[]" _port
    _ver=$(_vless_core_version 2>/dev/null || echo "-")
    _port=$(_vless_port)
    if [ -n "$_sid" ] && [ -n "$(_vless_link_row "$_sid")" ]; then
        _uri=$(_vless_link_uri "$_sid")
        _meta=$(_vless_parse check "$_uri" 2>/dev/null || echo '{}')
        _active=$(jq -c --arg id "$_sid" '. + {id:$id}' <<< "$_meta" 2>/dev/null || echo 'null')
    fi
    [ "${VLESS_ENABLED:-false}" = true ] && _enabled=true
    _service=$(systemctl is-active "$VLESS_UNIT" 2>/dev/null | head -1)
    _links=$(_vless_links_json)
    [ -s "$(_vless_subs)" ] && _subscription=true
    [ "${VLESS_WATCHDOG_ENABLED:-true}" = true ] && _watchdog=true
    [ "${VLESS_HWID_ENABLED:-true}" = true ] || _hwid_enabled=false
    _hwid=$(_vless_hwid 2>/dev/null)
    _ua="${VLESS_SUB_UA:-}"
    _notice=$(cat "$(_vless_sub_notice_file)" 2>/dev/null | head -1)
    _me=$(_vless_me_state)
    jq -nc \
        --argjson enabled "$_enabled" --arg service "$_service" \
        --arg core_version "$_ver" --argjson socks_port "${_port:-0}" \
        --argjson active "$_active" --argjson links "$_links" \
        --argjson subscription "$_subscription" --argjson watchdog "$_watchdog" \
        --arg hwid "$_hwid" --argjson hwid_enabled "$_hwid_enabled" \
        --arg sub_ua "$_ua" --arg sub_notice "$_notice" --arg me_state "$_me" \
        '{enabled:$enabled, service:$service, core_version:$core_version,
          socks_port:$socks_port, active:$active, links:$links,
          links_count:($links | length), subscription:$subscription,
          watchdog:$watchdog, hwid:$hwid, hwid_enabled:$hwid_enabled,
          sub_ua:$sub_ua, sub_notice:$sub_notice, me_state:$me_state}'
}

vless_status() {
    local _j; _j=$(vless_status_json)
    jq -r '
      "",
      "  VLESS: \(if .enabled then "включён" else "выключен" end) · служба \(.service) · Xray \(.core_version)",
      (if .active then
         "  Ссылка: \(.active.id) \(.active.name) → \(.active.host):\(.active.port) (\(.active.security)/\(.active.transport)\(if (.active.encryption // "none") != "none" then "+enc" else "" end))"
       else
         "  Активная ссылка не выбрана"
       end),
      "  SOCKS5: 127.0.0.1:\(.socks_port) · ссылок: \(.links_count) · подписка: \(if .subscription then "да" else "нет" end)",
      "  Middle proxy: \(if .me_state == "direct" then "mtdd: весь DC-трафик через Direct" elif .me_state == "disabled" then "выключен" elif .me_state == "enabled" then "включён" else .me_state end)",
      (if .hwid != "" then
         "  HWID: \(.hwid)\(if .hwid_enabled then "" else " (не отправляется)" end) · клиент подписки: \(if .sub_ua != "" then .sub_ua else "MTProxyL" end)"
       else empty end),
      (if .sub_notice != "" then "  Подписка: \(.sub_notice)" else empty end),
      ""
    ' <<< "$_j"
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
    local _ok; _ok=$(jq -r 'if .ok then "1" else "" end' <<< "$_st" 2>/dev/null)
    local _f; _f=$(_vless_state)
    if [ -n "$_ok" ]; then
        echo '{"fails":0}' > "$_f" 2>/dev/null || true
        return 0
    fi
    local _n=0
    [ -s "$_f" ] && _n=$(jq -r '(.fails // 0) | tonumber' "$_f" 2>/dev/null || echo 0)
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
    local _sub="${1:-status}" _arg
    case "$_sub" in
        on|enable)   shift; vless_on "$@" ;;
        off|disable) shift; vless_off "$@" ;;
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
            shift
            check_root
            [ "${VLESS_ENABLED:-false}" = true ] || { log_error "VLESS выключен"; return 1; }
            VLESS_DEFER_RESTART=false
            VLESS_ENGINE_PENDING=false
            for _arg in "$@"; do
                [ "$_arg" = "--defer-restart" ] && VLESS_DEFER_RESTART=true
            done
            vless_apply && _vless_schedule_engine_apply ;;
        engine-apply)
            check_root
            VLESS_DEFER_RESTART=false
            _vless_engine_apply ;;
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
