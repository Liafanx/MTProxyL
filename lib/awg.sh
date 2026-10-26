#!/bin/bash
# MTProxyL — выход к Telegram через свой сервер AmneziaWG по импортированному
# клиентскому конфигу. В туннель идут только подсети Telegram, остальное — мимо.

AWG_IFACE="mtpawg"
AWG_NFT_TABLE="mtproxyl_awg"
AWG_RT_TABLE="51821"
# Свой бит метки: 0x100000 у WARP, 0x40000000 и 0x40000 у zapret2.
AWG_FWMARK="0x200000"
AWG_ROUTE_UNIT="mtproxyl-awg-route.service"
AWG_WATCH_UNIT="mtproxyl-awg-watch"
AWG_CONF_MAX=65536

_awg_dir()        { echo "${INSTALL_DIR:-/opt/mtproxyl}/awg"; }
_awg_store()      { echo "$(_awg_dir)/configs"; }
_awg_state_file() { echo "$(_awg_dir)/state.conf"; }
_awg_nft_script() { echo "$(_awg_dir)/nft.sh"; }
_awg_sys_conf()   { echo "${DONOR_AWG_DIR:-/etc/amnezia/amneziawg}/${AWG_IFACE}.conf"; }
_awg_quick_unit() { echo "awg-quick@${AWG_IFACE}.service"; }

# ── Состояние ───────────────────────────────────────────────────────────────

_AWG_KEYS="AWG_ENABLED AWG_ACTIVE AWG_MTU AWG_EGRESS_IP AWG_EGRESS_AT AWG_IPV6 AWG_ME_MODE AWG_ME_DISABLED
AWG_ENGINE_ROUTED AWG_TARGET_ORIG_NATIP AWG_TARGET_ORIG_PROBE AWG_TARGET_ORIG_USEME AWG_ENABLED_AT
AWG_CHECK_AT AWG_CHECK_RESULT AWG_CHECK_ERROR AWG_ORDER AWG_FAIL_SINCE AWG_PRIMARY_AT
AWG_SWITCH_AT AWG_SWITCH_FROM AWG_SWITCH_TO AWG_SWITCH_REASON"

awg_load() {
    local _k
    for _k in $_AWG_KEYS; do printf -v "$_k" '%s' ""; done
    AWG_ENABLED="false"
    local _f; _f=$(_awg_state_file)
    [ -f "$_f" ] || return 0
    local _line _key _val
    while IFS= read -r _line; do
        [[ "$_line" =~ ^(AWG_[A-Z0-9_]+)=\'([^\']*)\'$ ]] || continue
        _key="${BASH_REMATCH[1]}"; _val="${BASH_REMATCH[2]}"
        case " ${_AWG_KEYS//$'\n'/ } " in
            *" ${_key} "*) printf -v "$_key" '%s' "$_val" ;;
        esac
    done < "$_f"
    _awg_valid_name "$AWG_ACTIVE" || AWG_ACTIVE=""
    _awg_valid_mtu "$AWG_MTU" || AWG_MTU=""
    validate_ip_literal "$AWG_EGRESS_IP" 2>/dev/null || AWG_EGRESS_IP=""
    local _n
    for _n in AWG_EGRESS_AT AWG_ENABLED_AT AWG_CHECK_AT AWG_FAIL_SINCE AWG_PRIMARY_AT AWG_SWITCH_AT; do
        [[ "${!_n}" =~ ^[0-9]{1,12}$ ]] || printf -v "$_n" '%s' ""
    done
    return 0
}

awg_save() {
    local _dir; _dir=$(_awg_dir)
    install -d -m 700 "$_dir" || return 1
    local _tmp; _tmp=$(mktemp "$_dir/.state.XXXXXX") || return 1
    local _k _v
    for _k in $_AWG_KEYS; do
        _v="${!_k:-}"; _v="${_v//\'/}"; _v="${_v//$'\n'/ }"
        printf "%s='%s'\n" "$_k" "$_v"
    done > "$_tmp"
    chmod 600 "$_tmp" && mv "$_tmp" "$(_awg_state_file)"
}

awg_is_enabled() {
    [ -f "$(_awg_state_file)" ] || return 1
    grep -qx "AWG_ENABLED='true'" "$(_awg_state_file)" 2>/dev/null
}

_awg_valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]; }
_awg_valid_mtu()  { [[ "$1" =~ ^[0-9]{4}$ ]] && [ "$1" -ge 1200 ] && [ "$1" -le 1500 ]; }

# Имя из имени файла: латиница, цифры, «-» и «_», до 32 символов.
_awg_name_from_path() {
    local _n; _n=$(basename "$1"); _n="${_n%.conf}"
    _n=$(printf '%s' "$_n" | tr -c 'A-Za-z0-9_-' '_' | sed 's/^[_-]*//' | cut -c1-32)
    [ -n "$_n" ] || _n="awg"
    echo "$_n"
}

# ── Разбор конфига ──────────────────────────────────────────────────────────

# Нормализует клиентский конфиг: оставляет ключи и параметры обфускации,
# выкидывает DNS, Table и Pre/PostUp — чужие команды от root не исполняем.
# Вывод: конфиг; при ошибке первая строка «ERR:причина». Выкинутое — в «DROP:».
_awg_normalize() {
    awk '
        function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
        function iskey(v) { return length(v) == 44 && v ~ /^[A-Za-z0-9+\/]+=$/ }
        function fail(m) { if (err == "") err = m }
        # Диапазон AWG 3.x: «N» или «N-M», u16, N <= M.
        function isrange(v,   r) {
            if (v !~ /^[0-9]+(-[0-9]+)?$/) return 0
            split(v, r, "-"); if (!(2 in r)) r[2] = r[1]
            return r[1] + 0 <= 65535 && r[2] + 0 <= 65535 && r[1] + 0 <= r[2] + 0
        }
        function isbool(v) { return tolower(v) ~ /^(on|off|[0-9]+)$/ }
        BEGIN {
            split("PrivateKey Address MTU Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5 HeaderProtectionKey ContentPaddingAddition RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts RandomTrailers DisableCookies", a, " ")
            for (i in a) ikeys[tolower(a[i])] = a[i]
            split("PublicKey PresharedKey Endpoint AllowedIPs PersistentKeepalive AdvancedSecurity", b, " ")
            for (i in b) pkeys[tolower(b[i])] = b[i]
            sec = ""; ni = 0; np = 0; n = 0; err = ""; drop = ""
        }
        {
            line = $0; sub(/\r$/, "", line)
            t = trim(line)
            if (t == "" || t ~ /^[#;]/) next
            if (t ~ /^\[.*\]$/) {
                s = tolower(t)
                if (s == "[interface]") { ni++; sec = "i"; out[++n] = "[Interface]" }
                else if (s == "[peer]") { np++; sec = "p"; out[++n] = ""; out[++n] = "[Peer]"; ppub[np] = 0; pep[np] = 0 }
                else fail("неизвестная секция " t)
                next
            }
            p = index(t, "=")
            if (!p) { fail("строка без «=»: " substr(t, 1, 40)); next }
            k = trim(substr(t, 1, p - 1)); v = trim(substr(t, p + 1)); lk = tolower(k)
            if (lk !~ /^i[1-5]$/) { c = index(v, "#"); if (c) v = trim(substr(v, 1, c - 1)) }
            if (v == "") next
            if (sec == "i" && (lk in ikeys)) {
                ck = ikeys[lk]
                if (ck == "PrivateKey") { if (!iskey(v)) fail("PrivateKey не похож на ключ"); hk = 1 }
                else if (ck == "Address") {
                    m = split(v, ad, ",")
                    for (j = 1; j <= m; j++) {
                        x = trim(ad[j])
                        if (x ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) has4 = 1
                        else if (x ~ /^[0-9a-fA-F:]+(\/[0-9]+)?$/ && index(x, ":")) has6 = 1
                        else fail("Address: " x)
                    }
                    addr = v
                }
                else if (ck == "MTU") { if (v !~ /^[0-9]+$/ || v + 0 < 576 || v + 0 > 9000) fail("MTU: " v) }
                else if (ck ~ /^(Jc|Jmin|Jmax|S[1-4]|H[1-4])$/) {
                    if (v !~ /^[0-9]+(-[0-9]+)?$/) fail(ck ": " v)
                    if (ck ~ /^S[1-4]$/) sv[ck] = v + 0
                    if (ck ~ /^H/ ? v !~ /^[1-4]$/ : v + 0 > 0) { obf = 1; if (lvl < 1) lvl = 1 }
                    if ((ck ~ /^S[34]$/ && v + 0 > 0) || (ck ~ /^H/ && index(v, "-"))) lvl = lvl < 2 ? 2 : lvl
                }
                else if (ck == "HeaderProtectionKey") { if (!iskey(v)) fail(ck " не похож на ключ"); obf = 1; lvl = 3; hpk = 1 }
                else if (ck ~ /^(RandomTrailers|DisableCookies)$/) { if (!isbool(v)) fail(ck ": " v); obf = 1; lvl = 3 }
                else if (ck ~ /^(ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts)$/) {
                    if (!isrange(v)) fail(ck ": " v); obf = 1; lvl = 3
                }
                else { if (v ~ /["`$\\'\'']/) fail(ck ": недопустимые символы"); obf = 1; if (lvl < 2) lvl = 2 }
                out[++n] = ck " = " v
            } else if (sec == "p" && (lk in pkeys)) {
                ck = pkeys[lk]
                if (ck == "PublicKey") { if (!iskey(v)) fail("PublicKey не похож на ключ"); ppub[np] = 1 }
                else if (ck == "PresharedKey") { if (!iskey(v)) fail("PresharedKey не похож на ключ") }
                else if (ck == "Endpoint") {
                    if (v !~ /^[A-Za-z0-9.-]+:[0-9]+$/ && v !~ /^\[[0-9a-fA-F:]+\]:[0-9]+$/) fail("Endpoint: " v)
                    pep[np] = 1; if (ep == "") ep = v
                }
                else if (ck == "AllowedIPs") { if (v !~ /^[0-9a-fA-F:.,\/ ]+$/) fail("AllowedIPs: " v) }
                else if (ck == "AdvancedSecurity") { if (!isbool(v)) fail(ck ": " v); lvl = 3 }
                else {
                    if (v != "off" && !isrange(v)) fail("PersistentKeepalive: " v)
                    if (index(v, "-")) lvl = 3
                }
                out[++n] = ck " = " v
            } else if (sec == "") {
                fail("ключ вне секции: " k)
            } else {
                drop = drop (drop == "" ? "" : ", ") k
            }
        }
        END {
            if (ni != 1) fail(ni == 0 ? "нет секции [Interface]" : "несколько секций [Interface]")
            if (np < 1) fail("нет секции [Peer]")
            if (!hk) fail("нет PrivateKey")
            if (!has4) fail("нет IPv4 в Address")
            # Модуль AWG 3.x с защитой заголовков требует S1–S4 не меньше 12.
            if (hpk) for (j = 1; j <= 4; j++) if (sv["S" j] + 0 < 12) { fail("с HeaderProtectionKey S1–S4 должны быть не меньше 12"); break }
            for (j = 1; j <= np; j++) {
                if (!ppub[j]) fail("у [Peer] нет PublicKey")
                if (!pep[j]) fail("у [Peer] нет Endpoint — это конфиг сервера, а нужен клиентский")
            }
            if (err != "") { print "ERR:" err; exit 1 }
            print "# MTProxyL: endpoint=" ep " address=" addr " obfuscation=" (obf ? "yes" : "no") " ipv6=" (has6 ? "yes" : "no") " awg=" (lvl ? lvl : (obf ? 1 : "wg"))
            if (drop != "") print "# DROP: " drop
            for (j = 1; j <= n; j++) print out[j]
        }
    ' "$1"
}

# Сводка по нормализованному конфигу: endpoint|address|obfuscation|ipv6.
# Пятое поле — уровень AWG (wg, 1, 2, 3); у конфигов до 1.7.15 его нет.
_awg_conf_info() {
    sed -n '1s/^# MTProxyL: endpoint=\([^ ]*\) address=\(.*\) obfuscation=\([a-z]*\) ipv6=\([a-z]*\)\( awg=\([a-z0-9]*\)\)\{0,1\}$/\1|\2|\3|\4|\6/p' "$1" 2>/dev/null
}

# Подпись уровня для людей: «AWG 3.x», «AWG 2.0», «AWG 1.0», «WireGuard».
_awg_level_label() {
    case "${1:-}" in
        3) echo "AWG 3.x" ;; 2) echo "AWG 2.0" ;; 1) echo "AWG 1.0" ;; wg) echo "WireGuard" ;; *) echo "" ;;
    esac
}

