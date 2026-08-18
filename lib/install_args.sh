#!/bin/bash
# MTProxyL — установка режима менеджера аргументами, без единого вопроса.
# Нужна при переезде: заблокировали адрес — поднимаем копию на другом сервере
# с тем же портом, доменом ссылок, секретами и меткой, и меняем только A-запись.

# Ответы мастера фиксов задаются здесь, а читает их _fix_read (lib/install.sh).
_FIX_ANS_ZAPRET2=""
_FIX_ANS_LIMITER=""
_FIX_ANS_OTHER_ACTION=""
_FIX_ANS_MEKO=""

# Пусто — «не задано»: такие параметры остаются на значениях по умолчанию.
_IA_PORT=""; _IA_METRICS_PORT=""; _IA_API_PORT=""
_IA_HOST=""; _IA_SNI=""; _IA_AD_TAG=""
_IA_MASK=""; _IA_SNI_POLICY=""
_IA_CPUS=""; _IA_MEMORY=""
_IA_SECRETS=()
_IA_SELFMASK_DOMAIN=""; _IA_SELFMASK_CERT=""; _IA_SELFMASK_EMAIL=""
_IA_SELFMASK_TEMPLATE=""; _IA_SELFMASK_BACKEND_PORT=""
_IA_FORCE="false"

install_args_help() {
    cat <<'EOF'
  Установка менеджера аргументами (без вопросов)

    mtproxyl install --mode manager [параметры]

  Прокси
    --port N                   порт прокси (по умолчанию 443)
    --metrics-port N           порт метрик Prometheus (по умолчанию свободный)
    --api-port N               порт REST API движка (по умолчанию свободный)
    --host <ip|домен>          что подставлять в ссылки (по умолчанию свой IP)
    --sni <домен>              FakeTLS домен (по умолчанию autoscout24.ru)
    --secret [метка:]<32 hex>  секрет; можно повторять; без него сгенерируем
    --ad-tag <32 hex>          рекламная метка
    --mask on|off              маскировка трафика (по умолчанию on)
    --sni-policy <политика>    mask, drop, accept или reject_handshake
    --cpus N                   лимит CPU контейнера
    --memory 512m              лимит памяти контейнера

  Обход блокировок
    --zapret2 yes|no           Zapret2 MTProto fix (по умолчанию yes)
    --syn-limiter meko|classic|off
                               NFT SYN limiter, если Zapret2 не ставится
    --limiter-action icmp|reject|drop
                               действие для не-iOS в режиме meko
    --meko yes|no              оптимизация системы By-MEKO (по умолчанию yes)

  Selfmask
    --selfmask <домен>         включить Selfmask на этом домене
    --selfmask-cert letsencrypt|selfsigned
    --selfmask-email <email>   почта для Let's Encrypt
    --selfmask-template stub|filemanager|catrunner|mekorunner|<url>
    --selfmask-backend-port N  локальный порт nginx (по умолчанию 8444)

  Прочее
    --force                    ставить поверх существующей установки

  Пример переезда на новый сервер:
    mtproxyl install --mode manager --port 443 --host proxy.example.com \
      --sni m.beboo.ru --secret vpn:0123...ef --ad-tag 89ab...01 \
      --zapret2 yes --selfmask proxy.example.com --selfmask-cert letsencrypt
EOF
}

