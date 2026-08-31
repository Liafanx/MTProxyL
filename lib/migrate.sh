#!/bin/bash
# MTProxyL — переезд на другой сервер по SSH.
# Прокси блокируют по адресу, и лечится это только сменой сервера. Здесь
# поднимается копия на новой машине: те же порт, домен ссылок, секреты, метка,
# маскировка и обход блокировок. Меняется один адрес — A-запись остаётся за
# владельцем домена.

MIGRATE_REMOTE_SCRIPT="/tmp/mtproxyl-install.sh"

# Разобранная цель: заполняется _mig_parse_target.
_MIG_USER=""; _MIG_HOST=""; _MIG_PORT="22"; _MIG_KEY=""
_MIG_WITH_PANEL="ask"; _MIG_WITH_TGBOT="ask"
_MIG_DRY="false"
# Адрес новой машины: узнаём при осмотре, по нему сверяем A-записи доменов.
_MIG_NEW_IP=""

_mig_parse_target() {
    local _t="${1:-}"
    [ -n "$_t" ] || { log_error "Куда переезжаем: mtproxyl migrate root@1.2.3.4[:порт]"; return 1; }
    _MIG_USER="root"; _MIG_PORT="22"
    case "$_t" in *@*) _MIG_USER="${_t%%@*}"; _t="${_t#*@}" ;; esac
    # Порт отделяем только у IPv4 и имён: у голого IPv6 двоеточий много.
    case "$_t" in
        *:*:*) ;;
        *:*) _MIG_PORT="${_t##*:}"; _t="${_t%:*}" ;;
    esac
    _MIG_HOST="$_t"
    [ -n "$_MIG_HOST" ] || { log_error "Не разобрали адрес сервера"; return 1; }
    validate_port "$_MIG_PORT" || { log_error "Порт SSH: 1..65535"; return 1; }
    return 0
}

_mig_ssh_opts() {
    local -a _o=(-p "$_MIG_PORT" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
    [ -n "$_MIG_KEY" ] && _o+=(-i "$_MIG_KEY")
    printf '%s\n' "${_o[@]}"
}

_mig_ssh() {
    local -a _o=(); local _l
    while IFS= read -r _l; do _o+=("$_l"); done < <(_mig_ssh_opts)
    ssh "${_o[@]}" "${_MIG_USER}@${_MIG_HOST}" "$@"
}

# scp хочет порт заглавной -P, а квадратные скобки нужны только IPv6.
_mig_scp() {
    local _src="$1" _dst="$2"
    local -a _o=(-P "$_MIG_PORT" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
    [ -n "$_MIG_KEY" ] && _o+=(-i "$_MIG_KEY")
    local _h="$_MIG_HOST"
    case "$_h" in *:*:*) _h="[${_h}]" ;; esac
    scp -q "${_o[@]}" "$_src" "${_MIG_USER}@${_h}:${_dst}"
}

# Ключ хоста сменился. После переустановки системы на том же адресе это норма,
# но выглядит ровно как подмена сервера — решает человек, молча не чиним.
_mig_host_key_changed() {
    local -a _o=(); local _l
    while IFS= read -r _l; do _o+=("$_l"); done < <(_mig_ssh_opts)
    local _out
    _out=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "${_o[@]}" \
        "${_MIG_USER}@${_MIG_HOST}" true 2>&1)
    case "$_out" in
        *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*) return 0 ;;
    esac
    return 1
}

# Запись в known_hosts у нестандартного порта хранится как [хост]:порт.
_mig_forget_host_key() {
    ssh-keygen -R "$_MIG_HOST" >/dev/null 2>&1 || true
    [ "$_MIG_PORT" = "22" ] || ssh-keygen -R "[${_MIG_HOST}]:${_MIG_PORT}" >/dev/null 2>&1 || true
}

_mig_new_host_fingerprint() {
    ssh-keyscan -p "$_MIG_PORT" -t ed25519 "$_MIG_HOST" 2>/dev/null \
        | ssh-keygen -lf - 2>/dev/null | head -1
}

_mig_handle_host_key_change() {
    _mig_host_key_changed || return 0

    echo ""
    log_warn "Ключ хоста ${_MIG_HOST} не совпадает с запомненным"
    echo -e "  ${DIM}Так бывает, когда на том же адресе переустановили систему —${NC}"
    echo -e "  ${DIM}новая система генерирует свои ключи. Точно так же выглядит и${NC}"
    echo -e "  ${DIM}подмена сервера: если систему вы не переставляли — остановитесь.${NC}"
    local _fp; _fp=$(_mig_new_host_fingerprint)
    [ -n "$_fp" ] && echo -e "  ${DIM}Отпечаток, который отдаёт сервер сейчас:${NC} ${_fp}"
    echo ""

    if [ "${MTPROXYL_NONINTERACTIVE:-false}" = "true" ]; then
        log_error "Забыть старый ключ и повторить: ssh-keygen -R ${_MIG_HOST}"
        return 1
    fi
    echo -en "  ${BOLD}Систему на ${_MIG_HOST} переставляли — забыть старый ключ? [y/N]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[yY] ]] || {
        log_error "Оставили как есть. Разберитесь с ключом хоста и повторите переезд"
        log_info "Забыть вручную: ssh-keygen -R ${_MIG_HOST}"
        return 1
    }
    _mig_forget_host_key
    log_success "Старый ключ хоста забыт — новый запомним при подключении"
    return 0
}

