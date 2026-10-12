#!/bin/bash
# MTProxyL — внешний API управления (mtproxyl-api). Выключен по умолчанию.
# Служба зовёт тот же CLI через sudo от своего пользователя и только
# команды пользователей и статуса; ключ хранится хешем.

API_SERVICE="mtproxyl-api.service"
API_BIN="/usr/local/bin/mtproxyl-api"
API_USER="mtproxyl-api"
API_DIR="/etc/mtproxyl-api"
API_KEY_FILE="${API_DIR}/key.sha256"
API_TLS_DIR="${API_DIR}/tls"
API_SUDOERS="/etc/sudoers.d/mtproxyl-api"
API_UNIT_FILE="/etc/systemd/system/${API_SERVICE}"

api_is_enabled() { [ "${API_ENABLED:-false}" = "true" ]; }
api_is_active() { systemctl is-active --quiet "$API_SERVICE" 2>/dev/null; }

_api_validate_listen() {
    local _v="$1" _host _port
    [[ "$_v" =~ ^(\[[0-9a-fA-F:]+\]|[0-9.]+):([0-9]+)$ ]] || return 1
    _port="${BASH_REMATCH[2]}"
    [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] || return 1
    _host="${BASH_REMATCH[1]}"
    [[ "$_host" == \[* ]] && return 0
    local IFS=. _o
    read -ra _o <<< "$_host"
    [ "${#_o[@]}" -eq 4 ] || return 1
    for _host in "${_o[@]}"; do
        [[ "$_host" =~ ^[0-9]{1,3}$ ]] && [ "$_host" -le 255 ] || return 1
    done
}

_api_validate_allow() {
    local _v="$1" _p
    [ -z "$_v" ] && return 0
    local IFS=','
    for _p in $_v; do
        _p="${_p// /}"
        [[ "$_p" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || return 1
    done
    return 0
}

api_url() {
    local _scheme="http" _listen="${API_LISTEN:-127.0.0.1:9190}" _host _port
    [ "${API_TLS:-off}" = "selfmask" ] && _scheme="https"
    _host="${_listen%:*}"; _port="${_listen##*:}"
    if [ "$_host" = "0.0.0.0" ]; then
        if [ "$_scheme" = "https" ] && [ -n "${SELFMASK_DOMAIN:-}" ]; then
            _host="$SELFMASK_DOMAIN"
        else
            _host=$(get_public_ip 2>/dev/null || echo "IP")
        fi
    fi
    echo "${_scheme}://${_host}:${_port}"
}

# ── Бинарник ──────────────────────────────────────────────────

# Бинарник выходит вместе с панелью: берём последний её релиз, где он есть.
_api_download() {
    local _arch _rel _url _sum _tmp
    case "$(uname -m)" in
        x86_64|amd64) _arch="amd64" ;;
        aarch64|arm64) _arch="arm64" ;;
        *) log_error "Архитектура $(uname -m) не поддерживается"; return 1 ;;
    esac
    if [ -n "${MTPROXYL_API_BINARY:-}" ] && [ -x "$MTPROXYL_API_BINARY" ]; then
        install -m 755 "$MTPROXYL_API_BINARY" "$API_BIN" || return 1
        log_success "mtproxyl-api взят из ${MTPROXYL_API_BINARY}"
        return 0
    fi
    _rel=$(curl -fsSL --max-time 30 "https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=50" 2>/dev/null) || {
        log_error "Не удалось получить список релизов"; return 1; }
    _url=$(jq -r --arg a "mtproxyl-api-linux-${_arch}" '
        [.[] | select(.tag_name | startswith("mtproxyl-panel-v")) | select(.draft | not)
             | .assets[] | select(.name == $a) | .browser_download_url][0] // empty' <<< "$_rel")
    [ -n "$_url" ] || { log_error "В релизах панели нет mtproxyl-api для ${_arch} — нужна панель 1.3.0 или новее"; return 1; }
    _tmp=$(mktemp) || return 1
    log_info "Скачивание ${_url##*/}..."
    curl -fsSL --max-time 120 "$_url" -o "$_tmp" || { rm -f "$_tmp"; log_error "Не удалось скачать mtproxyl-api"; return 1; }
    _sum=$(curl -fsSL --max-time 30 "${_url}.sha256" 2>/dev/null | awk '{print $1}')
    if [ -n "$_sum" ] && [ "$(sha256sum "$_tmp" | awk '{print $1}')" != "$_sum" ]; then
        rm -f "$_tmp"; log_error "Контрольная сумма mtproxyl-api не совпала"; return 1
    fi
    install -m 755 "$_tmp" "$API_BIN" && rm -f "$_tmp"
    log_success "mtproxyl-api установлен: $("$API_BIN" -version 2>/dev/null)"
}

# ── Пользователь, sudo, ключ ──────────────────────────────────

_api_ensure_user() {
    id "$API_USER" &>/dev/null && return 0
    useradd --system --no-create-home --shell /usr/sbin/nologin "$API_USER" 2>/dev/null \
        || useradd -r -M -s /sbin/nologin "$API_USER" || { log_error "Не удалось создать пользователя ${API_USER}"; return 1; }
}

# Только команды пользователей, статус и перезапуск — ничего про сеть и хост.
_api_write_sudoers() {
    local _s="${INSTALL_DIR}/mtproxyl.sh" _u="$API_USER" _tmp
    _tmp=$(mktemp) || return 1
    cat > "$_tmp" << EOF
# MTProxyL — права mtproxyl-api. Пересоздаётся командой mtproxyl api on.
Defaults:${_u} !syslog, !pam_session
Defaults:${_u} env_keep += "MTPROXYL_ASSUME_YES"
${_u} ALL=(root) NOPASSWD: ${_s} secret list --json
${_u} ALL=(root) NOPASSWD: ${_s} secret add [A-Za-z0-9]*
${_u} ALL=(root) NOPASSWD: ${_s} secret add [A-Za-z0-9]* [0-9a-fA-F]*
${_u} ALL=(root) NOPASSWD: ${_s} secret remove [A-Za-z0-9]*
${_u} ALL=(root) NOPASSWD: ${_s} secret rotate [A-Za-z0-9]*
${_u} ALL=(root) NOPASSWD: ${_s} secret enable [A-Za-z0-9]*
${_u} ALL=(root) NOPASSWD: ${_s} secret disable [A-Za-z0-9]*
${_u} ALL=(root) NOPASSWD: ${_s} secret rename [A-Za-z0-9]* [A-Za-z0-9]*
${_u} ALL=(root) NOPASSWD: ${_s} secret setlimits [A-Za-z0-9]* [0-9]* [0-9]* [0-9]* [0-9]*
${_u} ALL=(root) NOPASSWD: ${_s} secret setrate [A-Za-z0-9]* [0-9]* [0-9]*
${_u} ALL=(root) NOPASSWD: ${_s} secret adtag [A-Za-z0-9]* [0-9a-fA-F]*
${_u} ALL=(root) NOPASSWD: ${_s} secret adtag [A-Za-z0-9]* remove
${_u} ALL=(root) NOPASSWD: ${_s} secret reset-quota [A-Za-z0-9]*
${_u} ALL=(root) NOPASSWD: ${_s} secret link [A-Za-z0-9]*
${_u} ALL=(root) NOPASSWD: ${_s} stats reset user [A-Za-z0-9]*
${_u} ALL=(root) NOPASSWD: ${_s} status --json
${_u} ALL=(root) NOPASSWD: ${_s} restart
EOF
    if command -v visudo &>/dev/null && ! visudo -cf "$_tmp" &>/dev/null; then
        rm -f "$_tmp"; log_error "sudoers для API не прошёл проверку visudo"; return 1
    fi
    install -m 440 -o root -g root "$_tmp" "$API_SUDOERS" && rm -f "$_tmp"
}

# Ключ показывается один раз: на диске остаётся только его SHA-256.
_api_new_key() {
    local _key
    _key=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    [ ${#_key} -eq 64 ] || { log_error "Не удалось получить случайные байты"; return 1; }
    mkdir -p "$API_DIR"
    printf '%s' "$_key" | sha256sum | awk '{print $1}' > "${API_KEY_FILE}.tmp" || return 1
    chown "root:${API_USER}" "${API_KEY_FILE}.tmp" 2>/dev/null || true
    chmod 640 "${API_KEY_FILE}.tmp"
    mv -f "${API_KEY_FILE}.tmp" "$API_KEY_FILE"
    API_NEW_KEY="$_key"
}

# HTTPS на сертификате Selfmask: копия для пользователя службы, обновляется
# вместе с продлением (хук certbot зовёт mtproxyl api sync-cert).
_api_sync_tls() {
    [ "${API_TLS:-off}" = "selfmask" ] || return 0
    local _cd; _cd=$(_selfmask_cert_dir 2>/dev/null)
    [ -n "${SELFMASK_DOMAIN:-}" ] && [ -f "${_cd}/fullchain.pem" ] || {
        log_error "HTTPS для API берёт сертификат Selfmask, а его нет — включите Selfmask или API_TLS off"
        return 1
    }
    mkdir -p "$API_TLS_DIR"
    install -m 644 -o root -g "$API_USER" "${_cd}/fullchain.pem" "${API_TLS_DIR}/cert.pem" || return 1
    install -m 640 -o root -g "$API_USER" "${_cd}/privkey.pem" "${API_TLS_DIR}/key.pem" || return 1
}

_api_write_unit() {
    local _tls="" _allow=""
    [ "${API_TLS:-off}" = "selfmask" ] && _tls=" -tls-cert ${API_TLS_DIR}/cert.pem -tls-key ${API_TLS_DIR}/key.pem"
    [ -n "${API_ALLOW:-}" ] && _allow=" -allow ${API_ALLOW// /}"
    cat > "$API_UNIT_FILE" << EOF
[Unit]
Description=MTProxyL control API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${API_USER}
Group=${API_USER}
ExecStart=${API_BIN} -listen ${API_LISTEN:-127.0.0.1:9190} -key-file ${API_KEY_FILE} -script ${INSTALL_DIR}/mtproxyl.sh -install-dir ${INSTALL_DIR}${_allow}${_tls}
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ── Команды ───────────────────────────────────────────────────

api_enable() {
    check_root
    _api_validate_listen "${API_LISTEN:-127.0.0.1:9190}" || { log_error "API_LISTEN: адрес:порт, например 0.0.0.0:9190"; return 1; }
    _api_ensure_user || return 1
    [ -x "$API_BIN" ] || _api_download || return 1
    _api_write_sudoers || return 1
    local _fresh=""
    [ -f "$API_KEY_FILE" ] || { _api_new_key || return 1; _fresh=1; }
    chown "root:${API_USER}" "$API_DIR" "$API_KEY_FILE" 2>/dev/null || true
    chmod 750 "$API_DIR"
    _api_sync_tls || return 1
    _api_write_unit
    systemctl enable "$API_SERVICE" &>/dev/null || true
    systemctl restart "$API_SERVICE" || { log_error "mtproxyl-api не запустился"; journalctl -u "$API_SERVICE" -n 15 --no-pager | sed 's/^/    /'; return 1; }
    API_ENABLED="true"
    save_settings || return 1
    _api_open_port
    log_success "API включён: $(api_url)"
    [ -n "$_fresh" ] && _api_show_key
    return 0
}

api_disable() {
    check_root
    systemctl disable --now "$API_SERVICE" &>/dev/null || true
    API_ENABLED="false"
    save_settings || return 1
    log_success "API выключен (ключ сохранён — при включении останется прежним)"
}

api_uninstall() {
    check_root
    systemctl disable --now "$API_SERVICE" &>/dev/null || true
    rm -f "$API_UNIT_FILE" "$API_SUDOERS" "$API_BIN"
    rm -rf "$API_DIR"
    systemctl daemon-reload &>/dev/null || true
    id "$API_USER" &>/dev/null && userdel "$API_USER" &>/dev/null || true
    API_ENABLED="false"
    save_settings >/dev/null 2>&1 || true
    log_success "mtproxyl-api удалён"
}

api_rotate_key() {
    check_root
    _api_ensure_user || return 1
    _api_new_key || return 1
    api_is_active && systemctl restart "$API_SERVICE"
    log_success "Новый ключ API создан, прежний больше не действует"
    _api_show_key
}

_api_show_key() {
    echo ""
    echo -e "  ${BOLD}Ключ API (показывается один раз — сохраните):${NC}"
    echo -e "  ${CYAN}${API_NEW_KEY}${NC}"
    echo ""
    echo -e "  ${DIM}Пример: curl -H \"Authorization: Bearer <ключ>\" $(api_url)/v1/users${NC}"
    echo ""
}

# Порт API наружу открываем, только если он слушает не loopback.
_api_open_port() {
    local _host="${API_LISTEN%:*}" _port="${API_LISTEN##*:}"
    case "$_host" in 127.*|"[::1]") return 0 ;; esac
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${_port}/tcp" &>/dev/null && log_info "ufw: открыт порт ${_port}/tcp"
    fi
}

api_restart_if_active() {
    api_is_enabled || return 0
    _api_sync_tls || return 1
    _api_write_unit
    systemctl restart "$API_SERVICE" &>/dev/null || { log_error "mtproxyl-api не перезапустился"; return 1; }
}

api_set_param() {
    local _k="$1" _v="${2:-}"
    case "$_k" in
        API_LISTEN)
            _api_validate_listen "$_v" || { log_error "API_LISTEN: адрес:порт, например 0.0.0.0:9190"; return 1; } ;;
        API_ALLOW)
            [ "$_v" = "-" ] && _v=""
            _api_validate_allow "$_v" || { log_error "API_ALLOW: IP или CIDR через запятую, «-» — без ограничения"; return 1; } ;;
        API_TLS)
            case "$_v" in off|selfmask) ;; *) log_error "API_TLS: off или selfmask"; return 1 ;; esac ;;
        *) log_error "Параметры: API_LISTEN, API_ALLOW, API_TLS"; return 1 ;;
    esac
    printf -v "$_k" '%s' "$_v"
    save_settings || return 1
    api_restart_if_active || return 1
    _api_open_port
    log_success "${_k} = ${_v:-—}"
}

