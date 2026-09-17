#!/bin/bash
# MTProxyL — маршрут до Telegram через Cloudflare WARP (warpscout).
# Вариант A — SOCKS5 + redsocks, вариант B — интерфейс WireGuard.

WARPSCOUT_VERSION="0.16.0"
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
WARP_WATCH_UNIT="mtproxyl-warp-watch"
_warp_unit_dir() { echo /etc/systemd/system; }

_warp_valid_endpoint() {
    local _host="${1%:*}" _port="${1##*:}"
    _host="${_host#[}"; _host="${_host%]}"
    [[ "$_port" =~ ^[0-9]{1,5}$ ]] || return 1
    [ "$((10#$_port))" -ge 1 ] && [ "$((10#$_port))" -le 65535 ] || return 1
    if [[ "$_host" == *:* ]]; then
        [[ "$1" == \[*\]:* ]] || return 1
        if [[ "$_host" == *.* ]]; then
            validate_ip_literal "${_host##*:}" || return 1
            _host="${_host%:*}:0:0"
        fi
        [[ "$_host" =~ ^[0-9a-fA-F:]+$ ]] || return 1
        local _groups=0 _part
        [[ "$_host" != *:::* ]] || return 1
        [[ "$_host" != :* || "$_host" == ::* ]] || return 1
        [[ "$_host" != *: || "$_host" == *:: ]] || return 1
        local IFS=:
        for _part in $_host; do
            [ "${#_part}" -le 4 ] || return 1
            [ -z "$_part" ] || _groups=$((_groups + 1))
        done
        if [[ "$_host" == *::* ]]; then
            local _tail="${_host#*::}"
            [[ "$_tail" != *::* ]] && [ "$_groups" -le 7 ] || return 1
        else
            [ "$_groups" -eq 8 ] || return 1
        fi
    else
        [[ "$1" != \[* ]] || return 1
        validate_ip_literal "$_host"
    fi
}

_warp_write_state() {
    local _tmp; _tmp=$(mktemp "$(_warp_dir)/state.XXXXXX") || return 1
    jq -nc --arg endpoint "$1" --arg proto "$(_warp_proto)" --arg mode "$(_warp_mode)" \
        --arg location "${WARP_LOCATION:-}" --arg pin "${WARP_ENDPOINT:-}" \
        --argjson ts "$(date +%s)" '{endpoint:$endpoint,proto:$proto,mode:$mode,location:$location,pin:$pin,picked_at:$ts}' > "$_tmp" \
        && chmod 600 "$_tmp" && mv "$_tmp" "$(_warp_state)"
}

_warp_dir()      { echo "${INSTALL_DIR:-/opt/mtproxyl}/warp"; }
_warp_bin()      { echo "$(_warp_dir)/warpscout"; }
_warp_account()  { echo "$(_warp_dir)/account.json"; }
_warp_state()    { echo "$(_warp_dir)/state.json"; }
_warp_active_endpoint() { jq -r '.endpoint // ""' "$(_warp_state)" 2>/dev/null; }
_warp_cidr()     { echo "$(_warp_dir)/telegram-cidr.txt"; }
_warp_conf()     { echo "$(_warp_dir)/${WARP_IFACE}.conf"; }
_warp_redsocks_conf() { echo "$(_warp_dir)/redsocks.conf"; }
_warp_nft_script()    { echo "$(_warp_dir)/nft.sh"; }
_warp_runner()        { echo "$(_warp_dir)/run-socks.sh"; }

_warp_has_artifacts() {
    [ -d "$(_warp_dir)" ] && return 0
    local _unit
    for _unit in "$WARP_WATCH_UNIT.timer" "$WARP_WATCH_UNIT.service" \
        "$WARP_SOCKS_UNIT" "$WARP_REDSOCKS_UNIT" "$WARP_IFACE_UNIT" "$WARP_ROUTE_UNIT"; do
        [ -e "$(_warp_unit_dir)/$_unit" ] && return 0
    done
    return 1
}

_warp_fwmark() {
    local _v="${WARP_FWMARK:-$WARP_FWMARK_DEFAULT}"
    [[ "$_v" =~ ^0x[0-9a-fA-F]{1,8}$ ]] || _v="$WARP_FWMARK_DEFAULT"
    echo "$_v"
}

_warp_variant_letter() {
    case "$(_warp_mode)" in iface) echo "B" ;; upstream) echo "C" ;; *) echo "A" ;; esac
}

_warp_mode()  { case "${WARP_MODE:-socks}" in iface) echo "iface" ;; upstream) echo "upstream" ;; *) echo "socks" ;; esac; }
_warp_configured_proto() {
    case "${WARP_PROTO:-awg}" in wg|masque|masque-h2) echo "${WARP_PROTO}" ;; *) echo "awg" ;; esac
}
_warp_proto() {
    # У интерфейса выбора нет: awg и masque живут только в туннеле warpscout.
    [ "$(_warp_mode)" = "iface" ] && { echo "wg"; return; }
    _warp_configured_proto
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
    local _b="${1:-$(_warp_bin)}"
    [ -x "$_b" ] || return 1
    local _help; _help=$("$_b" scan -h 2>&1; "$_b" socks -h 2>&1)
    local _flag
    for _flag in best conf endpoint country node plain tun-ping port table-off no-dns; do
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

    local _tmp _i _extract _ok="false"
    _tmp=$(mktemp -d /tmp/warpscout.XXXXXX) || { log_error "Не удалось создать временный каталог"; return 1; }
    for _i in "${!_sources[@]}"; do
        _extract="${_tmp}/source-${_i}"
        mkdir -p "$_extract" || continue
        log_info "Скачиваем warpscout ${WARPSCOUT_VERSION} из ${_names[$_i]}..."
        if ! curl -fsSL --max-time 180 "${_sources[$_i]}" -o "${_tmp}/ws.tar.gz" 2>/dev/null; then
            log_warn "Источник недоступен: ${_sources[$_i]}"
            continue
        fi
        if ! tar xzf "${_tmp}/ws.tar.gz" -C "$_extract" 2>/dev/null; then
            log_warn "Архив не распаковался"
            continue
        fi
        local _found; _found=$(find "$_extract" -type f -name warpscout | head -1)
        [ -n "$_found" ] || { log_warn "В архиве нет warpscout"; continue; }
        chmod 700 "$_found"
        if ! _warp_bin_usable "$_found" || [ "$("$_found" version 2>/dev/null | head -1)" != "$WARPSCOUT_VERSION" ]; then
            log_warn "Скачанный warpscout не понимает нужные ключи — пробуем следующий источник"
            continue
        fi
        install -m 700 "$_found" "${_dir}/warpscout.new" || continue
        mv -f "${_dir}/warpscout.new" "$(_warp_bin)" || continue
        _ok="true"
        break
    done
    rm -rf "$_tmp"

    [ "$_ok" = "true" ] || { log_error "Не удалось поставить warpscout"; return 1; }
    log_success "warpscout $(_warp_bin_version) установлен: $(_warp_bin)"
}

# Бесплатная учётка Cloudflare — без неё warpscout не работает.
_warp_ensure_account() {
    if [ -e "$(_warp_account)" ]; then
        if jq -e 'type=="object" and (.private_key | type=="string" and length>0)' "$(_warp_account)" >/dev/null 2>&1; then
            return 0
        fi
        log_error "Учётная запись WARP повреждена. Восстановите account.json из бэкапа"
        return 1
    fi
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
    local _raw="${1-${WARP_LOCATION:-}}"
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
    local -a _a=(-a "$(_warp_account)" -p "$(_warp_proto)" -plain -tun-ping)
    local _line
    # MASQUE uses two fixed anycast endpoints. warpscout deliberately rejects
    # -node/-country for it because every candidate exits through one colo.
    case "$(_warp_proto)" in
        masque|masque-h2) ;;
        *) while IFS= read -r _line; do [ -n "$_line" ] && _a+=("$_line"); done < <(_warp_location_args) ;;
    esac
    printf '%s\n' "${_a[@]}"
}

