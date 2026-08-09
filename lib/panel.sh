#!/bin/bash
# MTProxyL — установка и управление веб-панелью MTProxyL-Panel
#
# Панель — отдельный компонент (Go + React, один бинарник), который ставится
# своим установщиком. Здесь только тонкая обёртка: MTProxyL не дублирует
# логику установки, а вызывает установщик панели и показывает её состояние.

PANEL_SERVICE="mtproxyl-panel"
PANEL_BINARY="/usr/local/bin/mtproxyl-panel"
PANEL_CONFIG_DIR="/etc/mtproxyl-panel"
PANEL_INSTALLER_URL="${GITHUB_RAW}/mtproxyl-panel/install.sh"

panel_installed() {
    [ -x "$PANEL_BINARY" ]
}

panel_version() {
    panel_installed || return 1
    # Подкоманда, не флаг: панель печатает "mtproxyl-panel <версия>".
    "$PANEL_BINARY" version 2>/dev/null | awk '{print $2}'
}

panel_status_line() {
    if ! panel_installed; then
        echo -e "${DIM}не установлена${NC}"
        return
    fi
    local _ver; _ver=$(panel_version)
    # Префикс "v" только для номерных версий: "vsource-dev" выглядит опечаткой.
    local _vs=""
    if [ -n "$_ver" ]; then
        case "$_ver" in
            [0-9]*) _vs=" (v${_ver})" ;;
            *)      _vs=" (${_ver})" ;;
        esac
    fi
    if systemctl is-active "$PANEL_SERVICE" &>/dev/null; then
        echo -e "${GREEN}работает${NC}${_vs}"
    else
        echo -e "${YELLOW}установлена, не запущена${NC}${_vs}"
    fi
}

# Имя, на которое выписан сертификат панели. Именно оно должно стоять в
# ссылке: по любому другому адресу браузер откажется открывать панель с
# ошибкой несовпадения имени, даже если сеть до неё доходит.
#
# Берём SAN, а не CN: у самоподписанного сертификата панели CN —
# «MTProxyL-Panel», это не адрес. localhost отбрасываем — панель добавляет
# его в каждый самоподписанный сертификат для локальных запросов.
_panel_cert_domain() {
    local _cfg="${PANEL_CONFIG_DIR}/config.toml"
    local _cert
    _cert=$(grep -oE '^[[:space:]]*cert_file[[:space:]]*=[[:space:]]*"[^"]+"' "$_cfg" 2>/dev/null \
        | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    [ -n "$_cert" ] && [ -r "$_cert" ] || return 1
    command -v openssl &>/dev/null || return 1

    local _dom
    _dom=$(openssl x509 -in "$_cert" -noout -text 2>/dev/null \
        | grep -oE 'DNS:[^,[:space:]]+' | cut -d: -f2 | grep -vFx 'localhost' | head -1)
    [ -n "$_dom" ] || return 1
    echo "$_dom"
}

# Адрес, по которому панель отвечает — читаем из её конфига, чтобы не гадать.
# 0.0.0.0 означает «на всех интерфейсах», поэтому подставляем реальный IP
# сервера: ссылка вида http://:8080 никуда не ведёт. Let's Encrypt (acme_domain)
# выпускается на конкретный домен — если он задан, показываем его, а не IP:
# сертификат домену не соответствует IP, браузер такой ссылке не поверит.
#
# По той же причине домен из готового сертификата (cert_file — свой файл либо
# подхваченный у certbot) идёт раньше IP. И ни при каких условиях не берём
# get_public_ip: она отдаёт CUSTOM_IP — «IP/домен сервера» из настроек прокси,
# то есть адрес для tg://-ссылок. С панелью он не связан никак, а совпасть с
# ней может разве что случайно: у панели на стенде свой домен и сертификат
# Let's Encrypt на него, и меню звало открыть её по домену прокси, где она
# либо не отвечает, либо отдаёт чужой сертификат.
panel_listen_addr() {
    local _cfg="${PANEL_CONFIG_DIR}/config.toml"
    [ -f "$_cfg" ] || return 1
    local _listen
    _listen=$(grep -oE '^[[:space:]]*listen[[:space:]]*=[[:space:]]*"[^"]+"' "$_cfg" 2>/dev/null \
        | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    [ -n "$_listen" ] || return 1

    local _host="${_listen%:*}" _port="${_listen##*:}"
    local _acme_domain
    # Привязка к петле — самый конкретный ответ, какой вообще бывает: панель
    # отвечает только по этому адресу. Домен из сертификата тут подставлять
    # нельзя, даже если сертификат есть: снаружи по этому имени панели нет.
    case "$_host" in
        "127.0.0.1"|"localhost"|"::1"|"[::1]")
            echo "$_listen"
            return 0
            ;;
    esac

    _acme_domain=$(grep -oE '^[[:space:]]*acme_domain[[:space:]]*=[[:space:]]*"[^"]+"' "$_cfg" 2>/dev/null \
        | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    if [ -n "$_acme_domain" ]; then
        echo "${_acme_domain}:${_port}"
        return 0
    fi

    local _cert_domain; _cert_domain=$(_panel_cert_domain 2>/dev/null)
    if [ -n "$_cert_domain" ]; then
        echo "${_cert_domain}:${_port}"
        return 0
    fi

    case "$_host" in
        ""|"0.0.0.0"|"::"|"[::]")
            # CUSTOM_IP="" — иначе вернётся домен прокси вместо адреса сервера.
            local _ip; _ip=$(CUSTOM_IP="" get_public_ip 2>/dev/null)
            [ -n "$_ip" ] || _ip=$(hostname -I 2>/dev/null | awk '{print $1}')
            [ -n "$_ip" ] || _ip="<адрес-сервера>"
            echo "${_ip}:${_port}"
            ;;
        *) echo "$_listen" ;;
    esac
}

