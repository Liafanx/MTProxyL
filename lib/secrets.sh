#!/bin/bash
# MTProxyL — управление секретами пользователей

# Массивы секретов
declare -a SECRETS_LABELS=()
declare -a SECRETS_KEYS=()
declare -a SECRETS_CREATED=()
declare -a SECRETS_ENABLED=()
declare -a SECRETS_MAX_CONNS=()
declare -a SECRETS_MAX_IPS=()
declare -a SECRETS_QUOTA=()
declare -a SECRETS_EXPIRES=()
declare -a SECRETS_NOTES=()
# Рекламная метка на пользователя ([access.user_ad_tags] у движка). Пусто —
# метки нет; общая метка из настроек остаётся в [general] и не отменяется.
declare -a SECRETS_ADTAG=()

save_secrets() {
    mkdir -p "$INSTALL_DIR"
    local tmp
    tmp=$(_mktemp "$INSTALL_DIR") || { log_error "Не удалось создать временный файл"; return 1; }

    echo "# MTProxyL — база секретов v${VERSION}" > "$tmp"
    echo "# Формат: LABEL|SECRET|CREATED_TS|ENABLED|MAX_CONNS|MAX_IPS|QUOTA_BYTES|EXPIRES|NOTES|AD_TAG" >> "$tmp"

    if [ ${#SECRETS_LABELS[@]} -gt 0 ]; then
        local i
        for i in "${!SECRETS_LABELS[@]}"; do
            # Заметка идёт не последней, поэтому «|» в ней сдвинул бы поля —
            # вырезаем разделитель, а не ломаем строку.
            local _note="${SECRETS_NOTES[$i]:-}"; _note="${_note//|/ }"
            echo "${SECRETS_LABELS[$i]}|${SECRETS_KEYS[$i]}|${SECRETS_CREATED[$i]}|${SECRETS_ENABLED[$i]}|${SECRETS_MAX_CONNS[$i]:-0}|${SECRETS_MAX_IPS[$i]:-0}|${SECRETS_QUOTA[$i]:-0}|${SECRETS_EXPIRES[$i]:-0}|${_note}|${SECRETS_ADTAG[$i]:-}" >> "$tmp"
        done
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$SECRETS_FILE"
}

load_secrets() {
    SECRETS_LABELS=(); SECRETS_KEYS=(); SECRETS_CREATED=(); SECRETS_ENABLED=()
    SECRETS_MAX_CONNS=(); SECRETS_MAX_IPS=(); SECRETS_QUOTA=()
    SECRETS_EXPIRES=(); SECRETS_NOTES=(); SECRETS_ADTAG=()

    [ -f "$SECRETS_FILE" ] || return 0

    while IFS='|' read -r label secret created enabled max_conns max_ips quota expires notes adtag; do
        [[ "$label" =~ ^[[:space:]]*# ]] && continue
        [[ "$label" =~ ^[[:space:]]*$ ]] && continue
        [ -z "$secret" ] && continue
        [[ "$label" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        [[ "$secret" =~ ^[0-9a-fA-F]{32}$ ]] || continue

        local _mc="${max_conns:-0}" _mi="${max_ips:-0}" _q="${quota:-0}" _en="${enabled:-true}"
        [[ "$_mc" =~ ^[0-9]+$ ]] || _mc="0"
        [[ "$_mi" =~ ^[0-9]+$ ]] || _mi="0"
        [[ "$_q" =~ ^[0-9]+$ ]] || _q="0"
        [ "$_en" != "true" ] && [ "$_en" != "false" ] && _en="true"

        SECRETS_LABELS+=("$label")
        SECRETS_KEYS+=("$secret")
        local _cr="${created:-$(date +%s)}"
        [[ "$_cr" =~ ^[0-9]+$ ]] || _cr=$(date +%s)
        SECRETS_CREATED+=("$_cr")
        SECRETS_ENABLED+=("$_en")
        SECRETS_MAX_CONNS+=("$_mc")
        SECRETS_MAX_IPS+=("$_mi")
        SECRETS_QUOTA+=("$_q")
        local _ex="${expires:-0}"
        if [ "$_ex" != "0" ] && ! [[ "$_ex" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:Z+.-]+)?$ ]]; then
            _ex="0"
        fi
        SECRETS_EXPIRES+=("$_ex")
        SECRETS_NOTES+=("${notes:-}")
        # Поля метки нет в базах до 1.4.9 — там она просто пустая.
        local _at="${adtag:-}"
        [[ "$_at" =~ ^[0-9a-fA-F]{32}$ ]] || _at=""
        SECRETS_ADTAG+=("$_at")
    done < "$SECRETS_FILE"
}

# Импорт: понимает и экспорт из меню, и файл базы секретов. Формат
# распознаётся по третьему полю — у базы там метка времени (issue #29).
secret_import_file() {
    local _file="${1:-}"
    [ -f "$_file" ] || { log_error "Файл не найден: ${_file}"; return 1; }

    local _added=0 _dup=0 _bad=0 _line
    while IFS= read -r _line || [ -n "$_line" ]; do
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$_line" =~ ^[[:space:]]*$ ]] && continue

        local _oldIFS="$IFS"
        declare -a _f=()
        IFS='|' read -ra _f <<< "$_line"
        IFS="$_oldIFS"

        local _l="${_f[0]:-}" _k="${_f[1]:-}"
        [[ "$_l" =~ ^[a-zA-Z0-9_-]+$ ]] && [ ${#_l} -le 32 ] || { _bad=$((_bad + 1)); continue; }
        [[ "$_k" =~ ^[0-9a-fA-F]{32}$ ]] || { _bad=$((_bad + 1)); continue; }

        local _cr _en _mc _mi _q _ex _n _at
        if [[ "${_f[2]:-}" =~ ^[0-9]{9,}$ ]]; then
            _cr="${_f[2]}";     _en="${_f[3]:-true}"; _mc="${_f[4]:-0}"; _mi="${_f[5]:-0}"
            _q="${_f[6]:-0}";   _ex="${_f[7]:-0}";    _n="${_f[8]:-}";   _at="${_f[9]:-}"
        else
            _cr="$(date +%s)";  _en="${_f[2]:-true}"; _mc="${_f[3]:-0}"; _mi="${_f[4]:-0}"
            _q="${_f[5]:-0}";   _ex="${_f[6]:-0}";    _n="${_f[7]:-}";   _at="${_f[8]:-}"
        fi

        local _i _exists=false
        for _i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_LABELS[$_i]}" = "$_l" ] && { _exists=true; break; }
        done
        if $_exists; then _dup=$((_dup + 1)); continue; fi

        # Те же проверки, что в load_secrets: чужой файл приносит что угодно.
        [[ "$_mc" =~ ^[0-9]+$ ]] || _mc="0"
        [[ "$_mi" =~ ^[0-9]+$ ]] || _mi="0"
        [[ "$_q"  =~ ^[0-9]+$ ]] || _q="0"
        [ "$_en" = "true" ] || [ "$_en" = "false" ] || _en="true"
        if [ "$_ex" != "0" ] && ! [[ "$_ex" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:Z+.-]+)?$ ]]; then
            _ex="0"
        fi
        [[ "$_at" =~ ^[0-9a-fA-F]{32}$ ]] || _at=""

        SECRETS_LABELS+=("$_l");   SECRETS_KEYS+=("$_k")
        SECRETS_CREATED+=("$_cr"); SECRETS_ENABLED+=("$_en")
        SECRETS_MAX_CONNS+=("$_mc"); SECRETS_MAX_IPS+=("$_mi")
        SECRETS_QUOTA+=("$_q");    SECRETS_EXPIRES+=("$_ex")
        SECRETS_NOTES+=("${_n//|/ }"); SECRETS_ADTAG+=("$_at")
        _added=$((_added + 1))
    done < "$_file"

    if [ "$_added" -gt 0 ]; then
        save_secrets
        reload_proxy_config 2>/dev/null || true
    fi
    log_success "Импортировано: ${_added}, пропущено дубликатов: ${_dup}, строк с ошибкой: ${_bad}"
    return 0
}

# Экспорт секретов в файл того же формата, что читает secret_import_file.
secret_export_file() {
    local _file="${1:-}"
    [ -n "$_file" ] || { log_error "Требуется имя файла"; return 1; }

    local _tmp; _tmp=$(_mktemp "$(dirname "$_file")") || { log_error "Не удалось создать временный файл"; return 1; }
    echo "# label|key|enabled|max_conns|max_ips|quota|expires|notes|ad_tag" > "$_tmp"
    local _i
    for _i in "${!SECRETS_LABELS[@]}"; do
        # «|» в заметке сдвинул бы поля при обратном импорте.
        local _note="${SECRETS_NOTES[$_i]:-}"; _note="${_note//|/ }"
        echo "${SECRETS_LABELS[$_i]}|${SECRETS_KEYS[$_i]}|${SECRETS_ENABLED[$_i]}|${SECRETS_MAX_CONNS[$_i]:-0}|${SECRETS_MAX_IPS[$_i]:-0}|${SECRETS_QUOTA[$_i]:-0}|${SECRETS_EXPIRES[$_i]:-0}|${_note}|${SECRETS_ADTAG[$_i]:-}" >> "$_tmp"
    done
    chmod 600 "$_tmp"
    mv "$_tmp" "$_file"
    log_success "Экспортировано ${#SECRETS_LABELS[@]} секретов в ${_file}"
}

# Добавить секрет
secret_add() {
    local label="$1" custom_secret="${2:-}" no_restart="${3:-false}"

    [ -z "$label" ] && { log_error "Требуется метка"; return 1; }
    [[ "$label" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Метка: только a-z, 0-9, _, -"; return 1; }
    [ ${#label} -gt 32 ] && { log_error "Метка: максимум 32 символа"; return 1; }

    local i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { log_error "Секрет '${label}' уже существует"; return 1; }
    done

    local raw_secret="${custom_secret:-$(generate_secret)}"
    [[ "$raw_secret" =~ ^[0-9a-fA-F]{32}$ ]] || { log_error "Секрет: ровно 32 hex-символа"; return 1; }

    SECRETS_LABELS+=("$label")
    SECRETS_KEYS+=("$raw_secret")
    SECRETS_CREATED+=("$(date +%s)")
    SECRETS_ENABLED+=("true")
    SECRETS_MAX_CONNS+=("0")
    SECRETS_MAX_IPS+=("0")
    SECRETS_QUOTA+=("0")
    SECRETS_EXPIRES+=("0")
    SECRETS_NOTES+=("")
    SECRETS_ADTAG+=("")

    save_secrets
    [ "$no_restart" != "true" ] && reload_proxy_config 2>/dev/null || true

    local server_ip server_port
    server_ip=$(proxy_link_host)
    server_port=$(proxy_link_port)

    log_success "Секрет '${label}' создан"
    echo ""
    _print_secret_links "$server_ip" "$server_port" "$raw_secret"
    echo ""
}

# Ссылки одного секрета всех включённых видов. QR в терминале не рисуем:
# в узком окне он рассыпается, а ссылку всё равно копируют текстом.
_print_secret_links() {
    local _ip="$1" _port="$2" _raw="$3"
    local _kind _sec _title
    while IFS='|' read -r _kind _sec; do
        [ -n "$_sec" ] || continue
        _title="$(link_kind_title "$_kind")"
        echo -e "  ${BOLD}Ссылка для Telegram${NC} ${DIM}(${_title})${NC}"
        echo -e "  ${CYAN}tg://proxy?server=${_ip}&port=${_port}&secret=${_sec}${NC}"
        echo -e "  ${BOLD}Веб-ссылка${NC} ${DIM}(${_title})${NC}"
        echo -e "  ${CYAN}https://t.me/proxy?server=${_ip}&port=${_port}&secret=${_sec}${NC}"
        echo ""
    done <<< "$(build_link_secrets "$_raw")"

    # WEB — отдельный тип прокси со своим доменом и без порта в ссылке.
    if web_is_enabled 2>/dev/null; then
        local _wl; _wl=$(web_link_for_secret "$_raw" 2>/dev/null)
        if [ -n "$_wl" ]; then
            echo -e "  ${BOLD}Ссылка для Telegram${NC} ${DIM}(WEB)${NC}"
            echo -e "  ${CYAN}${_wl}${NC}"
            echo ""
        fi
    fi
}

# Удалить секрет
secret_remove() {
    local label="$1" force="${2:-false}" no_restart="${3:-false}"

    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }
    [ ${#SECRETS_LABELS[@]} -le 1 ] && { log_error "Нельзя удалить последний секрет"; return 1; }

    if [ "$force" != "true" ] && [ -t 0 ]; then
        echo -e "  ${YELLOW}Удалить секрет '${label}'? Пользователи с этим ключом будут отключены.${NC}"
        echo -en "  ${BOLD}Введите 'yes':${NC} "
        local confirm; read_line confirm
        [ "$confirm" != "yes" ] && { log_info "Отменено"; return 0; }
    fi

    local -a nl=() nk=() nc=() ne=() nmc=() nmi=() nq=() nex=() nn=() nat=()
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "$i" -eq "$idx" ] && continue
        nl+=("${SECRETS_LABELS[$i]}"); nk+=("${SECRETS_KEYS[$i]}")
        nc+=("${SECRETS_CREATED[$i]}"); ne+=("${SECRETS_ENABLED[$i]}")
        nmc+=("${SECRETS_MAX_CONNS[$i]:-0}"); nmi+=("${SECRETS_MAX_IPS[$i]:-0}")
        nq+=("${SECRETS_QUOTA[$i]:-0}"); nex+=("${SECRETS_EXPIRES[$i]:-0}")
        nn+=("${SECRETS_NOTES[$i]:-}"); nat+=("${SECRETS_ADTAG[$i]:-}")
    done
    SECRETS_LABELS=("${nl[@]}"); SECRETS_KEYS=("${nk[@]}")
    SECRETS_CREATED=("${nc[@]}"); SECRETS_ENABLED=("${ne[@]}")
    SECRETS_MAX_CONNS=("${nmc[@]}"); SECRETS_MAX_IPS=("${nmi[@]}")
    SECRETS_QUOTA=("${nq[@]}"); SECRETS_EXPIRES=("${nex[@]}")
    SECRETS_NOTES=("${nn[@]}"); SECRETS_ADTAG=("${nat[@]}")

    save_secrets
    [ "$no_restart" != "true" ] && reload_proxy_config 2>/dev/null || true
    log_success "Секрет '${label}' удалён"
}

# Ротация секрета
secret_rotate() {
    local label="$1"
    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }

    local new_secret
    new_secret=$(generate_secret)
    SECRETS_KEYS[$idx]="$new_secret"
    SECRETS_CREATED[$idx]="$(date +%s)"

    save_secrets
    reload_proxy_config 2>/dev/null || true

    local server_ip server_port
    server_ip=$(proxy_link_host)
    server_port=$(proxy_link_port)

    log_success "Секрет '${label}' обновлён"
    echo ""
    _print_secret_links "$server_ip" "$server_port" "$new_secret"
}

# Включить/выключить секрет
secret_toggle() {
    local label="$1" action="${2:-toggle}"
    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }

    local _will_disable=false
    case "$action" in
        enable)  SECRETS_ENABLED[$idx]="true" ;;
        disable) _will_disable=true; SECRETS_ENABLED[$idx]="false" ;;
        toggle)
            if [ "${SECRETS_ENABLED[$idx]}" = "true" ]; then
                _will_disable=true; SECRETS_ENABLED[$idx]="false"
            else
                SECRETS_ENABLED[$idx]="true"
            fi ;;
    esac

    if $_will_disable; then
        local _en_count=0
        for i in "${!SECRETS_ENABLED[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && _en_count=$((_en_count + 1))
        done
        if [ "$_en_count" -eq 0 ]; then
            SECRETS_ENABLED[$idx]="true"
            log_error "Нельзя отключить последний активный секрет"
            return 1
        fi
    fi

    save_secrets
    reload_proxy_config 2>/dev/null || true
    log_success "Секрет '${label}': ${SECRETS_ENABLED[$idx]}"
}

# Установить лимиты
# Срок действия в том виде, в каком его понимает движок: голая дата для него
# не значение времени, а обрывок, и конфиг с ней он читать отказывается —
# у цели реаниматора это означает, что она больше не стартует.
# Возвращает "0", если срок снимают.
_normalize_expiry() {
    local _v="$1"
    case "$_v" in
        ""|0|never|нет) echo "0"; return 0 ;;
    esac
    # Форму проверяем регуляркой, существование даты — календарём: 2027-13-99
    # выглядит правильно, но движок его не примет и цель не поднимется.
    if [[ "$_v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        date -d "$_v" +%s &>/dev/null || { log_error "Такой даты не существует: ${_v}"; return 1; }
        # «до 1 января» человек понимает как «включая первое».
        echo "${_v}T23:59:59Z"; return 0
    fi
    if [[ "$_v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]]; then
        date -d "$_v" +%s &>/dev/null || { log_error "Такой даты не существует: ${_v}"; return 1; }
        echo "$_v"; return 0
    fi
    log_error "Срок: YYYY-MM-DD, полная дата RFC3339 или 0"
    return 1
}

secret_set_limits() {
    local label="$1" max_conns="${2:-}" max_ips="${3:-}" quota="${4:-}" expires="${5:-}"
    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }

    if [ -n "$max_conns" ]; then
        [[ "$max_conns" =~ ^[0-9]+$ ]] || { log_error "Макс. соединений: число"; return 1; }
        SECRETS_MAX_CONNS[$idx]="$max_conns"
    fi
    if [ -n "$max_ips" ]; then
        [[ "$max_ips" =~ ^[0-9]+$ ]] || { log_error "Макс. IP: число"; return 1; }
        SECRETS_MAX_IPS[$idx]="$max_ips"
    fi
    if [ -n "$quota" ]; then
        local quota_bytes
        quota_bytes=$(parse_human_bytes "$quota") || { log_error "Квота: напр. 5G, 500M, 0"; return 1; }
        SECRETS_QUOTA[$idx]="$quota_bytes"
    fi
    if [ -n "$expires" ]; then
        local _exp
        _exp=$(_normalize_expiry "$expires") || return 1
        SECRETS_EXPIRES[$idx]="$_exp"
    fi

    save_secrets
    reload_proxy_config 2>/dev/null || true
    log_success "Лимиты обновлены для '${label}'"
}

# Рекламная метка отдельного пользователя — секция [access.user_ad_tags]
# у движка. Общая метка в [general] от этого не отменяется: она остаётся для
# всех, у кого своей нет.
secret_set_adtag() {
    local label="$1" tag="${2:-}"
    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }

    case "$tag" in
        remove|none|"-"|"0")
            SECRETS_ADTAG[$idx]=""
            save_secrets
            reload_proxy_config 2>/dev/null || true
            log_success "Метка снята с '${label}'"
            return 0 ;;
    esac
    if [ -z "$tag" ]; then
        echo "${SECRETS_ADTAG[$idx]:-}"
        return 0
    fi
    if ! [[ "$tag" =~ ^[0-9a-fA-F]{32}$ ]]; then
        log_error "Метка: ровно 32 hex-символа (её выдаёт @MTProxybot)"
        return 1
    fi
    SECRETS_ADTAG[$idx]="$tag"
    save_secrets
    reload_proxy_config 2>/dev/null || true
    log_success "Метка задана для '${label}'"
}

# Список секретов
# Человекочитаемые лимиты секрета: соединения, IP, квота трафика, срок.
# Пустые (0) не показываем — иначе колонка превращается в шум.
_secret_limits_text() {
    local _i="$1" _used="${2:-0}"
    local _mc="${SECRETS_MAX_CONNS[$_i]:-0}"
    local _mi="${SECRETS_MAX_IPS[$_i]:-0}"
    local _q="${SECRETS_QUOTA[$_i]:-0}"
    local _ex="${SECRETS_EXPIRES[$_i]:-0}"
    local _out=""

    [ "$_mc" != "0" ] && [ -n "$_mc" ] && _out="соед ${_mc}"
    if [ "$_mi" != "0" ] && [ -n "$_mi" ]; then
        [ -n "$_out" ] && _out+=" · "
        _out+="IP ${_mi}"
    fi
    if [ "$_q" != "0" ] && [ -n "$_q" ] && [[ "$_q" =~ ^[0-9]+$ ]]; then
        [ -n "$_out" ] && _out+=" · "
        local _pct=""
        if [ "${_used:-0}" -gt 0 ] 2>/dev/null; then
            _pct=$(awk -v u="$_used" -v q="$_q" 'BEGIN{printf "%.0f", (u*100)/q}')
            _out+="квота $(format_bytes "$_q") (${_pct}%)"
        else
            _out+="квота $(format_bytes "$_q")"
        fi
    fi
    if [ "$_ex" != "0" ] && [ -n "$_ex" ]; then
        [ -n "$_out" ] && _out+=" · "
        local _ex_epoch; _ex_epoch=$(_iso_to_epoch "$_ex")
        local _ex_fmt="${_ex%%T*}"
        if [ "${_ex_epoch:-0}" -gt 0 ] 2>/dev/null && [ "$_ex_epoch" -lt "$(date +%s)" ]; then
            _out+="истёк ${_ex_fmt}"
        else
            _out+="до ${_ex_fmt}"
        fi
    fi

    [ -n "$_out" ] && echo "$_out" || echo "—"
}

# Машинный список секретов для панели. В менеджере движок записать
# пользователя не может — владелец здесь MTProxyL.
# Секрет отдаём: без него не собрать ссылки tg://. Только root.
_USER_IPS_DB="${INSTALL_DIR}/relay_stats/user_ips_db"
_TARGET_USER_IPS_DB="${INSTALL_DIR}/relay_stats/target_user_ips_db"

# Построить массив истории IP одного пользователя как JSON.
_user_ip_history_json() {
    local _label="$1" _db_file="$2" _first=1 _ip _fs _ls
    printf '['
    while IFS='|' read -r _ip _fs _ls; do
        [ -n "$_ip" ] || continue
        [ $_first -eq 1 ] || printf ','
        _first=0
        printf '{"ip":"%s","first_seen":%s,"last_seen":%s}' "$(json_escape "$_ip")" "${_fs:-0}" "${_ls:-0}"
    done < <(_user_ip_history "$_label" "$_db_file")
    printf ']'
}

secret_list_json() {
    load_secrets
    # Раз увиденный IP остаётся в истории и после того, как сессия
    # закончилась — сначала копим свежие данные из API движка (если он
    # отвечает), потом читаем историю уже из файла.
    local _json
    if _json=$(_get_telemt_users_json "$(_engine_config_path)" 2>/dev/null); then
        _target_user_ip_lists "$_json" | _flush_user_ip_history "$_USER_IPS_DB"
    fi

    # Статистика собирается один раз на весь список: раньше is_proxy_running
    # (реальный docker inspect) и метрики считались на каждого пользователя.
    declare -A _DB_USER_IN _DB_USER_OUT
    local _DB_TOTAL_IN=0 _DB_TOTAL_OUT=0
    _load_traffic_db

    local _running=false
    is_proxy_running 2>/dev/null && _running=true

    declare -A _CUR_USER_IN _CUR_USER_OUT
    if $_running; then
        local _m
        if _m=$(_fetch_metrics); then
            local _pu _pi _po
            while IFS='|' read -r _pu _pi _po; do
                [ -n "$_pu" ] || continue
                _CUR_USER_IN["$_pu"]="${_pi:-0}"
                _CUR_USER_OUT["$_pu"]="${_po:-0}"
            done < <(echo "$_m" | awk '
                function lbl(s, k,    p, q) {
                    p = index(s, k "=\""); if (!p) return ""
                    s = substr(s, p + length(k) + 2)
                    q = index(s, "\""); return q ? substr(s, 1, q-1) : ""
                }
                /^telemt_user_octets_from_client\{/ { u=lbl($0,"user"); if(u) { rx[u]+=$NF; seen[u]=1 } }
                /^telemt_user_octets_to_client\{/   { u=lbl($0,"user"); if(u) { tx[u]+=$NF; seen[u]=1 } }
                END { for (u in seen) printf "%s|%.0f|%.0f\n", u, rx[u]+0, tx[u]+0 }
            ')
        fi
    fi

    declare -A _SNAP_USER_IN _SNAP_USER_OUT
    local _user_snap_file="${INSTALL_DIR}/relay_stats/user_session_snapshot"
    if [ -f "$_user_snap_file" ]; then
        local _spu _spi _spo
        while IFS='|' read -r _spu _spi _spo; do
            [ -n "$_spu" ] || continue
            _SNAP_USER_IN["$_spu"]="${_spi:-0}"
            _SNAP_USER_OUT["$_spu"]="${_spo:-0}"
        done < "$_user_snap_file"
    fi

    declare -A _IP_HIST_JSON
    if [ -f "$_USER_IPS_DB" ]; then
        local _ht _hu _hip _hfs _hls _entry
        while IFS='|' read -r _ht _hu _hip _hfs _hls; do
            [ "$_ht" = "USER" ] || continue
            [ -n "$_hu" ] && [ -n "$_hip" ] || continue
            json_escape_fast "$_hip"
            _entry="{\"ip\":\"${_JSON_ESCAPE_OUT}\",\"first_seen\":${_hfs:-0},\"last_seen\":${_hls:-0}}"
            if [ -z "${_IP_HIST_JSON[$_hu]+x}" ]; then
                _IP_HIST_JSON["$_hu"]="$_entry"
            else
                _IP_HIST_JSON["$_hu"]="${_IP_HIST_JSON[$_hu]},$_entry"
            fi
        done < "$_USER_IPS_DB"
    fi

    # Дальше ни одного "$(...)": подстановка форкает подшелл на каждый вызов.
    # json_escape_fast кладёт результат в переменную вместо stdout.
    local _i _first=1 _label _uin _uout _cur_in _cur_out _snap_in _snap_out _unsaved_in _unsaved_out
    local _label_esc _secret_esc _expires_esc _notes_esc _enabled_str
    printf '['
    for _i in "${!SECRETS_LABELS[@]}"; do
        [ $_first -eq 1 ] || printf ','
        _first=0
        _label="${SECRETS_LABELS[$_i]}"

        _cur_in="${_CUR_USER_IN[$_label]:-0}"
        _cur_out="${_CUR_USER_OUT[$_label]:-0}"
        _snap_in="${_SNAP_USER_IN[$_label]:-0}"
        _snap_out="${_SNAP_USER_OUT[$_label]:-0}"
        [[ "$_snap_in" =~ ^[0-9]+$ ]] || _snap_in=0
        [[ "$_snap_out" =~ ^[0-9]+$ ]] || _snap_out=0

        if [ "${_cur_in:-0}" -ge "$_snap_in" ] 2>/dev/null; then
            _unsaved_in=$(( ${_cur_in:-0} - _snap_in ))
        else
            _unsaved_in="${_cur_in:-0}"
        fi
        if [ "${_cur_out:-0}" -ge "$_snap_out" ] 2>/dev/null; then
            _unsaved_out=$(( ${_cur_out:-0} - _snap_out ))
        else
            _unsaved_out="${_cur_out:-0}"
        fi

        _uin=$(( ${_DB_USER_IN[$_label]:-0} + _unsaved_in ))
        _uout=$(( ${_DB_USER_OUT[$_label]:-0} + _unsaved_out ))

        json_escape_fast "$_label";                       _label_esc="$_JSON_ESCAPE_OUT"
        json_escape_fast "${SECRETS_KEYS[$_i]}";           _secret_esc="$_JSON_ESCAPE_OUT"
        json_escape_fast "${SECRETS_EXPIRES[$_i]:-0}";     _expires_esc="$_JSON_ESCAPE_OUT"
        json_escape_fast "${SECRETS_NOTES[$_i]:-}";        _notes_esc="$_JSON_ESCAPE_OUT"
        if [ "${SECRETS_ENABLED[$_i]}" = "true" ]; then _enabled_str=true; else _enabled_str=false; fi

        printf '{"label":"%s","secret":"%s","created":%s,"enabled":%s,"max_conns":%s,"max_ips":%s,"quota_bytes":%s,"expires":"%s","notes":"%s","ad_tag":"%s","total_in":%s,"total_out":%s,"total_bytes":%s,"ip_history":[%s]}' \
            "$_label_esc" \
            "$_secret_esc" \
            "${SECRETS_CREATED[$_i]:-0}" \
            "$_enabled_str" \
            "${SECRETS_MAX_CONNS[$_i]:-0}" \
            "${SECRETS_MAX_IPS[$_i]:-0}" \
            "${SECRETS_QUOTA[$_i]:-0}" \
            "$_expires_esc" \
            "$_notes_esc" \
            "${SECRETS_ADTAG[$_i]:-}" \
            "${_uin:-0}" "${_uout:-0}" "$(( ${_uin:-0} + ${_uout:-0} ))" \
            "${_IP_HIST_JSON[$_label]:-}"
    done
    printf ']\n'
}

secret_list() {
    load_secrets
    if [ ${#SECRETS_LABELS[@]} -eq 0 ]; then
        log_info "Нет настроенных секретов"
        echo -e "  ${DIM}Выполните: mtproxyl secret add <метка>${NC}"
        return
    fi

    echo ""
    draw_header "СЕКРЕТЫ"
    echo ""
    # Ширины считаем в символах (_pad), а не байтах: с printf %-Ns
    # кириллица в шапке разъезжалась относительно строк.
    echo -e "  ${BOLD}$(_pad '#' 3) $(_pad 'МЕТКА' 16) $(_pad 'СТАТУС' 9) $(_pad 'СОЗДАН' 11) $(_pad 'СКАЧАНО' 11) $(_pad 'ОТПРАВЛЕНО' 11) ЛИМИТЫ${NC}"
    echo -e "  ${DIM}$(_repeat '─' 100)${NC}"

    local i
    for i in "${!SECRETS_LABELS[@]}"; do
        local label="${SECRETS_LABELS[$i]}"
        local enabled="${SECRETS_ENABLED[$i]}"
        local created="${SECRETS_CREATED[$i]}"

        local status_plain status_color
        if [ "$enabled" = "true" ]; then
            status_plain="активен"; status_color="$GREEN"
        else
            status_plain="выключен"; status_color="$RED"
        fi

        local created_fmt
        created_fmt=$(printf '%(%Y-%m-%d)T' "$created" 2>/dev/null) || \
            created_fmt=$(date -d "@${created}" '+%Y-%m-%d' 2>/dev/null || echo "?")

        local u_in=0 u_out=0 u_conns=0
        read -r u_in u_out u_conns <<< "$(get_persistent_user_stats "$label" 2>/dev/null)" || true

        local _limits; _limits=$(_secret_limits_text "$i" "$(( ${u_in:-0} + ${u_out:-0} ))")

        echo -e "  $(_pad "$((i+1))" 3) $(_pad "$(_ellipsis "$label" 16)" 16) ${status_color}$(_pad "$status_plain" 9)${NC} $(_pad "$created_fmt" 11) $(_pad "$(format_bytes "${u_in:-0}")" 11) $(_pad "$(format_bytes "${u_out:-0}")" 11) ${DIM}${_limits}${NC}"

        [ -n "${SECRETS_NOTES[$i]:-}" ] && echo -e "      ${DIM}📝 ${SECRETS_NOTES[$i]}${NC}"
    done
    echo ""
}
# Все рабочие ссылки секрета — по одной в строке. С выключенной маскировкой
# движок принимает и dd, и ee, и обе ссылки настоящие.
get_proxy_links() {
    local label="${1:-}"
    local server_ip server_port
    server_ip=$(proxy_link_host)
    server_port=$(proxy_link_port)

    if [ -z "$label" ]; then
        local i
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && { label="${SECRETS_LABELS[$i]}"; break; }
        done
    fi
    [ -z "$label" ] && { log_error "Нет активных секретов"; return 1; }

    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }

    local _kind _sec
    while IFS='|' read -r _kind _sec; do
        [ -n "$_sec" ] || continue
        echo "tg://proxy?server=${server_ip}&port=${server_port}&secret=${_sec}"
    done <<< "$(build_link_secrets "${SECRETS_KEYS[$idx]}")"

    # WEB — отдельный тип прокси: свой домен, свой префикс секрета, без порта.
    web_is_enabled 2>/dev/null && web_link_for_secret "${SECRETS_KEYS[$idx]}" 2>/dev/null
    return 0
}

# Одна ссылка — первая из списка. Её ждут те, кто читает вывод строкой:
# QR-код и телеграм-бот.
get_proxy_link() {
    local _links
    _links=$(get_proxy_links "${1:-}") || return 1
    printf '%s\n' "$_links" | head -1
}

# Получить список меток включённых секретов для конфига
get_enabled_labels_quoted() {
    local result="" first=true i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        if $first; then result="\"${SECRETS_LABELS[$i]}\""; first=false
        else result+=", \"${SECRETS_LABELS[$i]}\""; fi
    done
    echo "$result"
}

# Клонирование секрета
secret_clone() {
    local src="$1" new="$2"
    [ -z "$src" ] || [ -z "$new" ] && { log_error "Использование: secret clone <источник> <новая_метка>"; return 1; }
    [[ "$new" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Метка: только a-z, 0-9, _, -"; return 1; }

    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$src" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${src}' не найден"; return 1; }

    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$new" ] && { log_error "Секрет '${new}' уже существует"; return 1; }
    done

    SECRETS_LABELS+=("$new")
    SECRETS_KEYS+=("$(generate_secret)")
    SECRETS_CREATED+=("$(date +%s)")
    SECRETS_ENABLED+=("true")
    SECRETS_MAX_CONNS+=("${SECRETS_MAX_CONNS[$idx]:-0}")
    SECRETS_MAX_IPS+=("${SECRETS_MAX_IPS[$idx]:-0}")
    SECRETS_QUOTA+=("${SECRETS_QUOTA[$idx]:-0}")
    SECRETS_EXPIRES+=("${SECRETS_EXPIRES[$idx]:-0}")
    SECRETS_NOTES+=("${SECRETS_NOTES[$idx]:-}")
    SECRETS_ADTAG+=("${SECRETS_ADTAG[$idx]:-}")

    save_secrets
    reload_proxy_config 2>/dev/null || true

    local server_ip server_port
    server_ip=$(proxy_link_host)
    server_port=$(proxy_link_port)
    log_success "Секрет '${new}' клонирован из '${src}'"
    _print_secret_links "$server_ip" "$server_port" "${SECRETS_KEYS[-1]}"
}

# Переименование
secret_rename() {
    local old="$1" new="$2"
    [ -z "$old" ] || [ -z "$new" ] && { log_error "Использование: secret rename <старая> <новая>"; return 1; }
    [[ "$new" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Метка: только a-z, 0-9, _, -"; return 1; }

    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do [ "${SECRETS_LABELS[$i]}" = "$old" ] && { idx=$i; break; }; done
    [ $idx -eq -1 ] && { log_error "Секрет '${old}' не найден"; return 1; }
    for i in "${!SECRETS_LABELS[@]}"; do [ "${SECRETS_LABELS[$i]}" = "$new" ] && { log_error "'${new}' уже существует"; return 1; }; done

    SECRETS_LABELS[$idx]="$new"
    save_secrets
    reload_proxy_config 2>/dev/null || true
    log_success "Переименован: '${old}' → '${new}'"
}

# Показать лимиты
secret_show_limits() {
    local label="${1:-}"
    if [ -z "$label" ]; then
        echo ""
        draw_header "ЛИМИТЫ ПОЛЬЗОВАТЕЛЕЙ"
        echo ""
        printf "  ${BOLD}%-4s %-16s %-10s %-8s %-12s %-14s${NC}\n" "#" "МЕТКА" "СОЕД." "IP" "КВОТА" "СРОК"
        echo -e "  ${DIM}$(_repeat '─' 70)${NC}"
        local i
        for i in "${!SECRETS_LABELS[@]}"; do
            local c="${SECRETS_MAX_CONNS[$i]:-0}" p="${SECRETS_MAX_IPS[$i]:-0}"
            local q="${SECRETS_QUOTA[$i]:-0}" e="${SECRETS_EXPIRES[$i]:-0}"
            [ "$c" = "0" ] && c="${DIM}∞${NC}" ; [ "$p" = "0" ] && p="${DIM}∞${NC}"
            [ "$q" = "0" ] && q="${DIM}∞${NC}" || q="$(format_bytes "$q")"
            [ "$e" = "0" ] && e="${DIM}нет${NC}" || e="${e%%T*}"
            printf "  %-4s %-16s %-10b %-8b %-12b %-14b\n" "$((i+1))" "${SECRETS_LABELS[$i]}" "$c" "$p" "$q" "$e"
        done
        echo ""
    else
        local idx=-1 i
        for i in "${!SECRETS_LABELS[@]}"; do [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }; done
        [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }
        local c="${SECRETS_MAX_CONNS[$idx]:-0}" p="${SECRETS_MAX_IPS[$idx]:-0}"
        local q="${SECRETS_QUOTA[$idx]:-0}" e="${SECRETS_EXPIRES[$idx]:-0}"
        echo ""
        echo -e "  ${BOLD}Лимиты '${label}':${NC}"
        echo -e "  Макс. TCP соединений: $([ "$c" = "0" ] && echo "без ограничений" || echo "$c")"
        echo -e "  Макс. уникальных IP:  $([ "$p" = "0" ] && echo "без ограничений" || echo "$p")"
        echo -e "  Квота трафика:        $([ "$q" = "0" ] && echo "без ограничений" || echo "$(format_bytes "$q")")"
        echo -e "  Срок действия:        $([ "$e" = "0" ] && echo "бессрочно" || echo "$e")"
        echo ""
    fi
}

# ═══════════════════════════════════════════════════════════════
#  Пользователи цели (режим реаниматора)
# ═══════════════════════════════════════════════════════════════
# Источник правды — [access.users] цели, пишем прямо в её файле.
# Выключенный пользователь остаётся закомментированным.
_TARGET_USER_MARK='#mtproxyl-off '

# Секции цели, где пользователь упоминается по метке. Порядок важен только для
# вывода — удаляем и переименовываем во всех.
_TARGET_LIMIT_SECTIONS='access.user_max_tcp_conns access.user_max_unique_ips access.user_data_quota access.user_expirations access.user_ad_tags'

_target_users_ready() {
    if [ -z "${DETECTED_CONFIG_PATH:-}" ] || [ ! -f "$DETECTED_CONFIG_PATH" ]; then
        log_error "Конфиг цели не найден — выполните 'mtproxyl detect'"
        return 1
    fi
    return 0
}

# Строки «состояние|ключ|значение» из секции цели. Выключенные пользователи
# помечены own-префиксом, поэтому возвращаются наравне с активными.
_target_section_pairs() {
    local _sect="$1" _file="${2:-$DETECTED_CONFIG_PATH}"
    awk -v sect="[${_sect}]" -v mark="$_TARGET_USER_MARK" '
        BEGIN { insect = 0 }
        {
            t = $0; sub(/^[[:space:]]+/, "", t)
            if (t ~ /^\[/) { insect = (t == sect) ? 1 : 0; next }
            if (!insect) next
            off = 0
            if (substr(t, 1, length(mark)) == mark) {
                off = 1; t = substr(t, length(mark) + 1)
                sub(/^[[:space:]]+/, "", t)
            } else if (t ~ /^#/) next
            if (t !~ /^[A-Za-z0-9_.-]+[[:space:]]*=/) next
            eq = index(t, "=")
            name = substr(t, 1, eq - 1); val = substr(t, eq + 1)
            sub(/[[:space:]]*#.*$/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            gsub(/^["'"'"']|["'"'"']$/, "", val)
            if (name == "" || val == "") next
            print (off ? "off" : "on") "|" name "|" val
        }
    ' "$_file" 2>/dev/null
}

# Удаление ключа из своей секции. Пишем через cat >, чтобы у чужого файла
# сохранились владелец и права — как в _toml_safe_set.
_toml_safe_unset() {
    local _key="$1" _section="$2" _file="$3"
    [ -f "$_file" ] || return 1
    local _tmp; _tmp=$(_mktemp) || return 1
    awk -v sect="[${_section}]" -v k="$_key" -v mark="$_TARGET_USER_MARK" '
        BEGIN { insect = 0 }
        {
            t = $0; sub(/^[[:space:]]+/, "", t)
            if (t ~ /^\[/) { insect = (t == sect) ? 1 : 0; print; next }
            if (insect) {
                s = t
                if (substr(s, 1, length(mark)) == mark) {
                    s = substr(s, length(mark) + 1); sub(/^[[:space:]]+/, "", s)
                }
                if (s ~ ("^" k "[[:space:]]*=")) next
            }
            print
        }
    ' "$_file" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    [ -s "$_tmp" ] || { rm -f "$_tmp"; return 1; }
    cat "$_tmp" > "$_file" || { rm -f "$_tmp"; return 1; }
    rm -f "$_tmp"
}

# Комментирование и обратно — без потери самой строки.
_toml_toggle_key() {
    local _key="$1" _section="$2" _file="$3" _want="$4"
    [ -f "$_file" ] || return 1
    local _tmp; _tmp=$(_mktemp) || return 1
    awk -v sect="[${_section}]" -v k="$_key" -v mark="$_TARGET_USER_MARK" -v want="$_want" '
        BEGIN { insect = 0; hit = 0 }
        {
            line = $0
            t = line; sub(/^[[:space:]]+/, "", t)
            if (t ~ /^\[/) { insect = (t == sect) ? 1 : 0; print line; next }
            if (insect) {
                s = t; off = 0
                if (substr(s, 1, length(mark)) == mark) {
                    off = 1; s = substr(s, length(mark) + 1); sub(/^[[:space:]]+/, "", s)
                }
                if (s ~ ("^" k "[[:space:]]*=")) {
                    hit = 1
                    if (want == "off") print (off ? line : mark s)
                    else print s
                    next
                }
            }
            print line
        }
        END { exit hit ? 0 : 1 }
    ' "$_file" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    [ -s "$_tmp" ] || { rm -f "$_tmp"; return 1; }
    cat "$_tmp" > "$_file" || { rm -f "$_tmp"; return 1; }
    rm -f "$_tmp"
}

# Секция лимитов без единой строки — наш собственный мусор. Чистим только
# те, что перечислены в _TARGET_LIMIT_SECTIONS, чужие не трогаем.
_target_drop_empty_limit_section() {
    local _sect="$1"
    [ -n "$(_target_section_pairs "$_sect")" ] && return 0
    local _tmp; _tmp=$(_mktemp) || return 1
    awk -v sect="[${_sect}]" '
        BEGIN { insect = 0; nb = 0 }
        function flush_blanks(   i) { for (i = 1; i <= nb; i++) print blanks[i]; nb = 0 }
        {
            t = $0; sub(/^[[:space:]]+/, "", t)
            if (t ~ /^\[/) {
                if (t == sect) { insect = 1; nb = 0; next }
                insect = 0; flush_blanks(); print; next
            }
            # Пустые строки внутри выбрасываемой секции придерживаем: если она
            # и правда пуста, они уйдут вместе с заголовком.
            if (insect && t == "") { blanks[++nb] = $0; next }
            if (insect) { insect = 0; flush_blanks() }
            print
        }
        END { flush_blanks() }
    ' "$DETECTED_CONFIG_PATH" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    [ -s "$_tmp" ] || { rm -f "$_tmp"; return 1; }
    cat "$_tmp" > "$DETECTED_CONFIG_PATH" || { rm -f "$_tmp"; return 1; }
    rm -f "$_tmp"
}

# Записать ключ в секцию цели, создав саму секцию, если её ещё нет.
_target_set_in_section() {
    local _key="$1" _value="$2" _section="$3"
    _toml_safe_set "$_key" "$_value" "$_section" "$DETECTED_CONFIG_PATH" && return 0
    printf '\n[%s]\n%s = %s\n' "$_section" "$_key" "$_value" >> "$DETECTED_CONFIG_PATH"
}

# 'on', 'off' или пусто, если такого пользователя у цели нет.
_target_user_state() {
    local _label="$1" _row
    _row=$(_target_section_pairs "access.users" | awk -F'|' -v l="$_label" '$2 == l { print $1; exit }')
    printf '%s' "$_row"
}

# Ссылок у пользователя может быть несколько (dd и ee сразу) — печатаем
# каждую своей строкой, иначе вторая уезжает без отступа и цвета.
_echo_links() {
    local _l
    while IFS= read -r _l; do
        [ -n "$_l" ] && echo -e "  ${CYAN}${_l}${NC}"
    done <<< "$1"
}

_target_user_secret() {
    _target_section_pairs "access.users" | awk -F'|' -v l="$1" '$2 == l { print $3; exit }'
}

_target_user_limit() {
    _target_section_pairs "$2" | awk -F'|' -v l="$1" '$2 == l { print $3; exit }'
}

# Ссылки строятся по конфигу цели, а не по нашим настройкам: домен и режим
# маскировки у чужого движка свои. Может вернуть несколько строк — по одной
# на каждый включённый вид ссылки.
# WEB-ссылка идёт следом за обычными: движок её не отдаёт, а тип прокси
# в клиенте отдельный.
_target_web_link() {
    local _label="$1" _raw
    # В реаниматоре WEB поднимает сам владелец конфига — читаем оттуда.
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        web_target_link "$_label" 2>/dev/null || true
        return 0
    fi
    web_is_enabled 2>/dev/null || return 0
    web_link_for_label "$_label" 2>/dev/null && return 0
    _raw=$(_target_user_secret "$_label" 2>/dev/null) || return 0
    [ -n "$_raw" ] || return 0
    web_link_for_secret "$_raw" 2>/dev/null || true
}

target_user_link() {
    local _label="$1" _raw _domain _mask _full _ip _port

    # Если API цели отвечает — ссылки уже собраны самим движком, включая dd и
    # ee сразу. Свои строить незачем: у него правда о включённых режимах.
    local _json _u _l _from_api=""
    if _json=$(_get_telemt_users_json 2>/dev/null); then
        while IFS='|' read -r _u _l; do
            [ "$_u" = "$_label" ] && [ -n "$_l" ] && _from_api+="${_l}"$'\n'
        done <<< "$(_target_links_ipv4 "$_json")"
    fi
    if [ -n "$_from_api" ]; then
        printf '%s' "$_from_api"
        _target_web_link "$_label"
        return 0
    fi

    _raw=$(_target_user_secret "$_label")
    [ -n "$_raw" ] || return 1
    _domain=$(_toml_get_string_in_section "censorship" "tls_domain" "$DETECTED_CONFIG_PATH")
    _mask=$(_toml_get_string_in_section "censorship" "mask" "$DETECTED_CONFIG_PATH")
    if [ "$_mask" = "false" ] || [ -z "$_domain" ]; then
        _full="dd${_raw}"
    else
        _full="ee${_raw}$(domain_to_hex "$_domain")"
    fi
    # [general.links] public_host/public_port у цели — та же логика, что и
    # для superexpert: заданы явно — используем их, а не наш определённый
    # IP и не порт из детекта.
    _ip=$(_toml_get_string_in_section "general.links" "public_host" "$DETECTED_CONFIG_PATH")
    [ -n "$_ip" ] || _ip=$(get_public_ip)
    _port=$(_toml_get_string_in_section "general.links" "public_port" "$DETECTED_CONFIG_PATH")
    [ -n "$_port" ] || _port="${DETECTED_PORT:-443}"
    printf 'tg://proxy?server=%s&port=%s&secret=%s\n' "$_ip" "$_port" "$_full"
    _target_web_link "$_label"
}

# Успела ли цель подхватить правку сама. telemt следит за файлом конфига и
# применяет пользователей на ходу — сигнала ему для этого не нужно. Сверяем
# состав включённых в конфиге с тем, что отдаёт API: сошлось — перезапускать
# нечего. Не сошлось (другой движок, старая версия, API молчит) — вызывающий
# уходит на прежнюю ветку с перезапуском, то есть хуже не станет.
_target_users_hot_applied() {
    local _want _have _try
    _want=$(_target_config_user_limits 2>/dev/null)
    [ -n "$_want" ] || return 1
    for _try in 1 2 3 4 5 6; do
        _have=$(_target_api_user_limits 2>/dev/null)
        [ -n "$_have" ] && [ "$_want" = "$_have" ] && return 0
        sleep 0.5
    done
    return 1
}

# «Имя|соединения|адреса|квота|срок» по включённым пользователям конфига.
# Пустое поле — ограничения нет: движок понимает это как отсутствие строки.
_target_config_user_limits() {
    declare -A _CONN=() _UIPS=() _QUOTA=() _EXP=()
    local _st _lb _v
    while IFS='|' read -r _st _lb _v; do
        [ -n "$_lb" ] && _CONN["$_lb"]="$_v"
    done < <(_target_section_pairs "access.user_max_tcp_conns" 2>/dev/null)
    while IFS='|' read -r _st _lb _v; do
        [ -n "$_lb" ] && _UIPS["$_lb"]="$_v"
    done < <(_target_section_pairs "access.user_max_unique_ips" 2>/dev/null)
    while IFS='|' read -r _st _lb _v; do
        [ -n "$_lb" ] && _QUOTA["$_lb"]="$_v"
    done < <(_target_section_pairs "access.user_data_quota" 2>/dev/null)
    while IFS='|' read -r _st _lb _v; do
        [ -n "$_lb" ] && _EXP["$_lb"]="$_v"
    done < <(_target_section_pairs "access.user_expirations" 2>/dev/null)
    declare -A _ADT=()
    while IFS='|' read -r _st _lb _v; do
        [ -n "$_lb" ] && _ADT["$_lb"]="$_v"
    done < <(_target_section_pairs "access.user_ad_tags" 2>/dev/null)

    while IFS='|' read -r _st _lb _v; do
        [ "$_st" = "on" ] || continue
        [ -n "$_lb" ] || continue
        printf '%s|%s|%s|%s|%s|%s\n' "$_lb" \
            "${_CONN[$_lb]:-}" "${_UIPS[$_lb]:-}" "${_QUOTA[$_lb]:-}" "${_EXP[$_lb]:-}" \
            "${_ADT[$_lb]:-}"
    done < <(_target_section_pairs "access.users" 2>/dev/null) | LC_ALL=C sort
}

# То же самое, но так, как это видит сам движок — из его API.
_target_api_user_limits() {
    local _json
    _json=$(_get_telemt_users_json 2>/dev/null) || return 1
    printf '%s' "$_json" | tr -d '\n' | awk '
        function first_string(s,   p, q) {
            p = index(s, "\""); if (!p) return ""
            s = substr(s, p + 1); q = index(s, "\"")
            return q ? substr(s, 1, q - 1) : ""
        }
        function raw_after(s, k,   p) {
            p = index(s, "\"" k "\""); if (!p) return ""
            s = substr(s, p + length(k) + 2)
            p = index(s, ":"); if (!p) return ""
            s = substr(s, p + 1); sub(/^[ \t]+/, "", s)
            return s
        }
        function num(s, k,   v) {
            v = raw_after(s, k)
            if (match(v, /^[0-9]+/)) return substr(v, RSTART, RLENGTH)
            return ""
        }
        function str(s, k,   v, q) {
            v = raw_after(s, k)
            if (substr(v, 1, 1) != "\"") return ""
            v = substr(v, 2); q = index(v, "\"")
            return q ? substr(v, 1, q - 1) : ""
        }
        BEGIN { RS = "\"username\"" }
        NR == 1 { next }
        {
            u = first_string($0); if (u == "") next
            e = str($0, "expiration_rfc3339")
            # Движок отдаёт смещение, в конфиге стоит Z — это один момент
            # времени, и расходиться из-за записи они не должны.
            sub(/\+00:00$/, "Z", e)
            printf "%s|%s|%s|%s|%s|%s\n", u, num($0, "max_tcp_conns"), \
                num($0, "max_unique_ips"), num($0, "data_quota_bytes"), e, \
                str($0, "user_ad_tag")
        }
    ' | LC_ALL=C sort
}

# Общий хвост всех правок: у движка, который читает конфиг только при старте,
# без перезапуска ничего не изменится.
_target_users_apply() {
    if ! is_proxy_running; then
        log_info "Цель не запущена — изменения применятся при её запуске"
        return 0
    fi
    if _target_users_hot_applied; then
        log_success "Цель применила изменения на ходу — перезапуск не нужен"
        return 0
    fi
    echo -en "  ${BOLD}Перезапустить цель, чтобы применить? [Y/n]:${NC} "
    local _r; read_line _r
    if [[ "$_r" =~ ^[nN] ]]; then
        log_info "Перезапуск отложен — изменения вступят в силу после restart"
        return 0
    fi
    restart_target
    sleep 1
    if is_proxy_running; then
        log_success "Цель перезапущена"
    else
        log_error "Цель не поднялась после перезапуска — проверьте логи"
        return 1
    fi
}

target_user_add() {
    local _label="$1" _custom="${2:-}"
    _target_users_ready || return 1

    [ -z "$_label" ] && { log_error "Требуется метка"; return 1; }
    [[ "$_label" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Метка: только a-z, 0-9, _, -"; return 1; }
    [ ${#_label} -gt 32 ] && { log_error "Метка: максимум 32 символа"; return 1; }
    [ -n "$(_target_user_state "$_label")" ] && { log_error "Пользователь '${_label}' уже есть у цели"; return 1; }

    local _raw="${_custom:-$(generate_secret)}"
    [[ "$_raw" =~ ^[0-9a-fA-F]{32}$ ]] || { log_error "Секрет: ровно 32 hex-символа"; return 1; }

    backup_target_config "users" "true" || true
    _target_set_in_section "$_label" "\"${_raw}\"" "access.users" || {
        log_error "Не удалось записать пользователя в конфиг цели"
        return 1
    }
    log_success "Пользователь '${_label}' добавлен цели (${DETECTED_CONFIG_PATH})"
    [ -n "${TARGET_CONFIG_BACKUP:-}" ] && log_info "Резервная копия: ${TARGET_CONFIG_BACKUP}"

    local _link; _link=$(target_user_link "$_label")
    if [ -n "$_link" ]; then
        echo ""
        echo -e "  ${BOLD}Ссылки для Telegram:${NC}"
        _echo_links "$_link"
        echo ""
    fi
    _target_users_apply
}

target_user_remove() {
    local _label="$1"
    _target_users_ready || return 1
    [ -n "$(_target_user_state "$_label")" ] || { log_error "Пользователь '${_label}' не найден у цели"; return 1; }

    local _left
    _left=$(_target_section_pairs "access.users" | wc -l)
    [ "$_left" -le 1 ] && { log_error "Нельзя удалить последнего пользователя цели"; return 1; }

    backup_target_config "users" "true" || true
    _toml_safe_unset "$_label" "access.users" "$DETECTED_CONFIG_PATH" || {
        log_error "Не удалось удалить пользователя из конфига цели"
        return 1
    }
    # Лимиты без своего пользователя — мусор в чужом файле.
    local _sect
    for _sect in $_TARGET_LIMIT_SECTIONS; do
        _toml_safe_unset "$_label" "$_sect" "$DETECTED_CONFIG_PATH" 2>/dev/null || true
        _target_drop_empty_limit_section "$_sect" 2>/dev/null || true
    done
    log_success "Пользователь '${_label}' удалён у цели"
    [ -n "${TARGET_CONFIG_BACKUP:-}" ] && log_info "Резервная копия: ${TARGET_CONFIG_BACKUP}"
    _target_users_apply
}

target_user_rotate() {
    local _label="$1"
    _target_users_ready || return 1
    local _state; _state=$(_target_user_state "$_label")
    [ -n "$_state" ] || { log_error "Пользователь '${_label}' не найден у цели"; return 1; }

    local _raw; _raw=$(generate_secret)
    backup_target_config "users" "true" || true
    if [ "$_state" = "off" ]; then
        # У выключенного правим закомментированную строку: включать её здесь
        # нельзя, об этом не просили.
        _toml_toggle_key "$_label" "access.users" "$DETECTED_CONFIG_PATH" "on" || return 1
        _toml_safe_set "$_label" "\"${_raw}\"" "access.users" "$DETECTED_CONFIG_PATH" || return 1
        _toml_toggle_key "$_label" "access.users" "$DETECTED_CONFIG_PATH" "off" || return 1
    else
        _toml_safe_set "$_label" "\"${_raw}\"" "access.users" "$DETECTED_CONFIG_PATH" || {
            log_error "Не удалось обновить ключ в конфиге цели"
            return 1
        }
    fi
    log_success "Ключ пользователя '${_label}' обновлён — старый перестанет работать"
    local _link; _link=$(target_user_link "$_label")
    [ -n "$_link" ] && { echo ""; _echo_links "$_link"; echo ""; }
    _target_users_apply
}

target_user_toggle() {
    local _label="$1" _action="$2"
    _target_users_ready || return 1
    local _state; _state=$(_target_user_state "$_label")
    [ -n "$_state" ] || { log_error "Пользователь '${_label}' не найден у цели"; return 1; }

    local _want; [ "$_action" = "enable" ] && _want="on" || _want="off"
    if [ "$_state" = "$_want" ]; then
        log_info "Пользователь '${_label}' уже $([ "$_want" = "on" ] && echo "включён" || echo "выключен")"
        return 0
    fi
    if [ "$_want" = "off" ]; then
        local _on
        _on=$(_target_section_pairs "access.users" | awk -F'|' '$1 == "on"' | wc -l)
        [ "$_on" -le 1 ] && { log_error "Нельзя выключить последнего активного пользователя цели"; return 1; }
    fi

    backup_target_config "users" "true" || true
    _toml_toggle_key "$_label" "access.users" "$DETECTED_CONFIG_PATH" "$_want" || {
        log_error "Не удалось изменить состояние пользователя в конфиге цели"
        return 1
    }
    log_success "Пользователь '${_label}' $([ "$_want" = "on" ] && echo "включён" || echo "выключен")"
    _target_users_apply
}

target_user_rename() {
    local _from="$1" _to="$2"
    _target_users_ready || return 1
    [ -n "$(_target_user_state "$_from")" ] || { log_error "Пользователь '${_from}' не найден у цели"; return 1; }
    [[ "$_to" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Метка: только a-z, 0-9, _, -"; return 1; }
    [ -n "$(_target_user_state "$_to")" ] && { log_error "Пользователь '${_to}' уже есть у цели"; return 1; }

    local _state _secret
    _state=$(_target_user_state "$_from")
    _secret=$(_target_user_secret "$_from")

    backup_target_config "users" "true" || true
    local _sect _val
    for _sect in $_TARGET_LIMIT_SECTIONS; do
        _val=$(_target_user_limit "$_from" "$_sect")
        [ -n "$_val" ] || continue
        _toml_safe_unset "$_from" "$_sect" "$DETECTED_CONFIG_PATH" || true
        case "$_sect" in
            access.user_expirations|access.user_ad_tags) _target_set_in_section "$_to" "\"${_val}\"" "$_sect" ;;
            *)                       _target_set_in_section "$_to" "$_val" "$_sect" ;;
        esac
    done
    _toml_safe_unset "$_from" "access.users" "$DETECTED_CONFIG_PATH" || return 1
    _target_set_in_section "$_to" "\"${_secret}\"" "access.users" || return 1
    [ "$_state" = "off" ] && _toml_toggle_key "$_to" "access.users" "$DETECTED_CONFIG_PATH" "off"
    log_success "Пользователь переименован: ${_from} → ${_to}"
    _target_users_apply
}

target_user_setlimits() {
    local _label="$1" _conns="${2:-0}" _ips="${3:-0}" _quota="${4:-0}" _expires="${5:-}"
    _target_users_ready || return 1
    [ -n "$(_target_user_state "$_label")" ] || { log_error "Пользователь '${_label}' не найден у цели"; return 1; }

    # Проверяем до записи: негодный срок должен упереться здесь, а не в
    # отказавшемся стартовать движке с уже испорченным конфигом.
    _expires=$(_normalize_expiry "$_expires") || return 1

    backup_target_config "users" "true" || true
    # Ноль означает «без ограничения», а движок понимает это как отсутствие
    # строки: оставленный ноль он прочитал бы как запрет всего.
    _target_users_set_limit "$_label" "access.user_max_tcp_conns" "$_conns" num
    _target_users_set_limit "$_label" "access.user_max_unique_ips" "$_ips" num
    _target_users_set_limit "$_label" "access.user_data_quota" "$_quota" num
    _target_users_set_limit "$_label" "access.user_expirations" "${_expires:-0}" str
    log_success "Лимиты пользователя '${_label}' обновлены"
    _target_users_apply
}

_target_users_set_limit() {
    local _label="$1" _sect="$2" _val="$3" _kind="$4"
    if [ -z "$_val" ] || [ "$_val" = "0" ]; then
        _toml_safe_unset "$_label" "$_sect" "$DETECTED_CONFIG_PATH" 2>/dev/null || true
        _target_drop_empty_limit_section "$_sect" 2>/dev/null || true
        return 0
    fi
    if [ "$_kind" = "str" ]; then
        _target_set_in_section "$_label" "\"${_val}\"" "$_sect"
    else
        _target_set_in_section "$_label" "$_val" "$_sect"
    fi
}

# Рекламная метка пользователя цели — та же секция, что и у менеджера.
target_user_adtag() {
    local _label="$1" _tag="${2:-}"
    _target_users_ready || return 1
    [ -n "$(_target_user_state "$_label")" ] || {
        log_error "Пользователь '${_label}' не найден у цели"; return 1; }

    if [ -z "$_tag" ]; then
        _target_user_limit "$_label" "access.user_ad_tags"
        return 0
    fi
    backup_target_config "users" "true" || true
    case "$_tag" in
        remove|none|"-"|"0")
            _target_users_set_limit "$_label" "access.user_ad_tags" "" str
            log_success "Метка снята с '${_label}'" ;;
        *)
            if ! [[ "$_tag" =~ ^[0-9a-fA-F]{32}$ ]]; then
                log_error "Метка: ровно 32 hex-символа (её выдаёт @MTProxybot)"
                return 1
            fi
            _target_users_set_limit "$_label" "access.user_ad_tags" "$_tag" str
            log_success "Метка задана для '${_label}'" ;;
    esac
    _target_users_apply
}

target_users_list_json() {
    _target_users_ready || { printf '[]\n'; return 1; }
    local _json
    if _json=$(_get_telemt_users_json "$DETECTED_CONFIG_PATH" 2>/dev/null); then
        _target_user_ip_lists "$_json" | _flush_user_ip_history "$_TARGET_USER_IPS_DB"
    fi

    # Всё нужное списку собирается один раз: раньше на каждого пользователя
    # шёл поход в API цели с перезаписью базы трафика — 12 секунд на 24 секрета.
    flush_target_traffic_to_disk 2>/dev/null || true
    declare -A _TDB_IN=() _TDB_OUT=() _TDB_TOTAL=()
    local _TDB_SRC=""
    _load_target_db

    declare -A _LIM_CONNS=() _LIM_IPS=() _LIM_QUOTA=() _LIM_EXPIRES=() _LIM_ADTAG=()
    local _st _nm _vl
    while IFS='|' read -r _st _nm _vl; do
        [ -n "$_nm" ] && _LIM_CONNS["$_nm"]="$_vl"
    done < <(_target_section_pairs "access.user_max_tcp_conns")
    while IFS='|' read -r _st _nm _vl; do
        [ -n "$_nm" ] && _LIM_IPS["$_nm"]="$_vl"
    done < <(_target_section_pairs "access.user_max_unique_ips")
    while IFS='|' read -r _st _nm _vl; do
        [ -n "$_nm" ] && _LIM_QUOTA["$_nm"]="$_vl"
    done < <(_target_section_pairs "access.user_data_quota")
    while IFS='|' read -r _st _nm _vl; do
        [ -n "$_nm" ] && _LIM_EXPIRES["$_nm"]="$_vl"
    done < <(_target_section_pairs "access.user_expirations")
    while IFS='|' read -r _st _nm _vl; do
        [ -n "$_nm" ] && _LIM_ADTAG["$_nm"]="$_vl"
    done < <(_target_section_pairs "access.user_ad_tags")

    declare -A _IP_HIST=()
    if [ -f "$_TARGET_USER_IPS_DB" ]; then
        local _ht _hu _hip _hfs _hls _entry
        while IFS='|' read -r _ht _hu _hip _hfs _hls; do
            [ "$_ht" = "USER" ] || continue
            [ -n "$_hu" ] && [ -n "$_hip" ] || continue
            json_escape_fast "$_hip"
            _entry="{\"ip\":\"${_JSON_ESCAPE_OUT}\",\"first_seen\":${_hfs:-0},\"last_seen\":${_hls:-0}}"
            if [ -z "${_IP_HIST[$_hu]+x}" ]; then
                _IP_HIST["$_hu"]="$_entry"
            else
                _IP_HIST["$_hu"]="${_IP_HIST[$_hu]},$_entry"
            fi
        done < "$_TARGET_USER_IPS_DB"
    fi

    local _first=1 _state _label _secret _label_esc _secret_esc _expires_esc
    local _enabled_str _conns _ips _quota _expires
    printf '['
    while IFS='|' read -r _state _label _secret; do
        [ -n "$_label" ] || continue
        [ $_first -eq 1 ] || printf ','
        _first=0

        # Ноль — «без ограничения»; мусор в конфиге цели трактуем так же.
        _conns="${_LIM_CONNS[$_label]:-0}";  [[ "$_conns" =~ ^[0-9]+$ ]]  || _conns=0
        _ips="${_LIM_IPS[$_label]:-0}";      [[ "$_ips" =~ ^[0-9]+$ ]]    || _ips=0
        _quota="${_LIM_QUOTA[$_label]:-0}";  [[ "$_quota" =~ ^[0-9]+$ ]]  || _quota=0
        _expires="${_LIM_EXPIRES[$_label]:-}"
        local _adtag="${_LIM_ADTAG[$_label]:-}"
        [[ "$_adtag" =~ ^[0-9a-fA-F]{32}$ ]] || _adtag=""

        json_escape_fast "$_label";    _label_esc="$_JSON_ESCAPE_OUT"
        json_escape_fast "$_secret";   _secret_esc="$_JSON_ESCAPE_OUT"
        json_escape_fast "$_expires";  _expires_esc="$_JSON_ESCAPE_OUT"
        if [ "$_state" = "on" ]; then _enabled_str=true; else _enabled_str=false; fi

        printf '{"label":"%s","secret":"%s","created":0,"enabled":%s,"max_conns":%s,"max_ips":%s,"quota_bytes":%s,"expires":"%s","notes":"","ad_tag":"%s","total_in":%s,"total_out":%s,"total_bytes":%s,"ip_history":[%s]}' \
            "$_label_esc" "$_secret_esc" "$_enabled_str" \
            "$_conns" "$_ips" "$_quota" "$_expires_esc" "$_adtag" \
            "${_TDB_IN[$_label]:-0}" "${_TDB_OUT[$_label]:-0}" "${_TDB_TOTAL[$_label]:-0}" \
            "${_IP_HIST[$_label]:-}"
    done < <(_target_section_pairs "access.users")
    printf ']\n'
}

target_users_list() {
    _target_users_ready || return 1
    local _rows; _rows=$(_target_section_pairs "access.users")
    if [ -z "$_rows" ]; then
        log_info "У цели нет пользователей в [access.users]"
        echo -e "  ${DIM}Добавить: mtproxyl secret add <метка>${NC}"
        return 0
    fi

    echo ""
    draw_header "ПОЛЬЗОВАТЕЛИ ЦЕЛИ"
    echo ""
    echo -e "  ${DIM}Источник: ${DETECTED_CONFIG_PATH} — секция [access.users]${NC}"
    echo ""
    echo -e "  ${BOLD}$(_pad 'МЕТКА' 20) $(_pad 'СТАТУС' 10) ЛИМИТЫ${NC}"
    echo -e "  ${DIM}$(_repeat '─' 60)${NC}"

    local _state _label _secret _lim _c _i
    while IFS='|' read -r _state _label _secret; do
        [ -n "$_label" ] || continue
        _lim=""
        _c=$(_target_user_limit "$_label" "access.user_max_tcp_conns")
        _i=$(_target_user_limit "$_label" "access.user_max_unique_ips")
        [ -n "$_c" ] && _lim="соед: ${_c}"
        [ -n "$_i" ] && _lim="${_lim}${_lim:+, }IP: ${_i}"
        [ -n "$_lim" ] || _lim="—"
        if [ "$_state" = "on" ]; then
            echo -e "  $(_pad "$_label" 20) ${GREEN}$(_pad 'активен' 10)${NC} ${DIM}${_lim}${NC}"
        else
            echo -e "  $(_pad "$_label" 20) ${RED}$(_pad 'выключен' 10)${NC} ${DIM}${_lim}${NC}"
        fi
    done <<< "$_rows"
    echo ""
}

# Те же подкоманды, что у менеджера, но поверх конфига цели. Набор намеренно
# совпадает: панель дёргает 'mtproxyl secret ...' одинаково в обоих режимах, и
# расхождение в именах означало бы вторую реализацию на её стороне.
handle_target_user_command() {
    local subcmd="${1:-list}"; shift 2>/dev/null || true
    case "$subcmd" in
        add)      check_root; target_user_add "$1" "${2:-}" ;;
        remove)   check_root; target_user_remove "$1" ;;
        list)
            if [ "${1:-}" = "--json" ]; then
                target_users_list_json
            else
                target_users_list
            fi ;;
        rotate)   check_root; target_user_rotate "$1" ;;
        enable)   check_root; target_user_toggle "$1" enable ;;
        disable)  check_root; target_user_toggle "$1" disable ;;
        rename)   check_root; target_user_rename "$1" "$2" ;;
        setlimits)
            check_root
            local _l="$1"; shift 2>/dev/null || true
            target_user_setlimits "$_l" "${1:-0}" "${2:-0}" "${3:-0}" "${4:-}" ;;
        limits)   target_user_show_limits "${1:-}" ;;
        adtag)    check_root; target_user_adtag "${1:-}" "${2:-}" ;;
        link)
            local _links; _links=$(target_user_link "${1:-}") || {
                log_error "Пользователь '${1:-}' не найден у цели"; return 1; }
            _echo_links "$_links"
            echo "" ;;
        qr)
            # QR из терминала убран: остаются те же ссылки текстом.
            local _links; _links=$(target_user_link "${1:-}") || {
                log_error "Пользователь '${1:-}' не найден у цели"; return 1; }
            _echo_links "$_links"
            echo "" ;;
        clone)
            log_error "Клонирование недоступно в реаниматоре"
            log_info "Лимиты цели заданы её администратором — добавьте пользователя и задайте лимиты явно"
            return 1 ;;
        *)
            echo -e "  ${BOLD}Пользователи цели (реаниматор):${NC}"
            echo -e "  ${DIM}Живут в [access.users] конфига цели — ${DETECTED_CONFIG_PATH:-не найден}${NC}"
            echo ""
            echo -e "    ${GREEN}secret add${NC} <метка> [ключ]  Добавить"
            echo -e "    ${GREEN}secret remove${NC} <метка>      Удалить"
            echo -e "    ${GREEN}secret list${NC}                Список"
            echo -e "    ${GREEN}secret rotate${NC} <метка>      Обновить ключ"
            echo -e "    ${GREEN}secret enable${NC} <метка>      Включить"
            echo -e "    ${GREEN}secret disable${NC} <метка>     Выключить"
            echo -e "    ${GREEN}secret rename${NC} <из> <в>     Переименовать"
            echo -e "    ${GREEN}secret limits${NC} [метка]      Лимиты"
            echo -e "    ${GREEN}secret setlimits${NC} <метка> <соед> <ip> <квота> [срок]"
            echo -e "    ${GREEN}secret adtag${NC} <метка> <32hex|remove>"
            echo -e "                              Рекламная метка пользователя"
            echo -e "    ${GREEN}secret link${NC} <метка>        Ссылка"
            echo -e "    ${GREEN}secret qr${NC} <метка>          Ссылки (устар., = link)"
            ;;
    esac
}

target_user_show_limits() {
    _target_users_ready || return 1
    local _label="$1"
    if [ -z "$_label" ]; then
        target_users_list
        return 0
    fi
    [ -n "$(_target_user_state "$_label")" ] || { log_error "Пользователь '${_label}' не найден у цели"; return 1; }
    echo ""
    echo -e "  ${BOLD}Лимиты '${_label}':${NC}"
    echo -e "    Соединений : $(_target_user_limit "$_label" "access.user_max_tcp_conns" | grep . || echo '—')"
    echo -e "    Уникальных IP: $(_target_user_limit "$_label" "access.user_max_unique_ips" | grep . || echo '—')"
    echo -e "    Квота, байт: $(_target_user_limit "$_label" "access.user_data_quota" | grep . || echo '—')"
    echo -e "    Истекает   : $(_target_user_limit "$_label" "access.user_expirations" | grep . || echo '—')"
    echo ""
}

# CLI обработчик
handle_secret_command() {
    local subcmd="${1:-list}"; shift 2>/dev/null || true
    # В реаниматоре у пользователей своё хранилище — конфиг цели, и общий гвард
    # на режим менеджера к ним не относится.
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        handle_target_user_command "$subcmd" "$@"
        return $?
    fi
    _require_manager_mode || return 1
    # Гвард выбирается по подкоманде, а не по её первому аргументу: иначе
    # 'secret list --json' (запрос панели) попадал в ветку пишущих команд и в
    # режиме супер эксперта отказывал, хотя ничего не пишет.
    case "$subcmd" in
        list|link|qr|"") ;;
        *) _require_no_superexpert || return 1 ;;
    esac
    case "$subcmd" in
        add)      check_root; secret_add "$@" ;;
        remove)   check_root; secret_remove "$1" ;;
        list)
            if [ "${1:-}" = "--json" ]; then
                secret_list_json
            else
                secret_list
            fi ;;
        rotate)   check_root; secret_rotate "$1" ;;
        enable)   check_root; secret_toggle "$1" enable ;;
        disable)  check_root; secret_toggle "$1" disable ;;
        limits)   secret_show_limits "$1" ;;
        adtag)    check_root; secret_set_adtag "$1" "${2:-}" ;;
        setlimits)
            check_root
            local l="$1"; shift 2>/dev/null || true
            secret_set_limits "$l" "${1:-0}" "${2:-0}" "${3:-0}" "${4:-}" ;;
        link)     get_proxy_links "${1:-}"; echo "" ;;
        clone)    check_root; secret_clone "$1" "$2" ;;
        rename)   check_root; secret_rename "$1" "$2" ;;
        qr)
            # QR из терминала убран: остаются те же ссылки текстом.
            local links; links=$(get_proxy_links "${1:-}") || return 1
            _echo_links "$links"
            echo "" ;;
        *)
            echo -e "  ${BOLD}Управление секретами:${NC}"
            echo -e "    ${GREEN}secret add${NC} <метка>        Добавить"
            echo -e "    ${GREEN}secret remove${NC} <метка>     Удалить"
            echo -e "    ${GREEN}secret list${NC}               Список"
            echo -e "    ${GREEN}secret rotate${NC} <метка>     Обновить ключ"
            echo -e "    ${GREEN}secret enable${NC} <метка>     Включить"
            echo -e "    ${GREEN}secret disable${NC} <метка>    Выключить"
            echo -e "    ${GREEN}secret limits${NC} [метка]     Лимиты"
            echo -e "    ${GREEN}secret setlimits${NC} <метка> <соед> <ip> <квота> [срок]"
            echo -e "    ${GREEN}secret link${NC} [метка]       Ссылка"
            echo -e "    ${GREEN}secret qr${NC} [метка]         Ссылки (устар., = link)"
            echo -e "    ${GREEN}secret clone${NC} <из> <в>     Клонировать"
            echo -e "    ${GREEN}secret rename${NC} <из> <в>    Переименовать"
            ;;
    esac
}
