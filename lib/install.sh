#!/bin/bash
# MTProxyL — мастер установки + деинсталлятор

run_installer() {
    show_banner

    echo -e "  ${BRIGHT_GREEN}Добро пожаловать в MTProxyL — менеджер Telegram MTProto прокси${NC}"
    echo -e "  ${DIM}by LiafanX${NC}"
    echo ""

    check_root

    # Проверка на повторную установку
    if [ -f "${INSTALL_DIR}/mtproxyl.sh" ] && [ -f "$SETTINGS_FILE" ]; then
        echo -e "  ${YELLOW}MTProxyL уже установлен.${NC}"
        echo ""
        echo -e "  ${DIM}[1]${NC} Открыть меню"
        echo -e "  ${DIM}[2]${NC} Установка / переустановка"
        echo -e "  ${DIM}[3]${NC} Удалить"
        echo -e "  ${DIM}[0]${NC} Выход"
        local choice; choice=$(read_choice "выбор" "1")
        case "$choice" in
            1) load_settings; load_secrets; load_detect_settings; show_main_menu; return ;;
            2) ;;
            3) load_settings; uninstall; return ;;
            *) exit 0 ;;
        esac
    fi

    draw_header "РЕЖИМ РАБОТЫ"
    echo ""
    echo -e "  ${BOLD}[1]${NC} Manager    ${DIM}— MTProxyL устанавливает и владеет своим telemt${NC}"
    echo -e "  ${BOLD}[2]${NC} Reanimator ${DIM}— применить фиксы к уже установленному telemt${NC}"
    echo ""
    local _mode_choice; _mode_choice=$(read_choice "выбор" "1")
    if [ "$_mode_choice" = "2" ]; then
        MTPROXYL_MODE="reanimator"
        run_reanimator_installer
        return
    fi
    MTPROXYL_MODE="manager"

    draw_header "УСТАНОВКА"
    echo ""

    # Зависимости
    log_info "Проверка зависимостей..."
    local missing=()
    command -v curl &>/dev/null || missing+=("curl")
    command -v awk &>/dev/null || missing+=("awk")
    command -v openssl &>/dev/null || missing+=("openssl")
    # jq не нужен самому MTProxyL (JSON API цели разбирается awk/sed), но им
    # пользуются штатные команды telemt вида: curl /v1/users | jq
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

    # Docker
    install_docker || exit 1
    wait_for_docker || exit 1

    echo ""
    draw_header "НАСТРОЙКА ПРОКСИ"
    echo ""

    # Порт
    echo -e "  ${BOLD}Порт прокси${NC} ${DIM}(по умолчанию: ${PROXY_PORT:-443})${NC}"
    while true; do
        echo -en "  ${DIM}Порт [${PROXY_PORT:-443}]:${NC} "
        local port_input=""
        read_line port_input
        # Пустой ввод — это выбор порта по умолчанию, его тоже надо проверить
        # на занятость, иначе контейнер молча упадёт после установки.
        [ -z "$port_input" ] && port_input="${PROXY_PORT:-443}"
        if ! validate_port "$port_input"; then
            log_error "Некорректный порт (допустимо 1..65535)"
            continue
        fi
        if ! is_port_available "$port_input"; then
            log_warn "Порт ${port_input} уже занят"
            show_port_listener "$port_input"
            echo -e "  ${DIM}Контейнер не сможет занять этот порт и упадёт при запуске.${NC}"
            echo -e "  ${DIM}[1]${NC} Указать другой порт ${DIM}(рекомендуется)${NC}"
            echo -e "  ${DIM}[2]${NC} Всё равно использовать ${port_input}"
            local _pc; _pc=$(read_choice "выбор" "1")
            [ "$_pc" = "2" ] || continue
        fi
        PROXY_PORT="$port_input"
        break
    done

    # Metrics port — автоматически выбираем свободный
    echo ""
    local _metrics_default
    _metrics_default=$(find_free_metrics_port 9090 9199) || _metrics_default=9090
    PROXY_METRICS_PORT="${_metrics_default}"
    if ! is_port_available "$PROXY_METRICS_PORT" 2>/dev/null; then
        _metrics_default=9090
        PROXY_METRICS_PORT=9090
    fi
    echo -e "  ${BOLD}Порт метрик (Prometheus endpoint, только localhost)${NC}"
    if is_port_available "$PROXY_METRICS_PORT" 2>/dev/null; then
        echo -e "  ${DIM}Автоматически выбран свободный порт: ${PROXY_METRICS_PORT}${NC}"
    else
        echo -e "  ${YELLOW}Порт ${PROXY_METRICS_PORT} занят, рекомендуем выбрать другой${NC}"
    fi
    echo -en "  ${BOLD}Оставить порт метрик ${PROXY_METRICS_PORT}? [Y/n]:${NC} "
    local metrics_keep; read_line metrics_keep
    if [[ "$metrics_keep" =~ ^[nN] ]]; then
        while true; do
            echo -en "  ${BOLD}Введите порт метрик [${PROXY_METRICS_PORT}]:${NC} "
            local metrics_input; read_line metrics_input
            [ -z "$metrics_input" ] && break
            if validate_port "$metrics_input"; then
                if is_port_available "$metrics_input"; then
                    PROXY_METRICS_PORT="$metrics_input"
                    log_success "Порт метрик: ${PROXY_METRICS_PORT}"
                    break
                else
                    log_error "Порт ${metrics_input} уже занят, попробуйте другой"
                fi
            else
                log_error "Некорректный порт"
            fi
        done
    fi

    # Порт REST API — из него панель берёт пользователей и статистику.
    # 9091 занимают и другие сервисы, а движок с занятым портом его не поднимет.
    echo ""
    local _api_default
    _api_default=$(find_free_metrics_port "${PROXY_API_PORT:-9091}" 9199) || _api_default="${PROXY_API_PORT:-9091}"
    PROXY_API_PORT="$_api_default"
    echo -e "  ${BOLD}Порт REST API движка (только localhost)${NC}"
    echo -e "  ${DIM}Через него работает веб-панель: пользователи, статистика, конфиг.${NC}"
    if is_port_available "$PROXY_API_PORT" 2>/dev/null; then
        echo -e "  ${DIM}Автоматически выбран свободный порт: ${PROXY_API_PORT}${NC}"
    else
        echo -e "  ${YELLOW}Порт ${PROXY_API_PORT} занят, рекомендуем выбрать другой${NC}"
    fi
    echo -en "  ${BOLD}Оставить порт API ${PROXY_API_PORT}? [Y/n]:${NC} "
    local api_keep; read_line api_keep
    if [[ "$api_keep" =~ ^[nN] ]]; then
        while true; do
            echo -en "  ${BOLD}Введите порт API [${PROXY_API_PORT}]:${NC} "
            local api_input; read_line api_input
            [ -z "$api_input" ] && break
            if ! validate_port "$api_input"; then
                log_error "Некорректный порт"
                continue
            fi
            if [ "$api_input" = "${PROXY_METRICS_PORT:-9090}" ] || [ "$api_input" = "${PROXY_PORT:-443}" ]; then
                log_error "Этот порт уже занят самим прокси или метриками"
                continue
            fi
            if is_port_available "$api_input"; then
                PROXY_API_PORT="$api_input"
                log_success "Порт API: ${PROXY_API_PORT}"
                break
            fi
            log_error "Порт ${api_input} уже занят, попробуйте другой"
        done
    fi

    # IP
    echo ""
    local _det_ip; _det_ip=$(CUSTOM_IP="" get_public_ip)
    echo -e "  ${BOLD}IP или домен для ссылок${NC}"
    echo -e "  ${DIM}Определён: ${_det_ip:-?}${NC}"
    echo -e "  ${DIM}Введите свой IPv4 или домен, либо Enter для автоопределения.${NC}"
    echo ""
    echo -en "  ${BOLD}IP/домен [${_det_ip:-авто}]:${NC} "
    local ip_input=""
    read_line ip_input
    if [ -n "$ip_input" ]; then
        if validate_ip_literal "$ip_input"; then
            CUSTOM_IP="$ip_input"
            log_success "IP: ${CUSTOM_IP}"
        elif validate_domain "$ip_input"; then
            CUSTOM_IP="$ip_input"
            log_success "Домен: ${CUSTOM_IP}"
        else
            log_warn "Некорректный IP/домен: '${ip_input}' — используем автоопределение"
            CUSTOM_IP=""
        fi
    fi

    # Домен
    echo ""
    echo -e "  ${BOLD}FakeTLS домен (потом можно будет изменить)${NC}"
    echo -e "  ${DIM}[1] autoscout24.ru  [2] m.beboo.ru  [3] twitch.tv  [4] Свой${NC}"
    local d; d=$(read_choice "выбор" "1")
    case "$d" in
        2) PROXY_DOMAIN="m.beboo.ru" ;;
        3) PROXY_DOMAIN="twitch.tv" ;;
        4) echo -en "  Домен: "; local cd; read_line cd
           [ -n "$cd" ] && validate_domain "$cd" && PROXY_DOMAIN="$cd" ;;
        *) PROXY_DOMAIN="autoscout24.ru" ;;
    esac

    if [ -n "${PROXY_DOMAIN:-}" ]; then
        auto_set_fake_cert_len "$PROXY_DOMAIN" 2>/dev/null || \
            log_warn "Не удалось определить TLS cert length для '${PROXY_DOMAIN}', оставляем ${FAKE_CERT_LEN:-2048}"
    fi

    # Маскировка
    echo ""
    echo -e "  ${BOLD}Маскировка трафика${NC}"
    echo -en "  ${DIM}Включить? [Y/n]:${NC} "
    local mask_input; read_line mask_input
    [[ "$mask_input" =~ ^[nN] ]] && MASKING_ENABLED="false" || MASKING_ENABLED="true"

    # Ресурсы
    echo ""
    echo -e "  ${BOLD}Ресурсы${NC}"
    echo -en "  ${DIM}CPU (напр. 1 (1 ядро)) [Enter без ограничений]:${NC} "; local cpu; read_line cpu
    [ -n "$cpu" ] && PROXY_CPUS="$cpu"
    echo -en "  ${DIM}RAM (напр. 256m, 1g) [Enter без ограничений]:${NC} "; local mem; read_line mem
    [ -n "$mem" ] && PROXY_MEMORY="$mem"

    # Первый секрет
    echo ""
    draw_header "СЕКРЕТ"
    echo ""
    echo -en "  ${DIM}Метка (имя пользователя) [по умолчанию default]:${NC} "
    local first_label; read_line first_label
    [ -z "$first_label" ] && first_label="default"
    [[ "$first_label" =~ ^[a-zA-Z0-9_-]+$ ]] || first_label="default"

    local first_secret; first_secret=$(generate_secret)
    SECRETS_LABELS=("$first_label")
    SECRETS_KEYS=("$first_secret")
    SECRETS_CREATED+=("$(date +%s)")
    SECRETS_ENABLED=("true")
    SECRETS_MAX_CONNS=("0"); SECRETS_MAX_IPS=("0")
    SECRETS_QUOTA=("0"); SECRETS_EXPIRES=("0"); SECRETS_NOTES=("")

    # Сохранение
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$STATS_DIR" "$BACKUP_DIR"
    # Каталог настроек — 711: листинга нет, но settings.conf по известному имени
    # читается без sudo (см. lib/settings.sh). Конфиг движка остаётся закрытым.
    chmod 700 "$CONFIG_DIR" "$STATS_DIR" "$BACKUP_DIR"
    chmod "${_INSTALL_DIR_MODE:-711}" "$INSTALL_DIR"
    save_settings
    save_secrets

    # Копирование скрипта
    # Главный скрипт уже скачан корневым install.sh, здесь только обновляем симлинк
    ln -sf "${INSTALL_DIR}/mtproxyl.sh" /usr/local/bin/mtproxyl

    run_fix_arsenal_wizard

    # Запуск
    echo ""
    draw_header "ЗАПУСК ПРОКСИ"
    echo ""
    run_proxy_container || {
        log_error "Не удалось запустить прокси"
        echo -e "  ${DIM}Проверьте: docker logs mtproxyl${NC}"
    }

    # Автозапуск
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
        log_success "Снимки истории IP: каждые $(_ip_history_interval_minutes) мин"
    fi

    install_availability_timer
    log_success "Проверка доступности из РФ: каждые $(availability_interval_minutes) мин"

    offer_tgbot_install

    # Итог
    show_install_summary

    echo ""
    echo -en "  ${DIM}Нажмите клавишу для входа в меню...${NC}"
    read -rsn1
    read -rn 256 -t 0.05 _ 2>/dev/null || true
    load_settings; load_secrets
    show_main_menu
}

