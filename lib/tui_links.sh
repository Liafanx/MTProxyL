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

    # [general.links] public_host/public_port — то, что идёт в ссылку, отдельно
    # от того, где движок слушает (например, за NAT).
    local server_ip server_port
    server_ip=$(proxy_link_host)
    server_port=$(proxy_link_port)
    [ -z "$server_ip" ] && { log_error "Не удалось определить IP"; press_any_key; return; }

    # В режиме супер эксперта секреты живут в конфиге пользователя, а не в
    # secrets.conf — иначе показали бы ссылки, которых на прокси уже нет.
    if _superexpert_active; then
        local _dom _u _sec
        _dom=$(_toml_get_string_in_section "censorship" "tls_domain" "$SUPEREXPERT_FILE" 2>/dev/null)
        echo ""
        echo -e "  ${DIM}Источник: ваш конфиг ${SUPEREXPERT_FILE}${NC}"
        [ -z "$_dom" ] && log_warn "В конфиге нет [censorship] tls_domain — ссылки будут без домена"
        while IFS='|' read -r _u _sec; do
            [ -z "$_u" ] && continue
            echo ""
            echo -e "  ${BRIGHT_GREEN}${BOLD}${_u}${NC}"
            echo -e "  ${DIM}$(_repeat '─' 40)${NC}"
            _tui_print_links "$server_ip" "$server_port" \
                "$(build_link_secrets "$_sec" "$_dom" "$SUPEREXPERT_FILE")" "false"
        done <<< "$(_superexpert_users)"
        press_any_key
        return
    fi

    local i; for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        echo ""
        echo -e "  ${BRIGHT_GREEN}${BOLD}${SECRETS_LABELS[$i]}${NC}"
        echo -e "  ${DIM}$(_repeat '─' 40)${NC}"
        _tui_print_links "$server_ip" "$server_port" \
            "$(build_link_secrets "${SECRETS_KEYS[$i]}")" "true"
    done
    press_any_key
}

# Все рабочие ссылки одного пользователя. Видов может быть несколько: с
# выключенной маскировкой движок принимает и dd, и ee — раньше меню показывало
# только один из них, и вторая половина ссылок оставалась не у дел.
# QR печатаем один, для первой ссылки: их и так по две на человека.
_tui_print_links() {
    local _ip="$1" _port="$2" _pairs="$3" _qr="${4:-false}"
    local _kind _sec _first=1 _label
    while IFS='|' read -r _kind _sec; do
        [ -z "$_sec" ] && continue
        _label="$(link_kind_title "$_kind")"
        echo -e "  ${BOLD}TG${NC} ${DIM}(${_label})${NC}  ${CYAN}tg://proxy?server=${_ip}&port=${_port}&secret=${_sec}${NC}"
        echo -e "  ${BOLD}Веб${NC} ${DIM}(${_label})${NC} ${CYAN}https://t.me/proxy?server=${_ip}&port=${_port}&secret=${_sec}${NC}"
        if [ "$_qr" = "true" ] && [ $_first -eq 1 ] && command -v qrencode &>/dev/null; then
            echo ""
            qrencode -t ANSIUTF8 "https://t.me/proxy?server=${_ip}&port=${_port}&secret=${_sec}" 2>/dev/null | sed 's/^/  /'
        fi
        _first=0
    done <<< "$_pairs"
}

# Ссылки для reanimator-цели живут в show_target_links_ipv4() (lib/detect.sh) —
# они берутся из API самой цели и переиспользуются после настройки selfmask.
