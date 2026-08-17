#!/bin/bash
# MTProxyL — маршрут до Telegram через Cloudflare WARP (warpscout).
# Вариант A — SOCKS5 + redsocks, вариант B — интерфейс WireGuard.

WARPSCOUT_VERSION="0.14.0"
WARPSCOUT_UPSTREAM_REPO="vernette/warpscout"

WARP_IFACE="mtpwarp"
WARP_NFT_TABLE="mtproxyl_warp"
WARP_RT_TABLE="51820"
# Бит метки свой: у zapret2 заняты 0x40000000 и 0x40000, пересечься нельзя.
WARP_FWMARK_DEFAULT="0x100000"

WARP_UPSTREAM_NAME="warp"
WARP_UPSTREAM_LOCAL="warplocal"
WARP_SOCKS_UNIT="mtproxyl-warp-socks.service"
WARP_REDSOCKS_UNIT="mtproxyl-warp-redsocks.service"
WARP_IFACE_UNIT="mtproxyl-warp-iface.service"
WARP_ROUTE_UNIT="mtproxyl-warp-route.service"

_warp_dir()      { echo "${INSTALL_DIR:-/opt/mtproxyl}/warp"; }
_warp_bin()      { echo "$(_warp_dir)/warpscout"; }
_warp_account()  { echo "$(_warp_dir)/account.json"; }
_warp_state()    { echo "$(_warp_dir)/state.json"; }
_warp_cidr()     { echo "$(_warp_dir)/telegram-cidr.txt"; }
_warp_conf()     { echo "$(_warp_dir)/${WARP_IFACE}.conf"; }
_warp_redsocks_conf() { echo "$(_warp_dir)/redsocks.conf"; }
_warp_nft_script()    { echo "$(_warp_dir)/nft.sh"; }
_warp_runner()        { echo "$(_warp_dir)/run-socks.sh"; }

_warp_fwmark() {
    local _v="${WARP_FWMARK:-$WARP_FWMARK_DEFAULT}"
    [[ "$_v" =~ ^0x[0-9a-fA-F]{1,8}$ ]] || _v="$WARP_FWMARK_DEFAULT"
    echo "$_v"
}

_warp_variant_letter() {
    case "$(_warp_mode)" in iface) echo "B" ;; upstream) echo "C" ;; *) echo "A" ;; esac
}

_warp_mode()  { case "${WARP_MODE:-socks}" in iface) echo "iface" ;; upstream) echo "upstream" ;; *) echo "socks" ;; esac; }
_warp_proto() {
    # У интерфейса выбора нет: awg и masque живут только в туннеле warpscout.
    [ "$(_warp_mode)" = "iface" ] && { echo "wg"; return; }
    case "${WARP_PROTO:-awg}" in wg|masque|masque-h2) echo "${WARP_PROTO}" ;; *) echo "awg" ;; esac
}
_warp_socks_port() {
    local _v="${WARP_SOCKS_PORT:-41080}"
    [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 1 ] && [ "$_v" -le 65535 ] || _v="41080"
    echo "$_v"
}
_warp_redir_port() {
    local _v="${WARP_REDIR_PORT:-41081}"
    [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 1 ] && [ "$_v" -le 65535 ] || _v="41081"
    echo "$_v"
}
# Цель в docker bridge не достучится до петли хоста — тогда слушаем все адреса
# и закрываем порт правилом, а в конфиг цели идёт адрес шлюза моста.
_warp_target_is_bridge() {
    [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] || return 1
    [ "${DETECTED_NETWORK_MODE:-host}" = "bridge" ]
}

_warp_socks_listen() {
    _warp_target_is_bridge && { echo "0.0.0.0"; return 0; }
    echo "127.0.0.1"
}

_warp_socks_reachable_host() {
    if _warp_target_is_bridge; then
        local _gw; _gw=$(ip -4 route show 2>/dev/null | awk '$3 ~ /^(docker|br-)/ && $1 ~ /\// {print $NF; exit}')
        [ -n "$_gw" ] && { echo "$_gw"; return 0; }
    fi
    echo "127.0.0.1"
}

_warp_mtu() {
    local _v="${WARP_MTU:-1280}"
    [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 1000 ] && [ "$_v" -le 1500 ] || _v="1280"
    echo "$_v"
}

# ── Бинарник ────────────────────────────────────────────────────────────────

_warp_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) return 1 ;;
    esac
}

_warp_bin_version() {
    local _b; _b=$(_warp_bin)
    [ -x "$_b" ] || return 1
    "$_b" version 2>/dev/null | head -1 | tr -d '\r'
}

# Понимает ли бинарник ключи, которыми мы его зовём.
_warp_bin_usable() {
    local _b; _b=$(_warp_bin)
    [ -x "$_b" ] || return 1
    local _help; _help=$("$_b" scan -h 2>&1; "$_b" socks -h 2>&1)
    local _flag
    for _flag in best conf endpoint country node; do
        grep -q -- "-${_flag}\b" <<< "$_help" || return 1
    done
    return 0
}

warp_install_binary() {
    local _dir; _dir=$(_warp_dir)
    mkdir -p "$_dir"
    chmod 700 "$_dir"

    if [ -x "$(_warp_bin)" ] && [ "$(_warp_bin_version)" = "$WARPSCOUT_VERSION" ] && _warp_bin_usable; then
        log_success "warpscout ${WARPSCOUT_VERSION} уже установлен"
        return 0
    fi

    local _arch; _arch=$(_warp_arch) || { log_error "Архитектура $(uname -m) не поддерживается"; return 1; }

    # Сначала релиз оригинального проекта, запасной — наша сборка из форка.
    local _sources=(
        "https://github.com/${WARPSCOUT_UPSTREAM_REPO}/releases/download/v${WARPSCOUT_VERSION}/warpscout_${WARPSCOUT_VERSION}_linux_${_arch}.tar.gz"
        "https://github.com/${GITHUB_REPO}/releases/download/warpscout-${WARPSCOUT_VERSION}/mtproxyl-warpscout-${WARPSCOUT_VERSION}-linux-${_arch}.tar.gz"
    )
    local _names=("оригинального проекта" "сборки MTProxyL")

    local _tmp _i _ok="false"
    _tmp=$(mktemp -d /tmp/warpscout.XXXXXX) || { log_error "Не удалось создать временный каталог"; return 1; }
    for _i in "${!_sources[@]}"; do
        log_info "Скачиваем warpscout ${WARPSCOUT_VERSION} из ${_names[$_i]}..."
        if ! curl -fsSL --max-time 180 "${_sources[$_i]}" -o "${_tmp}/ws.tar.gz" 2>/dev/null; then
            log_warn "Источник недоступен: ${_sources[$_i]}"
            continue
        fi
        if ! tar xzf "${_tmp}/ws.tar.gz" -C "$_tmp" 2>/dev/null; then
            log_warn "Архив не распаковался"
            continue
        fi
        local _found; _found=$(find "$_tmp" -type f -name warpscout | head -1)
        [ -n "$_found" ] || { log_warn "В архиве нет warpscout"; continue; }
        install -m 700 "$_found" "$(_warp_bin)" || continue
        if ! _warp_bin_usable; then
            log_warn "Скачанный warpscout не понимает нужные ключи — пробуем следующий источник"
            rm -f "$(_warp_bin)"
            continue
        fi
        _ok="true"
        break
    done
    rm -rf "$_tmp"

    [ "$_ok" = "true" ] || { log_error "Не удалось поставить warpscout"; return 1; }
    log_success "warpscout $(_warp_bin_version) установлен: $(_warp_bin)"
}

