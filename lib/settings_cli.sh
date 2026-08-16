#!/bin/bash
# MTProxyL — машинный доступ к собственным настройкам (для веб-панели).
# В менеджере config.toml примонтирован только для чтения, поэтому настройки
# живут в settings.conf и меняются здесь, а не через API движка.
# Формат каталога: "КЛЮЧ|валидатор|описание", валидаторы из _expert_validate.

_SETTINGS_SETTABLE=(
    "PROXY_PORT|range:1:65535|Порт прокси"
    "PROXY_DOMAIN|custom:_validate_settings_domain|Домен FakeTLS (SNI)"
    "CUSTOM_IP|custom:_validate_settings_ip|IP или домен для ссылок (пусто — автоопределение)"
    "AD_TAG|custom:_validate_settings_adtag|Рекламная метка от @MTProxybot (пусто — выключена)"
    "MASKING_ENABLED|bool|Маскировка: отдавать настоящий сайт при неудачном рукопожатии"
    "MASKING_HOST|custom:_validate_settings_mask_host|Хост маскировки (пусто — совпадает с доменом)"
    "MASKING_PORT|range:1:65535|Порт хоста маскировки"
    "UNKNOWN_SNI_ACTION|enum:mask,drop,accept,reject_handshake|Что делать с чужим SNI"
    "PROXY_CONCURRENCY|range:1:1000000|Максимум одновременных соединений"
    "FAKE_CERT_LEN|range:512:65536|Длина поддельного сертификата"
    "PROXY_PROTOCOL|bool|Принимать PROXY protocol от вышестоящего балансировщика"
    "PROXY_METRICS_PORT|range:1:65535|Порт метрик Prometheus (только localhost)"
    "PROXY_API_PORT|range:1:65535|Порт REST API движка (через него работает панель)"
    "BACKUP_RETENTION_DAYS|range:0:3650|Сколько дней хранить бэкапы (0 — не удалять)"
    "IP_HISTORY_LIMIT|range:1:100000|Сколько IP хранить в истории на пользователя"
    "IP_HISTORY_INTERVAL|range:0:1440|Как часто снимать адреса в историю, минут (0 — выключить)"
    "DC_THRESHOLD|range:0:100|Порог покрытия дата-центров Telegram, % (0 — без предупреждений)"
    "AVAILABILITY_ENABLED|bool|Проверять доступность из России по расписанию"
    "AVAILABILITY_INTERVAL|range:1:1440|Как часто проверять доступность, минут"
    "AVAILABILITY_PROBES|range:1:50|Сколько российских зондов опрашивать (кредит за зонд)"
    "AVAILABILITY_THRESHOLD|range:0:100|Порог доступности для уведомления, %"
    "AVAILABILITY_HOST|custom:_validate_settings_avail_host|Адрес для проверки (пусто — автоопределение)"
    "AVAILABILITY_PORT|custom:_validate_settings_avail_port|Порт для проверки (пусто — порт прокси)"
    "AVAILABILITY_SNI|custom:_validate_settings_mask_host|SNI для проверки (пусто — домен FakeTLS)"
)

# ── Валидаторы, которых нет в экспертном каталоге ─────────────
_validate_settings_domain() {
    [ -n "$1" ] || { echo "Домен не может быть пустым"; return 1; }
    validate_domain "$1" && return 0
    echo "Домен вида example.com"; return 1
}

# Пусто — законное значение: означает автоопределение.
_validate_settings_ip() {
    [ -z "$1" ] && return 0
    validate_ip_literal "$1" 2>/dev/null && return 0
    validate_domain "$1" 2>/dev/null && return 0
    echo "IPv4-адрес или домен, либо пусто для автоопределения"; return 1
}

_validate_settings_adtag() {
    [ -z "$1" ] && return 0
    [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]] && return 0
    echo "32 шестнадцатеричных символа либо пусто"; return 1
}

_validate_settings_mask_host() {
    [ -z "$1" ] && return 0
    validate_domain "$1" 2>/dev/null && return 0
    validate_ip_literal "$1" 2>/dev/null && return 0
    echo "Домен или IP, либо пусто"; return 1
}

