#!/bin/bash
# MTProxyL — генерация config.toml + режим эксперта

_TUNE_FILE="${INSTALL_DIR}/tunings.conf"

# ── Tune whitelist ────────────────────────────────────────────
_TUNE_WHITELIST=(
    "fake_cert_len:censorship:^[0-9]+$"
    "client_handshake:timeouts:^[0-9]+$"
    "tg_connect:general:^[0-9]+$"
    "client_keepalive:timeouts:^[0-9]+$"
    "client_ack:timeouts:^[0-9]+$"
    "replay_check_len:access:^[0-9]+$"
    "replay_window_secs:access:^[0-9]+$"
    "ignore_time_skew:access:^(true|false)$"
    "listen_backlog:server:^[0-9]+$"
    "max_connections:server:^[0-9]+$"
    "accept_permit_timeout_ms:server:^[0-9]+$"
    "prefer_ipv6:general:^(true|false)$"
    "fast_mode:general:^(true|false)$"
    "log_level:general:^(debug|verbose|normal|silent)$"
    "mask_relay_timeout_ms:censorship:^[0-9]+$"
    "mask_relay_idle_timeout_ms:censorship:^[0-9]+$"
    "client_mss:server:^(extreme-low|tspu|2in8|[0-9]+)$"
    "client_mss_bulk:server:^(extreme-low|tspu|2in8|[0-9]+)$"
)

_tune_lookup() {
    local param="$1" entry
    for entry in "${_TUNE_WHITELIST[@]}"; do
        [[ "$entry" =~ ^${param}: ]] && { echo "$entry"; return 0; }
    done
    return 1
}

handle_tune_command() {
    local sub="${1:-list}"; shift 2>/dev/null || true
    case "$sub" in
        list)
            echo ""; draw_header "ПАРАМЕТРЫ ТЮНИНГА ДВИЖКА"; echo ""
            local entry p s v
            for entry in "${_TUNE_WHITELIST[@]}"; do
                IFS=':' read -r p s v <<< "$entry"
                printf "  %-32s ${DIM}[%s]${NC}\n" "$p" "$s"
            done
            echo ""
            [ -f "$_TUNE_FILE" ] && [ -s "$_TUNE_FILE" ] && {
                echo -e "  ${BOLD}Текущие:${NC}"
                while IFS='|' read -r p v; do
                    [ -z "$p" ] && continue; echo "    ${p} = ${v}"
                done < "$_TUNE_FILE"; echo ""
            } ;;
        get)
            local param="$1"
            if [ -z "$param" ]; then
                [ ! -f "$_TUNE_FILE" ] || [ ! -s "$_TUNE_FILE" ] && { log_info "Нет параметров"; return; }
                while IFS='|' read -r p v; do [ -z "$p" ] && continue; echo "  ${p} = ${v}"; done < "$_TUNE_FILE"
            else
                local v; v=$(awk -F'|' -v u="$param" '$1==u{print $2; exit}' "$_TUNE_FILE" 2>/dev/null)
                [ -n "$v" ] && echo "  ${param} = ${v}" || echo -e "  ${DIM}${param}: не задан${NC}"
            fi ;;
        set)
            check_root
            local param="$1" value="$2"
            [ -z "$param" ] && { log_error "Использование: tune set <параметр> <значение>"; return 1; }
            local entry; entry=$(_tune_lookup "$param") || { log_error "Неизвестный параметр. Выполните: mtproxyl tune list"; return 1; }
            local p sect regex; IFS=':' read -r p sect regex <<< "$entry"
            [ -z "$value" ] && { log_error "Требуется значение"; return 1; }
            [[ "$value" =~ $regex ]] || { log_error "Некорректное значение (ожидается: ${regex})"; return 1; }
            mkdir -p "$INSTALL_DIR"; touch "$_TUNE_FILE"; chmod 600 "$_TUNE_FILE"
            local tmp; tmp=$(_mktemp) || return 1
            grep -v "^${param}|" "$_TUNE_FILE" > "$tmp" 2>/dev/null || true
            echo "${param}|${value}" >> "$tmp"
            mv "$tmp" "$_TUNE_FILE"; chmod 600 "$_TUNE_FILE"
            log_success "${param} = ${value}"
            if is_proxy_running; then
                echo -en "  ${DIM}Перезапустить? [Y/n]:${NC} "; local r; read -r r 2>/dev/null || r="y"
                [[ ! "$r" =~ ^[nN] ]] && { load_secrets; restart_proxy_container || true; }
            fi ;;
        clear)
            check_root
            local param="$1"
            [ -z "$param" ] && { log_error "Использование: tune clear <параметр|all>"; return 1; }
            [ ! -f "$_TUNE_FILE" ] && { log_info "Нет параметров"; return 0; }
            if [ "$param" = "all" ]; then rm -f "$_TUNE_FILE"; log_success "Все параметры очищены"
            else
                local tmp; tmp=$(_mktemp) || return 1
                grep -v "^${param}|" "$_TUNE_FILE" > "$tmp" 2>/dev/null || true
                mv "$tmp" "$_TUNE_FILE"; chmod 600 "$_TUNE_FILE"
                log_success "${param} очищен"
            fi ;;
    esac
}