# Бесплатная учётка Cloudflare — без неё warpscout не работает.
_warp_ensure_account() {
    [ -s "$(_warp_account)" ] && return 0
    log_info "Регистрируем учётную запись WARP..."
    "$(_warp_bin)" register -a "$(_warp_account)" >/dev/null 2>&1 || {
        log_error "Cloudflare не выдал учётную запись WARP"
        log_info "Проверьте, что с сервера доступен api.cloudflareclient.com"
        return 1
    }
    chmod 600 "$(_warp_account)"
    log_success "Учётная запись WARP получена"
}

# ── Выбор эндпоинта ─────────────────────────────────────────────────────────

# «DE,NL» — страны (две буквы), «FRA,AMS» — узлы Cloudflare (три).
_warp_location_args() {
    local _raw="${WARP_LOCATION:-}"
    [ -n "$_raw" ] || return 0
    local _tok _countries="" _nodes=""
    local _old="$IFS"; IFS=','
    local -a _toks=(); read -ra _toks <<< "$_raw"
    IFS="$_old"
    for _tok in "${_toks[@]}"; do
        _tok="${_tok//[[:space:]]/}"
        [ -n "$_tok" ] || continue
        _tok=$(tr '[:lower:]' '[:upper:]' <<< "$_tok")
        if [[ "$_tok" =~ ^[A-Z]{2}$ ]]; then
            _countries+="${_countries:+,}${_tok}"
        elif [[ "$_tok" =~ ^[A-Z]{3}$ ]]; then
            _nodes+="${_nodes:+,}${_tok}"
        fi
    done
    [ -n "$_countries" ] && printf '%s\n%s\n' "-country" "$_countries"
    [ -n "$_nodes" ] && printf '%s\n%s\n' "-node" "$_nodes"
    return 0
}

_warp_scan_args() {
    local -a _a=(-a "$(_warp_account)" -p "$(_warp_proto)" -plain)
    local _line
    while IFS= read -r _line; do [ -n "$_line" ] && _a+=("$_line"); done < <(_warp_location_args)
    printf '%s\n' "${_a[@]}"
}

# Лучший эндпоинт на stdout; прогресс warpscout уходит в stderr.
warp_scan_best() {
    local _target="${1:-}"
    local -a _args=()
    local _line
    while IFS= read -r _line; do _args+=("$_line"); done < <(_warp_scan_args)
    _args+=(-best)
    [ -n "$_target" ] && _args+=(-target "$_target")

    local _out
    _out=$("$(_warp_bin)" scan "${_args[@]}" 2>/dev/null | tail -1 | tr -d '\r')
    [[ "$_out" =~ ^[0-9a-fA-F:.]+:[0-9]+$ ]] || return 1
    echo "$_out"
}

# Закреплённый эндпоинт проверяем точечно; молчит — ищем заново.
warp_resolve_endpoint() {
    local _pin="${WARP_ENDPOINT:-}"
    if [ -n "$_pin" ]; then
        local _host="${_pin%:*}"
        if warp_scan_best "$_host" >/dev/null 2>&1; then
            echo "$_pin"
            return 0
        fi
        log_warn "Закреплённый эндпоинт ${_pin} не отвечает — ищем новый"
    fi
    local _found; _found=$(warp_scan_best) || return 1
    echo "$_found"
}

# ── Подсети Telegram ────────────────────────────────────────────────────────

# Официальный список подсетей Telegram.
_WARP_CIDR_URL="https://core.telegram.org/resources/cidr.txt"

# Запасной список: core.telegram.org недоступен ровно там, где всё это нужно.
_warp_cidr_fallback() {
    cat <<'EOF'
91.108.4.0/22
91.108.8.0/22
91.108.12.0/22
91.108.16.0/22
91.108.20.0/22
91.108.56.0/22
91.105.192.0/23
149.154.160.0/20
185.76.151.0/24
2001:67c:4e8::/48
2001:b28:f23d::/48
2001:b28:f23f::/48
2001:b28:f23c::/48
2a0a:f280::/32
EOF
}

warp_update_cidr() {
    local _file; _file=$(_warp_cidr)
    mkdir -p "$(_warp_dir)"
    local _tmp; _tmp=$(mktemp "$(_warp_dir)/cidr.XXXXXX") || return 1

    if curl -fsS --max-time 15 "$_WARP_CIDR_URL" 2>/dev/null \
       | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' > "$_tmp" && [ -s "$_tmp" ]; then
        mv -f "$_tmp" "$_file"
        log_success "Список подсетей Telegram обновлён: $(wc -l < "$_file") записей"
        return 0
    fi
    rm -f "$_tmp"

    if [ -s "$_file" ]; then
        log_warn "core.telegram.org недоступен — оставляем прежний список ($(wc -l < "$_file") записей)"
        return 0
    fi
    _warp_cidr_fallback > "$_file"
    log_warn "core.telegram.org недоступен — берём встроенный список ($(wc -l < "$_file") записей)"
}

_warp_cidr_list() {
    local _file; _file=$(_warp_cidr) _family="${1:-4}"
    [ -s "$_file" ] || _warp_cidr_fallback > "$_file"
    if [ "$_family" = "6" ]; then
        grep ':' "$_file" | paste -sd, -
    else
        grep -v ':' "$_file" | paste -sd, -
    fi
}

# ── Правила nft ─────────────────────────────────────────────────────────────

# Подсети docker-мостов: их трафик ловится в prerouting, а не в output.
_warp_bridge_nets() {
    ip -4 route show 2>/dev/null \
        | awk '$1 ~ /^(172\.1[6-9]|172\.2[0-9]|172\.3[01]|10\.|192\.168)\./ && $2 == "dev" && $3 ~ /^(docker|br-)/ {print $1}' \
        | paste -sd, -
}

