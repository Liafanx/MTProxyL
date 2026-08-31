#!/bin/bash
# MTProxyL — доступность прокси из России (Globalping).
#
# Зонды обязаны стоять на домашних сетях: фильтрация применяется к абонентскому
# трафику, и зонд в дата-центре регулярно видит сервер, до которого его
# пользователи не достучатся. Проверка — HTTPS HEAD на порт прокси с доменом
# FakeTLS в SNI, успех — вернувшийся сертификат: ровно то рукопожатие, что
# делает клиент Telegram, поэтому ловится и порт, который отвечает, но рвёт
# сессию на середине.

AVAILABILITY_API="https://api.globalping.io/v1"
AVAILABILITY_SERVICE="mtproxyl-availability.service"
AVAILABILITY_TIMER="mtproxyl-availability.timer"

# Кредиты Globalping: один зонд — один кредит, окно скользящее, час.
_AVAIL_CREDITS_ANON=250
_AVAIL_CREDITS_TOKEN=500
_AVAIL_CREDIT_WINDOW=3600
# Сколько ждём зонды и как часто спрашиваем результат.
_AVAIL_MEASURE_WAIT=60
_AVAIL_POLL=2
# Ручная проверка не чаще: каждый зонд стоит кредита.
_AVAIL_COOLDOWN=60
# Сервисы определения внешнего адреса — по очереди, пока кто-нибудь не ответит.
_AVAIL_IP_SERVICES=(
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
    "https://icanhazip.com"
    "https://ipecho.net/plain"
)

_avail_dir()        { echo "${INSTALL_DIR}/availability"; }
_avail_state_file() { echo "${INSTALL_DIR}/availability/last.json"; }
_avail_quota_file() { echo "${INSTALL_DIR}/availability/quota"; }
_avail_token_file() { echo "${INSTALL_DIR}/availability/token"; }
_avail_lock_file()  { echo "${INSTALL_DIR}/availability/lock"; }

