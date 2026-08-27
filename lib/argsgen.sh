#!/bin/bash
# MTProxyL — сборка команды установки аргументами из текущей конфигурации.
# Переезд по SSH умеет не всё: на новый сервер бывает не достучаться отсюда,
# а параметры повторить в точности всё равно надо. Здесь та же выжимка, но
# в виде строки, которую можно скопировать и выполнить на другой машине.

# Что включено в команду. Заполняется _argsgen_defaults из текущих настроек.
declare -A _AG_ON=()
declare -A _AG_VAL=()

# Пункты в порядке показа: ключ|подпись|можно ли править значение.
_AG_ITEMS=(
    "engine|Движок|yes"
    "port|Порт прокси|yes"
    "ports|Порты метрик и API|no"
    "host|Домен в ссылках|yes"
    "sni|FakeTLS SNI|yes"
    "secrets|Секреты|no"
    "adtag|Рекламная метка|no"
    "mask|Маскировка и SNI-политика|no"
    "fixes|Zapret2 или SYN-лимитер|no"
    "meko|Оптимизация By-MEKO|no"
    "selfmask|Selfmask|yes"
    "web|WEB Proxy|yes"
    "geoip|База GeoIP|no"
    "block|Список блокировок|no"
    "force|Ставить поверх существующей|no"
)

_argsgen_defaults() {
    load_nft_settings 2>/dev/null || true
    load_selfmask_settings 2>/dev/null || true

    _AG_ON=(); _AG_VAL=()

    _AG_ON[engine]="yes"
    if [ "$(engine_backend)" = "binary" ]; then
        local _ev; _ev=$(binengine_version)
        [ -n "$_ev" ] && [ "$_ev" != "unknown" ] && _AG_VAL[engine]="binary:${_ev}" || _AG_VAL[engine]="binary"
    else
        _AG_VAL[engine]="docker"
    fi
    _AG_ON[port]="yes";   _AG_VAL[port]="${PROXY_PORT:-443}"
    _AG_ON[ports]="no";   _AG_VAL[ports]="${PROXY_METRICS_PORT:-9090}/${PROXY_API_PORT:-9091}"
    _AG_ON[sni]="yes";    _AG_VAL[sni]="${PROXY_DOMAIN:-autoscout24.ru}"

    # Литеральный IP в ссылках привязан к этой машине: на новой он вёл бы в
    # никуда, поэтому предлагаем его только как домен.
    if [ -n "${CUSTOM_IP:-}" ] && ! validate_ip_literal "${CUSTOM_IP}"; then
        _AG_ON[host]="yes"; _AG_VAL[host]="${CUSTOM_IP}"
    else
        _AG_ON[host]="no";  _AG_VAL[host]=""
    fi

    _AG_ON[secrets]="yes"; _AG_VAL[secrets]="${#SECRETS_LABELS[@]}"
    if [ -n "${AD_TAG:-}" ]; then _AG_ON[adtag]="yes"; else _AG_ON[adtag]="no"; fi
    _AG_VAL[adtag]="${AD_TAG:-нет}"

    _AG_ON[mask]="yes"
    _AG_VAL[mask]="$([ "${MASKING_ENABLED:-true}" = "false" ] && echo "выкл" || echo "вкл"), ${UNKNOWN_SNI_ACTION:-mask}"

    _AG_ON[fixes]="yes"
    if zapret2_in_effect; then
        _AG_VAL[fixes]="zapret2"
    elif [ "${NFT_ENABLED:-false}" = "true" ]; then
        _AG_VAL[fixes]="SYN-лимитер ${NFT_MODE:-classic}"
    else
        _AG_VAL[fixes]="ничего"
    fi

    _AG_ON[meko]="yes"
    _AG_VAL[meko]="$([ "${MEKO_OPT_APPLIED:-false}" = "true" ] && echo "вкл" || echo "выкл")"

    if [ "${SELFMASK_ENABLED:-false}" = "true" ] && [ -n "${SELFMASK_DOMAIN:-}" ]; then
        _AG_ON[selfmask]="yes"
        _AG_VAL[selfmask]="${SELFMASK_DOMAIN} (${SELFMASK_CERT_MODE:-letsencrypt})"
    else
        _AG_ON[selfmask]="no"; _AG_VAL[selfmask]="выключен"
    fi

    if web_is_enabled 2>/dev/null; then
        _AG_ON[web]="yes"
        _AG_VAL[web]="$(web_domain 2>/dev/null) (${WEB_LAYOUT:-shared}, ${WEB_CARRIER:-websocket-lanes})"
    else
        _AG_ON[web]="no"; _AG_VAL[web]="выключен"
    fi

    _AG_ON[geoip]="$(geoip_installed 2>/dev/null && echo yes || echo no)"
    _AG_VAL[geoip]="$(geoip_installed 2>/dev/null && echo "установлена" || echo "нет")"

    local _bn; _bn=$(ipblock_count 2>/dev/null || echo 0)
    if [ "${IPBLOCK_ENABLED:-false}" = "true" ] && [ "$_bn" -gt 0 ]; then
        _AG_ON[block]="yes"; _AG_VAL[block]="${_bn} записей, ${IPBLOCK_ACTION}"
    else
        _AG_ON[block]="no"; _AG_VAL[block]="$([ "$_bn" -gt 0 ] && echo "${_bn} записей, выключен" || echo "пусто")"
    fi

    _AG_ON[force]="no"; _AG_VAL[force]="--force"
}