_warp_generate_nft() {
    local _mode; _mode=$(_warp_mode)
    local _v4 _v6 _bridges
    _v4=$(_warp_cidr_list 4); _v6=$(_warp_cidr_list 6)
    _bridges=$(_warp_bridge_nets)

    local _script; _script=$(_warp_nft_script)
    {
        echo "#!/bin/sh"
        echo "# Сгенерировано MTProxyL — правила маршрута до Telegram через WARP"
        echo "nft delete table inet ${WARP_NFT_TABLE} 2>/dev/null || true"
        echo "nft add table inet ${WARP_NFT_TABLE}"
        echo "nft add set inet ${WARP_NFT_TABLE} tg4 '{ type ipv4_addr; flags interval; }'"
        echo "nft add set inet ${WARP_NFT_TABLE} tg6 '{ type ipv6_addr; flags interval; }'"
        if [ "$_mode" != "upstream" ]; then
            [ -n "$_v4" ] && echo "nft add element inet ${WARP_NFT_TABLE} tg4 '{ ${_v4} }'"
            [ -n "$_v6" ] && echo "nft add element inet ${WARP_NFT_TABLE} tg6 '{ ${_v6} }'"
        fi

        if [ "$_mode" = "upstream" ]; then
            # Порт открыт на все адреса ради цели в docker bridge — снаружи закрываем.
            local _sp; _sp=$(_warp_socks_port)
            echo "nft add chain inet ${WARP_NFT_TABLE} input '{ type filter hook input priority -150; policy accept; }'"
            echo "nft add rule inet ${WARP_NFT_TABLE} input iifname lo accept"
            [ -n "$_bridges" ] && echo "nft add rule inet ${WARP_NFT_TABLE} input ip saddr { ${_bridges} } tcp dport ${_sp} accept"
            echo "nft add rule inet ${WARP_NFT_TABLE} input tcp dport ${_sp} drop"
        elif [ "$_mode" = "socks" ]; then
            local _port; _port=$(_warp_redir_port)
            # nat/output — трафик самого хоста (движок службой или сеть host).
            echo "nft add chain inet ${WARP_NFT_TABLE} output '{ type nat hook output priority -100; policy accept; }'"
            echo "nft add rule inet ${WARP_NFT_TABLE} output meta l4proto tcp ip daddr @tg4 counter redirect to :${_port}"
            echo "nft add rule inet ${WARP_NFT_TABLE} output meta l4proto tcp ip6 daddr @tg6 counter redirect to :${_port}"
            if [ -n "$_bridges" ]; then
                # nat/prerouting — трафик контейнера за docker bridge.
                echo "nft add chain inet ${WARP_NFT_TABLE} prerouting '{ type nat hook prerouting priority -100; policy accept; }'"
                echo "nft add rule inet ${WARP_NFT_TABLE} prerouting meta l4proto tcp ip saddr { ${_bridges} } ip daddr @tg4 counter redirect to :${_port}"
            fi
            # Порт слушает на всех адресах ради контейнеров — снаружи закрываем.
            echo "nft add chain inet ${WARP_NFT_TABLE} input '{ type filter hook input priority -150; policy accept; }'"
            echo "nft add rule inet ${WARP_NFT_TABLE} input iifname lo accept"
            [ -n "$_bridges" ] && echo "nft add rule inet ${WARP_NFT_TABLE} input ip saddr { ${_bridges} } tcp dport ${_port} accept"
            echo "nft add rule inet ${WARP_NFT_TABLE} input tcp dport ${_port} drop"
        else
            local _mark; _mark=$(_warp_fwmark)
            # Метку ставим до выбора маршрута — ядро перевыберет его по ip rule.
            echo "nft add chain inet ${WARP_NFT_TABLE} output '{ type route hook output priority -150; policy accept; }'"
            echo "nft add rule inet ${WARP_NFT_TABLE} output ip daddr @tg4 counter meta mark set meta mark or ${_mark}"
            echo "nft add rule inet ${WARP_NFT_TABLE} output ip6 daddr @tg6 counter meta mark set meta mark or ${_mark}"
            if [ -n "$_bridges" ]; then
                echo "nft add chain inet ${WARP_NFT_TABLE} prerouting '{ type filter hook prerouting priority -150; policy accept; }'"
                echo "nft add rule inet ${WARP_NFT_TABLE} prerouting ip saddr { ${_bridges} } ip daddr @tg4 counter meta mark set meta mark or ${_mark}"
            fi
            # Пакеты с приватным источником Cloudflare отбросит — подменяем.
            echo "nft add chain inet ${WARP_NFT_TABLE} postrouting '{ type nat hook postrouting priority 100; policy accept; }'"
            echo "nft add rule inet ${WARP_NFT_TABLE} postrouting oifname ${WARP_IFACE} masquerade"
        fi
    } > "$_script"
    chmod 700 "$_script"
}

_warp_nft_remove() {
    nft delete table inet "${WARP_NFT_TABLE}" 2>/dev/null || true
}

# ── Служба варианта A: warpscout socks + redsocks ───────────────────────────

_warp_write_socks_runner() {
    local _runner; _runner=$(_warp_runner)
    cat > "$_runner" <<EOF
#!/bin/bash
# SOCKS5 поверх WARP; перед стартом сверяем, жив ли эндпоинт.
set -u
INSTALL_DIR="${INSTALL_DIR:-/opt/mtproxyl}"
SETTINGS_FILE="\${INSTALL_DIR}/settings.conf"
[ -f "\$SETTINGS_FILE" ] && . "\$SETTINGS_FILE"

BIN="$(_warp_bin)"
ACCOUNT="$(_warp_account)"
STATE="$(_warp_state)"
PROTO="$(_warp_proto)"
PORT="$(_warp_socks_port)"

pick() {
    local args=(-a "\$ACCOUNT" -p "\$PROTO" -plain -best)
    [ -n "\${WARP_LOCATION:-}" ] && args+=(\$WARP_LOCATION_ARGS)
    "\$BIN" scan "\${args[@]}" 2>/dev/null | tail -1 | tr -d '\r'
}

WARP_LOCATION_ARGS="$( _warp_location_args | paste -sd' ' - )"
EP="\${WARP_ENDPOINT:-}"
if [ -n "\$EP" ]; then
    args=(-a "\$ACCOUNT" -p "\$PROTO" -plain -best -target "\${EP%:*}")
    CHECK=\$("\$BIN" scan "\${args[@]}" 2>/dev/null | tail -1 | tr -d '\r')
    [ -n "\$CHECK" ] || EP=""
fi
[ -n "\$EP" ] || EP=\$(pick)
if [ -z "\$EP" ]; then
    echo "warpscout: живого эндпоинта WARP не нашлось" >&2
    exit 1
fi
printf '{"endpoint":"%s","proto":"%s","picked_at":%s}\n' "\$EP" "\$PROTO" "\$(date +%s)" > "\$STATE"
exec "\$BIN" socks -a "\$ACCOUNT" -e "\$EP" -p "\$PROTO" -l LISTEN_ADDR -port "\$PORT"
EOF
    sed -i "s/LISTEN_ADDR/$(_warp_socks_listen)/" "$_runner"
    chmod 700 "$_runner"
}

_warp_write_redsocks_conf() {
    local _conf; _conf=$(_warp_redsocks_conf)
    cat > "$_conf" <<EOF
base {
    log_debug = off;
    log_info = on;
    log = "stderr";
    daemon = off;
    redirector = iptables;
}

redsocks {
    local_ip = 0.0.0.0;
    local_port = $(_warp_redir_port);
    ip = 127.0.0.1;
    port = $(_warp_socks_port);
    type = socks5;
}
EOF
    chmod 600 "$_conf"
}