_availability_ensure_dir() {
    local _d="${INSTALL_DIR}/availability"
    [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null || return 1
    chmod 700 "$_d" 2>/dev/null || true
    return 0
}

# ── Настройки ─────────────────────────────────────────────────

availability_interval_minutes() {
    local _v="${AVAILABILITY_INTERVAL:-15}"
    [[ "$_v" =~ ^[0-9]+$ ]] || _v=15
    [ "$_v" -gt 1440 ] && _v=1440
    echo "$_v"
}

availability_probe_limit() {
    local _v="${AVAILABILITY_PROBES:-20}"
    [[ "$_v" =~ ^[0-9]+$ ]] || _v=20
    [ "$_v" -lt 1 ] && _v=20
    [ "$_v" -gt 50 ] && _v=50
    echo "$_v"
}

availability_threshold() {
    local _v="${AVAILABILITY_THRESHOLD:-50}"
    [[ "$_v" =~ ^[0-9]+$ ]] || _v=50
    [ "$_v" -gt 100 ] && _v=100
    echo "$_v"
}

availability_enabled() {
    [ "${AVAILABILITY_ENABLED:-true}" != "false" ]
}

# Токен живёт отдельным файлом с правами 600: settings.conf читаем всем миром.
availability_token() {
    local _f; _f=$(_avail_token_file)
    [ -r "$_f" ] || return 0
    tr -d '\n\r' < "$_f" 2>/dev/null
}

availability_set_token() {
    local _t="$1" _f; _f=$(_avail_token_file)
    if [ -z "$_t" ]; then
        rm -f "$_f"
        return 0
    fi
    # Проверяем форму, а не подлинность: негодный отсеется первым же ответом.
    [[ "$_t" =~ ^[A-Za-z0-9_-]{20,200}$ ]] || {
        log_error "Токен Globalping — 20-200 символов из латиницы, цифр, дефиса и подчёркивания"
        return 1
    }
    _availability_ensure_dir || return 1
    printf '%s\n' "$_t" > "$_f" && chmod 600 "$_f"
}

# ── Квота ─────────────────────────────────────────────────────
# Счётчик потраченного, а не сторож: настоящий лимит объявляет сам сервис
# ответом 429, и его слово важнее нашей арифметики.

_avail_budget() {
    if [ -n "$(availability_token)" ]; then echo "$_AVAIL_CREDITS_TOKEN"; else echo "$_AVAIL_CREDITS_ANON"; fi
}

_avail_quota_append() {
    local _line="$1" _f
    _f=$(_avail_quota_file)
    _availability_ensure_dir || return 0
    printf '%s\n' "$_line" >> "$_f" 2>/dev/null
    chmod 600 "$_f" 2>/dev/null || true
}

availability_quota_record() {
    local _cost="$1"
    [[ "$_cost" =~ ^[0-9]+$ ]] && [ "$_cost" -gt 0 ] || return 0
    _avail_quota_append "SPEND $(date +%s) ${_cost}"
    _avail_quota_compact
}

# Сервис сказал 429 — считаем квоту исчерпанной, пока он не разрешит снова.
availability_quota_block() {
    local _secs="$1"
    [[ "$_secs" =~ ^[0-9]+$ ]] && [ "$_secs" -gt 0 ] || _secs="$_AVAIL_CREDIT_WINDOW"
    _avail_quota_append "BLOCK $(( $(date +%s) + _secs ))"
}

# Выкидываем траты, вышедшие из скользящего часа, и истёкшую блокировку.
_avail_quota_compact() {
    local _f _now _tmp
    _f=$(_avail_quota_file)
    [ -f "$_f" ] || return 0
    _now=$(date +%s)
    _tmp="${_f}.tmp"
    awk -v now="$_now" -v win="$_AVAIL_CREDIT_WINDOW" '
        $1 == "SPEND" && ($2 + win) > now { print }
        $1 == "BLOCK" && $2 > now { print }
    ' "$_f" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$_f" 2>/dev/null
    rm -f "$_tmp" 2>/dev/null
}

# "budget spent remaining reset_in blocked" одной строкой.
_avail_quota_state() {
    local _f _now _budget
    _f=$(_avail_quota_file)
    _now=$(date +%s)
    _budget=$(_avail_budget)
    awk -v now="$_now" -v win="$_AVAIL_CREDIT_WINDOW" -v budget="$_budget" '
        $1 == "SPEND" && ($2 + win) > now {
            spent += $3
            if (oldest == 0 || $2 < oldest) oldest = $2
        }
        $1 == "BLOCK" && $2 > now && $2 > blocked { blocked = $2 }
        END {
            remaining = budget - spent
            if (remaining < 0) remaining = 0
            reset = 0
            if (blocked > 0) { remaining = 0; reset = blocked - now }
            else if (oldest > 0) { reset = oldest + win - now }
            if (reset < 0) reset = 0
            printf "%d %d %d %d %d\n", budget, spent, remaining, reset, (blocked > 0 ? 1 : 0)
        }
    ' "$_f" 2>/dev/null || echo "$_budget 0 $_budget 0 0"
}

availability_quota_json() {
    local _b _s _r _reset _blocked _has="false"
    read -r _b _s _r _reset _blocked <<< "$(_avail_quota_state)"
    [ -n "$(availability_token)" ] && _has="true"
    printf '{"budget":%d,"spent":%d,"remaining":%d,"reset_in_seconds":%d,"has_token":%s}' \
        "${_b:-0}" "${_s:-0}" "${_r:-0}" "${_reset:-0}" "$_has"
}

# ── Цель проверки ─────────────────────────────────────────────

_availability_public_ip() {
    local _u _ip
    for _u in "${_AVAIL_IP_SERVICES[@]}"; do
        _ip=$(curl -fsS --max-time 5 "$_u" 2>/dev/null | tr -d '\r\n[:space:]')
        [ -n "$_ip" ] && { printf '%s' "$_ip"; return 0; }
    done
    return 1
}

# public_host из конфига движка. Именно это имя видит клиент, и оно бывает
# задано там, где ни Selfmask, ни CUSTOM_IP ничего не подсказывают.
_availability_config_public_host() {
    local _v=""
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        [ -n "${DETECTED_CONFIG_PATH:-}" ] && [ -f "${DETECTED_CONFIG_PATH}" ] || return 1
        _v=$(_toml_get_string_in_section "general.links" "public_host" "$DETECTED_CONFIG_PATH" 2>/dev/null)
    elif _superexpert_active 2>/dev/null; then
        _v=$(_toml_get_string_in_section "general.links" "public_host" "$SUPEREXPERT_FILE" 2>/dev/null)
    else
        _v=$(proxy_public_host 2>/dev/null)
    fi
    [ -n "$_v" ] || return 1
    case "$_v" in *:*) return 1 ;; esac   # IPv6 в SNI и Host не годится
    printf '%s' "$_v"
}

# Домен WEB: у менеджера свой, у цели — host первого vhost из её конфига.
_availability_web_host() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        web_target_enabled 2>/dev/null || return 1
        web_target_host 2>/dev/null
        return $?
    fi
    web_is_enabled 2>/dev/null || return 1
    web_domain 2>/dev/null
}