_warp_scan_filter() {
    case "$(_warp_proto)" in masque|masque-h2) echo "" ;; *) echo "${WARP_LOCATION:-}" ;; esac
}

# Лучший эндпоинт на stdout; прогресс warpscout уходит в stderr.
warp_scan_best() {
    local _target="${1:-}"
    local -a _args=()
    local _line
    while IFS= read -r _line; do _args+=("$_line"); done < <(_warp_scan_args)
    _args+=(-best)
    [ -n "$_target" ] && _args+=(-target "$_target")
    [ -n "${2:-}" ] && _args+=(-port "$2")

    local _out
    local _timeout=420; [ -n "$_target" ] && _timeout=45
    _out=$(timeout --foreground -k 5 "$_timeout" "$(_warp_bin)" scan "${_args[@]}") || return 1
    _out=$(tail -1 <<< "$_out" | tr -d '\r')
    _warp_valid_endpoint "$_out" || return 1
    echo "$_out"
}

_warp_scan_file() { echo "$(_warp_dir)/last-scan.json"; }

# Читаем все рабочие адреса; старые отчёты могут содержать только сводку узлов.
_warp_report_to_json() {
    LC_ALL=C awk '
        function trim(v) { gsub(/^[ \t]+|[ \t]+$/, "", v); return v }
        function field(start, stop) {
            if (!start) return ""
            return trim(substr($0, start + shift, stop ? stop-start : length($0)))
        }
        /^#.*torn down/ { section=0; torn=1; next }
        /^# Best endpoint per node/ { section=full ? 0 : 2; next }
        /^ENDPOINT[ \t]/ && !torn { full=1; section=1; header=0 }
        (section==1 && /^ENDPOINT[ \t]/) || (section==2 && /^NODE/) {
            ep=index($0,"ENDPOINT"); ping=index($0,"ENDPOINT PING")
            tun=index($0,"TUN PING"); loss=index($0,"LOSS")
            speed=index($0,"SPEED"); region=index($0,"SEEN AS")
            nodecol=index($0,"NODE")
            place=index($0,"NODE LOCATION"); header=1; next
        }
        section && header {
            if ($0 ~ /^[ \t]*$/ || $0 ~ /^#/) {section=0; next}
            if (!ep || !ping || !region || !place) exit 2
            endpoint=section==1 ? $1 : $2
            if (endpoint !~ /:[0-9]+$/) exit 2
            shift=length(endpoint)-(ping-ep-1); if (shift<0) shift=0
            node=section==1 ? field(nodecol,place) : $1
            print node "\t" endpoint "\t" field(ping,tun ? tun : (speed ? speed : region)) "\t" field(region,section==1 ? nodecol : place) "\t" field(place,0) "\t" field(tun,loss) "\t" field(loss,speed ? speed : region)
        }
    ' "$1" | jq -Rsc --arg proto "$(_warp_proto)" --arg filter "$(_warp_scan_filter)" --argjson ts "$(date +%s)" '
        split("\n") | map(select(length>0) | split("\t") |
        {node:.[0],endpoint:.[1],ping:.[2],region:.[3],location:.[4],tunnel_ping:.[5],loss:.[6]}) |
        reduce .[] as $r ({seen:{},rows:[]}; if .seen[$r.endpoint] then . else .seen[$r.endpoint]=true | .rows+=[$r] end) | .rows |
        {scanned_at:$ts,proto:$proto,filter:$filter,nodes:.,status:(if length>0 then "success" else "empty" end),best_endpoint:(.[0].endpoint // "")}'
}

# Сохраняем полный список рабочих адресов для TUI и панели.
warp_scan_collect() (
    set -o pipefail
    umask 077
    mkdir -p "$(_warp_dir)" || return 1
    local -a _args=()
    local _line
    while IFS= read -r _line; do _args+=("$_line"); done < <(_warp_scan_args)
    local _report _json _rc=0
    _report=$(mktemp "$(_warp_dir)/report.XXXXXX") || return 1
    _json=$(mktemp "$(_warp_dir)/scan.XXXXXX") || return 1
    trap 'rm -f "$_report" "$_json"' EXIT
    trap 'jq -nc "{scanned_at:0,status:\"error\",error:\"Разведка прервана\",nodes:[]}" > "$_json"; mv "$_json" "$(_warp_scan_file)"; exit 143' TERM INT HUP
    jq -nc --argjson pid "$BASHPID" '{scanned_at:0,status:"running",pid:$pid,nodes:[]}' > "$_json"
    mv "$_json" "$(_warp_scan_file)"
    timeout --foreground -k 5 420 "$(_warp_bin)" scan "${_args[@]}" -o "$_report" > "$(_warp_dir)/last-scan.log" 2>&1 || _rc=$?
    if [ "$_rc" -ne 0 ] || ! _warp_report_to_json "$_report" > "$_json"; then
        jq -nc --argjson ts "$(date +%s)" --arg error "Разведка завершилась с ошибкой (код $_rc); см. журнал операции" \
            '{scanned_at:$ts,status:"error",error:$error,nodes:[]}' > "$_json"
        tail -30 "$(_warp_dir)/last-scan.log" >&2
        mv "$_json" "$(_warp_scan_file)"
        return 1
    fi
    mv "$_json" "$(_warp_scan_file)"
    jq -e '.nodes | length>0' "$(_warp_scan_file)" >/dev/null
)

warp_scan_json() {
    local _f; _f=$(_warp_scan_file)
    local _pid
    _pid=$(jq -r 'select(.status=="running") | .pid // 0' "$_f" 2>/dev/null)
    if [[ "$_pid" =~ ^[0-9]+$ ]] && [ "$_pid" -gt 0 ] && ! kill -0 "$_pid" 2>/dev/null; then
        jq -c '.status="error" | .error="Разведка прервана; запустите повторно"' "$_f"
        return
    fi
    if [ -s "$_f" ]; then cat "$_f"; else echo '{"scanned_at":0,"nodes":[]}'; fi
}

# Таблица узлов из последней разведки — то, что вводится в «Локацию».
warp_scan_print() {
    local _f; _f=$(_warp_scan_file)
    [ -s "$_f" ] || { log_info "Разведки ещё не было: mtproxyl warp scan"; return 1; }
    local _rows
    _rows=$(tr '{' '\n' < "$_f" | awk -F'"' '
        /"node":/ {
            node = ""; ep = ""; ping = ""; region = ""; place = ""
            for (i = 1; i < NF; i++) {
                if ($i == "node")     node = $(i + 2)
                if ($i == "endpoint") ep = $(i + 2)
                if ($i == "ping")     ping = $(i + 2)
                if ($i == "region")   region = $(i + 2)
                if ($i == "location") place = $(i + 2)
            }
            if (node != "") printf "  %-6s %-22s %-9s %-6s %s\n", node, ep, ping, region, place
        }')
    [ -n "$_rows" ] || { log_warn "В последней разведке живых узлов нет"; return 1; }
    echo ""
    echo -e "  ${BOLD}Живые узлы последней разведки${NC}"
    echo -e "  ${DIM}Узел   Эндпоинт               Пинг      Выход  Локация${NC}"
    printf '%s\n' "$_rows"
    echo ""
    echo -e "  ${DIM}Локация задаётся кодом узла (FRA) или страны (DE): mtproxyl warp location DE${NC}"
}

# Выбор из успешной разведки уже проверен настоящим туннелем. Повторно гонять
# warpscout scan перед A/B/C не нужно; жизнеспособность подтвердит запуск службы.
_warp_cached_endpoint() {
    local _f; _f=$(_warp_scan_file)
    [ -s "$_f" ] || return 1
    local _cached_proto _wanted_proto
    _cached_proto=$(jq -r '.proto // ""' "$_f" 2>/dev/null) || return 1
    _wanted_proto=$(_warp_proto)
    case "${_wanted_proto}:${_cached_proto}" in
        wg:wg|wg:awg|awg:wg|awg:awg|masque:masque|masque-h2:masque-h2) ;;
        *) return 1 ;;
    esac
    jq -er --arg pin "${WARP_ENDPOINT:-}" --arg location "${WARP_LOCATION:-}" '
        select(.status == "success" and (.nodes | type == "array" and length > 0)) |
        if $pin != "" then
            [.nodes[] | select(.endpoint == $pin)][0].endpoint // empty
        elif $location != "" then
            ($location | split(",") | map(gsub("[[:space:]]"; "") | ascii_upcase)) as $wanted |
            [.nodes[] |
                (.node // "" | ascii_upcase) as $node |
                (.region // "" | ascii_upcase) as $region |
                select(($wanted | index($node)) != null or ($wanted | index($region)) != null)
            ][0].endpoint // empty
        else empty end
    ' "$_f" 2>/dev/null
}

# Закреплённый адрес без результата разведки проверяем точечно; для нового
# узла или автовыбора запускаем обычную разведку.
warp_resolve_endpoint() {
    local _pin="${WARP_ENDPOINT:-}"
    local _cached=""
    _cached=$(_warp_cached_endpoint) || _cached=""
    if [ -n "$_cached" ]; then
        log_info "Используем выбор из последней разведки без повторного поиска: ${_cached}" >&2
        echo "$_cached"
        return 0
    fi
    if [ -n "$_pin" ]; then
        log_info "Проверяем закреплённый эндпоинт WARP: ${_pin}" >&2
        local _host="${_pin%:*}"; _host="${_host#[}"; _host="${_host%]}"
        if warp_scan_best "$_host" "${_pin##*:}" >/dev/null; then
            echo "$_pin"
            return 0
        fi
        log_warn "Закреплённый эндпоинт ${_pin} не отвечает — ищем новый" >&2
    fi
    log_info "Ищем живой эндпоинт WARP (${WARP_LOCATION:-лучший по задержке}, протокол $(_warp_proto))..." >&2
    log_info "Разведка идёт несколько минут — она поднимает туннель к каждому кандидату" >&2
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
    {
        echo '#!/bin/bash'
        printf 'BIN=%q\nACCOUNT=%q\nSTATE=%q\nPORT=%q\nLISTEN=%q\n' \
            "$(_warp_bin)" "$(_warp_account)" "$(_warp_state)" "$(_warp_socks_port)" "$(_warp_socks_listen)"
        cat <<'RUNNER'
set -eu
EP=$(jq -er '.endpoint' "$STATE")
PROTO=$(jq -er '.proto' "$STATE")
exec "$BIN" socks -a "$ACCOUNT" -e "$EP" -p "$PROTO" -l "$LISTEN" -port "$PORT"
RUNNER
    } > "$_runner"
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
    cat > "$(_warp_unit_dir)/${WARP_SOCKS_UNIT}" <<EOF
[Unit]
Description=MTProxyL WARP SOCKS5 (warpscout)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(_warp_runner)
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    cat > "$(_warp_unit_dir)/${WARP_REDSOCKS_UNIT}" <<EOF
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

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ── Служба варианта B: интерфейс WireGuard + policy routing ─────────────────

_warp_write_iface_units() {
    cat > "$(_warp_unit_dir)/${WARP_IFACE_UNIT}" <<EOF
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
    cat > "$(_warp_unit_dir)/${WARP_ROUTE_UNIT}" <<EOF
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
    _warp_valid_endpoint "$_ep" || return 1
    log_info "Готовим конфиг WireGuard для выбранного эндпоинта ${_ep}..."
    local _private _public _address _tmp
    _private=$(jq -er '.private_key | select(type == "string" and length > 0)' "$(_warp_account)" 2>/dev/null) || return 1
    _public=$(jq -er '.peer_public_key | select(type == "string" and length > 0)' "$(_warp_account)" 2>/dev/null) || return 1
    _address=$(jq -er '.ipv4 | select(type == "string" and length > 0)' "$(_warp_account)" 2>/dev/null) || return 1
    [[ "$_private" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
        && [[ "$_public" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
        && validate_ip_literal "$_address" || {
            log_error "В account.json нет корректных данных WireGuard"
            return 1
        }
    _tmp=$(mktemp "$(_warp_dir)/iface.XXXXXX") || return 1
    if ! cat > "$_tmp" <<EOF
[Interface]
Address = ${_address}/32
PrivateKey = ${_private}
MTU = $(_warp_mtu)
Table = off

[Peer]
PublicKey = ${_public}
Endpoint = ${_ep}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    then
        rm -f "$_tmp"
        return 1
    fi
    mv "$_tmp" "$(_warp_conf)" || return 1
    chmod 600 "$(_warp_conf)"
    return 0
}

# ── Зависимости ─────────────────────────────────────────────────────────────

_warp_need_packages() {
    _warp_scan_dependencies || return 1
    local -a _need=()
    command -v jq >/dev/null || _need+=("jq")
    if [ "$(_warp_mode)" = "socks" ]; then
        command -v redsocks &>/dev/null || [ -x /usr/sbin/redsocks ] || _need+=("redsocks")
    elif [ "$(_warp_mode)" = "iface" ]; then
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
    elif [ "$(_warp_mode)" = "iface" ]; then
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

# В вариантах A и C шифрует warpscout, а не ядро, и его цена видна только
# по счётчику службы. Пустой вывод — служба не запускалась.
_warp_tunnel_cpu() {
    local _ns _ts _start _now _up _cpu
    _ns=$(systemctl show -p CPUUsageNSec --value "$WARP_SOCKS_UNIT" 2>/dev/null)
    [[ "$_ns" =~ ^[0-9]+$ ]] && [ "$_ns" -gt 0 ] || return 1
    _ts=$(systemctl show -p ActiveEnterTimestamp --value "$WARP_SOCKS_UNIT" 2>/dev/null)
    [ -n "$_ts" ] || return 1
    _start=$(date -d "$_ts" +%s 2>/dev/null) || return 1
    _now=$(date +%s); _up=$((_now - _start))
    [ "$_up" -gt 0 ] || return 1
    _cpu=$((_ns / 1000000000))
    printf '%dс за %dч%02dм, в среднем %d%% ядра' \
        "$_cpu" $((_up / 3600)) $(((_up % 3600) / 60)) $((_cpu * 100 / _up))
}

# `mtproxyl dc` показывает писателей middle proxy. Вариант C его выключает,
# и советовать эту команду после включения — отправлять смотреть в пустоту.
_warp_dc_hint() {
    if _warp_me_enabled; then
        echo -e "  ${DIM}Связь с дата-центрами Telegram: mtproxyl dc${NC}"
    else
        echo -e "  ${DIM}Middle proxy выключен — писателей к DC нет, mtproxyl dc покажет пусто.${NC}"
        echo -e "  ${DIM}Выход наружу: mtproxyl warp status, доступность: mtproxyl availability${NC}"
    fi
}

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
        if [ "${WARP_ALLOW_DISABLE_ME:-false}" != "true" ]; then
            log_error "Нужно явное согласие на отключение middle proxy"
            log_info "CLI: добавьте --allow-disable-me; в панели отметьте согласие"
            return 1
        fi
    else
        local _yn; read_line _yn "  ${BOLD}Выключить middle proxy и продолжить? [y/N]:${NC} "
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Ничего не меняем — WARP не включён"; return 1; }
    fi

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
        if [ "${MTPROXYL_ASSUME_YES:-}" = "1" ]; then
            if [ "${WARP_ALLOW_DISABLE_DEFAULT_UPSTREAMS:-false}" != "true" ]; then
                log_error "Нужно явное согласие на временное отключение маршрутов: ${_others}"
                log_info "CLI: добавьте --allow-disable-default-upstreams; в панели отметьте согласие"
                return 1
            fi
        else
            local _yn; read_line _yn "  ${BOLD}Выключить их на время работы WARP? [Y/n]:${NC} "
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
        upstream_toggle "$_name" disable >/dev/null 2>&1 || { UPSTREAM_DEFER_RESTART=false; return 1; }
        case ",${WARP_DISABLED_UPSTREAMS:-}," in
            *",${_name},"*) ;;
            *) WARP_DISABLED_UPSTREAMS+="${WARP_DISABLED_UPSTREAMS:+,}${_name}" ;;
        esac
    done

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

_warp_stop_runtime() {
    systemctl disable --now "$WARP_WATCH_UNIT.timer" "$WARP_REDSOCKS_UNIT" "$WARP_ROUTE_UNIT" \
        "$WARP_IFACE_UNIT" "$WARP_SOCKS_UNIT" >/dev/null 2>&1 || true
    systemctl stop "$WARP_WATCH_UNIT.service" >/dev/null 2>&1 || true
    _warp_nft_remove
    ip rule del fwmark "$(_warp_fwmark)/$(_warp_fwmark)" lookup "$WARP_RT_TABLE" 2>/dev/null || true
    ip -6 rule del fwmark "$(_warp_fwmark)/$(_warp_fwmark)" lookup "$WARP_RT_TABLE" 2>/dev/null || true
    ip route flush table "$WARP_RT_TABLE" 2>/dev/null || true
    ip -6 route flush table "$WARP_RT_TABLE" 2>/dev/null || true
}

_warp_tcp_port_busy() {
    ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
}

# После остановки наших служб занятый порт принадлежит другой программе.
# Подбираем соседнюю свободную пару и сохраняем её вместе с режимом WARP.
_warp_select_runtime_ports() {
    [ "$(_warp_mode)" != iface ] || return 0
    local _socks; _socks=$(_warp_socks_port)
    local _redir; _redir=$(_warp_redir_port)
    if ! _warp_tcp_port_busy "$_socks" \
       && { [ "$(_warp_mode)" != socks ] || { [ "$_socks" != "$_redir" ] && ! _warp_tcp_port_busy "$_redir"; }; }; then
        return 0
    fi

    local _candidate
    for ((_candidate=41080; _candidate<=41198; _candidate+=2)); do
        _warp_tcp_port_busy "$_candidate" && continue
        _warp_tcp_port_busy "$((_candidate + 1))" && continue
        WARP_SOCKS_PORT="$_candidate"
        WARP_REDIR_PORT="$((_candidate + 1))"
        log_warn "Порты ${_socks}/${_redir} заняты другой службой — WARP использует ${WARP_SOCKS_PORT}/${WARP_REDIR_PORT}"
        return 0
    done
    log_error "Не нашлось свободной пары TCP-портов для локального туннеля WARP (41080–41199)"
    return 1
}

_warp_wait_socks_listener() {
    local _i
    for _i in {1..30}; do
        if _warp_unit_active "$WARP_SOCKS_UNIT" && _warp_tcp_port_busy "$(_warp_socks_port)"; then
            return 0
        fi
        systemctl is-failed --quiet "$WARP_SOCKS_UNIT" 2>/dev/null && break
        sleep 1
    done
    log_error "Локальный туннель WARP не запустился на 127.0.0.1:$(_warp_socks_port)"
    log_info "Смотрите: journalctl -u ${WARP_SOCKS_UNIT}"
    return 1
}

warp_enable() (
    local WARP_ALLOW_DISABLE_ME=false WARP_ALLOW_DISABLE_DEFAULT_UPSTREAMS=false _arg
    local _requested_mode="${1:-}"; shift 2>/dev/null || true
    for _arg in "$@"; do
        case "$_arg" in
            --allow-disable-me) WARP_ALLOW_DISABLE_ME=true ;;
            --allow-disable-default-upstreams) WARP_ALLOW_DISABLE_DEFAULT_UPSTREAMS=true ;;
            *) log_error "Неизвестный параметр включения WARP: $_arg"; return 1 ;;
        esac
    done
    local _before _file _ok=false _WARP_PREVIOUS_MODE="$(_warp_mode)" _WARP_PREVIOUS_ENABLED="${WARP_ENABLED:-false}"
    _before=$(mktemp -d "$INSTALL_DIR/warp-transition.XXXXXX") || return 1
    local -a _files=(settings.conf upstreams.conf expert.conf warp/state.json "warp/$WARP_IFACE.conf")
    mkdir -p "$_before/warp"
    for _file in "${_files[@]}"; do
        [ ! -f "$INSTALL_DIR/$_file" ] || cp -p "$INSTALL_DIR/$_file" "$_before/$_file" || return 1
    done
    _warp_transition_cleanup() {
        if [ "$_ok" != true ]; then
            if [ "${_WARP_RUNTIME_CHANGED:-false}" = true ]; then _warp_stop_runtime; fi
            for _file in "${_files[@]}"; do
                if [ -f "$_before/$_file" ]; then
                    cp -p "$_before/$_file" "$INSTALL_DIR/$_file"
                else
                    rm -f "$INSTALL_DIR/$_file"
                fi
            done
            load_settings; load_secrets; load_upstreams
            if [ "${_WARP_RUNTIME_CHANGED:-false}" = true ]; then
                if _warp_owns_engine_config; then
                    generate_telemt_config >/dev/null 2>&1 || true
                    if is_proxy_running; then reload_proxy_config >/dev/null 2>&1 || true; fi
                fi
                if [ "$_WARP_PREVIOUS_ENABLED" = true ]; then
                    _warp_start_services >/dev/null 2>&1 || log_warn "Прежний туннель требует восстановления"
                    warp_install_watchdog >/dev/null 2>&1 || true
                fi
            fi
            log_error "Включение WARP отменено, прежние настройки восстановлены"
        fi
        rm -rf "$_before"
    }
    trap _warp_transition_cleanup EXIT
    _warp_enable "$_requested_mode" || return 1
    _ok=true
)

_warp_enable() {
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

    local _ep; _ep=$(warp_resolve_endpoint) || {
        log_error "Живого эндпоинта WARP не нашлось"
        log_info "Если задана локация, попробуйте убрать её: mtproxyl warp location clear"
        return 1
    }
    _WARP_RUNTIME_CHANGED=true
    _warp_stop_runtime
    _warp_select_runtime_ports || return 1
    if [ "${_WARP_PREVIOUS_MODE:-}" = upstream ] && [ "$(_warp_mode)" != upstream ] && _warp_owns_engine_config; then
        _warp_drop_upstream
        _WARP_CONFIG_DIRTY=true
    fi
    _warp_write_state "$_ep" || return 1
    log_success "Эндпоинт: ${_ep}"

    # Вариант C правил не ставит; исключение — закрытый снаружи порт socks,
    # когда его пришлось открыть на все адреса ради цели в docker bridge.
    if [ "$(_warp_mode)" != "upstream" ] || [ "$(_warp_socks_listen)" != "127.0.0.1" ]; then
        _warp_generate_nft
    fi

    if [ "$(_warp_mode)" != "iface" ]; then
        _warp_write_socks_runner
        _warp_write_socks_units
        systemctl enable "$WARP_SOCKS_UNIT" >/dev/null 2>&1
        systemctl restart "$WARP_SOCKS_UNIT" || return 1
        _warp_wait_socks_listener || return 1
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
        systemctl enable "$WARP_REDSOCKS_UNIT" >/dev/null 2>&1
        systemctl restart "$WARP_REDSOCKS_UNIT" || return 1
    else
        _warp_generate_iface_conf "$_ep" || return 1
        _warp_write_iface_units
        systemctl enable "$WARP_IFACE_UNIT" "$WARP_ROUTE_UNIT" >/dev/null || return 1
        systemctl restart "$WARP_IFACE_UNIT" && systemctl restart "$WARP_ROUTE_UNIT" || return 1
    fi

    WARP_ENABLED="true"
    save_settings
    warp_install_watchdog || return 1

    # Один перезапуск на все правки конфига: и выключенный ME, и маршруты.
    if [ "$_WARP_CONFIG_DIRTY" = "true" ]; then
        generate_telemt_config || return 1
        if is_proxy_running; then restart_proxy_container || return 1; fi
    fi

    if _warp_wait_route; then
        log_success "Трафик до Telegram идёт через WARP (вариант $(_warp_variant_letter))"
        if [ -n "${WARP_LOCATION:-}" ]; then
            local _exit _exit_ip _exit_loc _exit_colo
            _exit=$(warp_exit_info 2>/dev/null) || return 1
            IFS='|' read -r _exit_ip _exit_loc _exit_colo <<< "$_exit"
            if ! _warp_exit_matches_location "$_exit_loc" "$_exit_colo"; then
                log_error "Выбранная локация ${WARP_LOCATION}, но фактический выход: ${_exit_loc} (узел ${_exit_colo})"
                log_info "Эндпоинт сменил anycast-маршрут — запустите разведку выбранного узла ещё раз"
                return 1
            fi
            log_success "Выход подтверждён: ${_exit_loc}, узел ${_exit_colo}"
        fi
    else
        log_warn "Правила применены, но проверка маршрута не подтвердила выход через WARP"
        log_info "Смотрите: mtproxyl warp status, journalctl -u ${WARP_SOCKS_UNIT}"
        return 1
    fi
    echo ""
    _warp_dc_hint
}

warp_disable() {
    check_root
    systemctl disable --now "$WARP_WATCH_UNIT.timer" >/dev/null 2>&1 || true
    systemctl stop "$WARP_WATCH_UNIT.service" >/dev/null 2>&1 || true
    systemctl reset-failed "$WARP_WATCH_UNIT.service" >/dev/null 2>&1 || true
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
    systemctl disable --now "$WARP_WATCH_UNIT.timer" >/dev/null 2>&1 || true
    systemctl stop "$WARP_WATCH_UNIT.service" >/dev/null 2>&1 || true
    rm -f "$(_warp_unit_dir)/$WARP_WATCH_UNIT.timer" "$(_warp_unit_dir)/$WARP_WATCH_UNIT.service"
    rm -f "$(_warp_unit_dir)/${WARP_SOCKS_UNIT}" "$(_warp_unit_dir)/${WARP_REDSOCKS_UNIT}" \
          "$(_warp_unit_dir)/${WARP_IFACE_UNIT}" "$(_warp_unit_dir)/${WARP_ROUTE_UNIT}"
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
    local -a _route=()
    if [ "$(_warp_mode)" != "iface" ] && _warp_unit_active "$WARP_SOCKS_UNIT"; then
        _route=(-x "socks5h://127.0.0.1:$(_warp_socks_port)")
    elif [ "$(_warp_mode)" = "iface" ] && ip link show "$WARP_IFACE" >/dev/null 2>&1; then
        _route=(--proxy '' --interface "$WARP_IFACE")
    else
        return 1
    fi
    for _url in https://www.cloudflare.com/cdn-cgi/trace https://1.1.1.1/cdn-cgi/trace; do
        _out=$(curl -fsS --noproxy '' --max-time 5 "${_route[@]}" "$_url" 2>/dev/null)
        if grep -Eq '^warp=(on|plus)$' <<< "$_out"; then break; fi
        _out=""
    done
    [ -n "$_out" ] || return 1
    local _ip _loc _colo _warp
    _ip=$(grep -m1 '^ip=' <<< "$_out" | cut -d= -f2)
    _loc=$(grep -m1 '^loc=' <<< "$_out" | cut -d= -f2)
    _colo=$(grep -m1 '^colo=' <<< "$_out" | cut -d= -f2)
    _warp=$(grep -m1 '^warp=' <<< "$_out" | cut -d= -f2)
    [ "$_warp" = "on" ] || [ "$_warp" = "plus" ] || return 1
    echo "${_ip:-?}|${_loc:-?}|${_colo:-?}"
}

_warp_exit_matches_location() {
    case "$(_warp_proto)" in masque|masque-h2) return 0 ;; esac
    local _wanted="${WARP_LOCATION:-}" _loc="${1^^}" _colo="${2^^}" _tok
    [ -n "$_wanted" ] || return 0
    local _old="$IFS"; IFS=','
    local -a _tokens=(); read -ra _tokens <<< "$_wanted"
    IFS="$_old"
    for _tok in "${_tokens[@]}"; do
        _tok="${_tok//[[:space:]]/}"; _tok="${_tok^^}"
        if { [ "${#_tok}" -eq 2 ] && [ "$_tok" = "$_loc" ]; } \
           || { [ "${#_tok}" -eq 3 ] && [ "$_tok" = "$_colo" ]; }; then
            return 0
        fi
    done
    return 1
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
    local _exit _ip _loc _colo
    _exit=$(warp_exit_info 2>/dev/null) || return 1
    IFS='|' read -r _ip _loc _colo <<< "$_exit"
    _warp_exit_matches_location "$_loc" "$_colo"
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
    echo -e "  ${BOLD}Рабочий адрес:${NC} $(_warp_active_endpoint)"
    echo -e "  ${BOLD}Автовосстановление:${NC} ${WARP_WATCHDOG_ENABLED:-true}"
    if [ -s "$(_warp_health_file)" ]; then
        jq -r '"  Проверка: \(.checked_at | todateiso8601), ошибок подряд: \(.failures)", (if .last_recovery_at>0 then "  Восстановление: \(.last_recovery_at | todateiso8601)" else empty end), (if .error!="" then "  Ошибка: \(.error)" else empty end)' "$(_warp_health_file)"
    fi
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
        local _cpu; _cpu=$(_warp_tunnel_cpu) && \
            echo -e "  ${BOLD}Процессор:${NC}    ${_cpu} ${DIM}(шифрование в пользовательском пространстве)${NC}"
        if _warp_owns_engine_config; then
            local _rogue; _rogue=$(_warp_foreign_default_upstreams)
            [ -n "$_rogue" ] && log_warn "Маршруты без области мимо туннеля: ${_rogue}"
        else
            echo -e "  ${DIM}Конфиг цели правится вручную: mtproxyl warp hint${NC}"
        fi
        echo ""
        _warp_dc_hint
        echo ""
        return 0
    elif [ "$_mode" = "socks" ]; then
        echo -e "  ${BOLD}Туннель:${NC}      $(_warp_unit_active "$WARP_SOCKS_UNIT" && echo -e "${GREEN}работает${NC}" || echo -e "${RED}лежит${NC}") ${DIM}(${WARP_SOCKS_UNIT})${NC}"
        echo -e "  ${BOLD}Редирект:${NC}     $(_warp_unit_active "$WARP_REDSOCKS_UNIT" && echo -e "${GREEN}работает${NC}" || echo -e "${RED}лежит${NC}") ${DIM}(порт $(_warp_redir_port))${NC}"
        local _cpu; _cpu=$(_warp_tunnel_cpu) && \
            echo -e "  ${BOLD}Процессор:${NC}    ${_cpu} ${DIM}(шифрование в пользовательском пространстве)${NC}"
    else
        echo -e "  ${BOLD}Интерфейс:${NC}    $(ip link show "$WARP_IFACE" >/dev/null 2>&1 && echo -e "${GREEN}поднят${NC}" || echo -e "${RED}нет${NC}") ${DIM}(${WARP_IFACE}, метка $(_warp_fwmark))${NC}"
    fi
    echo -e "  ${BOLD}Правила nft:${NC}  $(_warp_nft_applied && echo -e "${GREEN}на месте${NC}" || echo -e "${RED}нет${NC}") ${DIM}(подсетей: $(wc -l 2>/dev/null < "$(_warp_cidr)" || echo 0))${NC}"
    echo -e "  ${BOLD}Уведено:${NC}      $(warp_matched_packets) пакетов до Telegram"
    echo ""
    _warp_dc_hint
    echo ""
}

warp_status_json() {
    local _health _active _active_proto
    _health=$(jq -c . "$(_warp_health_file)" 2>/dev/null) || _health='{}'
    _active=$(jq -r '.endpoint // ""' "$(_warp_state)" 2>/dev/null)
    _active_proto=$(jq -r '.proto // ""' "$(_warp_state)" 2>/dev/null)
    local _exit_ip="" _exit_loc="" _exit_colo=""
    local _exit; _exit=$(warp_exit_info 2>/dev/null) && IFS='|' read -r _exit_ip _exit_loc _exit_colo <<< "$_exit"

    local _tunnel="false" _redir="false" _iface="false"
    _warp_unit_active "$WARP_SOCKS_UNIT" && _tunnel="true"
    _warp_unit_active "$WARP_REDSOCKS_UNIT" && _redir="true"
    ip link show "$WARP_IFACE" >/dev/null 2>&1 && _iface="true"

    printf '{"watchdog_enabled":%s,"active_endpoint":"%s","active_proto":"%s","health":%s,' \
        "$([ "${WARP_WATCHDOG_ENABLED:-true}" = true ] && echo true || echo false)" \
        "$(json_escape "$_active")" "$(json_escape "$_active_proto")" "$_health"
    printf '"enabled":%s,"mode":"%s","proto":"%s","endpoint":"%s","location":"%s",' \
        "$([ "${WARP_ENABLED:-false}" = "true" ] && echo true || echo false)" \
        "$(_warp_mode)" "$(_warp_configured_proto)" \
        "$(json_escape "${WARP_ENDPOINT:-}")" "$(json_escape "${WARP_LOCATION:-}")"
    printf '"installed":%s,"version":"%s","socks_active":%s,"redirect_active":%s,"iface_active":%s,' \
        "$([ -x "$(_warp_bin)" ] && echo true || echo false)" \
        "$(json_escape "$(_warp_bin_version 2>/dev/null)")" \
        "$_tunnel" "$_redir" "$_iface"
    printf '"nft_applied":%s,"cidr_count":%s,"socks_port":%s,"redirect_port":%s,"matched_packets":%s,' \
        "$(_warp_nft_applied && echo true || echo false)" \
        "$(wc -l 2>/dev/null < "$(_warp_cidr)" || echo 0)" \
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
    # Разбираем то, что ввели, а не то, что уже сохранено.
    local _norm=""
    local _line
    while IFS= read -r _line; do _norm+="${_norm:+ }${_line}"; done < <(_warp_location_args "$_v")
    [ -n "$_norm" ] || { log_error "Локация: коды стран (DE,NL) или узлов Cloudflare (FRA,AMS)"; return 1; }
    WARP_LOCATION="$_v"
    save_settings
    log_success "Локация: ${_v} (${_norm})"
    log_info "Для смены действующего туннеля: mtproxyl warp apply"
}

warp_set_endpoint() {
    check_root
    local _v="${1:-}"
    case "$_v" in
        clear|auto|"") WARP_ENDPOINT=""; save_settings; log_success "Эндпоинт выбирается разведкой"; return 0 ;;
    esac
    _warp_valid_endpoint "$_v" || { log_error "Эндпоинт: IPv4:порт или [IPv6]:порт (1–65535)"; return 1; }
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
    _warp_scan_dependencies || return 1
    warp_install_binary || return 1
    command -v jq >/dev/null || { log_error "Для разведки нужен jq"; return 1; }
    _warp_ensure_account || return 1
    echo ""
    log_info "Разведка эндпоинтов WARP (${WARP_LOCATION:-лучший по задержке}, $(_warp_proto))"
    case "$(_warp_proto)" in
        masque|masque-h2)
            [ -z "${WARP_LOCATION:-}" ] || log_warn "У MASQUE фиксированные anycast-адреса: фильтр ${WARP_LOCATION} к разведке не применяется"
            ;;
    esac
    log_info "Это несколько минут: к каждому кандидату поднимается настоящий туннель"
    if warp_scan_collect; then
        warp_scan_print
    else
        log_error "Разведка не нашла рабочих узлов или завершилась с ошибкой"
        return 1
    fi
    local _ep; _ep=$(jq -r '.best_endpoint // empty' "$(_warp_scan_file)")
    log_success "Лучший эндпоинт: ${_ep}"
    echo -e "  ${DIM}Закрепить: mtproxyl warp endpoint ${_ep}${NC}"
    echo ""
}

_warp_scan_dependencies() {
    command -v jq >/dev/null && command -v timeout >/dev/null && return 0
    case "$(detect_os)" in
        debian) apt-get update -qq && apt-get install -y -qq jq coreutils ;;
        rhel) yum install -y -q jq coreutils ;;
        alpine) apk add --no-cache jq coreutils ;;
        *) log_error "Установите jq и coreutils"; return 1 ;;
    esac
    command -v jq >/dev/null && command -v timeout >/dev/null
}