_warp_write_socks_units() {
    cat > "/etc/systemd/system/${WARP_SOCKS_UNIT}" <<EOF
[Unit]
Description=MTProxyL WARP SOCKS5 (warpscout)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(_warp_runner)
Restart=always
RestartSec=10
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF

    cat > "/etc/systemd/system/${WARP_REDSOCKS_UNIT}" <<EOF
[Unit]
Description=MTProxyL WARP transparent redirector (redsocks)
After=${WARP_SOCKS_UNIT}
Requires=${WARP_SOCKS_UNIT}

[Service]
Type=simple
ExecStart=/usr/sbin/redsocks -c $(_warp_redsocks_conf)
ExecStartPost=/bin/sh $(_warp_nft_script)
ExecStopPost=/bin/sh -c '/usr/sbin/nft delete table inet ${WARP_NFT_TABLE} 2>/dev/null || true'
Restart=always
RestartSec=5
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ── Служба варианта B: интерфейс WireGuard + policy routing ─────────────────

_warp_write_iface_units() {
    cat > "/etc/systemd/system/${WARP_IFACE_UNIT}" <<EOF
[Unit]
Description=MTProxyL WARP interface (${WARP_IFACE})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/wg-quick up $(_warp_conf)
ExecStop=/usr/bin/wg-quick down $(_warp_conf)

[Install]
WantedBy=multi-user.target
EOF

    # Маршрут и правило — отдельной службой: интерфейс может подняться заново.
    cat > "/etc/systemd/system/${WARP_ROUTE_UNIT}" <<EOF
[Unit]
Description=MTProxyL WARP policy routing
After=${WARP_IFACE_UNIT}
Requires=${WARP_IFACE_UNIT}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip route replace default dev ${WARP_IFACE} table ${WARP_RT_TABLE}; ip rule add fwmark $(_warp_fwmark)/$(_warp_fwmark) lookup ${WARP_RT_TABLE} 2>/dev/null || true; ip -6 route replace default dev ${WARP_IFACE} table ${WARP_RT_TABLE} 2>/dev/null || true; ip -6 rule add fwmark $(_warp_fwmark)/$(_warp_fwmark) lookup ${WARP_RT_TABLE} 2>/dev/null || true'
ExecStartPost=/bin/sh $(_warp_nft_script)
ExecStop=/bin/sh -c 'ip rule del fwmark $(_warp_fwmark)/$(_warp_fwmark) lookup ${WARP_RT_TABLE} 2>/dev/null || true; ip -6 rule del fwmark $(_warp_fwmark)/$(_warp_fwmark) lookup ${WARP_RT_TABLE} 2>/dev/null || true; ip route flush table ${WARP_RT_TABLE} 2>/dev/null || true; /usr/sbin/nft delete table inet ${WARP_NFT_TABLE} 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

_warp_generate_iface_conf() {
    local _ep="$1"
    log_info "Готовим конфиг WireGuard для ${_ep}..."
    local -a _args=()
    local _line
    while IFS= read -r _line; do _args+=("$_line"); done < <(_warp_scan_args)
    _args+=(-best -target "${_ep%:*}" -conf "$(_warp_conf)" -table-off -no-dns -mtu "$(_warp_mtu)")

    "$(_warp_bin)" scan "${_args[@]}" >/dev/null 2>&1
    [ -s "$(_warp_conf)" ] || { log_error "warpscout не отдал конфиг WireGuard"; return 1; }
    chmod 600 "$(_warp_conf)"
    # Строка DNS в wg-quick переписала бы /etc/resolv.conf всему серверу.
    sed -i '/^DNS[[:space:]]*=/d' "$(_warp_conf)"
    return 0
}

# ── Зависимости ─────────────────────────────────────────────────────────────

_warp_need_packages() {
    local -a _need=()
    [ "$(_warp_mode)" = "upstream" ] && return 0
    if [ "$(_warp_mode)" = "socks" ]; then
        command -v redsocks &>/dev/null || [ -x /usr/sbin/redsocks ] || _need+=("redsocks")
    else
        command -v wg-quick &>/dev/null || _need+=("wireguard-tools")
    fi
    command -v nft &>/dev/null || _need+=("nftables")
    [ ${#_need[@]} -eq 0 ] && return 0

    log_info "Ставим зависимости: ${_need[*]}"
    case "$(detect_os)" in
        debian)
            apt-get update -qq || log_warn "apt update прошёл с ошибками — ставим из того, что уже в индексе"
            apt-get install -y -qq "${_need[@]}" || true ;;
        rhel)  yum install -y -q "${_need[@]}" || true ;;
        alpine) apk add --no-cache "${_need[@]}" || true ;;
        *) log_warn "Неизвестный дистрибутив — поставьте вручную: ${_need[*]}"; return 1 ;;
    esac

    if [ "$(_warp_mode)" = "socks" ]; then
        [ -x /usr/sbin/redsocks ] || command -v redsocks &>/dev/null || {
            log_error "redsocks не установился — вариант A без него не работает"
            return 1
        }
    else
        command -v wg-quick &>/dev/null || {
            log_error "wireguard-tools не установились — вариант B без них не работает"
            return 1
        }
        modprobe wireguard 2>/dev/null || true
        if ! ip link add dev _warpprobe type wireguard 2>/dev/null; then
            log_error "Ядро не умеет WireGuard — на этом хосте доступен только вариант A"
            return 1
        fi
        ip link del dev _warpprobe 2>/dev/null || true
    fi
    return 0
}

# ── Middle proxy: почему он несовместим ─────────────────────────────────────

# ME с WARP несовместим: ключи рукопожатия зависят от адреса и порта, а выход
# Cloudflare меняет и то, и другое. Замеры — в README и CHANGELOG.
_warp_me_enabled() {
    local _cfg; _cfg=$(_engine_config_path 2>/dev/null)
    [ -n "$_cfg" ] && [ -r "$_cfg" ] || return 1
    grep -qE '^[[:space:]]*use_middle_proxy[[:space:]]*=[[:space:]]*false' "$_cfg" && return 1
    return 0
}

_warp_me_gate() {
    _warp_me_enabled || return 0

    echo ""
    log_warn "У движка включён middle proxy (ME) — вместе с WARP он не работает"
    echo -e "  ${DIM}Ключи ME-рукопожатия выводятся из адреса и порта, с которых движок${NC}"
    echo -e "  ${DIM}пришёл к Telegram. Выход WARP — общий CGNAT Cloudflare: он меняет${NC}"
    echo -e "  ${DIM}и адрес, и порт, стороны считают разные ключи, и связь с DC${NC}"
    echo -e "  ${DIM}пропадает целиком. Обойти это настройкой нельзя.${NC}"
    echo ""
    echo -e "  ${DIM}Прямая маршрутизация (use_middle_proxy = false) через WARP работает:${NC}"
    echo -e "  ${DIM}движок ходит к дата-центрам как обычный клиент. Цена — рекламная${NC}"
    echo -e "  ${DIM}метка (спонсорский канал) перестаёт действовать: она живёт только${NC}"
    echo -e "  ${DIM}в режиме ME.${NC}"
    echo ""

    if [ "${MTPROXYL_MODE:-manager}" != "manager" ] || _superexpert_active 2>/dev/null; then
        log_error "Выключите ME в конфиге цели и перезапустите её, потом включайте WARP"
        echo -e "  ${DIM}В [general] конфига $(_engine_config_path): use_middle_proxy = false${NC}"
        return 1
    fi

    if [ "${MTPROXYL_ASSUME_YES:-}" = "1" ]; then
        log_error "Выключите ME сами: mtproxyl expert set general use_middle_proxy false"
        log_info "Автоматически не выключаем — вместе с ним отключится рекламная метка"
        return 1
    fi

    echo -en "  ${BOLD}Выключить middle proxy и продолжить? [y/N]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Ничего не меняем — WARP не включён"; return 1; }

    handle_expert_command set general use_middle_proxy false --no-apply >/dev/null || {
        log_error "Не удалось выключить middle proxy"
        return 1
    }
    _WARP_CONFIG_DIRTY="true"
    log_success "Middle proxy выключен — движок пойдёт к дата-центрам напрямую"
    return 0
}