# Что проверяем: "host|port|sni". Заданное руками важнее всего — оператор уже
# видел автоопределение и от него отступил.
availability_target() {
    local _h="${AVAILABILITY_HOST:-}" _p="${AVAILABILITY_PORT:-}" _s="${AVAILABILITY_SNI:-}"

    [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ] || _p=""

    if [ -z "$_p" ]; then
        if web_is_only_mode 2>/dev/null; then
            _p=$(web_public_port 2>/dev/null)
        else
            _p="${PROXY_PORT:-}"
        fi
        # В реаниматоре порт может ещё не переехать в профиль режима, а у цели
        # он свой — обнаружение знает точнее.
        [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] && [ -n "${DETECTED_PORT:-}" ] && _p="$DETECTED_PORT"
    fi
    [[ "$_p" =~ ^[0-9]+$ ]] || _p=443

    if [ -z "$_s" ]; then
        if web_is_only_mode 2>/dev/null; then
            _s=$(_availability_web_host 2>/dev/null) || _s=""
        else
            _s=$(_current_sni_domain 2>/dev/null) || _s=""
        fi
        [ -n "$_s" ] || _s="${PROXY_DOMAIN:-}"
        # В WEB-режиме маскировки может не быть вовсе, и тогда FakeTLS-домена
        # тоже нет. Публичное имя там — домен WEB, по нему и здороваемся.
        [ -n "$_s" ] || _s=$(_availability_web_host 2>/dev/null)
    fi

    # Адрес: домен заглушки, потом public_host из конфига, прикреплённый к
    # ссылкам адрес и только в конце внешний IP.
    if [ -z "$_h" ] && web_is_only_mode 2>/dev/null; then
        _h=$(_availability_web_host 2>/dev/null)
    fi
    if [ -z "$_h" ] && [ "${SELFMASK_ENABLED:-false}" = "true" ] && [ -n "${SELFMASK_DOMAIN:-}" ]; then
        _h="$SELFMASK_DOMAIN"
    fi
    [ -z "$_h" ] && _h=$(_availability_config_public_host 2>/dev/null)
    [ -z "$_h" ] && _h="${CUSTOM_IP:-}"
    [ -z "$_h" ] && _h=$(_availability_web_host 2>/dev/null)
    [ -z "$_h" ] && _h=$(_availability_public_ip)

    printf '%s|%s|%s' "$_h" "$_p" "$_s"
}

availability_target_json() {
    local _t _h _p _s
    _t=$(availability_target)
    IFS='|' read -r _h _p _s <<< "$_t"
    printf '{"host":"%s","port":%d,"sni":"%s","override":{"host":"%s","port":"%s","sni":"%s"}}' \
        "$(json_escape "$_h")" "${_p:-0}" "$(json_escape "$_s")" \
        "$(json_escape "${AVAILABILITY_HOST:-}")" "$(json_escape "${AVAILABILITY_PORT:-}")" \
        "$(json_escape "${AVAILABILITY_SNI:-}")"
}

# ── Состояние ─────────────────────────────────────────────────

_avail_now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Запись через временный файл рядом: оборванная запись оставила бы обрезанный
# JSON, и панель с ботом читали бы мусор до следующей проверки.
_availability_write_state() {
    local _json="$1" _f _tmp
    _f=$(_avail_state_file)
    _availability_ensure_dir || return 1
    _tmp="${_f}.tmp"
    printf '%s\n' "$_json" > "$_tmp" || return 1
    chmod 600 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$_f"
}

# Неудача — тоже результат: без неё страница показывала бы прошлый вердикт как
# свежий и молчала о том, почему нового нет.
_availability_write_error() {
    local _msg="$1" _target="${2:-}"
    _availability_write_state "$(printf '{"checked_at":"%s","target":"%s","level":"red","percentage":0,"total_probes":0,"success_probes":0,"measurement_id":"","probes":[],"error":"%s"}' \
        "$(_avail_now_iso)" "$(json_escape "$_target")" "$(json_escape "$_msg")")"
}

availability_last_json() {
    local _f; _f=$(_avail_state_file)
    [ -s "$_f" ] && cat "$_f" || echo "null"
}

# Тот же результат без списка зондов: индикатор дашборда опрашивает его часто,
# а два десятка сырых выводов ему ни к чему.
availability_last_short_json() {
    local _f; _f=$(_avail_state_file)
    [ -s "$_f" ] || { echo "null"; return 0; }
    if command -v jq &>/dev/null; then
        jq -c 'del(.probes)' "$_f" 2>/dev/null || echo "null"
    else
        cat "$_f"
    fi
}

# ── Проверка ──────────────────────────────────────────────────