# ── Генерация config.toml ────────────────────────────────────
generate_telemt_config() {
    mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"

    local domain="${PROXY_DOMAIN:-cloudflare.com}"
    local mask_enabled="${MASKING_ENABLED:-true}"
    local mask_host="${MASKING_HOST:-$domain}"
    local mask_port="${MASKING_PORT:-443}"
    local ad_tag="${AD_TAG:-}"
    local port="${PROXY_PORT:-443}"
    local metrics_port="${PROXY_METRICS_PORT:-9090}"

    local tmp; tmp=$(_mktemp "$CONFIG_DIR") || return 1

    cat > "$tmp" << TOML_EOF
# MTProxyL — конфигурация telemt
# Создано: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

[general]
prefer_ipv6 = false
tg_connect = 30
fast_mode = true
use_middle_proxy = true
log_level = "normal"
$([ -n "$ad_tag" ] && echo "ad_tag = \"$ad_tag\"")
$([ -n "${PROXY_SECRET_URL:-}" ] && echo "proxy_secret_url = \"${PROXY_SECRET_URL}\"")
$([ -n "${PROXY_CONFIG_V4_URL:-}" ] && echo "proxy_config_v4_url = \"${PROXY_CONFIG_V4_URL}\"")
$([ -n "${PROXY_CONFIG_V6_URL:-}" ] && echo "proxy_config_v6_url = \"${PROXY_CONFIG_V6_URL}\"")

[general.modes]
classic = false
secure = $([ "$mask_enabled" = "false" ] && echo "true" || echo "false")
tls = true

[general.links]
show = [$(get_enabled_labels_quoted)]

[server]
port = ${port}
listen_addr_ipv4 = "0.0.0.0"
listen_addr_ipv6 = "::"
proxy_protocol = ${PROXY_PROTOCOL:-false}
metrics_listen = "127.0.0.1:${metrics_port}"
metrics_whitelist = ["127.0.0.1", "::1"]

[timeouts]
client_handshake = 90
client_keepalive = 120
client_ack = 90

[censorship]
tls_domain = "${domain}"
unknown_sni_action = "${UNKNOWN_SNI_ACTION:-mask}"
mask = ${mask_enabled}
mask_port = ${mask_port}
$([ "$mask_enabled" = "true" ] && [ -n "$mask_host" ] && echo "mask_host = \"${mask_host}\"")
$([ -n "${MASKING_RELAY_MAX_BYTES:-}" ] && echo "mask_relay_max_bytes = ${MASKING_RELAY_MAX_BYTES}")
fake_cert_len = ${FAKE_CERT_LEN:-2048}

[access]
replay_check_len = 65536
replay_window_secs = 1800
ignore_time_skew = false

[access.users]
TOML_EOF

    # Секреты
    local i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        echo "${SECRETS_LABELS[$i]} = \"${SECRETS_KEYS[$i]}\"" >> "$tmp"
    done

    # Лимиты
    local has_conns=false has_ips=false has_quota=false has_expires=false
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        [ "${SECRETS_MAX_CONNS[$i]:-0}" != "0" ] && has_conns=true
        [ "${SECRETS_MAX_IPS[$i]:-0}" != "0" ] && has_ips=true
        [ "${SECRETS_QUOTA[$i]:-0}" != "0" ] && has_quota=true
        [ "${SECRETS_EXPIRES[$i]:-0}" != "0" ] && has_expires=true
    done

    if $has_conns; then
        echo "" >> "$tmp"; echo "[access.user_max_tcp_conns]" >> "$tmp"
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && [ "${SECRETS_MAX_CONNS[$i]:-0}" != "0" ] && \
                echo "${SECRETS_LABELS[$i]} = ${SECRETS_MAX_CONNS[$i]}" >> "$tmp"
        done
    fi
    if $has_ips; then
        echo "" >> "$tmp"; echo "[access.user_max_unique_ips]" >> "$tmp"
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && [ "${SECRETS_MAX_IPS[$i]:-0}" != "0" ] && \
                echo "${SECRETS_LABELS[$i]} = ${SECRETS_MAX_IPS[$i]}" >> "$tmp"
        done
    fi
    if $has_quota; then
        echo "" >> "$tmp"; echo "[access.user_data_quota]" >> "$tmp"
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && [ "${SECRETS_QUOTA[$i]:-0}" != "0" ] && \
                echo "${SECRETS_LABELS[$i]} = ${SECRETS_QUOTA[$i]}" >> "$tmp"
        done
    fi
    if $has_expires; then
        echo "" >> "$tmp"; echo "[access.user_expirations]" >> "$tmp"
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && [ "${SECRETS_EXPIRES[$i]:-0}" != "0" ] && \
                echo "${SECRETS_LABELS[$i]} = \"${SECRETS_EXPIRES[$i]}\"" >> "$tmp"
        done
    fi

    # Upstreams
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_ENABLED[$i]}" = "true" ] || continue
        echo "" >> "$tmp"; echo "[[upstreams]]" >> "$tmp"
        echo "type = \"${UPSTREAM_TYPES[$i]}\"" >> "$tmp"
        echo "weight = ${UPSTREAM_WEIGHTS[$i]}" >> "$tmp"
        [ "${UPSTREAM_TYPES[$i]}" != "direct" ] && [ -n "${UPSTREAM_ADDRS[$i]}" ] && \
            echo "address = \"${UPSTREAM_ADDRS[$i]}\"" >> "$tmp"
        if [ "${UPSTREAM_TYPES[$i]}" = "socks5" ]; then
            [ -n "${UPSTREAM_USERS[$i]}" ] && echo "username = \"${UPSTREAM_USERS[$i]}\"" >> "$tmp"
            [ -n "${UPSTREAM_PASSES[$i]}" ] && echo "password = \"${UPSTREAM_PASSES[$i]}\"" >> "$tmp"
        elif [ "${UPSTREAM_TYPES[$i]}" = "socks4" ] && [ -n "${UPSTREAM_USERS[$i]}" ]; then
            echo "user_id = \"${UPSTREAM_USERS[$i]}\"" >> "$tmp"
        fi
        [ -n "${UPSTREAM_IFACES[$i]}" ] && echo "interface = \"${UPSTREAM_IFACES[$i]}\"" >> "$tmp"
    done

    # Engine tunings
    if [ -f "${_TUNE_FILE:-/dev/null}" ] && [ -s "${_TUNE_FILE}" ]; then
        while IFS='|' read -r _tp _tv; do
            [ -z "$_tp" ] && continue
            _tune_lookup "$_tp" >/dev/null 2>&1 || continue
            local _tv_out
            if [[ "$_tv" =~ ^(true|false|[0-9]+)$ ]]; then _tv_out="$_tv"; else _tv_out="\"$_tv\""; fi
            if grep -qE "^${_tp} *=" "$tmp"; then
                sed -i "s/^${_tp} *=.*/${_tp} = ${_tv_out}/" "$tmp"
            else
                awk -v p="$_tp" -v v="$_tv_out" '
                    BEGIN{ins=0} {print}
                    /^\[general\]$/ && !ins {print p " = " v; ins=1}
                ' "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
            fi
        done < "$_TUNE_FILE"
    fi

    # Expert overrides
    _apply_expert_overrides "$tmp"

    chmod 644 "$tmp"
    cp "$tmp" "${CONFIG_DIR}/config.toml" && rm -f "$tmp"
}

handle_expert_command() {
    local subcmd="${1:-list}"; shift 2>/dev/null || true
    case "$subcmd" in
        list)  expert_list ;;
        set)   check_root; expert_set "$1" "$2" "$3" ;;
        clear) check_root; expert_clear "$1" ;;
        edit)
            check_root
            local config="${CONFIG_DIR}/config.toml"
            if [ -f "$config" ]; then
                local editor="${EDITOR:-nano}"
                log_warn "Изменения будут перезаписаны при генерации конфига!"
                log_info "Для постоянных: mtproxyl expert set <секция> <ключ> <значение>"
                "$editor" "$config"
            else log_error "Конфиг не найден"; fi ;;
        *)
            echo -e "  ${BOLD}Режим эксперта:${NC}"
            echo -e "    ${GREEN}expert list${NC}                            Параметры"
            echo -e "    ${GREEN}expert set${NC} <секция> <ключ> <значение>   Добавить"
            echo -e "    ${GREEN}expert clear${NC} <ключ|all>                 Удалить"
            echo -e "    ${GREEN}expert edit${NC}                            Редактор" ;;
    esac
}
