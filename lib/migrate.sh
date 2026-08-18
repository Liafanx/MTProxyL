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
    ssh-copy-id -p "$_MIG_PORT" ${_MIG_KEY:+-i "${_MIG_KEY}.pub"} "${_MIG_USER}@${_MIG_HOST}" || return 1
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
        log_warn "Включён режим супер эксперта — ваш config.toml туда не поедет"
        log_info "После переезда положите его на новом сервере и включите режим заново"
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

    local _busy
    _busy=$(_mig_ssh "ss -ltn 2>/dev/null | awk '{print \$4}' | grep -c ':${PROXY_PORT}\$'" 2>/dev/null || echo 0)
    if [ "${_busy:-0}" -gt 0 ]; then
        log_warn "Порт ${PROXY_PORT} на новом сервере уже занят — прокси может не подняться"
    fi
    return 0
}

# Аргументы установки собираем из своих же настроек: что здесь работает, то
# и должно заработать там.
_mig_build_args() {
    local -a _a=(--mode manager --force)
    _a+=(--port "${PROXY_PORT:-443}")
    _a+=(--metrics-port "${PROXY_METRICS_PORT:-9090}")
    _a+=(--api-port "${PROXY_API_PORT:-9091}")
    _a+=(--sni "${PROXY_DOMAIN:-autoscout24.ru}")
    _a+=(--sni-policy "${UNKNOWN_SNI_ACTION:-mask}")
    [ "${MASKING_ENABLED:-true}" = "false" ] && _a+=(--mask off) || _a+=(--mask on)
    [ -n "${AD_TAG:-}" ] && _a+=(--ad-tag "$AD_TAG")
    [ -n "${PROXY_CPUS:-}" ] && _a+=(--cpus "$PROXY_CPUS")
    [ -n "${PROXY_MEMORY:-}" ] && _a+=(--memory "$PROXY_MEMORY")

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
    if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
        _a+=(--zapret2 yes)
    else
        _a+=(--zapret2 no)
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
    [ "${MEKO_OPT_APPLIED:-false}" = "true" ] && _a+=(--meko yes) || _a+=(--meko no)

    load_selfmask_settings 2>/dev/null || true
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] && [ -n "${SELFMASK_DOMAIN:-}" ]; then
        _a+=(--selfmask "$SELFMASK_DOMAIN")
        _a+=(--selfmask-cert "${SELFMASK_CERT_MODE:-letsencrypt}")
        [ -n "${SELFMASK_CERT_EMAIL:-}" ] && _a+=(--selfmask-email "$SELFMASK_CERT_EMAIL")
        [ -n "${SELFMASK_SITE_SOURCE:-}" ] && _a+=(--selfmask-template "$SELFMASK_SITE_SOURCE")
        [ -n "${SELFMASK_NGINX_BACKEND_PORT:-}" ] && _a+=(--selfmask-backend-port "$SELFMASK_NGINX_BACKEND_PORT")
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
_mig_push_secrets() {
    local _f="${CONFIG_DIR}/secrets.conf"
    [ -f "$_f" ] || return 0
    log_info "Переносим лимиты и квоты пользователей..."
    _mig_scp "$_f" "/tmp/mtproxyl-secrets.conf" || { log_warn "secrets.conf не доехал — лимиты останутся пустыми"; return 0; }
    _mig_ssh "install -m 600 -o root -g root /tmp/mtproxyl-secrets.conf ${CONFIG_DIR}/secrets.conf && rm -f /tmp/mtproxyl-secrets.conf && mtproxyl restart >/dev/null 2>&1" \
        || log_warn "Не удалось положить secrets.conf на новом сервере"
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
    if _mig_ssh "mtproxyl panel install" </dev/null; then
        log_success "Панель установлена, пароль администратора прежний"
    else
        log_warn "Панель не установилась — поставьте на новом сервере: mtproxyl panel install"
    fi
}

