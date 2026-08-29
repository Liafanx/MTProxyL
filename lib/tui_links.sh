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
                "$(build_link_secrets "$_sec" "$_dom" "$SUPEREXPERT_FILE")" "false" "$_sec"
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
            "$(build_link_secrets "${SECRETS_KEYS[$i]}")" "true" "${SECRETS_KEYS[$i]}"
    done
    press_any_key
}

# Все рабочие ссылки одного пользователя. Видов может быть несколько: с
# выключенной маскировкой движок принимает и dd, и ee — раньше меню показывало
# только один из них, и вторая половина ссылок оставалась не у дел.
# QR в терминале не рисуем: в узком окне он рассыпается, а ссылку копируют
# текстом. Четвёртый аргумент остался ради совместимости вызовов.
_tui_print_links() {
    local _ip="$1" _port="$2" _pairs="$3" _raw="${5:-}"
    local _kind _sec _label
    while IFS='|' read -r _kind _sec; do
        [ -z "$_sec" ] && continue
        _label="$(link_kind_title "$_kind")"
        echo -e "  ${BOLD}TG${NC} ${DIM}(${_label})${NC}  ${CYAN}tg://proxy?server=${_ip}&port=${_port}&secret=${_sec}${NC}"
        echo -e "  ${BOLD}Веб${NC} ${DIM}(${_label})${NC} ${CYAN}https://t.me/proxy?server=${_ip}&port=${_port}&secret=${_sec}${NC}"
    done <<< "$_pairs"

    # WEB — свой домен и без порта, поэтому строкой отдельно от остальных.
    if [ -n "$_raw" ] && web_is_enabled 2>/dev/null; then
        local _wl; _wl=$(web_link_for_secret "$_raw" 2>/dev/null)
        [ -n "$_wl" ] && echo -e "  ${BOLD}WEB${NC} ${DIM}(WEB)${NC} ${CYAN}${_wl}${NC}"
    fi
}

# Ссылки для reanimator-цели живут в show_target_links_ipv4() (lib/detect.sh) —
# они берутся из API самой цели и переиспользуются после настройки selfmask.