# ── Включение и выключение ──────────────────────────────────────────────────

# Вариант C: маршрут задаёт сам движок, правил в ядре нет. Записи upstream
# живут в нашем config.toml, поэтому только режим менеджера.
_warp_local_mask_backend() {
    [ "${SELFMASK_ENABLED:-false}" = "true" ] && return 0
    case "${MASKING_HOST:-}" in 127.0.0.1|localhost|::1) return 0 ;; esac
    return 1
}

# Чужие маршруты без области: движок раскладывает между ними трафик по весу,
# и часть пошла бы мимо туннеля. Имена запоминаем, чтобы вернуть при выключении.
_warp_foreign_default_upstreams() {
    load_upstreams 2>/dev/null
    local _i _out=""
    for _i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_ENABLED[$_i]}" = "true" ] || continue
        [ -n "${UPSTREAM_SCOPES[$_i]:-}" ] && continue
        case "${UPSTREAM_NAMES[$_i]}" in "$WARP_UPSTREAM_NAME"|"$WARP_UPSTREAM_LOCAL") continue ;; esac
        _out+="${_out:+,}${UPSTREAM_NAMES[$_i]}"
    done
    printf '%s' "$_out"
}

_warp_owns_engine_config() {
    [ "${MTPROXYL_MODE:-manager}" = "manager" ] || return 1
    [ "${TOOLS_ONLY:-false}" = "true" ] && return 1
    _superexpert_active 2>/dev/null && return 1
    return 0
}

# Конфиг не наш — правит его владелец. Печатаем ровно то, что нужно дописать.
_warp_upstream_manual_hint() {
    local _addr; _addr="$(_warp_socks_reachable_host):$(_warp_socks_port)"
    if _warp_owns_engine_config; then
        log_info "В этом режиме MTProxyL правит конфиг сам — руками ничего не нужно"
        echo -e "  ${DIM}Ниже — то же самое, если хотите свериться.${NC}"
    fi
    local _cfg; _cfg=$(_engine_config_path 2>/dev/null)
    echo ""
    log_info "Туннель поднят, дальше — правка конфига движка (он не наш)"
    echo -e "  ${BOLD}1.${NC} Допишите в ${_cfg:-конфиг цели}:"
    echo ""
    echo -e "  ${DIM}[[upstreams]]${NC}"
    echo -e "  ${DIM}type = \"socks5\"${NC}"
    echo -e "  ${DIM}address = \"${_addr}\"${NC}"
    echo -e "  ${DIM}weight = 1${NC}"
    echo -e "  ${DIM}enabled = true${NC}"
    echo ""
    echo -e "  ${BOLD}2.${NC} Выключите там же остальные маршруты без ${DIM}scopes${NC}"
    echo -e "     ${DIM}(enabled = false): запрос без области движок раскладывает${NC}"
    echo -e "     ${DIM}между всеми такими маршрутами по весу, и часть соединений${NC}"
    echo -e "     ${DIM}пойдёт мимо туннеля. Если маршрутов там нет вовсе — ничего не нужно.${NC}"
    echo ""
    echo -e "  ${BOLD}3.${NC} Если mask-бэкенд у цели локальный (127.0.0.1), добавьте туда же:"
    echo ""
    echo -e "  ${DIM}[censorship]${NC}"
    echo -e "  ${DIM}tls_fetch_scope = \"local\"${NC}"
    echo ""
    echo -e "  ${DIM}[[upstreams]]${NC}"
    echo -e "  ${DIM}type = \"direct\"${NC}"
    echo -e "  ${DIM}scopes = \"local\"${NC}"
    echo -e "  ${DIM}weight = 1${NC}"
    echo -e "  ${DIM}enabled = true${NC}"
    echo ""
    echo -e "  ${BOLD}4.${NC} Перезапустите цель: ${GREEN}mtproxyl restart${NC}"
    echo ""
    echo -e "  ${DIM}Конфиг цели можно открыть отсюда: mtproxyl target-config show${NC}"
    _warp_target_is_bridge && \
        echo -e "  ${DIM}Цель в docker bridge, поэтому адрес шлюза, а не 127.0.0.1.${NC}"
    echo -e "  ${DIM}Проверить после перезапуска: mtproxyl warp status${NC}"
    echo ""
}

_warp_apply_upstream() {
    local _others; _others=$(_warp_foreign_default_upstreams)
    if [ -n "$_others" ]; then
        echo ""
        log_warn "Есть другие маршруты без области: ${_others}"
        echo -e "  ${DIM}Движок раскладывает трафик между всеми такими маршрутами по весу —${NC}"
        echo -e "  ${DIM}часть соединений пойдёт мимо туннеля. Их нужно выключить.${NC}"
        if [ "${MTPROXYL_ASSUME_YES:-}" != "1" ]; then
            echo -en "  ${BOLD}Выключить их на время работы WARP? [Y/n]:${NC} "
            local _yn; read_line _yn
            [[ "$_yn" =~ ^[nN] ]] && { log_error "Без этого вариант C работать не будет"; return 1; }
        fi
    fi

    UPSTREAM_DEFER_RESTART="true"
    local _rc=0 _name
    local _old="$IFS"; IFS=','
    local -a _list=(); read -ra _list <<< "$_others"
    IFS="$_old"
    for _name in "${_list[@]}"; do
        [ -n "$_name" ] || continue
        upstream_toggle "$_name" disable >/dev/null 2>&1 || true
    done
    WARP_DISABLED_UPSTREAMS="$_others"

    upstream_remove "$WARP_UPSTREAM_NAME" >/dev/null 2>&1 || true
    upstream_add "$WARP_UPSTREAM_NAME" socks5 "127.0.0.1:$(_warp_socks_port)" "" "" 1 "" "" >/dev/null \
        || { log_error "Не удалось добавить upstream ${WARP_UPSTREAM_NAME}"; _rc=1; }

    # Локальный mask-бэкенд через socks недостижим: туннель резолвит 127.0.0.1
    # у себя. Возвращаем только загрузку TLS-метаданных на прямой маршрут.
    upstream_remove "$WARP_UPSTREAM_LOCAL" >/dev/null 2>&1 || true
    if [ $_rc -eq 0 ] && _warp_local_mask_backend; then
        upstream_add "$WARP_UPSTREAM_LOCAL" direct "" "" "" 1 "" "local" >/dev/null || true
        handle_expert_command set censorship tls_fetch_scope local --no-apply >/dev/null 2>&1 \
            || log_warn "Не удалось задать censorship.tls_fetch_scope — маскировка может не подтянуть сертификат"
    fi

    UPSTREAM_DEFER_RESTART="false"
    [ $_rc -eq 0 ] || return 1

    log_success "Маршрут движка: socks5 127.0.0.1:$(_warp_socks_port)"
    [ -n "$_others" ] && log_info "Выключены на время работы WARP: ${_others}"
    _warp_local_mask_backend && log_info "Загрузка TLS-метаданных с локального бэкенда идёт мимо туннеля"
    return 0
}

