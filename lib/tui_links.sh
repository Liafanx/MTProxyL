#!/bin/bash
# MTProxyL — подменю: ссылки 

tui_links_menu() {
    clear_screen
    draw_header "ССЫЛКИ для подключения"
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