# Пароли мы не храним и не подставляем: связь только по ключу. Если ключа нет,
# зовём ssh-copy-id — пароль вводит хозяин сервера и он никуда не попадает.
_mig_ensure_auth() {
    command -v ssh >/dev/null 2>&1 || { log_error "На этом сервере нет ssh — поставьте openssh-client"; return 1; }
    command -v scp >/dev/null 2>&1 || { log_error "На этом сервере нет scp — поставьте openssh-client"; return 1; }

    local -a _o=(); local _l
    while IFS= read -r _l; do _o+=("$_l"); done < <(_mig_ssh_opts)
    if ssh -o BatchMode=yes "${_o[@]}" "${_MIG_USER}@${_MIG_HOST}" true 2>/dev/null; then
        log_success "SSH: вход по ключу работает"
        return 0
    fi

    # Сначала ключ хоста: пока он не сойдётся, не сработает ни вход по ключу,
    # ни ssh-copy-id, и оба соврут, что дело в правах.
    _mig_handle_host_key_change || return 1
    if ssh -o BatchMode=yes "${_o[@]}" "${_MIG_USER}@${_MIG_HOST}" true 2>/dev/null; then
        log_success "SSH: вход по ключу работает"
        return 0
    fi

    log_warn "По ключу войти не вышло"
    if [ "${MTPROXYL_NONINTERACTIVE:-false}" = "true" ]; then
        log_error "Настройте вход по ключу и повторите: ssh-copy-id -p ${_MIG_PORT} ${_MIG_USER}@${_MIG_HOST}"
        return 1
    fi
    command -v ssh-copy-id >/dev/null 2>&1 || {
        log_error "Настройте вход по ключу: ssh-copy-id -p ${_MIG_PORT} ${_MIG_USER}@${_MIG_HOST}"
        return 1
    }
    echo ""
    echo -e "  ${DIM}Скопируем ваш публичный ключ на новый сервер. Пароль спросит${NC}"
    echo -e "  ${DIM}сам ssh-copy-id — MTProxyL его не видит и не сохраняет.${NC}"
    echo -en "  ${BOLD}Скопировать ключ? [Y/n]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[nN] ]] && { log_error "Без входа по ключу переезд невозможен"; return 1; }

    [ -f "${HOME}/.ssh/id_ed25519.pub" ] || [ -f "${HOME}/.ssh/id_rsa.pub" ] || {
        log_info "Ключа нет — создаём"
        ssh-keygen -t ed25519 -N "" -f "${HOME}/.ssh/id_ed25519" >/dev/null || return 1
    }
    # Свои опции отдаём и ssh-copy-id: со своими умолчаниями он спотыкался
    # о ключ хоста там, где обычное подключение уже проходило.
    ssh-copy-id -p "$_MIG_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
        ${_MIG_KEY:+-i "${_MIG_KEY}.pub"} "${_MIG_USER}@${_MIG_HOST}" || return 1
    # Пароль набирали вслепую и, возможно, не с первого раза: лишние Enter
    # иначе ответят за пользователя на ближайшие вопросы.
    drain_tty_input
    ssh -o BatchMode=yes "${_o[@]}" "${_MIG_USER}@${_MIG_HOST}" true 2>/dev/null || {
        log_error "Ключ скопирован, но вход всё равно не работает"
        return 1
    }
    log_success "SSH: вход по ключу работает"
}

_mig_check_local() {
    if [ "${MTPROXYL_MODE:-manager}" != "manager" ]; then
        log_error "Переезд доступен только в режиме менеджера"
        log_info "В реаниматоре цель чужая: её конфиг, движок и данные не наши, копировать нечего"
        return 1
    fi
    [ -f "$SETTINGS_FILE" ] || { log_error "Настройки не найдены — переносить нечего"; return 1; }
    if _superexpert_active 2>/dev/null; then
        log_info "Включён режим супер эксперта — ваш конфиг движка поедет вместе с остальным"
    fi
    if [ -f "${NGINX_CUSTOM_FILE:-/opt/mtproxyl/nginx-custom.conf}" ]; then
        log_info "Пользовательский конфиг nginx поедет вместе с остальным"
    fi
    return 0
}

# Заранее смотрим, куда едем: чужая установка и занятый порт — самые частые
# сюрпризы, и узнавать о них после запуска установщика поздно.
_mig_check_remote() {
    log_info "Проверяем новый сервер..."
    local _probe
    _probe=$(_mig_ssh 'printf "%s|%s|%s|%s\n" \
        "$(id -u)" \
        "$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")" \
        "$([ -f /opt/mtproxyl/settings.conf ] && echo yes || echo no)" \
        "$(uname -m)"' 2>/dev/null) || {
        log_error "Не удалось выполнить команду на ${_MIG_HOST}"
        return 1
    }
    local _uid _os _has _arch; IFS='|' read -r _uid _os _has _arch <<< "$_probe"
    if [ "$_uid" != "0" ]; then
        log_error "На новом сервере нужен root: подключайтесь как root@${_MIG_HOST}"
        return 1
    fi
    log_success "Новый сервер: ${_os} ${_arch}, root есть"
    if [ "$_has" = "yes" ]; then
        log_warn "Там уже стоит MTProxyL — установка пойдёт поверх"
    fi
    # Бинарник движка собирают не под всё: под чужую архитектуру ехать незачем.
    if engine_is_binary; then
        case "$_arch" in
            x86_64|amd64|aarch64|arm64) ;;
            *)
                log_error "Движок-бинарник под ${_arch} не собирают — сборки telemt есть для x86_64 и aarch64"
                log_info "Переезжайте на Docker-движок: сначала здесь mtproxyl engine backend docker"
                return 1 ;;
        esac
    fi

    # grep -c печатает 0 и выходит с кодом 1, так что «|| echo 0» дописывал
    # второй ноль и сравнение падало на «0\n0». Берём последнюю строку и цифры.
    local _busy
    _busy=$(_mig_ssh "ss -ltn 2>/dev/null | awk '{print \$4}' | grep -c ':${PROXY_PORT}\$' || true" \
        </dev/null 2>/dev/null | tail -1 | tr -cd '0-9')
    [ -n "$_busy" ] || _busy=0
    if [ "$_busy" -gt 0 ]; then
        log_warn "Порт ${PROXY_PORT} на новом сервере уже занят — прокси может не подняться"
    fi

    # Адрес новой машины нужен до установки: по нему сверяем A-записи доменов.
    _MIG_NEW_IP=$(_mig_ssh "curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
        || ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 \
           | grep -vE '^(172\\.(1[6-9]|2[0-9]|3[01])\\.|169\\.254\\.)' | head -1" \
        </dev/null 2>/dev/null | tr -d '\r\n')
    [ -n "$_MIG_NEW_IP" ] && log_success "Адрес новой машины: ${_MIG_NEW_IP}"
    return 0
}

