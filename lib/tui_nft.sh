#!/bin/bash
# MTProxyL — подменю: NFT лимитер + iOS фиксы

tui_nft_menu() {
    while true; do
        clear_screen
        draw_header "NFT ЛИМИТЕР И iOS ФИКСЫ"
        echo ""
        load_nft_settings 2>/dev/null
        echo -e "  ${BOLD}NFT лимитер:${NC} $(nft_status_line)"
        echo -e "  ${BOLD}iOS фикс v1:${NC} $(ios_fix_status_line)"
        echo -e "  ${BOLD}iOS фикс v2:${NC} $(ios2_fix_status_line)"
        echo -e "  ${DIM}rate=${NFT_RATE} burst=${NFT_BURST} timeout=${NFT_METER_TIMEOUT}${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  Применить NFT правила"
        echo -e "  ${CYAN}[2]${NC}  Удалить NFT правила"
        echo -e "  ${CYAN}[3]${NC}  Пресеты"
        echo -e "  ${CYAN}[4]${NC}  Настройки NFT"
        echo -e "  ${CYAN}[5]${NC}  Счётчик дропов"
        echo -e "  ${CYAN}[6]${NC}  Служба NFT"
        echo -e "  ${CYAN}[7]${NC}  Удалить службу"
        echo -e "  ${CYAN}[8]${NC}  Доп. правила"
        echo -e "  ${CYAN}[a]${NC}  iOS Fix v1 (keepalive)"
        echo -e "  ${CYAN}[b]${NC}  iOS Fix v2 (MSS+redirect)"
        echo -e "  ${DIM}[0]${NC}  Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) [ -z "${PROXY_PORT:-}" ] && { log_error "Порт не задан"; press_any_key; continue; }
               apply_nft_rules || true; press_any_key ;;
            2) remove_nft_rules || true; press_any_key ;;
            3) echo -e "  ${RED}[1]${NC} Жёсткий  ${YELLOW}[2]${NC} Средний  ${GREEN}[3]${NC} Мягкий"
               local pc; pc=$(read_choice "выбор" "1")
               case "$pc" in 1) apply_nft_preset hard ;; 2) apply_nft_preset medium ;; 3) apply_nft_preset soft ;; esac
               echo -en "  ${BOLD}Применить? [Y/n]:${NC} "; local yn; read -r yn
               [[ ! "$yn" =~ ^[nN]$ ]] && apply_nft_rules || true; press_any_key ;;
            4) echo -en "  ${BOLD}Rate [${NFT_RATE}]:${NC} "; local r; read -r r; [ -n "$r" ] && NFT_RATE="$r"
               echo -en "  ${BOLD}Burst [${NFT_BURST}]:${NC} "; local b; read -r b; [[ "$b" =~ ^[0-9]+$ ]] && NFT_BURST="$b"
               echo -en "  ${BOLD}Timeout [${NFT_METER_TIMEOUT}]:${NC} "; local t; read -r t; [ -n "$t" ] && NFT_METER_TIMEOUT="$t"
               echo -en "  ${BOLD}IP [${NFT_SERVER_IP:-все}]:${NC} "; local ip; read -r ip
               case "$ip" in none|clear|-) NFT_SERVER_IP="" ;; "") ;; *) NFT_SERVER_IP="$ip" ;; esac
               save_nft_settings; log_success "Настройки обновлены"
               echo -en "  ${BOLD}Применить? [Y/n]:${NC} "; local yn; read -r yn
               [[ ! "$yn" =~ ^[nN]$ ]] && apply_nft_rules || true; press_any_key ;;
            5) show_nft_drop_counter || true ;;
            6) install_nft_service || true; press_any_key ;;
            7) remove_nft_service || true; press_any_key ;;
            8) tui_nft_extra ;;
            a|A) tui_ios1 ;;
            b|B) tui_ios2 ;;
            0|"") return ;;
        esac
    done
}

tui_nft_extra() {
    clear_screen; draw_header "ДОПОЛНИТЕЛЬНЫЕ ПРАВИЛА"
    echo ""
    if [ "$NFT_EXTRA_COUNT" -eq 0 ]; then echo -e "  ${DIM}Нет${NC}"
    else local i; for i in $(seq 1 "$NFT_EXTRA_COUNT"); do
        echo -e "  ${DIM}[$i]${NC} порт=${NFT_EXTRA_PORT[$i]:-?} ip=${NFT_EXTRA_IP[$i]:-все}"; done; fi
    echo ""; echo -e "  ${DIM}[a] Добавить  [d] Удалить  [0] Назад${NC}"
    local c; c=$(read_choice "выбор" "0")
    case "$c" in
        a|A) echo -en "  Порт: "; local p; read -r p
             echo -en "  IP (пусто=все): "; local ip; read -r ip
             nft_extra_add "$p" "$ip" || true
             echo -en "  ${BOLD}Применить? [Y/n]:${NC} "; local yn; read -r yn
             [[ ! "$yn" =~ ^[nN]$ ]] && apply_nft_rules || true ;;
        d|D) echo -en "  #: "; local idx; read -r idx
             nft_extra_remove "$idx" || true
             echo -en "  ${BOLD}Применить? [Y/n]:${NC} "; local yn; read -r yn
             [[ ! "$yn" =~ ^[nN]$ ]] && apply_nft_rules || true ;;
    esac; press_any_key
}

tui_ios1() {
    clear_screen; draw_header "iOS FIX v1 — TCP KEEPALIVE"
    echo -e "  Статус: $(ios_fix_status_line)"; echo ""
    echo -e "  ${DIM}[1] Применить  [2] Откатить  [0] Назад${NC}"
    local c; c=$(read_choice "выбор" "0")
    case "$c" in 1) ios_fix_apply || true ;; 2) ios_fix_remove || true ;; esac; press_any_key
}

tui_ios2() {
    clear_screen; draw_header "iOS FIX v2 — MSS + REDIRECT"
    echo -e "  Статус: $(ios2_fix_status_line)"
    echo -e "  Порт: ${IOS2_EXTERNAL_PORT}  MSS: ${IOS2_MSS}"; echo ""
    echo -e "  ${DIM}[1] Применить  [2] Откатить  [3] Порт  [4] MSS  [0] Назад${NC}"
    local c; c=$(read_choice "выбор" "0")
    case "$c" in
        1) ios2_fix_apply || true ;;
        2) ios2_fix_remove || true ;;
        3) echo -en "  Порт: "; local p; read -r p
           [[ "$p" =~ ^[0-9]+$ ]] && { IOS2_EXTERNAL_PORT="$p"; save_nft_settings; } ;;
        4) echo -en "  MSS: "; local m; read -r m
           [[ "$m" =~ ^[0-9]+$ ]] && { IOS2_MSS="$m"; save_nft_settings; } ;;
    esac; press_any_key
}