# Аргументы одной строкой на stdout.
_argsgen_build() {
    local -a _a=(--mode manager)
    [ "${_AG_ON[force]}" = "yes" ] && _a+=(--force)
    if [ "${_AG_ON[engine]}" = "yes" ]; then
        case "${_AG_VAL[engine]}" in
            binary:*) _a+=(--engine binary --engine-version "${_AG_VAL[engine]#binary:}") ;;
            binary)   _a+=(--engine binary) ;;
            *)        _a+=(--engine docker) ;;
        esac
    fi
    [ "${_AG_ON[port]}" = "yes" ] && _a+=(--port "${_AG_VAL[port]}")
    if [ "${_AG_ON[ports]}" = "yes" ]; then
        _a+=(--metrics-port "${PROXY_METRICS_PORT:-9090}" --api-port "${PROXY_API_PORT:-9091}")
    fi
    [ "${_AG_ON[host]}" = "yes" ] && [ -n "${_AG_VAL[host]}" ] && _a+=(--host "${_AG_VAL[host]}")
    [ "${_AG_ON[sni]}" = "yes" ] && _a+=(--sni "${_AG_VAL[sni]}")

    if [ "${_AG_ON[secrets]}" = "yes" ]; then
        local _i
        for _i in "${!SECRETS_LABELS[@]}"; do
            _a+=(--secret "${SECRETS_LABELS[$_i]}:${SECRETS_KEYS[$_i]}")
        done
    fi
    [ "${_AG_ON[adtag]}" = "yes" ] && [ -n "${AD_TAG:-}" ] && _a+=(--ad-tag "$AD_TAG")

    if [ "${_AG_ON[mask]}" = "yes" ]; then
        [ "${MASKING_ENABLED:-true}" = "false" ] && _a+=(--mask off) || _a+=(--mask on)
        _a+=(--sni-policy "${UNKNOWN_SNI_ACTION:-mask}")
    fi

    if [ "${_AG_ON[fixes]}" = "yes" ]; then
        if zapret2_in_effect; then
            _a+=(--zapret2 yes)
        else
            _a+=(--zapret2 no)
            if [ "${NFT_ENABLED:-false}" != "true" ]; then
                _a+=(--syn-limiter off)
            else
                case "${NFT_MODE:-}" in
                    smart)   _a+=(--syn-limiter meko) ;;
                    classic) _a+=(--syn-limiter classic) ;;
                    *)       _a+=(--syn-limiter off) ;;
                esac
                case "${NFT_OTHER_ACTION:-}" in
                    reject) _a+=(--limiter-action reject) ;;
                    drop)   _a+=(--limiter-action drop) ;;
                    icmp-host-unreachable) _a+=(--limiter-action icmp) ;;
                esac
            fi
        fi
    fi

    if [ "${_AG_ON[meko]}" = "yes" ]; then
        [ "${MEKO_OPT_APPLIED:-false}" = "true" ] && _a+=(--meko yes) || _a+=(--meko no)
    fi

    if [ "${_AG_ON[selfmask]}" = "yes" ] && [ -n "${SELFMASK_DOMAIN:-}" ]; then
        _a+=(--selfmask "$SELFMASK_DOMAIN")
        _a+=(--selfmask-cert "${SELFMASK_CERT_MODE:-letsencrypt}")
        [ -n "${SELFMASK_CERT_EMAIL:-}" ] && _a+=(--selfmask-email "$SELFMASK_CERT_EMAIL")
        [ -n "${SELFMASK_SITE_SOURCE:-}" ] && _a+=(--selfmask-template "$SELFMASK_SITE_SOURCE")
        [ -n "${SELFMASK_NGINX_BACKEND_PORT:-}" ] && _a+=(--selfmask-backend-port "$SELFMASK_NGINX_BACKEND_PORT")
        # WEB стоит на плечах Selfmask, поэтому только внутри его ветки.
        if [ "${_AG_ON[web]}" = "yes" ]; then
            _a+=(--web yes --web-layout "${WEB_LAYOUT:-shared}")
            _a+=(--web-carrier "${WEB_CARRIER:-websocket-lanes}")
            _a+=(--web-secret-mode "${WEB_SECRET_MODE:-dd}")
            [ -n "${WEB_DOMAIN:-}" ] && _a+=(--web-domain "$WEB_DOMAIN")
            [ "${WEB_LAYOUT:-shared}" = "split" ] && _a+=(--web-port "${WEB_PUBLIC_PORT:-443}")
        fi
    fi

    [ "${_AG_ON[geoip]}" = "yes" ] && _a+=(--geoip yes)

    if [ "${_AG_ON[block]}" = "yes" ]; then
        local _bl; _bl=$(ipblock_entries 2>/dev/null | paste -sd, -)
        if [ -n "$_bl" ]; then
            _a+=(--block "$_bl")
            [ "${IPBLOCK_ACTION:-drop}" = "reject" ] && _a+=(--block-action reject)
        fi
    fi

    local _s
    for _s in "${_a[@]}"; do printf '%q ' "$_s"; done
}