# Разбор аргументов. 1 — аргумент неизвестен или значение не годится,
# 2 — попросили справку.
_install_args_parse() {
    # «--ключ=значение» разбираем в два токена, дальше форма ровно одна.
    local -a _a=()
    local _t
    for _t in "$@"; do
        case "$_t" in
            --*=*) _a+=("${_t%%=*}" "${_t#*=}") ;;
            *)     _a+=("$_t") ;;
        esac
    done

    local _k _v _i=0
    while [ $_i -lt ${#_a[@]} ]; do
        _k="${_a[$_i]}"
        _v=""
        # Ключам со значением оно обязательно: молча съесть следующий ключ
        # как значение — верный способ поставить не то, что просили.
        case "$_k" in
            --force|--yes|-y|-h|--help) ;;
            *)
                _v="${_a[$((_i + 1))]-}"
                if [ -z "$_v" ] || [ "${_v#--}" != "$_v" ]; then
                    log_error "${_k}: не хватает значения"
                    return 1
                fi
                _i=$((_i + 1)) ;;
        esac

        case "$_k" in
            --mode)
                if [ "$_v" != "manager" ]; then
                    log_error "Аргументами ставится только менеджер: --mode manager"
                    log_info "Реаниматор чинит чужую цель — её параметры берутся с сервера, а не из ключей"
                    return 1
                fi ;;
            --port)          _IA_PORT="$_v" ;;
            --metrics-port)  _IA_METRICS_PORT="$_v" ;;
            --api-port)      _IA_API_PORT="$_v" ;;
            --host|--ip)     _IA_HOST="$_v" ;;
            --sni|--domain)  _IA_SNI="$_v" ;;
            --ad-tag|--tag)  _IA_AD_TAG="$_v" ;;
            --mask)          _IA_MASK="$_v" ;;
            --sni-policy)    _IA_SNI_POLICY="$_v" ;;
            --cpus)          _IA_CPUS="$_v" ;;
            --memory|--ram)  _IA_MEMORY="$_v" ;;
            --secret)        _IA_SECRETS+=("$_v") ;;
            --zapret2)
                case "${_v,,}" in
                    yes|y|да|true|on)   _FIX_ANS_ZAPRET2="" ;;
                    no|n|нет|false|off) _FIX_ANS_ZAPRET2="n" ;;
                    *) log_error "--zapret2: yes или no"; return 1 ;;
                esac ;;
            --syn-limiter|--limiter)
                case "${_v,,}" in
                    meko|smart) _FIX_ANS_LIMITER="1" ;;
                    classic)    _FIX_ANS_LIMITER="2" ;;
                    off|no|нет) _FIX_ANS_LIMITER="0" ;;
                    *) log_error "--syn-limiter: meko, classic или off"; return 1 ;;
                esac ;;
            --limiter-action)
                case "${_v,,}" in
                    icmp|icmp-host-unreachable) _FIX_ANS_OTHER_ACTION="1" ;;
                    reject) _FIX_ANS_OTHER_ACTION="2" ;;
                    drop)   _FIX_ANS_OTHER_ACTION="3" ;;
                    *) log_error "--limiter-action: icmp, reject или drop"; return 1 ;;
                esac ;;
            --meko)
                case "${_v,,}" in
                    yes|y|да|true|on)   _FIX_ANS_MEKO="" ;;
                    no|n|нет|false|off) _FIX_ANS_MEKO="n" ;;
                    *) log_error "--meko: yes или no"; return 1 ;;
                esac ;;
            --selfmask)              _IA_SELFMASK_DOMAIN="$_v" ;;
            --selfmask-cert)         _IA_SELFMASK_CERT="$_v" ;;
            --selfmask-email)        _IA_SELFMASK_EMAIL="$_v" ;;
            --selfmask-template)     _IA_SELFMASK_TEMPLATE="$_v" ;;
            --selfmask-backend-port) _IA_SELFMASK_BACKEND_PORT="$_v" ;;
            --force|--yes|-y)        _IA_FORCE="true" ;;
            -h|--help)               install_args_help; return 2 ;;
            *) log_error "Неизвестный аргумент: ${_k}"; return 1 ;;
        esac
        _i=$((_i + 1))
    done
    return 0
}

