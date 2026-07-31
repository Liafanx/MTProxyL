#!/bin/bash
# MTProxyL — подменю: ссылки 

tui_links_menu() {
    clear_screen
    draw_header "ССЫЛКИ для подключения"

    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        show_target_links_ipv4 || true
        press_any_key
        return
    fi

    local server_ip; server_ip=$(get_public_ip)
    [ -z "$server_ip" ] && { log_error "Не удалось определить IP"; press_any_key; return; }

    # В режиме супер эксперта секреты живут в конфиге пользователя, а не в
    # secrets.conf — иначе показали бы ссылки, которых на прокси уже нет.
    if _superexpert_active; then
        local _dom _port _u _sec _fs
        _dom=$(_toml_get_string_in_section "censorship" "tls_domain" "$SUPEREXPERT_FILE" 2>/dev/null)
        _port=$(_toml_get_string_in_section "server" "port" "$SUPEREXPERT_FILE" 2>/dev/null)
        [ -n "$_port" ] || _port="${PROXY_PORT}"
        echo ""
        echo -e "  ${DIM}Источник: ваш конфиг ${SUPEREXPERT_FILE}${NC}"
        [ -z "$_dom" ] && log_warn "В конфиге нет [censorship] tls_domain — ссылки будут без домена"
        while IFS='|' read -r _u _sec; do
            [ -z "$_u" ] && continue
            if [ -n "$_dom" ]; then
                _fs="ee${_sec}$(domain_to_hex "$_dom")"
            else
                _fs="dd${_sec}"
            fi
            echo ""
            echo -e "  ${BRIGHT_GREEN}${BOLD}${_u}${NC}"
            echo -e "  ${DIM}$(_repeat '─' 40)${NC}"
            echo -e "  ${BOLD}TG:${NC}  ${CYAN}tg://proxy?server=${server_ip}&port=${_port}&secret=${_fs}${NC}"
            echo -e "  ${BOLD}Веб:${NC} ${CYAN}https://t.me/proxy?server=${server_ip}&port=${_port}&secret=${_fs}${NC}"
        done <<< "$(_superexpert_users)"
        press_any_key
        return
    fi

    local i; for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        local fs; fs=$(build_faketls_secret "${SECRETS_KEYS[$i]}")
        echo ""
        echo -e "  ${BRIGHT_GREEN}${BOLD}${SECRETS_LABELS[$i]}${NC}"
        echo -e "  ${DIM}$(_repeat '─' 40)${NC}"
        echo -e "  ${BOLD}TG:${NC}  ${CYAN}tg://proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${fs}${NC}"
        echo -e "  ${BOLD}Веб:${NC} ${CYAN}https://t.me/proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${fs}${NC}"
        command -v qrencode &>/dev/null && { echo ""; qrencode -t ANSIUTF8 "https://t.me/proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${fs}" 2>/dev/null | sed 's/^/  /'; }
    done
    press_any_key
}

# Ссылки для reanimator-цели живут в show_target_links_ipv4() (lib/detect.sh) —
# они берутся из API самой цели и переиспользуются после настройки selfmask.