# В значениях храним то, что уйдёт в аргументы; человеку показываем словами.
_ag_engine_label() {
    case "$1" in
        binary:*) echo "бинарник ${1#binary:}" ;;
        binary)   echo "бинарник, последняя версия" ;;
        *)        echo "Docker-образ" ;;
    esac
}

# printf %-30s меряет байты, а кириллица двухбайтовая — колонки разъезжались.
_ag_pad() {
    local _s="$1" _w="$2" _len
    _len=$(printf '%s' "$_s" | wc -m)
    printf '%s' "$_s"
    while [ "$_len" -lt "$_w" ]; do printf ' '; _len=$((_len + 1)); done
}

_argsgen_print_command() {
    local _branch="${GITHUB_BRANCH:-main}"
    local _url="https://raw.githubusercontent.com/${GITHUB_REPO:-Liafanx/MTProxyL}/${_branch}/install.sh"
    local _branch_arg=""
    # Ветку указываем явно: список библиотек берётся из install.sh, и если он
    # с одной ветки, а файлы качаются с другой, установка падает на 404.
    [ "$_branch" != "main" ] && _branch_arg=" --branch ${_branch}"

    echo ""
    echo -e "  ${BOLD}Скопируйте это на новый сервер и выполните под root:${NC}"
    echo ""
    echo -e "${CYAN}wget -qO /tmp/mtproxyl-install.sh ${_url}${NC}"
    echo -e "${CYAN}bash /tmp/mtproxyl-install.sh${_branch_arg} -- $(_argsgen_build)${NC}"
    echo ""
}

_argsgen_edit() {
    local _key="$1" _v=""
    case "$_key" in
        engine)
            echo -e "  ${DIM}Чем новый сервер будет держать движок.${NC}"
            echo -e "  ${DIM}[1]${NC} Docker-образ"
            echo -e "  ${DIM}[2]${NC} бинарник MTProxyL-Telemt, та же версия, что здесь"
            echo -e "  ${DIM}[3]${NC} бинарник MTProxyL-Telemt, последняя версия"
            local _ec; _ec=$(read_choice "выбор" "1")
            case "$_ec" in
                2)
                    local _ev; _ev=$(binengine_version)
                    if [ -z "$_ev" ] || [ "$_ev" = "unknown" ]; then
                        log_warn "Версия здешнего бинарника неизвестна — возьмём последнюю"
                        _AG_VAL[engine]="binary"
                    else
                        _AG_VAL[engine]="binary:${_ev}"
                    fi ;;
                3) _AG_VAL[engine]="binary" ;;
                *) _AG_VAL[engine]="docker" ;;
            esac ;;
        port)
            echo -en "  ${BOLD}Порт прокси [${_AG_VAL[port]}]:${NC} "; read_line _v
            [ -n "$_v" ] || return 0
            validate_port "$_v" || { log_error "Порт: 1..65535"; return 1; }
            _AG_VAL[port]="$_v" ;;
        host)
            echo -e "  ${DIM}Что подставлять в ссылки. Пусто — новый сервер определит свой адрес.${NC}"
            echo -en "  ${BOLD}Домен [${_AG_VAL[host]:-нет}]:${NC} "; read_line _v
            if [ -z "$_v" ]; then _AG_ON[host]="no"; _AG_VAL[host]=""; return 0; fi
            validate_domain "$_v" || { log_error "Нужен домен, IP переносить бессмысленно"; return 1; }
            _AG_VAL[host]="$_v"; _AG_ON[host]="yes" ;;
        sni)
            echo -en "  ${BOLD}FakeTLS SNI [${_AG_VAL[sni]}]:${NC} "; read_line _v
            [ -n "$_v" ] || return 0
            validate_domain "$_v" || { log_error "Нужен домен"; return 1; }
            _AG_VAL[sni]="$_v" ;;
        selfmask)
            echo -e "  ${DIM}Домен и тип сертификата берутся из текущих настроек Selfmask.${NC}"
            echo -e "  ${DIM}Изменить их: меню «Дополнения» → Selfmask.${NC}" ;;
        web)
            echo -e "  ${DIM}Домен, раскладка и carrier берутся из текущих настроек WEB.${NC}"
            echo -e "  ${DIM}Изменить их: mtproxyl web set. Требует включённого Selfmask.${NC}" ;;
        *) log_info "У этого пункта нечего править — он только включается и выключается" ;;
    esac
    return 0
}