# У сервера может не быть домена вовсе, а адрес — быть только шестым.
_validate_settings_avail_host() {
    [ -z "$1" ] && return 0
    validate_ip_literal "$1" 2>/dev/null && return 0
    [[ "$1" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$1" == *:* ]] && return 0
    validate_domain "$1" 2>/dev/null && return 0
    echo "IPv4, IPv6 или домен, либо пусто для автоопределения"; return 1
}

# Пусто — законное значение: означает «тот же порт, что у прокси».
_validate_settings_avail_port() {
    [ -z "$1" ] && return 0
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] && return 0
    echo "Порт 1-65535 либо пусто"; return 1
}

_settings_find() {
    local _key="$1" _entry
    for _entry in "${_SETTINGS_SETTABLE[@]}"; do
        [ "${_entry%%|*}" = "$_key" ] && { echo "$_entry"; return 0; }
    done
    return 1
}

# Список настроек с текущими значениями — панель строит по нему форму.
settings_settable_json() {
    local _entry _key _validator _desc _rest _first=1
    printf '['
    for _entry in "${_SETTINGS_SETTABLE[@]}"; do
        _key="${_entry%%|*}"
        _rest="${_entry#*|}"
        _validator="${_rest%%|*}"
        _desc="${_rest#*|}"
        [ $_first -eq 1 ] || printf ','
        _first=0
        printf '{"key":"%s","validator":"%s","description":"%s","value":"%s"}' \
            "$(json_escape "$_key")" "$(json_escape "$_validator")" \
            "$(json_escape "$_desc")" "$(json_escape "${!_key:-}")"
    done
    printf ']\n'
}

# Изменить одну настройку. Ключи с побочными действиями (гео-блокировка
# прибита к порту и т.п.) отдаём готовым командам, а не присваиваем напрямую.
settings_set_param() {
    local _key="$1" _val="$2"
    [ -n "$_key" ] || { log_error "Использование: settings set <ключ> <значение>"; return 1; }

    local _entry
    _entry=$(_settings_find "$_key") || {
        log_error "Параметр '${_key}' недоступен для изменения"
        log_info "Список: mtproxyl settings list"
        return 1
    }

    # Раздельные объявления намеренно: в одном `local a=... b="${a}"` bash
    # сперва обнулит оба, и пустой валидатор пропустит что угодно.
    local _rest _validator
    _rest="${_entry#*|}"
    _validator="${_rest%%|*}"
    local _err
    _err=$(_expert_validate "$_validator" "$_val" 2>&1) || {
        log_error "Недопустимое значение для ${_key}: ${_err}"
        return 1
    }

    case "$_key" in
        PROXY_PORT)
            # Переносит гео-блокировку на новый порт и перезапускает контейнер.
            handle_port_command "$_val"
            return $?
            ;;
        PROXY_DOMAIN)
            handle_domain_command "$_val"
            return $?
            ;;
        CUSTOM_IP)
            handle_ip_command "${_val:-auto}"
            return $?
            ;;
        MASKING_HOST|MASKING_PORT)
            # Пересчитывает длину поддельного сертификата под новый хост.
            local _host="${MASKING_HOST:-${PROXY_DOMAIN}}" _port="${MASKING_PORT:-443}"
            [ "$_key" = "MASKING_HOST" ] && _host="${_val:-${PROXY_DOMAIN}}"
            [ "$_key" = "MASKING_PORT" ] && _port="$_val"
            handle_mask_backend "${_host}:${_port}"
            return $?
            ;;
    esac

    check_root

    # Настройки самого MTProxyL в конфиг движка не попадают, поэтому доступны
    # и в реаниматоре, и при супер эксперте: чужой конфиг они не трогают.
    local _own_setting="false"
    case "$_key" in
        BACKUP_RETENTION_DAYS|IP_HISTORY_LIMIT|IP_HISTORY_INTERVAL|AVAILABILITY_*|DC_THRESHOLD)
            _own_setting="true" ;;
    esac
    if [ "$_own_setting" != "true" ]; then
        _require_manager_mode || return 1
        _require_no_superexpert || return 1
    fi

    printf -v "$_key" '%s' "$_val"
    save_settings
    log_success "${_key} = ${_val:-<пусто>}"

    # Порты метрик и API попадают в конфиг движка, но на лету не подхватываются:
    # движок открывает сокеты при старте.
    case "$_key" in
        PROXY_METRICS_PORT|PROXY_API_PORT)
            generate_telemt_config >/dev/null 2>&1 || true
            log_info "Порт применится после перезапуска: mtproxyl restart"
            [ "$_key" = "PROXY_API_PORT" ] && \
                log_warn "Поправьте url в конфиге панели: /etc/mtproxyl-panel/config.toml"
            ;;
        BACKUP_RETENTION_DAYS|IP_HISTORY_LIMIT|DC_THRESHOLD|\
        AVAILABILITY_THRESHOLD|AVAILABILITY_HOST|AVAILABILITY_PORT|AVAILABILITY_SNI|AVAILABILITY_PROBES)
            # Настройки самого MTProxyL — в конфиг движка не попадают.
            ;;
        AVAILABILITY_ENABLED|AVAILABILITY_INTERVAL)
            # Интервал зашит в юнит таймера, его надо переписать.
            install_availability_timer
            [ "$_key" = "AVAILABILITY_ENABLED" ] && [ "$_val" = "false" ] && \
                log_info "Проверка по расписанию выключена: остаётся ручная, mtproxyl availability check"
            ;;
        IP_HISTORY_INTERVAL)
            # Интервал зашит в юнит таймера, его надо переписать.
            install_ip_history_timer
            [ "$_val" = "0" ] && log_info "Снимки выключены: история пополняется, только пока открыта панель"
            ;;
        *)
            reload_proxy_config >/dev/null 2>&1 || true
            ;;
    esac
    return 0
}

handle_settings_command() {
    local _sub="${1:-list}"; shift 2>/dev/null || true
    case "$_sub" in
        list)
            if [ "${1:-}" = "--json" ]; then
                settings_settable_json
            else
                local _entry _key _rest _desc
                echo ""
                echo -e "  ${BOLD}Настройки MTProxyL${NC}"
                echo ""
                for _entry in "${_SETTINGS_SETTABLE[@]}"; do
                    _key="${_entry%%|*}"
                    _rest="${_entry#*|}"
                    _desc="${_rest#*|}"
                    printf "    %-26s %s\n" "$_key" "${!_key:-<пусто>}"
                    printf "    %-26s ${DIM}%s${NC}\n" "" "$_desc"
                done
                echo ""
            fi ;;
        set)  settings_set_param "${1:-}" "${2:-}" ;;
        *)
            echo -e "  ${BOLD}Настройки:${NC}"
            echo -e "    ${GREEN}settings list${NC} [--json]        Показать настройки"
            echo -e "    ${GREEN}settings set${NC} <ключ> <значение> Изменить"
            ;;
    esac
}