_mig_push_tgbot() {
    tgbot_installed 2>/dev/null || return 0
    log_info "Переносим телеграм-бота..."
    local _token _admins
    _token=$(jq -r '.token // empty' "$TGBOT_CONFIG" 2>/dev/null)
    _admins=$(jq -r '(.admins // []) | join(",")' "$TGBOT_CONFIG" 2>/dev/null)
    if [ -z "$_token" ] || [ -z "$_admins" ]; then
        log_warn "Токен или админов бота прочитать не вышло — поставьте бота на новом сервере вручную"
        return 0
    fi
    local _first="${_admins%%,*}"
    if _mig_ssh "mtproxyl tgbot install --token $(_mig_quote "$_token") --admin $(_mig_quote "$_first")" </dev/null; then
        # Остальных админов добавляем по одному: у install только первый.
        local _a
        for _a in ${_admins//,/ }; do
            [ "$_a" = "$_first" ] && continue
            _mig_ssh "mtproxyl tgbot admin-add $(_mig_quote "$_a")" </dev/null >/dev/null 2>&1 || true
        done
        log_success "Бот установлен, токен и админы прежние"
        log_warn "Два бота на одном токене не уживутся — старого остановите"
    else
        log_warn "Бот не установился — поставьте на новом сервере: mtproxyl tgbot install"
    fi
}

migrate_run() {
    check_root
    _mig_check_local || return 1
    _mig_ensure_auth || return 1
    _mig_check_remote || return 1

    local -a _args=(); local _l
    while IFS= read -r _l; do _args+=("$_l"); done < <(_mig_build_args)

    echo ""
    draw_header "ЧТО ПОЕДЕТ"
    echo ""
    echo -e "  ${BOLD}Куда:${NC}       ${_MIG_USER}@${_MIG_HOST}:${_MIG_PORT}"
    echo -e "  ${BOLD}Порт:${NC}       ${PROXY_PORT:-443}"
    echo -e "  ${BOLD}Домен SNI:${NC}  ${PROXY_DOMAIN:-?}"
    echo -e "  ${BOLD}В ссылках:${NC}  $(if [ -n "${CUSTOM_IP:-}" ] && ! validate_ip_literal "${CUSTOM_IP}"; then echo "${CUSTOM_IP}"; else echo "адрес нового сервера"; fi)"
    echo -e "  ${BOLD}Секретов:${NC}   ${#SECRETS_LABELS[@]}"
    echo -e "  ${BOLD}Метка:${NC}      ${AD_TAG:-${DIM}нет${NC}}"
    echo -e "  ${BOLD}Selfmask:${NC}   $([ "${SELFMASK_ENABLED:-false}" = "true" ] && echo "${SELFMASK_DOMAIN}" || echo "${DIM}выключен${NC}")"
    echo -e "  ${BOLD}Панель:${NC}     $(panel_installed 2>/dev/null && echo "переносим" || echo "${DIM}нет${NC}")"
    echo -e "  ${BOLD}Бот:${NC}        $(tgbot_installed 2>/dev/null && echo "переносим" || echo "${DIM}нет${NC}")"
    echo ""
    echo -e "  ${DIM}A-запись домена на новый адрес переводите сами — это${NC}"
    echo -e "  ${DIM}единственное, что MTProxyL сделать за вас не может.${NC}"
    echo ""

    if [ "$_MIG_DRY" = "true" ]; then
        echo -e "  ${BOLD}Команда установки:${NC}"
        echo -e "  ${DIM}mtproxyl install $(_mig_quote "${_args[@]}")${NC}"
        echo ""
        log_info "Пробный прогон — на новом сервере ничего не менялось"
        return 0
    fi

    if [ "${MTPROXYL_NONINTERACTIVE:-false}" != "true" ]; then
        echo -en "  ${BOLD}Начинаем? [y/N]:${NC} "
        local _yn; read_line _yn
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
    fi

    echo ""
    draw_header "УСТАНОВКА НА НОВОМ СЕРВЕРЕ"
    echo ""
    log_info "Это займёт несколько минут: пакеты, docker, образ движка"

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

    _mig_push_secrets

    if [ "$_MIG_WITH_PANEL" != "no" ]; then _mig_push_panel; fi
    if [ "$_MIG_WITH_TGBOT" != "no" ]; then _mig_push_tgbot; fi

    _mig_finish
}

_mig_finish() {
    local _new_ip
    _new_ip=$(_mig_ssh "curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print \$1}'" </dev/null 2>/dev/null | tr -d '\r\n')
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
            --no-panel) _MIG_WITH_PANEL="no"; shift ;;
            --no-tgbot|--no-bot) _MIG_WITH_TGBOT="no"; shift ;;
            --dry-run)  _MIG_DRY="true"; shift ;;
            -h|--help)
                cat <<'EOF'
  Переезд на другой сервер (только режим менеджера)

    mtproxyl migrate <[пользователь@]хост[:порт]> [параметры]

    --key <файл>     приватный ключ для входа
    --no-panel       не переносить веб-панель
    --no-tgbot       не переносить телеграм-бота
    --dry-run        показать, что поедет, и ничего не делать

  Переносятся: порт, домен ссылок, FakeTLS SNI, секреты с лимитами,
  рекламная метка, маскировка, SNI-политика, Zapret2 или SYN limiter,
  оптимизация By-MEKO, Selfmask, панель и бот.

  Вход только по ключу: пароль MTProxyL не спрашивает и не хранит.
  A-запись домена переводит владелец — этого за него никто не сделает.
EOF
                return 0 ;;
            -*) log_error "Неизвестный аргумент: $1"; return 1 ;;
            *)  _target="$1"; shift ;;
        esac
    done
    _mig_parse_target "$_target" || return 1
    migrate_run
}