api_status_json() {
    jq -n --argjson enabled "$(api_is_enabled && echo true || echo false)" \
        --argjson active "$(api_is_active && echo true || echo false)" \
        --argjson installed "$([ -x "$API_BIN" ] && echo true || echo false)" \
        --argjson has_key "$([ -f "$API_KEY_FILE" ] && echo true || echo false)" \
        --arg listen "${API_LISTEN:-127.0.0.1:9190}" --arg allow "${API_ALLOW:-}" \
        --arg tls "${API_TLS:-off}" --arg url "$(api_url)" \
        --arg version "$([ -x "$API_BIN" ] && "$API_BIN" -version 2>/dev/null)" \
        '{enabled: $enabled, active: $active, installed: $installed, has_key: $has_key,
          listen: $listen, allow: $allow, tls: $tls, url: $url, version: $version}'
}

api_show_status() {
    echo ""
    echo -e "  ${BOLD}API управления MTProxyL${NC}"
    echo -e "  Состояние: $(api_is_enabled && { api_is_active && echo -e "${GREEN}включён${NC}" || echo -e "${YELLOW}включён, служба не работает${NC}"; } || echo -e "${DIM}выключен${NC}")"
    echo -e "  Адрес:     $(api_url)  ${DIM}(API_LISTEN ${API_LISTEN:-127.0.0.1:9190})${NC}"
    echo -e "  Доступ:    ${API_ALLOW:-с любого адреса, только по ключу}"
    echo -e "  HTTPS:     $([ "${API_TLS:-off}" = selfmask ] && echo "сертификат Selfmask" || echo "нет")"
    echo -e "  Ключ:      $([ -f "$API_KEY_FILE" ] && echo "задан" || echo "не создан")"
    echo ""
}