# «, AWG 3.x» для строк списка; у старых сводок уровня нет.
_awg_kind() {
    local _l; _l=$(_awg_level_label "${2:-}")
    [ -z "$_l" ] && [ "${1:-}" = yes ] && _l="AWG"
    [ -n "$_l" ] && echo ", ${_l}"
}

_awg_conf_dropped() { sed -n 's/^# DROP: //p' "$1" 2>/dev/null | head -1; }

# Проверка файла-кандидата без печати ключей. Вывод — как у _awg_conf_info.
_awg_check_file() {
    local _f="$1" _tmp _out
    _AWG_FILE_ERR=""
    [ -f "$_f" ] && [ -r "$_f" ] || { _AWG_FILE_ERR="файл не найден"; return 1; }
    [ "$(stat -c %s "$_f" 2>/dev/null || echo 0)" -le "$AWG_CONF_MAX" ] || { _AWG_FILE_ERR="файл больше 64 КБ"; return 1; }
    _tmp=$(mktemp) || return 1
    if ! _awg_normalize "$_f" > "$_tmp"; then
        _out=$(head -1 "$_tmp"); rm -f "$_tmp"
        _AWG_FILE_ERR="${_out#ERR:}"; [ -n "$_AWG_FILE_ERR" ] || _AWG_FILE_ERR="не разобран"
        return 1
    fi
    _awg_conf_info "$_tmp"
    rm -f "$_tmp"
}

# ── Поиск и импорт ──────────────────────────────────────────────────────────

_awg_scan_paths() {
    {
        find "${INSTALL_DIR:-/opt/mtproxyl}" -maxdepth 3 -type f -name '*.conf' -size -65k \
            -not -path "$(_awg_dir)/*" 2>/dev/null
        find /root -maxdepth 2 -type f -name '*.conf' -size -65k 2>/dev/null
        find /etc/amnezia/amneziawg /etc/wireguard -maxdepth 1 -type f -name '*.conf' 2>/dev/null
    } | sort -u | while IFS= read -r _f; do
        case "$(basename "$_f")" in mtpdonor.conf|mtpwarp.conf|"${AWG_IFACE}.conf") continue ;; esac
        grep -qiE '^[[:space:]]*\[Interface\]' "$_f" 2>/dev/null || continue
        grep -qiE '^[[:space:]]*\[Peer\]' "$_f" 2>/dev/null || continue
        echo "$_f"
    done
}

