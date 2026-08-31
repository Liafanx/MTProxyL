#!/bin/bash
# MTProxyL — Selfmask через локальный nginx + Let's Encrypt
# Важно: backend nginx для mask работает на TLS 1.3

SELFMASK_PQ_PREFIX="/opt/mtproxyl-nginx"
SELFMASK_PQ_SERVICE="mtproxyl-pq-nginx.service"
SELFMASK_PQ_RELEASE_TAG="pq-nginx-1.28.3-openssl3.5.7-r2"
SELFMASK_PQ_NGINX_VERSION="1.28.3"
SELFMASK_PQ_OPENSSL_VERSION="3.5.7"

_selfmask_pq_nginx_bin() {
    echo "${SELFMASK_PQ_PREFIX}/sbin/nginx"
}

_selfmask_pq_openssl_bin() {
    echo "${SELFMASK_PQ_PREFIX}/bin/openssl"
}

# Минимальная версия OpenSSL с постквантовым обменом ключами (X25519MLKEM768)
# из коробки. До 3.5.0 его нет вовсе, и нужен наш собранный.
SELFMASK_MIN_SYSTEM_OPENSSL="3.5.0"

# Сравнение версий вида 3.5.7: возвращает 0, если $1 >= $2.
_version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# Умеет ли системный OpenSSL постквантовый обмен ключами.
# С 3.5.0 X25519MLKEM768 штатно — своя сборка не нужна.
_system_openssl_has_pq() {
    local _bin; _bin=$(command -v openssl 2>/dev/null) || return 1
    local _ver; _ver=$("$_bin" version 2>/dev/null | awk '{print $2}')
    # Версия бывает с суффиксом: "3.5.7", "3.6.0-dev". Берём числовую часть.
    _ver="${_ver%%-*}"
    [[ "$_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    _version_ge "$_ver" "$SELFMASK_MIN_SYSTEM_OPENSSL" || return 1
    # Версия — необходимое условие, но сборка может быть собрана без ML-KEM.
    # Спрашиваем сам бинарник, а не полагаемся на номер.
    "$_bin" list -kem-algorithms 2>/dev/null | grep -qi 'mlkem768\|ml-kem-768' && return 0
    "$_bin" list -group-algorithms 2>/dev/null | grep -qi 'X25519MLKEM768' && return 0
    return 1
}

# Какой openssl использовать для проверок PQ: системный, если он умеет, иначе
# наш собранный. Пустой вывод означает, что подходящего нет вовсе.
_pq_openssl_bin() {
    if _system_openssl_has_pq; then
        command -v openssl
        return 0
    fi
    local _own; _own=$(_selfmask_pq_openssl_bin)
    [ -x "$_own" ] && { echo "$_own"; return 0; }
    return 1
}

# Умеет ли системный nginx PQ. Важно, с чем слинкован он сам, а не
# версия CLI openssl — это разные пакеты. Спрашиваем nginx через -V.
_system_nginx_has_pq() {
    local _bin; _bin=$(command -v nginx 2>/dev/null) || return 1
    local _ssl
    _ssl=$("$_bin" -V 2>&1 | grep -oE 'OpenSSL [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}')
    [ -n "$_ssl" ] || return 1
    _version_ge "$_ssl" "$SELFMASK_MIN_SYSTEM_OPENSSL"
}

_system_nginx_has_stream() {
    local _bin; _bin=$(command -v nginx 2>/dev/null) || return 1
    "$_bin" -V 2>&1 | grep -q -- '--with-stream_ssl_preread_module'
}

_selfmask_web_needs_stream() {
    [ "${WEB_ENABLED:-false}" = "true" ] \
        && [ "${PROXY_MODE:-mtproto}" != "web" ] \
        && [ "${WEB_LAYOUT:-shared}" != "split" ]
}

# Какой nginx использовать для заглушки. Системный годится при OpenSSL
# 3.5.0+, но запускаем со своим конфигом и юнитом: в /etc/nginx чужой сайт.
_selfmask_nginx_bin() {
    if _system_nginx_has_pq \
       && { ! _selfmask_web_needs_stream || _system_nginx_has_stream; }; then
        command -v nginx
        return 0
    fi
    echo "$(_selfmask_pq_nginx_bin)"
}

_selfmask_conf_needs_stream() {
    [ -f "$1" ] && grep -qE '^[[:space:]]*stream[[:space:]]*\{' "$1" 2>/dev/null
}

_selfmask_nginx_bin_for_conf() {
    local _conf="$1"
    if _selfmask_conf_needs_stream "$_conf" && ! _system_nginx_has_stream; then
        echo "$(_selfmask_pq_nginx_bin)"
    else
        _selfmask_nginx_bin
    fi
}

_selfmask_nginx_source() {
    if _system_nginx_has_pq \
       && { ! _selfmask_web_needs_stream || _system_nginx_has_stream; }; then
        echo "системный nginx ($(nginx -V 2>&1 | grep -oE 'OpenSSL [0-9]+\.[0-9]+\.[0-9]+' | head -1))"
    else
        echo "nginx из состава MTProxyL (OpenSSL ${SELFMASK_PQ_OPENSSL_VERSION})"
    fi
}

# Человекочитаемое описание источника — для вывода и для панели.
_pq_openssl_source() {
    if _system_openssl_has_pq; then
        echo "системный OpenSSL $(openssl version 2>/dev/null | awk '{print $2}')"
    elif [ -x "$(_selfmask_pq_openssl_bin)" ]; then
        echo "PQ OpenSSL из состава MTProxyL"
    else
        echo ""
    fi
}

NGINX_CUSTOM_FILE="${INSTALL_DIR:-/opt/mtproxyl}/nginx-custom.conf"

_selfmask_generated_pq_conf() {
    echo "${SELFMASK_PQ_PREFIX}/conf/nginx.conf"
}

_selfmask_custom_pq_conf() {
    echo "$NGINX_CUSTOM_FILE"
}

nginx_custom_active() {
    [ "${NGINX_CUSTOM_ENABLED:-false}" = "true" ] && [ -f "$NGINX_CUSTOM_FILE" ]
}

_selfmask_pq_conf() {
    if [ "${NGINX_CUSTOM_ENABLED:-false}" = "true" ]; then
        _selfmask_custom_pq_conf
    else
        _selfmask_generated_pq_conf
    fi
}

# Без mime.types nginx отдаёт всё как text/plain, и браузер такой CSS не
# применяет — многофайловая заглушка открывалась без стилей. Файла может не
# оказаться в чужой сборке: тогда лучше без include, чем nginx, который не
# стартует.
_selfmask_nginx_mime_block() {
    local _f="${SELFMASK_PQ_PREFIX}/conf/mime.types"
    [ -f "$_f" ] || return 0
    printf '    include       %s;\n    default_type  application/octet-stream;\n\n' "$_f"
}

_selfmask_template_label() {
    case "${1:-stub}" in
        stub)        echo "Простая заглушка" ;;
        filemanager) echo "Файловый менеджер" ;;
        catrunner)   echo "Cat Runner" ;;
        mekorunner)  echo "MEKO Runner" ;;
        http*)       echo "$1" ;;
        /*)          echo "свой сайт: $1" ;;
        *)           echo "${1:-stub}" ;;
    esac
}

# Настоящий внешний адрес сервера — спрошенный у сети, а не у настроек.
# get_public_ip первым делом отдаёт CUSTOM_IP, «IP/домен сервера» для
# tg://-ссылок: там бывает домен, и сверка с A-записью тогда не сходится
# никогда.
_selfmask_real_public_ip() {
    CUSTOM_IP="" get_public_ip 2>/dev/null
}

# Все адреса этого сервера: переданный внешний плюс адреса интерфейсов.
# Каждый печатаем отдельным printf: источники не гарантируют перевод строки,
# и без этого адреса склеиваются в одну строку.
_selfmask_own_addresses() {
    local _pub="${1:-}" _ip
    [ -n "$_pub" ] && printf '%s\n' "$_pub"
    for _ip in $(hostname -I 2>/dev/null); do
        printf '%s\n' "$_ip"
    done
}

# Указывает ли домен на этот сервер.
# 0 — да, 1 — нет, 2 — проверить не удалось.
_selfmask_check_dns() {
    local _domain="$1"
    local _a; _a=$(getent ahostsv4 "$_domain" 2>/dev/null | awk '{print $1}' | sort -u)

    if [ -z "$_a" ]; then
        log_warn "A-запись ${_domain} не найдена"
        log_info "Домен должен резолвиться в адрес этого сервера, иначе Let's Encrypt откажет"
        return 2
    fi
    log_info "A-запись ${_domain}: $(echo "$_a" | tr '\n' ' ')"

    local _pub; _pub=$(_selfmask_real_public_ip)
    if [ -n "$_pub" ]; then
        log_info "Внешний IP сервера: ${_pub}"
    else
        log_warn "Не удалось узнать внешний IP сервера — сверить не с чем"
        return 2
    fi

    local _own _ip
    _own=$(_selfmask_own_addresses "$_pub" | grep -v '^[[:space:]]*$' | sort -u)
    while IFS= read -r _ip; do
        [ -n "$_ip" ] || continue
        if printf '%s\n' "$_own" | grep -qxF "$_ip"; then
            log_success "Домен указывает на этот сервер"
            return 0
        fi
    done <<< "$_a"

    log_warn "A-запись домена не совпадает ни с одним адресом этого сервера"
    log_info "Так бывает за CDN или обратным прокси — тогда это нормально"
    return 1
}

# Каталог с готовым сайтом. Принимает и путь к index.html — берём его папку,
# сайт это не один файл, рядом лежат стили, скрипты и картинки.
# Печатает каталог в stdout, диагностику — в stderr: результат забирают через $( ).
_selfmask_resolve_local_site() {
    local _p="${1%/}"
    [ -n "$_p" ] || { log_error "Путь не задан" >&2; return 1; }
    case "$_p" in
        /*) ;;
        *) log_error "Нужен абсолютный путь, например /var/www/site.ru" >&2; return 1 ;;
    esac

    [ -e "$_p" ] || { log_error "Путь не существует: ${_p}" >&2; return 1; }
    [ -f "$_p" ] && _p=$(dirname "$_p")
    [ -d "$_p" ] || { log_error "Не каталог: ${_p}" >&2; return 1; }
    [ -f "${_p}/index.html" ] || { log_error "В каталоге нет index.html: ${_p}" >&2; return 1; }

    # Копировать каталог сам в себя нечем и незачем.
    if [ "$_p" = "${SELFMASK_SITE_DIR%/}" ]; then
        log_error "Это и есть каталог заглушки — укажите другой" >&2
        return 1
    fi
    echo "$_p"
}

# Копирует сайт оператора в каталог заглушки.
_selfmask_copy_local_site() {
    local _src; _src=$(_selfmask_resolve_local_site "$1") || return 1

    log_info "Копирование сайта из ${_src}"
    # Каталог чистим, но не .well-known: там лежит challenge Let's Encrypt.
    find "$SELFMASK_SITE_DIR" -mindepth 1 -maxdepth 1 \
        ! -name '.well-known' -exec rm -rf {} + 2>/dev/null || true

    if ! cp -a "${_src}/." "$SELFMASK_SITE_DIR/" 2>/dev/null; then
        log_error "Не удалось скопировать сайт из ${_src}"
        return 1
    fi
    log_success "Сайт скопирован: $(find "$SELFMASK_SITE_DIR" -type f | wc -l) файлов"
}

_selfmask_selfsigned_dir() {
    echo "${SELFMASK_PQ_PREFIX}/selfsigned/${SELFMASK_DOMAIN}"
}

# Каталог с fullchain.pem/privkey.pem текущего домена — Let's Encrypt либо
# самоподписанный. Имена файлов одинаковы, nginx-конфиг менять не нужно.
_selfmask_cert_dir() {
    if [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "selfsigned" ]; then
        _selfmask_selfsigned_dir
    else
        echo "/etc/letsencrypt/live/${SELFMASK_DOMAIN}"
    fi
}

# Самоподписанный сертификат на произвольный (в т.ч. несуществующий) домен —
# не требует A-записи и внешнего порта 80. CN/SAN = SELFMASK_DOMAIN.
_selfmask_generate_selfsigned_cert() {
    local _dir; _dir="$(_selfmask_selfsigned_dir)"
    if [ -f "${_dir}/fullchain.pem" ] && [ -f "${_dir}/privkey.pem" ]; then
        log_success "Самоподписанный сертификат уже существует"
        return 0
    fi

    mkdir -p "$_dir"

    # Системный openssl: у PQ-сборки нет своего OPENSSLDIR и 'req -x509' в ней
    # не работает. На PQ это не влияет — X25519MLKEM768 согласует nginx.
    local _openssl="openssl"
    command -v openssl &>/dev/null || _openssl="$(_selfmask_pq_openssl_bin)"

    local _err=""
    if ! _err=$("$_openssl" req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "${_dir}/privkey.pem" -out "${_dir}/fullchain.pem" \
        -subj "/CN=${SELFMASK_DOMAIN}" \
        -addext "subjectAltName=DNS:${SELFMASK_DOMAIN}" 2>&1); then
        log_error "Не удалось сгенерировать самоподписанный сертификат"
        [ -n "$_err" ] && echo "$_err" | sed 's/^/    /' >&2
        return 1
    fi
    chmod 600 "${_dir}/privkey.pem"
    log_success "Самоподписанный сертификат создан (CN=${SELFMASK_DOMAIN}, 10 лет)"
}

_selfmask_get_tls_info() {
    local _conf="$(_selfmask_pq_conf)"
    if [ -f "$_conf" ]; then
        local _proto _curve
        _proto=$(grep -m1 'ssl_protocols' "$_conf" 2>/dev/null | awk '{$1=""; print}' | tr -d ';' | xargs)
        _curve=$(grep -m1 'ssl_ecdh_curve' "$_conf" 2>/dev/null | awk '{$1=""; print}' | tr -d ';' | xargs)
        if [ -n "$_proto" ]; then
            [ -n "$_curve" ] && echo "${_proto} (${_curve})" || echo "${_proto}"
            return 0
        fi
    fi
    echo "TLSv1.3 (X25519MLKEM768)"
}

selfmask_supported_os() {
    [ "$(detect_os)" = "debian" ]
}

selfmask_status_line() {
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] || [ "${SELFMASK_CONFIGURE_ACTIVE:-false}" = "true" ]; then
        echo -e "${GREEN}включён${NC} (${SELFMASK_DOMAIN:-?} → 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT:-8444})"
    else
        echo -e "${DIM}выключен${NC}"
    fi
}

# Машинный статус для панели: mtproxyl selfmask status --json
selfmask_show_status_json() {
    local _cert="false" _nginx="false" _conf
    _conf="$(_selfmask_pq_conf)"
    [ -n "${SELFMASK_DOMAIN:-}" ] && [ -f "$(_selfmask_cert_dir)/fullchain.pem" ] && _cert="true"
    systemctl is-active "${SELFMASK_PQ_SERVICE}" &>/dev/null && _nginx="true"

    printf '{"enabled":%s,"domain":"%s","site_source":"%s","site_dir":"%s","backend_port":%d,"cert_mode":"%s","auto_renew":%s,"nginx_conf":"%s","nginx_conf_exists":%s,"nginx_custom_enabled":%s,"nginx_custom_active":%s,"nginx_custom_file":"%s","nginx_custom_file_exists":%s,"cert_found":%s,"pq_nginx_active":%s,"pq_source":"%s","pq_available":%s,"pq_system":%s,"prev_saved":%s,"prev_domain":"%s"}\n' \
        "$([ "${SELFMASK_ENABLED:-false}" = "true" ] && echo true || echo false)" \
        "$(json_escape "${SELFMASK_DOMAIN:-}")" \
        "$(json_escape "${SELFMASK_SITE_SOURCE:-stub}")" \
        "$(json_escape "${SELFMASK_SITE_DIR:-/var/www/mtproxyl-selfmask}")" \
        "${SELFMASK_NGINX_BACKEND_PORT:-8444}" \
        "$(json_escape "${SELFMASK_CERT_MODE:-letsencrypt}")" \
        "$([ "${SELFMASK_AUTO_RENEW:-true}" = "true" ] && echo true || echo false)" \
        "$(json_escape "$_conf")" \
        "$([ -f "$_conf" ] && echo true || echo false)" \
        "$([ "${NGINX_CUSTOM_ENABLED:-false}" = "true" ] && echo true || echo false)" \
        "$(nginx_custom_active && echo true || echo false)" \
        "$(json_escape "$NGINX_CUSTOM_FILE")" \
        "$([ -f "$NGINX_CUSTOM_FILE" ] && echo true || echo false)" \
        "$_cert" "$_nginx" \
        "$(json_escape "$(_pq_openssl_source)")" \
        "$(_pq_openssl_bin >/dev/null 2>&1 && echo true || echo false)" \
        "$(_system_openssl_has_pq && echo true || echo false)" \
        "$([ "${SELFMASK_PREV_SAVED:-false}" = "true" ] && echo true || echo false)" \
        "$(json_escape "${SELFMASK_PREV_DOMAIN:-}")"
}

selfmask_show_requirements() {
    echo ""
    echo -e "  ${BOLD}Selfmask / FakeTLS:${NC}"
    echo -e "  ${GREEN}${SYM_CHECK}${NC} ${DIM}Заглушка ставится самим MTProxyL — PQ hybrid${NC}"
    echo -e "    ${DIM}(X25519MLKEM768) поддерживается гарантированно.${NC}"
    echo -e "  ${DIM}• Backend nginx работает на ${BOLD}TLS 1.3${NC}${DIM}.${NC}"
    echo ""
    if [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "selfsigned" ]; then
        # Самоподписанный сертификат мы выписываем сами и на любой домен —
        # чужого домена в этой схеме нет, проверять на PQ нечего.
        echo -e "  ${DIM}Сертификат самоподписанный: домен может быть любым, даже${NC}"
        echo -e "  ${DIM}несуществующим — A-запись, порт 80 и Let's Encrypt не нужны.${NC}"
        echo -e "  ${DIM}Домен нигде не проверяется: TLS отдаёт наш же nginx, поэтому${NC}"
        echo -e "  ${DIM}поддержка PQ не зависит от выбранного имени.${NC}"
    else
        echo -e "  ${DIM}Если вы используете ${BOLD}чужой${NC}${DIM} домен для FakeTLS — его поддержку${NC}"
        echo -e "  ${DIM}PQ можно проверить: меню ${BOLD}Дополнения${NC}${DIM} → проверка домена на PQ,${NC}"
        echo -e "  ${DIM}либо ботом ${CYAN}@Sni_checker_bot${NC}${DIM}.${NC}"
    fi
    echo ""
}

# При включённом WEB публичный порт держит уже не движок, а nginx: он разбирает
# SNI и разводит FakeTLS и WEB по разным бэкендам. Старая строка про
# «telemt :443 → mask» в этом случае описывала несуществующий путь.
_selfmask_scheme_line() {
    local _back="127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT:-8444}"
    # В реаниматоре WEB поднимает хозяин цели, и наши WEB_* к нему отношения
    # не имеют: раскладку портов оттуда взять неоткуда.
    if web_is_reanimator 2>/dev/null; then
        local _p="${DETECTED_PORT:-${PROXY_PORT:-443}}"
        if web_target_enabled 2>/dev/null; then
            echo "telemt :${_p} → mask → nginx ${_back}; WEB у цели: $(web_target_host 2>/dev/null || echo '—')"
        else
            echo "telemt :${_p} → mask → nginx ${_back}"
        fi
        return 0
    fi
    if ! web_is_enabled 2>/dev/null; then
        echo "telemt :${PROXY_PORT:-443} → mask → nginx ${_back}"
        return 0
    fi
    if web_layout_is_split; then
        echo "telemt :${PROXY_PORT:-443} → mask → nginx ${_back}; WEB: nginx :$(web_public_port) → telemt :${WEB_LISTEN_PORT:-15080}"
    else
        echo "nginx :${PROXY_PORT:-443} → по SNI: telemt :${WEB_MTPROXY_PORT:-15443} → mask → nginx ${_back}; $(web_domain 2>/dev/null) → nginx :${WEB_TLS_PORT:-15444} → telemt :${WEB_LISTEN_PORT:-15080}"
    fi
}

selfmask_show_status() {
    echo ""
    draw_header "SELFMASK"
    echo ""
    echo -e "  ${BOLD}Статус:${NC}         $(selfmask_status_line)"
    echo -e "  ${BOLD}Домен:${NC}          ${SELFMASK_DOMAIN:-${DIM}не задан${NC}}"
    echo -e "  ${BOLD}Источник сайта:${NC} $(_selfmask_template_label "${SELFMASK_SITE_SOURCE:-stub}")"
    echo -e "  ${BOLD}Каталог сайта:${NC}  ${SELFMASK_SITE_DIR:-/var/www/mtproxyl-selfmask}"
    echo -e "  ${BOLD}Backend:${NC}        127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT:-8444}"
    echo -e "  ${BOLD}Схема:${NC}          $(_selfmask_scheme_line)"
    echo -e "  ${BOLD}TLS backend:${NC}    $(_selfmask_get_tls_info)"
    echo -e "  ${BOLD}Тип сертификата:${NC} ${SELFMASK_CERT_MODE:-letsencrypt}"
    [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "letsencrypt" ] && echo -e "  ${BOLD}Продление cert:${NC} ${SELFMASK_AUTO_RENEW:-true}"
    echo ""

    local _site_conf="$(_selfmask_pq_conf)"
    [ -f "$_site_conf" ] && echo -e "  ${BOLD}Nginx conf:${NC}     ${_site_conf}" || echo -e "  ${BOLD}Nginx conf:${NC}     ${DIM}не найден${NC}"
    echo -e "  ${BOLD}Свой nginx conf:${NC} $(nginx_custom_status_line)"

    if [ -n "${SELFMASK_DOMAIN:-}" ] && [ -f "$(_selfmask_cert_dir)/fullchain.pem" ]; then
        echo -e "  ${BOLD}Сертификат:${NC}     ${GREEN}найден${NC}"
    else
        echo -e "  ${BOLD}Сертификат:${NC}     ${DIM}не найден${NC}"
    fi

    if systemctl is-active "${SELFMASK_PQ_SERVICE}" &>/dev/null; then
        echo -e "  ${BOLD}PQ nginx:${NC}       ${GREEN}активен${NC}"
    else
        echo -e "  ${BOLD}PQ nginx:${NC}       ${DIM}не запущен${NC}"
    fi

    selfmask_show_requirements
}

_selfmask_collect_params() {
    echo ""
    draw_header "ПАРАМЕТРЫ SELFMASK"
    echo ""
    echo -e "  ${DIM}Selfmask маскирует прокси под реальный сайт на вашем домене.${NC}"
    echo -e "  ${DIM}MTProto остаётся на порту прокси (${PROXY_PORT:-443}), браузерные запросы и mask идут в локальный nginx.${NC}"
    echo ""
    echo -e "  ${BOLD}Тип сертификата${NC}"
    echo -e "  ${DIM}[1]${NC} Let's Encrypt ${DIM}(реальный домен, нужна A-запись на этот сервер)${NC}"
    echo -e "  ${DIM}[2]${NC} Самоподписанный ${DIM}(любой домен, в т.ч. несуществующий, A-запись не нужна)${NC}"
    local _cm_default="1"; [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "selfsigned" ] && _cm_default="2"
    local _cm; _cm=$(read_choice "выбор" "$_cm_default")
    if [ "$_cm" = "2" ]; then
        SELFMASK_CERT_MODE="selfsigned"
    else
        SELFMASK_CERT_MODE="letsencrypt"
    fi

    [ "$SELFMASK_CERT_MODE" = "letsencrypt" ] && echo -e "  ${DIM}Нужен домен с A-записью на этот сервер.${NC}"
    selfmask_show_requirements

    local _domain=""
    local _saved_domain="${SELFMASK_DOMAIN:-}"

    while true; do
        if [ -n "$_saved_domain" ] && validate_domain "$_saved_domain"; then
            echo -en "  ${BOLD}Ваш домен [${_saved_domain}]:${NC} "
        else
            echo -en "  ${BOLD}Ваш домен:${NC} "
        fi

        read_line _domain
        [ -z "$_domain" ] && _domain="$_saved_domain"
        _domain=$(echo "$_domain" | tr '[:upper:]' '[:lower:]')

        if validate_domain "$_domain"; then
            SELFMASK_DOMAIN="$_domain"
            break
        fi
        log_error "Некорректный домен"
    done

    if [ "$SELFMASK_CERT_MODE" = "letsencrypt" ]; then
        local _email_default
        if [ -n "${SELFMASK_CERT_EMAIL:-}" ]; then
            _email_default="${SELFMASK_CERT_EMAIL}"
        else
            _email_default="admin@${SELFMASK_DOMAIN}"
        fi

        echo -en "  ${BOLD}Email для Let's Encrypt [${_email_default}]:${NC} "
        local _email=""
        read_line _email
        SELFMASK_CERT_EMAIL="${_email:-$_email_default}"

        echo ""
        log_info "Проверяем DNS..."
        _selfmask_check_dns "$SELFMASK_DOMAIN"
        case "$?" in
            0) ;;
            *)
                echo -en "  ${BOLD}Продолжить всё равно? [y/N]:${NC} "
                local _dns_yn
                read_line _dns_yn
                [[ "$_dns_yn" =~ ^[yY] ]] || return 1
                ;;
        esac
    else
        log_info "Самоподписанный сертификат — проверка A-записи не требуется"
    fi

    echo ""
    draw_header "ШАБЛОН САЙТА"
    echo ""
    local _saved_tpl="${SELFMASK_SITE_SOURCE:-stub}"
    echo -e "  ${BOLD}Текущий шаблон:${NC} $(_selfmask_template_label "$_saved_tpl")"
    echo ""
    echo -e "  ${DIM}[0]${NC} Оставить текущий шаблон"
    echo -e "  ${DIM}[1]${NC} Простая заглушка ${DIM}(«Сайт временно недоступен»)${NC}"
    echo -e "  ${DIM}[2]${NC} Файловый менеджер ${DIM}(форма входа с логином/паролем)${NC}"
    echo -e "  ${DIM}[3]${NC} Cat Runner ${DIM}(мини-игра: кот прыгает через кактусы)${NC}"
    echo -e "  ${DIM}[4]${NC} MEKO Runner ${DIM}(MEKO убегает от сотрудников РКН)${NC}"
    echo -e "  ${CYAN}[5]${NC} Указать свой URL ${DIM}(прямая ссылка на index.html)${NC}"
    echo -e "  ${CYAN}[6]${NC} Свой сайт с этого сервера ${DIM}(путь к папке с index.html)${NC}"
    echo ""

    local _tpl
    _tpl=$(read_choice "выбор" "0")
    case "$_tpl" in
        0|"")
            SELFMASK_SITE_SOURCE="$_saved_tpl"
            log_info "Оставлен текущий шаблон: $(_selfmask_template_label "$SELFMASK_SITE_SOURCE")"
            ;;
        2)
            SELFMASK_SITE_SOURCE="filemanager"
            log_info "Выбран шаблон: Файловый менеджер"
            ;;
        3)
            SELFMASK_SITE_SOURCE="catrunner"
            log_info "Выбран шаблон: Cat Runner"
            ;;
        4)
            SELFMASK_SITE_SOURCE="mekorunner"
            log_info "Выбран шаблон: MEKO Runner"
            ;;
        5)
            echo -en "  ${BOLD}URL файла index.html:${NC} "
            local _custom_url
            read_line _custom_url
            if [[ "$_custom_url" =~ ^https?:// ]]; then
                SELFMASK_SITE_SOURCE="$_custom_url"
                log_info "Пользовательский шаблон: ${_custom_url}"
            else
                log_error "Нужен URL вида http(s)://..."
                return 1
            fi
            ;;
        6)
            echo ""
            echo -e "  ${DIM}Каталог с готовым сайтом на этом сервере. Можно указать и путь${NC}"
            echo -e "  ${DIM}к index.html — возьмём его папку целиком, со всеми файлами.${NC}"
            echo -e "  ${DIM}Например: /var/www/some.name.ru${NC}"
            echo -en "  ${BOLD}Путь:${NC} "
            local _local_path
            read_line _local_path
            local _resolved
            _resolved=$(_selfmask_resolve_local_site "$_local_path") || return 1
            SELFMASK_SITE_SOURCE="$_resolved"
            log_info "Свой сайт: ${_resolved}"
            log_info "Файлы копируются в ${SELFMASK_SITE_DIR} при применении"
            ;;
        *)
            SELFMASK_SITE_SOURCE="stub"
            log_info "Выбрана простая заглушка"
            ;;
    esac

    echo ""
    echo -en "  ${BOLD}Локальный backend-порт nginx [${SELFMASK_NGINX_BACKEND_PORT:-8444}]:${NC} "
    local _bp
    read_line _bp
    if [ -n "$_bp" ]; then
        validate_port "$_bp" || { log_error "Некорректный порт"; return 1; }
        SELFMASK_NGINX_BACKEND_PORT="$_bp"
    fi

    echo ""
    echo -e "  ${BOLD}Итоговые параметры:${NC}"
    echo -e "    Домен:     ${SELFMASK_DOMAIN}"
    if [ "$SELFMASK_CERT_MODE" = "selfsigned" ]; then
        echo -e "    Сертификат: самоподписанный (10 лет)"
    else
        echo -e "    Email:     ${SELFMASK_CERT_EMAIL}"
    fi
    echo -e "    Сайт:      $(_selfmask_template_label "${SELFMASK_SITE_SOURCE:-stub}")"
    echo -e "    Каталог:   ${SELFMASK_SITE_DIR}"
    echo -e "    Backend:   127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT}"
    echo -e "    TLS:       TLSv1.3 (PQ)"
    echo -e "    Порт прокси: ${PROXY_PORT:-443}"
    echo ""

    echo -en "  ${BOLD}Продолжить настройку? [Y/n]:${NC} "
    local _yn
    read_line _yn
    [[ "$_yn" =~ ^[nN] ]] && return 1

    return 0
}

_selfmask_install_deps() {
    log_info "Установка зависимостей..."

    local _missing=()

    if [ "${SELFMASK_CERT_MODE:-letsencrypt}" != "selfsigned" ]; then
        command -v certbot &>/dev/null || _missing+=("certbot")
    fi
    dpkg -s libpcre2-8-0 &>/dev/null 2>&1 || _missing+=("libpcre2-8-0")
    dpkg -s zlib1g &>/dev/null 2>&1 || _missing+=("zlib1g")
    dpkg -s ca-certificates &>/dev/null 2>&1 || _missing+=("ca-certificates")

    if [ ${#_missing[@]} -gt 0 ]; then
        _wait_apt
        apt-get update -qq || true
        apt-get install -y -qq "${_missing[@]}" || {
            log_error "Не удалось установить зависимости: ${_missing[*]}"
            return 1
        }
    fi

    log_success "Зависимости установлены"
}

_selfmask_install_pq_nginx() {
    local _prefix="${SELFMASK_PQ_PREFIX}"
    # Заглушке нужен nginx, проверке домена — openssl. Пакеты разные: системный
    # nginx бывает с OpenSSL 3.5+, когда CLI openssl ещё старый.
    local _need="${1:-nginx}"
    # force — качать нашу сборку в любом случае. Нужен, когда системного nginx
    # или уже стоящего не хватает по возможностям (например, нет stream).
    local _force="${2:-}"

    # Системный nginx с OpenSSL 3.5.0+ умеет X25519MLKEM768 сам — качать свою
    # сборку незачем. Каталоги под конфиг и логи всё равно готовим: запускаем
    # его со своим конфигом, чтобы не трогать чужой /etc/nginx.
    if [ "$_need" = "nginx" ] && [ "$_force" != "force" ] && _system_nginx_has_pq; then
        log_success "Используем $(_selfmask_nginx_source)"
        log_info "Своя сборка nginx не нужна — обновления придут из дистрибутива"
        mkdir -p /var/log/mtproxyl-nginx /var/lib/mtproxyl-nginx/{body,proxy,fastcgi} /var/lock
        mkdir -p "${_prefix}/logs" "${_prefix}/conf"
        return 0
    fi

    if [ "$_force" != "force" ] && [ -x "$(_selfmask_pq_nginx_bin)" ] && [ -x "$(_selfmask_pq_openssl_bin)" ]; then
        local _ver
        _ver=$("$(_selfmask_pq_openssl_bin)" version 2>/dev/null | awk '{print $2}')
        log_success "PQ nginx уже установлен (OpenSSL ${_ver:-?})"
        return 0
    fi

    log_info "Скачивание PQ nginx (OpenSSL ${SELFMASK_PQ_OPENSSL_VERSION} + nginx ${SELFMASK_PQ_NGINX_VERSION})..."

    # Свой конфиг откладываем до распаковки: она сносит префикс целиком и
    # приносит стоковый. Копию держим вне префикса — внутри её съест rm -rf.
    local _conf_backup="" _generated_conf
    _generated_conf="$(_selfmask_generated_pq_conf)"
    if [ -f "$_generated_conf" ] && grep -q 'mtproxyl' "$_generated_conf" 2>/dev/null; then
        _conf_backup="/tmp/.mtproxyl-nginx-conf.$$"
        cp -f "$_generated_conf" "$_conf_backup" 2>/dev/null || _conf_backup=""
    fi

    local _arch
    case "$(uname -m)" in
        x86_64|amd64) _arch="amd64" ;;
        aarch64|arm64) _arch="arm64" ;;
        *)
            log_error "Архитектура $(uname -m) не поддерживается"
            return 1
            ;;
    esac

    local _archive="mtproxyl-pq-nginx-${SELFMASK_PQ_NGINX_VERSION}-openssl${SELFMASK_PQ_OPENSSL_VERSION}-linux-${_arch}.tar.gz"
    local _url="https://github.com/${GITHUB_REPO}/releases/download/${SELFMASK_PQ_RELEASE_TAG}/${_archive}"
    local _tmp="/tmp/${_archive}"

    if ! curl -fsSL --max-time 180 "$_url" -o "$_tmp" 2>/dev/null; then
        log_error "Не удалось скачать PQ nginx"
        log_info "Проверьте Release asset: ${_url}"
        return 1
    fi

    rm -rf "$_prefix" /opt/opt/mtproxyl-nginx
    tar xzf "$_tmp" -C / || {
        log_error "Не удалось распаковать PQ nginx"
        rm -f "$_tmp"
        return 1
    }
    rm -f "$_tmp"

    # Обратная совместимость: если архив всё же был распакован в /opt/opt
    if [ ! -d "$_prefix" ] && [ -d "/opt/opt/mtproxyl-nginx" ]; then
        mkdir -p /opt
        mv /opt/opt/mtproxyl-nginx /opt/mtproxyl-nginx 2>/dev/null || true
        rmdir /opt/opt 2>/dev/null || true
    fi

    mkdir -p /var/log/mtproxyl-nginx
    mkdir -p /var/lib/mtproxyl-nginx/body
    mkdir -p /var/lib/mtproxyl-nginx/proxy
    mkdir -p /var/lib/mtproxyl-nginx/fastcgi
    mkdir -p /var/lock
    mkdir -p "${_prefix}/logs"
    mkdir -p "${_prefix}/conf"

    if [ ! -x "$(_selfmask_pq_nginx_bin)" ]; then
        log_error "После распаковки nginx-pq не найден"
        log_info "Ожидался путь: $(_selfmask_pq_nginx_bin)"
        return 1
    fi

    if [ ! -x "$(_selfmask_pq_openssl_bin)" ]; then
        log_error "После распаковки openssl-pq не найден"
        return 1
    fi

    local _ver
    _ver=$("$(_selfmask_pq_openssl_bin)" version 2>/dev/null | awk '{print $2}')
    log_success "PQ nginx установлен (OpenSSL ${_ver:-?})"

    # Архив разворачивается поверх префикса и приносит свой conf/nginx.conf.
    # Настроенный при этом теряется, а с ним и публичный порт — возвращаем.
    if [ -n "$_conf_backup" ] && [ -f "$_conf_backup" ]; then
        mv -f "$_conf_backup" "$_generated_conf" 2>/dev/null || true
        log_info "Настроенный конфиг nginx возвращён на место"
    fi
}

_selfmask_install_pq_service() {
    local _conf="${1:-$(_selfmask_pq_conf)}" _nginx_bin
    _nginx_bin="$(_selfmask_nginx_bin_for_conf "$_conf")"
    cat > "/etc/systemd/system/${SELFMASK_PQ_SERVICE}" << EOF
[Unit]
Description=MTProxyL PQ nginx for selfmask
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${_nginx_bin} -t -c ${_conf}
ExecStart=${_nginx_bin} -c ${_conf} -g 'daemon off;'
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=/bin/kill -QUIT \$MAINPID
Restart=on-failure
RestartSec=3
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SELFMASK_PQ_SERVICE}" &>/dev/null || true
}

SELFMASK_SYSTEM_NGINX_WAS_ACTIVE="false"
SELFMASK_PANEL_WAS_ACTIVE="false"

_selfmask_stop_own_nginx() {
    if systemctl is-active "${SELFMASK_PQ_SERVICE}" &>/dev/null 2>&1; then
        log_info "Останавливаем предыдущий экземпляр PQ nginx"
        systemctl stop "${SELFMASK_PQ_SERVICE}" &>/dev/null || true
    fi

    # На всякий случай убиваем только наш nginx
    pkill -f "${SELFMASK_PQ_PREFIX}/sbin/nginx" 2>/dev/null || true
}

_selfmask_free_ports() {
    # 1. Останавливаем наш PQ nginx если он уже запущен
    _selfmask_stop_own_nginx

    # Самоподписанному сертификату порт 80 не нужен: ACME не используется,
    # а mask-backend слушает только 127.0.0.1:<backend>. Не трогаем чужой
    # nginx/панель на 80 порту.
    if [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "selfsigned" ]; then
        return 0
    fi

    # 2. Проверяем занят ли порт 80 кем-то ещё.
    # Вывод в переменную, а не пайп в grep -q: grep закрывает пайп, источник
    # ловит SIGPIPE и под pipefail пайплайн ненулевой при найденном совпадении.
    local _port80_busy="false"
    local _listen_out=""
    if command -v ss &>/dev/null; then
        _listen_out=$(ss -tln 2>/dev/null)
    elif command -v netstat &>/dev/null; then
        _listen_out=$(netstat -tln 2>/dev/null)
    fi
    printf '%s\n' "$_listen_out" | awk '{print $4}' | grep -qE '(^|:|])80$' && _port80_busy="true"

    # Если порт 80 свободен — отлично
    [ "$_port80_busy" != "true" ] && return 0

    # 3. Если активен системный nginx — спрашиваем пользователя
    local _unit_files; _unit_files=$(systemctl list-unit-files 2>/dev/null)
    if printf '%s\n' "$_unit_files" | grep -q '^nginx\.service' && systemctl is-active nginx &>/dev/null 2>&1; then
        echo ""
        log_warn "Обнаружен системный nginx, который использует порт 80"
        echo -e "  ${DIM}Selfmask требует порт 80 для Let's Encrypt и http→https redirect.${NC}"
        echo -e "  ${DIM}Если остановить системный nginx, его сайты/панели временно станут недоступны.${NC}"
        echo ""
        echo -en "  ${BOLD}Временно остановить системный nginx? [y/N]:${NC} "
        local _yn
        read_line _yn
        if [[ "$_yn" =~ ^[yY] ]]; then
            SELFMASK_SYSTEM_NGINX_WAS_ACTIVE="true"
            systemctl stop nginx &>/dev/null || {
                log_error "Не удалось остановить системный nginx"
                return 1
            }
            log_info "Системный nginx временно остановлен"
            return 0
        else
            log_error "Настройка selfmask отменена: порт 80 занят системным nginx"
            return 1
        fi
    fi

    # 4. Веб-панель держит порт 80 постоянно ради своего Let's Encrypt.
    # Тот же вопрос, что для системного nginx.
    if printf '%s\n' "$_unit_files" | grep -q '^mtproxyl-panel\.service' && systemctl is-active mtproxyl-panel &>/dev/null 2>&1; then
        # Под ASSUME_YES эту команду зовёт сама панель: остановив её, systemd
        # убьёт и наш процесс — она останется выключенной. Отказываем явно.
        if [ "${MTPROXYL_ASSUME_YES:-}" = "1" ]; then
            log_error "Порт 80 занят веб-панелью MTProxyL-Panel — не могу остановить её автоматически"
            log_info "Остановите панель вручную (sudo systemctl stop mtproxyl-panel), повторите"
            log_info "selfmask apply, затем запустите панель обратно (sudo systemctl start mtproxyl-panel)"
            return 1
        fi
        echo ""
        log_warn "Порт 80 занят веб-панелью MTProxyL-Panel (её собственный Let's Encrypt)"
        echo -e "  ${DIM}Selfmask требует порт 80 для своего Let's Encrypt и http→https redirect.${NC}"
        echo -e "  ${DIM}Панель будет недоступна на несколько секунд, пока сертификат не выпущен.${NC}"
        echo ""
        echo -en "  ${BOLD}Временно остановить панель? [y/N]:${NC} "
        local _yn
        read_line _yn
        if [[ "$_yn" =~ ^[yY] ]]; then
            SELFMASK_PANEL_WAS_ACTIVE="true"
            systemctl stop mtproxyl-panel &>/dev/null || {
                log_error "Не удалось остановить mtproxyl-panel"
                return 1
            }
            log_info "Панель временно остановлена"
            return 0
        else
            log_error "Настройка selfmask отменена: порт 80 занят панелью"
            return 1
        fi
    fi

    # 5. Если занят чем-то ещё — просто сообщаем
    log_error "Порт 80 уже занят другим процессом"
    log_info "Освободите порт 80 и повторите настройку selfmask"
    return 1
}

_selfmask_restore_port80_holders() {
    if [ "${SELFMASK_SYSTEM_NGINX_WAS_ACTIVE:-false}" = "true" ]; then
        log_info "Возвращаем системный nginx в исходное состояние..."
        systemctl start nginx &>/dev/null || log_warn "Не удалось снова запустить системный nginx"
        SELFMASK_SYSTEM_NGINX_WAS_ACTIVE="false"
    fi
    if [ "${SELFMASK_PANEL_WAS_ACTIVE:-false}" = "true" ]; then
        log_info "Возвращаем веб-панель в исходное состояние..."
        systemctl start mtproxyl-panel &>/dev/null || log_warn "Не удалось снова запустить mtproxyl-panel"
        SELFMASK_PANEL_WAS_ACTIVE="false"
    fi
}

_selfmask_deploy_site() {
    log_info "Развёртывание сайта-маски..."

    mkdir -p "$SELFMASK_SITE_DIR"

    local _src="${SELFMASK_SITE_SOURCE:-stub}"
    local _templates_base="${GITHUB_RAW}/templates_html"

    case "$_src" in
        stub)
            _selfmask_download_builtin_template "${_templates_base}/stub.html" || _selfmask_fallback_stub
            ;;
        filemanager)
            _selfmask_download_builtin_template "${_templates_base}/filemanager.html" || _selfmask_fallback_stub
            ;;
        catrunner)
            _selfmask_download_builtin_template "${_templates_base}/catrunner.html" || _selfmask_fallback_stub
            ;;
        mekorunner)
            _selfmask_download_builtin_template "${_templates_base}/mekorunner.html" || _selfmask_fallback_stub
            ;;
        http*)
            _selfmask_download_template "$_src" || _selfmask_fallback_stub
            ;;
        /*)
            _selfmask_copy_local_site "$_src" || _selfmask_fallback_stub
            ;;
    esac

    chown -R www-data:www-data "$SELFMASK_SITE_DIR" 2>/dev/null || true
    chmod -R 755 "$SELFMASK_SITE_DIR" 2>/dev/null || true
}

_selfmask_download_builtin_template() {
    _selfmask_download_template "$1" || return 1
    rm -f "${SELFMASK_SITE_DIR}/mtproxyl-decoy.css" "${SELFMASK_SITE_DIR}/mtproxyl-decoy.js"
    _selfmask_externalize_inline_assets
}

_selfmask_externalize_tag() {
    local _html="$1" _tag="$2" _asset="$3" _replacement="$4" _counts _tmp _asset_tmp

    _counts=$(awk -v tag="$_tag" '
        BEGIN { open_re = "<" tag "[[:space:]]*>"; close_re = "</" tag "[[:space:]]*>" }
        {
            line = tolower($0)
            while (match(line, open_re)) { opens++; line = substr(line, RSTART + RLENGTH) }
            line = tolower($0)
            while (match(line, close_re)) { closes++; line = substr(line, RSTART + RLENGTH) }
        }
        END { print opens + 0 ":" closes + 0 }
    ' "$_html") || return 1
    [ "$_counts" = "1:1" ] || return 0

    _tmp=$(_mktemp "$SELFMASK_SITE_DIR") || return 1
    _asset_tmp=$(_mktemp "$SELFMASK_SITE_DIR") || { rm -f "$_tmp"; return 1; }
    if ! awk -v tag="$_tag" -v asset="$_asset_tmp" -v replacement="$_replacement" '
        BEGIN { open_re = "<" tag "[[:space:]]*>"; close_re = "</" tag "[[:space:]]*>" }
        {
            line = $0
            out = ""
            while (1) {
                if (!inside) {
                    if (match(tolower(line), open_re)) {
                        out = out substr(line, 1, RSTART - 1) replacement
                        line = substr(line, RSTART + RLENGTH)
                        inside = 1
                        continue
                    }
                    out = out line
                    break
                }
                if (match(tolower(line), close_re)) {
                    print substr(line, 1, RSTART - 1) >> asset
                    line = substr(line, RSTART + RLENGTH)
                    inside = 0
                    continue
                }
                print line >> asset
                break
            }
            print out
        }
        END { if (inside) exit 1 }
    ' "$_html" > "$_tmp"; then
        rm -f "$_tmp" "$_asset_tmp"
        return 1
    fi

    mv "$_asset_tmp" "$_asset" || { rm -f "$_tmp" "$_asset_tmp"; return 1; }
    mv "$_tmp" "$_html" || return 1
}

_selfmask_has_inline_assets() {
    awk '
        {
            line = tolower($0)
            if (line ~ /<style([[:space:]>])/) found = 1
            while (match(line, /<script[^>]*>/)) {
                tag = substr(line, RSTART, RLENGTH)
                if (tag !~ /[[:space:]]src[[:space:]]*=/) found = 1
                line = substr(line, RSTART + RLENGTH)
            }
        }
        END { exit found ? 0 : 1 }
    ' "$1"
}

_selfmask_externalize_inline_assets() {
    local _prefix="${1:-mtproxyl-decoy}"
    local _html="${SELFMASK_SITE_DIR}/index.html" _tmp _legacy_login="false" _script_tag
    [ -f "$_html" ] || return 1

    if [ "$_prefix" = "mtproxyl-decoy" ] && grep -q 'onsubmit="return tryLogin()"' "$_html"; then
        _legacy_login="true"
        _tmp=$(_mktemp "$SELFMASK_SITE_DIR") || return 1
        awk '{gsub(/ onsubmit="return tryLogin\(\)"/, ""); print}' "$_html" > "$_tmp"
        mv "$_tmp" "$_html"
    fi

    _selfmask_externalize_tag \
        "$_html" style "${SELFMASK_SITE_DIR}/${_prefix}.css" \
        "<link rel=\"stylesheet\" href=\"/${_prefix}.css\">" || return 1

    _script_tag="<script src=\"/${_prefix}.js\"></script>"
    [ "$_prefix" != "mtproxyl-decoy" ] || \
        _script_tag="<script src=\"/${_prefix}.js\" defer></script>"
    _selfmask_externalize_tag \
        "$_html" script "${SELFMASK_SITE_DIR}/${_prefix}.js" "$_script_tag" || return 1

    if [ "$_legacy_login" = "true" ] && [ -f "${SELFMASK_SITE_DIR}/${_prefix}.js" ]; then
        cat >> "${SELFMASK_SITE_DIR}/${_prefix}.js" <<'JS_EOF'
document.getElementById('lf').addEventListener('submit',function(e){
  e.preventDefault();
  tryLogin();
});
JS_EOF
    fi

    chmod 644 "$_html" 2>/dev/null || return 1
    [ ! -f "${SELFMASK_SITE_DIR}/${_prefix}.css" ] || \
        chmod 644 "${SELFMASK_SITE_DIR}/${_prefix}.css" 2>/dev/null || return 1
    [ ! -f "${SELFMASK_SITE_DIR}/${_prefix}.js" ] || \
        chmod 644 "${SELFMASK_SITE_DIR}/${_prefix}.js" 2>/dev/null || return 1
}

selfmask_prepare_web_decoy() {
    [ "${WEB_DECOY_MODE:-static_directory}" = "static_directory" ] || return 0
    local _prefix="mtproxyl-web-inline"
    case "${SELFMASK_SITE_SOURCE:-stub}" in
        stub|filemanager|catrunner|mekorunner) _prefix="mtproxyl-decoy" ;;
    esac
    _selfmask_externalize_inline_assets "$_prefix" || return 1
    if [ "$_prefix" = "mtproxyl-web-inline" ] && \
        _selfmask_has_inline_assets "${SELFMASK_SITE_DIR}/index.html"; then
        log_warn "WEB: в пользовательской заглушке остался inline CSS или JavaScript"
        log_info "Вынесите сложные inline-блоки в отдельные локальные .css/.js файлы"
    fi
}

_selfmask_download_template() {
    local _url="$1"
    log_info "Скачивание шаблона: ${_url}"
    if curl -fsSL --max-time 15 "$_url" -o "${SELFMASK_SITE_DIR}/index.html" 2>/dev/null; then
        log_success "Шаблон установлен"
        return 0
    else
        log_warn "Не удалось скачать шаблон"
        return 1
    fi
}

_selfmask_fallback_stub() {
    log_info "Создаём встроенную заглушку..."
    rm -f "${SELFMASK_SITE_DIR}/mtproxyl-decoy.css" "${SELFMASK_SITE_DIR}/mtproxyl-decoy.js"
    cat > "${SELFMASK_SITE_DIR}/index.html" << 'HTML_EOF'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Добро пожаловать</title>
<style>
  body{font-family:system-ui,-apple-system,sans-serif;max-width:680px;margin:80px auto;padding:0 20px;color:#333;background:#fafafa}
  h1{font-size:1.6rem;color:#111}
  p{color:#666;line-height:1.6}
  .footer{margin-top:60px;font-size:.85rem;color:#aaa}
</style>
</head>
<body>
  <h1>Сайт временно недоступен</h1>
  <p>Ведутся технические работы. Пожалуйста, зайдите позже.</p>
  <p class="footer">&copy; 2026</p>
</body>
</html>
HTML_EOF
    _selfmask_externalize_inline_assets || return 1
    log_success "Встроенная заглушка создана"
}

_selfmask_open_public_ports() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 80/tcp &>/dev/null || true
        ufw allow 443/tcp &>/dev/null || true
        log_info "UFW: открыты 80 и 443"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=80/tcp &>/dev/null || true
        firewall-cmd --permanent --add-port=443/tcp &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
        log_info "firewalld: открыты 80 и 443"
    elif command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
        iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
        log_info "iptables: открыты 80 и 443"
    fi
}

# Годен ли лежащий сертификат: оба файла, наш домен, больше 30 дней до
# истечения. Наличия fullchain.pem мало — просроченный файл никуда не девается.
# Доменов может быть несколько: при включённом WEB его имя лежит в том же
# сертификате отдельным SAN, и без него ветка WEB отдавала бы чужое имя.
_selfmask_cert_is_valid() {
    local _dir="$1"; shift
    [ -f "${_dir}/fullchain.pem" ] && [ -f "${_dir}/privkey.pem" ] || return 1

    # Проверить нечем — считаем годным: своей проверкой мы бы только выбросили
    # рабочий сертификат и упёрлись в недельный лимит Let's Encrypt.
    command -v openssl &>/dev/null || return 0

    openssl x509 -in "${_dir}/fullchain.pem" -noout -checkend 2592000 &>/dev/null || return 1

    local _sans _d
    _sans=$(openssl x509 -in "${_dir}/fullchain.pem" -noout -text 2>/dev/null \
        | grep -oE 'DNS:[^,[:space:]]+' | cut -d: -f2)
    # Домен сверяем по SAN точным совпадением: grep по строке с доменом принял
    # бы и чужой сертификат, где наш домен — лишь часть другого имени.
    for _d in "$@"; do
        [ -n "$_d" ] || continue
        printf '%s\n' "$_sans" | grep -Fxq "$_d" || return 1
    done
    return 0
}

# Под словом «лимит» у Let's Encrypt прячутся разные вещи с разными причинами и
# разными способами обойти. Раньше мы называли один и тот же — «5 сертификатов на
# набор доменов» — и уверяли, что с DNS всё хорошо; при упёршейся проверке домена
# это было прямой ложью. Теперь разбираем, что именно ответил сервер, и в любом
# случае показываем его собственный текст.
_selfmask_explain_cert_error() {
    local _out="$1" _retry _bucket

    _retry=$(printf '%s\n' "$_out" | grep -oE 'retry after [0-9T:-]+( [0-9:]+)?( UTC)?' | head -1)

    case "$_out" in
        *"too many failed authorizations"*|*"too many failed validations"*)
            log_error "Слишком много неудачных проверок домена подряд"
            log_info "Это следствие, а не причина: Let's Encrypt не смог подтвердить домен"
            log_info "и временно перестал принимать попытки. Проверьте A-запись и порт 80,"
            log_info "иначе следующая попытка упрётся в то же самое"
            ;;
        *"exact set of domains"*|*"too many duplicate certificates"*)
            log_error "Уже выдано 5 одинаковых сертификатов на этот же набор доменов за 168 часов"
            log_info "С DNS и портом 80 всё в порядке — упёрлись именно в повторные выпуски"
            ;;
        *"too many certificates"*|*"too many new certificates"*)
            # Лимит считается по регистрируемому домену, и сервер сам его называет.
            _bucket=$(printf '%s\n' "$_out" | grep -oE 'already issued for(:| )+"?[A-Za-z0-9.*-]+' | head -1 | grep -oE '[A-Za-z0-9.*-]+$')
            log_error "Достигнут лимит сертификатов${_bucket:+ по домену ${_bucket}}"
            log_info "Лимит считается по регистрируемому домену, а не по вашему поддомену."
            if [ -n "$_bucket" ] && [ "$_bucket" != "$SELFMASK_DOMAIN" ]; then
                log_warn "Похоже, ${_bucket} — сервис чужих поддоменов: квоту расходуете не только вы"
                log_info "Свой домен решает это насовсем, у него будет отдельная квота"
            fi
            ;;
        *rateLimited*|*"rate limit"*)
            log_error "Let's Encrypt ограничил выпуск — точную причину он назвал ниже"
            ;;
        *)
            log_info "Проверьте DNS домена и доступность порта 80 извне"
            ;;
    esac

    [ -n "$_retry" ] && log_info "Повторить можно после: ${_retry#retry after }"
    log_info "Не дожидаясь: mtproxyl selfmask set SELFMASK_CERT_MODE selfsigned, затем selfmask apply"

    # Текст сервера показываем всегда: наша расшифровка может не угадать, а он
    # называет и лимит, и домен, по которому тот считается.
    echo ""
    log_info "Ответ Let's Encrypt:"
    printf '%s\n' "$_out" | grep -iE 'error|limit|detail|problem|urn:ietf' | tail -6 | sed 's/^/    /'
    [ -f /var/log/letsencrypt/letsencrypt.log ] && \
        log_info "Полный лог: /var/log/letsencrypt/letsencrypt.log"
    return 0
}

# Отдельный сертификат только на WEB-домен, своим cert-name. Нужен, когда общий
# набор отвергнут из-за домена маскировки: у другого домена своя квота, и WEB
# поднимется, даже пока Selfmask ждёт.
_selfmask_obtain_web_cert() {
    local _wd _dir
    web_is_enabled 2>/dev/null || return 1
    _wd=$(web_domain 2>/dev/null) || return 1
    [ -n "$_wd" ] && [ "$_wd" != "$SELFMASK_DOMAIN" ] || return 1

    _dir=$(web_own_cert_dir) || return 1
    if _selfmask_cert_is_valid "$_dir" "$_wd"; then
        log_success "У WEB уже есть свой сертификат на ${_wd}"
        return 0
    fi

    log_info "Пробуем отдельный сертификат только на ${_wd}..."
    local -a _mail2=(--register-unsafely-without-email)
    [ -n "${SELFMASK_CERT_EMAIL:-}" ] && _mail2=(-m "$SELFMASK_CERT_EMAIL")

    local _out
    if _out=$(certbot certonly --webroot -w "$SELFMASK_SITE_DIR" \
        -d "$_wd" --non-interactive --agree-tos \
        "${_mail2[@]}" --cert-name "$_wd" 2>&1); then
        log_success "Сертификат для ${_wd} получен"
        return 0
    fi
    log_warn "Отдельный сертификат для ${_wd} тоже не вышел"
    _selfmask_explain_cert_error "$_out"
    return 1
}

_selfmask_obtain_cert() {
    log_info "Получение сертификата Let's Encrypt..."

    local _cert_dir; _cert_dir="$(_selfmask_cert_dir)"
    local -a _need=("$SELFMASK_DOMAIN")
    # Если WEB уже обзавёлся своим сертификатом, требовать его имя от общего
    # незачем — иначе мы бы выпускали общий заново на каждом применении.
    if web_is_enabled 2>/dev/null && ! web_has_own_cert 2>/dev/null; then
        local _wd; _wd=$(web_domain 2>/dev/null)
        [ -n "$_wd" ] && [ "$_wd" != "$SELFMASK_DOMAIN" ] && _need+=("$_wd")
    fi
    if _selfmask_cert_is_valid "$_cert_dir" "${_need[@]}"; then
        local _until
        _until=$(openssl x509 -in "${_cert_dir}/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
        log_success "Сертификат для ${SELFMASK_DOMAIN} уже есть в системе — используем его"
        [ -n "$_until" ] && log_info "Действителен до: ${_until}"
        log_info "Порт 80 не понадобится: выпускать нечего"
        return 0
    fi

    # Файлы есть, но не годятся — так бывает после смены домена или когда
    # сертификат успел истечь. Выпускаем заново, но говорим почему.
    if [ -f "${_cert_dir}/fullchain.pem" ]; then
        log_warn "Найден сертификат, но он истёк или выдан на другой домен — выпускаем заново"
    fi

    mkdir -p "${SELFMASK_SITE_DIR}/.well-known/acme-challenge"
    mkdir -p "${SELFMASK_PQ_PREFIX}/conf"

    local _mime; _mime=$(_selfmask_nginx_mime_block)

    local _acme_conf
    _acme_conf="$(_selfmask_generated_pq_conf)"
    cat > "$_acme_conf" << EOF
worker_processes auto;

events {
    worker_connections 1024;
}

http {
${_mime}
    server {
        listen 80;
        server_name ${SELFMASK_DOMAIN};
        root ${SELFMASK_SITE_DIR};

        location /.well-known/acme-challenge/ {
            root ${SELFMASK_SITE_DIR};
            allow all;
        }

        location / {
            return 200 'ok';
            add_header Content-Type text/plain;
        }
    }
}
EOF

    _selfmask_open_public_ports
    _selfmask_install_pq_service "$_acme_conf"
    _selfmask_free_ports || { _selfmask_restore_custom_service || true; return 1; }

    mkdir -p /var/lib/mtproxyl-nginx/body
    mkdir -p /var/lib/mtproxyl-nginx/proxy
    mkdir -p /var/lib/mtproxyl-nginx/fastcgi
    mkdir -p /var/log/mtproxyl-nginx
    mkdir -p /var/lock
    rm -f /run/mtproxyl-nginx.pid 2>/dev/null || true

    local _test_out=""
    _test_out=$("$(_selfmask_nginx_bin)" -t -c "$_acme_conf" 2>&1) || {
        log_error "Ошибка временного конфига PQ nginx для ACME"
        echo "$_test_out" | sed 's/^/    /'
        _selfmask_restore_custom_service || true
        return 1
    }
    
    systemctl restart "${SELFMASK_PQ_SERVICE}" &>/dev/null || {
        log_error "Не удалось запустить PQ nginx"
        _selfmask_restore_custom_service || true
        return 1
    }

    # Почта необязательна: без неё certbot регистрируется анонимно, только
    # писем об истечении не будет. Пустое -m он не принимает вовсе.
    local -a _mail_args=(--register-unsafely-without-email)
    [ -n "${SELFMASK_CERT_EMAIL:-}" ] && _mail_args=(-m "$SELFMASK_CERT_EMAIL")

    # Вывод certbot нужен целиком: без него причина отказа терялась, и любая
    # неудача выглядела как проблема с DNS или портом 80.
    # WEB-домен идёт в тот же сертификат отдельным SAN: --cert-name не меняем,
    # поэтому пути в конфиге nginx остаются прежними.
    local -a _domain_args=(-d "$SELFMASK_DOMAIN")
    if web_is_enabled 2>/dev/null; then
        local _wd; _wd=$(web_domain 2>/dev/null)
        [ -n "$_wd" ] && [ "$_wd" != "$SELFMASK_DOMAIN" ] && _domain_args+=(-d "$_wd")
    fi

    local _cb_out
    if _cb_out=$(certbot certonly --webroot -w "$SELFMASK_SITE_DIR" \
        "${_domain_args[@]}" \
        --non-interactive --agree-tos \
        "${_mail_args[@]}" \
        --cert-name "$SELFMASK_DOMAIN" 2>&1); then
        log_success "Сертификат получен"
        _selfmask_restore_custom_service || true
        return 0
    fi

    # Общий сертификат не вышел. Если в наборе был ещё и WEB-домен, пробуем
    # выпустить ему отдельный: чаще всего упирается именно домен маскировки —
    # он идёт в каждом запросе, — и тогда развязка спасает WEB целиком.
    if [ "${#_domain_args[@]}" -gt 2 ] && _selfmask_obtain_web_cert; then
        log_warn "Общий сертификат выпустить не удалось, но у WEB теперь свой"
        log_info "Причина отказа по общему набору:"
        _selfmask_explain_cert_error "$_cb_out"
        _selfmask_restore_custom_service || true
        return 0
    fi

    log_error "Не удалось получить сертификат"
    _selfmask_explain_cert_error "$_cb_out"
    _selfmask_restore_custom_service || true
    return 1
}

_selfmask_restore_custom_service() {
    nginx_custom_active || return 0
    "$(_selfmask_nginx_bin_for_conf "$NGINX_CUSTOM_FILE")" -t -c "$NGINX_CUSTOM_FILE" &>/dev/null || return 1
    _selfmask_install_pq_service "$NGINX_CUSTOM_FILE"
    systemctl restart "${SELFMASK_PQ_SERVICE}" &>/dev/null
}

_selfmask_activate_nginx_conf() {
    local _conf="$1" _test_out="" _nginx_bin
    [ -f "$_conf" ] || { log_error "Конфиг nginx не найден: ${_conf}"; return 1; }
    _nginx_bin="$(_selfmask_nginx_bin_for_conf "$_conf")"

    _test_out=$("$_nginx_bin" -t -c "$_conf" 2>&1) || {
        log_error "Ошибка конфига nginx"
        echo "$_test_out" | sed 's/^/    /'
        return 1
    }

    _selfmask_install_pq_service "$_conf"
    _selfmask_free_ports || { _selfmask_restore_port80_holders; return 1; }

    mkdir -p /var/lib/mtproxyl-nginx/{body,proxy,fastcgi}
    mkdir -p /var/log/mtproxyl-nginx /var/lock
    rm -f /run/mtproxyl-nginx.pid 2>/dev/null || true

    systemctl restart "${SELFMASK_PQ_SERVICE}" &>/dev/null || {
        log_error "Не удалось перезапустить PQ nginx"
        journalctl -u "${SELFMASK_PQ_SERVICE}" -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
        _selfmask_restore_port80_holders
        return 1
    }
}

_selfmask_configure_nginx() {
    log_info "Настройка PQ nginx..."

    local _cert_dir
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] || [ "${SELFMASK_CONFIGURE_ACTIVE:-false}" = "true" ]; then
        _cert_dir="$(_selfmask_cert_dir)"
    else
        _cert_dir="$(web_cert_dir 2>/dev/null)"
    fi
    [ -f "${_cert_dir}/fullchain.pem" ] || { log_error "Сертификат не найден"; return 1; }

    mkdir -p "${SELFMASK_PQ_PREFIX}/conf"

    if [ "${NGINX_CUSTOM_ENABLED:-false}" = "true" ]; then
        [ -f "$NGINX_CUSTOM_FILE" ] || {
            log_error "Пользовательский конфиг nginx не найден: ${NGINX_CUSTOM_FILE}"
            return 1
        }
        _selfmask_activate_nginx_conf "$NGINX_CUSTOM_FILE" || return 1
        log_success "PQ nginx настроен (пользовательский конфиг)"
        return 0
    fi

    # Блоки на порту 80 (ACME-challenge + http→https redirect) нужны только
    # для Let's Encrypt. При самоподписанном сертификате домена в DNS нет,
    # ACME не используется, и занимать общий порт 80 незачем.
    local _http80="" _frontend_domain="${SELFMASK_DOMAIN}"
    if [ "${SELFMASK_ENABLED:-false}" != "true" ] && [ "${SELFMASK_CONFIGURE_ACTIVE:-false}" != "true" ]; then
        _frontend_domain=$(web_domain 2>/dev/null)
    fi
    if [ "${SELFMASK_CERT_MODE:-letsencrypt}" != "selfsigned" ]; then
        _http80=$(cat << EOF
    server {
        listen 80 default_server;
        server_name _;

        # HTTP-01 для любого домена, смотрящего на этот сервер: порт 80 занят
        # нами постоянно, иначе сертификат для панели не выпустить.
        location /.well-known/acme-challenge/ {
            root ${SELFMASK_SITE_DIR};
            allow all;
        }

        location / {
            return 444;
        }
    }

    server {
        listen 80;
        server_name ${_frontend_domain};
        root ${SELFMASK_SITE_DIR};

        location /.well-known/acme-challenge/ {
            root ${SELFMASK_SITE_DIR};
            allow all;
        }

        location / {
            return 301 https://${_frontend_domain}\$request_uri;
        }
    }
EOF
)
    fi

    # WEB Proxy: публичный порт забирает nginx и разводит по SNI, движок
    # уходит на loopback. Без WEB конфиг остаётся прежним.
    local _mime; _mime=$(_selfmask_nginx_mime_block)

    local _web_stream="" _web_map="" _web_server=""
    if web_is_enabled 2>/dev/null; then
        _web_stream=$(web_nginx_stream_block) || {
            log_error "Не удалось собрать stream-блок WEB"; return 1; }
        _web_map=$(web_nginx_upgrade_map)
        _web_server=$(web_nginx_http_server "$_cert_dir") || return 1
    fi

    local _selfmask_servers=""
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] || [ "${SELFMASK_CONFIGURE_ACTIVE:-false}" = "true" ]; then
        _selfmask_servers=$(cat << EOF
    server {
        listen 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT} ssl default_server;
        server_name _;

        ssl_protocols TLSv1.3;
        ssl_ecdh_curve X25519MLKEM768:X25519:prime256v1;
        ssl_prefer_server_ciphers on;

        ssl_certificate     ${_cert_dir}/fullchain.pem;
        ssl_certificate_key ${_cert_dir}/privkey.pem;

        return 444;
    }

    server {
        listen 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT} ssl;
        server_name ${SELFMASK_DOMAIN};
        server_tokens off;

        ssl_protocols TLSv1.3;
        ssl_ecdh_curve X25519MLKEM768:X25519:prime256v1;
        ssl_prefer_server_ciphers on;

        ssl_certificate     ${_cert_dir}/fullchain.pem;
        ssl_certificate_key ${_cert_dir}/privkey.pem;

        root ${SELFMASK_SITE_DIR};
        index index.html index.htm;

        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options SAMEORIGIN always;
        add_header Referrer-Policy no-referrer always;

        location ~* "(wget|curl|chmod|/tmp/|eval\\(|base64)" {
            return 403;
        }

        location / {
            try_files \$uri \$uri/ =404;
        }
    }
EOF
)
    fi

    local _generated_conf
    _generated_conf="$(_selfmask_generated_pq_conf)"
    cat > "$_generated_conf" << EOF
worker_processes auto;

events {
    worker_connections 1024;
}

${_web_stream}
http {
${_mime}
${_web_map}
${_http80}
${_selfmask_servers}
${_web_server}
}
EOF

    _selfmask_activate_nginx_conf "$_generated_conf" || return 1
    log_success "PQ nginx настроен"
}

# Запомнить то, что Selfmask сейчас перепишет. Снимок делается один раз,
# иначе повторное применение запишет в «прежние» его же значения.
_selfmask_snapshot_manager_settings() {
    [ "${SELFMASK_PREV_SAVED:-false}" = "true" ] && return 0
    SELFMASK_PREV_DOMAIN="${PROXY_DOMAIN:-}"
    SELFMASK_PREV_MASKING_ENABLED="${MASKING_ENABLED:-}"
    SELFMASK_PREV_MASK_HOST="${MASKING_HOST:-}"
    SELFMASK_PREV_MASK_PORT="${MASKING_PORT:-}"
    SELFMASK_PREV_UNKNOWN_SNI="${UNKNOWN_SNI_ACTION:-}"
    SELFMASK_PREV_FAKE_CERT_LEN="${FAKE_CERT_LEN:-}"
    SELFMASK_PREV_SAVED="true"
}

# Вернуть настройки менеджера к состоянию до Selfmask.
# Возвращает 1, если снимка нет (selfmask включали ещё старой версией).
_selfmask_restore_manager_settings() {
    [ "${SELFMASK_PREV_SAVED:-false}" = "true" ] || return 1

    local _was_domain="${SELFMASK_PREV_DOMAIN}"
    PROXY_DOMAIN="${SELFMASK_PREV_DOMAIN}"
    MASKING_ENABLED="${SELFMASK_PREV_MASKING_ENABLED:-true}"
    MASKING_HOST="${SELFMASK_PREV_MASK_HOST}"
    MASKING_PORT="${SELFMASK_PREV_MASK_PORT:-443}"
    UNKNOWN_SNI_ACTION="${SELFMASK_PREV_UNKNOWN_SNI:-mask}"
    [ -n "${SELFMASK_PREV_FAKE_CERT_LEN}" ] && FAKE_CERT_LEN="${SELFMASK_PREV_FAKE_CERT_LEN}"

    SELFMASK_PREV_SAVED="false"
    SELFMASK_PREV_DOMAIN=""
    SELFMASK_PREV_MASK_HOST=""
    SELFMASK_PREV_MASK_PORT=""
    SELFMASK_PREV_UNKNOWN_SNI=""
    SELFMASK_PREV_MASKING_ENABLED=""
    SELFMASK_PREV_FAKE_CERT_LEN=""

    log_success "Возвращены настройки, которые были до Selfmask"
    [ -n "$_was_domain" ] && log_info "Fake SNI: ${_was_domain}"
    log_info "Backend маскировки: ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT}"
    return 0
}

# Снимок [censorship]/[general.links] цели перед тем, как их перепишет Selfmask.
_selfmask_snapshot_target_settings() {
    [ "${SELFMASK_PREV_SAVED:-false}" = "true" ] && return 0
    local _cfg="${DETECTED_CONFIG_PATH:-}"
    [ -f "$_cfg" ] || return 1
    SELFMASK_PREV_DOMAIN=$(_toml_get_string_in_section "censorship" "tls_domain" "$_cfg" 2>/dev/null)
    SELFMASK_PREV_MASK_HOST=$(_toml_get_string_in_section "censorship" "mask_host" "$_cfg" 2>/dev/null)
    SELFMASK_PREV_MASK_PORT=$(_toml_get_string_in_section "censorship" "mask_port" "$_cfg" 2>/dev/null)
    SELFMASK_PREV_UNKNOWN_SNI=$(_toml_get_string_in_section "censorship" "unknown_sni_action" "$_cfg" 2>/dev/null)
    SELFMASK_PREV_PUBLIC_HOST=$(_toml_get_string_in_section "general.links" "public_host" "$_cfg" 2>/dev/null)
    SELFMASK_PREV_SAVED="true"
    return 0
}

# Вернуть конфиг цели к состоянию до Selfmask. Возвращаем только те ключи,
# что реально стояли: у отсутствовавших прежний вид — отсутствие.
_selfmask_restore_target_settings() {
    [ "${SELFMASK_PREV_SAVED:-false}" = "true" ] || return 1
    if [ -z "${DETECTED_CONFIG_PATH:-}" ] || [ ! -f "${DETECTED_CONFIG_PATH:-}" ]; then
        log_warn "Конфиг цели не найден — вернуть прежние параметры автоматически не получится"
        return 1
    fi

    local _ok=true _touched=false _skipped=""
    _selfmask_restore_target_key() {
        local _key="$1" _val="$2" _section="$3"
        if [ -z "$_val" ]; then
            _skipped+="${_skipped:+, }${_key}"
            return 0
        fi
        apply_target_tuning "$_key" "$_val" "$_section" true || _ok=false
        _touched=true
    }

    _selfmask_restore_target_key "tls_domain" "${SELFMASK_PREV_DOMAIN}" "censorship"
    _selfmask_restore_target_key "mask_host" "${SELFMASK_PREV_MASK_HOST}" "censorship"
    _selfmask_restore_target_key "mask_port" "${SELFMASK_PREV_MASK_PORT}" "censorship"
    _selfmask_restore_target_key "unknown_sni_action" "${SELFMASK_PREV_UNKNOWN_SNI}" "censorship"
    _selfmask_restore_target_key "public_host" "${SELFMASK_PREV_PUBLIC_HOST}" "general.links"
    unset -f _selfmask_restore_target_key

    SELFMASK_PREV_SAVED="false"
    SELFMASK_PREV_DOMAIN=""
    SELFMASK_PREV_MASK_HOST=""
    SELFMASK_PREV_MASK_PORT=""
    SELFMASK_PREV_UNKNOWN_SNI=""
    SELFMASK_PREV_PUBLIC_HOST=""

    if [ "$_touched" = "true" ] && [ "$_ok" = "true" ]; then
        log_success "Конфиг цели возвращён к состоянию до Selfmask"
    elif [ "$_touched" = "true" ]; then
        log_warn "Не все прежние параметры удалось вернуть — проверьте [censorship] в конфиге цели"
    fi
    if [ -n "$_skipped" ]; then
        log_info "До Selfmask эти ключи в конфиге не стояли, поэтому не восстанавливались: ${_skipped}"
        log_info "Если движок их не любит пустыми — удалите их из конфига вручную"
    fi
    [ "$_ok" = "true" ]
}

_selfmask_apply_mtproxyl_settings() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        _selfmask_apply_target_settings
        return $?
    fi

    log_info "Применение selfmask-настроек в MTProxyL..."

    _selfmask_snapshot_manager_settings
    SELFMASK_ENABLED="true"

    PROXY_DOMAIN="${SELFMASK_DOMAIN}"
    MASKING_ENABLED="true"
    MASKING_HOST="127.0.0.1"
    MASKING_PORT="${SELFMASK_NGINX_BACKEND_PORT}"
    UNKNOWN_SNI_ACTION="mask"

    # Длину берём из своего же сертификата: по сети на 443 этого домена
    # отвечает прокси, а не nginx Selfmask, и замер никогда не удавался.
    auto_set_fake_cert_len "${SELFMASK_DOMAIN}" "$(_selfmask_cert_dir)/fullchain.pem" 2>/dev/null || \
        log_warn "Не удалось определить fake_cert_len для '${SELFMASK_DOMAIN}', оставляем ${FAKE_CERT_LEN:-2048}"

    save_settings
    log_success "Selfmask-настройки сохранены"

    if is_proxy_running; then
        log_info "Перезапуск прокси..."
        load_secrets
        restart_proxy_container || true
    else
        log_info "Прокси не запущен — запустите позже командой mtproxyl start"
    fi
}

# Reanimator: конфиг чужой, точечно патчим [censorship] через
# apply_target_tuning(). Инструкцию печатаем всегда — автопатч не универсален.
_selfmask_apply_target_settings() {
    SELFMASK_ENABLED="true"
    save_settings

    local _old_domain; _old_domain=$(_target_tls_domain 2>/dev/null)

    echo ""
    echo -e "  ${BOLD}Нужно применить в конфиге цели, секция [censorship]:${NC}"
    echo -e "    tls_domain = \"${SELFMASK_DOMAIN}\"${_old_domain:+  ${DIM}(было: ${_old_domain})${NC}}"
    echo -e "    mask_host = \"127.0.0.1\""
    echo -e "    mask_port = ${SELFMASK_NGINX_BACKEND_PORT}"
    echo -e "    unknown_sni_action = \"mask\""
    echo -e "  ${BOLD}и в секции [general.links]:${NC}"
    echo -e "    public_host = \"${SELFMASK_DOMAIN}\"  ${DIM}(иначе ссылки будут с IP, а не с доменом)${NC}"
    echo ""
    if [ -n "$_old_domain" ] && [ "$_old_domain" != "${SELFMASK_DOMAIN}" ]; then
        log_warn "Смена SNI-домена меняет FakeTLS-ссылки — старые ee-ссылки перестанут работать"
        echo -e "  ${DIM}Новые ссылки будут показаны после перезапуска цели.${NC}"
        echo ""
    fi

    if [ -z "${DETECTED_CONFIG_PATH:-}" ] || [ ! -f "${DETECTED_CONFIG_PATH:-}" ]; then
        log_warn "Конфиг цели не найден — примените параметры выше вручную и перезапустите цель"
        return 1
    fi

    echo -en "  ${BOLD}Применить в ${DETECTED_CONFIG_PATH} и перезапустить цель? [Y/n]:${NC} "
    local _yn; read_line _yn
    if [[ "$_yn" =~ ^[nN] ]]; then
        log_info "Пропущено — примените параметры вручную и перезапустите цель"
        return 0
    fi

    # То же, что и в менеджере: запоминаем, что стояло в конфиге цели, чтобы
    # отключение вернуло это назад, а не оставило чужой конфиг с нашим доменом.
    _selfmask_snapshot_target_settings

    # Пакетный режим: перезапуск один раз в конце, а не после каждого ключа.
    local _ok=true
    apply_target_tuning "tls_domain" "${SELFMASK_DOMAIN}" "censorship" true || _ok=false
    apply_target_tuning "mask_host" "127.0.0.1" "censorship" true || _ok=false
    apply_target_tuning "mask_port" "${SELFMASK_NGINX_BACKEND_PORT}" "censorship" true || _ok=false
    apply_target_tuning "unknown_sni_action" "mask" "censorship" true || _ok=false
    # Домен selfmask — заведомо наш, с проверенной A-записью сюда. Без
    # public_host движок подставляет в ссылки определённый им IP, и клиент
    # получает адрес, по которому FakeTLS-домен не совпадает с именем хоста.
    apply_target_tuning "public_host" "${SELFMASK_DOMAIN}" "general.links" true || _ok=false

    if [ "$_ok" = "true" ]; then
        log_success "Параметры selfmask применены в конфиге цели"
    else
        log_warn "Не всё удалось применить автоматически — сверьтесь с инструкцией выше"
    fi

    if is_proxy_running; then
        restart_target
    else
        log_info "Цель не запущена — запустите её, чтобы изменения вступили в силу"
        return 0
    fi

    # Ссылки печатаем в самом конце setup'а: сразу после рестарта их
    # затирали бы вывод verify и итоговая сводка, а API цели к этому
    # моменту ещё не успевал подняться.
    _SELFMASK_LINKS_PENDING="true"
}

# Новые ссылки цели — последним блоком, когда всё уже настроено.
_selfmask_show_links_tail() {
    [ "${_SELFMASK_LINKS_PENDING:-false}" = "true" ] || return 0
    _SELFMASK_LINKS_PENDING="false"

    echo ""
    draw_header "НОВЫЕ ССЫЛКИ (SNI: ${SELFMASK_DOMAIN})"
    # Ждём не просто ответа API, а появления самих ссылок: после рестарта
    # telemt отдаёт пользователей раньше, чем заполняет [general.links].
    if _wait_target_links 15; then
        show_target_links_ipv4 || true
    elif _get_telemt_users_json >/dev/null 2>&1; then
        log_warn "Цель отвечает, но ссылок в ответе пока нет"
        echo -e "  ${DIM}Посмотреть позже: главное меню → Ссылки на прокси${NC}"
        echo -e "  ${DIM}Если цель отдаёт только IPv6 — задайте [general.links] public_host${NC}"
    else
        log_warn "Ссылки недоступны: $(_telemt_api_unavailable_reason)"
        echo -e "  ${DIM}Позже: главное меню → Ссылки на прокси${NC}"
    fi
}

# Выполняется после любого успешного продления — хоть по certbot.timer,
# хоть по cron. В --deploy-hook нашей cron-строки его держать нельзя: на
# системе со штатным таймером та строка не добавляется вовсе.
SELFMASK_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/mtproxyl-selfmask.sh"

_selfmask_install_deploy_hook() {
    mkdir -p "$(dirname "$SELFMASK_DEPLOY_HOOK")"
    cat > "$SELFMASK_DEPLOY_HOOK" << HOOKEOF
#!/bin/bash
# MTProxyL — обновление служб после продления сертификата Let's Encrypt.
# Ставится автоматически (lib/selfmask.sh), правки будут перезаписаны.

# certbot зовёт хук на каждый домен отдельно — сверяем, что продлили наш.
_domain=\$(basename "\${RENEWED_LINEAGE:-}" 2>/dev/null)
[ -n "\$_domain" ] || exit 0

# Реаниматор держит настройки selfmask отдельно от менеджера. Через source,
# а не grep: значения в одинарных кавычках.
_ours=""
for _f in "${INSTALL_DIR}/selfmask-reanimator.conf" "${INSTALL_DIR}/settings.conf"; do
    [ -r "\$_f" ] || continue
    SELFMASK_DOMAIN=""
    # shellcheck source=/dev/null
    . "\$_f" 2>/dev/null || continue
    [ -n "\$SELFMASK_DOMAIN" ] && { _ours="\$SELFMASK_DOMAIN"; break; }
done
# Заглушка selfmask: подхватывает новый сертификат без обрыва соединений.
# Только на своём домене — чужое продление её не касается.
if [ -n "\$_ours" ] && [ "\$_domain" = "\$_ours" ]; then
    systemctl reload ${SELFMASK_PQ_SERVICE} 2>/dev/null || true
fi

# У панели своя копия сертификата: /etc/letsencrypt её пользователю не
# читается. Домен панели может отличаться — сверяем с самой копией.
_panel_cfg="/etc/mtproxyl-panel/config.toml"
_panel_certs="/var/lib/mtproxyl-panel/certs"
_panel_is_ours=""
if [ -f "\$_panel_certs/panel.crt" ]; then
    openssl x509 -in "\$_panel_certs/panel.crt" -noout -text 2>/dev/null \\
        | grep -oE 'DNS:[^,[:space:]]+' | cut -d: -f2 | grep -Fxq "\$_domain" \\
        && _panel_is_ours="yes"
fi
if [ -n "\$_panel_is_ours" ] && [ -f "\$_panel_cfg" ] && grep -q "^cert_file *= *\"\$_panel_certs/panel.crt\"" "\$_panel_cfg" 2>/dev/null; then
    install -o mtproxyl-panel -g mtproxyl-panel -m 0644 \\
        "\${RENEWED_LINEAGE}/fullchain.pem" "\$_panel_certs/panel.crt" 2>/dev/null || exit 0
    install -o mtproxyl-panel -g mtproxyl-panel -m 0600 \\
        "\${RENEWED_LINEAGE}/privkey.pem" "\$_panel_certs/panel.key" 2>/dev/null || exit 0
    # Панель читает сертификат один раз при старте, reload она не умеет.
    systemctl restart mtproxyl-panel 2>/dev/null || true
fi
HOOKEOF
    chmod 700 "$SELFMASK_DEPLOY_HOOK"
}

# Панель со своим ACME на нашем домене обречена: порт 80 занят нашим nginx.
# Отдаём ей копию сертификата certbot и снимаем acme_domain — заодно панель
# перестаёт слушать 80 вовсе (см. internal/server/server.go).
# Отдать панели текущий сертификат Selfmask. Нужно после переустановки панели
# (в том числе при переезде): свой файл она делает самоподписанным, и в её
# интерфейсе вместо домена снова появляется голый IP.
selfmask_sync_panel_cert() {
    local _panel_cfg="/etc/mtproxyl-panel/config.toml"
    local _panel_certs="/var/lib/mtproxyl-panel/certs"
    local _cert_dir; _cert_dir="$(_selfmask_cert_dir)"

    [ -f "$_panel_cfg" ] || { log_info "Панель не установлена — отдавать сертификат некому"; return 0; }
    id mtproxyl-panel &>/dev/null || { log_info "Пользователя панели нет"; return 0; }
    if [ "${SELFMASK_ENABLED:-false}" != "true" ] || [ -z "${SELFMASK_DOMAIN:-}" ]; then
        log_info "Selfmask выключен — своего сертификата у нас нет"
        return 0
    fi
    [ -f "${_cert_dir}/fullchain.pem" ] || { log_error "Сертификат Selfmask не найден: ${_cert_dir}"; return 1; }

    # Панель со своим или чужим сертификатом трогать нельзя — это выбор хозяина.
    if ! grep -qF "${_panel_certs}/panel.crt" "$_panel_cfg" 2>/dev/null; then
        log_warn "Панель настроена на свой сертификат — не трогаем"
        log_info "Чтобы она взяла наш: пропишите cert_file = \"${_panel_certs}/panel.crt\""
        return 0
    fi

    mkdir -p "$_panel_certs"
    install -o mtproxyl-panel -g mtproxyl-panel -m 0644 \
        "${_cert_dir}/fullchain.pem" "${_panel_certs}/panel.crt" 2>/dev/null || {
        log_error "Не удалось скопировать сертификат для панели"; return 1; }
    install -o mtproxyl-panel -g mtproxyl-panel -m 0600 \
        "${_cert_dir}/privkey.pem" "${_panel_certs}/panel.key" 2>/dev/null || {
        log_error "Не удалось скопировать ключ для панели"; return 1; }
    systemctl restart mtproxyl-panel 2>/dev/null || true
    log_success "Панель получила сертификат Selfmask — она снова на ${SELFMASK_DOMAIN}"
}

_selfmask_handoff_cert_to_panel() {
    local _panel_cfg="/etc/mtproxyl-panel/config.toml"
    local _panel_certs="/var/lib/mtproxyl-panel/certs"
    local _cert_dir; _cert_dir="$(_selfmask_cert_dir)"

    [ -f "$_panel_cfg" ] || return 0
    id mtproxyl-panel &>/dev/null || return 0

    # Трогаем только панель, которая просит Let's Encrypt на наш же домен.
    # Свой сертификат или самоподписанный — осознанный выбор пользователя.
    grep -qE "^acme_domain[[:space:]]*=[[:space:]]*\"${SELFMASK_DOMAIN}\"" "$_panel_cfg" 2>/dev/null || return 0

    log_info "Панель использует Let's Encrypt на этом же домене — передаём ей сертификат"

    mkdir -p "$_panel_certs"
    install -o mtproxyl-panel -g mtproxyl-panel -m 0644 \
        "${_cert_dir}/fullchain.pem" "${_panel_certs}/panel.crt" 2>/dev/null || {
        log_warn "Не удалось скопировать сертификат для панели"
        return 0
    }
    install -o mtproxyl-panel -g mtproxyl-panel -m 0600 \
        "${_cert_dir}/privkey.pem" "${_panel_certs}/panel.key" 2>/dev/null || {
        log_warn "Не удалось скопировать ключ для панели"
        return 0
    }

    # acme_domain убираем, cert_file/key_file добавляем — сохраняя остальной
    # конфиг как есть: он принадлежит панели, а не нам.
    local _tmp; _tmp=$(mktemp) || return 0
    awk -v certs="$_panel_certs" '
        /^acme_domain[[:space:]]*=/ { next }
        /^acme_cache_dir[[:space:]]*=/ { next }
        /^cert_file[[:space:]]*=/ { next }
        /^key_file[[:space:]]*=/ { next }
        /^\[tls\]/ {
            print
            print "cert_file = \"" certs "/panel.crt\""
            print "key_file = \"" certs "/panel.key\""
            next
        }
        { print }
    ' "$_panel_cfg" > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 0; }

    if ! grep -q '^cert_file' "$_tmp"; then
        rm -f "$_tmp"
        log_warn "Не удалось перенастроить панель — секция [tls] не найдена"
        return 0
    fi

    cat "$_tmp" > "$_panel_cfg"
    rm -f "$_tmp"
    chown mtproxyl-panel:mtproxyl-panel "$_panel_cfg" 2>/dev/null || true
    chmod 600 "$_panel_cfg" 2>/dev/null || true

    log_success "Панель переведена на сертификат selfmask — порт 80 ей больше не нужен"

    # Конфиг читается при старте. Остановленную поднимет
    # _selfmask_restore_port80_holders, работающую перезапускаем здесь.
    systemctl is-active mtproxyl-panel &>/dev/null || return 0
    if [ "${MTPROXYL_ASSUME_YES:-}" = "1" ]; then
        # Зовёт сама панель — перезапуск оборвал бы её же запрос.
        log_warn "Панель перечитает сертификат после перезапуска:"
        log_info "  sudo systemctl restart mtproxyl-panel"
        return 0
    fi
    if systemctl restart mtproxyl-panel 2>/dev/null; then
        log_success "Панель перезапущена с новым сертификатом"
    else
        log_warn "Не удалось перезапустить панель — сделайте это вручную"
    fi
}

_selfmask_setup_renewal() {
    log_info "Настройка автопродления сертификата..."

    _selfmask_install_deploy_hook
    log_success "Хук обновления служб установлен (${SELFMASK_DEPLOY_HOOK})"

    if systemctl is-enabled certbot.timer &>/dev/null 2>&1; then
        log_success "certbot.timer уже активен — продление по расписанию системы"
        return 0
    fi

    if [ -f /etc/cron.d/certbot ]; then
        log_success "Системный cron certbot уже настроен"
        return 0
    fi

    # Свой cron нужен только там, где certbot не принёс ни таймера, ни
    # cron.d. Перезагрузку служб оставляем хуку выше — иначе она была бы
    # в двух местах и разошлась бы при первой же правке.
    local _cron_line="0 3 * * * certbot renew --quiet"
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "$_cron_line") | crontab -
        log_success "Добавлен cron для автопродления"
    else
        log_info "Cron автопродления уже существует"
    fi
}

selfmask_verify() {
    echo ""
    draw_header "ПРОВЕРКА SELFMASK"
    echo ""

    local _ok=true

    if [ -x "$(_selfmask_nginx_bin)" ]; then
        log_success "nginx с поддержкой PQ: $(_selfmask_nginx_source)"
    else
        log_error "nginx с поддержкой PQ не найден"; _ok=false
    fi
    # Годится любой openssl с X25519MLKEM768 — системный 3.5.0+ ничем не хуже
    # нашей сборки, и требовать именно её значит ронять проверку на ровном месте.
    local _verify_openssl=""
    if _verify_openssl=$(_pq_openssl_bin 2>/dev/null); then
        log_success "openssl с поддержкой PQ: $(_pq_openssl_source)"
    else
        log_error "openssl с поддержкой PQ не найден"; _ok=false
    fi
    if [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "letsencrypt" ]; then
        command -v certbot &>/dev/null && log_success "certbot установлен" || { log_error "certbot не установлен"; _ok=false; }
    fi

    if [ -f "$(_selfmask_cert_dir)/fullchain.pem" ]; then
        log_success "Сертификат найден (${SELFMASK_CERT_MODE:-letsencrypt})"
    else
        log_warn "Сертификат не найден"
        _ok=false
    fi

    if systemctl is-active "${SELFMASK_PQ_SERVICE}" &>/dev/null; then
        log_success "PQ nginx активен"
    else
        log_warn "PQ nginx не запущен"
        _ok=false
    fi

    local _site_conf="$(_selfmask_pq_conf)"
    [ -f "$_site_conf" ] && log_success "Конфиг nginx найден" || { log_warn "Конфиг nginx не найден"; _ok=false; }

    local _http_code=""
    if [ -n "${SELFMASK_DOMAIN:-}" ]; then
        _http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            --resolve "${SELFMASK_DOMAIN}:${SELFMASK_NGINX_BACKEND_PORT}:127.0.0.1" \
            "https://${SELFMASK_DOMAIN}:${SELFMASK_NGINX_BACKEND_PORT}/" 2>/dev/null || true)
    fi

    if [ "$_http_code" = "200" ] || [ "$_http_code" = "403" ] || [ "$_http_code" = "404" ]; then
        log_success "Backend nginx отвечает (HTTP ${_http_code})"
    else
        log_warn "Backend nginx не отвечает как ожидалось (HTTP ${_http_code:-?})"
    fi

    if [ -n "${SELFMASK_DOMAIN:-}" ] && [ -n "$_verify_openssl" ]; then
        local _pq_out _pq_line
        _pq_out=$("$_verify_openssl" s_client \
            -tls1_3 \
            -groups X25519MLKEM768 \
            -connect "127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT}" \
            -servername "${SELFMASK_DOMAIN}" </dev/null 2>&1 || true)

        _pq_line=$(echo "$_pq_out" | grep -iE "Server Temp Key|X25519MLKEM768|Negotiated group|group" | head -1 || true)

        if echo "$_pq_out" | grep -q "X25519MLKEM768"; then
            log_success "PQ handshake активен"
            [ -n "$_pq_line" ] && log_info "${_pq_line}"
        else
            log_warn "PQ handshake не подтверждён"
            [ -n "$_pq_line" ] && log_warn "${_pq_line}"
        fi
    fi   

    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        # Сверяем конфиг ЦЕЛИ, а не собственные настройки менеджера —
        # в этом режиме mask/SNI живут в чужом toml.
        local _t_host _t_port _t_dom
        _t_host=$(_toml_get_string_in_section "censorship" "mask_host" "${DETECTED_CONFIG_PATH:-}" 2>/dev/null)
        _t_port=$(_toml_get_string_in_section "censorship" "mask_port" "${DETECTED_CONFIG_PATH:-}" 2>/dev/null)
        _t_dom=$(_target_tls_domain 2>/dev/null)
        if [ "$_t_host" = "127.0.0.1" ] && \
           [ "$_t_port" = "${SELFMASK_NGINX_BACKEND_PORT}" ] && \
           [ "$_t_dom" = "${SELFMASK_DOMAIN:-}" ]; then
            log_success "Конфиг цели настроен под selfmask (SNI: ${_t_dom})"
        else
            log_warn "Конфиг цели не совпадает с selfmask"
            echo -e "    ${DIM}ожидалось: tls_domain=${SELFMASK_DOMAIN} mask_host=127.0.0.1 mask_port=${SELFMASK_NGINX_BACKEND_PORT}${NC}"
            echo -e "    ${DIM}в конфиге: tls_domain=${_t_dom:-—} mask_host=${_t_host:-—} mask_port=${_t_port:-—}${NC}"
            _ok=false
        fi
    elif [ "${SELFMASK_ENABLED:-false}" = "true" ] && \
       [ "${MASKING_HOST:-}" = "127.0.0.1" ] && \
       [ "${MASKING_PORT:-}" = "${SELFMASK_NGINX_BACKEND_PORT}" ] && \
       [ "${PROXY_DOMAIN:-}" = "${SELFMASK_DOMAIN:-}" ]; then
        log_success "Настройки MTProxyL для selfmask применены"
    else
        log_warn "Настройки MTProxyL не совпадают с selfmask"
        _ok=false
    fi

    echo ""
    if $_ok; then
        log_success "Проверка selfmask завершена успешно"
    else
        log_warn "Selfmask настроен не полностью — проверьте предупреждения выше"
    fi

    selfmask_show_requirements
}

selfmask_setup() {
    check_root

    if ! selfmask_supported_os; then
        log_error "Selfmask пока поддерживается только на Debian/Ubuntu"
        return 1
    fi

    if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
        echo ""
        log_warn "Selfmask уже включён"
        echo -e "  ${BOLD}Текущие параметры:${NC}"
        echo -e "    Домен:    ${SELFMASK_DOMAIN:-${DIM}не задан${NC}}"
        echo -e "    Шаблон:   $(_selfmask_template_label "${SELFMASK_SITE_SOURCE:-stub}")"
        echo -e "    Backend:  127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT:-8444}"
        echo ""
        if [ "${MTPROXYL_NONINTERACTIVE:-false}" != "true" ]; then
            echo -en "  ${BOLD}Переустановить / обновить настройку? [y/N]:${NC} "
            local _re
            read_line _re
            [[ "$_re" =~ ^[yY] ]] || return 0
        fi
    fi

    # При установке аргументами параметры уже разложены по переменным.
    if [ "${MTPROXYL_NONINTERACTIVE:-false}" = "true" ]; then
        [ -n "${SELFMASK_DOMAIN:-}" ] || { log_error "Selfmask: домен не задан"; return 1; }
        log_info "Домен ${SELFMASK_DOMAIN}, сертификат ${SELFMASK_CERT_MODE}, шаблон $(_selfmask_template_label "${SELFMASK_SITE_SOURCE:-stub}")"
    else
        _selfmask_collect_params   || return 1
    fi
    _selfmask_install_deps         || return 1
    _selfmask_install_pq_nginx     || return 1
    _selfmask_deploy_site          || return 1
    if [ "$SELFMASK_CERT_MODE" = "selfsigned" ]; then
        _selfmask_generate_selfsigned_cert || return 1
    else
        _selfmask_obtain_cert          || { _selfmask_restore_port80_holders; return 1; }
    fi
    SELFMASK_CONFIGURE_ACTIVE="true" _selfmask_configure_nginx || { _selfmask_restore_port80_holders; return 1; }
    _selfmask_apply_mtproxyl_settings || { _selfmask_restore_port80_holders; return 1; }
    if [ "$SELFMASK_CERT_MODE" = "letsencrypt" ]; then
        _selfmask_setup_renewal || true
        # До возврата панели: она читает конфиг только при старте, и поднимать
        # её со старым acme_domain значило бы разбудить второго претендента на
        # порт 80, который уже занят нашим nginx.
        _selfmask_handoff_cert_to_panel || true
    fi
    # Возвращаем всех, кого останавливали ради выпуска сертификата.
    # Раньше это делалось только на путях с ошибкой.
    _selfmask_restore_port80_holders
    selfmask_verify

    echo ""
    log_success "Selfmask настроен"
    if [ "$SELFMASK_CERT_MODE" = "selfsigned" ]; then
        echo -e "  ${BOLD}Домен(SNI):${NC} ${SELFMASK_DOMAIN} ${DIM}(самоподписанный, A-запись не нужна)${NC}"
        echo -e "  ${DIM}Снаружи домен не открывается — заглушка отдаётся только по SNI${NC}"
        echo -e "  ${DIM}на mask-backend, порт 80 не занимается.${NC}"
    else
        echo -e "  ${BOLD}Домен:${NC}   https://${SELFMASK_DOMAIN}"
    fi
    echo -e "  ${BOLD}Сайт:${NC}    ${SELFMASK_SITE_DIR}"
    echo -e "  ${BOLD}Схема:${NC}   $(_selfmask_scheme_line)"
    echo ""

    _selfmask_show_links_tail
}

selfmask_disable() {
    check_root

    echo ""
    echo -e "  ${YELLOW}${BOLD}Отключение Selfmask${NC}"
    echo -e "  ${DIM}Будет отключён nginx selfmask и MTProxyL перестанет использовать локальный mask backend.${NC}"
    if [ "${SELFMASK_PREV_SAVED:-false}" = "true" ]; then
        echo -e "  ${DIM}Fake SNI и маскировка вернутся к тому, что было до включения${NC}"
        echo -e "  ${DIM}(${SELFMASK_PREV_DOMAIN:-домен не был задан}). Ссылки при этом изменятся.${NC}"
    else
        echo -e "  ${DIM}Прежний fake SNI не сохранён — домен останется selfmask'овым,${NC}"
        echo -e "  ${DIM}задайте нужный вручную после отключения.${NC}"
    fi
    echo -e "  ${DIM}Каталог сайта и сертификаты удаляться не будут.${NC}"
    echo ""
    echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
    local _yn
    read_line _yn
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }

    if ! web_is_enabled 2>/dev/null; then
        systemctl disable --now "${SELFMASK_PQ_SERVICE}" &>/dev/null || true
        rm -f "/etc/systemd/system/${SELFMASK_PQ_SERVICE}" 2>/dev/null || true
        systemctl daemon-reload &>/dev/null || true
        rm -f "$(_selfmask_generated_pq_conf)" 2>/dev/null || true
    fi

    SELFMASK_ENABLED="false"

    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        # Раньше здесь только просили вернуть всё руками, и в чужом конфиге
        # оставался наш домен вместе с mask_host = 127.0.0.1 — то есть цель
        # продолжала ходить на уже выключенную заглушку.
        if _selfmask_restore_target_settings; then
            log_warn "Ссылки цели изменились — проверьте их после перезапуска"
        else
            echo -e "  ${DIM}Nginx-заглушка selfmask отключена. Конфиг цели не тронут —${NC}"
            echo -e "  ${DIM}при необходимости верните в [censorship] цели прежние${NC}"
            echo -e "  ${DIM}tls_domain/mask_host/mask_port/unknown_sni_action вручную${NC}"
            echo -e "  ${DIM}и перезапустите цель.${NC}"
        fi
    elif _selfmask_restore_manager_settings; then
        log_warn "Проверьте ссылки после отключения selfmask: mtproxyl secret link"
    elif [ "${MASKING_HOST:-}" = "127.0.0.1" ] && [ "${MASKING_PORT:-}" = "${SELFMASK_NGINX_BACKEND_PORT}" ]; then
        # Снимка нет: selfmask включали версией, которая его ещё не делала.
        # Тогда как раньше — только маскировка, fake SNI остаётся selfmask'овым.
        MASKING_ENABLED="true"
        MASKING_HOST=""
        MASKING_PORT="443"
        log_info "Selfmask отключён — маскировка возвращена в обычный режим"
        log_info "Теперь backend по умолчанию: ${PROXY_DOMAIN}:443"
        log_warn "Прежний fake SNI не сохранялся (selfmask включён до обновления)"
        log_warn "Задайте домен вручную: mtproxyl settings set PROXY_DOMAIN <домен>"
        log_warn "Проверьте ссылки после отключения selfmask: mtproxyl secret link"
    fi

    save_settings

    if web_is_enabled 2>/dev/null; then
        _selfmask_configure_nginx || return 1
        log_info "PQ nginx оставлен для WEB Proxy"
    fi

    if [ "${MTPROXYL_MODE:-manager}" != "manager" ]; then
        is_proxy_running && restart_target
    elif is_proxy_running; then
        load_secrets
        restart_proxy_container || true
    fi

    log_success "Selfmask отключён"
}

selfmask_remove_pq_nginx() {
    check_root

    echo ""
    echo -e "  ${RED}${BOLD}Полное удаление PQ nginx${NC}"
    echo ""
    echo -e "  ${DIM}Будет удалено:${NC}"
    echo -e "  ${DIM}  - /opt/mtproxyl-nginx/ (nginx + OpenSSL)${NC}"
    echo -e "  ${DIM}  - Служба ${SELFMASK_PQ_SERVICE}${NC}"
    echo -e "  ${DIM}  - /var/log/mtproxyl-nginx/  /var/lib/mtproxyl-nginx/${NC}"
    echo ""
    echo -e "  ${GREEN}Не будет удалено:${NC}"
    echo -e "  ${DIM}  - Сертификаты Let's Encrypt${NC}"
    echo -e "  ${DIM}  - Каталог сайта ${SELFMASK_SITE_DIR}${NC}"
    echo -e "  ${DIM}  - Системный nginx и OpenSSL${NC}"
    echo ""

    echo -en "  ${BOLD}Удалить PQ nginx? [y/N]:${NC} "
    local _yn
    read_line _yn
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }

    # Сначала отключаем selfmask если активен
    if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
        log_info "Отключаем selfmask..."
        systemctl disable --now "${SELFMASK_PQ_SERVICE}" &>/dev/null || true
        rm -f "/etc/systemd/system/${SELFMASK_PQ_SERVICE}" 2>/dev/null || true
        rm -f "$(_selfmask_generated_pq_conf)" 2>/dev/null || true

        SELFMASK_ENABLED="false"
        if [ "${MTPROXYL_MODE:-manager}" = "manager" ] && \
           [ "${MASKING_HOST:-}" = "127.0.0.1" ] && [ "${MASKING_PORT:-}" = "${SELFMASK_NGINX_BACKEND_PORT}" ]; then
            MASKING_ENABLED="true"
            MASKING_HOST=""
            MASKING_PORT="443"
        fi
        save_settings
        log_success "Selfmask отключён"
    fi

    # Останавливаем сервис
    systemctl disable --now "${SELFMASK_PQ_SERVICE}" &>/dev/null || true
    rm -f "/etc/systemd/system/${SELFMASK_PQ_SERVICE}" 2>/dev/null || true
    systemctl daemon-reload &>/dev/null || true
    pkill -f "${SELFMASK_PQ_PREFIX}/sbin/nginx" 2>/dev/null || true

    # Удаляем файлы PQ nginx
    rm -rf "${SELFMASK_PQ_PREFIX}"
    rm -rf /var/log/mtproxyl-nginx
    rm -rf /var/lib/mtproxyl-nginx

    log_success "PQ nginx полностью удалён"

    # Перезапуск: в reanimator-режиме нельзя дёргать restart_proxy_container —
    # он пересобирает СВОЙ образ telemt (а Docker на хосте может быть вообще
    # не установлен). Цель перезапускаем её же способом.
    if [ "${MTPROXYL_MODE:-manager}" != "manager" ]; then
        if is_proxy_running; then
            echo ""
            log_warn "Заглушка удалена, но в конфиге цели остались mask_host/mask_port на 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT}"
            echo -e "  ${DIM}Поправьте [censorship] в ${DETECTED_CONFIG_PATH:-конфиге цели} (меню: Цель/режим → Редактировать конфиг цели),${NC}"
            echo -e "  ${DIM}иначе маскировка будет ссылаться на несуществующий backend.${NC}"
        fi
        return 0
    fi

    if is_proxy_running; then
        log_info "Перезапуск прокси..."
        load_secrets
        restart_proxy_container || true
    fi
}

_selfmask_cleanup_for_uninstall() {
    # Отключаем selfmask
    if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
        SELFMASK_ENABLED="false"
        save_settings 2>/dev/null || true
    fi

    # Останавливаем и удаляем PQ nginx сервис
    systemctl disable --now "${SELFMASK_PQ_SERVICE}" &>/dev/null || true
    rm -f "/etc/systemd/system/${SELFMASK_PQ_SERVICE}" 2>/dev/null || true
    pkill -f "${SELFMASK_PQ_PREFIX}/sbin/nginx" 2>/dev/null || true

    # Удаляем PQ nginx
    rm -rf "${SELFMASK_PQ_PREFIX}" 2>/dev/null || true
    rm -rf /var/log/mtproxyl-nginx 2>/dev/null || true
    rm -rf /var/lib/mtproxyl-nginx 2>/dev/null || true

    systemctl daemon-reload &>/dev/null || true
}

# Ставит нашу сборку поверх любой текущей: системный nginx без stream или
# устаревшая своя — обе лечатся одинаково.
selfmask_refresh_pq_nginx() {
    check_root
    log_info "Обновление nginx из состава MTProxyL (${SELFMASK_PQ_RELEASE_TAG})..."
    _selfmask_install_pq_nginx nginx force || return 1
    local _bin; _bin=$(_selfmask_pq_nginx_bin)
    if "$_bin" -V 2>&1 | grep -q -- '--with-stream_ssl_preread_module'; then
        log_success "nginx умеет stream и ssl_preread — WEB Proxy можно включать"
    else
        log_warn "В этой сборке нет stream — раскладка shared работать не будет"
    fi

    # Конфиг переживает распаковку сам (его откладывает установка), остаётся
    # перезапустить службу на новом бинарнике.
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] || web_is_enabled 2>/dev/null; then
        _selfmask_install_pq_service "$(_selfmask_pq_conf)"
        systemctl restart "${SELFMASK_PQ_SERVICE}" &>/dev/null || {
            log_error "nginx не поднялся после обновления"; return 1; }
        log_success "Служба перезапущена на новой сборке"
    fi
}

nginx_custom_status_line() {
    if nginx_custom_active; then
        echo -e "${GREEN}включён${NC}"
    elif [ -f "$NGINX_CUSTOM_FILE" ]; then
        echo -e "${DIM}выключен, файл сохранён${NC}"
    else
        echo -e "${DIM}выключен${NC}"
    fi
}

nginx_custom_status_json() {
    local _size=0 _mtime=""
    if [ -f "$NGINX_CUSTOM_FILE" ]; then
        _size=$(stat -c %s "$NGINX_CUSTOM_FILE" 2>/dev/null || echo 0)
        _mtime=$(stat -c %y "$NGINX_CUSTOM_FILE" 2>/dev/null || true)
    fi
    printf '{"enabled":%s,"active":%s,"file":"%s","file_exists":%s,"size":%s,"modified":"%s"}\n' \
        "$([ "${NGINX_CUSTOM_ENABLED:-false}" = "true" ] && echo true || echo false)" \
        "$(nginx_custom_active && echo true || echo false)" \
        "$(json_escape "$NGINX_CUSTOM_FILE")" \
        "$([ -f "$NGINX_CUSTOM_FILE" ] && echo true || echo false)" \
        "${_size:-0}" "$(json_escape "$_mtime")"
}

_nginx_custom_validate() {
    local _conf="$1" _out=""
    [ -s "$_conf" ] || { log_error "Конфиг nginx пуст"; return 1; }
    if _selfmask_conf_needs_stream "$_conf" && ! _system_nginx_has_stream \
       && [ ! -x "$(_selfmask_pq_nginx_bin)" ]; then
        log_info "Конфигу нужен stream — устанавливаем nginx из состава MTProxyL"
        _selfmask_install_pq_nginx nginx force || return 1
    fi
    _out=$("$(_selfmask_nginx_bin_for_conf "$_conf")" -t -c "$_conf" 2>&1) || {
        log_error "Проверка nginx -t завершилась ошибкой"
        echo "$_out" | sed 's/^/    /'
        return 1
    }
    [ -n "$_out" ] && echo "$_out" | sed 's/^/    /'
    return 0
}

nginx_custom_show() {
    local _conf="$NGINX_CUSTOM_FILE"
    [ -f "$_conf" ] || _conf="$(_selfmask_generated_pq_conf)"
    [ -f "$_conf" ] || { log_error "Конфиг nginx ещё не создан"; return 1; }
    cat "$_conf"
}

nginx_custom_test() {
    local _conf="$NGINX_CUSTOM_FILE"
    [ -f "$_conf" ] || { log_error "Пользовательский конфиг не найден"; return 1; }
    _nginx_custom_validate "$_conf" || return 1
    log_success "Конфиг nginx корректен"
}

nginx_custom_enable() {
    check_root
    if nginx_custom_active; then
        log_info "Пользовательский конфиг nginx уже включён"
        return 0
    fi
    if [ "${SELFMASK_ENABLED:-false}" != "true" ] && ! web_is_enabled 2>/dev/null; then
        log_error "Сначала включите Selfmask или WEB Proxy"
        return 1
    fi

    echo ""
    log_warn "MTProxyL перестанет пересобирать nginx.conf при изменении настроек"
    echo -e "  ${DIM}Маршруты, домены и порты в пользовательском файле нужно синхронизировать вручную.${NC}"
    echo -en "  ${BOLD}Включить пользовательский конфиг nginx? [y/N]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }

    if [ ! -f "$NGINX_CUSTOM_FILE" ]; then
        NGINX_CUSTOM_ENABLED="false"
        _selfmask_configure_nginx || { _selfmask_restore_port80_holders; return 1; }
        mkdir -p "$INSTALL_DIR"
        cp "$(_selfmask_generated_pq_conf)" "$NGINX_CUSTOM_FILE" || {
            _selfmask_restore_port80_holders
            log_error "Не удалось создать ${NGINX_CUSTOM_FILE}"
            return 1
        }
        chmod 600 "$NGINX_CUSTOM_FILE"
        log_success "Создан пользовательский конфиг из текущего рабочего"
    else
        log_info "Используем сохранённый пользовательский конфиг"
    fi

    _nginx_custom_validate "$NGINX_CUSTOM_FILE" || {
        _selfmask_restore_port80_holders
        return 1
    }
    NGINX_CUSTOM_ENABLED="true"
    if ! save_settings; then
        NGINX_CUSTOM_ENABLED="false"
        _selfmask_restore_port80_holders
        return 1
    fi
    if ! _selfmask_configure_nginx; then
        NGINX_CUSTOM_ENABLED="false"
        save_settings
        _selfmask_configure_nginx >/dev/null 2>&1 || true
        _selfmask_restore_port80_holders
        log_error "Пользовательский конфиг не включён"
        return 1
    fi
    _selfmask_restore_port80_holders
    log_success "Пользовательский конфиг nginx включён"
    echo -e "  ${BOLD}Файл:${NC} ${NGINX_CUSTOM_FILE}"
}

nginx_custom_disable() {
    check_root
    if [ "${NGINX_CUSTOM_ENABLED:-false}" != "true" ]; then
        log_info "Пользовательский конфиг nginx уже выключен"
        return 0
    fi

    echo ""
    log_warn "Nginx снова будет собираться из настроек MTProxyL"
    echo -e "  ${DIM}Пользовательский файл останется на месте для повторного включения.${NC}"
    echo -en "  ${BOLD}Выключить пользовательский конфиг nginx? [y/N]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }

    NGINX_CUSTOM_ENABLED="false"
    if ! save_settings; then
        NGINX_CUSTOM_ENABLED="true"
        return 1
    fi
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] || web_is_enabled 2>/dev/null; then
        if ! _selfmask_configure_nginx; then
            NGINX_CUSTOM_ENABLED="true"
            save_settings
            _selfmask_configure_nginx >/dev/null 2>&1 || true
            _selfmask_restore_port80_holders
            log_error "Не удалось вернуться к стандартному конфигу"
            return 1
        fi
        _selfmask_restore_port80_holders
    fi
    log_success "Стандартный конфиг nginx включён, пользовательский файл сохранён"
}

nginx_custom_write() {
    check_root
    mkdir -p "$INSTALL_DIR"
    local _tmp _size _backup="${NGINX_CUSTOM_FILE}.bak"
    _tmp=$(_mktemp "$INSTALL_DIR") || return 1
    cat > "$_tmp"
    _size=$(stat -c %s "$_tmp" 2>/dev/null || echo 0)
    if [ "${_size:-0}" -eq 0 ] || [ "${_size:-0}" -gt 2097152 ]; then
        rm -f "$_tmp"
        log_error "Размер конфига должен быть от 1 байта до 2 МБ"
        return 1
    fi
    _nginx_custom_validate "$_tmp" || { rm -f "$_tmp"; return 1; }

    [ ! -f "$NGINX_CUSTOM_FILE" ] || cp -f "$NGINX_CUSTOM_FILE" "$_backup"
    chmod 600 "$_tmp"
    mv -f "$_tmp" "$NGINX_CUSTOM_FILE"

    if nginx_custom_active && ! _selfmask_configure_nginx; then
        if [ -f "$_backup" ]; then
            mv -f "$_backup" "$NGINX_CUSTOM_FILE"
            _selfmask_install_pq_service "$NGINX_CUSTOM_FILE"
            systemctl restart "${SELFMASK_PQ_SERVICE}" &>/dev/null || true
        fi
        _selfmask_restore_port80_holders
        log_error "Изменение отменено: nginx не запустился"
        return 1
    fi
    _selfmask_restore_port80_holders
    log_success "Пользовательский конфиг nginx сохранён"
}

nginx_custom_edit() {
    check_root
    [ -f "$NGINX_CUSTOM_FILE" ] || {
        log_error "Пользовательский конфиг не найден — сначала включите режим"
        return 1
    }
    if [ "${MTPROXYL_ASSUME_YES:-}" = "1" ] || [ ! -t 0 ]; then
        log_error "Редактор недоступен без терминала"
        log_info "Из скрипта: mtproxyl selfmask nginx-config write < nginx.conf"
        return 1
    fi

    local _tmp _editor="${EDITOR:-nano}"
    _tmp=$(_mktemp "$INSTALL_DIR") || return 1
    cp "$NGINX_CUSTOM_FILE" "$_tmp" || return 1
    command -v "$_editor" &>/dev/null || _editor="vi"
    "$_editor" "$_tmp"
    cmp -s "$_tmp" "$NGINX_CUSTOM_FILE" && { rm -f "$_tmp"; log_info "Файл не изменён"; return 0; }
    nginx_custom_write < "$_tmp"
    local _rc=$?
    rm -f "$_tmp"
    return $_rc
}

handle_nginx_custom_command() {
    local _cmd="${1:-status}"
    case "$_cmd" in
        status) nginx_custom_status_json ;;
        on|enable) nginx_custom_enable ;;
        off|disable) nginx_custom_disable ;;
        show) nginx_custom_show ;;
        write) nginx_custom_write ;;
        edit) nginx_custom_edit ;;
        test) nginx_custom_test ;;
        *)
            log_error "Использование: mtproxyl selfmask nginx-config {status|on|off|show|write|edit|test}"
            return 1
            ;;
    esac
}

handle_selfmask_command() {
    local subcmd="${1:-status}"
    shift 2>/dev/null || true

    case "$subcmd" in
        status)
            if [ "${1:-}" = "--json" ]; then
                selfmask_show_status_json
            else
                selfmask_show_status
            fi
            ;;
        setup)   selfmask_setup ;;
        apply)   selfmask_apply ;;
        pq-install) selfmask_install_pq_tools ;;
        pq-nginx)   selfmask_refresh_pq_nginx ;;
        nginx-config) handle_nginx_custom_command "$@" ;;
        panel-cert) check_root; selfmask_sync_panel_cert ;;
        set)     selfmask_set_param "$1" "$2" ;;
        settable) selfmask_settable_json ;;
        verify)  selfmask_verify ;;
        disable) selfmask_disable ;;
        menu)    tui_selfmask_menu ;;
        *)
            echo -e "  ${BOLD}Selfmask:${NC}"
            echo -e "    ${GREEN}selfmask status${NC}   Статус"
            echo -e "    ${GREEN}selfmask setup${NC}    Настроить через мастер"
            echo -e "    ${GREEN}selfmask apply${NC}    Применить по сохранённым параметрам"
            echo -e "    ${GREEN}selfmask set${NC} K V   Изменить параметр"
            echo -e "    ${GREEN}selfmask settable${NC} Список параметров (JSON)"
            echo -e "    ${GREEN}selfmask pq-nginx${NC}  Обновить nginx из состава MTProxyL (нужен stream для WEB)"
            echo -e "    ${GREEN}selfmask nginx-config${NC} Управление пользовательским nginx.conf"
            echo -e "    ${GREEN}selfmask panel-cert${NC} Отдать сертификат веб-панели"
            echo -e "    ${GREEN}selfmask verify${NC}   Проверка"
            echo -e "    ${GREEN}selfmask disable${NC}  Отключить"
            echo -e "    ${GREEN}selfmask menu${NC}     Открыть меню"
            ;;
    esac
}

# ── Настраиваемые параметры для внешней панели ───────────────────────────────
# Формат: КЛЮЧ|валидатор|описание — как в каталоге NFT.
# Только то, что спрашивает мастер: производным состоянием и путями
# управляет сама установка.
_SELFMASK_SETTABLE=(
    "SELFMASK_DOMAIN|custom:_validate_selfmask_domain|Домен сайта-заглушки"
    "SELFMASK_CERT_MODE|enum:letsencrypt,selfsigned|Тип сертификата"
    "SELFMASK_CERT_EMAIL|custom:_validate_selfmask_email|Email для Let's Encrypt"
    "SELFMASK_SITE_SOURCE|custom:_validate_selfmask_template|Шаблон, URL на index.html или путь к папке с сайтом"
    "SELFMASK_NGINX_BACKEND_PORT|range:1:65535|Порт локального nginx"
    "SELFMASK_AUTO_RENEW|bool|Автопродление сертификата"
)

_validate_selfmask_domain() {
    validate_domain "$1" && return 0
    echo "Домен вида example.com"; return 1
}

# Пустой email допустим — установка подставит admin@<домен>.
_validate_selfmask_email() {
    [ -z "$1" ] && return 0
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && return 0
    echo "Адрес вида user@example.com"; return 1
}

# Либо имя встроенного шаблона, либо ссылка на свой index.html.
_validate_selfmask_template() {
    case "$1" in
        stub|filemanager|catrunner|mekorunner) return 0 ;;
        http://*|https://*) return 0 ;;
        /*)
            # Путь проверяем сразу: иначе панель приняла бы несуществующий
            # каталог, и подмена вскрылась бы только заглушкой вместо сайта.
            _selfmask_resolve_local_site "$1" >/dev/null 2>&1 && return 0
            echo "Каталог не найден или в нём нет index.html: $1"
            return 1
            ;;
    esac
    echo "Допустимо: stub, filemanager, catrunner, mekorunner, http(s)://... или путь к папке с index.html"
    return 1
}

_selfmask_find_settable() {
    local _key="$1" _entry
    for _entry in "${_SELFMASK_SETTABLE[@]}"; do
        [ "${_entry%%|*}" = "$_key" ] && { echo "$_entry"; return 0; }
    done
    return 1
}

# mtproxyl selfmask set <КЛЮЧ> <значение> — меняет только сохранённое
# значение. Сайт и сертификат перевыпускает selfmask apply.
selfmask_set_param() {
    local _key="$1" _val="$2" _entry
    if [ -z "$_key" ]; then
        log_error "Использование: mtproxyl selfmask set <ключ> <значение>"
        return 1
    fi
    if ! _entry=$(_selfmask_find_settable "$_key"); then
        log_error "Параметр '${_key}' недоступен для изменения"
        log_info "Список: mtproxyl selfmask settable"
        return 1
    fi
    local _rest="${_entry#*|}"
    local _validator="${_rest%%|*}"

    local _err
    if ! _err=$(_expert_validate "$_validator" "$_val" 2>&1); then
        log_error "Недопустимое значение для ${_key}: ${_err}"
        return 1
    fi

    printf -v "$_key" '%s' "$_val"
    save_selfmask_settings
    log_success "${_key} = ${_val}"
    log_info "Примените настройку заново: mtproxyl selfmask apply"
}

selfmask_settable_json() {
    local _entry _key _validator _desc _first=1
    printf '['
    for _entry in "${_SELFMASK_SETTABLE[@]}"; do
        _key="${_entry%%|*}"
        local _rest="${_entry#*|}"
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

# Неинтерактивная установка по сохранённым параметрам.
# selfmask_setup для панели не годится: под обходом подтверждений он берёт
# значения по умолчанию, а не введённые в интерфейсе.
selfmask_apply() {
    check_root

    if ! selfmask_supported_os; then
        log_error "Selfmask пока поддерживается только на Debian/Ubuntu"
        return 1
    fi

    if ! validate_domain "${SELFMASK_DOMAIN:-}"; then
        log_error "Домен не задан или некорректен"
        log_info "Задайте его: mtproxyl selfmask set SELFMASK_DOMAIN example.com"
        return 1
    fi

    # Мастер подставляет email сам, здесь делаем то же явно.
    if [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "letsencrypt" ] && [ -z "${SELFMASK_CERT_EMAIL:-}" ]; then
        SELFMASK_CERT_EMAIL="admin@${SELFMASK_DOMAIN}"
    fi

    log_info "Домен:   ${SELFMASK_DOMAIN}"
    log_info "Шаблон:  $(_selfmask_template_label "${SELFMASK_SITE_SOURCE:-stub}")"
    log_info "Сертификат: ${SELFMASK_CERT_MODE:-letsencrypt}"

    _selfmask_install_deps         || return 1
    _selfmask_install_pq_nginx     || return 1
    _selfmask_deploy_site          || return 1
    if [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "selfsigned" ]; then
        _selfmask_generate_selfsigned_cert || return 1
    else
        _selfmask_obtain_cert      || { _selfmask_restore_port80_holders; return 1; }
    fi
    _selfmask_configure_nginx      || { _selfmask_restore_port80_holders; return 1; }
    _selfmask_apply_mtproxyl_settings || { _selfmask_restore_port80_holders; return 1; }
    if [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "letsencrypt" ]; then
        _selfmask_setup_renewal || true
        _selfmask_handoff_cert_to_panel || true
    fi
    _selfmask_restore_port80_holders

    echo ""
    log_success "Selfmask настроен"
}

# Поставить только инструменты PQ, без настройки заглушки: проверке домена
# нужен openssl с X25519MLKEM768, а ради неё весь мастер — чересчур.
# Установка из Release. Раньше выходила молча, если что-то уже стояло, —
# и обновиться на свежий релиз можно было только снеся каталог руками.
# Теперь показываем, что стоит и что предлагается, и переспрашиваем.
selfmask_install_pq_tools() {
    check_root

    local _installed=""
    [ -x "$(_selfmask_pq_openssl_bin)" ] && \
        _installed=$("$(_selfmask_pq_openssl_bin)" version 2>/dev/null | awk '{print $2}')

    if _system_openssl_has_pq && [ -z "$_installed" ]; then
        log_success "Уже есть: $(_pq_openssl_source)"
        log_info "Системный OpenSSL умеет PQ сам, своя сборка не обязательна"
        echo ""
        echo -en "  ${BOLD}Всё равно поставить сборку из Release (${SELFMASK_PQ_OPENSSL_VERSION})? [y/N]:${NC} "
        local _a; read_line _a
        [[ "$_a" =~ ^[yY] ]] || { log_info "Оставляем системный"; return 0; }
    elif [ -n "$_installed" ]; then
        log_info "Установлено сейчас: OpenSSL ${_installed}"
        log_info "В Release: OpenSSL ${SELFMASK_PQ_OPENSSL_VERSION} (${SELFMASK_PQ_RELEASE_TAG})"
        if [ "$_installed" = "${SELFMASK_PQ_OPENSSL_VERSION}" ]; then
            log_warn "Версия та же — переустановка заменит файлы теми же самыми"
        fi
        echo ""
        echo -en "  ${BOLD}Скачать и переустановить из Release? [y/N]:${NC} "
        local _a; read_line _a
        [[ "$_a" =~ ^[yY] ]] || { log_info "Оставляем как есть"; return 0; }
    fi

    if ! selfmask_supported_os; then
        log_error "Готовая сборка есть только для Debian/Ubuntu"
        log_info "На других системах поставьте OpenSSL ${SELFMASK_MIN_SYSTEM_OPENSSL}+ средствами дистрибутива"
        return 1
    fi

    # force: без него установка увидела бы уже лежащие файлы и вышла молча.
    _selfmask_install_pq_nginx openssl force || return 1
    log_success "Готово: $(_pq_openssl_source)"
}