handle_api_command() {
    local _sub="${1:-status}"; shift || true
    case "$_sub" in
        status) if [ "${1:-}" = "--json" ]; then api_status_json; else api_show_status; fi ;;
        on|enable) api_enable ;;
        off|disable) api_disable ;;
        key) api_rotate_key ;;
        set) api_set_param "${1:-}" "${2:-}" ;;
        sync-cert) api_restart_if_active ;;
        update) check_root; _api_download && api_restart_if_active ;;
        uninstall) api_uninstall ;;
        *)
            echo -e "  ${BOLD}API управления (по умолчанию выключен):${NC}"
            echo -e "    ${GREEN}api status${NC} [--json]          Состояние"
            echo -e "    ${GREEN}api on${NC} | ${GREEN}api off${NC}            Включить / выключить"
            echo -e "    ${GREEN}api key${NC}                      Новый ключ (старый перестаёт работать)"
            echo -e "    ${GREEN}api set API_LISTEN${NC} 0.0.0.0:9190  Где слушать"
            echo -e "    ${GREEN}api set API_ALLOW${NC} 1.2.3.4,10.0.0.0/8  С каких адресов пускать («-» — с любых)"
            echo -e "    ${GREEN}api set API_TLS${NC} off|selfmask  HTTPS на сертификате Selfmask"
            echo -e "    ${GREEN}api update${NC}                   Обновить mtproxyl-api"
            echo -e "    ${GREEN}api uninstall${NC}                Удалить службу, ключ и пользователя"
            ;;
    esac
}