awg_scan() {
    local _json=false _f _info _first=true
    [ "${1:-}" = "--json" ] && _json=true
    local -a _found=()
    mapfile -t _found < <(_awg_scan_paths)
    if [ "$_json" = true ]; then
        printf '{"files":['
        for _f in "${_found[@]}"; do
            [ "$_first" = true ] || printf ','; _first=false
            if _info=$(_awg_check_file "$_f"); then
                IFS='|' read -r _ep _addr _obf _v6 _lvl <<< "$_info"
                printf '{"path":"%s","name":"%s","valid":true,"endpoint":"%s","address":"%s","obfuscation":%s,"ipv6":%s,"awg_version":"%s","error":""}' \
                    "$(json_escape "$_f")" "$(json_escape "$(_awg_name_from_path "$_f")")" "$(json_escape "$_ep")" \
                    "$(json_escape "$_addr")" "$([ "$_obf" = yes ] && echo true || echo false)" \
                    "$([ "$_v6" = yes ] && echo true || echo false)" "$(_awg_level_label "$_lvl")"
            else
                printf '{"path":"%s","name":"%s","valid":false,"endpoint":"","address":"","obfuscation":false,"ipv6":false,"awg_version":"","error":"%s"}' \
                    "$(json_escape "$_f")" "$(json_escape "$(_awg_name_from_path "$_f")")" "$(json_escape "$_AWG_FILE_ERR")"
            fi
        done
        printf ']}\n'
        return 0
    fi
    echo ""
    if [ ${#_found[@]} -eq 0 ]; then
        log_info "Конфигов WireGuard/AmneziaWG не найдено"
        echo -e "  ${DIM}Положите файл в $(_awg_dir) или /root и повторите, либо укажите путь: mtproxyl awg import <файл>${NC}"
        return 0
    fi
    for _f in "${_found[@]}"; do
        if _info=$(_awg_check_file "$_f"); then
            IFS='|' read -r _ep _addr _obf _v6 _lvl <<< "$_info"
            echo -e "  ${GREEN}${SYM_OK}${NC} ${_f}  ${DIM}${_ep}, ${_addr}$(_awg_kind "$_obf" "$_lvl")${NC}"
        else
            echo -e "  ${DIM}—${NC} ${_f}  ${DIM}не подходит: ${_AWG_FILE_ERR}${NC}"
        fi
    done
    echo ""
}

awg_import() {
    check_root
    local _src="" _name="" _json=false _arg
    while [ $# -gt 0 ]; do
        _arg="$1"; shift
        case "$_arg" in
            --name) _name="${1:-}"; shift ;;
            --json) _json=true ;;
            -) [ -z "$_src" ] && _src="-" || { log_error "Лишний аргумент: ${_arg}"; return 1; } ;;
            -*) log_error "Неизвестный параметр: ${_arg}"; return 1 ;;
            *) [ -z "$_src" ] && _src="$_arg" || { log_error "Лишний аргумент: ${_arg}"; return 1; } ;;
        esac
    done
    [ -n "$_src" ] || { log_error "Укажите файл конфига или «-» для stdin"; return 1; }

    local _raw; _raw=$(mktemp) || return 1
    if [ "$_src" = "-" ]; then
        head -c $((AWG_CONF_MAX + 1)) > "$_raw"
        [ -z "$_name" ] && _name="awg"
    else
        [[ "$_src" == /* ]] || _src="$(pwd)/${_src}"
        [ -f "$_src" ] || { rm -f "$_raw"; log_error "Файл не найден: ${_src}"; return 1; }
        head -c $((AWG_CONF_MAX + 1)) "$_src" > "$_raw"
        [ -z "$_name" ] && _name=$(_awg_name_from_path "$_src")
    fi
    if [ "$(stat -c %s "$_raw")" -gt "$AWG_CONF_MAX" ]; then
        rm -f "$_raw"; log_error "Файл больше 64 КБ — это не конфиг WireGuard"; return 1
    fi
    _awg_valid_name "$_name" || { rm -f "$_raw"; log_error "Имя: латиница, цифры, «-» и «_», до 32 символов"; return 1; }

    local _norm; _norm=$(mktemp) || { rm -f "$_raw"; return 1; }
    if ! _awg_normalize "$_raw" > "$_norm"; then
        log_error "Конфиг не подходит: $(head -1 "$_norm" | sed 's/^ERR://')"
        rm -f "$_raw" "$_norm"; return 1
    fi
    rm -f "$_raw"

    awg_load
    if [ "$AWG_ENABLED" = true ] && [ "$AWG_ACTIVE" = "$_name" ]; then
        rm -f "$_norm"
        log_error "Конфиг «${_name}» сейчас используется — выключите выход или дайте другое имя (--name)"
        return 1
    fi
    install -d -m 700 "$(_awg_dir)" "$(_awg_store)" || { rm -f "$_norm"; return 1; }
    local _dst; _dst="$(_awg_store)/${_name}.conf"
    local _existed=false; [ -f "$_dst" ] && _existed=true
    install -m 600 "$_norm" "$_dst" || { rm -f "$_norm"; return 1; }
    rm -f "$_norm"

    local _ep _addr _obf _v6 _lvl
    IFS='|' read -r _ep _addr _obf _v6 _lvl < <(_awg_conf_info "$_dst")
    if [ "$_json" = true ]; then
        printf '{"name":"%s","endpoint":"%s","address":"%s","obfuscation":%s,"replaced":%s,"dropped":"%s"}\n' \
            "$(json_escape "$_name")" "$(json_escape "$_ep")" "$(json_escape "$_addr")" \
            "$([ "$_obf" = yes ] && echo true || echo false)" "$_existed" "$(json_escape "$(_awg_conf_dropped "$_dst")")"
        return 0
    fi
    log_success "Конфиг сохранён как «${_name}»$([ "$_existed" = true ] && echo " (заменён прежний)")"
    echo -e "  ${DIM}Сервер: ${_ep}, адрес в туннеле: ${_addr}$(_awg_kind "$_obf" "$_lvl")${NC}"
    local _drop; _drop=$(_awg_conf_dropped "$_dst")
    [ -n "$_drop" ] && echo -e "  ${DIM}Не используются (маршруты и DNS задаёт MTProxyL): ${_drop}${NC}"
    echo -e "  ${DIM}Включить: ${GREEN}mtproxyl awg on ${_name}${NC}"
}

_awg_list_names() {
    local _f
    for _f in "$(_awg_store)"/*.conf; do
        [ -f "$_f" ] || continue
        _f=$(basename "$_f" .conf)
        _awg_valid_name "$_f" && echo "$_f"
    done
}

awg_remove() {
    check_root
    local _name="${1:-}"
    _awg_valid_name "$_name" || { log_error "Укажите имя конфига: mtproxyl awg list"; return 1; }
    local _f; _f="$(_awg_store)/${_name}.conf"
    [ -f "$_f" ] || { log_error "Конфига «${_name}» нет"; return 1; }
    awg_load
    if [ "$AWG_ENABLED" = true ] && [ "$AWG_ACTIVE" = "$_name" ]; then
        log_error "Конфиг используется — сначала выключите выход: mtproxyl awg off"
        return 1
    fi
    rm -f "$_f"
    [ "$AWG_ACTIVE" = "$_name" ] && AWG_ACTIVE=""
    AWG_ORDER=$(tr ',' '\n' <<< "${AWG_ORDER:-}" | grep -vxF "$_name" | paste -sd, -)
    awg_save
    log_success "Конфиг «${_name}» удалён"
}

# ── Интерфейс и маршруты ────────────────────────────────────────────────────

_awg_write_sys_conf() {
    local _src; _src="$(_awg_store)/${AWG_ACTIVE}.conf"
    [ -f "$_src" ] || { log_error "Нет конфига «${AWG_ACTIVE}»"; return 1; }
    install -d -m 700 "$(dirname "$(_awg_sys_conf)")" || return 1
    local _tmp; _tmp=$(mktemp "$(dirname "$(_awg_sys_conf)")/.mtpawg.XXXXXX") || return 1
    # Table = off: маршрутов из AllowedIPs не ставим, в туннель ведут ip rule по метке.
    awk -v mtu="${AWG_MTU:-}" '
        /^#/ { next }
        /^MTU = / && mtu != "" { next }
        { print }
        /^\[Interface\]$/ { print "Table = off"; if (mtu != "") print "MTU = " mtu }
    ' "$_src" > "$_tmp" && chmod 600 "$_tmp" && mv "$_tmp" "$(_awg_sys_conf)"
}

_awg_handshake_age() {
    local _ts; _ts=$(awg show "$AWG_IFACE" latest-handshakes 2>/dev/null | awk '$2 > m {m = $2} END {print m + 0}')
    [[ "$_ts" =~ ^[0-9]+$ ]] && [ "$_ts" -gt 0 ] || { echo ""; return 1; }
    echo $(( $(date +%s) - _ts ))
}

_awg_tunnel_up() {
    _donor_dkms_hook_local 2>/dev/null || true
    systemctl enable "$(_awg_quick_unit)" >/dev/null 2>&1
    systemctl restart "$(_awg_quick_unit)" >/dev/null 2>&1 || {
        log_error "Интерфейс ${AWG_IFACE} не поднялся"
        journalctl -u "$(_awg_quick_unit)" -n 5 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    }
    local _i
    for _i in $(seq 1 20); do
        _awg_handshake_age >/dev/null && return 0
        # Рукопожатие начинается с первого пакета в туннель.
        curl -4 -s -m 1 -o /dev/null --interface "$AWG_IFACE" http://1.1.1.1/ 2>/dev/null || true
        sleep 1
    done
    log_error "Сервер AmneziaWG не ответил на рукопожатие за 20 секунд"
    echo -e "  ${DIM}Проверьте, что конфиг рабочий (подключите им телефон) и UDP до сервера не режется.${NC}"
    return 1
}

_awg_tunnel_down() {
    systemctl disable --now "$(_awg_quick_unit)" >/dev/null 2>&1 || true
    ip link show "$AWG_IFACE" >/dev/null 2>&1 && ip link delete "$AWG_IFACE" 2>/dev/null
    return 0
}

# Выход туннеля: IP и живой ответ Telegram.
_awg_probe() {
    _AWG_PROBE_EGRESS=""; _AWG_PROBE_TG=""
    _AWG_PROBE_EGRESS=$(curl -4 -s -m 10 --interface "$AWG_IFACE" https://api.ipify.org 2>/dev/null)
    validate_ip_literal "$_AWG_PROBE_EGRESS" 2>/dev/null || _AWG_PROBE_EGRESS=""
    _AWG_PROBE_TG=$(curl -4 -s -m 15 -o /dev/null -w '%{http_code}' --interface "$AWG_IFACE" \
        https://core.telegram.org/getProxyConfig 2>/dev/null)
    [ "$_AWG_PROBE_TG" = 200 ]
}

_awg_tunnel_has_v6() {
    grep -q inet6 <<< "$(ip -6 addr show dev "$AWG_IFACE" scope global 2>/dev/null)"
}

_awg_generate_nft() {
    local _v4 _v6 _bridges _script
    _v4=$(_warp_cidr_list 4); _v6=$(_warp_cidr_list 6)
    _bridges=$(_warp_bridge_nets)
    _script=$(_awg_nft_script)
    install -d -m 700 "$(_awg_dir)" || return 1
    {
        echo "#!/bin/sh"
        echo "# Сгенерировано MTProxyL — подсети Telegram через ${AWG_IFACE}"
        echo "nft delete table inet ${AWG_NFT_TABLE} 2>/dev/null || true"
        echo "nft add table inet ${AWG_NFT_TABLE}"
        echo "nft add set inet ${AWG_NFT_TABLE} tg4 '{ type ipv4_addr; flags interval; }'"
        echo "nft add set inet ${AWG_NFT_TABLE} tg6 '{ type ipv6_addr; flags interval; }'"
        [ -n "$_v4" ] && echo "nft add element inet ${AWG_NFT_TABLE} tg4 '{ ${_v4} }'"
        [ -n "$_v6" ] && echo "nft add element inet ${AWG_NFT_TABLE} tg6 '{ ${_v6} }'"
        echo "nft add chain inet ${AWG_NFT_TABLE} output '{ type route hook output priority -150; policy accept; }'"
        echo "nft add rule inet ${AWG_NFT_TABLE} output ip daddr @tg4 counter meta mark set meta mark or ${AWG_FWMARK}"
        # Без IPv6 в туннеле IPv6 до Telegram сбрасываем — движок уйдёт на IPv4 через туннель.
        echo "if ip -6 addr show dev ${AWG_IFACE} scope global 2>/dev/null | grep -q inet6; then"
        echo "  nft add rule inet ${AWG_NFT_TABLE} output ip6 daddr @tg6 counter meta mark set meta mark or ${AWG_FWMARK}"
        echo "else"
        echo "  nft add chain inet ${AWG_NFT_TABLE} filter_out '{ type filter hook output priority 0; policy accept; }'"
        echo "  nft add rule inet ${AWG_NFT_TABLE} filter_out meta l4proto tcp ip6 daddr @tg6 counter reject with tcp reset"
        echo "fi"
        if [ -n "$_bridges" ]; then
            echo "nft add chain inet ${AWG_NFT_TABLE} prerouting '{ type filter hook prerouting priority -150; policy accept; }'"
            echo "nft add rule inet ${AWG_NFT_TABLE} prerouting ip saddr { ${_bridges} } ip daddr @tg4 counter meta mark set meta mark or ${AWG_FWMARK}"
        fi
        # Сервер AWG ждёт от нас только адрес из Address — подменяем источник.
        echo "nft add chain inet ${AWG_NFT_TABLE} postrouting '{ type nat hook postrouting priority 100; policy accept; }'"
        echo "nft add rule inet ${AWG_NFT_TABLE} postrouting oifname ${AWG_IFACE} masquerade"
    } > "$_script"
    chmod 700 "$_script"
}

_awg_write_units() {
    local _q; _q=$(_awg_quick_unit)
    # PartOf: перезапуск интерфейса перезапускает и маршруты.
    cat > "/etc/systemd/system/${AWG_ROUTE_UNIT}" <<EOF
[Unit]
Description=MTProxyL AWG policy routing (${AWG_IFACE})
After=${_q}
Requires=${_q}
PartOf=${_q}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip route replace default dev ${AWG_IFACE} table ${AWG_RT_TABLE}; ip rule del fwmark ${AWG_FWMARK}/${AWG_FWMARK} lookup ${AWG_RT_TABLE} 2>/dev/null; ip rule add fwmark ${AWG_FWMARK}/${AWG_FWMARK} lookup ${AWG_RT_TABLE}; if ip -6 addr show dev ${AWG_IFACE} scope global | grep -q inet6; then ip -6 route replace default dev ${AWG_IFACE} table ${AWG_RT_TABLE}; ip -6 rule del fwmark ${AWG_FWMARK}/${AWG_FWMARK} lookup ${AWG_RT_TABLE} 2>/dev/null; ip -6 rule add fwmark ${AWG_FWMARK}/${AWG_FWMARK} lookup ${AWG_RT_TABLE}; fi; true'
ExecStartPost=/bin/sh $(_awg_nft_script)
ExecStop=/bin/sh -c 'ip rule del fwmark ${AWG_FWMARK}/${AWG_FWMARK} lookup ${AWG_RT_TABLE} 2>/dev/null; ip -6 rule del fwmark ${AWG_FWMARK}/${AWG_FWMARK} lookup ${AWG_RT_TABLE} 2>/dev/null; ip route flush table ${AWG_RT_TABLE} 2>/dev/null; ip -6 route flush table ${AWG_RT_TABLE} 2>/dev/null; /usr/sbin/nft delete table inet ${AWG_NFT_TABLE} 2>/dev/null; true'

[Install]
WantedBy=multi-user.target
EOF
    cat > "/etc/systemd/system/${AWG_WATCH_UNIT}.service" <<EOF
[Unit]
Description=MTProxyL AWG tunnel watchdog

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR:-/opt/mtproxyl}/mtproxyl.sh awg watch
EOF
    cat > "/etc/systemd/system/${AWG_WATCH_UNIT}.timer" <<EOF
[Unit]
Description=MTProxyL AWG tunnel watchdog timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
}

_awg_remove_units() {
    systemctl disable --now "${AWG_WATCH_UNIT}.timer" "${AWG_ROUTE_UNIT}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${AWG_ROUTE_UNIT}" "/etc/systemd/system/${AWG_WATCH_UNIT}.service" \
        "/etc/systemd/system/${AWG_WATCH_UNIT}.timer"
    systemctl daemon-reload 2>/dev/null || true
    nft delete table inet "$AWG_NFT_TABLE" 2>/dev/null || true
}

_awg_route_ready() {
    grep -q "lookup ${AWG_RT_TABLE}" <<< "$(ip rule show 2>/dev/null)" \
        && nft list table inet "$AWG_NFT_TABLE" >/dev/null 2>&1
}

# ── Движок и middle proxy ───────────────────────────────────────────────────

# Строки для [general] нашего конфига: ME считает ключи от адреса выхода,
# а STUN идёт мимо туннеля и нашёл бы не тот адрес.
awg_general_toml() {
    [ -f "$(_awg_state_file)" ] || return 0
    awg_load
    [ "$AWG_ENABLED" = true ] && [ "$AWG_ME_MODE" = natip ] && [ -n "$AWG_EGRESS_IP" ] || return 0
    printf 'middle_proxy_nat_ip = "%s"\nmiddle_proxy_nat_probe = false\n' "$AWG_EGRESS_IP"
}

_awg_toml_raw() {
    local _key="$1" _section="$2" _file="$3"
    awk -v sect="[${_section}]" -v k="$_key" '
        { t = $0; sub(/^[[:space:]]+/, "", t) }
        t ~ /^\[/ { insect = (t == sect); next }
        insect && t ~ ("^" k "[[:space:]]*=") { sub(/^[^=]*=[[:space:]]*/, "", t); sub(/[[:space:]]+#.*$/, "", t); print t; found = 1; exit }
        END { if (!found) print "~" }
    ' "$_file" 2>/dev/null
}

_awg_target_restore_key() {
    local _key="$1" _orig="$2" _cfg="$DETECTED_CONFIG_PATH"
    if [ -z "$_orig" ]; then return 0; fi
    if [ "$_orig" = "~" ]; then
        _toml_safe_unset "$_key" general "$_cfg" || true
    else
        _toml_safe_set "$_key" "$_orig" general "$_cfg" || true
    fi
}

_awg_wait_dc() {
    _AWG_DC_PCT=""
    declare -F _engine_api_get >/dev/null || return 0
    local _i _json _sum
    echo -e "  ${DIM}Ждём, пока движок поднимет связь с дата-центрами (до 90 секунд)...${NC}"
    for _i in $(seq 1 18); do
        sleep 5
        _json=$(_engine_api_get "/v1/stats/dcs" 2>/dev/null) || continue
        grep -qE '"middle_proxy_enabled"[[:space:]]*:[[:space:]]*true' <<< "$_json" || { _AWG_DC_PCT=""; return 0; }
        _sum=$(_dc_summary "$(_dc_rows "$_json")")
        _AWG_DC_PCT=$(cut -d'|' -f2 <<< "$_sum")
        [ "${_AWG_DC_PCT:-0}" -ge 80 ] && break
    done
    return 0
}

_awg_restart_engine() {
    if [ "$AWG_ENGINE_ROUTED" = target ]; then
        restart_target >/dev/null 2>&1
    else
        generate_telemt_config >/dev/null || { log_error "Не удалось пересобрать конфиг движка"; return 1; }
        if is_proxy_running; then restart_proxy_container >/dev/null 2>&1 || return 1; fi
    fi
    return 0
}

_awg_owns_engine_config() { _donor_owns_engine_config; }
_awg_target_editable()    { _donor_target_editable; }

_awg_manual_hint() {
    local _cfg; _cfg=$(_engine_config_path 2>/dev/null)
    echo ""
    log_info "Трафик до Telegram уже идёт через туннель. Конфиг движка MTProxyL здесь не правит"
    if _warp_me_enabled; then
        echo -e "  ${DIM}Для middle proxy допишите в [general] ${_cfg:-конфига движка} и перезапустите движок:${NC}"
        echo -e "  ${DIM}middle_proxy_nat_ip = \"${AWG_EGRESS_IP}\"${NC}"
        echo -e "  ${DIM}middle_proxy_nat_probe = false${NC}"
    else
        echo -e "  ${DIM}Перезапустите движок, чтобы старые соединения переоткрылись через туннель.${NC}"
    fi
}

# ME не поднялся: выключаем только с согласия.
_awg_me_fallback() {
    local _allow="$1"
    echo ""
    log_warn "Middle proxy не поднялся через туннель (покрытие ${_AWG_DC_PCT:-0}%)"
    echo -e "  ${DIM}Ключи ME выводятся из адреса и порта выхода. Если сервер AWG меняет порт${NC}"
    echo -e "  ${DIM}при NAT или выход плавает между адресами, стороны считают разные ключи.${NC}"
    echo -e "  ${DIM}Без ME движок ходит к дата-центрам напрямую; рекламная метка (ad_tag)${NC}"
    echo -e "  ${DIM}при этом не действует.${NC}"
    if [ "${MTPROXYL_ASSUME_YES:-}" = "1" ]; then
        if [ "$_allow" != true ]; then
            log_info "ME оставлен включённым. Выключить: mtproxyl awg on ${AWG_ACTIVE} --allow-disable-me"
            return 0
        fi
    else
        local _yn; read_line _yn "  ${BOLD}Выключить middle proxy? [y/N]:${NC} "
        [[ "$_yn" =~ ^[yY] ]] || { log_info "ME оставлен включённым — проверьте позже: mtproxyl dc"; return 0; }
    fi
    if [ "$AWG_ENGINE_ROUTED" = target ]; then
        _toml_safe_set use_middle_proxy false general "$DETECTED_CONFIG_PATH" || { log_error "Не удалось выключить ME в конфиге цели"; return 1; }
        AWG_ME_DISABLED="target"
    else
        handle_expert_command set general use_middle_proxy false --no-apply >/dev/null || { log_error "Не удалось выключить middle proxy"; return 1; }
        AWG_ME_DISABLED="manager"
    fi
    AWG_ME_MODE=""; awg_save
    _awg_restart_engine || return 1
    log_success "Middle proxy выключен — движок идёт к дата-центрам напрямую через туннель"
}

_awg_route_engine() {
    local _allow="$1" _me=false
    _warp_me_enabled && _me=true
    if _awg_owns_engine_config; then
        AWG_ENGINE_ROUTED="manager"
        AWG_ME_MODE=""; [ "$_me" = true ] && AWG_ME_MODE="natip"
        awg_save
        _awg_restart_engine || return 1
    elif _awg_target_editable; then
        AWG_ENGINE_ROUTED="target"
        if [ "$_me" = true ]; then
            backup_target_config "awg" "true" || return 1
            local _cfg="$DETECTED_CONFIG_PATH"
            AWG_TARGET_ORIG_NATIP=$(_awg_toml_raw middle_proxy_nat_ip general "$_cfg")
            AWG_TARGET_ORIG_PROBE=$(_awg_toml_raw middle_proxy_nat_probe general "$_cfg")
            _toml_safe_set middle_proxy_nat_ip "\"${AWG_EGRESS_IP}\"" general "$_cfg" \
                && _toml_safe_set middle_proxy_nat_probe false general "$_cfg" \
                || { log_error "Не удалось изменить конфиг цели"; cp "$TARGET_CONFIG_BACKUP" "$_cfg" 2>/dev/null; return 1; }
            AWG_ME_MODE="natip"
            log_info "В [general] конфига цели записан адрес выхода для ME, копия: ${TARGET_CONFIG_BACKUP}"
        fi
        awg_save
        _awg_restart_engine
    else
        AWG_ENGINE_ROUTED=""; awg_save
        _awg_manual_hint
        return 0
    fi
    if [ "$_me" = true ]; then
        _awg_wait_dc
        if [ -n "$_AWG_DC_PCT" ] && [ "$_AWG_DC_PCT" -ge 50 ]; then
            log_success "Покрытие дата-центров через туннель: ${_AWG_DC_PCT}%"
        else
            _awg_me_fallback "$_allow"
        fi
    else
        log_success "Движок перезапущен и идёт к Telegram через туннель"
    fi
    return 0
}

_awg_unroute_engine() {
    case "$AWG_ENGINE_ROUTED" in
        manager)
            AWG_ME_MODE=""
            if [ "$AWG_ME_DISABLED" = manager ]; then
                MTPROXYL_MODE=manager handle_expert_command clear general use_middle_proxy --no-apply >/dev/null 2>&1 \
                    && log_info "Middle proxy включён обратно"
            fi
            AWG_ME_DISABLED=""; AWG_ENGINE_ROUTED=""; awg_save
            if _awg_owns_engine_config; then
                generate_telemt_config >/dev/null 2>&1 || true
                if is_proxy_running; then restart_proxy_container >/dev/null 2>&1 || true; fi
            fi
            ;;
        target)
            if _awg_target_editable; then
                backup_target_config "awg-off" "true" || true
                if [ "$AWG_ME_MODE" = natip ]; then
                    _awg_target_restore_key middle_proxy_nat_ip "$AWG_TARGET_ORIG_NATIP"
                    _awg_target_restore_key middle_proxy_nat_probe "$AWG_TARGET_ORIG_PROBE"
                fi
                if [ "$AWG_ME_DISABLED" = target ]; then
                    _toml_safe_set use_middle_proxy true general "$DETECTED_CONFIG_PATH" \
                        && log_info "Middle proxy в конфиге цели включён обратно"
                fi
                is_proxy_running && restart_target >/dev/null 2>&1
            fi
            AWG_ME_MODE=""; AWG_ME_DISABLED=""; AWG_ENGINE_ROUTED=""
            AWG_TARGET_ORIG_NATIP=""; AWG_TARGET_ORIG_PROBE=""; awg_save
            ;;
        *)
            AWG_ME_MODE=""; awg_save
            ;;
    esac
}