# Куда указывает A-запись домена сейчас. Пусто — не разрешился вовсе.
_mig_resolve_a() {
    local _d="$1" _out=""
    if command -v getent >/dev/null 2>&1; then
        _out=$(getent ahostsv4 "$_d" 2>/dev/null | awk '{print $1}' | head -1)
    fi
    [ -n "$_out" ] || _out=$(dig +short A "$_d" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    printf '%s' "$_out"
}

# 0 — запись уже смотрит на новую машину, 1 — на старую, 2 — проверить нечем.
_mig_dns_ready() {
    local _d="$1"
    [ -n "$_d" ] && [ -n "$_MIG_NEW_IP" ] || return 2
    local _a; _a=$(_mig_resolve_a "$_d")
    [ -n "$_a" ] || return 2
    [ "$_a" = "$_MIG_NEW_IP" ]
}

# Домен, на который панель выпускает сертификат сама (acme_domain в конфиге).
_mig_panel_acme_domain() {
    local _cfg="/etc/mtproxyl-panel/config.toml"
    [ -f "$_cfg" ] || return 1
    grep -oE '^[[:space:]]*acme_domain[[:space:]]*=[[:space:]]*"[^"]+"' "$_cfg" 2>/dev/null \
        | head -1 | sed 's/.*"\([^"]*\)".*/\1/'
}

# Всё, что упрётся в непереведённую A-запись, — одним списком и до начала работ:
# сертификат выпускается в момент установки, и «потом поправлю» тут не работает.
_mig_warn_dns() {
    local _blocked=0

    load_selfmask_settings 2>/dev/null || true
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] && [ -n "${SELFMASK_DOMAIN:-}" ] \
       && [ "${SELFMASK_CERT_MODE:-letsencrypt}" != "selfsigned" ]; then
        _mig_dns_ready "$SELFMASK_DOMAIN"
        case $? in
            0) log_success "DNS ${SELFMASK_DOMAIN} уже смотрит на новую машину — Selfmask поднимется сразу" ;;
            1) log_warn "Selfmask: A-запись ${SELFMASK_DOMAIN} ведёт на $(_mig_resolve_a "$SELFMASK_DOMAIN"), а не на ${_MIG_NEW_IP}"; _blocked=1 ;;
            2) log_warn "Selfmask: A-запись ${SELFMASK_DOMAIN} проверить не вышло"; _blocked=1 ;;
        esac
    fi

    if web_is_enabled 2>/dev/null; then
        local _web_domain; _web_domain=$(web_domain 2>/dev/null)
        if [ -n "$_web_domain" ] && { [ "${SELFMASK_ENABLED:-false}" != "true" ] \
           || [ "$_web_domain" != "${SELFMASK_DOMAIN:-}" ]; }; then
            _mig_dns_ready "$_web_domain"
            case $? in
                0) log_success "DNS ${_web_domain} уже смотрит на новую машину — WEB поднимется сразу" ;;
                1) log_warn "WEB: A-запись ${_web_domain} ведёт на $(_mig_resolve_a "$_web_domain"), а не на ${_MIG_NEW_IP}"; _blocked=1 ;;
                2) log_warn "WEB: A-запись ${_web_domain} проверить не вышло"; _blocked=1 ;;
            esac
        fi
    fi

    local _acme; _acme=$(_mig_panel_acme_domain 2>/dev/null)
    if [ -n "$_acme" ] && [ "$_MIG_WITH_PANEL" != "no" ]; then
        _mig_dns_ready "$_acme"
        case $? in
            0) log_success "DNS ${_acme} уже смотрит на новую машину — панель выпустит сертификат сама" ;;
            *) log_warn "Панель: A-запись ${_acme} ещё не на новой машине — сертификат не выпустится"; _blocked=1 ;;
        esac
    fi

    if [ -n "${CUSTOM_IP:-}" ] && ! validate_ip_literal "${CUSTOM_IP}"; then
        _mig_dns_ready "$CUSTOM_IP"
        case $? in
            0) log_success "DNS ${CUSTOM_IP} уже смотрит на новую машину — ссылки не изменятся" ;;
            1) log_warn "Ссылки: A-запись ${CUSTOM_IP} ещё ведёт на старую машину — клиенты пойдут туда же" ;;
            2) log_warn "Ссылки: A-запись ${CUSTOM_IP} проверить не вышло" ;;
        esac
    fi

    [ "$_blocked" -eq 0 ] && return 0
    echo ""
    echo -e "  ${YELLOW}${BOLD}Сертификат Let's Encrypt выпускается в момент установки.${NC}"
    echo -e "  ${DIM}Пока A-запись смотрит на старый сервер, проверка домена уйдёт${NC}"
    echo -e "  ${DIM}туда же, и на новой машине не поднимутся WEB, Selfmask или HTTPS${NC}"
    echo -e "  ${DIM}панели. Переезд при этом пройдёт — настройки и секреты${NC}"
    echo -e "  ${DIM}встанут, но их придётся доделать вручную.${NC}"
    echo ""
    echo -e "  ${BOLD}Как лучше:${NC} сначала переведите A-запись на ${_MIG_NEW_IP:-новый адрес},"
    echo -e "  дождитесь, пока она разойдётся, и повторите переезд."
    echo -e "  ${DIM}Доделать потом: mtproxyl web enable, mtproxyl selfmask setup, mtproxyl panel cert <домен>${NC}"
    return 1
}

