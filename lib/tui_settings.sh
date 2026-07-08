#!/bin/bash
# MTProxyL — подменю: настройки

tui_settings_menu() {
    while true; do
        clear_screen
        draw_header "НАСТРОЙКИ"
        echo ""
        echo -e "  ${BOLD}Порт:${NC}              ${PROXY_PORT}"
        echo -e "  ${BOLD}IP/домен сервера:${NC}  ${CUSTOM_IP:-$(get_public_ip 2>/dev/null) ${DIM}(авто)${NC}}"
        echo -e "  ${BOLD}Домен(SNI):${NC}        ${PROXY_DOMAIN}"
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
        echo -e "  ${DIM}[m]${NC} Mask backend (хост:порт)"
        echo -e "  ${DIM}[6]${NC} Рекламная метка"
        echo -e "  ${DIM}[7]${NC} SNI-политика [${UNKNOWN_SNI_ACTION}]"
        echo -e "  ${DIM}[8]${NC} PROXY protocol вкл/выкл"
        echo -e "  ${DIM}[9]${NC} Управление движком"
        echo -e "  ${DIM}[g]${NC} Изменить порт метрик"        
        echo -e "  ${DIM}[v]${NC} Просмотр текущего конфига"
        echo -e "  ${DIM}[t]${NC} Тюнинг движка (tune) Telemt"
        echo -e "  ${DIM}[u]${NC} Пользовательские URL Telegram"
        echo -e "  ${DIM}[h]${NC} Selfmask (nginx + Let's Encrypt)"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                echo -en "  ${BOLD}Новый порт:${NC} "; local p; read -r p
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
                read -r ip
                case "$ip" in
                    auto|clear|AUTO|CLEAR)
                        CUSTOM_IP=""
                        save_settings
                        log_success "IP: авто ($(get_public_ip 2>/dev/null || echo '?'))"
                        ;;
                    "")
                        ;;
                    *)
                        if validate_ip_literal "$ip"; then
                            CUSTOM_IP="$ip"
                            save_settings
                            log_success "IP: ${ip}"
                        elif validate_domain "$ip"; then
                            CUSTOM_IP="$ip"
                            save_settings
                            log_success "Домен: ${ip}"
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
                        read -r cd
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
                        read -r _mask_yn
                        if [[ ! "$_mask_yn" =~ ^[nN]$ ]]; then
                            MASKING_HOST="$PROXY_DOMAIN"
                            save_settings
                            log_success "Mask backend обновлён: ${MASKING_HOST}:${MASKING_PORT:-443}"
                        fi
                    fi
                fi

                is_proxy_running && { load_secrets; restart_proxy_container || true; }
                press_any_key ;;
            4)
                echo -en "  ${BOLD}CPU [${PROXY_CPUS:-∞}]:${NC} "; local c; read -r c
                [ -n "$c" ] && PROXY_CPUS="$c"
                echo -en "  ${BOLD}RAM (напр. 256m, 1g) [${PROXY_MEMORY:-∞}]:${NC} "; local m; read -r m
                [ -n "$m" ] && PROXY_MEMORY="$m"
                save_settings; log_success "Ресурсы обновлены"
                press_any_key ;;
            5)
                [ "$MASKING_ENABLED" = "true" ] && MASKING_ENABLED="false" || MASKING_ENABLED="true"
                save_settings; log_success "Маскировка: ${MASKING_ENABLED}"
                is_proxy_running && { load_secrets; restart_proxy_container || true; }
                press_any_key ;;
            m|M)
                if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
                    log_warn "Selfmask активен. Локальный mask backend управляется через меню Selfmask"
                    press_any_key
                    continue
                fi
                echo -e "  ${DIM}Текущий: ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}${NC}"
                echo -en "  ${BOLD}Хост:${NC} "; local mh; read -r mh
                echo -en "  ${BOLD}Порт [${MASKING_PORT:-443}]:${NC} "; local mp; read -r mp
                [ -n "$mh" ] && MASKING_HOST="$mh"
                [ -n "$mp" ] && [[ "$mp" =~ ^[0-9]+$ ]] && MASKING_PORT="$mp"
                save_settings; log_success "Mask backend: ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}"
                is_proxy_running && { load_secrets; restart_proxy_container || true; }
                press_any_key ;;
            6)
                echo -en "  ${BOLD}Рекл. метка (32 hex, 'remove'):${NC} "; local at; read -r at
                if [ "$at" = "remove" ]; then AD_TAG=""; log_success "Метка удалена"
                elif [[ "$at" =~ ^[0-9a-fA-F]{32}$ ]]; then AD_TAG="$at"; log_success "Метка установлена"
                elif [ -n "$at" ]; then log_error "Нужно 32 hex-символа"; fi
                save_settings; load_secrets; reload_proxy_config 2>/dev/null || true
                press_any_key ;;
            7)
                echo -e "  ${DIM}[1] Mask (перенаправлять)  [2] Drop (закрывать)${NC}"
                local sc; sc=$(read_choice "выбор" "1")
                case "$sc" in 2) UNKNOWN_SNI_ACTION="drop" ;; *) UNKNOWN_SNI_ACTION="mask" ;; esac
                save_settings; reload_proxy_config 2>/dev/null || true
                log_success "SNI-политика: ${UNKNOWN_SNI_ACTION}"
                press_any_key ;;
            8)
                [ "$PROXY_PROTOCOL" = "true" ] && PROXY_PROTOCOL="false" || PROXY_PROTOCOL="true"
                if [ "$PROXY_PROTOCOL" = "true" ]; then
                    echo -en "  ${BOLD}Доверенные CIDR (через запятую):${NC} "; local cidrs; read -r cidrs
                    PROXY_PROTOCOL_TRUSTED_CIDRS="$cidrs"
                else PROXY_PROTOCOL_TRUSTED_CIDRS=""; fi
                save_settings; log_success "PROXY protocol: ${PROXY_PROTOCOL}"
                is_proxy_running && { load_secrets; restart_proxy_container || true; }
                press_any_key ;;
            9) tui_engine_menu ;;
            g|G)
                echo ""
                echo -e "  ${DIM}Порт Prometheus endpoint метрик (только localhost).${NC}"
                echo -e "  ${DIM}Текущий: 127.0.0.1:${PROXY_METRICS_PORT:-9090}${NC}"
                echo ""
                while true; do
                    echo -en "  ${BOLD}Новый порт метрик [${PROXY_METRICS_PORT:-9090}]:${NC} "
                    local _mp; read -r _mp
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
            v|V) show_config; press_any_key ;;
            t|T)
                handle_tune_command list
                echo -e "  ${DIM}[1] Установить  [2] Очистить  [3] Очистить все  [0] Назад${NC}"
                local tc; tc=$(read_choice "выбор" "0")
                case "$tc" in
                    1) echo -en "  ${BOLD}Параметр:${NC} "; local tp; read -r tp
                       echo -en "  ${BOLD}Значение:${NC} "; local tv; read -r tv
                       [ -n "$tp" ] && [ -n "$tv" ] && handle_tune_command set "$tp" "$tv" ;;
                    2) echo -en "  ${BOLD}Параметр:${NC} "; local tp; read -r tp
                       [ -n "$tp" ] && handle_tune_command clear "$tp" ;;
                    3) handle_tune_command clear all ;;
                esac
                press_any_key ;;
            u|U)
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
                        echo -en "  ${BOLD}URL:${NC} "; local uv; read -r uv
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
             h|H) tui_selfmask_menu ;;             
            0|"") return ;;
        esac
    done
}