warp_set_settings() {
    local _proto="${1:-keep}" _location="${2:-keep}" _ep="${3:-keep}"
    case "$_proto" in keep|awg|wg|masque|masque-h2) ;; *) log_error "Неверный протокол WARP"; return 1 ;; esac
    if [ "$_location" != keep ] && [ "$_location" != clear ]; then
        [[ "$_location" =~ ^[A-Za-z]{2,3}(,[A-Za-z]{2,3})*$ ]] || { log_error "Неверная локация WARP"; return 1; }
    fi
    if [ "$_ep" != keep ] && [ "$_ep" != clear ]; then
        _warp_valid_endpoint "$_ep" || { log_error "Неверный endpoint WARP"; return 1; }
    fi
    [ "$_proto" = keep ] || WARP_PROTO="$_proto"
    [ "$_location" = keep ] || WARP_LOCATION="${_location^^}"
    [ "$_location" != clear ] || WARP_LOCATION=""
    [ "$_ep" = keep ] || WARP_ENDPOINT="$_ep"
    [ "$_ep" != clear ] || WARP_ENDPOINT=""
    save_settings || return 1
    log_success "Выбор сохранён. Для смены действующего туннеля: mtproxyl warp apply"
}

warp_install_watchdog() {
    if [ "${WARP_ENABLED:-false}" != true ] || [ "${WARP_WATCHDOG_ENABLED:-true}" != true ]; then
        systemctl disable --now "$WARP_WATCH_UNIT.timer" >/dev/null 2>&1 || true
        systemctl stop "$WARP_WATCH_UNIT.service" >/dev/null 2>&1 || true
        systemctl reset-failed "$WARP_WATCH_UNIT.service" >/dev/null 2>&1 || true
        return 0
    fi
    cat > "$(_warp_unit_dir)/$WARP_WATCH_UNIT.service" <<EOF
[Unit]
Description=MTProxyL WARP health and recovery
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/mtproxyl.sh warp watch
TimeoutStartSec=15min
KillMode=control-group
UMask=0077
EOF
    cat > "$(_warp_unit_dir)/$WARP_WATCH_UNIT.timer" <<EOF
[Unit]
Description=MTProxyL WARP health timer

[Timer]
OnBootSec=60s
OnUnitInactiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload || return 1
    systemctl reset-failed "$WARP_WATCH_UNIT.service" >/dev/null 2>&1 || true
    systemctl enable --now "$WARP_WATCH_UNIT.timer"
}