# Меню: сверху готовая команда, ниже — что в неё входит.
tui_args_export_menu() {
    _require_manager_mode || { press_any_key; return 0; }
    _argsgen_defaults

    while true; do
        clear_screen
        draw_header "ПЕРЕНОС АРГУМЕНТАМИ"
        echo ""
        echo -e "  ${DIM}Готовая команда установки из текущей конфигурации. Пригодится,${NC}"
        echo -e "  ${DIM}когда до нового сервера отсюда не достучаться, а повторить${NC}"
        echo -e "  ${DIM}настройки надо в точности.${NC}"
        _argsgen_print_command

        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo ""
        local _i=1 _row _key _label _editable _state
        for _row in "${_AG_ITEMS[@]}"; do
            IFS='|' read -r _key _label _editable <<< "$_row"
            if [ "${_AG_ON[$_key]}" = "yes" ]; then
                _state="${GREEN}вкл${NC} "
            else
                _state="${DIM}выкл${NC}"
            fi
            local _shown="${_AG_VAL[$_key]}"
            [ "$_key" = "engine" ] && _shown=$(_ag_engine_label "$_shown")
            echo -e "  ${CYAN}[$(printf '%2d' "$_i")]${NC} ${_state}  $(_ag_pad "$_label" 28)${DIM}${_shown}${NC}"
            _i=$((_i + 1))
        done
        echo ""
        echo -e "  ${DIM}Номер — включить или выключить пункт. «e» и номер (например e1) —${NC}"
        echo -e "  ${DIM}изменить значение. «r» — вернуть всё из текущей конфигурации.${NC}"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""

        local _c; _c=$(read_choice "выбор" "0")
        case "$_c" in
            0|"") return ;;
            r|R|с|С) _argsgen_defaults; log_success "Вернули значения из конфигурации"; press_any_key ;;
            e*|E*|у*|У*)
                local _n="${_c:1}"
                if ! [[ "$_n" =~ ^[0-9]+$ ]] || [ "$_n" -lt 1 ] || [ "$_n" -gt "${#_AG_ITEMS[@]}" ]; then
                    log_error "После «e» нужен номер пункта, например e1"; press_any_key; continue
                fi
                IFS='|' read -r _key _label _editable <<< "${_AG_ITEMS[$((_n - 1))]}"
                echo ""
                _argsgen_edit "$_key" || true
                press_any_key ;;
            *)
                if ! [[ "$_c" =~ ^[0-9]+$ ]] || [ "$_c" -gt "${#_AG_ITEMS[@]}" ]; then
                    log_error "Нет такого пункта"; press_any_key; continue
                fi
                IFS='|' read -r _key _label _editable <<< "${_AG_ITEMS[$((_c - 1))]}"
                if [ "$_key" = "host" ] && [ "${_AG_ON[host]}" != "yes" ] && [ -z "${_AG_VAL[host]}" ]; then
                    echo ""
                    log_info "В ссылках сейчас адрес сервера, а не домен — переносить нечего"
                    log_info "Задать домен для нового сервера: e4"
                    press_any_key; continue
                fi
                [ "${_AG_ON[$_key]}" = "yes" ] && _AG_ON[$_key]="no" || _AG_ON[$_key]="yes" ;;
        esac
    done
}