# Проверка всего разом до первого изменения на сервере: половину установки
# откатывать некому, а ошибка в аргументе — обычное дело.
_install_args_validate() {
    local _ok=true

    if [ -n "$_IA_PORT" ] && ! validate_port "$_IA_PORT"; then
        log_error "--port: 1..65535"; _ok=false
    fi
    local _p
    for _p in "$_IA_METRICS_PORT" "$_IA_API_PORT" "$_IA_SELFMASK_BACKEND_PORT"; do
        [ -n "$_p" ] || continue
        validate_port "$_p" || { log_error "Порт '${_p}': 1..65535"; _ok=false; }
    done

    if [ -n "$_IA_HOST" ] && ! validate_ip_literal "$_IA_HOST" && ! validate_domain "$_IA_HOST"; then
        log_error "--host: IPv4 или домен, получили '${_IA_HOST}'"; _ok=false
    fi
    if [ -n "$_IA_SNI" ] && ! validate_domain "$_IA_SNI"; then
        log_error "--sni: домен, получили '${_IA_SNI}'"; _ok=false
    fi
    if [ -n "$_IA_AD_TAG" ] && ! [[ "$_IA_AD_TAG" =~ ^[0-9a-fA-F]{32}$ ]]; then
        log_error "--ad-tag: 32 hex-символа"; _ok=false
    fi
    if [ -n "$_IA_MASK" ]; then
        case "${_IA_MASK,,}" in on|off|yes|no|true|false) ;; *) log_error "--mask: on или off"; _ok=false ;; esac
    fi
    if [ -n "$_IA_SNI_POLICY" ]; then
        case "$_IA_SNI_POLICY" in
            mask|drop|accept|reject_handshake) ;;
            *) log_error "--sni-policy: mask, drop, accept или reject_handshake"; _ok=false ;;
        esac
    fi
    # docker меряет лимит ядрами этой машины: 4 на одноядерной он не примет и
    # уронит контейнер уже после установки. Ловим здесь, а не там.
    if [ -n "$_IA_CPUS" ]; then
        local _cores; _cores=$(nproc 2>/dev/null || echo 1)
        if ! awk -v v="$_IA_CPUS" -v c="$_cores" 'BEGIN{exit !(v+0>0 && v+0<=c+0)}' 2>/dev/null; then
            log_error "--cpus ${_IA_CPUS}: на этой машине ядер ${_cores}, docker примет от 0.01 до ${_cores}"
            _ok=false
        fi
    fi

    local _s _label _key
    for _s in "${_IA_SECRETS[@]}"; do
        _key="${_s##*:}"; _label="${_s%:*}"
        [ "$_label" = "$_s" ] && _label="default"
        if ! [[ "$_key" =~ ^[0-9a-fA-F]{32}$ ]]; then
            log_error "--secret '${_s}': ключ — 32 hex-символа, формат «метка:ключ» или просто ключ"; _ok=false
        fi
        if ! [[ "$_label" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_error "--secret '${_s}': в метке только буквы, цифры, дефис и подчёркивание"; _ok=false
        fi
    done

    if [ -n "$_IA_SELFMASK_DOMAIN" ] && ! validate_domain "$_IA_SELFMASK_DOMAIN"; then
        log_error "--selfmask: домен, получили '${_IA_SELFMASK_DOMAIN}'"; _ok=false
    fi
    if [ -n "$_IA_SELFMASK_CERT" ]; then
        case "$_IA_SELFMASK_CERT" in
            letsencrypt|selfsigned) ;;
            *) log_error "--selfmask-cert: letsencrypt или selfsigned"; _ok=false ;;
        esac
    fi
    if [ -n "$_IA_SELFMASK_CERT" ] || [ -n "$_IA_SELFMASK_EMAIL" ] || \
       [ -n "$_IA_SELFMASK_TEMPLATE" ] || [ -n "$_IA_SELFMASK_BACKEND_PORT" ]; then
        [ -n "$_IA_SELFMASK_DOMAIN" ] || { log_error "Параметры Selfmask заданы без --selfmask <домен>"; _ok=false; }
    fi

    [ "$_ok" = "true" ]
}

# Порт, который просили, либо первый свободный от него же.
_install_args_pick_port() {
    local _want="$1" _fallback="$2"
    if [ -n "$_want" ]; then echo "$_want"; return 0; fi
    find_free_metrics_port "$_fallback" 9199 2>/dev/null || echo "$_fallback"
}