warp_refresh() {
    if [ "${WARP_ENABLED:-false}" != true ]; then
        # Обновление или чистая установка не должны оживить оставшийся timer.
        warp_install_watchdog
        return 0
    fi
    _warp_scan_dependencies && warp_install_binary || return 1
    local _ep _proto
    _ep=$(jq -r '.endpoint // empty' "$(_warp_state)" 2>/dev/null)
    [ -n "$_ep" ] || _ep="${WARP_ENDPOINT:-}"
    _warp_valid_endpoint "$_ep" || { log_error "Нет сохранённого endpoint: mtproxyl warp apply"; return 1; }
    if ! jq -e '.mode and has("location") and has("pin")' "$(_warp_state)" >/dev/null 2>&1; then
        _proto=$(jq -r '.proto // empty' "$(_warp_state)" 2>/dev/null)
        local WARP_PROTO="${_proto:-${WARP_PROTO:-awg}}"
        _warp_write_state "$_ep" || return 1
    fi
    if [ "$(_warp_mode)" = iface ]; then
        _warp_write_iface_units
    else
        _warp_write_socks_runner && _warp_write_socks_units || return 1
    fi
    warp_install_watchdog || return 1
    log_info "Службы WARP обновлены. Новый бинарник используется после восстановления или применения выбора"
}