# Схема, по которой панель отвечает: она умеет HTTPS с самоподписанным
# сертификатом, Let's Encrypt и своим сертификатом. Подсказывать http, когда
# слушается https, — значит отправить пользователя по нерабочей ссылке.
panel_scheme() {
    local _cfg="${PANEL_CONFIG_DIR}/config.toml"
    [ -f "$_cfg" ] || { echo "http"; return 0; }
    if grep -qE '^[[:space:]]*(cert_file|acme_domain)[[:space:]]*=' "$_cfg" 2>/dev/null; then
        echo "https"
    else
        echo "http"
    fi
}

panel_install() {
    check_root || return 1

    if panel_installed; then
        log_info "Панель уже установлена: $(panel_status_line)"
        echo ""
        echo -en "  ${BOLD}Запустить установщик повторно (обновление/перенастройка)? [y/N]:${NC} "
        local _yn; read_line _yn
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
    fi

    if [ "${MTPROXYL_MODE:-manager}" = "manager" ] && ! _own_install_exists; then
        log_warn "Свой telemt ещё не установлен"
        log_info "Панели нужен работающий движок с доступным API — сначала выполните установку"
        return 1
    fi

    echo ""
    log_info "Установщик панели спросит адрес API telemt, логин и пароль администратора"
    log_info "Интеграция с MTProxyL будет предложена автоматически"

    # В режиме реаниматора цель чужая, и её API может слушать не на порту по
    # умолчанию — подсказываем найденный, чтобы не подбирать вручную.
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        local _api_port; _api_port=$(_get_telemt_api_port 2>/dev/null)
        if [ -n "$_api_port" ]; then
            log_info "API обнаруженной цели: http://127.0.0.1:${_api_port}"
            if ! _telemt_api_enabled 2>/dev/null; then
                log_warn "API цели сейчас недоступен: $(_telemt_api_unavailable_reason 2>/dev/null)"
                log_warn "Без работающего API панель не сможет показывать данные"
            fi
        else
            log_warn "Не удалось определить порт API цели — уточните его в конфиге цели"
        fi
    fi
    echo ""

    # Установщик интерактивный, поэтому запускаем его с терминалом, а не
    # через пайп: curl | sh лишил бы его stdin и все ответы ушли бы в никуда.
    local _tmp; _tmp=$(_mktemp) || return 1
    if ! curl -fsSL "$PANEL_INSTALLER_URL" -o "$_tmp"; then
        log_error "Не удалось скачать установщик панели"
        log_info "URL: ${PANEL_INSTALLER_URL}"
        return 1
    fi
    chmod +x "$_tmp"

    # На нестандартной ветке релиз — не то, что нужно: он собран с main и
    # может не содержать правок, ради которых вообще переключились на другую
    # ветку. Раньше здесь сперва тихо ставился последний релиз (он почти
    # всегда есть) и сборка из исходников предлагалась только если релиза нет
    # вовсе — то есть практически никогда. Теперь на не-main ветке сборка из
    # исходников идёт сразу, без обманчиво «успешной» установки чужого кода.
    if [ "$GITHUB_BRANCH" != "main" ]; then
        log_info "CLI установлен из ветки ${GITHUB_BRANCH} — собираем панель из тех же исходников"
        log_info "(релиз панели собран с main и может не содержать правок этой ветки)"
        if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
            log_info "Сборка пойдёт в Docker — тулчейн на сервере не останется"
        else
            log_warn "Docker недоступен: понадобятся Go 1.25+ и Node.js 20+ на сервере"
        fi
        log_info "Нужен git; сборка занимает несколько минут"

        sh "$_tmp" install "--from-source=${GITHUB_BRANCH}" \
            || { log_error "Сборка из исходников не удалась (причина выше)"; return 1; }
        _panel_install_report
        return 0
    fi

    # main: обычная установка из релиза.
    if sh "$_tmp" install; then
        _panel_install_report
        return 0
    fi

    # Установщик уже объяснил причину своим сообщением. Самая частая — релиза
    # панели ещё нет; в этом случае можно собрать её прямо из ветки.
    echo ""
    log_warn "Установка из релиза не удалась (причина выше)"
    echo ""
    log_info "Панель можно собрать из исходников ветки ${GITHUB_BRANCH}"
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        log_info "Сборка пойдёт в Docker — тулчейн на сервере не останется"
    else
        log_warn "Docker недоступен: понадобятся Go 1.25+ и Node.js 20+ на сервере"
    fi
    log_info "Нужен git; сборка занимает несколько минут"
    echo -en "  ${BOLD}Собрать из исходников? [y/N]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 1; }

    sh "$_tmp" install "--from-source=${GITHUB_BRANCH}" \
        || { log_error "Сборка из исходников не удалась (причина выше)"; return 1; }
    _panel_install_report
}

