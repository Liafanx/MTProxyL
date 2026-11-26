#!/bin/bash
# MTProxyL — разбор ссылок VLESS в конфиг Xray-core.
#
# Часть правил повторяет lib/outbound-parse.py из Liafanx/AZ-WARP (MIT):
# те же правила для Reality, ws/grpc/httpupgrade и early data. Отличие —
# вывод под Xray: VLESS Encryption, XHTTP, mKCP и pqv (ML-DSA-65).
# Зависимость — jq: он уже ставится установщиком MTProxyL.

declare -A V_Q=()

_vless_parse_fail() { printf '%s\n' "$*" >&2; return 1; }

_vless_url_decode() {
    local s="${1//\\/\\\\}"
    printf '%b' "${s//%/\\x}"
}

_vless_query_decode() {
    local s="${1//+/%20}"
    _vless_url_decode "$s"
}

_vless_query_parse() {
    local q="$1" part k v
    local -a parts=()
    V_Q=()
    [ -n "$q" ] || return 0
    IFS='&' read -r -a parts <<< "$q"
    for part in "${parts[@]}"; do
        k=${part%%=*}
        v=${part#*=}
        k=$(_vless_query_decode "$k")
        v=$(_vless_query_decode "$v")
        [ -n "$k" ] || continue
        [ -n "$v" ] || continue
        [ -n "${V_Q[$k]+x}" ] && continue
        V_Q["$k"]="$v"
    done
}

_vless_q() {
    local n
    for n in "$@"; do
        if [ -n "${V_Q[$n]:-}" ]; then
            printf '%s' "${V_Q[$n]}"
            return 0
        fi
    done
}

_vless_truthy() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
    esac
    return 1
}