_warp_health_file() { echo "$(_warp_dir)/health.json"; }

_warp_health_save() {
    local _tmp; _tmp=$(mktemp "$(_warp_dir)/health.XXXXXX") || return 1
    jq -nc --argjson checked_at "$(date +%s)" --argjson failures "$1" \
        --argjson last_recovery_at "$2" --arg result "$3" --arg error "${4:-}" \
        '{checked_at:$checked_at,failures:$failures,last_recovery_at:$last_recovery_at,result:$result,error:$error}' \
        > "$_tmp" && chmod 600 "$_tmp" && mv "$_tmp" "$(_warp_health_file)"
}

_warp_wait_route() {
    local _i
    for _i in {1..15}; do
        warp_check_route && return 0
        [ "$_i" -ne 1 ] || log_info "Ждём подтверждение маршрута WARP..."
        sleep 2
    done
    return 1
}

_warp_start_services() {
    if [ "$(_warp_mode)" = iface ]; then
        _warp_write_iface_units || return 1
        systemctl enable "$WARP_IFACE_UNIT" "$WARP_ROUTE_UNIT" >/dev/null || return 1
        systemctl reset-failed "$WARP_IFACE_UNIT" "$WARP_ROUTE_UNIT" >/dev/null 2>&1 || true
        systemctl restart "$WARP_IFACE_UNIT" && systemctl restart "$WARP_ROUTE_UNIT"
    else
        _warp_write_socks_runner && _warp_write_socks_units || return 1
        systemctl enable "$WARP_SOCKS_UNIT" >/dev/null || return 1
        systemctl reset-failed "$WARP_SOCKS_UNIT" >/dev/null 2>&1 || true
        systemctl restart "$WARP_SOCKS_UNIT" || return 1
        if [ "$(_warp_mode)" = socks ]; then
            _warp_write_redsocks_conf
            systemctl enable "$WARP_REDSOCKS_UNIT" >/dev/null || return 1
            systemctl reset-failed "$WARP_REDSOCKS_UNIT" >/dev/null 2>&1 || true
            systemctl restart "$WARP_REDSOCKS_UNIT" || return 1
        fi
    fi
    if [ "$(_warp_mode)" != upstream ] || [ "$(_warp_socks_listen)" != 127.0.0.1 ]; then
        _warp_generate_nft && sh "$(_warp_nft_script)" || return 1
    fi
    return 0
}