# Телеграм-бот при первой установке. По умолчанию «нет»: для него нужен
# заведённый у BotFather токен, а он есть не у всех и не сразу.
offer_tgbot_install() {
    tgbot_installed 2>/dev/null && return 0
    echo ""
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${BRIGHT_CYAN}${BOLD}Телеграм-бот${NC}"
    echo ""
    echo -e "  ${DIM}Управление прокси кнопками в Telegram: пользователи, ссылки${NC}"
    echo -e "  ${DIM}с QR-кодами, трафик, доступность из России и уведомления,${NC}"
    echo -e "  ${DIM}когда прокси упал или его перестали видеть из РФ.${NC}"
    echo ""
    echo -e "  ${DIM}Понадобится токен от @BotFather. Поставить можно и позже:${NC}"
    echo -e "  ${DIM}главное меню → Телеграм бот.${NC}"
    echo ""
    echo -en "  ${BOLD}Установить телеграм-бота? [y/N]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[yYдД] ]] || { log_info "Пропускаем — поставите когда понадобится"; return 0; }
    tgbot_install
}

# ── Общий блок фиксов (NFT/Zapret2/MEKO) — manager и reanimator ──
run_fix_arsenal_wizard() {
    # Zapret2 MTProto fix
    echo ""
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${BRIGHT_CYAN}${BOLD}Zapret2 MTProto fix${NC}"
    echo ""
    echo -e "  ${DIM}Серверный обход MTProto прокси на уровне TCP-пакетов.${NC}"
    echo -e "  ${DIM}Метод: disorder + badsum + TCP window control.${NC}"
    echo -e "  ${DIM}Работает на сервере — клиент ничего не устанавливает.${NC}"
    echo -e "  ${DIM}При установке заменяет SYN limiter.${NC}"
    echo ""
    echo -en "  ${BOLD}Установить Zapret2 MTProto fix? [Y/n]:${NC} "
    local _yn_zapret2; read_line _yn_zapret2
    local _zapret2_installed="false"
    if [[ ! "$_yn_zapret2" =~ ^[nN] ]]; then
        load_nft_settings 2>/dev/null || true
        zapret2_download_bundle
        if [ $? -eq 0 ]; then
            # Проверяем занятость NFQUEUE
            if zapret2_queue_in_use "${ZAPRET2_QNUM}"; then
                local _new_q
                _new_q=$(zapret2_find_free_queue 250 299)
                [ -z "$_new_q" ] && _new_q=$(zapret2_find_free_queue 201 249)

                if [ -n "$_new_q" ]; then
                    log_warn "NFQUEUE ${ZAPRET2_QNUM} занята — используем ${_new_q}"
                    ZAPRET2_QNUM="$_new_q"
                    save_nft_settings
                else
                    log_error "Не удалось найти свободную NFQUEUE в диапазоне 201..299"
                fi
            fi

            zapret2_write_conf
            zapret2_write_lua
            zapret2_write_service
            zapret2_apply_nft
            systemctl enable "$ZAPRET2_SERVICE" 2>/dev/null || true
            systemctl start "$ZAPRET2_SERVICE" 2>/dev/null || true
            sleep 1
            if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null; then
                ZAPRET2_APPLIED="true"
                ZAPRET2_SERVICE_ENABLED="true"
                save_nft_settings
                _zapret2_installed="true"
                log_success "Zapret2 MTProto fix установлен и запущен"
                zapret2_check_wscale "false"
            else
                log_error "zapret2 не запустился"
                journalctl -u "$ZAPRET2_SERVICE" -n 5 --no-pager 2>/dev/null || true
            fi
        else
            log_error "Не удалось скачать zapret2 — можно установить позже: меню NFT → [2]"
        fi
    else
        log_info "Zapret2 fix не установлен. Можно установить позже: меню NFT → [2]"
    fi

    # NFT SYN limiter (только если zapret2 не установлен)
    if [ "$_zapret2_installed" != "true" ]; then
      echo ""
      echo -e "  ${BOLD}NFT SYN Limiter${NC}"
      echo -e "  ${DIM}Ограничение входящих SYN-пакетов клиента.${NC}"
      echo -e "  ${DIM}Без этого прокси нестабилен в ~90% случаев.${NC}"
      echo ""
    echo -e "  ${DIM}Режимы:${NC}"
    echo -e "    ${BRIGHT_GREEN}[1]${NC} ★ Smart By-MEKO ${DIM}(рекомендуется — iOS/Android авторазделение + REJECT)${NC}"
    echo -e "    ${RED}[2]${NC} Classic — 1/sec burst 1"
    echo -e "    ${DIM}[0]${NC} Не применять"
    echo ""
    echo -en "  ${BOLD}Применить NFT limiter? [1 по умолчанию]:${NC} "
    local _nft_choice; read_line _nft_choice

    # Отказ — это отказ: без флага ниже применялись правила режима по
    # умолчанию, и каскад через реаниматор ломался.
    local _nft_applied="true"
    case "$_nft_choice" in
        2) apply_nft_preset classic ;;
        0) _nft_applied="false"; log_info "NFT limiter не применён" ;;
        *) apply_nft_preset smart ;;
    esac

      # Выбор Other Action для Smart режима
      if [ "$_nft_applied" = "true" ] && [ "$NFT_MODE" = "smart" ]; then
        echo ""
        echo -e "  ${BOLD}Действие для non-iOS устройств (Android / Desktop):${NC}"
        echo ""
        echo -e "    ${GREEN}[1]${NC} ${BOLD}icmp-host-unreachable${NC} ${DIM}(рекомендуется)${NC}"
        echo -e "         ${DIM}Мгновенное переключение Telegram, медиа без задержек.${NC}"
        echo -e "    ${CYAN}[2]${NC} reject (tcp reset)  ${DIM}(оригинал By-MEKO)${NC}"
        echo -e "    ${YELLOW}[3]${NC} drop  ${DIM}(не рекомендуется)${NC}"
        echo ""
        local _action_choice; read -erp "  Выбор [1]: " _action_choice
        case "${_action_choice:-1}" in
            2) NFT_OTHER_ACTION="reject" ;;
            3) NFT_OTHER_ACTION="drop" ;;
            *) NFT_OTHER_ACTION="icmp-host-unreachable" ;;
        esac
        save_nft_settings
        log_success "Other Action: ${NFT_OTHER_ACTION}"
      fi

      if [ "$_nft_applied" = "true" ]; then
        # По умолчанию ограничиваем по IP сервера
        if [ -n "${CUSTOM_IP:-}" ] && validate_ip_literal "${CUSTOM_IP}"; then
            NFT_SERVER_IP="${CUSTOM_IP}"
            log_info "Используем IP из настроек ссылок: ${NFT_SERVER_IP}"
        elif [ -n "${CUSTOM_IP:-}" ]; then
            log_warn "В настройках ссылок указан домен '${CUSTOM_IP}' — для NFT нужен IPv4"
            # CUSTOM_IP="" — иначе get_public_ip вернёт тот же домен.
            NFT_SERVER_IP="$(CUSTOM_IP="" get_public_ip)"
            if [ -n "$NFT_SERVER_IP" ]; then
                log_info "Автоматически определён IP для NFT: ${NFT_SERVER_IP}"
            else
                log_warn "Не удалось определить IP — NFT правило без привязки к IP"
                NFT_SERVER_IP=""
            fi
        else
            NFT_SERVER_IP="$(get_public_ip)"
            if [ -n "$NFT_SERVER_IP" ]; then
                log_info "Автоматически определён IP для NFT: ${NFT_SERVER_IP}"
            else
                log_warn "Не удалось автоматически определить IP сервера"
                log_warn "NFT правило будет создано без IP-привязки"
                NFT_SERVER_IP=""
            fi
        fi

        save_nft_settings
        apply_nft_rules || log_warn "Не удалось применить NFT правила"
        install_nft_service || log_warn "Не удалось установить службу NFT"
      fi
    fi 

    # Оптимизация By-MEKO
    echo ""
    echo -e "  ${BOLD}Оптимизация системы By-MEKO${NC}"
    echo -e "  ${DIM}TCP keepalive 45s, BBR, расширенные очереди.${NC}"
    echo -e "  ${DIM}Текущие значения ядра будут сохранены для отката.${NC}"
    echo ""
    echo -en "  ${BOLD}Применить оптимизацию By-MEKO? [Y/n]:${NC} "
    local _meko_choice; read_line _meko_choice
    if [[ ! "$_meko_choice" =~ ^[nN] ]]; then
        load_nft_settings 2>/dev/null || true
        meko_opt_apply || log_warn "Не удалось применить оптимизацию By-MEKO"
    fi
}