_panel_install_report() {
    echo ""
    if panel_installed; then
        log_success "Панель установлена"
        local _addr; _addr=$(panel_listen_addr)
        [ -n "$_addr" ] && log_info "Адрес: $(panel_scheme)://${_addr}"
    fi
}

# panel_uninstall [--no-confirm]
#
# --no-confirm пропускает вопрос «продолжить»: его задаёт вызывающий, когда
# согласие уже получено. Без этого при удалении MTProxyL пользователя
# спрашивают об одном и том же три раза подряд.
panel_uninstall() {
    check_root || return 1
    panel_installed || { log_info "Панель не установлена"; return 0; }

    if [ "${1:-}" != "--no-confirm" ]; then
        echo ""
        log_warn "Панель, служба и права sudo будут удалены"
        echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
        local _yn; read_line _yn
        [[ "$_yn" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }
    fi

    # Конфиг хранит логин, хеш пароля и настройки. Если его оставить, повторная
    # установка пропустит мастер и пароль останется прежним — спрашиваем явно.
    echo ""
    echo -e "  ${DIM}Конфиг ${PANEL_CONFIG_DIR}/config.toml хранит логин и пароль.${NC}"
    echo -e "  ${DIM}Если оставить, при новой установке мастер будет пропущен${NC}"
    echo -e "  ${DIM}и пароль останется прежним.${NC}"
    echo -en "  ${BOLD}Удалить конфиг и данные тоже? [Y/n]:${NC} "
    local _purge; read_line _purge
    local _cmd="purge"
    [[ "$_purge" =~ ^[nN] ]] && _cmd="uninstall"

    local _tmp; _tmp=$(_mktemp) || return 1
    if curl -fsSL "$PANEL_INSTALLER_URL" -o "$_tmp"; then
        chmod +x "$_tmp"
        sh "$_tmp" "$_cmd" || log_warn "Установщик вернул ошибку при удалении"
    else
        log_warn "Установщик недоступен, удаляем вручную"
        systemctl disable --now "$PANEL_SERVICE" &>/dev/null || true
        rm -f "$PANEL_BINARY" "/etc/systemd/system/${PANEL_SERVICE}.service"
        rm -f "/etc/sudoers.d/${PANEL_SERVICE}" "/etc/sudoers.d/${PANEL_SERVICE}-mtproxyl"
        systemctl daemon-reload &>/dev/null || true
    fi
    log_success "Панель удалена"
}

# Отключить интеграцию панели с MTProxyL, не удаляя саму панель.
#
# Нужно при удалении MTProxyL, когда пользователь решил панель оставить: без
# этого остаётся файл sudoers, разрешающий пользователю панели запускать
# /opt/mtproxyl/mtproxyl.sh от root, — путь, которого больше нет. Если этот
# путь потом появится снова (чужая установка, другой владелец), разрешение
# сработает. Заодно панель перестанет показывать разделы, которые всё равно
# больше не работают.
_panel_detach_mtproxyl() {
    rm -f "/etc/sudoers.d/${PANEL_SERVICE}-mtproxyl"

    local _cfg="${PANEL_CONFIG_DIR}/config.toml"
    if [ -f "$_cfg" ]; then
        # Правим на месте: файл принадлежит пользователю панели, и mv из
        # временного каталога сменил бы владельца — панель перестала бы его
        # читать и не поднялась после перезапуска.
        local _tmp; _tmp=$(_mktemp "$PANEL_CONFIG_DIR") || return 1
        if awk '
            /^[[:space:]]*\[/ { insect = ($0 ~ /^[[:space:]]*\[mtproxyl\]/) }
            insect && /^[[:space:]]*enabled[[:space:]]*=/ { print "enabled = false"; next }
            { print }
        ' "$_cfg" > "$_tmp"; then
            cat "$_tmp" > "$_cfg"
        fi
        rm -f "$_tmp"
    fi

    systemctl restart "$PANEL_SERVICE" &>/dev/null || true
    log_success "Интеграция отключена, права sudo сняты"
    log_info "Панель продолжит работать как обычная панель telemt"
}

# Смена пароля администратора панели.
#
# Установщик пропускает мастер, если конфиг уже есть, поэтому после
# переустановки пароль иначе было бы не поменять.
panel_password() {
    check_root || return 1
    panel_installed || { log_error "Панель не установлена"; return 1; }

    local _cfg="${PANEL_CONFIG_DIR}/config.toml"
    [ -f "$_cfg" ] || { log_error "Конфиг не найден: ${_cfg}"; return 1; }

    echo ""
    echo -en "  ${BOLD}Новый пароль администратора:${NC} "
    local _p1; read -rs _p1; echo ""
    [ -n "$_p1" ] || { log_error "Пароль не может быть пустым"; return 1; }
    echo -en "  ${BOLD}Повторите пароль:${NC} "
    local _p2; read -rs _p2; echo ""
    [ "$_p1" = "$_p2" ] || { log_error "Пароли не совпадают"; return 1; }

    # Хеш считает сама панель — тем же кодом, что проверяет его при входе.
    local _hash
    _hash=$(printf '%s\n' "$_p1" | "$PANEL_BINARY" hash-password 2>/dev/null) \
        || { log_error "Не удалось вычислить хеш пароля"; return 1; }
    [ -n "$_hash" ] || { log_error "Пустой хеш пароля"; return 1; }

    # Пишем через временный файл, чтобы не оставить конфиг битым при сбое.
    local _tmp; _tmp=$(_mktemp) || return 1
    if ! awk -v h="$_hash" '
        /^[[:space:]]*password_hash[[:space:]]*=/ && !done { print "password_hash = \"" h "\""; done=1; next }
        { print }
        END { if (!done) exit 3 }
    ' "$_cfg" > "$_tmp"; then
        log_error "В конфиге нет строки password_hash — правьте ${_cfg} вручную"
        return 1
    fi

    cat "$_tmp" > "$_cfg"
    chown mtproxyl-panel:mtproxyl-panel "$_cfg" 2>/dev/null || true
    chmod 600 "$_cfg"
    log_success "Пароль изменён"

    systemctl restart "$PANEL_SERVICE" &>/dev/null \
        && log_info "Панель перезапущена, войдите с новым паролем" \
        || log_warn "Перезапустите панель вручную: mtproxyl panel restart"
}

panel_restart() {
    check_root || return 1
    panel_installed || { log_error "Панель не установлена"; return 1; }
    systemctl restart "$PANEL_SERVICE" \
        && log_success "Панель перезапущена" \
        || log_error "Не удалось перезапустить панель"
}

panel_show_status() {
    echo ""
    draw_header "MTPROXYL-PANEL"
    echo ""
    echo -e "  ${BOLD}Состояние:${NC} $(panel_status_line)"
    if panel_installed; then
        local _addr; _addr=$(panel_listen_addr)
        [ -n "$_addr" ] && echo -e "  ${BOLD}Адрес:${NC}     $(panel_scheme)://${_addr}"
        echo -e "  ${BOLD}Бинарник:${NC}  ${PANEL_BINARY}"
        echo -e "  ${BOLD}Конфиг:${NC}    ${PANEL_CONFIG_DIR}/config.toml"
        echo -e "  ${BOLD}Логи:${NC}      journalctl -u ${PANEL_SERVICE} -f"
    else
        echo ""
        echo -e "  ${DIM}Установка: mtproxyl panel install${NC}"
    fi
    echo ""
}

# ── Let's Encrypt для панели ─────────────────────────────────────────────────
#
# Панель умеет ACME сама, но только когда порт 80 свободен: она поднимает на
# нём свой обработчик challenge. С включённым Selfmask порт 80 постоянно занят
# его nginx, и выпуск падал с «порт занят» — а останавливать заглушку руками
# ради сертификата пользователю неоткуда знать.
#
# Здесь сертификат выпускает certbot, а панель получает готовую копию файлов:
# так порт 80 либо не нужен вовсе (challenge отдаёт nginx selfmask из общего
# webroot), либо занят ровно на время выпуска.
PANEL_CERT_DIR="/var/lib/mtproxyl-panel/certs"

# Годен ли сертификат: не истекает в ближайший месяц и выписан на этот домен.
_panel_cert_is_valid() {
    local _dir="$1" _domain="$2"
    [ -f "${_dir}/fullchain.pem" ] && [ -f "${_dir}/privkey.pem" ] || return 1
    command -v openssl &>/dev/null || return 1
    openssl x509 -in "${_dir}/fullchain.pem" -noout -checkend 2592000 &>/dev/null || return 1
    openssl x509 -in "${_dir}/fullchain.pem" -noout -text 2>/dev/null \
        | grep -oE 'DNS:[^,[:space:]]+' | cut -d: -f2 | grep -Fxq "$_domain"
}

# Домен, на который панель хочет (или уже имеет) сертификат.
panel_cert_domain() {
    local _cfg="${PANEL_CONFIG_DIR}/config.toml"
    [ -f "$_cfg" ] || return 1
    local _d
    _d=$(grep -oE '^[[:space:]]*acme_domain[[:space:]]*=[[:space:]]*"[^"]+"' "$_cfg" 2>/dev/null \
        | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    if [ -z "$_d" ] && [ -f "${PANEL_CERT_DIR}/panel.crt" ]; then
        _d=$(openssl x509 -in "${PANEL_CERT_DIR}/panel.crt" -noout -text 2>/dev/null \
            | grep -oE 'DNS:[^,[:space:]]+' | cut -d: -f2 | head -1)
    fi
    [ -n "$_d" ] || return 1
    echo "$_d"
}

# Отдаёт панели копию сертификата и переводит её конфиг на файлы.
#
# Копия, а не путь в /etc/letsencrypt: панель работает под своим
# непривилегированным пользователем и читать оттуда не может.
_panel_adopt_cert() {
    local _lineage="$1"
    local _cfg="${PANEL_CONFIG_DIR}/config.toml"

    id mtproxyl-panel &>/dev/null || { log_error "Пользователь mtproxyl-panel не найден"; return 1; }
    [ -f "$_cfg" ] || { log_error "Конфиг панели не найден: ${_cfg}"; return 1; }

    mkdir -p "$PANEL_CERT_DIR"
    install -o mtproxyl-panel -g mtproxyl-panel -m 0644 \
        "${_lineage}/fullchain.pem" "${PANEL_CERT_DIR}/panel.crt" || {
        log_error "Не удалось скопировать сертификат для панели"; return 1; }
    install -o mtproxyl-panel -g mtproxyl-panel -m 0600 \
        "${_lineage}/privkey.pem" "${PANEL_CERT_DIR}/panel.key" || {
        log_error "Не удалось скопировать ключ для панели"; return 1; }

    # acme_domain снимаем: с ним панель продолжит занимать порт 80 под свой
    # (теперь не нужный) обработчик challenge.
    local _tmp; _tmp=$(_mktemp) || return 1
    awk -v certs="$PANEL_CERT_DIR" '
        /^[[:space:]]*acme_domain[[:space:]]*=/    { next }
        /^[[:space:]]*acme_cache_dir[[:space:]]*=/ { next }
        /^[[:space:]]*cert_file[[:space:]]*=/      { next }
        /^[[:space:]]*key_file[[:space:]]*=/       { next }
        /^\[tls\]/ {
            print
            print "cert_file = \"" certs "/panel.crt\""
            print "key_file = \"" certs "/panel.key\""
            found=1
            next
        }
        { print }
        END { if (!found) exit 3 }
    ' "$_cfg" > "$_tmp" || {
        log_error "В конфиге панели нет секции [tls] — добавьте её и повторите"
        return 1
    }

    cat "$_tmp" > "$_cfg"
    chown mtproxyl-panel:mtproxyl-panel "$_cfg" 2>/dev/null || true
    chmod 600 "$_cfg" 2>/dev/null || true
    log_success "Панель переведена на выпущенный сертификат"
    return 0
}

# Умеет ли работающий nginx selfmask отдать HTTP-01 за нас.
#
# Тогда порт 80 останавливать не нужно вовсе: challenge кладётся в тот же
# webroot, и заглушка продолжает работать. Проверяем не разбором конфига, а
# делом: кладём пробный файл и просим его у порта 80 с нужным Host. Конфиг
# бывает старый (без challenge в default_server), да и отдать файл может
# кто-то совсем другой.
_panel_selfmask_serves_acme() {
    local _domain="$1"
    [ -n "$_domain" ] || return 1
    [ -n "${SELFMASK_SITE_DIR:-}" ] && [ -d "$SELFMASK_SITE_DIR" ] || return 1
    systemctl is-active "${SELFMASK_PQ_SERVICE:-mtproxyl-pq-nginx.service}" &>/dev/null || return 1
    command -v curl &>/dev/null || return 1

    local _dir="${SELFMASK_SITE_DIR}/.well-known/acme-challenge"
    mkdir -p "$_dir" 2>/dev/null || return 1
    local _token="mtproxyl-probe-$$"
    printf 'ok' > "${_dir}/${_token}" 2>/dev/null || return 1
    chmod 644 "${_dir}/${_token}" 2>/dev/null || true

    local _code
    _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: ${_domain}" \
        "http://127.0.0.1/.well-known/acme-challenge/${_token}" 2>/dev/null)
    rm -f "${_dir}/${_token}" 2>/dev/null || true
    [ "$_code" = "200" ]
}

# Кто сейчас держит порт 80 — из тех, кого мы вправе трогать.
_panel_port80_holders() {
    local _out=""
    systemctl is-active "${SELFMASK_PQ_SERVICE:-mtproxyl-pq-nginx.service}" &>/dev/null \
        && _out+="${SELFMASK_PQ_SERVICE:-mtproxyl-pq-nginx.service} "
    systemctl is-active nginx &>/dev/null && _out+="nginx "
    systemctl is-active apache2 &>/dev/null && _out+="apache2 "
    echo "$_out"
}

_panel_port80_busy() {
    local _listen=""
    if command -v ss &>/dev/null; then
        _listen=$(ss -tln 2>/dev/null)
    elif command -v netstat &>/dev/null; then
        _listen=$(netstat -tln 2>/dev/null)
    else
        return 1
    fi
    printf '%s\n' "$_listen" | awk '{print $4}' | grep -qE '(^|:|])80$'
}

# true, если панель привязана к петле и снаружи её нет.
_panel_listens_locally() {
    local _cfg="${PANEL_CONFIG_DIR}/config.toml"
    [ -f "$_cfg" ] || return 1
    local _listen
    _listen=$(grep -oE '^[[:space:]]*listen[[:space:]]*=[[:space:]]*"[^"]+"' "$_cfg" 2>/dev/null \
        | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    case "${_listen%:*}" in
        "127.0.0.1"|"localhost"|"::1"|"[::1]") return 0 ;;
    esac
    return 1
}

# Выпуск сертификата Let's Encrypt для панели.
panel_issue_cert() {
    check_root || return 1
    panel_installed || { log_error "Панель не установлена"; return 1; }

    local _domain="${1:-}" _email="${2:-}"

    echo ""
    draw_header "СЕРТИФИКАТ LET'S ENCRYPT ДЛЯ ПАНЕЛИ"
    echo ""

    # Панель, привязанная к петле, снаружи не отвечает: по домену до неё не
    # дойти, а шифровать соединение, которое не покидает машину, незачем.
    # Сам выпуск при этом прошёл бы — и оставил после себя сертификат, который
    # некуда применить, плюс продление, которое некому использовать.
    if _panel_listens_locally; then
        log_warn "Панель слушает только 127.0.0.1 — снаружи она недоступна"
        log_info "Сертификат такой панели не нужен: до неё ходят через ssh-туннель,"
        log_info "а он шифрует соединение сам. Чтобы открыть панель наружу,"
        log_info "смените listen в ${PANEL_CONFIG_DIR}/config.toml и перезапустите её."
        echo ""
        echo -en "  ${BOLD}Всё равно выпустить? [y/N]:${NC} "
        local _yn_local; read_line _yn_local
        [[ "$_yn_local" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
    fi

    if [ -z "$_domain" ]; then
        local _suggest; _suggest=$(panel_cert_domain 2>/dev/null)
        echo -en "  ${BOLD}Домен панели${_suggest:+ [${_suggest}]}:${NC} "
        read_line _domain
        [ -n "$_domain" ] || _domain="$_suggest"
    fi
    [ -n "$_domain" ] || { log_error "Домен не задан"; return 1; }
    if ! validate_domain "$_domain"; then
        log_error "Некорректный домен: ${_domain}"
        return 1
    fi

    local _lineage="/etc/letsencrypt/live/${_domain}"

    # Сертификат мог уже выпустить selfmask на этот же домен — тогда всё, что
    # нужно, это отдать копию панели.
    if _panel_cert_is_valid "$_lineage" "$_domain"; then
        log_success "Сертификат для ${_domain} уже есть — используем его"
        _panel_adopt_cert "$_lineage" || return 1
        _panel_finish_cert
        return 0
    fi

    if ! command -v certbot &>/dev/null; then
        log_info "Устанавливаем certbot..."
        _wait_apt 2>/dev/null || true
        apt-get update -qq &>/dev/null || true
        apt-get install -y -qq certbot &>/dev/null || {
            log_error "Не удалось установить certbot"
            log_info "Поставьте его вручную (apt install certbot) и повторите"
            return 1
        }
    fi

    if [ -z "$_email" ]; then
        echo -en "  ${BOLD}Email для Let's Encrypt${SELFMASK_CERT_EMAIL:+ [${SELFMASK_CERT_EMAIL}]}:${NC} "
        read_line _email
        [ -n "$_email" ] || _email="${SELFMASK_CERT_EMAIL:-}"
    fi
    [ -n "$_email" ] || { log_error "Email обязателен для выпуска сертификата"; return 1; }

    echo ""
    log_info "Домен: ${_domain}"

    local _rc=1
    if _panel_selfmask_serves_acme "$_domain"; then
        # Ничего останавливать не нужно: заглушка сама отдаёт challenge.
        log_info "Проверку домена отдаёт nginx Selfmask — порт 80 не освобождаем"
        certbot certonly --webroot -w "$SELFMASK_SITE_DIR" \
            -d "$_domain" --non-interactive --agree-tos -m "$_email" \
            --cert-name "$_domain" && _rc=0
    else
        local _stopped=""
        if _panel_port80_busy; then
            local _holders; _holders=$(_panel_port80_holders)
            if [ -z "$_holders" ]; then
                log_error "Порт 80 занят посторонним процессом — освободите его и повторите"
                return 1
            fi
            echo ""
            log_warn "Порт 80 занят: ${_holders}"
            echo -e "  ${DIM}На время выпуска эти службы будут остановлены и сразу запущены обратно.${NC}"
            echo -e "  ${DIM}Обычно это несколько секунд.${NC}"
            echo ""
            echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
            local _yn; read_line _yn
            [[ "$_yn" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }

            local _svc
            for _svc in $_holders; do
                systemctl stop "$_svc" &>/dev/null && _stopped+="${_svc} "
            done
            [ -n "$_stopped" ] && log_info "Временно остановлено: ${_stopped}"
        fi

        certbot certonly --standalone \
            -d "$_domain" --non-interactive --agree-tos -m "$_email" \
            --cert-name "$_domain" && _rc=0

        # Возвращаем всё на место в любом случае — и после ошибки тоже.
        local _svc
        for _svc in $_stopped; do
            systemctl start "$_svc" &>/dev/null || log_warn "Не удалось запустить обратно: ${_svc}"
        done
        [ -n "$_stopped" ] && log_info "Остановленные службы запущены обратно"
    fi

    if [ "$_rc" -ne 0 ]; then
        log_error "Не удалось выпустить сертификат"
        log_info "Проверьте A-запись домена ${_domain} на этот сервер и доступность порта 80 извне"
        return 1
    fi
    log_success "Сертификат получен"

    _panel_adopt_cert "$_lineage" || return 1
    # Продление тоже должно доехать до панели: хук копирует новые файлы и
    # перезапускает её.
    _selfmask_install_deploy_hook 2>/dev/null || true
    _panel_finish_cert
}

# Перезапуск панели и подсказка по адресу — общий хвост выпуска/принятия.
_panel_finish_cert() {
    if [ "${MTPROXYL_ASSUME_YES:-}" = "1" ]; then
        log_warn "Панель прочитает сертификат после перезапуска:"
        log_info "  sudo systemctl restart ${PANEL_SERVICE}"
        return 0
    fi
    systemctl restart "$PANEL_SERVICE" &>/dev/null \
        && log_success "Панель перезапущена" \
        || log_warn "Перезапустите панель вручную: mtproxyl panel restart"
    local _addr; _addr=$(panel_listen_addr 2>/dev/null)
    [ -n "$_addr" ] && log_info "Адрес: https://${_addr}"
}

handle_panel_command() {
    case "${1:-status}" in
        install)   panel_install ;;
        uninstall) panel_uninstall ;;
        restart)   panel_restart ;;
        password)  panel_password ;;
        cert)      panel_issue_cert "${2:-}" "${3:-}" ;;
        status)    panel_show_status ;;
        *)
            echo -e "  ${BOLD}MTProxyL-Panel (веб-панель):${NC}"
            echo -e "    ${GREEN}panel status${NC}     Состояние"
            echo -e "    ${GREEN}panel install${NC}    Установить / переустановить"
            echo -e "    ${GREEN}panel restart${NC}    Перезапустить"
            echo -e "    ${GREEN}panel password${NC}   Сменить пароль администратора"
            echo -e "    ${GREEN}panel cert${NC} [домен] [email]"
            echo -e "                     Выпустить сертификат Let's Encrypt"
            echo -e "    ${GREEN}panel uninstall${NC}  Удалить"
            ;;
    esac
}