_warp_drop_upstream() {
    load_upstreams 2>/dev/null
    UPSTREAM_DEFER_RESTART="true"
    upstream_remove "$WARP_UPSTREAM_NAME" >/dev/null 2>&1 || true
    upstream_remove "$WARP_UPSTREAM_LOCAL" >/dev/null 2>&1 || true
    handle_expert_command clear censorship tls_fetch_scope --no-apply >/dev/null 2>&1 || true

    local _name
    local _old="$IFS"; IFS=','
    local -a _list=(); read -ra _list <<< "${WARP_DISABLED_UPSTREAMS:-}"
    IFS="$_old"
    for _name in "${_list[@]}"; do
        [ -n "$_name" ] || continue
        upstream_toggle "$_name" enable >/dev/null 2>&1 && log_info "Маршрут '${_name}' включён обратно"
    done
    WARP_DISABLED_UPSTREAMS=""
    UPSTREAM_DEFER_RESTART="false"
}

warp_enable() {
    check_root
    local _mode="${1:-$(_warp_mode)}"
    case "$_mode" in
        socks|a|A) WARP_MODE="socks" ;;
        iface|b|B) WARP_MODE="iface" ;;
        upstream|c|C) WARP_MODE="upstream" ;;
        *) log_error "Вариант: socks (A), iface (B) или upstream (C)"; return 1 ;;
    esac


    # С включённым ME включать нечего.
    _WARP_CONFIG_DIRTY="false"
    _warp_me_gate || return 1

    _warp_need_packages || return 1
    warp_install_binary || return 1
    _warp_ensure_account || return 1
    warp_update_cidr

    log_info "Ищем живой эндпоинт WARP (${WARP_LOCATION:-лучший по задержке}, протокол $(_warp_proto))..."
    log_info "Разведка идёт несколько минут — она поднимает туннель к каждому кандидату"
    local _ep; _ep=$(warp_resolve_endpoint) || {
        log_error "Живого эндпоинта WARP не нашлось"
        log_info "Если задана локация, попробуйте убрать её: mtproxyl warp location clear"
        return 1
    }
    WARP_ENDPOINT="$_ep"
    log_success "Эндпоинт: ${_ep}"

    # Вариант C правил не ставит; исключение — закрытый снаружи порт socks,
    # когда его пришлось открыть на все адреса ради цели в docker bridge.
    if [ "$(_warp_mode)" != "upstream" ] || [ "$(_warp_socks_listen)" != "127.0.0.1" ]; then
        _warp_generate_nft
    fi

    if [ "$(_warp_mode)" != "iface" ]; then
        _warp_write_socks_runner
        _warp_write_socks_units
        systemctl enable --now "$WARP_SOCKS_UNIT" >/dev/null 2>&1
        # Туннель поднимается не мгновенно.
        local _i
        for _i in $(seq 1 30); do
            ss -ltn 2>/dev/null | grep -q ":$(_warp_socks_port)\b" && break
            sleep 1
        done
    fi

    if [ "$(_warp_mode)" = "upstream" ]; then
        [ "$(_warp_socks_listen)" = "127.0.0.1" ] || sh "$(_warp_nft_script)" 2>/dev/null || true
        if _warp_owns_engine_config; then
            _warp_apply_upstream || return 1
            _WARP_CONFIG_DIRTY="true"
        else
            _warp_upstream_manual_hint
        fi
    elif [ "$(_warp_mode)" = "socks" ]; then
        _warp_write_redsocks_conf
        systemctl enable --now "$WARP_REDSOCKS_UNIT" >/dev/null 2>&1
    else
        _warp_generate_iface_conf "$_ep" || return 1
        _warp_write_iface_units
        systemctl enable --now "$WARP_IFACE_UNIT" >/dev/null 2>&1
        systemctl enable --now "$WARP_ROUTE_UNIT" >/dev/null 2>&1
    fi

    WARP_ENABLED="true"
    save_settings

    # Один перезапуск на все правки конфига: и выключенный ME, и маршруты.
    if [ "$_WARP_CONFIG_DIRTY" = "true" ]; then
        generate_telemt_config >/dev/null 2>&1 || true
        is_proxy_running && restart_proxy_container >/dev/null 2>&1
    fi

    if warp_check_route; then
        log_success "Трафик до Telegram идёт через WARP (вариант $(_warp_variant_letter))"
    else
        log_warn "Правила применены, но проверка маршрута не подтвердила выход через WARP"
        log_info "Смотрите: mtproxyl warp status, journalctl -u ${WARP_SOCKS_UNIT}"
    fi
    echo ""
    log_info "Проверьте связь с Telegram: mtproxyl dc"
}

warp_disable() {
    check_root
    local _was_upstream="false"
    if [ "$(_warp_mode)" = "upstream" ]; then
        if _warp_owns_engine_config; then
            _warp_drop_upstream
            _was_upstream="true"
        else
            log_info "Уберите запись socks5-upstream из конфига цели и перезапустите её"
        fi
    fi
    systemctl disable --now "$WARP_REDSOCKS_UNIT" >/dev/null 2>&1 || true
    systemctl disable --now "$WARP_SOCKS_UNIT" >/dev/null 2>&1 || true
    systemctl disable --now "$WARP_ROUTE_UNIT" >/dev/null 2>&1 || true
    systemctl disable --now "$WARP_IFACE_UNIT" >/dev/null 2>&1 || true
    _warp_nft_remove
    ip rule del fwmark "$(_warp_fwmark)/$(_warp_fwmark)" lookup "$WARP_RT_TABLE" 2>/dev/null || true
    ip -6 rule del fwmark "$(_warp_fwmark)/$(_warp_fwmark)" lookup "$WARP_RT_TABLE" 2>/dev/null || true
    ip route flush table "$WARP_RT_TABLE" 2>/dev/null || true
    WARP_ENABLED="false"
    save_settings
    if [ "$_was_upstream" = "true" ]; then
        generate_telemt_config >/dev/null 2>&1 || true
        is_proxy_running && restart_proxy_container >/dev/null 2>&1
    fi
    log_success "Маршрут до Telegram через WARP выключен — трафик идёт напрямую"
    if _warp_me_enabled; then :; else
        log_info "Middle proxy остался выключенным: mtproxyl expert clear general use_middle_proxy"
    fi
}

warp_remove() {
    check_root
    warp_disable
    rm -f "/etc/systemd/system/${WARP_SOCKS_UNIT}" "/etc/systemd/system/${WARP_REDSOCKS_UNIT}" \
          "/etc/systemd/system/${WARP_IFACE_UNIT}" "/etc/systemd/system/${WARP_ROUTE_UNIT}"
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$(_warp_dir)"
    log_success "warpscout и его службы удалены"
}

# Переприменить: список подсетей и адрес моста меняются, правила — нет.
warp_reapply() {
    check_root
    [ "${WARP_ENABLED:-false}" = "true" ] || { log_error "WARP выключен: mtproxyl warp on"; return 1; }
    warp_update_cidr
    _warp_generate_nft
    sh "$(_warp_nft_script)" || { log_error "Правила nft не применились"; return 1; }
    log_success "Правила переприменены"
}

# ── Состояние ───────────────────────────────────────────────────────────────

_warp_unit_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

_warp_nft_applied() {
    nft list table inet "${WARP_NFT_TABLE}" >/dev/null 2>&1
}