# Адрес выхода сменился — ME нужен новый.
_awg_update_egress() {
    local _new="$1"
    [ -n "$_new" ] && [ "$_new" != "$AWG_EGRESS_IP" ] || return 0
    local _old="$AWG_EGRESS_IP"
    AWG_EGRESS_IP="$_new"; AWG_EGRESS_AT=$(date +%s); awg_save
    [ "$AWG_ME_MODE" = natip ] || return 0
    log_info "Адрес выхода туннеля сменился: ${_old:-?} → ${_new}, обновляем конфиг движка"
    if [ "$AWG_ENGINE_ROUTED" = target ] && _awg_target_editable; then
        _toml_safe_set middle_proxy_nat_ip "\"${_new}\"" general "$DETECTED_CONFIG_PATH" || return 1
    fi
    _awg_restart_engine
}

# ── Команды ────────────────────────────────────────────────────────────────

_awg_guard_conflicts() {
    if [ "${WARP_ENABLED:-false}" = "true" ]; then
        log_error "Включён маршрут через WARP — сначала выключите его: mtproxyl warp off"
        return 1
    fi
    if declare -F donor_load >/dev/null; then
        donor_load
        if [ "$DONOR_ENABLED" = "true" ]; then
            log_error "Включён туннель до донора — сначала выключите его: mtproxyl donor off"
            return 1
        fi
    fi
    return 0
}