run_installer_args() {
    check_root

    _install_args_parse "$@"
    case $? in
        0) ;;
        2) return 0 ;;
        *) echo ""; log_info "Справка: mtproxyl install --help"; return 1 ;;
    esac
    _install_args_validate || { echo ""; log_info "Справка: mtproxyl install --help"; return 1; }

    if [ -f "${INSTALL_DIR}/mtproxyl.sh" ] && [ -f "$SETTINGS_FILE" ] && [ "$_IA_FORCE" != "true" ]; then
        log_error "MTProxyL уже установлен — переустановка поверх только с --force"
        return 1
    fi

    # Дальше вопросов не будет: мастер фиксов и Selfmask читают готовые ответы.
    MTPROXYL_NONINTERACTIVE="true"
    MTPROXYL_MODE="manager"

    show_banner
    draw_header "УСТАНОВКА АРГУМЕНТАМИ"
    echo ""
    log_info "Режим: manager, вопросов не будет"
    echo ""

    _install_args_deps || return 1
    # Подкачка до docker: на машине с гигабайтом памяти сборка и запуск иначе
    # упираются в OOM, и установка выглядит зависшей.
    offer_swap_if_low_ram
    install_docker || return 1
    wait_for_docker || return 1

    PROXY_PORT="${_IA_PORT:-${PROXY_PORT:-443}}"
    if ! is_port_available "$PROXY_PORT" 2>/dev/null; then
        log_warn "Порт ${PROXY_PORT} уже занят — контейнер может не подняться"
        show_port_listener "$PROXY_PORT" 2>/dev/null || true
    fi
    PROXY_METRICS_PORT=$(_install_args_pick_port "$_IA_METRICS_PORT" "${PROXY_METRICS_PORT:-9090}")
    PROXY_API_PORT=$(_install_args_pick_port "$_IA_API_PORT" "${PROXY_API_PORT:-9091}")
    if [ "$PROXY_API_PORT" = "$PROXY_METRICS_PORT" ] || [ "$PROXY_API_PORT" = "$PROXY_PORT" ]; then
        log_error "Порт API (${PROXY_API_PORT}) совпадает с портом прокси или метрик"
        return 1
    fi
    log_success "Порты: прокси ${PROXY_PORT}, метрики ${PROXY_METRICS_PORT}, API ${PROXY_API_PORT}"

    if [ -n "$_IA_HOST" ]; then
        CUSTOM_IP="$_IA_HOST"
        log_success "В ссылках: ${CUSTOM_IP}"
    else
        CUSTOM_IP=""
        log_info "В ссылках: определяем адрес сам ($(CUSTOM_IP="" get_public_ip 2>/dev/null || echo "?"))"
    fi

    PROXY_DOMAIN="${_IA_SNI:-${PROXY_DOMAIN:-autoscout24.ru}}"
    auto_set_fake_cert_len "$PROXY_DOMAIN" 2>/dev/null || \
        log_warn "Не удалось снять TLS cert length с '${PROXY_DOMAIN}', оставляем ${FAKE_CERT_LEN:-2048}"
    log_success "FakeTLS домен: ${PROXY_DOMAIN}"

    case "${_IA_MASK,,}" in
        off|no|false) MASKING_ENABLED="false" ;;
        on|yes|true)  MASKING_ENABLED="true" ;;
    esac
    [ -n "$_IA_SNI_POLICY" ] && UNKNOWN_SNI_ACTION="$_IA_SNI_POLICY"
    [ -n "$_IA_AD_TAG" ] && AD_TAG="$_IA_AD_TAG"
    # Лимиты берутся только из аргументов: при установке поверх старой (--force)
    # донашивать чужие значения — верный способ получить контейнер, который
    # docker на этой машине запустить откажется.
    PROXY_CPUS="$_IA_CPUS"
    PROXY_MEMORY="$_IA_MEMORY"

    _install_args_secrets

    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$STATS_DIR" "$BACKUP_DIR"
    chmod 700 "$CONFIG_DIR" "$STATS_DIR" "$BACKUP_DIR"
    chmod "${_INSTALL_DIR_MODE:-711}" "$INSTALL_DIR"
    save_settings
    save_secrets
    ln -sf "${INSTALL_DIR}/mtproxyl.sh" /usr/local/bin/mtproxyl

    run_fix_arsenal_wizard

    echo ""
    draw_header "ЗАПУСК ПРОКСИ"
    echo ""
    run_proxy_container || {
        log_error "Не удалось запустить прокси"
        echo -e "  ${DIM}Проверьте: docker logs mtproxyl${NC}"
    }

    _install_args_autostart

    if [ -n "$_IA_SELFMASK_DOMAIN" ]; then
        _install_args_selfmask || log_warn "Selfmask не настроен — остальное установлено"
    fi

    load_settings; load_secrets
    show_install_summary
}