# Выход по версии самого Cloudflare: в его ответе есть warp=on/off.
warp_exit_info() {
    local _url="https://www.cloudflare.com/cdn-cgi/trace" _out=""
    if [ "$(_warp_mode)" != "iface" ] && _warp_unit_active "$WARP_SOCKS_UNIT"; then
        _out=$(curl -fsS --max-time 10 -x "socks5h://127.0.0.1:$(_warp_socks_port)" "$_url" 2>/dev/null)
    elif [ "$(_warp_mode)" = "iface" ] && ip link show "$WARP_IFACE" >/dev/null 2>&1; then
        _out=$(curl -fsS --max-time 10 --interface "$WARP_IFACE" "$_url" 2>/dev/null)
    fi
    [ -n "$_out" ] || return 1
    local _ip _loc _colo _warp
    _ip=$(grep -m1 '^ip=' <<< "$_out" | cut -d= -f2)
    _loc=$(grep -m1 '^loc=' <<< "$_out" | cut -d= -f2)
    _colo=$(grep -m1 '^colo=' <<< "$_out" | cut -d= -f2)
    _warp=$(grep -m1 '^warp=' <<< "$_out" | cut -d= -f2)
    [ "$_warp" = "on" ] || return 1
    echo "${_ip:-?}|${_loc:-?}|${_colo:-?}"
}

# Сколько пакетов правило увело в туннель.
warp_matched_packets() {
    nft list table inet "${WARP_NFT_TABLE}" 2>/dev/null \
        | grep -E '@tg[46]' \
        | grep -oE 'packets [0-9]+' \
        | awk '{s += $2} END {print s + 0}'
}

# Дешёвая проверка без сети: службы на месте и правила применены.
warp_route_ready() {
    [ "${WARP_ENABLED:-false}" = "true" ] || return 1
    if [ "$(_warp_mode)" = "upstream" ]; then
        _warp_unit_active "$WARP_SOCKS_UNIT" || return 1
        if ! _warp_owns_engine_config; then
            local _cfg; _cfg=$(_engine_config_path 2>/dev/null)
            [ -r "$_cfg" ] || return 1
            grep -q "$(_warp_socks_reachable_host):$(_warp_socks_port)" "$_cfg"
            return $?
        fi
        load_upstreams 2>/dev/null
        local _i
        for _i in "${!UPSTREAM_NAMES[@]}"; do
            [ "${UPSTREAM_NAMES[$_i]}" = "$WARP_UPSTREAM_NAME" ] && return 0
        done
        return 1
    fi
    if [ "$(_warp_mode)" = "socks" ]; then
        _warp_unit_active "$WARP_SOCKS_UNIT" || return 1
        _warp_unit_active "$WARP_REDSOCKS_UNIT" || return 1
    else
        ip link show "$WARP_IFACE" >/dev/null 2>&1 || return 1
        ip route show table "$WARP_RT_TABLE" 2>/dev/null | grep -q "$WARP_IFACE" || return 1
    fi
    _warp_nft_applied
}

# Полная проверка: плюс ответ Cloudflare с warp=on, ходит в сеть.
warp_check_route() {
    warp_route_ready || return 1
    warp_exit_info >/dev/null 2>&1
}

warp_status() {
    echo ""
    draw_header "МАРШРУТ ДО TELEGRAM ЧЕРЕЗ WARP"
    echo ""

    if [ "${WARP_ENABLED:-false}" != "true" ]; then
        log_info "Выключен — трафик до Telegram идёт напрямую"
        echo -e "  ${DIM}Включить: mtproxyl warp on socks (A), iface (B) или upstream (C)${NC}"
        echo ""
        return 0
    fi

    local _mode; _mode=$(_warp_mode)
    local _title="вариант A — SOCKS5 + redsocks"
    [ "$_mode" = "iface" ] && _title="вариант B — интерфейс ${WARP_IFACE}"
    [ "$_mode" = "upstream" ] && _title="вариант C — socks5-upstream движка"
    echo -e "  ${BOLD}Режим:${NC}        ${_title}"
    echo -e "  ${BOLD}Протокол:${NC}     $(_warp_proto)"
    echo -e "  ${BOLD}Эндпоинт:${NC}     ${WARP_ENDPOINT:-${DIM}выбирается разведкой${NC}}"
    echo -e "  ${BOLD}Локация:${NC}      ${WARP_LOCATION:-${DIM}лучший по задержке${NC}}"

    local _exit; _exit=$(warp_exit_info 2>/dev/null)
    if [ -n "$_exit" ]; then
        local _ip _loc _colo; IFS='|' read -r _ip _loc _colo <<< "$_exit"
        echo -e "  ${BOLD}Выход:${NC}        ${_ip}, ${_loc} ${DIM}(узел ${_colo}, Cloudflare подтверждает WARP)${NC}"
    else
        echo -e "  ${BOLD}Выход:${NC}        ${YELLOW}туннель не подтверждён${NC}"
    fi

    echo ""
    if [ "$_mode" = "upstream" ]; then
        echo -e "  ${BOLD}Туннель:${NC}      $(_warp_unit_active "$WARP_SOCKS_UNIT" && echo -e "${GREEN}работает${NC}" || echo -e "${RED}лежит${NC}") ${DIM}(socks5 на 127.0.0.1:$(_warp_socks_port))${NC}"
        echo -e "  ${BOLD}Upstream:${NC}     $(warp_route_ready >/dev/null 2>&1 && echo -e "${GREEN}прописан в конфиге движка${NC}" || echo -e "${RED}нет${NC}")"
        if _warp_owns_engine_config; then
            local _rogue; _rogue=$(_warp_foreign_default_upstreams)
            [ -n "$_rogue" ] && log_warn "Маршруты без области мимо туннеля: ${_rogue}"
        else
            echo -e "  ${DIM}Конфиг цели правится вручную: mtproxyl warp hint${NC}"
        fi
        echo ""
        echo -e "  ${DIM}Связь с дата-центрами Telegram: mtproxyl dc${NC}"
        echo ""
        return 0
    elif [ "$_mode" = "socks" ]; then
        echo -e "  ${BOLD}Туннель:${NC}      $(_warp_unit_active "$WARP_SOCKS_UNIT" && echo -e "${GREEN}работает${NC}" || echo -e "${RED}лежит${NC}") ${DIM}(${WARP_SOCKS_UNIT})${NC}"
        echo -e "  ${BOLD}Редирект:${NC}     $(_warp_unit_active "$WARP_REDSOCKS_UNIT" && echo -e "${GREEN}работает${NC}" || echo -e "${RED}лежит${NC}") ${DIM}(порт $(_warp_redir_port))${NC}"
    else
        echo -e "  ${BOLD}Интерфейс:${NC}    $(ip link show "$WARP_IFACE" >/dev/null 2>&1 && echo -e "${GREEN}поднят${NC}" || echo -e "${RED}нет${NC}") ${DIM}(${WARP_IFACE}, метка $(_warp_fwmark))${NC}"
    fi
    echo -e "  ${BOLD}Правила nft:${NC}  $(_warp_nft_applied && echo -e "${GREEN}на месте${NC}" || echo -e "${RED}нет${NC}") ${DIM}(подсетей: $(wc -l < "$(_warp_cidr)" 2>/dev/null || echo 0))${NC}"
    echo -e "  ${BOLD}Уведено:${NC}      $(warp_matched_packets) пакетов до Telegram"
    echo ""
    echo -e "  ${DIM}Связь с дата-центрами Telegram: mtproxyl dc${NC}"
    echo ""
}