show_install_summary() {
    echo ""
    local server_ip; server_ip=$(get_public_ip)

    echo -e "  ${BRIGHT_GREEN}${BOLD}УСТАНОВКА ЗАВЕРШЕНА${NC}"
    echo ""
    echo -e "  ${BOLD}Сервер:${NC} ${server_ip:-?}"
    echo -e "  ${BOLD}Порт:${NC}   ${PROXY_PORT}"
    echo -e "  ${BOLD}Домен:${NC} ${PROXY_DOMAIN}"
    echo -e "  ${BOLD}Движок:${NC} telemt (Rust)"
    echo ""

    if [ -n "$server_ip" ]; then
        echo -e "  ${BOLD}ССЫЛКИ${NC}"
        echo ""
        local i
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
            local fs; fs=$(build_faketls_secret "${SECRETS_KEYS[$i]}")
            echo -e "  ${BRIGHT_GREEN}${SECRETS_LABELS[$i]}:${NC}"
            echo -e "  ${CYAN}tg://proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${fs}${NC}"
            echo ""
        done
    fi

    echo -e "  ${BOLD}КОМАНДЫ${NC}"
    echo -e "  ${GREEN}mtproxyl${NC}              Меню управления"
    echo -e "  ${GREEN}mtproxyl status${NC}       Статус"
    echo -e "  ${GREEN}mtproxyl secret add${NC}   Добавить пользователя"
    echo -e "  ${GREEN}mtproxyl help${NC}         Справка"
    echo ""
    echo -e "  ${YELLOW}Фаервол: откройте TCP порт, если закрыт ${PROXY_PORT}${NC}"
    echo ""
}

