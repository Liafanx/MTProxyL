#!/bin/bash
# MTProxyL — подменю: настройки

tui_settings_menu() {
    if _superexpert_active; then
        clear_screen
        draw_header "НАСТРОЙКИ"
        echo ""
        log_warn "Включён режим супер эксперта — настройки движка задаёте вы"
        echo -e "  ${DIM}Порт, домен, маскировка и всё остальное берутся из вашего конфига:${NC}"
        echo -e "  ${BOLD}${SUPEREXPERT_FILE}${NC}"
        echo -e "  ${DIM}Правка: главное меню → Режим супер эксперта → Редактировать конфиг${NC}"
        echo ""
        echo -e "  ${DIM}Настройки хоста (NFT, Zapret2, selfmask, гео-блокировка, бэкапы)${NC}"
        echo -e "  ${DIM}работают как обычно — они не про конфиг движка.${NC}"
        press_any_key
        return
    fi
    while true; do
        clear_screen
        draw_header "НАСТРОЙКИ"
        echo ""
        echo -e "  ${BOLD}Транспорт:${NC}         $(proxy_transport_mode_title)"
        if web_is_only_mode; then
            echo -e "  ${BOLD}WEB:${NC}              $(web_domain 2>/dev/null || echo '—'):$(web_public_port 2>/dev/null || echo 443)"
            echo -e "  ${BOLD}Порт MTProto:${NC}      ${PROXY_PORT} ${DIM}(резерв для совместного режима)${NC}"
        else
            echo -e "  ${BOLD}Порт:${NC}              ${PROXY_PORT}"
        fi
        echo -e "  ${BOLD}IP/домен сервера:${NC}  ${CUSTOM_IP:-$(get_public_ip 2>/dev/null) ${DIM}(авто)${NC}}"
        echo -e "  ${BOLD}Домен(SNI):${NC}        ${PROXY_DOMAIN}$([ "${PROXY_MODE:-mtproto}" = "web" ] && echo " ${DIM}(резерв)${NC}")"
        echo -e "  ${BOLD}CPU:${NC}               ${PROXY_CPUS:-без ограничений}"
        echo -e "  ${BOLD}Память:${NC}            ${PROXY_MEMORY:-без ограничений}"
        echo -e "  ${BOLD}Маскировка:${NC}        ${MASKING_ENABLED}$([ "$MASKING_ENABLED" = "true" ] && echo " → ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}")"
        echo -e "  ${BOLD}Метрики:${NC}           127.0.0.1:${PROXY_METRICS_PORT}"
        echo -e "  ${BOLD}Рекл. метка:${NC}       ${AD_TAG:-${DIM}не задана${NC}}"
        echo -e "  ${BOLD}SNI-полит.:${NC}        ${UNKNOWN_SNI_ACTION}"
        echo -e "  ${BOLD}PROXY proto:${NC}       ${PROXY_PROTOCOL}"
        echo -e "  ${BOLD}Selfmask:${NC}          $(selfmask_status_line 2>/dev/null || echo "${DIM}выключен${NC}")"
        echo -e "  ${BOLD}Движок:${NC}            telemt v$(get_telemt_version)"
        echo ""
        echo -e "  ${DIM}[1]${NC} Изменить порт"
        echo -e "  ${DIM}[2]${NC} Изменить IP/домен сервера"
        echo -e "  ${DIM}[3]${NC} Изменить домен(SNI)"
        echo -e "  ${DIM}[4]${NC} Ресурсы (CPU/RAM)"
        echo -e "  ${DIM}[5]${NC} Маскировка вкл/выкл"
        echo -e "  ${DIM}[6]${NC} Mask backend (хост:порт)"
        echo -e "  ${DIM}[7]${NC} Рекламная метка"
        echo -e "  ${DIM}[8]${NC} SNI-политика [${UNKNOWN_SNI_ACTION}]"
        echo -e "  ${DIM}[9]${NC} PROXY protocol вкл/выкл"
        echo -e "  ${DIM}[10]${NC} Управление движком"
        echo -e "  ${DIM}[11]${NC} Изменить порт метрик"        
        echo -e "  ${DIM}[16]${NC} Изменить порт REST API [${PROXY_API_PORT:-9091}]"
        echo -e "  ${DIM}[12]${NC} Просмотр текущего конфига"
        echo -e "  ${DIM}[13]${NC} Тюнинг движка (tune) Telemt"
        echo -e "  ${DIM}[14]${NC} Пользовательские URL Telegram"
        echo -e "  ${DIM}[15]${NC} Selfmask (заглушка + сертификат)"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                echo -en "  ${BOLD}Новый порт:${NC} "; local p; read_line p
                if validate_port "$p"; then
                    PROXY_PORT="$p"; save_settings; log_success "Порт: ${p}"
                    is_proxy_running && { load_secrets; restart_proxy_container || true; }
                elif [ -n "$p" ]; then log_error "Некорректный порт"; fi
                press_any_key ;;
            2)
                echo ""
                echo -e "  ${DIM}Введите IPv4-адрес или домен для ссылок на прокси.${NC}"
                echo -e "  ${DIM}auto / clear — использовать автоопределение IP сервера.${NC}"
                echo -e "  ${DIM}Enter — оставить текущее значение.${NC}"
                echo ""
                echo -en "  ${BOLD}IP/домен [${CUSTOM_IP:-авто}]:${NC} "
                local ip=""
                read_line ip
                # Через handle_ip_command, а не своим save_settings: там же
                # перегенерируется конфиг движка, иначе ссылки в панели и у
                # самого движка остаются со старым адресом.
                case "$ip" in
                    auto|clear|AUTO|CLEAR) handle_ip_command auto ;;
                    "") ;;
                    *)
                        if validate_ip_literal "$ip" || validate_domain "$ip"; then
                            handle_ip_command "$ip"
                        else
                            log_error "Некорректный IP-адрес или домен"
                        fi
                        ;;
                esac
                press_any_key ;;
            3)
                if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
                    log_warn "Selfmask активен. Домен меняется через меню Selfmask"
                    press_any_key
                    continue
                fi
                echo ""
                echo -e "  ${DIM}[1] autoscout24.ru  [2] m.beboo.ru  [3] twitch.tv  [4] Свой  [0] Отмена${NC}"
                local d
                d=$(read_choice "выбор" "0")
                case "$d" in
                    0|"")
                        log_info "Отменено"
                        press_any_key
                        continue
                        ;;
                    1) PROXY_DOMAIN="autoscout24.ru" ;;
                    2) PROXY_DOMAIN="m.beboo.ru" ;;
                    3) PROXY_DOMAIN="twitch.tv" ;;
                    4)
                        echo -en "  ${BOLD}Домен:${NC} "
                        local cd=""
                        read_line cd
                        if [ -z "$cd" ]; then
                            log_info "Отменено"
                            press_any_key
                            continue
                        fi
                        if validate_domain "$cd"; then
                            PROXY_DOMAIN="$cd"
                        else
                            log_error "Некорректный домен: ${cd}"
                            press_any_key
                            continue
                        fi
                        ;;
                    *)
                        log_error "Некорректный выбор"
                        press_any_key
                        continue
                        ;;
                esac

                local _old_domain="${PROXY_DOMAIN}"
                auto_set_fake_cert_len "$PROXY_DOMAIN" 2>/dev/null || \
                    log_warn "Не удалось определить TLS cert length для '${PROXY_DOMAIN}', оставляем ${FAKE_CERT_LEN:-2048}"
                save_settings
                log_success "Домен: ${PROXY_DOMAIN}"

                if [ "$MASKING_ENABLED" = "true" ]; then
                    local _cur_mask="${MASKING_HOST:-}"
                    if [ -z "$_cur_mask" ] || [ "$_cur_mask" = "$_old_domain" ]; then
                        echo ""
                        echo -e "  ${YELLOW}Маскировка включена. Mask backend сейчас: ${_cur_mask:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}${NC}"
                        echo -en "  ${BOLD}Обновить mask backend на ${PROXY_DOMAIN}? [Y/n]:${NC} "
                        local _mask_yn=""
                        read_line _mask_yn
                        if [[ ! "$_mask_yn" =~ ^[nN] ]]; then
                            MASKING_HOST="$PROXY_DOMAIN"
                            save_settings
                            log_success "Mask backend обновлён: ${MASKING_HOST}:${MASKING_PORT:-443}"
                        fi
                    fi
                fi

                is_proxy_running && { load_secrets; restart_proxy_container || true; }
                press_any_key ;;
            4)
                echo -en "  ${BOLD}CPU [${PROXY_CPUS:-∞}]:${NC} "; local c; read_line c
                [ -n "$c" ] && PROXY_CPUS="$c"
                echo -en "  ${BOLD}RAM (напр. 256m, 1g) [${PROXY_MEMORY:-∞}]:${NC} "; local m; read_line m
                [ -n "$m" ] && PROXY_MEMORY="$m"
                save_settings; log_success "Ресурсы обновлены"
                press_any_key ;;
            5)
                [ "$MASKING_ENABLED" = "true" ] && MASKING_ENABLED="false" || MASKING_ENABLED="true"
                save_settings; log_success "Маскировка: ${MASKING_ENABLED}"
                is_proxy_running && { load_secrets; restart_proxy_container || true; }
                press_any_key ;;
            6)
                if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
                    log_warn "Selfmask активен. Локальный mask backend управляется через меню Selfmask"
                    press_any_key
                    continue
                fi
                echo -e "  ${DIM}Текущий: ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}${NC}"
                echo -en "  ${BOLD}Хост:${NC} "; local mh; read_line mh
                echo -en "  ${BOLD}Порт [${MASKING_PORT:-443}]:${NC} "; local mp; read_line mp
                [ -n "$mh" ] && MASKING_HOST="$mh"
                [ -n "$mp" ] && [[ "$mp" =~ ^[0-9]+$ ]] && MASKING_PORT="$mp"
                save_settings; log_success "Mask backend: ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}"
                is_proxy_running && { load_secrets; restart_proxy_container || true; }
                press_any_key ;;
            7)
                echo -en "  ${BOLD}Рекл. метка (32 hex, 'remove'):${NC} "; local at; read_line at
                if [ "$at" = "remove" ]; then AD_TAG=""; log_success "Метка удалена"
                elif [[ "$at" =~ ^[0-9a-fA-F]{32}$ ]]; then AD_TAG="$at"; log_success "Метка установлена"
                elif [ -n "$at" ]; then log_error "Нужно 32 hex-символа"; fi
                save_settings; load_secrets; reload_proxy_config 2>/dev/null || true
                press_any_key ;;
            8)
                echo -e "  ${DIM}[1] Mask (перенаправлять)      [2] Drop (закрывать)${NC}"
                echo -e "  ${DIM}[3] Accept (пропускать как есть) [4] Reject handshake (TLS-отказ)${NC}"
                local sc; sc=$(read_choice "выбор" "1")
                case "$sc" in
                    2) UNKNOWN_SNI_ACTION="drop" ;;
                    3) UNKNOWN_SNI_ACTION="accept" ;;
                    4) UNKNOWN_SNI_ACTION="reject_handshake" ;;
                    *) UNKNOWN_SNI_ACTION="mask" ;;
                esac
                save_settings; reload_proxy_config 2>/dev/null || true
                log_success "SNI-политика: ${UNKNOWN_SNI_ACTION}"
                press_any_key ;;
            9)
                [ "$PROXY_PROTOCOL" = "true" ] && PROXY_PROTOCOL="false" || PROXY_PROTOCOL="true"
                if [ "$PROXY_PROTOCOL" = "true" ]; then
                    echo -en "  ${BOLD}Доверенные CIDR (через запятую):${NC} "; local cidrs; read_line cidrs
                    PROXY_PROTOCOL_TRUSTED_CIDRS="$cidrs"
                else PROXY_PROTOCOL_TRUSTED_CIDRS=""; fi
                save_settings; log_success "PROXY protocol: ${PROXY_PROTOCOL}"
                is_proxy_running && { load_secrets; restart_proxy_container || true; }
                press_any_key ;;
            10) tui_engine_menu ;;
            11)
                echo ""
                echo -e "  ${DIM}Порт Prometheus endpoint метрик (только localhost).${NC}"
                echo -e "  ${DIM}Текущий: 127.0.0.1:${PROXY_METRICS_PORT:-9090}${NC}"
                echo ""
                while true; do
                    echo -en "  ${BOLD}Новый порт метрик [${PROXY_METRICS_PORT:-9090}]:${NC} "
                    local _mp; read_line _mp
                    [ -z "$_mp" ] && break
                    if validate_port "$_mp"; then
                        if is_port_available "$_mp"; then
                            PROXY_METRICS_PORT="$_mp"
                            save_settings
                            log_success "Порт метрик установлен: ${PROXY_METRICS_PORT}"
                            is_proxy_running && { load_secrets; restart_proxy_container || true; }
                            break
                        else
                            log_error "Порт ${_mp} уже занят, попробуйте другой"
                        fi
                    else
                        log_error "Некорректный порт"
                    fi
                done
                press_any_key ;;
            16)
                echo ""
                echo -e "  ${DIM}REST API движка (только localhost). Через него работает веб-панель.${NC}"
                echo -e "  ${DIM}Текущий: 127.0.0.1:${PROXY_API_PORT:-9091}${NC}"
                echo -e "  ${YELLOW}После смены порта поправьте адрес в конфиге панели:${NC}"
                echo -e "  ${DIM}  /etc/mtproxyl-panel/config.toml → [telemt] url${NC}"
                echo ""
                while true; do
                    echo -en "  ${BOLD}Новый порт API [${PROXY_API_PORT:-9091}]:${NC} "
                    local _ap; read_line _ap
                    [ -z "$_ap" ] && break
                    if ! validate_port "$_ap"; then
                        log_error "Некорректный порт"; continue
                    fi
                    if [ "$_ap" = "${PROXY_METRICS_PORT:-9090}" ] || [ "$_ap" = "${PROXY_PORT:-443}" ]; then
                        log_error "Этот порт уже занят самим прокси или метриками"; continue
                    fi
                    if is_port_available "$_ap"; then
                        PROXY_API_PORT="$_ap"
                        save_settings
                        log_success "Порт API установлен: ${PROXY_API_PORT}"
                        is_proxy_running && { load_secrets; restart_proxy_container || true; }
                        break
                    fi
                    log_error "Порт ${_ap} уже занят, попробуйте другой"
                done
                press_any_key ;;
            12) show_config; press_any_key ;;
            13)
                run_tune_wizard
                press_any_key ;;
            14)
                echo -e "  ${BOLD}Пользовательские URL Telegram${NC}"
                echo -e "  ${DIM}Для регионов где core.telegram.org заблокирован${NC}"
                echo ""
                echo -e "  proxy_secret_url:    ${PROXY_SECRET_URL:-${DIM}(по умолчанию)${NC}}"
                echo -e "  proxy_config_v4_url: ${PROXY_CONFIG_V4_URL:-${DIM}(по умолчанию)${NC}}"
                echo -e "  proxy_config_v6_url: ${PROXY_CONFIG_V6_URL:-${DIM}(по умолчанию)${NC}}"
                echo ""
                echo -e "  ${DIM}[1] Установить  [2] Очистить все  [0] Назад${NC}"
                local uc; uc=$(read_choice "выбор" "0")
                case "$uc" in
                    1)
                        echo -e "  ${DIM}[1] secret  [2] config-v4  [3] config-v6${NC}"
                        local uf; uf=$(read_choice "выбор" "1")
                        echo -en "  ${BOLD}URL:${NC} "; local uv; read_line uv
                        if [ -n "$uv" ] && [[ "$uv" =~ ^https?:// ]]; then
                            case "$uf" in
                                1) PROXY_SECRET_URL="$uv" ;;
                                2) PROXY_CONFIG_V4_URL="$uv" ;;
                                3) PROXY_CONFIG_V6_URL="$uv" ;;
                            esac
                            save_settings; log_success "URL установлен"
                            is_proxy_running && { load_secrets; restart_proxy_container || true; }
                        elif [ -n "$uv" ]; then log_error "URL должен начинаться с http:// или https://"; fi ;;
                    2) PROXY_SECRET_URL=""; PROXY_CONFIG_V4_URL=""; PROXY_CONFIG_V6_URL=""
                       save_settings; log_success "URL сброшены"
                       is_proxy_running && { load_secrets; restart_proxy_container || true; } ;;
                esac
                press_any_key ;;        
            15) tui_selfmask_menu ;;             
            0|"") return ;;
        esac
    done
}