warp_status_json() {
    local _exit_ip="" _exit_loc="" _exit_colo=""
    local _exit; _exit=$(warp_exit_info 2>/dev/null) && IFS='|' read -r _exit_ip _exit_loc _exit_colo <<< "$_exit"

    local _tunnel="false" _redir="false" _iface="false"
    _warp_unit_active "$WARP_SOCKS_UNIT" && _tunnel="true"
    _warp_unit_active "$WARP_REDSOCKS_UNIT" && _redir="true"
    ip link show "$WARP_IFACE" >/dev/null 2>&1 && _iface="true"

    printf '{"enabled":%s,"mode":"%s","proto":"%s","endpoint":"%s","location":"%s",' \
        "$([ "${WARP_ENABLED:-false}" = "true" ] && echo true || echo false)" \
        "$(_warp_mode)" "$(_warp_proto)" \
        "$(json_escape "${WARP_ENDPOINT:-}")" "$(json_escape "${WARP_LOCATION:-}")"
    printf '"installed":%s,"version":"%s","socks_active":%s,"redirect_active":%s,"iface_active":%s,' \
        "$([ -x "$(_warp_bin)" ] && echo true || echo false)" \
        "$(json_escape "$(_warp_bin_version 2>/dev/null)")" \
        "$_tunnel" "$_redir" "$_iface"
    printf '"nft_applied":%s,"cidr_count":%s,"socks_port":%s,"redirect_port":%s,"matched_packets":%s,' \
        "$(_warp_nft_applied && echo true || echo false)" \
        "$(wc -l < "$(_warp_cidr)" 2>/dev/null || echo 0)" \
        "$(_warp_socks_port)" "$(_warp_redir_port)" "$(warp_matched_packets)"
    printf '"exit":{"ip":"%s","loc":"%s","colo":"%s","confirmed":%s}}\n' \
        "$(json_escape "$_exit_ip")" "$(json_escape "$_exit_loc")" "$(json_escape "$_exit_colo")" \
        "$([ -n "$_exit_ip" ] && echo true || echo false)"
}

# Строка главного меню — только когда включено.
warp_menu_line() {
    [ "${WARP_ENABLED:-false}" = "true" ] || return 0
    local _variant; _variant=$(_warp_variant_letter)
    local _state="${RED}лежит${NC}"
    warp_route_ready >/dev/null 2>&1 && _state="${GREEN}работает${NC}"
    local _where="${WARP_LOCATION:-авто}"
    echo -e "  ${BOLD}Telegram через WARP:${NC} вариант ${_variant}, ${_state} ${DIM}(${_where}, $(_warp_proto))${NC}"
}

# ── Настройки ───────────────────────────────────────────────────────────────

warp_set_location() {
    check_root
    local _v="${1:-}"
    case "$_v" in
        clear|auto|"") WARP_LOCATION=""; save_settings; log_success "Локация: лучший по задержке"; return 0 ;;
    esac
    local _norm=""
    local _line
    while IFS= read -r _line; do _norm+="${_norm:+ }${_line}"; done < <(_warp_location_args)
    [ -n "$_norm" ] || { log_error "Локация: коды стран (DE,NL) или узлов Cloudflare (FRA,AMS)"; return 1; }
    WARP_LOCATION="$_v"
    save_settings
    log_success "Локация: ${_v} (${_norm})"
    log_info "Применится при следующей разведке: mtproxyl warp scan"
}

warp_set_endpoint() {
    check_root
    local _v="${1:-}"
    case "$_v" in
        clear|auto|"") WARP_ENDPOINT=""; save_settings; log_success "Эндпоинт выбирается разведкой"; return 0 ;;
    esac
    [[ "$_v" =~ ^[0-9a-fA-F:.]+:[0-9]+$ ]] || { log_error "Эндпоинт: адрес вида 188.114.98.58:2408"; return 1; }
    WARP_ENDPOINT="$_v"
    save_settings
    log_success "Эндпоинт закреплён: ${_v}"
}

warp_set_proto() {
    check_root
    case "${1:-}" in
        awg|wg|masque|masque-h2) WARP_PROTO="$1" ;;
        *) log_error "Протокол: awg, wg, masque или masque-h2"; return 1 ;;
    esac
    save_settings
    log_success "Протокол: ${WARP_PROTO}"
    [ "$(_warp_mode)" = "iface" ] && log_warn "Вариант B работает только по wg — протокол учтётся при переходе на вариант A"
    return 0
}

# Разведка руками.
warp_scan_show() {
    check_root
    [ -x "$(_warp_bin)" ] || { log_error "warpscout не установлен: mtproxyl warp install"; return 1; }
    _warp_ensure_account || return 1
    echo ""
    log_info "Разведка эндпоинтов WARP (${WARP_LOCATION:-лучший по задержке}, $(_warp_proto))"
    log_info "Это несколько минут: к каждому кандидату поднимается настоящий туннель"
    local _ep; _ep=$(warp_scan_best) || { log_error "Живых эндпоинтов не нашлось"; return 1; }
    log_success "Лучший эндпоинт: ${_ep}"
    echo -e "  ${DIM}Закрепить: mtproxyl warp endpoint ${_ep}${NC}"
    echo ""
}

handle_warp_command() {
    case "${1:-status}" in
        status|"")
            if [ "${2:-}" = "--json" ]; then warp_status_json; else warp_status; fi ;;
        on|enable)   warp_enable "${2:-}" ;;
        off|disable) warp_disable ;;
        install)     check_root; warp_install_binary ;;
        remove|uninstall) warp_remove ;;
        reapply)     warp_reapply ;;
        scan)        warp_scan_show ;;
        location)    warp_set_location "${2:-}" ;;
        endpoint)    warp_set_endpoint "${2:-}" ;;
        proto)       warp_set_proto "${2:-}" ;;
        cidr)        check_root; warp_update_cidr ;;
        hint)        _warp_upstream_manual_hint ;;
        *)
            echo -e "  ${BOLD}Маршрут до Telegram через WARP:${NC}"
            echo -e "    ${GREEN}warp status${NC} [--json]  Состояние, выход, службы"
            echo -e "    ${GREEN}warp on${NC} <вариант>     socks (A), iface (B) или upstream (C)"
            echo -e "    ${GREEN}warp off${NC}              Выключить, вернуть прямой ход"
            echo -e "    ${GREEN}warp scan${NC}             Разведка: найти лучший эндпоинт"
            echo -e "    ${GREEN}warp location${NC} <A>     Страны (DE,NL) или узлы (FRA,AMS), clear — авто"
            echo -e "    ${GREEN}warp endpoint${NC} <A>     Закрепить адрес, clear — выбирать разведкой"
            echo -e "    ${GREEN}warp proto${NC} <P>        awg (по умолчанию), wg, masque"
            echo -e "    ${GREEN}warp hint${NC}             Что дописать в конфиг чужой цели для варианта C"
            echo -e "    ${GREEN}warp reapply${NC}          Переприменить правила и список подсетей"
            echo -e "    ${GREEN}warp remove${NC}           Удалить warpscout и его службы"
            ;;
    esac
}