_warp_activate_endpoint() {
    _warp_valid_endpoint "$1" || return 1
    local _old_state="" _old_conf=""
    [ ! -f "$(_warp_state)" ] || _old_state=$(cat "$(_warp_state)")
    [ ! -f "$(_warp_conf)" ] || _old_conf=$(cat "$(_warp_conf)")
    if [ "$(_warp_mode)" = iface ]; then
        _warp_generate_iface_conf "$1" || return 1
    fi
    _warp_write_state "$1" || return 1
    if _warp_start_services && _warp_wait_route; then
        return 0
    fi
    log_warn "Новый туннель не подтверждён — восстанавливаем прежний"
    [ -z "$_old_state" ] || printf '%s\n' "$_old_state" > "$(_warp_state)"
    [ -z "$_old_conf" ] || printf '%s\n' "$_old_conf" > "$(_warp_conf)"
    _warp_start_services >/dev/null 2>&1 || true
    return 1
}

warp_apply() {
    [ "${WARP_ENABLED:-false}" = true ] || { log_error "Сначала включите WARP"; return 1; }
    local _ep
    _ep=$(warp_resolve_endpoint) || return 1
    _warp_activate_endpoint "$_ep" || return 1
    warp_install_watchdog || return 1
    log_success "Выбор применён: $_ep"
}