# Аргументы установки собираем из своих же настроек: что здесь работает, то
# и должно заработать там.
_mig_build_args() {
    local -a _a=(--mode manager --force)
    _a+=(--proxy-mode "${PROXY_MODE:-mtproto}")
    # Движок переезжает тем же носителем: у кого бинарник — тому и версию,
    # чтобы на новой машине встало ровно то же, что работало на старой.
    if [ "$(engine_backend)" = "binary" ]; then
        _a+=(--engine binary)
        local _ev; _ev=$(binengine_version)
        [ -n "$_ev" ] && [ "$_ev" != "unknown" ] && _a+=(--engine-version "$_ev")
    else
        _a+=(--engine docker)
    fi
    _a+=(--port "${PROXY_PORT:-443}")
    _a+=(--metrics-port "${PROXY_METRICS_PORT:-9090}")
    _a+=(--api-port "${PROXY_API_PORT:-9091}")
    _a+=(--sni "${PROXY_DOMAIN:-autoscout24.ru}")
    _a+=(--sni-policy "${UNKNOWN_SNI_ACTION:-mask}")
    [ "${MASKING_ENABLED:-true}" = "false" ] && _a+=(--mask off) || _a+=(--mask on)
    [ -n "${AD_TAG:-}" ] && _a+=(--ad-tag "$AD_TAG")
    # Лимиты CPU и памяти не переносим: их подбирали под старую машину, а docker
    # на новой откажется запускать контейнер, если ядер там меньше. У бинарника
    # таких лимитов нет вовсе.

    # Домен в ссылках переезжает как есть, литеральный IP — нет: он привязан
    # к старой машине, и на новой ссылки по нему вели бы в никуда.
    if [ -n "${CUSTOM_IP:-}" ] && ! validate_ip_literal "${CUSTOM_IP}"; then
        _a+=(--host "$CUSTOM_IP")
    fi

    local _i
    for _i in "${!SECRETS_LABELS[@]}"; do
        _a+=(--secret "${SECRETS_LABELS[$_i]}:${SECRETS_KEYS[$_i]}")
    done

    load_nft_settings 2>/dev/null || true
    if zapret2_in_effect; then
        _a+=(--zapret2 yes)
    else
        _a+=(--zapret2 no)
        # NFT_MODE осмыслен только при включённом лимитере: по умолчанию там
        # «classic», и без этой проверки переезд ставил бы лимитер тем, у кого
        # его не было.
        if [ "${NFT_ENABLED:-false}" != "true" ]; then
            _a+=(--syn-limiter off)
        else
            case "${NFT_MODE:-}" in
                smart)   _a+=(--syn-limiter meko) ;;
                classic) _a+=(--syn-limiter classic) ;;
                *)       _a+=(--syn-limiter off) ;;
            esac
        fi
        case "${NFT_OTHER_ACTION:-}" in
            reject) _a+=(--limiter-action reject) ;;
            drop)   _a+=(--limiter-action drop) ;;
            icmp-host-unreachable) _a+=(--limiter-action icmp) ;;
        esac
    fi
    [ "${MEKO_OPT_APPLIED:-false}" = "true" ] && _a+=(--meko yes) || _a+=(--meko no)

    load_selfmask_settings 2>/dev/null || true
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] && [ -n "${SELFMASK_DOMAIN:-}" ]; then
        _a+=(--selfmask "$SELFMASK_DOMAIN")
        _a+=(--selfmask-cert "${SELFMASK_CERT_MODE:-letsencrypt}")
        [ -n "${SELFMASK_CERT_EMAIL:-}" ] && _a+=(--selfmask-email "$SELFMASK_CERT_EMAIL")
        [ -n "${SELFMASK_SITE_SOURCE:-}" ] && _a+=(--selfmask-template "$SELFMASK_SITE_SOURCE")
        [ -n "${SELFMASK_NGINX_BACKEND_PORT:-}" ] && _a+=(--selfmask-backend-port "$SELFMASK_NGINX_BACKEND_PORT")
    fi
    if web_is_enabled 2>/dev/null; then
        _a+=(--web yes --web-layout "${WEB_LAYOUT:-shared}")
        _a+=(--web-carrier "${WEB_CARRIER:-websocket}")
        _a+=(--web-secret-mode "${WEB_SECRET_MODE:-dd}")
        [ -n "${WEB_DOMAIN:-}" ] && _a+=(--web-domain "$WEB_DOMAIN")
        { web_is_only_mode || [ "${WEB_LAYOUT:-shared}" = "split" ]; } \
            && _a+=(--web-port "${WEB_PUBLIC_PORT:-443}")
        if [ "${SELFMASK_ENABLED:-false}" != "true" ]; then
            [ -n "${SELFMASK_CERT_EMAIL:-}" ] && _a+=(--selfmask-email "$SELFMASK_CERT_EMAIL")
            [ -n "${SELFMASK_SITE_SOURCE:-}" ] && _a+=(--selfmask-template "$SELFMASK_SITE_SOURCE")
        fi
    fi

    printf '%s\n' "${_a[@]}"
}

# Одна строка для ssh: аргументы кавычим, иначе домен с точкой или метка с
# дефисом на той стороне разъедутся по словам.
_mig_quote() {
    local _s
    for _s in "$@"; do printf "%q " "$_s"; done
}

# Лимиты, квоты, сроки и заметки аргументами не передашь — везём файл целиком.
# Снимок делается до установки на той стороне: при переезде «на себя» файл к
# этому моменту уже переписан установщиком, и везти было бы нечего.
_MIG_SECRETS_SNAPSHOT=""

_MIG_SUPEREXPERT_SNAPSHOT=""
_MIG_NGINX_CUSTOM_SNAPSHOT=""
_MIG_NGINX_CUSTOM_WAS_ACTIVE="false"

_mig_snapshot_superexpert() {
    _superexpert_active 2>/dev/null || return 0
    [ -f "$SUPEREXPERT_FILE" ] || return 0
    _MIG_SUPEREXPERT_SNAPSHOT=$(mktemp /tmp/.mtproxyl-migrate-superexpert.XXXXXX) || { _MIG_SUPEREXPERT_SNAPSHOT=""; return 0; }
    chmod 600 "$_MIG_SUPEREXPERT_SNAPSHOT"
    cat "$SUPEREXPERT_FILE" > "$_MIG_SUPEREXPERT_SNAPSHOT"
}