# ── Подменю панели ───────────────────────────────────────────────────────────
tui_panel_menu() {
    while true; do
        clear_screen
        panel_show_status

        if panel_installed; then
            echo -e "  ${CYAN}[1]${NC}  Перезапустить"
            echo -e "  ${CYAN}[2]${NC}  Переустановить / перенастроить"
            echo -e "  ${CYAN}[3]${NC}  Сменить пароль администратора"
            echo -e "  ${CYAN}[4]${NC}  Показать логи"
            echo -e "  ${CYAN}[5]${NC}  Удалить"
            echo -e "  ${CYAN}[6]${NC}  Выпустить сертификат Let's Encrypt"
            if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
                echo -e "      ${DIM}порт 80 занят Selfmask — выпуск это учитывает${NC}"
            fi
        else
            echo -e "  ${CYAN}[1]${NC}  Установить"
            echo ""
            echo -e "  ${DIM}Панель даёт веб-интерфейс: пользователи, трафик, режим,${NC}"
            echo -e "  ${DIM}Selfmask, лимитер, бэкапы — всё то же, что и в этом меню.${NC}"
        fi
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""

        local choice; choice=$(read_choice "выбор" "0")
        if panel_installed; then
            case "$choice" in
                1) panel_restart; press_any_key ;;
                2) panel_install; press_any_key ;;
                3) panel_password; press_any_key ;;
                4) journalctl -u "$PANEL_SERVICE" -n 50 --no-pager; press_any_key ;;
                5) panel_uninstall; press_any_key ;;
                6) panel_issue_cert; press_any_key ;;
                0|"") return ;;
            esac
        else
            case "$choice" in
                1) panel_install; press_any_key ;;
                0|"") return ;;
            esac
        fi
    done
}