# Пакеты те же, что у интерактивной установки: без них не соберётся ни ссылка,
# ни конфиг движка.
_install_args_deps() {
    log_info "Проверка зависимостей..."
    local missing=()
    command -v curl &>/dev/null || missing+=("curl")
    command -v awk &>/dev/null || missing+=("awk")
    command -v openssl &>/dev/null || missing+=("openssl")
    command -v jq &>/dev/null || missing+=("jq")
    command -v nano &>/dev/null || command -v vim &>/dev/null || missing+=("nano")
    if [ ${#missing[@]} -gt 0 ]; then
        log_info "Установка: ${missing[*]}"
        _wait_apt
        local os; os=$(detect_os)
        case "$os" in
            debian) apt-get update -qq && apt-get install -y -qq "${missing[@]}" ;;
            rhel)   yum install -y -q "${missing[@]}" ;;
            alpine) apk add --no-cache "${missing[@]}" ;;
        esac
    fi
    log_success "Зависимости в порядке"
}

# Секреты из аргументов сохраняем как есть — в этом весь смысл переезда:
# у клиентов ссылки не меняются.
_install_args_secrets() {
    SECRETS_LABELS=(); SECRETS_KEYS=(); SECRETS_CREATED=(); SECRETS_ENABLED=()
    SECRETS_MAX_CONNS=(); SECRETS_MAX_IPS=(); SECRETS_QUOTA=(); SECRETS_EXPIRES=(); SECRETS_NOTES=()

    local _s _label _key _now; _now=$(date +%s)
    if [ ${#_IA_SECRETS[@]} -eq 0 ]; then
        _IA_SECRETS=("default:$(generate_secret)")
        log_info "Секрет не задан — сгенерировали новый"
    fi
    for _s in "${_IA_SECRETS[@]}"; do
        _key="${_s##*:}"; _label="${_s%:*}"
        [ "$_label" = "$_s" ] && _label="default"
        SECRETS_LABELS+=("$_label"); SECRETS_KEYS+=("${_key,,}")
        SECRETS_CREATED+=("$_now"); SECRETS_ENABLED+=("true")
        SECRETS_MAX_CONNS+=("0"); SECRETS_MAX_IPS+=("0")
        SECRETS_QUOTA+=("0"); SECRETS_EXPIRES+=("0"); SECRETS_NOTES+=("")
    done
    log_success "Секретов перенесено: ${#SECRETS_LABELS[@]}"
}

_install_args_autostart() {
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/mtproxyl.service << 'SVC_EOF'
[Unit]
Description=MTProxyL Telegram Proxy
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/mtproxyl start
ExecStop=/usr/local/bin/mtproxyl stop

[Install]
WantedBy=multi-user.target
SVC_EOF
        systemctl daemon-reload
        systemctl enable mtproxyl.service 2>/dev/null
        log_success "Автозапуск включён"
        install_ip_history_timer
    fi
    install_availability_timer
}

# Selfmask с готовыми параметрами: мастер опроса пропускается, всё остальное
# (nginx, сертификат, патч настроек) делается тем же кодом, что и вручную.
_install_args_selfmask() {
    echo ""
    draw_header "SELFMASK"
    echo ""
    load_selfmask_settings 2>/dev/null || true
    SELFMASK_DOMAIN="${_IA_SELFMASK_DOMAIN,,}"
    SELFMASK_CERT_MODE="${_IA_SELFMASK_CERT:-letsencrypt}"
    [ -n "$_IA_SELFMASK_TEMPLATE" ] && SELFMASK_SITE_SOURCE="$_IA_SELFMASK_TEMPLATE"
    [ -n "$_IA_SELFMASK_BACKEND_PORT" ] && SELFMASK_NGINX_BACKEND_PORT="$_IA_SELFMASK_BACKEND_PORT"
    if [ "$SELFMASK_CERT_MODE" = "letsencrypt" ]; then
        SELFMASK_CERT_EMAIL="${_IA_SELFMASK_EMAIL:-admin@${SELFMASK_DOMAIN}}"
        # A-запись переезжает руками владельца домена, и до неё Let's Encrypt
        # не выпишет сертификат. Отказ здесь честнее сломанной установки.
        if ! _selfmask_check_dns "$SELFMASK_DOMAIN" >/dev/null 2>&1; then
            log_error "DNS ${SELFMASK_DOMAIN} пока смотрит не на этот сервер"
            log_info "Переведите A-запись и повторите: mtproxyl selfmask setup"
            log_info "Либо ставьте с --selfmask-cert selfsigned — там A-запись не нужна"
            return 1
        fi
    fi
    selfmask_setup
}