_awg_ensure_installed() {
    if command -v awg-quick >/dev/null 2>&1 && modprobe amneziawg 2>/dev/null; then
        return 0
    fi
    log_info "Устанавливаем AmneziaWG..."
    _donor_run_agent local install || { log_error "AmneziaWG не установился"; return 1; }
    command -v awg-quick >/dev/null 2>&1
}

# ── AWG 3.x ─────────────────────────────────────────────────────────────────

_awg_conf_level() { _awg_conf_info "$(_awg_store)/${1}.conf" | cut -d'|' -f5; }

_awg_module_v3() {
    local _v; _v=$(cat /sys/module/amneziawg/version 2>/dev/null) || return 1
    [[ "$_v" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    [ $(( BASH_REMATCH[1] * 100 + BASH_REMATCH[2] )) -ge 301 ]
}

_awg_tools_v3() { grep -q 'header-protection-key' <<< "$(awg set 2>&1)"; }

_awg_supports_v3() { _awg_tools_v3 && _awg_module_v3; }

# Конфиг 3.x требует свежих tools и модуля: обновляем пакеты из PPA Amnezia.
_awg_ensure_v3() {
    _awg_supports_v3 && return 0
    log_info "Конфиг AWG 3.x — обновляем AmneziaWG..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq --only-upgrade amneziawg-tools amneziawg-dkms >/dev/null 2>&1 || true
    if ! _awg_tools_v3; then
        log_error "Установленный awg не понимает AWG 3.x — пакеты AmneziaWG не из PPA Amnezia?"
        return 1
    fi
    _awg_module_v3 && return 0
    if [ -n "$(ip -o link show type amneziawg 2>/dev/null)" ]; then
        log_error "Модуль AmneziaWG обновлён, но загружен старый: выключите туннели AmneziaWG или перезапустите сервер"
        return 1
    fi
    modprobe -r amneziawg 2>/dev/null; modprobe amneziawg 2>/dev/null
    _awg_module_v3 || { log_error "Модуль AmneziaWG не поддерживает AWG 3.x — нужен перезапуск сервера"; return 1; }
    log_success "AmneziaWG обновлён, AWG 3.x поддерживается"
}

_awg_need_v3() {
    [ "$(_awg_conf_level "$1")" = 3 ] || return 0
    _awg_ensure_v3
}

# ── Несколько выходов ───────────────────────────────────────────────────────

AWG_TEST_IFACE="mtpawgt"
AWG_FAILOVER_AFTER="${AWG_FAILOVER_AFTER:-180}"
AWG_FAILBACK_EVERY="${AWG_FAILBACK_EVERY:-600}"

# Порядок выходов; у состояний до 1.7.15 — один активный.
_awg_order_list() {
    local _n
    tr ',' '\n' <<< "${AWG_ORDER:-$AWG_ACTIVE}" | while IFS= read -r _n; do
        _awg_valid_name "$_n" && [ -f "$(_awg_store)/${_n}.conf" ] && echo "$_n"
    done
}

# Кандидаты после активного, по кругу.
_awg_next_candidates() {
    local -a _o=(); mapfile -t _o < <(_awg_order_list)
    local _i _n=${#_o[@]} _at=-1
    for _i in "${!_o[@]}"; do [ "${_o[$_i]}" = "$AWG_ACTIVE" ] && _at=$_i; done
    for _i in $(seq 1 "$_n"); do
        local _c="${_o[$(( (_at + _i) % _n ))]}"
        [ "$_c" = "$AWG_ACTIVE" ] || echo "$_c"
    done
}

_awg_parse_names() {
    _AWG_NAMES=()
    local _t _nm
    for _t in "$@"; do
        if [[ "$_t" == */* ]]; then
            _nm=$(_awg_name_from_path "$_t")
            [ "$AWG_ENABLED" = true ] && [ "$AWG_ACTIVE" = "$_nm" ] && _nm="${_nm:0:28}-new"
            awg_import "$_t" --name "$_nm" >/dev/null 2>&1 || { awg_import "$_t" --name "$_nm"; return 1; }
            _t="$_nm"
        fi
        _awg_valid_name "$_t" && [ -f "$(_awg_store)/${_t}.conf" ] \
            || { log_error "Конфига «${_t}» нет: mtproxyl awg list"; return 1; }
        [[ " ${_AWG_NAMES[*]} " == *" ${_t} "* ]] || _AWG_NAMES+=("$_t")
    done
}

_awg_tg_ok() {
    [ "$(curl -4 -s -m 15 -o /dev/null -w '%{http_code}' --interface "$1" \
        https://core.telegram.org/getProxyConfig 2>/dev/null)" = 200 ]
}

# Проверка запасного на временном интерфейсе: основной туннель не трогаем.
_awg_test_config() {
    local _name="$1" _src _tmp _ok=1 _a _i _ts
    _src="$(_awg_store)/${_name}.conf"
    [ -f "$_src" ] || return 1
    if [ "$(_awg_conf_level "$_name")" = 3 ] && ! _awg_supports_v3; then return 1; fi
    ip link delete "$AWG_TEST_IFACE" 2>/dev/null
    _tmp=$(mktemp) || return 1
    awk '/^#/ || /^(Address|MTU) = / { next } { print }' "$_src" > "$_tmp"
    if ip link add "$AWG_TEST_IFACE" type amneziawg 2>/dev/null && awg setconf "$AWG_TEST_IFACE" "$_tmp" 2>/dev/null; then
        for _a in $(sed -n 's/^Address = //p' "$_src" | tr ',' ' '); do
            ip address add "$_a" dev "$AWG_TEST_IFACE" 2>/dev/null
        done
        ip link set mtu "${AWG_MTU:-1280}" up dev "$AWG_TEST_IFACE" 2>/dev/null
        for _i in $(seq 1 15); do
            _ts=$(awg show "$AWG_TEST_IFACE" latest-handshakes 2>/dev/null | awk '$2 > m {m = $2} END {print m + 0}')
            [ "${_ts:-0}" -gt 0 ] && break
            curl -4 -s -m 1 -o /dev/null --interface "$AWG_TEST_IFACE" http://1.1.1.1/ 2>/dev/null || true
            sleep 1
        done
        [ "${_ts:-0}" -gt 0 ] && _awg_tg_ok "$AWG_TEST_IFACE" && _ok=0
    fi
    ip link delete "$AWG_TEST_IFACE" 2>/dev/null
    rm -f "$_tmp"
    return $_ok
}

# Поднять конфиг на основном интерфейсе и убедиться, что Telegram отвечает.
_awg_bring_up() {
    AWG_ACTIVE="$1"; awg_save
    _awg_write_sys_conf || return 1
    _awg_tunnel_up || return 1
    _awg_probe || { log_warn "«$1»: через туннель не открывается Telegram (ответ: ${_AWG_PROBE_TG:-нет})"; return 1; }
}

_awg_switch_to() {
    local _to="$1" _reason="$2" _from="$AWG_ACTIVE"
    _awg_need_v3 "$_to" || return 1
    log_info "Переключаем выход: ${_from:-?} → ${_to} (${_reason})"
    if ! _awg_bring_up "$_to"; then
        log_warn "«${_to}» не поднялся — возвращаем «${_from}»"
        [ -n "$_from" ] && _awg_bring_up "$_from" >/dev/null 2>&1
        return 1
    fi
    _awg_tunnel_has_v6 && AWG_IPV6="yes" || AWG_IPV6="no"
    AWG_SWITCH_AT=$(date +%s); AWG_SWITCH_FROM="$_from"; AWG_SWITCH_TO="$_to"; AWG_SWITCH_REASON="$_reason"
    AWG_FAIL_SINCE=""; AWG_CHECK_AT=$(date +%s); AWG_CHECK_RESULT="ok"; AWG_CHECK_ERROR=""
    awg_save
    logger -t mtproxyl-awg "switched ${_from} -> ${_to}: ${_reason}" 2>/dev/null || true
    # Новый выход — новый адрес для ME; движок перезапускается.
    if [ -n "$_AWG_PROBE_EGRESS" ] && [ "$_AWG_PROBE_EGRESS" != "$AWG_EGRESS_IP" ]; then
        _awg_update_egress "$_AWG_PROBE_EGRESS"
    elif [ "$AWG_ENGINE_ROUTED" = manager ] || [ "$AWG_ENGINE_ROUTED" = target ]; then
        _awg_restart_engine
    fi
    log_success "Выход переключён на «${_to}»"
}

_awg_failover() {
    local _reason="$1" _c
    while IFS= read -r _c; do
        [ -n "$_c" ] || continue
        _awg_test_config "$_c" || { log_info "«${_c}» тоже не отвечает"; continue; }
        _awg_switch_to "$_c" "$_reason" && return 0
    done < <(_awg_next_candidates)
    AWG_FAIL_SINCE=$(date +%s); AWG_CHECK_RESULT="fail"; AWG_CHECK_ERROR="ни один выход не отвечает"
    awg_save
    return 1
}

awg_enable() (
    check_root
    local _mtu="" _allow=false _arg
    local -a _targets=()
    while [ $# -gt 0 ]; do
        _arg="$1"; shift
        case "$_arg" in
            --mtu) _mtu="${1:-}"; shift ;;
            --allow-disable-me) _allow=true ;;
            --yes) MTPROXYL_ASSUME_YES=1 ;;
            -*) log_error "Неизвестный параметр: ${_arg}"; return 1 ;;
            *) _targets+=("$_arg") ;;
        esac
    done
    if [ -n "$_mtu" ] && [ "$_mtu" != auto ] && ! _awg_valid_mtu "$_mtu"; then
        log_error "MTU: число от 1200 до 1500 или auto"; return 1
    fi
    _awg_guard_conflicts || return 1

    awg_load
    if [ ${#_targets[@]} -eq 0 ]; then
        mapfile -t _targets < <(_awg_order_list)
        [ ${#_targets[@]} -gt 0 ] || { log_error "Укажите конфиг: mtproxyl awg on <имя или путь> [запасной ...]"; return 1; }
    fi
    _awg_parse_names "${_targets[@]}" || return 1
    [ ${#_AWG_NAMES[@]} -le 8 ] || { log_error "Не больше 8 выходов"; return 1; }

    _awg_ensure_installed || return 1

    # Смена конфига на ходу: старый маршрут снимаем целиком.
    local _was_enabled="$AWG_ENABLED"
    if [ "$_was_enabled" = true ]; then
        systemctl stop "$AWG_ROUTE_UNIT" >/dev/null 2>&1 || true
    fi
    AWG_ORDER=$(IFS=,; echo "${_AWG_NAMES[*]}")
    case "$_mtu" in auto) AWG_MTU="" ;; "") ;; *) AWG_MTU="$_mtu" ;; esac
    awg_save

    local _name _up=""
    for _name in "${_AWG_NAMES[@]}"; do
        _awg_need_v3 "$_name" || continue
        log_info "Поднимаем туннель ${AWG_IFACE} по конфигу «${_name}»..."
        if _awg_bring_up "$_name"; then _up="$_name"; break; fi
        [ ${#_AWG_NAMES[@]} -gt 1 ] && log_warn "«${_name}» не отвечает — пробуем следующий"
    done
    if [ -z "$_up" ]; then
        _awg_tunnel_down
        [ "$_was_enabled" = true ] && { _awg_unroute_engine; AWG_ENABLED="false"; awg_save; _awg_remove_units; }
        log_error "Ни один выход не поднялся"
        echo -e "  ${DIM}Сервер AWG должен выпускать трафик в интернет (NAT на его стороне).${NC}"
        return 1
    fi
    log_success "Telegram через «${_up}» отвечает, адрес выхода: ${_AWG_PROBE_EGRESS:-не определён}"
    if [ -z "$_AWG_PROBE_EGRESS" ] && _warp_me_enabled; then
        log_warn "Адрес выхода не определён — middle proxy может не подняться"
    fi

    warp_update_cidr >/dev/null 2>&1 || true
    _awg_generate_nft || return 1
    _awg_write_units
    systemctl enable "$AWG_ROUTE_UNIT" >/dev/null 2>&1
    systemctl restart "$AWG_ROUTE_UNIT" >/dev/null 2>&1 || {
        log_error "Не удалось включить маршрут через туннель"
        journalctl -u "$AWG_ROUTE_UNIT" -n 5 --no-pager 2>/dev/null | sed 's/^/    /'
        _awg_remove_units; _awg_tunnel_down
        return 1
    }
    systemctl enable --now "${AWG_WATCH_UNIT}.timer" >/dev/null 2>&1 || true

    AWG_ENABLED="true"; AWG_ENABLED_AT=$(date +%s)
    AWG_EGRESS_IP="$_AWG_PROBE_EGRESS"; AWG_EGRESS_AT=$(date +%s)
    _awg_tunnel_has_v6 && AWG_IPV6="yes" || AWG_IPV6="no"
    AWG_CHECK_AT=$(date +%s); AWG_CHECK_RESULT="ok"; AWG_CHECK_ERROR=""
    AWG_FAIL_SINCE=""; AWG_PRIMARY_AT=$(date +%s)
    awg_save
    log_success "Подсети Telegram идут через ${AWG_IFACE}, остальной трафик сервера — напрямую"
    [ ${#_AWG_NAMES[@]} -gt 1 ] && log_info "Порядок выходов: ${AWG_ORDER//,/ → }"
    _awg_route_engine "$_allow"
)

# Порядок выходов без перезапуска; активный вне списка — переключаемся сразу.
awg_order() (
    check_root
    [ $# -gt 0 ] || { log_error "Укажите выходы: mtproxyl awg order <основной> [запасной ...]"; return 1; }
    awg_load
    _awg_parse_names "$@" || return 1
    [ ${#_AWG_NAMES[@]} -le 8 ] || { log_error "Не больше 8 выходов"; return 1; }
    AWG_ORDER=$(IFS=,; echo "${_AWG_NAMES[*]}")
    if [ "$AWG_ENABLED" != true ]; then
        AWG_ACTIVE="${_AWG_NAMES[0]}"; awg_save
        log_success "Порядок выходов: ${AWG_ORDER//,/ → }"
        return 0
    fi
    # Основной проверим при следующем запуске сторожа.
    AWG_PRIMARY_AT=0; awg_save
    log_success "Порядок выходов: ${AWG_ORDER//,/ → }"
    if [[ ",${AWG_ORDER}," != *",${AWG_ACTIVE},"* ]]; then
        local _c
        for _c in "${_AWG_NAMES[@]}"; do
            _awg_test_config "$_c" && _awg_switch_to "$_c" "выход убран из списка" && return 0
        done
        log_warn "Ни один выход из списка не отвечает — остаёмся на «${AWG_ACTIVE}»"
    fi
    return 0
)

awg_disable() (
    check_root
    awg_load
    if [ "$AWG_ENABLED" != true ] && ! ip link show "$AWG_IFACE" >/dev/null 2>&1; then
        log_info "Выход через AWG уже выключен"
        return 0
    fi
    _awg_remove_units
    _awg_tunnel_down
    AWG_ENABLED="false"; awg_save
    _awg_unroute_engine
    log_success "Выход через AWG выключен — движок идёт к Telegram напрямую"
)

awg_check() {
    local _json=false; [ "${1:-}" = "--json" ] && _json=true
    awg_load
    local _res="ok" _err="" _age=""
    if [ "$AWG_ENABLED" != true ]; then
        _res="off"
    elif ! ip link show "$AWG_IFACE" >/dev/null 2>&1; then
        _res="fail"; _err="интерфейс не поднят"
    elif ! _age=$(_awg_handshake_age) || [ "$_age" -gt 300 ]; then
        _res="fail"; _err="нет рукопожатия с сервером"
    elif ! _awg_route_ready; then
        _res="fail"; _err="нет правил маршрута"
    elif ! _awg_probe; then
        _res="fail"; _err="Telegram через туннель не отвечает (${_AWG_PROBE_TG:-нет ответа})"
    fi
    if [ "$_res" = ok ] && [ -n "${_AWG_PROBE_EGRESS:-}" ]; then
        _awg_update_egress "$_AWG_PROBE_EGRESS" >/dev/null 2>&1 || true
    fi
    if [ "$_res" != off ]; then
        AWG_CHECK_AT=$(date +%s); AWG_CHECK_RESULT="$_res"; AWG_CHECK_ERROR="$_err"
        [ "$(id -u)" = 0 ] && awg_save
    fi
    if [ "$_json" = true ]; then
        printf '{"result":"%s","error":"%s","egress_ip":"%s","handshake_age":%s}\n' "$_res" "$(json_escape "$_err")" \
            "$(json_escape "${_AWG_PROBE_EGRESS:-$AWG_EGRESS_IP}")" "${_age:-null}"
    else
        case "$_res" in
            ok)  log_success "Туннель «${AWG_ACTIVE}» работает, Telegram отвечает, выход ${_AWG_PROBE_EGRESS:-$AWG_EGRESS_IP}" ;;
            off) log_info "Выход через AWG выключен" ;;
            *)   log_error "Туннель не работает: ${_err}" ;;
        esac
    fi
    [ "$_res" != fail ]
}

# Таймер раз в минуту: чинит туннель, переключает на запасной и обратно,
# следит за адресом выхода.
awg_watch() {
    awg_load
    [ "$AWG_ENABLED" = true ] || return 0
    local _now _age _healthy=false
    _now=$(date +%s)
    if ip link show "$AWG_IFACE" >/dev/null 2>&1; then
        if ! _age=$(_awg_handshake_age) || [ "$_age" -gt 180 ]; then
            # Без трафика рукопожатие не обновляется — сначала будим туннель.
            curl -4 -s -m 3 -o /dev/null --interface "$AWG_IFACE" http://1.1.1.1/ 2>/dev/null || true
            sleep 2
        fi
        _age=$(_awg_handshake_age) && [ "$_age" -le 180 ] && _awg_tg_ok "$AWG_IFACE" && _healthy=true
    fi

    if [ "$_healthy" != true ]; then
        [ -n "$AWG_FAIL_SINCE" ] || { AWG_FAIL_SINCE="$_now"; awg_save; }
        logger -t mtproxyl-awg "exit ${AWG_ACTIVE} unhealthy since ${AWG_FAIL_SINCE}" 2>/dev/null || true
        if [ $(( _now - AWG_FAIL_SINCE )) -ge "$AWG_FAILOVER_AFTER" ] && [ "$(_awg_next_candidates | wc -l)" -gt 0 ]; then
            _awg_failover "«${AWG_ACTIVE}» не отвечает" >/dev/null 2>&1 && return 0
        fi
        systemctl restart "$(_awg_quick_unit)" >/dev/null 2>&1 || true
        return 0
    fi
    if [ -n "$AWG_FAIL_SINCE" ]; then AWG_FAIL_SINCE=""; awg_save; fi
    _awg_route_ready || systemctl restart "$AWG_ROUTE_UNIT" >/dev/null 2>&1 || true

    # Возврат на основной, когда он снова отвечает.
    local _primary; _primary=$(_awg_order_list | head -1)
    if [ -n "$_primary" ] && [ "$_primary" != "$AWG_ACTIVE" ] \
        && [ $(( _now - ${AWG_PRIMARY_AT:-0} )) -ge "$AWG_FAILBACK_EVERY" ]; then
        AWG_PRIMARY_AT="$_now"; awg_save
        if _awg_test_config "$_primary"; then
            _awg_switch_to "$_primary" "основной снова отвечает" >/dev/null 2>&1 && return 0
        fi
    fi

    if [ $(( _now - ${AWG_EGRESS_AT:-0} )) -ge 600 ]; then
        local _ip; _ip=$(curl -4 -s -m 10 --interface "$AWG_IFACE" https://api.ipify.org 2>/dev/null)
        if validate_ip_literal "$_ip" 2>/dev/null; then
            if [ "$_ip" != "$AWG_EGRESS_IP" ]; then
                _awg_update_egress "$_ip" >/dev/null 2>&1 || true
            else
                AWG_EGRESS_AT="$_now"; awg_save
            fi
        fi
    fi
}

# Сводки импортированных конфигов по текущему разбору (уровень AWG с 1.7.15).
_awg_renormalize_store() {
    local _f _tmp
    for _f in "$(_awg_store)"/*.conf; do
        [ -f "$_f" ] || continue
        _tmp=$(mktemp) || return 0
        if _awg_normalize "$_f" > "$_tmp" && ! cmp -s "$_f" "$_tmp"; then
            install -m 600 "$_tmp" "$_f"
        fi
        rm -f "$_tmp"
    done
}

# После mtproxyl update: юниты и правила по текущему коду.
awg_refresh() {
    _awg_renormalize_store
    awg_is_enabled || return 0
    awg_load
    _awg_write_sys_conf || return 0
    _awg_generate_nft || return 0
    _awg_write_units
    systemctl enable "$AWG_ROUTE_UNIT" "${AWG_WATCH_UNIT}.timer" >/dev/null 2>&1 || true
    systemctl start "${AWG_WATCH_UNIT}.timer" >/dev/null 2>&1 || true
    systemctl restart "$AWG_ROUTE_UNIT" >/dev/null 2>&1 || true
}

awg_purge() {
    _awg_remove_units
    _awg_tunnel_down
    rm -f "$(_awg_sys_conf)"
    rm -rf "$(_awg_dir)"
}

awg_menu_line() {
    awg_is_enabled || return 0
    awg_load
    local _state="${RED}туннель лежит${NC}" _age
    if _age=$(_awg_handshake_age) && [ "$_age" -lt 300 ]; then _state="${GREEN}работает${NC}"; fi
    echo -e "  ${BOLD}Выход AWG:${NC}    ${AWG_ACTIVE}, ${_state}"
}

awg_state_label() {
    awg_load
    if [ "$AWG_ENABLED" = true ]; then
        if ip link show "$AWG_IFACE" >/dev/null 2>&1; then echo "через ${AWG_ACTIVE}"; else echo "включён, туннель лежит"; fi
    elif [ -n "$(_awg_list_names)" ]; then
        echo "выключен"
    else
        echo "не настроен"
    fi
}

awg_status_json() {
    awg_load
    local _up=false _age="null" _rx=0 _tx=0 _installed=false _ep="" _addr="" _obf=false _v6="" _lvl="" _rules=false
    command -v awg-quick >/dev/null 2>&1 && _installed=true
    if ip link show "$AWG_IFACE" >/dev/null 2>&1; then
        _up=true
        local _a; _a=$(_awg_handshake_age) && _age="$_a"
        read -r _rx _tx < <(awg show "$AWG_IFACE" transfer 2>/dev/null | awk '{r += $2; t += $3} END {print r + 0, t + 0}')
    fi
    _awg_route_ready && _rules=true
    local _mode_engine="manual"
    if _awg_owns_engine_config; then _mode_engine="manager"
    elif _awg_target_editable; then _mode_engine="target"; fi
    local _donor=false
    if declare -F donor_load >/dev/null; then
        ( donor_load; [ "$DONOR_ENABLED" = true ] ) && _donor=true
    fi
    local _name _first=true _configs=""
    while IFS= read -r _name; do
        [ -n "$_name" ] || continue
        IFS='|' read -r _ep _addr _obf _v6 _lvl < <(_awg_conf_info "$(_awg_store)/${_name}.conf")
        [ "$_first" = true ] || _configs+=","; _first=false
        _configs+=$(printf '{"name":"%s","endpoint":"%s","address":"%s","obfuscation":%s,"awg_version":"%s"}' \
            "$(json_escape "$_name")" "$(json_escape "$_ep")" "$(json_escape "$_addr")" \
            "$([ "$_obf" = yes ] && echo true || echo false)" "$(_awg_level_label "$_lvl")")
    done < <(_awg_list_names)
    printf '{"enabled":%s,"active":"%s","mtu":%s,"iface":"%s","awg_installed":%s,"tunnel_up":%s,"rules":%s,' \
        "$([ "$AWG_ENABLED" = true ] && echo true || echo false)" "$(json_escape "$AWG_ACTIVE")" \
        "${AWG_MTU:-null}" "$AWG_IFACE" "$_installed" "$_up" "$_rules"
    printf '"handshake_age":%s,"rx_bytes":%s,"tx_bytes":%s,"egress_ip":"%s","ipv6":%s,"me_mode":"%s","me_disabled":%s,' \
        "$_age" "${_rx:-0}" "${_tx:-0}" "$(json_escape "$AWG_EGRESS_IP")" \
        "$([ "$AWG_IPV6" = yes ] && echo true || echo false)" "$(json_escape "$AWG_ME_MODE")" \
        "$([ -n "$AWG_ME_DISABLED" ] && echo true || echo false)"
    printf '"engine_mode":"%s","engine_routed":"%s","warp_enabled":%s,"donor_enabled":%s,"enabled_at":%s,' \
        "$_mode_engine" "$(json_escape "$AWG_ENGINE_ROUTED")" \
        "$([ "${WARP_ENABLED:-false}" = true ] && echo true || echo false)" "$_donor" "${AWG_ENABLED_AT:-0}"
    local _order_json; _order_json=$(_awg_order_list | while IFS= read -r _name; do printf '"%s",' "$(json_escape "$_name")"; done)
    printf '"order":[%s],"fail_since":%s,"last_switch":{"at":%s,"from":"%s","to":"%s","reason":"%s"},' \
        "${_order_json%,}" "${AWG_FAIL_SINCE:-0}" "${AWG_SWITCH_AT:-0}" "$(json_escape "$AWG_SWITCH_FROM")" \
        "$(json_escape "$AWG_SWITCH_TO")" "$(json_escape "$AWG_SWITCH_REASON")"
    printf '"check":{"at":%s,"result":"%s","error":"%s"},"configs":[%s]}\n' \
        "${AWG_CHECK_AT:-0}" "$(json_escape "$AWG_CHECK_RESULT")" "$(json_escape "$AWG_CHECK_ERROR")" "$_configs"
}

awg_status() {
    awg_load
    echo ""
    local _names; _names=$(_awg_list_names | paste -sd, - | sed 's/,/, /g')
    echo -e "  ${BOLD}Конфиги:${NC}      ${_names:-${DIM}нет — mtproxyl awg scan / import <файл>${NC}}"
    if [ "$AWG_ENABLED" != true ]; then
        echo -e "  ${BOLD}Состояние:${NC}    ${DIM}выключен${NC}"
        echo ""
        return 0
    fi
    local _ep _addr _obf _v6 _lvl _age
    IFS='|' read -r _ep _addr _obf _v6 _lvl < <(_awg_conf_info "$(_awg_store)/${AWG_ACTIVE}.conf")
    echo -e "  ${BOLD}Активный:${NC}     ${AWG_ACTIVE} — ${_ep}, ${_addr}$(_awg_kind "$_obf" "$_lvl")${AWG_MTU:+, MTU ${AWG_MTU}}"
    local _ord; _ord=$(_awg_order_list | paste -sd, -)
    [[ "$_ord" == *,* ]] && echo -e "  ${BOLD}Порядок:${NC}      ${_ord//,/ → } ${DIM}(запасной — через $((AWG_FAILOVER_AFTER / 60)) мин сбоя)${NC}"
    if [ -n "$AWG_SWITCH_AT" ] && [ "$AWG_SWITCH_AT" != 0 ]; then
        echo -e "  ${BOLD}Переключение:${NC} ${AWG_SWITCH_FROM} → ${AWG_SWITCH_TO} ($(date -d "@${AWG_SWITCH_AT}" '+%d.%m %H:%M' 2>/dev/null)) — ${AWG_SWITCH_REASON}"
    fi
    if ! ip link show "$AWG_IFACE" >/dev/null 2>&1; then
        echo -e "  ${BOLD}Состояние:${NC}    ${YELLOW}интерфейс не поднят${NC}"
    elif _age=$(_awg_handshake_age); then
        echo -e "  ${BOLD}Состояние:${NC}    ${GREEN}поднят${NC}, рукопожатие ${_age} с назад"
    else
        echo -e "  ${BOLD}Состояние:${NC}    ${RED}нет рукопожатия с сервером${NC}"
    fi
    _awg_route_ready || echo -e "  ${BOLD}Маршрут:${NC}      ${RED}правила не применены${NC}"
    [ -n "$AWG_EGRESS_IP" ] && echo -e "  ${BOLD}Выход:${NC}        ${AWG_EGRESS_IP}"
    case "$AWG_ME_MODE:$AWG_ME_DISABLED" in
        natip:*) echo -e "  ${BOLD}Middle proxy:${NC} через адрес выхода ${AWG_EGRESS_IP}" ;;
        *:manager|*:target) echo -e "  ${BOLD}Middle proxy:${NC} ${YELLOW}выключен на время работы через AWG${NC}" ;;
    esac
    case "$AWG_ENGINE_ROUTED" in
        target) echo -e "  ${BOLD}Движок:${NC}       цель реаниматора" ;;
        manager) ;;
        *) echo -e "  ${BOLD}Движок:${NC}       ${YELLOW}конфиг не правится автоматически${NC}" ;;
    esac
    if [ -n "$AWG_CHECK_AT" ] && [ "$AWG_CHECK_AT" != 0 ]; then
        echo -e "  ${BOLD}Проверка:${NC}     ${AWG_CHECK_RESULT} ($(date -d "@${AWG_CHECK_AT}" '+%d.%m %H:%M' 2>/dev/null))${AWG_CHECK_ERROR:+ — ${AWG_CHECK_ERROR}}"
    fi
    echo ""
}

awg_help() {
    echo -e "  ${BOLD}Выход к Telegram через свой сервер AmneziaWG:${NC}"
    echo -e "    ${GREEN}awg status${NC} [--json]                 Состояние"
    echo -e "    ${GREEN}awg scan${NC} [--json]                   Найти конфиги на сервере"
    echo -e "    ${GREEN}awg import${NC} <файл|-> [--name N]      Импортировать клиентский конфиг"
    echo -e "    ${GREEN}awg list${NC}                            Импортированные конфиги"
    echo -e "    ${GREEN}awg on${NC} <имя|файл> [запасной ...] [--mtu N|auto] [--allow-disable-me]"
    echo -e "                                        Включить: Telegram через туннель"
    echo -e "    ${GREEN}awg order${NC} <основной> [запасной ...]  Порядок выходов без перезапуска"
    echo -e "    ${GREEN}awg off${NC}                             Выключить"
    echo -e "    ${GREEN}awg check${NC} [--json]                  Проверить туннель и выход"
    echo -e "    ${GREEN}awg remove${NC} <имя>                    Удалить импортированный конфиг"
}

handle_awg_command() (
    case "${1:-status}" in
        status|scan|list|help|-h|--help) ;;
        *)
            check_root
            install -d -m 700 "$(_awg_dir)" || return 1
            local _lock
            exec {_lock}>"$(_awg_dir)/.lock" || return 1
            if ! flock -n "$_lock"; then
                [ "${1:-}" = watch ] && return 0
                log_error "Другая операция с AWG уже выполняется"
                return 1
            fi
            ;;
    esac
    local _sub="${1:-status}"; shift 2>/dev/null || true
    case "$_sub" in
        status)
            if [ "${1:-}" = "--json" ]; then awg_status_json; else awg_status; fi ;;
        scan)          awg_scan "$@" ;;
        import)        awg_import "$@" ;;
        list)          _awg_list_names ;;
        on|enable)     awg_enable "$@" ;;
        order)         awg_order "$@" ;;
        off|disable)   awg_disable ;;
        check)         awg_check "$@" ;;
        remove)        awg_remove "$@" ;;
        watch)         awg_watch ;;
        refresh)       awg_refresh ;;
        help|-h|--help) awg_help ;;
        *) log_error "Неизвестная команда: awg ${_sub}"; awg_help; return 1 ;;
    esac
)