warp_recover() {
    [ "${WARP_ENABLED:-false}" = true ] || { log_error "WARP выключен"; return 1; }
    local _state; _state=$(cat "$(_warp_state)" 2>/dev/null)
    if ! jq -e '(.mode | IN("socks","iface","upstream")) and (.proto | IN("wg","awg","masque","masque-h2")) and (.location | type=="string") and (.pin | type=="string")' \
        <<< "$_state" >/dev/null 2>&1; then
        _warp_health_save 3 "$(date +%s)" failed "Нет настроек активного туннеля: mtproxyl warp refresh или apply"
        log_error "Не удалось прочитать активные настройки WARP; автоматическая смена локации отменена"
        return 1
    fi
    local WARP_MODE WARP_PROTO WARP_LOCATION WARP_ENDPOINT
    WARP_MODE=$(jq -r '.mode' <<< "$_state")
    WARP_PROTO=$(jq -r '.proto' <<< "$_state")
    WARP_LOCATION=$(jq -r '.location' <<< "$_state")
    WARP_ENDPOINT=$(jq -r '.pin' <<< "$_state")
    local _now; _now=$(date +%s)
    _warp_health_save 0 "$_now" recovering
    if _warp_start_services && _warp_wait_route; then
        _warp_health_save 0 "$_now" recovered
        log_success "Туннель и маршрут WARP восстановлены"
        return 0
    fi
    local _ep _candidate _host
    _candidate=$(jq -r --arg proto "$(_warp_proto)" --arg filter "$WARP_LOCATION" \
        --arg active "$(jq -r '.endpoint // ""' <<< "$_state")" \
        'select(.proto==$proto and .filter==$filter) | [.nodes[] | select(.endpoint!=$active)][0].endpoint // empty' \
        "$(_warp_scan_file)" 2>/dev/null)
    if [ -n "$_candidate" ]; then
        _host="${_candidate%:*}"; _host="${_host#[}"; _host="${_host%]}"
        _ep=$(warp_scan_best "$_host" "${_candidate##*:}") || _ep=""
    fi
    if [ -z "${_ep:-}" ]; then
        if warp_scan_collect; then
            _ep=$(jq -r '.best_endpoint // empty' "$(_warp_scan_file)")
        fi
    fi
    if [ -n "${_ep:-}" ] && _warp_activate_endpoint "$_ep"; then
        _warp_health_save 0 "$_now" recovered
        log_success "WARP восстановлен через $_ep"
        return 0
    fi
    _warp_health_save 3 "$_now" failed "Не удалось восстановить туннель в выбранной локации"
    log_error "WARP не восстановлен; локация, протокол и маршруты сохранены"
    return 1
}