_vless_split_host_port() {
    local hp="$1" host port rest
    if [[ "$hp" == \[* ]]; then
        [[ "$hp" == *\]* ]] || { _vless_parse_fail "адрес: незакрытая квадратная скобка"; return 1; }
        host=${hp#\[}
        host=${host%%\]*}
        rest=${hp#*\]}
        [[ "$rest" == :* ]] || { _vless_parse_fail "адрес: не указан порт"; return 1; }
        port=${rest#:}
    else
        [[ "$hp" == *:* ]] || { _vless_parse_fail "адрес: нужен host:port"; return 1; }
        host=${hp%:*}
        port=${hp##*:}
    fi
    [[ -n "$host" && "$host" =~ ^[A-Za-z0-9._:-]+$ ]] \
        || { _vless_parse_fail "адрес: недопустимые символы"; return 1; }
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
        || { _vless_parse_fail "порт: 1..65535"; return 1; }
    V_HOST=$host
    V_PORT=$((10#$port))
}

_vless_check_id() {
    local uid="$1" n
    [[ "$uid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && return 0
    n=$(printf '%s' "$uid" | wc -c)
    [ "$n" -ge 1 ] && [ "$n" -le 30 ] \
        || { _vless_parse_fail "id: UUID или строка 1..30 байт (Xray)"; return 1; }
    [[ "$uid" != */* && "$uid" != *[[:cntrl:][:space:]]* ]] \
        || { _vless_parse_fail "id: недопустимые символы"; return 1; }
}

_vless_check_b64key() {
    local pbk="$1" s pad n
    [[ "$pbk" =~ ^[A-Za-z0-9_-]+=*$ ]] \
        || { _vless_parse_fail "pbk (публичный ключ Reality): неверный формат"; return 1; }
    s=${pbk%=}
    s=${s//-/+}
    s=${s//_/\/}
    pad=$(( (4 - ${#s} % 4) % 4 ))
    if [ "$pad" -gt 0 ]; then
        s+=$(printf '=%.0s' $(seq 1 "$pad"))
    fi
    n=$(printf '%s' "$s" | base64 -d 2>/dev/null | wc -c)
    [ "$n" -eq 32 ] || { _vless_parse_fail "pbk (публичный ключ Reality): неверный формат"; return 1; }
}

_vless_is_private() {
    local h="${1,,}" o1 o2 o3 o4
    case "$h" in
        localhost|*.local) return 0 ;;
    esac
    if [[ "$h" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        o1=$((10#${BASH_REMATCH[1]}))
        o2=$((10#${BASH_REMATCH[2]}))
        o3=$((10#${BASH_REMATCH[3]}))
        o4=$((10#${BASH_REMATCH[4]}))
        [ "$o1" -le 255 ] && [ "$o2" -le 255 ] && [ "$o3" -le 255 ] && [ "$o4" -le 255 ] || return 1
        [ "$o1" -eq 127 ] && return 0
        [ "$o1" -eq 10 ] && return 0
        [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ] && return 0
        [ "$o1" -eq 192 ] && [ "$o2" -eq 168 ] && return 0
        [ "$o1" -eq 169 ] && [ "$o2" -eq 254 ] && return 0
        [ "$o1" -eq 0 ] && return 0
        return 1
    fi
    case "$h" in
        ::1|fc*|fd*|fe8*|fe9*|fea*|feb*) return 0 ;;
    esac
    return 1
}

_vless_parse_uri() {
    local uri="$1" rest frag="" query="" authority uid hp enc flow sec net header
    local sni fp sid pbk pqv alpn mode extra path hosthdr service authority_name

    uri="${uri#"${uri%%[![:space:]]*}"}"
    uri="${uri%"${uri##*[![:space:]]}"}"
    [[ "$uri" == vless://* ]] || { _vless_parse_fail "ожидается ссылка vless://"; return 1; }
    rest=${uri#vless://}

    if [[ "$rest" == *#* ]]; then
        frag=${rest#*#}
        rest=${rest%%#*}
    fi
    if [[ "$rest" == *\?* ]]; then
        query=${rest#*\?}
        rest=${rest%%\?*}
    fi
    [[ "$rest" == *@* ]] || { _vless_parse_fail "адрес: нет id@host:port"; return 1; }
    uid=${rest%%@*}
    hp=${rest#*@}
    uid=$(_vless_url_decode "$uid")
    _vless_check_id "$uid" || return 1
    _vless_split_host_port "$hp" || return 1
    _vless_query_parse "$query"

    V_UID=$uid
    V_NAME=""
    if [ -n "$frag" ]; then
        V_NAME=$(_vless_url_decode "$frag")
    fi
    [ -n "$V_NAME" ] || V_NAME=$V_HOST

    enc=$(_vless_q encryption)
    enc=${enc:-none}
    if [ "$enc" != none ]; then
        [[ "$enc" =~ ^[A-Za-z0-9._-]+$ && "$enc" == mlkem768x25519plus* ]] \
            || { _vless_parse_fail "encryption: поддерживается none или mlkem768x25519plus.* (VLESS Encryption Xray)"; return 1; }
        V_ENC_META=mlkem768x25519plus
    else
        V_ENC_META=none
    fi
    V_ENC=$enc

    flow=$(_vless_q flow)
    case "$flow" in
        ""|xtls-rprx-vision|xtls-rprx-vision-udp443) ;;
        *) _vless_parse_fail "flow: допустимы xtls-rprx-vision и xtls-rprx-vision-udp443"; return 1 ;;
    esac
    V_FLOW=$flow

    sec=$(_vless_q security)
    sec=${sec,,}
    sec=${sec:-none}
    case "$sec" in
        tls|reality|none) ;;
        *) _vless_parse_fail "security: tls, reality или none"; return 1 ;;
    esac
    V_SEC=$sec

    net=$(_vless_q type)
    net=${net,,}
    net=${net:-tcp}
    header=$(_vless_q headerType)
    header=${header,,}
    header=${header:-none}
    if [ "$net" = raw ]; then
        net=tcp
    fi
    if [ "$net" = http ]; then
        net=tcp
        header=http
    fi
    case "$net" in
        tcp|ws|grpc|httpupgrade|xhttp|kcp) ;;
        *) _vless_parse_fail "транспорт type=${net} не поддерживается Xray-сборкой MTProxyL"; return 1 ;;
    esac
    if [ -n "$flow" ] && [ "$net" != tcp ]; then
        _vless_parse_fail "Vision flow требует type=tcp"
        return 1
    fi
    V_NET=$net
    V_HEADER=""

    if [ "$sec" = none ] && [ "$enc" = none ] && ! _vless_is_private "$V_HOST"; then
        _vless_parse_fail "VLESS без TLS/Reality/Encryption запрещён Xray для публичного адреса"
        return 1
    fi

    if [ "$sec" = tls ] || [ "$sec" = reality ]; then
        sni=$(_vless_q sni host)
    else
        sni=$(_vless_q sni)
    fi
    fp=$(_vless_q fp)
    if [ -n "$fp" ]; then
        case "$fp" in
            chrome|firefox|safari|ios|android|edge|360|qq|random|randomized) ;;
            *) _vless_parse_fail "fp: неизвестный отпечаток ${fp}"; return 1 ;;
        esac
    fi
    V_SNI=$sni
    V_FP=$fp
    V_ALPN=$(_vless_q alpn)
    V_INSECURE=0
    if _vless_truthy "$(_vless_q allowInsecure insecure)"; then
        V_INSECURE=1
    fi
    V_PBK=""
    V_SID=""
    V_SPX=""
    V_PQV=""

    if [ "$sec" = reality ]; then
        [ -n "$sni" ] || { _vless_parse_fail "Reality: в ссылке нужен sni"; return 1; }
        pbk=$(_vless_q pbk)
        [ -n "$pbk" ] || { _vless_parse_fail "Reality: нет pbk (публичный ключ)"; return 1; }
        _vless_check_b64key "$pbk" || return 1
        sid=$(_vless_q sid)
        if [ -n "$sid" ] && { [[ ! "$sid" =~ ^[0-9a-fA-F]*$ ]] || [ $(( ${#sid} % 2 )) -ne 0 ] || [ ${#sid} -gt 16 ]; }; then
            _vless_parse_fail "Reality: sid — hex чётной длины, не длиннее 16 символов"
            return 1
        fi
        V_PBK=$pbk
        V_SID=$sid
        V_SPX=$(_vless_q spx)
        [ -n "$V_SPX" ] || V_SPX=/
        V_PQV=$(_vless_q pqv mldsa65Verify)
    fi

    V_PATH=""
    V_HOSTHDR=""
    V_SERVICE=""
    V_AUTHORITY=""
    V_MODE=""
    V_EXTRA=""
    V_SEED=""
    V_WS_MAX=""

    case "$net" in
        tcp)
            if [ "$header" = http ]; then
                path=$(_vless_q path)
                path=${path:-/}
                hosthdr=$(_vless_q host)
                V_PATH=$path
                V_HOSTHDR=$hosthdr
                V_HEADER=http
            elif [ "$header" != none ] && [ -n "$header" ]; then
                _vless_parse_fail "tcp: headerType=${header} не поддерживается"
                return 1
            fi
            ;;
        ws)
            path=$(_vless_q path)
            path=${path:-/}
            if [[ "$path" =~ [\?\&]ed=([0-9]+) ]]; then
                V_WS_MAX=${BASH_REMATCH[1]}
                path=$(sed -E 's/[?&]ed=[0-9]+//g' <<< "$path")
                [ -n "$path" ] || path=/
            fi
            V_PATH=$path
            V_HOSTHDR=$(_vless_q host)
            ;;
        grpc)
            V_SERVICE=$(_vless_q serviceName)
            V_AUTHORITY=$(_vless_q authority)
            ;;
        httpupgrade)
            path=$(_vless_q path)
            V_PATH=${path:-/}
            V_HOSTHDR=$(_vless_q host)
            ;;
        xhttp)
            path=$(_vless_q path)
            V_PATH=${path:-/}
            V_HOSTHDR=$(_vless_q host)
            mode=$(_vless_q mode)
            if [ -n "$mode" ]; then
                case "$mode" in
                    auto|packet-up|stream-up|stream-one) ;;
                    *) _vless_parse_fail "xhttp: mode=${mode} не поддерживается"; return 1 ;;
                esac
                V_MODE=$mode
            fi
            extra=$(_vless_q extra)
            if [ -n "$extra" ]; then
                jq -e . >/dev/null 2>&1 <<< "$extra" \
                    || { _vless_parse_fail "xhttp: extra — не JSON"; return 1; }
                V_EXTRA=$extra
            fi
            ;;
        kcp)
            if [ -n "$header" ] && [ "$header" != none ]; then
                V_HEADER=$header
            else
                V_HEADER=none
            fi
            V_SEED=$(_vless_q seed)
            ;;
    esac
}

_vless_meta_json() {
    jq -nc \
        --arg name "$V_NAME" \
        --arg host "$V_HOST" \
        --argjson port "$V_PORT" \
        --arg security "$V_SEC" \
        --arg transport "$V_NET" \
        --arg encryption "$V_ENC_META" \
        --arg flow "$V_FLOW" \
        --arg sni "$V_SNI" \
        --arg header "$V_HEADER" \
        '{name:$name,host:$host,port:$port,security:$security,transport:$transport,
          encryption:$encryption,flow:$flow,sni:$sni,header:$header}'
}

_vless_out_json() {
    jq -nc \
        --arg host "$V_HOST" \
        --argjson port "$V_PORT" \
        --arg uid "$V_UID" \
        --arg enc "$V_ENC" \
        --arg flow "$V_FLOW" \
        --arg net "$V_NET" \
        --arg sec "$V_SEC" \
        --arg sni "$V_SNI" \
        --arg fp "$V_FP" \
        --arg alpn "$V_ALPN" \
        --arg insecure "$V_INSECURE" \
        --arg pbk "$V_PBK" \
        --arg sid "$V_SID" \
        --arg spx "$V_SPX" \
        --arg pqv "$V_PQV" \
        --arg path "$V_PATH" \
        --arg hosthdr "$V_HOSTHDR" \
        --arg service "$V_SERVICE" \
        --arg authority "$V_AUTHORITY" \
        --arg mode "$V_MODE" \
        --arg extra "$V_EXTRA" \
        --arg header "$V_HEADER" \
        --arg seed "$V_SEED" \
        --arg wsmax "$V_WS_MAX" \
        '{
          tag:"vless-out",
          protocol:"vless",
          settings:{vnext:[{
            address:$host,
            port:$port,
            users:[({id:$uid,encryption:$enc}
                    + (if $flow != "" then {flow:$flow} else {} end))]
          }]},
          streamSettings:(
            {network:$net,security:$sec}
            + (if $sec == "tls" then {tlsSettings:(
                 {serverName:$sni}
                 + (if $fp != "" then {fingerprint:$fp} else {} end)
                 + (if $alpn != "" then {alpn:($alpn|split(",")|map(select(length>0)))} else {} end)
                 + (if $insecure == "1" then {allowInsecure:true} else {} end)
               )} else {} end)
            + (if $sec == "reality" then {realitySettings:(
                 {serverName:$sni,
                  fingerprint:(if $fp != "" then $fp else "chrome" end),
                  publicKey:$pbk,
                  shortId:$sid,
                  spiderX:(if $spx != "" then $spx else "/" end)}
                 + (if $pqv != "" then {mldsa65Verify:$pqv} else {} end)
               )} else {} end)
            + (if $net == "tcp" and $header == "http" then {tcpSettings:{header:{
                 type:"http",
                 request:({path:[$path]}
                          + (if $hosthdr != "" then {headers:{Host:[$hosthdr]}} else {} end))
               }}} else {} end)
            + (if $net == "ws" then {wsSettings:(
                 {path:$path}
                 + (if $wsmax != "" then {maxEarlyData:($wsmax|tonumber),
                                          earlyDataHeaderName:"Sec-WebSocket-Protocol"} else {} end)
                 + (if $hosthdr != "" then {headers:{Host:$hosthdr}} else {} end)
               )} else {} end)
            + (if $net == "grpc" then {grpcSettings:(
                 {serviceName:$service}
                 + (if $authority != "" then {authority:$authority} else {} end)
               )} else {} end)
            + (if $net == "httpupgrade" then {httpupgradeSettings:(
                 {path:$path}
                 + (if $hosthdr != "" then {host:$hosthdr} else {} end)
               )} else {} end)
            + (if $net == "xhttp" then {xhttpSettings:(
                 {path:$path}
                 + (if $hosthdr != "" then {host:$hosthdr} else {} end)
                 + (if $mode != "" then {mode:$mode} else {} end)
                 + (if $extra != "" then {extra:($extra|fromjson)} else {} end)
               )} else {} end)
            + (if $net == "kcp" then {kcpSettings:(
                 {header:{type:(if $header != "" then $header else "none" end)}}
                 + (if $seed != "" then {seed:$seed} else {} end)
               )} else {} end)
          )
        }'
}

_vless_build() {
    local uri="$1" port="$2" path="$3" out tmp
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
        || { _vless_parse_fail "порт SOCKS: 1..65535"; return 1; }
    _vless_parse_uri "$uri" || return 1
    out=$(_vless_out_json) || return 1
    tmp="${path}.tmp"
    jq -n --argjson out "$out" --argjson port "$((10#$port))" '{
      log:{loglevel:"warning",access:"none"},
      inbounds:[{
        tag:"socks-in",
        listen:"127.0.0.1",
        port:$port,
        protocol:"socks",
        settings:{auth:"noauth",udp:false}
      }],
      outbounds:[$out,{tag:"direct",protocol:"freedom"}],
      routing:{
        domainStrategy:"AsIs",
        rules:[{
          type:"field",
          ip:["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16",
              "169.254.0.0/16","::1/128","fc00::/7","fe80::/10"],
          outboundTag:"direct"
        }]
      }
    }' > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" && mv -f "$tmp" "$path"
}

_vless_json_to_uri() {
    local json="$1" kind remarks tag host port uid enc flow net sec sni fp alpn insecure
    local pbk sid spx pqv path hosthdr service authority mode extra header seed maxed
    local params h name q

    IFS=$'\x1f' read -r kind remarks tag host port uid enc flow net sec sni fp alpn insecure \
        pbk sid spx pqv path hosthdr service authority mode extra header seed maxed \
        < <(jq -r '[
            .kind,.remarks,.tag,.host,.port,.uid,.enc,.flow,.net,.sec,.sni,.fp,.alpn,
            .insecure,.pbk,.sid,.spx,.pqv,.path,.hosthdr,.service,.authority,.mode,
            .extra,.header,.seed,.maxed
        ] | map(if . == null then "" else tostring end) | join("\u001f")' <<< "$json")

    [ -n "$host" ] && [ -n "$port" ] && [ -n "$uid" ] || return 1
    params=$(jq -nc \
        --arg sec "$sec" --arg net "$net" --arg sni "$sni" --arg fp "$fp" \
        --arg alpn "$alpn" --arg insecure "$insecure" --arg pbk "$pbk" \
        --arg sid "$sid" --arg spx "$spx" --arg pqv "$pqv" --arg path "$path" \
        --arg hosthdr "$hosthdr" --arg service "$service" --arg authority "$authority" \
        --arg mode "$mode" --arg extra "$extra" --arg header "$header" \
        --arg seed "$seed" --arg maxed "$maxed" --arg enc "$enc" --arg flow "$flow" '
        ({security:$sec,type:$net}
         + (if ($sec == "tls" or $sec == "reality") and $sni != "" then {sni:$sni} else {} end)
         + (if ($sec == "tls" or $sec == "reality") and $fp != "" then {fp:$fp} else {} end)
         + (if $alpn != "" then {alpn:$alpn} else {} end)
         + (if $insecure == "1" then {allowInsecure:"1"} else {} end)
         + (if $sec == "reality" then
              ({pbk:$pbk,sid:$sid,spx:(if $spx != "" then $spx else "/" end)}
               + (if $pqv != "" then {pqv:$pqv} else {} end))
            else {} end)
         + (if $net == "tcp" and $header == "http" then
              {headerType:"http",path:(if $path != "" then $path else "/" end),host:$hosthdr}
            else {} end)
         + (if $net == "ws" then
              {path:(if $maxed != "" then
                       ((if $path != "" then $path else "/" end)
                        + (if ((if $path != "" then $path else "/" end)|contains("?")) then "&" else "?" end)
                        + "ed=" + $maxed)
                     else (if $path != "" then $path else "/" end) end),
               host:$hosthdr}
            else {} end)
         + (if $net == "grpc" then {serviceName:$service,authority:$authority} else {} end)
         + (if $net == "httpupgrade" then
              {path:(if $path != "" then $path else "/" end),host:$hosthdr}
            else {} end)
         + (if $net == "xhttp" then
              ({path:(if $path != "" then $path else "/" end),host:$hosthdr}
               + (if $mode != "" then {mode:$mode} else {} end)
               + (if $extra != "" then {extra:($extra|fromjson)} else {} end))
            else {} end)
         + (if $net == "kcp" then
              {headerType:(if $header != "" then $header else "none" end),seed:$seed}
            else {} end)
         + (if $enc != "" and $enc != "none" then {encryption:$enc} else {} end)
         + (if $flow != "" then {flow:$flow} else {} end)
        ) | with_entries(select(.value != "" and .value != null))' 2>/dev/null) || return 1

    h=$host
    [[ "$host" == *:* ]] && h="[${host}]"
    name=$remarks
    if [ -n "$tag" ] && [ "$tag" != proxy ] && [ "$tag" != vless-out ]; then
        name="${name:+${name} · }${tag}"
    fi
    [ -n "$name" ] || name=$host
    q=$(jq -r 'to_entries | map("\(.key)=\(.value|@uri)") | join("&")' <<< "$params" 2>/dev/null) || return 1
    printf 'vless://%s@%s:%s?%s#%s\n' \
        "$(printf '%s' "$uid" | jq -sRr @uri)" "$h" "$port" "$q" \
        "$(printf '%s' "$name" | jq -sRr @uri)"
}

_vless_from_json() {
    local file="$1" tmp line n=0
    local prog
    prog=$(cat <<'JQ'
def first: if type == "array" then (.[0] // "") else (. // "") end;
def s: if . == null then "" else tostring end;
def bools: if . == true then "1" else "0" end;
def norm($remarks; $out):
  ($out.streamSettings // {}) as $ss
  | ($ss.tlsSettings // {}) as $tls
  | ($ss.realitySettings // {}) as $r
  | ($ss.wsSettings // {}) as $ws
  | ($ss.grpcSettings // {}) as $grpc
  | ($ss.httpupgradeSettings // {}) as $up
  | ($ss.xhttpSettings // {}) as $xh
  | ($ss.kcpSettings // {}) as $kcp
  | ($ss.tcpSettings // {}) as $tcp
  | (($ss.network // "tcp") | tostring | ascii_downcase) as $net0
  | (if $net0 == "raw" then "tcp" elif $net0 == "http" then "tcp" else $net0 end) as $net
  | (($ss.security // "none") | tostring | ascii_downcase) as $sec
  | ($out.settings.vnext[0]) as $v
  | ($v.users[0]) as $u
  | {
      kind:"xray", remarks:$remarks, tag:($out.tag // ""),
      host:($v.address // ""), port:($v.port // 0), uid:($u.id // ""),
      enc:($u.encryption // "none"), flow:($u.flow // ""),
      net:$net, sec:$sec,
      sni:($r.serverName // $tls.serverName // ""),
      fp:($r.fingerprint // $tls.fingerprint // ""),
      alpn:(($tls.alpn // []) | if type=="array" then join(",") else s end),
      insecure:(($tls.allowInsecure // $ss.allowInsecure // false) | bools),
      pbk:($r.publicKey // ""), sid:($r.shortId // ""), spx:($r.spiderX // ""),
      pqv:($r.mldsa65Verify // ""),
      path:(if $net=="ws" then ($ws.path // "/")
            elif $net=="httpupgrade" then ($up.path // "/")
            elif $net=="xhttp" then ($xh.path // "/")
            elif $net=="tcp" and (($tcp.header.type // "none") == "http")
              then (($tcp.header.request.path // ["/"]) | first)
            else "" end),
      hosthdr:(if $net=="ws" then (($ws.headers.Host // "") | first)
               elif $net=="httpupgrade" then ($up.host // "")
               elif $net=="xhttp" then ($xh.host // "")
               elif $net=="tcp" then (($tcp.header.request.headers.Host // "") | first)
               else "" end),
      service:($grpc.serviceName // ""), authority:($grpc.authority // ""),
      mode:($xh.mode // ""),
      extra:(if ($xh.extra // null) != null then ($xh.extra | tojson) else "" end),
      header:(if $net=="tcp" then ($tcp.header.type // "none")
              elif $net=="kcp" then ($kcp.header.type // "none")
              else "" end),
      seed:($kcp.seed // ""), maxed:($ws.maxEarlyData // "")
    };
def normsb($remarks; $out):
  ($out.tls // {}) as $tls
  | ($tls.reality // {}) as $r
  | ($tls.utls // {}) as $utls
  | ($out.transport // {}) as $tr
  | (($tr.type // "tcp") | tostring | ascii_downcase) as $net
  | (if $r.enabled then "reality" elif $tls.enabled then "tls" else "none" end) as $sec
  | {
      kind:"singbox", remarks:$remarks, tag:($out.tag // ""),
      host:($out.server // ""), port:($out.server_port // 0), uid:($out.uuid // ""),
      enc:($out.encryption // "none"), flow:($out.flow // ""),
      net:$net, sec:$sec,
      sni:($tls.server_name // $out.server // ""),
      fp:($utls.fingerprint // (if $sec=="none" then "" else "chrome" end)),
      alpn:(($tls.alpn // []) | if type=="array" then join(",") else s end),
      insecure:(($tls.insecure // false) | bools),
      pbk:($r.public_key // ""), sid:($r.short_id // ""), spx:"", pqv:"",
      path:(if $net=="ws" then ($tr.path // "/")
            elif $net=="httpupgrade" then ($tr.path // "/")
            elif $net=="xhttp" then ($tr.path // "/")
            else "" end),
      hosthdr:(if $net=="ws" then (($tr.headers.Host // "") | first)
               elif $net=="httpupgrade" then ($tr.host // "")
               elif $net=="xhttp" then ($tr.host // "")
               else "" end),
      service:($tr.service_name // ""), authority:($tr.authority // ""),
      mode:($tr.mode // ""),
      extra:(if ($tr.extra // null) != null then ($tr.extra | tojson) else "" end),
      header:"", seed:"", maxed:($tr.max_early_data // "")
    };
(if type == "array" then .[] else . end)
| . as $p
| (($p.remarks // $p.meta.name // "") | s) as $remarks
| ($p.outbounds // [])[]
| . as $o
| (($o.protocol // $o.type // "") | tostring | ascii_downcase) as $proto
| select($proto == "vless")
| if (($o.settings.vnext // null) != null)
  then norm($remarks; $o)
  else normsb($remarks; $o)
  end
JQ
)
    tmp=$(mktemp) || return 1
    if ! jq -c "$prog" "$file" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        _vless_parse_fail "JSON подписки не прочитан"
        return 1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if _vless_json_to_uri "$line"; then
            n=$((n + 1))
        fi
    done < "$tmp"
    rm -f "$tmp"
    if [ "$n" -eq 0 ]; then
        _vless_parse_fail "в JSON-подписке нет VLESS-выходов"
        return 1
    fi
}

_vless_parse_probe() {
    local port="$1" host="$2" tport="$3" timeout="${4:-10}"
    [[ "$port" =~ ^[0-9]+$ && "$tport" =~ ^[0-9]+$ ]] || return 2
    timeout "$timeout" bash -c '
        port=$1; host=$2; tport=$3
        exec 3<>"/dev/tcp/127.0.0.1/$port" || exit 2
        printf "\x05\x01\x00" >&3 || exit 2
        r=$(dd bs=1 count=2 <&3 2>/dev/null | od -An -tx1 | tr -d " \n")
        [ "$r" = "0500" ] || exit 2
        n=${#host}
        [ "$n" -ge 1 ] && [ "$n" -le 255 ] || exit 2
        printf "\x05\x01\x00\x03" >&3 || exit 2
        printf "%b" "\\x$(printf "%02x" "$n")" >&3 || exit 2
        printf "%s" "$host" >&3 || exit 2
        printf "%b" "\\x$(printf "%02x" $((tport / 256)))\\x$(printf "%02x" $((tport % 256)))" >&3 || exit 2
        r=$(dd bs=1 count=4 <&3 2>/dev/null | od -An -tx1 | tr -d " \n")
        [ "${r:2:2}" = "00" ] || exit 3
    ' _ "$port" "$host" "$tport"
}

vless_parse_main() {
    local cmd="${1:-}"
    case "$cmd" in
        check)
            [ "$#" -ge 2 ] || { _vless_parse_fail "использование: vless_parse.sh check URI"; return 1; }
            _vless_parse_uri "$2" || return 1
            _vless_meta_json
            ;;
        build)
            [ "$#" -ge 4 ] || { _vless_parse_fail "использование: vless_parse.sh build URI PORT FILE"; return 1; }
            _vless_build "$2" "$3" "$4"
            ;;
        from-json)
            [ "$#" -ge 2 ] || { _vless_parse_fail "использование: vless_parse.sh from-json FILE"; return 1; }
            _vless_from_json "$2"
            ;;
        probe)
            [ "$#" -ge 4 ] || { _vless_parse_fail "использование: vless_parse.sh probe PORT HOST TPORT"; return 1; }
            _vless_parse_probe "$2" "$3" "$4"
            ;;
        *)
            _vless_parse_fail "неизвестная команда: ${cmd}"
            return 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    vless_parse_main "$@"
fi