# Свой config.toml везём как есть и включаем режим на новой машине. Выключить
# его там можно в любой момент: файл при этом не удаляется, а MTProxyL
# возвращается к своему сгенерированному конфигу из перенесённых настроек.
_mig_push_superexpert() {
    [ -n "$_MIG_SUPEREXPERT_SNAPSHOT" ] && [ -f "$_MIG_SUPEREXPERT_SNAPSHOT" ] || return 0
    log_info "Переносим конфиг режима супер эксперта..."
    if ! _mig_scp "$_MIG_SUPEREXPERT_SNAPSHOT" "/tmp/mtproxyl-superexpert.toml"; then
        log_warn "Конфиг супер эксперта не доехал — режим на новой машине не включаем"
        return 0
    fi
    if ! _mig_ssh "install -m 600 -o root -g root /tmp/mtproxyl-superexpert.toml ${SUPEREXPERT_FILE} && rm -f /tmp/mtproxyl-superexpert.toml" \
        </dev/null >/dev/null 2>&1; then
        log_warn "Не удалось положить конфиг супер эксперта"
        return 0
    fi
    if _mig_ssh "MTPROXYL_ASSUME_YES=1 mtproxyl superexpert on" </dev/null >/dev/null 2>&1; then
        log_success "Режим супер эксперта включён, конфиг ваш"
        log_warn "Проверьте в нём адреса: старый IP там останется как есть"
        _mig_ssh "mtproxyl restart" </dev/null >/dev/null 2>&1 || true
    else
        log_warn "Конфиг положили, но режим не включился — на новом сервере: mtproxyl superexpert on"
    fi
}

_mig_snapshot_nginx_custom() {
    [ -f "$NGINX_CUSTOM_FILE" ] || return 0
    _MIG_NGINX_CUSTOM_SNAPSHOT=$(mktemp /tmp/.mtproxyl-migrate-nginx.XXXXXX) || {
        _MIG_NGINX_CUSTOM_SNAPSHOT=""
        return 0
    }
    chmod 600 "$_MIG_NGINX_CUSTOM_SNAPSHOT"
    cat "$NGINX_CUSTOM_FILE" > "$_MIG_NGINX_CUSTOM_SNAPSHOT"
    nginx_custom_active 2>/dev/null && _MIG_NGINX_CUSTOM_WAS_ACTIVE="true"
}

_mig_push_nginx_custom() {
    [ -n "$_MIG_NGINX_CUSTOM_SNAPSHOT" ] && [ -f "$_MIG_NGINX_CUSTOM_SNAPSHOT" ] || return 0
    log_info "Переносим пользовательский конфиг nginx..."
    if ! _mig_scp "$_MIG_NGINX_CUSTOM_SNAPSHOT" "/tmp/mtproxyl-nginx-custom.conf"; then
        log_warn "Пользовательский конфиг nginx не доехал"
        return 0
    fi
    if ! _mig_ssh "install -m 600 -o root -g root /tmp/mtproxyl-nginx-custom.conf ${NGINX_CUSTOM_FILE} && rm -f /tmp/mtproxyl-nginx-custom.conf" \
        </dev/null >/dev/null 2>&1; then
        log_warn "Не удалось положить пользовательский конфиг nginx"
        return 0
    fi
    if [ "$_MIG_NGINX_CUSTOM_WAS_ACTIVE" = "true" ]; then
        if _mig_ssh "MTPROXYL_ASSUME_YES=1 mtproxyl selfmask nginx-config on" </dev/null >/dev/null 2>&1; then
            log_success "Пользовательский конфиг nginx включён"
            log_warn "Проверьте в нём домены, адреса и пути на новом сервере"
        else
            log_warn "Конфиг перенесён, но режим не включился — проверьте nginx -t на новом сервере"
        fi
    else
        log_success "Пользовательский конфиг nginx перенесён и оставлен выключенным"
    fi
}

_mig_snapshot_secrets() {
    [ -f "$SECRETS_FILE" ] || return 0
    _MIG_SECRETS_SNAPSHOT=$(mktemp /tmp/.mtproxyl-migrate-secrets.XXXXXX) || { _MIG_SECRETS_SNAPSHOT=""; return 0; }
    chmod 600 "$_MIG_SECRETS_SNAPSHOT"
    cat "$SECRETS_FILE" > "$_MIG_SECRETS_SNAPSHOT"
}

_mig_push_secrets() {
    [ -n "$_MIG_SECRETS_SNAPSHOT" ] && [ -f "$_MIG_SECRETS_SNAPSHOT" ] || return 0
    log_info "Переносим лимиты и квоты пользователей..."
    if ! _mig_scp "$_MIG_SECRETS_SNAPSHOT" "/tmp/mtproxyl-secrets.conf"; then
        log_warn "secrets.conf не доехал — секреты на месте, лимиты и квоты пустые"
        return 0
    fi
    if ! _mig_ssh "install -m 600 -o root -g root /tmp/mtproxyl-secrets.conf ${SECRETS_FILE} && rm -f /tmp/mtproxyl-secrets.conf" </dev/null >/dev/null 2>&1; then
        log_warn "Не удалось положить secrets.conf на новом сервере"
        return 0
    fi
    log_success "Лимиты, квоты, сроки и заметки перенесены"
    # Перезапуск — отдельно: если прокси там не поднялся по своей причине,
    # это не повод объявлять непереехавшими уже разложенные секреты.
    _mig_ssh "mtproxyl restart" </dev/null >/dev/null 2>&1 || \
        log_warn "Перезапустить прокси на новом сервере не вышло — проверьте там mtproxyl status"
}

