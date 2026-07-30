#!/bin/bash
# MTProxyL — подменю: ссылки 

tui_links_menu() {
    clear_screen
    draw_header "ССЫЛКИ для подключения"

    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        _tui_links_reanimator
        press_any_key
        return
    fi

    local server_ip; server_ip=$(get_public_ip)
    [ -z "$server_ip" ] && { log_error "Не удалось определить IP"; press_any_key; return; }
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

# Ссылки для reanimator-цели: своих секретов у менеджера нет, поэтому
# берём уже готовые ссылки из API самой цели (GET /v1/users), как это
# делает mtpr.sh.
_tui_links_reanimator() {
    if ! _telemt_api_enabled; then
        log_warn "API цели выключено — включите [server.api] enabled = true в ${DETECTED_CONFIG_PATH:-конфиге цели} и перезапустите цель"
        return 1
    fi

    local _json
    _json=$(_get_telemt_users_json) || {
        log_error "API цели недоступно (127.0.0.1:$(_get_telemt_api_port))"
        return 1
    }

    local _tg_links _web_links
    _tg_links=$(grep -oE 'tg://proxy\?[^"]*' <<< "$_json" | sort -u)
    _web_links=$(grep -oE 'https://t\.me/proxy\?[^"]*' <<< "$_json" | sort -u)

    if [ -z "$_tg_links" ] && [ -z "$_web_links" ]; then
        log_warn "Ссылки не найдены в ответе API цели"
        return 1
    fi

    echo ""
    echo -e "  ${DIM}Источник: API цели (127.0.0.1:$(_get_telemt_api_port)/v1/users)${NC}"
    echo ""
    local _l
    while IFS= read -r _l; do
        [ -n "$_l" ] && echo -e "  ${BOLD}TG:${NC}  ${CYAN}${_l}${NC}"
    done <<< "$_tg_links"
    while IFS= read -r _l; do
        [ -n "$_l" ] && echo -e "  ${BOLD}Веб:${NC} ${CYAN}${_l}${NC}"
    done <<< "$_web_links"
}