_avail_require_tools() {
    local _missing=()
    command -v curl &>/dev/null || _missing+=("curl")
    command -v jq   &>/dev/null || _missing+=("jq")
    [ ${#_missing[@]} -eq 0 ] && return 0
    log_error "Для проверки доступности нужны: ${_missing[*]}"
    return 1
}

# Сколько секунд назад закончилась прошлая проверка; 999999, если её не было.
_avail_seconds_since_last() {
    local _f _mtime
    _f=$(_avail_state_file)
    [ -s "$_f" ] || { echo 999999; return 0; }
    _mtime=$(stat -c '%Y' "$_f" 2>/dev/null) || { echo 999999; return 0; }
    echo $(( $(date +%s) - _mtime ))
}

# Одна проверка. Пишет состояние и печатает итог; --json — машинный вывод.
availability_check() {
    local _json="false" _quiet="false" _arg
    for _arg in "$@"; do
        case "$_arg" in
            --json)  _json="true" ;;
            --quiet) _quiet="true" ;;
        esac
    done

    _avail_require_tools || return 1
    _availability_ensure_dir || { log_error "Не удалось создать ${INSTALL_DIR}/availability"; return 1; }

    # Замок на всю проверку: панель, бот и таймер ходят сюда независимо, а два
    # одновременных измерения — это двойной расход квоты ради одного вердикта.
    local _lock _waited_from; _lock=$(_avail_lock_file)
    _waited_from=$(date +%s)
    # Скобки обязательны: голый `exec 9>… 2>/dev/null` перенаправил бы stderr
    # всего скрипта до самого конца, и все сообщения ушли бы в никуда.
    { exec 9>"$_lock"; } 2>/dev/null || true
    if command -v flock &>/dev/null; then
        if ! flock -w "$(( _AVAIL_MEASURE_WAIT + 30 ))" 9 2>/dev/null; then
            _avail_output "$_json" "Проверка уже идёт и не закончилась вовремя" 1
            return 1
        fi
    fi

    local _since; _since=$(_avail_seconds_since_last)
    if [ "$_since" -lt "$_AVAIL_COOLDOWN" ]; then
        # Стояли в очереди за чужой проверкой — отдаём её результат: заказывать
        # второе измерение подряд незачем, оно стоит квоты.
        if [ $(( $(date +%s) - _waited_from )) -ge 2 ]; then
            if [ "$_json" = "true" ]; then
                availability_last_json
            elif [ "$_quiet" != "true" ]; then
                availability_show_status
            fi
            return 0
        fi
        # Никого не ждали, просто проверка была только что — это отказ, иначе
        # нажавший кнопку решит, что видит свежий результат.
        _avail_output "$_json" \
            "проверка была ${_since} с назад — каждый зонд стоит квоты, подождите $(( _AVAIL_COOLDOWN - _since )) с" 1
        return 1
    fi

    local _target _host _port _sni
    _target=$(availability_target)
    IFS='|' read -r _host _port _sni <<< "$_target"
    if [ -z "$_host" ]; then
        _availability_write_error "не удалось определить адрес сервера — задайте его в настройках проверки"
        _avail_output "$_json" "Не удалось определить адрес сервера" 1
        return 1
    fi

    local _label="${_host}:${_port}"
    [ -n "$_sni" ] && _label="${_label} (SNI: ${_sni})"

    local _b _s _r _reset _blocked
    read -r _b _s _r _reset _blocked <<< "$(_avail_quota_state)"
    if [ "${_r:-0}" -le 0 ]; then
        local _wait_msg="квота Globalping исчерпана"
        [ "${_reset:-0}" -gt 0 ] && _wait_msg="${_wait_msg}, вернётся через $(( (_reset + 59) / 60 )) мин"
        _availability_write_error "$_wait_msg" "$_label"
        _avail_output "$_json" "$_wait_msg" 1
        return 1
    fi

    local _limit; _limit=$(availability_probe_limit)
    [ "$_limit" -gt "$_r" ] && _limit="$_r"

    # Host уходит и в заголовок, и в SNI — именно это делает проверку FakeTLS.
    local _req
    _req=$(jq -nc --arg host "$_host" --arg sni "$_sni" \
                  --argjson port "$_port" --argjson limit "$_limit" '
        {
            type: "http",
            target: $host,
            measurementOptions: {
                protocol: "HTTPS",
                port: $port,
                request: (if $sni == "" then {method: "HEAD"} else {method: "HEAD", host: $sni} end)
            },
            locations: [{country: "RU", tags: ["eyeball-network"]}],
            limit: $limit
        }')

    local _tmp_body _tmp_head _code
    _tmp_body=$(_mktemp) || return 1
    _tmp_head=$(_mktemp) || return 1

    local _auth=() _tok
    _tok=$(availability_token)
    [ -n "$_tok" ] && _auth=(-H "Authorization: Bearer ${_tok}")

    _code=$(curl -sS --max-time 30 -o "$_tmp_body" -D "$_tmp_head" -w '%{http_code}' \
        -X POST "${AVAILABILITY_API}/measurements" \
        -H "Content-Type: application/json" "${_auth[@]}" \
        --data-binary "$_req" 2>/dev/null) || _code="000"

    if [ "$_code" = "429" ]; then
        local _retry
        _retry=$(awk 'BEGIN{IGNORECASE=1} /^x-ratelimit-reset:|^retry-after:/ {gsub(/[^0-9]/,"",$2); if ($2 != "") {print $2; exit}}' "$_tmp_head" 2>/dev/null)
        [[ "$_retry" =~ ^[0-9]+$ ]] || _retry="$_AVAIL_CREDIT_WINDOW"
        availability_quota_block "$_retry"
        local _msg="превышен часовой лимит Globalping, следующая попытка через $(( (_retry + 59) / 60 )) мин"
        [ -z "$_tok" ] && _msg="${_msg}. Бесплатный токен на dash.globalping.io поднимает лимит вдвое"
        _availability_write_error "$_msg" "$_label"
        _avail_output "$_json" "$_msg" 1
        return 1
    fi
    if [ "$_code" != "200" ] && [ "$_code" != "202" ]; then
        local _msg="сервис проверки ответил ${_code}"
        [ "$_code" = "000" ] && _msg="сервис проверки не отвечает"
        _availability_write_error "$_msg" "$_label"
        _avail_output "$_json" "$_msg" 1
        return 1
    fi

    local _id _count
    _id=$(jq -r '.id // empty' "$_tmp_body" 2>/dev/null)
    _count=$(jq -r '.probesCount // 0' "$_tmp_body" 2>/dev/null)
    if [ -z "$_id" ]; then
        _availability_write_error "сервис проверки не вернул идентификатор измерения" "$_label"
        _avail_output "$_json" "Сервис проверки не вернул идентификатор измерения" 1
        return 1
    fi

    # Платим за реально задействованные зонды: сервис не всегда даёт столько,
    # сколько попросили, и списание по запрошенному занижало бы остаток.
    [[ "$_count" =~ ^[0-9]+$ ]] && [ "$_count" -gt 0 ] || _count="$_limit"
    availability_quota_record "$_count"

    local _deadline=$(( $(date +%s) + _AVAIL_MEASURE_WAIT )) _status=""
    while :; do
        sleep "$_AVAIL_POLL"
        _code=$(curl -sS --max-time 30 -o "$_tmp_body" -w '%{http_code}' \
            "${AVAILABILITY_API}/measurements/${_id}" \
            -H "Accept: application/json" "${_auth[@]}" 2>/dev/null) || _code="000"
        if [ "$_code" != "200" ]; then
            _availability_write_error "сервис проверки ответил ${_code} на запрос результата" "$_label"
            _avail_output "$_json" "Сервис проверки ответил ${_code}" 1
            return 1
        fi
        _status=$(jq -r '.status // empty' "$_tmp_body" 2>/dev/null)
        [ "$_status" != "in-progress" ] && break
        # Время вышло — берём что есть: не ответившие зонды пойдут как таковые,
        # а не в минус прокси.
        [ "$(date +%s)" -ge "$_deadline" ] && break
    done

    local _result
    _result=$(jq -c --arg target "$_label" --arg now "$(_avail_now_iso)" '
        [ .results[]? | {
            city: (.probe.city // ""), country: (.probe.country // ""),
            region: (.probe.region // ""), continent: (.probe.continent // ""),
            asn: (.probe.asn // 0), network: (.probe.network // ""),
            tags: (.probe.tags // []),
            status: (.result.status // ""),
            tls_success: ((.result.status == "finished") and (.result.tls != null)),
            tls_info: .result.tls,
            http_status_code: (.result.statusCode // 0),
            raw_output: (.result.rawOutput // "")
        } ]
        | map(. + {error: (
            if .tls_success then ""
            elif (.raw_output | gsub("^\\s+|\\s+$"; "")) != "" then (.raw_output | gsub("^\\s+|\\s+$"; ""))
            elif .status == "in-progress" then "зонд не ответил вовремя"
            else "соединение не установлено" end)})
        | {probes: ., total_probes: length, success_probes: (map(select(.tls_success)) | length)}
        | .percentage = (if .total_probes > 0 then (.success_probes * 100 / .total_probes) else 0 end)
        | .level = (if .percentage >= 80 then "green" elif .percentage >= 50 then "yellow" else "red" end)
        | .target = $target | .checked_at = $now | .error = ""
    ' "$_tmp_body" 2>/dev/null)

    if [ -z "$_result" ]; then
        _availability_write_error "не удалось разобрать ответ сервиса проверки" "$_label"
        _avail_output "$_json" "Не удалось разобрать ответ сервиса проверки" 1
        return 1
    fi
    _result=$(jq -c --arg id "$_id" '.measurement_id = $id' <<< "$_result")

    local _total
    _total=$(jq -r '.total_probes' <<< "$_result")
    if [ "${_total:-0}" -eq 0 ]; then
        _availability_write_error "ни один российский зонд не взялся за проверку — повторите позже" "$_label"
        _avail_output "$_json" "Ни один российский зонд не взялся за проверку" 1
        return 1
    fi

    _availability_write_state "$_result"

    if [ "$_json" = "true" ]; then
        printf '%s\n' "$_result"
    elif [ "$_quiet" != "true" ]; then
        availability_show_status
    fi
    return 0
}

# Единая печать отказа: в JSON — то же поле error, что и в состоянии.
_avail_output() {
    local _json="$1" _msg="$2" _rc="${3:-1}"
    if [ "$_json" = "true" ]; then
        printf '{"error":"%s"}\n' "$(json_escape "$_msg")"
    else
        log_error "$_msg"
    fi
    return "$_rc"
}

# ── Вывод для человека ────────────────────────────────────────

_avail_level_color() {
    case "$1" in
        green)  printf '%s' "$GREEN" ;;
        yellow) printf '%s' "$YELLOW" ;;
        *)      printf '%s' "$RED" ;;
    esac
}

# Строка для главного меню и меню дополнений.
availability_status_line() {
    local _f; _f=$(_avail_state_file)
    if [ ! -s "$_f" ]; then
        echo -e "${DIM}проверок ещё не было${NC}"
        return 0
    fi
    command -v jq &>/dev/null || { echo -e "${DIM}н/д${NC}"; return 0; }
    local _pct _lvl _ok _total _err _age
    _pct=$(jq -r '.percentage // 0' "$_f" 2>/dev/null)
    _lvl=$(jq -r '.level // "red"' "$_f" 2>/dev/null)
    _ok=$(jq -r '.success_probes // 0' "$_f" 2>/dev/null)
    _total=$(jq -r '.total_probes // 0' "$_f" 2>/dev/null)
    _err=$(jq -r '.error // ""' "$_f" 2>/dev/null)
    if [ -n "$_err" ]; then
        echo -e "${YELLOW}нет свежего результата${NC} ${DIM}(${_err})${NC}"
        return 0
    fi
    _age=$(_avail_seconds_since_last)
    printf '%b%.0f%%%b %s(%s из %s зондов, %s назад)%b\n' \
        "$(_avail_level_color "$_lvl")" "$_pct" "$NC" "$DIM" "$_ok" "$_total" \
        "$(_avail_human_age "$_age")" "$NC"
}

_avail_human_age() {
    local _s="${1:-0}"
    if [ "$_s" -lt 60 ]; then echo "${_s} с"
    elif [ "$_s" -lt 3600 ]; then echo "$(( _s / 60 )) мин"
    else echo "$(( _s / 3600 )) ч"; fi
}

# --no-title — для меню, у которого свой заголовок.
availability_show_status() {
    local _f; _f=$(_avail_state_file)
    echo ""
    if [ "${1:-}" != "--no-title" ]; then
        echo -e "  ${BOLD}Доступность из России${NC}"
        echo ""
    fi
    echo -e "  ${BOLD}Результат:${NC}   $(availability_status_line)"

    local _t _h _p _s
    _t=$(availability_target); IFS='|' read -r _h _p _s <<< "$_t"
    echo -e "  ${BOLD}Проверяем:${NC}   ${_h:-${DIM}не определён${NC}}:${_p}${_s:+ ${DIM}(SNI: ${_s})${NC}}"

    if availability_timer_active; then
        local _next _left=""
        _next=$(_avail_next_run)
        [ -n "$_next" ] && _left=$(( $(date -u -d "$_next" +%s 2>/dev/null || echo 0) - $(date +%s) ))
        echo -e "  ${BOLD}Автопроверка:${NC} каждые $(availability_interval_minutes) мин, $(availability_probe_limit) зондов$(
            [ "${_left:-0}" -gt 0 ] && echo " ${DIM}(следующая через $(_avail_human_age "$_left"))${NC}")"
    else
        echo -e "  ${BOLD}Автопроверка:${NC} ${DIM}выключена (mtproxyl availability on)${NC}"
    fi

    local _b _sp _r _reset _blocked
    read -r _b _sp _r _reset _blocked <<< "$(_avail_quota_state)"
    local _tok_note="${DIM}без токена${NC}"
    [ -n "$(availability_token)" ] && _tok_note="${DIM}с токеном${NC}"
    echo -e "  ${BOLD}Квота:${NC}       ${_r} из ${_b} кредитов ${_tok_note}"
    [ "${_reset:-0}" -gt 0 ] && echo -e "  ${BOLD}Обновится:${NC}   через $(_avail_human_age "$_reset")"
    echo -e "  ${BOLD}Порог:${NC}       $(availability_threshold)% ${DIM}(ниже — уведомление в телеграм-боте)${NC}"

    if [ -s "$_f" ] && command -v jq &>/dev/null; then
        local _bad
        _bad=$(jq -r '[.probes[]? | select(.tls_success | not)] | length' "$_f" 2>/dev/null)
        if [ "${_bad:-0}" -gt 0 ]; then
            echo ""
            echo -e "  ${BOLD}Не достучались:${NC}"
            jq -r '.probes[]? | select(.tls_success | not)
                   | "    \(.city // "?"), \(.network // "?") — \(.error)"' "$_f" 2>/dev/null | head -10
        fi
    fi
    echo ""
}

# ── Общий JSON для панели и бота ──────────────────────────────

# Таймер считает от прошлого запуска, а не от календаря, поэтому
# NextElapseUSecRealtime у него пуст — время следующего запуска берём из
# list-timers, а на systemd без JSON считаем сами.
_avail_next_run() {
    command -v systemctl &>/dev/null || return 0
    local _us _last
    _us=$(systemctl list-timers "$AVAILABILITY_TIMER" --no-pager -o json 2>/dev/null \
          | jq -r '.[0].next // empty' 2>/dev/null)
    if [[ "$_us" =~ ^[0-9]+$ ]] && [ "$_us" -gt 0 ]; then
        date -u -d "@$(( _us / 1000000 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
        return 0
    fi
    _last=$(systemctl show "$AVAILABILITY_TIMER" -p LastTriggerUSec --value 2>/dev/null)
    [ -n "$_last" ] || return 0
    date -u -d "${_last} + $(availability_interval_minutes) minutes" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
}

availability_status_json() {
    local _full="false"
    [ "${1:-}" = "--full" ] && _full="true"

    local _timer="false" _result
    availability_timer_active && _timer="true"
    if [ "$_full" = "true" ]; then _result=$(availability_last_json); else _result=$(availability_last_short_json); fi

    local _msg=""
    [ "$_result" = "null" ] && _msg="Проверки ещё не проводились"

    # enabled — «проверка вообще есть», auto_check — «идёт по расписанию».
    # Выключенное расписание не отменяет ручную проверку.
    printf '{"enabled":true,"auto_check":%s,"timer_active":%s,"interval":%s,"probes":%s,"threshold":%s,"next_run":"%s","quota":%s,"target":%s,"result":%s,"message":"%s"}\n' \
        "$(availability_enabled && echo true || echo false)" \
        "$_timer" \
        "$(availability_interval_minutes)" \
        "$(availability_probe_limit)" \
        "$(availability_threshold)" \
        "$(json_escape "$(_avail_next_run)")" \
        "$(availability_quota_json)" \
        "$(availability_target_json)" \
        "$_result" \
        "$(json_escape "$_msg")"
}

# ── Таймер ────────────────────────────────────────────────────

availability_timer_active() {
    command -v systemctl &>/dev/null || return 1
    systemctl is-enabled "$AVAILABILITY_TIMER" &>/dev/null
}

# Таймер появился в 1.4.8, и у обновившихся его нет: установщик своё уже
# отработал. Проверка — один stat, установка — только когда его правда нет.
_ensure_availability_timer() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || return 0
    [ -f "$SETTINGS_FILE" ] || return 0
    availability_enabled || return 0
    [ "$(availability_interval_minutes)" -gt 0 ] || return 0
    [ -f "/etc/systemd/system/${AVAILABILITY_TIMER}" ] && return 0
    command -v systemctl &>/dev/null || return 0
    install_availability_timer >/dev/null 2>&1 || true
}

install_availability_timer() {
    command -v systemctl &>/dev/null || return 0
    local _min; _min=$(availability_interval_minutes)
    if ! availability_enabled || [ "$_min" -le 0 ]; then
        remove_availability_timer
        return 0
    fi

    cat > "/etc/systemd/system/${AVAILABILITY_SERVICE}" << EOF
[Unit]
Description=MTProxyL: проверка доступности прокси из России
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# «-»: исчерпанная квота и молчащий сервис — обычное дело, и падающий каждые
# четверть часа юнит в журнале выглядел бы поломкой.
ExecStart=-${INSTALL_DIR}/mtproxyl.sh availability check --quiet
TimeoutStartSec=180
EOF

    cat > "/etc/systemd/system/${AVAILABILITY_TIMER}" << EOF
[Unit]
Description=MTProxyL: проверка доступности из России каждые ${_min} мин

[Timer]
# OnActiveSec, а не OnBootSec: последний у давно загруженного сервера истёк, и
# таймер срабатывал бы сразу после каждой правки интервала — по 20 кредитов.
OnActiveSec=5min
OnUnitActiveSec=${_min}min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload 2>/dev/null
    systemctl enable --now "$AVAILABILITY_TIMER" &>/dev/null
}

remove_availability_timer() {
    command -v systemctl &>/dev/null || return 0
    systemctl disable --now "$AVAILABILITY_TIMER" &>/dev/null
    rm -f "/etc/systemd/system/${AVAILABILITY_TIMER}" "/etc/systemd/system/${AVAILABILITY_SERVICE}"
    systemctl daemon-reload 2>/dev/null
}

# ── Переезд настроек из панели ────────────────────────────────
# До 1.4.8 проверка жила в панели, и токен с целью лежали у неё. Забираем их
# один раз: иначе обновившийся получил бы пустую настройку и анонимную квоту.

_availability_migrate_from_panel() {
    local _marker="${INSTALL_DIR}/availability/.migrated"
    [ -f "$_marker" ] && return 0
    _availability_ensure_dir || return 0

    local _ovr="/var/lib/mtproxyl-panel/availability-target.json"
    local _cfg="/etc/mtproxyl-panel/config.toml"
    local _changed="false"

    if [ -r "$_ovr" ] && command -v jq &>/dev/null; then
        local _h _p _s _tok
        _h=$(jq -r '.host // ""' "$_ovr" 2>/dev/null)
        _p=$(jq -r '.port // ""' "$_ovr" 2>/dev/null)
        _s=$(jq -r '.sni // ""' "$_ovr" 2>/dev/null)
        _tok=$(jq -r '.api_token // ""' "$_ovr" 2>/dev/null)
        [ -n "$_h" ] && [ -z "${AVAILABILITY_HOST:-}" ] && { AVAILABILITY_HOST="$_h"; _changed="true"; }
        [ -n "$_p" ] && [ "$_p" != "0" ] && [ -z "${AVAILABILITY_PORT:-}" ] && { AVAILABILITY_PORT="$_p"; _changed="true"; }
        [ -n "$_s" ] && [ -z "${AVAILABILITY_SNI:-}" ] && { AVAILABILITY_SNI="$_s"; _changed="true"; }
        [ -n "$_tok" ] && [ -z "$(availability_token)" ] && availability_set_token "$_tok" 2>/dev/null
    fi

    if [ -r "$_cfg" ] && [ -z "$(availability_token)" ]; then
        local _ctok _chost
        # Кавычки снимаем и одинарные: в TOML это такая же строка, а конфиг
        # панели правят руками.
        _ctok=$(awk '/^\[globalping\]/{f=1;next} /^\[/{f=0} f && /^[[:space:]]*api_token[[:space:]]*=/{gsub(/.*=[[:space:]]*["'"'"']?|["'"'"'][[:space:]]*$/,""); print; exit}' "$_cfg" 2>/dev/null)
        [ -n "$_ctok" ] && availability_set_token "$_ctok" 2>/dev/null
        _chost=$(awk '/^\[globalping\]/{f=1;next} /^\[/{f=0} f && /^[[:space:]]*override_host[[:space:]]*=/{gsub(/.*=[[:space:]]*["'"'"']?|["'"'"'][[:space:]]*$/,""); print; exit}' "$_cfg" 2>/dev/null)
        [ -n "$_chost" ] && [ -z "${AVAILABILITY_HOST:-}" ] && { AVAILABILITY_HOST="$_chost"; _changed="true"; }
    fi

    [ "$_changed" = "true" ] && save_settings 2>/dev/null
    touch "$_marker" 2>/dev/null
    return 0
}

# ── CLI ───────────────────────────────────────────────────────

# Период автопроверки: минуты пишутся в юнит таймера, поэтому после смены
# его надо переписать — сам он новое значение не подхватит.
_avail_valid_interval() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 1440 ] && return 0
    log_error "Период проверки — целое число минут от 1 до 1440"
    return 1
}

_avail_set_interval() {
    local _min="$1"
    _avail_valid_interval "$_min" || return 1
    AVAILABILITY_INTERVAL="$_min"
    save_settings
    install_availability_timer
    log_success "Период проверки доступности: каждые ${_min} мин"
    if ! availability_enabled; then
        log_info "Автопроверка выключена — период применится после mtproxyl availability on"
        return 0
    fi
    local _probes; _probes=$(availability_probe_limit)
    if [ "$_min" -le 60 ]; then
        log_info "Расход: ${_probes} кредитов за проверку, $(( 60 / _min * _probes )) в час при квоте $(_avail_budget) в час"
    else
        log_info "Расход: ${_probes} кредитов за проверку, $(( 1440 / _min * _probes )) в сутки при квоте $(_avail_budget) в час"
    fi
}

handle_availability_command() {
    local _sub="${1:-status}"; shift 2>/dev/null || true
    case "$_sub" in
        check)
            check_root
            availability_check "$@"
            ;;
        status)
            if [ "${1:-}" = "--json" ]; then
                check_root; availability_status_json "${2:-}"
            else
                check_root; availability_show_status
            fi ;;
        details)
            check_root; availability_status_json --full ;;
        target)
            check_root; availability_target_json; echo "" ;;
        interval|period)
            check_root
            if [ -z "${1:-}" ]; then
                echo -e "  ${BOLD}Период проверки:${NC} $(availability_interval_minutes) мин"
                if availability_enabled && availability_timer_active; then
                    echo -e "  ${BOLD}Таймер:${NC} ${GREEN}включён${NC}, следующая проверка $(_avail_next_run)"
                else
                    echo -e "  ${BOLD}Таймер:${NC} ${DIM}выключен${NC} ${DIM}(mtproxyl availability on)${NC}"
                fi
                echo -e "  ${DIM}Изменить: mtproxyl availability interval <минуты>, 1..1440${NC}"
                return 0
            fi
            _avail_set_interval "$1" || return 1 ;;
        on|enable)
            check_root
            AVAILABILITY_ENABLED="true"
            if [ -n "${1:-}" ]; then
                _avail_valid_interval "$1" || return 1
                AVAILABILITY_INTERVAL="$1"
            fi
            [ "$(availability_interval_minutes)" -gt 0 ] || AVAILABILITY_INTERVAL="15"
            save_settings
            install_availability_timer
            log_success "Автопроверка доступности: каждые $(availability_interval_minutes) мин" ;;
        off|disable)
            check_root
            AVAILABILITY_ENABLED="false"
            save_settings
            remove_availability_timer
            log_success "Автопроверка доступности выключена ${DIM}(проверка вручную по-прежнему доступна)${NC}" ;;
        token)
            check_root
            case "${1:-}" in
                ""|--show)
                    if [ -n "$(availability_token)" ]; then
                        log_info "Токен Globalping задан"
                    else
                        log_info "Токен не задан — квота 250 кредитов в час"
                        log_info "Бесплатный токен: https://dash.globalping.io/"
                    fi ;;
                --clear) availability_set_token "" && log_success "Токен удалён" ;;
                *) availability_set_token "$1" && log_success "Токен сохранён" ;;
            esac ;;
        *)
            echo -e "  ${BOLD}Доступность из России:${NC}"
            echo -e "    ${GREEN}availability status${NC} [--json]  Последний вердикт"
            echo -e "    ${GREEN}availability details${NC}          Вердикт со списком зондов (JSON)"
            echo -e "    ${GREEN}availability check${NC} [--json]   Проверить сейчас"
            echo -e "    ${GREEN}availability target${NC}           Что именно проверяется (JSON)"
            echo -e "    ${GREEN}availability on|off${NC} [мин]     Автопроверка по таймеру"
            echo -e "    ${GREEN}availability interval${NC} [мин]   Период автопроверки, 1..1440"
            echo -e "    ${GREEN}availability token${NC} <токен>    Токен Globalping (--clear чтобы убрать)"
            echo ""
            echo -e "  ${DIM}Число зондов и порог: mtproxyl settings set AVAILABILITY_PROBES|AVAILABILITY_THRESHOLD${NC}"
            ;;
    esac
}