_mig_push_panel() {
    panel_installed 2>/dev/null || return 0
    log_info "Переносим панель..."
    # Конфиг едет первым: установщик панели видит его и мастер настройки
    # пропускает — логин, хеш пароля и jwt_secret остаются прежними.
    local _cfg="/etc/mtproxyl-panel/config.toml"
    [ -f "$_cfg" ] || { log_warn "Конфиг панели не найден — на новом сервере поставьте её сами"; return 0; }
    _mig_scp "$_cfg" "/tmp/mtproxyl-panel-config.toml" || { log_warn "Конфиг панели не доехал"; return 0; }
    _mig_ssh "mkdir -p /etc/mtproxyl-panel && install -m 600 /tmp/mtproxyl-panel-config.toml ${_cfg} && rm -f /tmp/mtproxyl-panel-config.toml" \
        || { log_warn "Не удалось положить конфиг панели"; return 0; }
    # MTPROXYL_NONINTERACTIVE — чтобы установщик не начал сам выпускать
    # сертификат: отвечать на той стороне некому, а A-запись ещё не переехала.
    if ! _mig_ssh "MTPROXYL_NONINTERACTIVE=true mtproxyl panel install" </dev/null; then
        log_warn "Панель не установилась — поставьте на новом сервере: mtproxyl panel install"
        return 0
    fi
    log_success "Панель установлена, пароль администратора прежний"
    # Свой сертификат панель делает самоподписанным, и её адрес снова
    # становится голым IP. Если Selfmask на новой машине уже поднялся —
    # отдаём ей тот же сертификат, что и раньше.
    if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
        _mig_ssh "mtproxyl selfmask panel-cert" </dev/null 2>&1 | grep -aE '\[✓\]|\[!\]|\[i\]' || true
    fi
}

_mig_push_tgbot() {
    tgbot_installed 2>/dev/null || return 0
    log_info "Переносим телеграм-бота..."
    local _token _first
    _token=$(jq -r '.token // empty' "$TGBOT_CONFIG" 2>/dev/null)
    _first=$(jq -r '(.admins // []) | .[0] // empty' "$TGBOT_CONFIG" 2>/dev/null)
    if [ -z "$_token" ] || [ -z "$_first" ]; then
        log_warn "Токен или админов бота прочитать не вышло — поставьте бота на новом сервере вручную"
        return 0
    fi
    # С сервера в РФ до Telegram часто нет доступа. Там бот не заработает, а
    # установка растянется на минуты и будет выглядеть зависшей.
    local _code
    _code=$(_mig_ssh "curl -sS --max-time 15 -o /dev/null -w '%{http_code}' https://api.telegram.org 2>/dev/null || true" \
        </dev/null 2>/dev/null | tr -cd '0-9' | tail -c 3)
    if [ "${_code:-000}" = "000" ]; then
        log_warn "С нового сервера не видно api.telegram.org — бота не ставим"
        log_info "Там он всё равно не запустится: сначала дайте серверу доступ к Telegram"
        log_info "Когда появится: mtproxyl tgbot install --token <токен> --admin <id>"
        return 0
    fi
    # Сборка venv на слабой машине идёт минутами; ограничение спасает от
    # переезда, который висит без конца.
    if ! _mig_ssh "timeout 900 mtproxyl tgbot install --token $(_mig_quote "$_token") --admin $(_mig_quote "$_first")" </dev/null; then
        log_warn "Бот не установился — поставьте на новом сервере: mtproxyl tgbot install"
        return 0
    fi
    # Остальные админы, уведомления и интервалы живут в том же файле — везём
    # его целиком, добавлять по одному нечего.
    if _mig_scp "$TGBOT_CONFIG" "/tmp/mtproxyl-tgbot-config.json" && \
       _mig_ssh "install -m 600 -o ${TGBOT_USER} -g ${TGBOT_USER} /tmp/mtproxyl-tgbot-config.json ${TGBOT_CONFIG} && rm -f /tmp/mtproxyl-tgbot-config.json && systemctl restart ${TGBOT_SERVICE}" </dev/null >/dev/null 2>&1; then
        log_success "Бот установлен: токен, админы и уведомления прежние"
    else
        log_success "Бот установлен с прежним токеном"
        log_warn "Настройки уведомлений не доехали — проверьте меню бота на новом сервере"
    fi
    log_warn "Два бота на одном токене не уживутся — старого остановите"
}

# Панель и бот — по желанию, по умолчанию да. Флаги --no-panel/--no-tgbot
# уже ответили, второй раз не спрашиваем.
_mig_ask_extras() {
    [ "${MTPROXYL_NONINTERACTIVE:-false}" = "true" ] && return 0
    [ "$_MIG_DRY" = "true" ] && return 0

    drain_tty_input
    local _yn
    if panel_installed 2>/dev/null && [ "$_MIG_WITH_PANEL" = "ask" ]; then
        echo ""
        echo -e "  ${DIM}Панель поедет вместе с конфигом: логин, пароль и jwt_secret${NC}"
        echo -e "  ${DIM}останутся прежними, мастер настройки там не запустится.${NC}"
        if [ "${GITHUB_BRANCH:-main}" != "main" ]; then
            echo -e "  ${YELLOW}Ветка ${GITHUB_BRANCH} — панель будет собираться из исходников${NC}"
            echo -e "  ${DIM}в Docker: несколько минут и заметная нагрузка на новую машину.${NC}"
        fi
        echo -en "  ${BOLD}Переносить панель? [Y/n]:${NC} "
        read_line _yn
        [[ "$_yn" =~ ^[nN] ]] && _MIG_WITH_PANEL="no" || _MIG_WITH_PANEL="yes"
    fi

    if tgbot_installed 2>/dev/null && [ "$_MIG_WITH_TGBOT" = "ask" ]; then
        echo ""
        echo -e "  ${DIM}Бот поедет с прежним токеном и админами. Два бота на одном${NC}"
        echo -e "  ${DIM}токене не уживутся — старого придётся остановить.${NC}"
        echo -en "  ${BOLD}Переносить телеграм-бота? [Y/n]:${NC} "
        read_line _yn
        [[ "$_yn" =~ ^[nN] ]] && _MIG_WITH_TGBOT="no" || _MIG_WITH_TGBOT="yes"
    fi
    return 0
}