warp_watch() {
    [ "${WARP_ENABLED:-false}" = true ] && [ "${WARP_WATCHDOG_ENABLED:-true}" = true ] || return 0
    local _fails _last _now
    _fails=$(jq -r '.failures // 0' "$(_warp_health_file)" 2>/dev/null) || _fails=0
    _last=$(jq -r '.last_recovery_at // 0' "$(_warp_health_file)" 2>/dev/null) || _last=0
    [[ "$_fails" =~ ^[0-9]+$ ]] || _fails=0
    [[ "$_last" =~ ^[0-9]+$ ]] || _last=0
    _now=$(date +%s)
    if warp_check_route; then
        _warp_health_save 0 "$_last" healthy
        return 0
    fi
    _fails=$((_fails + 1))
    _warp_health_save "$_fails" "$_last" unhealthy "Проверка туннеля или маршрута не прошла"
    [ "$_fails" -ge 3 ] && [ "$((_now - _last))" -ge 300 ] || return 0
    warp_recover
}

warp_set_watchdog() {
    case "${1:-}" in
        on) WARP_WATCHDOG_ENABLED=true ;;
        off) WARP_WATCHDOG_ENABLED=false ;;
        *) log_error "watchdog on|off"; return 1 ;;
    esac
    save_settings && warp_install_watchdog
}

warp_preflight() {
    local _mode="${1:-$(_warp_mode)}" _me=false _can_me=false _owns=false _manual=false _others=""
    case "$_mode" in socks|iface|upstream) ;; *) return 1 ;; esac
    _warp_me_enabled && _me=true
    if [ "${MTPROXYL_MODE:-manager}" = "manager" ] && ! _superexpert_active 2>/dev/null; then _can_me=true; fi
    _warp_owns_engine_config && _owns=true
    if [ "$_mode" = upstream ]; then
        if [ "$_owns" = true ]; then _others=$(_warp_foreign_default_upstreams); else _manual=true; fi
    fi
    jq -nc --arg mode "$_mode" --argjson me "$_me" --argjson canMe "$_can_me" \
        --argjson owns "$_owns" --argjson manual "$_manual" --arg others "$_others" '
        {mode:$mode,middle_proxy_enabled:$me,can_disable_middle_proxy:$canMe,
         owns_engine_config:$owns,manual_engine_config:$manual,
         default_upstreams:($others|split(",")|map(select(length>0))),
         can_disable_default_upstreams:($owns and ($mode=="upstream"))}'
}

handle_warp_command() (
    case "${1:-}" in
        off|disable|remove|uninstall)
            check_root
            systemctl stop "$WARP_WATCH_UNIT.timer" "$WARP_WATCH_UNIT.service" >/dev/null 2>&1 || true
            ;;
    esac
    case "${1:-status}:${2:-}" in
        status:*|hint:*|preflight:*|scan:--json|scan:--last) ;;
        *)
            check_root
            mkdir -p "$INSTALL_DIR" || return 1
            local _lock
            exec {_lock}>"$INSTALL_DIR/.warp.lock" || return 1
            if ! flock -n "$_lock"; then
                # Таймер может попасть ровно в ручное включение/выключение.
                # Это штатный пропуск проверки, а не падение systemd-службы.
                [ "${1:-}" = watch ] && return 0
                log_error "Другая операция WARP уже выполняется"
                return 1
            fi
            load_settings
            ;;
    esac
    _warp_dispatch "$@"
)

_warp_dispatch() {
    case "${1:-status}" in
        status|"")
            if [ "${2:-}" = "--json" ]; then warp_status_json; else warp_status; fi ;;
        on|enable)   warp_enable "${@:2}" ;;
        off|disable) warp_disable ;;
        install)
            check_root
            _warp_scan_dependencies && warp_install_binary || return 1
            if [ "${WARP_ENABLED:-false}" = true ]; then
                log_info "Для запуска обновлённого бинарника: mtproxyl warp recover"
            fi ;;
        remove|uninstall) warp_remove ;;
        reapply)     warp_reapply ;;
        apply)       warp_apply ;;
        refresh)     warp_refresh ;;
        recover)     warp_recover ;;
        watch)       warp_watch ;;
        watchdog)    warp_set_watchdog "${2:-}" ;;
        settings)    warp_set_settings "${2:-keep}" "${3:-keep}" "${4:-keep}" ;;
        preflight)
            [ "${3:-}" = "--json" ] || { log_error "warp preflight <вариант> --json"; return 1; }
            warp_preflight "${2:-}" ;;
        scan)
            if [ "${2:-}" = "--json" ]; then warp_scan_json
            elif [ "${2:-}" = "--last" ]; then warp_scan_print
            else
                local WARP_MODE="${WARP_MODE:-socks}"
                case "${2:-}" in socks|iface|upstream) WARP_MODE="$2" ;; "") ;; *) return 1 ;; esac
                warp_scan_show
            fi ;;
        location)    warp_set_location "${2:-}" ;;
        endpoint)    warp_set_endpoint "${2:-}" ;;
        proto)       warp_set_proto "${2:-}" ;;
        cidr)        check_root; warp_update_cidr ;;
        hint)        _warp_upstream_manual_hint ;;
        *)
            echo -e "  ${BOLD}Маршрут до Telegram через WARP:${NC}"
            echo -e "    ${GREEN}warp status${NC} [--json]  Состояние, выход, службы"
            echo -e "    ${GREEN}warp on${NC} <вариант>     socks (A), iface (B) или upstream (C)"
            echo -e "      ${DIM}--allow-disable-me --allow-disable-default-upstreams — явные согласия для автоматизации${NC}"
            echo -e "    ${GREEN}warp preflight${NC} <вариант> --json  Проверить конфликты перед включением"
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