uninstall() {
    clear_screen
    echo ""
    echo -e "  ${BRIGHT_RED}${BOLD}УДАЛЕНИЕ MTPROXYL${NC}"
    echo ""
    echo -e "  ${YELLOW}Будет удалено:${NC}"
    if [ "${MTPROXYL_MODE:-manager}" = "manager" ]; then
        echo -e "  ${DIM}- Контейнер и Docker-образ MTProxyL${NC}"
    fi
    echo -e "  ${DIM}- Конфигурация и секреты${NC}"
    echo -e "  ${DIM}- Systemd-сервисы MTProxyL${NC}"
    echo -e "  ${DIM}- NFT правила и iOS фиксы${NC}"
    echo -e "  ${DIM}- Selfmask и PQ nginx (если установлены)${NC}"
    echo -e "  ${DIM}- /usr/local/bin/mtproxyl${NC}"
    if panel_installed 2>/dev/null; then
        echo -e "  ${DIM}- Веб-панель MTProxyL-Panel (спросим отдельно)${NC}"
    fi
    if tgbot_installed 2>/dev/null; then
        echo -e "  ${DIM}- Телеграм-бот${NC}"
    fi
    echo ""
    echo -e "  ${GREEN}НЕ будет удалено:${NC}"
    echo -e "  ${DIM}- Docker (сам движок)${NC}"
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        echo -e "  ${DIM}- Обнаруженная цель (контейнер/процесс/конфиг telemt) — она не наша${NC}"
    fi
    echo -e "  ${DIM}- Другие Docker-образы и контейнеры${NC}"
    echo -e "  ${DIM}- Глобальный Docker build cache${NC}"
    echo ""

    echo -en "  ${BOLD}Введите 'yes' для подтверждения:${NC} "
    local confirm; read_line confirm
    [ "$confirm" != "yes" ] && { log_info "Отменено"; return; }

    # Экспорт секретов
    echo -en "  ${BOLD}Сохранить секреты перед удалением? [y/N]:${NC} "
    local export_choice; read_line export_choice
    if [[ "$export_choice" =~ ^[yY] ]]; then
        local export_file="${HOME}/mtproxyl-secrets-backup.txt"
        if [ -f "$SECRETS_FILE" ]; then
            cp "$SECRETS_FILE" "$export_file" 2>/dev/null || true
            chmod 600 "$export_file" 2>/dev/null || true
            log_success "Секреты сохранены: ${export_file}"
        else
            log_warn "Файл секретов не найден — нечего сохранять"
        fi
    fi

    # Веб-панель спрашиваем первой: если её оставить, нужно снять права sudo —
    # они разрешают запуск файла, который сейчас исчезнет.
    if panel_installed 2>/dev/null; then
        echo ""
        echo -e "  ${BOLD}Установлена веб-панель MTProxyL-Panel${NC}"
        echo -e "  ${DIM}Без MTProxyL она останется работать как обычная панель telemt,${NC}"
        echo -e "  ${DIM}но разделы режима, Selfmask и лимитера в ней перестанут работать.${NC}"
        echo -en "  ${BOLD}Удалить панель тоже? [Y/n]:${NC} "
        local _panel_yn; read_line _panel_yn
        if [[ ! "$_panel_yn" =~ ^[nN] ]]; then
            panel_uninstall --no-confirm || log_warn "Не удалось удалить панель — проверьте вручную"
        fi
        # Панель могла остаться и после «удалить»: у panel_uninstall своё
        # подтверждение, а установщик панели мог не скачаться. В любом случае,
        # если она на месте — снимаем права sudo на исчезающий скрипт.
        if panel_installed 2>/dev/null; then
            log_info "Панель осталась — отключаем интеграцию с MTProxyL"
            _panel_detach_mtproxyl
        fi
    fi

    # Телеграм-бот: без MTProxyL он бесполезен — все его команды идут в скрипт,
    # который сейчас исчезнет.
    if tgbot_installed 2>/dev/null; then
        echo ""
        log_info "Удаляем телеграм-бота: без MTProxyL ему нечем управлять"
        systemctl disable --now "$TGBOT_SERVICE" &>/dev/null
        rm -f "/etc/systemd/system/${TGBOT_SERVICE}" "$TGBOT_SUDOERS"
        systemctl daemon-reload 2>/dev/null
        rm -rf "$TGBOT_DIR"
        userdel "$TGBOT_USER" 2>/dev/null || true
        log_success "Телеграм-бот удалён"
    fi

    # Selfmask и PQ nginx
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] || [ -d "${SELFMASK_PQ_PREFIX:-/opt/mtproxyl-nginx}" ]; then
        echo ""
        echo -e "  ${BOLD}Обнаружен Selfmask / PQ nginx${NC}"
        echo -en "  ${BOLD}Удалить PQ nginx и отключить selfmask? [Y/n]:${NC} "
        local _sm_yn
        read_line _sm_yn
        if [[ ! "$_sm_yn" =~ ^[nN] ]]; then
            log_info "Удаление selfmask и PQ nginx..."
            _selfmask_cleanup_for_uninstall 2>/dev/null || true
            log_success "Selfmask и PQ nginx удалены"
        else
            log_info "PQ nginx оставлен без изменений"
        fi
    fi

    # NFT очистка
    log_info "Удаление NFT правил..."
    load_nft_settings 2>/dev/null || true
    nft_full_cleanup 2>/dev/null || true

    # Systemd сервисы
    log_info "Удаление сервисов..."
    systemctl stop mtproxyl.service >/dev/null 2>&1 || true
    systemctl disable mtproxyl.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/mtproxyl.service
    remove_ip_history_timer >/dev/null 2>&1 || true
    remove_availability_timer >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    # Гео-блокировка
    log_info "Удаление гео-блокировки..."
    geoblock_remove_all >/dev/null 2>&1 || true

    if [ "${MTPROXYL_MODE:-manager}" = "manager" ]; then
        # Docker контейнер
        log_info "Удаление контейнера..."
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

        # Docker образы — только MTProxyL
        log_info "Удаление образов MTProxyL..."
        docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | grep "^${DOCKER_IMAGE_BASE}:" \
            | while IFS= read -r _img; do
                docker rmi "$_img" >/dev/null 2>&1 || true
            done || true

        docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | grep "^${REGISTRY_IMAGE}:" \
            | while IFS= read -r _img; do
                docker rmi "$_img" >/dev/null 2>&1 || true
            done || true
    else
        log_info "Reanimator-режим: обнаруженная цель (${DETECTED_MODE:-unknown}) не трогается"
    fi

    # Файлы
    log_info "Удаление файлов..."
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/mtproxyl
    # Алиас 'mtproxyl → sudo mtproxyl' от установщика. Строки в ~/.bashrc
    # пользователей не трогаем — они безобидны (алиас на несуществующую
    # команду) и лезть в чужие dotfiles при удалении не стоит.
    rm -f /etc/profile.d/mtproxyl.sh

    # Параметры ядра, которые ставили фиксы. В отличие от алиаса это не
    # безобидный остаток: удалённый MTProxyL продолжал бы менять поведение
    # TCP на каждой загрузке. Значения вернутся к дефолтам ядра.
    rm -f /etc/sysctl.d/99-mtproxyl-zapret2.conf \
          /etc/sysctl.d/99-mtproxyl-wscale.conf \
          /etc/sysctl.d/99-mtproxyl-keepalive.conf \
          /etc/sysctl.d/99-mtproxyl-meko-opt.conf

    echo ""
    log_success "MTProxyL полностью удалён"
    echo ""
}