migrate_run() {
    check_root
    _mig_check_local || return 1
    _mig_ensure_auth || return 1
    _mig_check_remote || return 1
    _mig_snapshot_secrets
    _mig_snapshot_superexpert
    _mig_snapshot_nginx_custom

    _mig_ask_extras

    local -a _args=(); local _l
    while IFS= read -r _l; do _args+=("$_l"); done < <(_mig_build_args)

    echo ""
    draw_header "ЧТО ПОЕДЕТ"
    echo ""
    echo -e "  ${BOLD}Куда:${NC}       ${_MIG_USER}@${_MIG_HOST}:${_MIG_PORT}${_MIG_NEW_IP:+ ${DIM}(${_MIG_NEW_IP})${NC}}"
    echo -e "  ${BOLD}Движок:${NC}     $(engine_backend_title)$(engine_is_binary && echo ", v$(binengine_version)")"
    echo -e "  ${BOLD}Порт:${NC}       ${PROXY_PORT:-443}"
    echo -e "  ${BOLD}Домен SNI:${NC}  ${PROXY_DOMAIN:-?}"
    echo -e "  ${BOLD}В ссылках:${NC}  $(if [ -n "${CUSTOM_IP:-}" ] && ! validate_ip_literal "${CUSTOM_IP}"; then echo "${CUSTOM_IP}"; else echo "адрес нового сервера"; fi)"
    echo -e "  ${BOLD}Секретов:${NC}   ${#SECRETS_LABELS[@]}"
    echo -e "  ${BOLD}Метка:${NC}      ${AD_TAG:-${DIM}нет${NC}}"
    echo -e "  ${BOLD}Selfmask:${NC}   $([ "${SELFMASK_ENABLED:-false}" = "true" ] && echo "${SELFMASK_DOMAIN} (${SELFMASK_CERT_MODE:-letsencrypt})" || echo "${DIM}выключен${NC}")"
    _superexpert_active 2>/dev/null && \
        echo -e "  ${BOLD}Супер эксперт:${NC} свой конфиг движка едет вместе с остальным"
    [ -f "$NGINX_CUSTOM_FILE" ] && \
        echo -e "  ${BOLD}Свой nginx:${NC}  конфиг едет вместе с остальным$([ "$_MIG_NGINX_CUSTOM_WAS_ACTIVE" = "true" ] || echo " ${DIM}(выключен)${NC}")"
    echo -e "  ${BOLD}Панель:${NC}     $(if ! panel_installed 2>/dev/null; then echo "${DIM}не установлена${NC}"; elif [ "$_MIG_WITH_PANEL" = "no" ]; then echo "${DIM}пропускаем${NC}"; else echo "переносим"; fi)"
    echo -e "  ${BOLD}Бот:${NC}        $(if ! tgbot_installed 2>/dev/null; then echo "${DIM}не установлен${NC}"; elif [ "$_MIG_WITH_TGBOT" = "no" ]; then echo "${DIM}пропускаем${NC}"; else echo "переносим"; fi)"
    echo ""
    if ! engine_is_binary; then
        echo -e "  ${DIM}Лимиты CPU и памяти контейнера не переносим: на новой машине${NC}"
        echo -e "  ${DIM}ядер может быть меньше, и docker откажется его запускать.${NC}"
    fi
    echo ""

    local _dns_ok="true"
    _mig_warn_dns || _dns_ok="false"
    echo ""

    if [ "$_MIG_DRY" = "true" ]; then
        echo -e "  ${BOLD}Команда установки:${NC}"
        echo -e "  ${DIM}mtproxyl install $(_mig_quote "${_args[@]}")${NC}"
        echo ""
        log_info "Пробный прогон — на новом сервере ничего не менялось"
        return 0
    fi

    if [ "${MTPROXYL_NONINTERACTIVE:-false}" != "true" ]; then
        if [ "$_dns_ok" = "false" ]; then
            echo -en "  ${BOLD}Всё равно переезжать сейчас, без сертификата? [y/N]:${NC} "
        else
            echo -en "  ${BOLD}Начинаем? [y/N]:${NC} "
        fi
        local _yn; read_line _yn
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
    fi

    echo ""
    draw_header "УСТАНОВКА НА НОВОМ СЕРВЕРЕ"
    echo ""
    if engine_is_binary; then
        log_info "Это займёт пару минут: пакеты и бинарник движка, Docker не нужен"
    else
        log_info "Это займёт несколько минут: пакеты, docker, образ движка"
    fi

    local _branch="${GITHUB_BRANCH:-main}"
    local _url="https://raw.githubusercontent.com/${GITHUB_REPO:-Liafanx/MTProxyL}/${_branch}/install.sh"
    if ! _mig_ssh "curl -fsSL $(_mig_quote "$_url") -o ${MIGRATE_REMOTE_SCRIPT}" </dev/null; then
        log_error "На новом сервере не скачался установщик"
        log_info "Проверьте там интернет и доступность github.com"
        return 1
    fi
    if ! _mig_ssh "bash ${MIGRATE_REMOTE_SCRIPT} --branch $(_mig_quote "$_branch") -- $(_mig_quote "${_args[@]}")" </dev/null; then
        log_error "Установка на новом сервере не прошла"
        log_info "Зайдите туда и посмотрите: /tmp/mtproxyl-install.log"
        return 1
    fi
    _mig_ssh "rm -f ${MIGRATE_REMOTE_SCRIPT}" </dev/null >/dev/null 2>&1 || true
    log_success "MTProxyL поднят на новом сервере"

    # Установщик может закончиться без ошибки, а контейнер не подняться —
    # молчать об этом нельзя: дальше поедут секреты в неработающий прокси.
    local _alive_cmd="docker ps --filter name=mtproxyl --filter status=running -q | grep -q ."
    local _why_cmd="docker logs mtproxyl"
    if engine_is_binary; then
        _alive_cmd="systemctl is-active --quiet ${ENGINE_SERVICE}"
        _why_cmd="journalctl -u ${ENGINE_SERVICE} -n 50"
    fi
    if ! _mig_ssh "$_alive_cmd" </dev/null >/dev/null 2>&1; then
        log_error "Прокси на новом сервере не запустился"
        log_info "Причину покажет: ssh ${_MIG_USER}@${_MIG_HOST} '${_why_cmd}'"
        log_info "Остальное всё равно перенесём — прокси поднимете там: mtproxyl start"
    fi

    _mig_push_secrets
    _mig_push_nginx_custom
    _mig_push_superexpert

    if [ "$_MIG_WITH_PANEL" != "no" ]; then _mig_push_panel; fi
    if [ "$_MIG_WITH_TGBOT" != "no" ]; then _mig_push_tgbot; fi

    [ -n "$_MIG_SECRETS_SNAPSHOT" ] && rm -f "$_MIG_SECRETS_SNAPSHOT"
    [ -n "$_MIG_SUPEREXPERT_SNAPSHOT" ] && rm -f "$_MIG_SUPEREXPERT_SNAPSHOT"
    [ -n "$_MIG_NGINX_CUSTOM_SNAPSHOT" ] && rm -f "$_MIG_NGINX_CUSTOM_SNAPSHOT"
    _mig_finish
}

_mig_finish() {
    local _new_ip
    # Тот же порядок, что и у самого MTProxyL: IPv4 наружу, потом свой
    # глобальный адрес мимо docker-мостов. hostname -I отдавал первым что попало.
    _new_ip=$(_mig_ssh "curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
        || ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 \
           | grep -vE '^(172\\.(1[6-9]|2[0-9]|3[01])\\.|169\\.254\\.)' | head -1" \
        </dev/null 2>/dev/null | tr -d '\r\n')
    [ -n "$_new_ip" ] || _new_ip="$_MIG_HOST"

    echo ""
    draw_header "ПЕРЕЕЗД ЗАВЕРШЁН"
    echo ""
    echo -e "  ${BOLD}Новый адрес:${NC} ${_new_ip}:${PROXY_PORT:-443}"
    echo ""
    if [ -n "${CUSTOM_IP:-}" ] && ! validate_ip_literal "${CUSTOM_IP}"; then
        echo -e "  ${YELLOW}Переведите A-запись ${CUSTOM_IP} на ${_new_ip}${NC}"
        echo -e "  ${DIM}До этого ссылки будут вести на старый сервер, а Selfmask${NC}"
        echo -e "  ${DIM}с Let's Encrypt не выпустит сертификат.${NC}"
    else
        echo -e "  ${YELLOW}Ссылки изменились: у клиентов адрес был старый${NC}"
        echo -e "  ${DIM}Новые ссылки: ssh на новый сервер и mtproxyl link${NC}"
    fi
    echo ""
    echo -e "  ${DIM}Проверьте там: mtproxyl status, mtproxyl dc${NC}"
    echo ""

    [ "${MTPROXYL_NONINTERACTIVE:-false}" = "true" ] && return 0
    echo -e "  ${BOLD}Старая копия на этом сервере${NC}"
    echo -e "  ${DIM}Пока она жива, два прокси делят один токен бота и одни ссылки.${NC}"
    echo -e "  ${DIM}Удалять стоит после того, как проверите новый сервер.${NC}"
    echo -en "  ${BOLD}Удалить MTProxyL здесь сейчас? [y/N]:${NC} "
    local _yn; read_line _yn
    if [[ "$_yn" =~ ^[yY] ]]; then
        uninstall
    else
        log_info "Оставили. Удалить позже: mtproxyl uninstall"
    fi
}

handle_migrate_command() {
    local _target=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --key)      _MIG_KEY="${2:-}"; shift 2 ;;
            --key=*)    _MIG_KEY="${1#*=}"; shift ;;
            --panel)    _MIG_WITH_PANEL="yes"; shift ;;
            --no-panel) _MIG_WITH_PANEL="no"; shift ;;
            --tgbot|--bot) _MIG_WITH_TGBOT="yes"; shift ;;
            --no-tgbot|--no-bot) _MIG_WITH_TGBOT="no"; shift ;;
            --dry-run)  _MIG_DRY="true"; shift ;;
            -h|--help)
                cat <<'EOF'
  Переезд на другой сервер (только режим менеджера)

    mtproxyl migrate <[пользователь@]хост[:порт]> [параметры]

    --key <файл>     приватный ключ для входа
    --panel          переносить веб-панель, не спрашивая
    --no-panel       не переносить веб-панель
    --tgbot          переносить телеграм-бота, не спрашивая
    --no-tgbot       не переносить телеграм-бота
    --dry-run        показать, что поедет, и ничего не делать

  Переносятся: носитель движка (Docker или бинарник MTProxyL-Telemt той же
  версии), порт, домен ссылок, FakeTLS SNI, секреты с лимитами, рекламная
  метка, маскировка, SNI-политика, Zapret2 или SYN limiter, оптимизация
  By-MEKO, Selfmask, панель и бот. Про панель и бота спрашиваем,
  по умолчанию да.

  Лимиты CPU и памяти контейнера не переносятся: их подбирали под старую
  машину, а docker на новой откажется запускать контейнер, если ядер меньше.

  Вход только по ключу: пароль MTProxyL не спрашивает и не хранит.
  A-запись домена переводит владелец — этого за него никто не сделает.
  Сертификат Let's Encrypt выпускается в момент установки, поэтому запись
  лучше перевести до переезда: иначе ни Selfmask, ни HTTPS панели не встанут.
EOF
                return 0 ;;
            -*) log_error "Неизвестный аргумент: $1"; return 1 ;;
            *)  _target="$1"; shift ;;
        esac
    done
    _mig_parse_target "$_target" || return 1
    migrate_run
}
