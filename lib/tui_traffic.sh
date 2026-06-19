#!/bin/bash
# MTProxyL — подменю: логи и трафик

tui_traffic_menu() {
    while true; do
        clear_screen
        draw_header "ЛОГИ И ТРАФИК"

        if ! is_proxy_running; then
            echo -e "  ${DIM}Прокси не запущен${NC}"; press_any_key; return
        fi

        local t_in t_out conns
        read -r t_in t_out conns <<< "$(get_proxy_stats)"
        echo ""
        echo -e "  ${BOLD}Общий трафик${NC}"
        echo -e "  ${SYM_DOWN} Скачано:    $(format_bytes "$t_in")"
        echo -e "  ${SYM_UP} Отправлено: $(format_bytes "$t_out")"
        echo -e "  ${BOLD}Активных соединений:${NC} ${conns}"
        echo ""

        echo -e "  ${BOLD}По пользователям${NC}"
        echo -e "  ${DIM}$(_repeat '─' 60)${NC}"
        local i; for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
            local label="${SECRETS_LABELS[$i]}"
            local u_in u_out u_conns
            read -r u_in u_out u_conns <<< "$(get_user_stats "$label")"
            echo -e "  ${GREEN}${SYM_OK}${NC} ${BOLD}${label}${NC}"
            echo -e "    ${SYM_DOWN} $(format_bytes "$u_in")  ${SYM_UP} $(format_bytes "$u_out")  соед: ${u_conns}"
        done
        echo ""
        echo -e "  ${DIM}[1]${NC} Потоковые логи"
        echo -e "  ${DIM}[2]${NC} Метрики движка"
        echo -e "  ${DIM}[3]${NC} Метрики движка (live)"
        echo -e "  ${DIM}[4]${NC} Активные соединения"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) echo -e "  ${DIM}Ctrl+C для остановки...${NC}"; docker logs -f --tail 30 "$CONTAINER_NAME" 2>&1; ;;
            2) show_metrics 2>/dev/null || log_error "Метрики недоступны"; press_any_key ;;
            3) tui_metrics_live ;;
            4) show_connections; press_any_key ;;
            0|"") return ;;
        esac
    done
}

tui_metrics_live() {
    local interval=5
    trap 'return 0' INT
    while true; do
        clear_screen
        show_metrics 2>/dev/null || { log_error "Метрики недоступны"; break; }
        echo -e "  ${DIM}[обновление каждые ${interval}с, Ctrl+C для остановки]${NC}"
        sleep "$interval" || break
    done
    trap - INT
}

show_metrics() {
    local m
    m=$(_fetch_metrics 2>/dev/null) || { log_error "Эндпоинт метрик недоступен"; return 1; }

    local parsed
    parsed=$(echo "$m" | awk '
        function lbl(s, k,    p, q) {
            p = index(s, k "=\""); if (!p) return ""
            s = substr(s, p + length(k) + 2)
            q = index(s, "\""); return q ? substr(s, 1, q-1) : ""
        }
        /^telemt_uptime_seconds /                  { uptime = $NF }
        /^telemt_connections_total /                { c_tot  = $NF }
        /^telemt_connections_bad_total /            { c_bad  = $NF }
        /^telemt_connections_current /              { c_cur  = $NF }
        /^telemt_upstream_connect_attempt_total /   { up_att = $NF }
        /^telemt_upstream_connect_success_total /   { up_ok  = $NF }
        /^telemt_upstream_connect_fail_total /      { up_fail= $NF }
        /^telemt_user_connections_current\{/ { u=lbl($0,"user"); if(u) uc[u]+=$NF }
        /^telemt_user_octets_from_client\{/  { u=lbl($0,"user"); if(u) rx[u]+=$NF }
        /^telemt_user_octets_to_client\{/    { u=lbl($0,"user"); if(u) tx[u]+=$NF }
        /^telemt_user_unique_ips_current\{/  { u=lbl($0,"user"); if(u) ui[u]+=$NF }
        END {
            printf "S|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f\n",
                uptime+0,c_tot+0,c_bad+0,c_cur+0,up_att+0,up_ok+0,up_fail+0
            for (u in uc)
                printf "U|%s|%.0f|%.0f|%.0f|%.0f\n", u, uc[u]+0, rx[u]+0, tx[u]+0, ui[u]+0
        }
    ')

    local uptime c_tot c_bad c_cur up_att up_ok up_fail
    IFS='|' read -r _ uptime c_tot c_bad c_cur up_att up_ok up_fail <<< "$(echo "$parsed" | grep '^S|')"

    local c_good=$(( ${c_tot:-0} - ${c_bad:-0} ))

    draw_header "МЕТРИКИ"
    echo -e "  ${DIM}аптайм:${NC} $(format_duration "${uptime:-0}")   ${DIM}активных:${NC} ${c_cur:-0}"
    echo ""
    echo -e "  ${BOLD}Соединения${NC}"
    echo -e "  ${DIM}всего:${NC} ${c_tot:-0}   ${DIM}авторизованных:${NC} ${BRIGHT_GREEN}${c_good}${NC}   ${DIM}отклонённых:${NC} ${BRIGHT_RED}${c_bad:-0}${NC}"
    echo ""
    echo -e "  ${BOLD}Upstream${NC}"
    echo -e "  ${DIM}попыток:${NC} ${up_att:-0}   ${DIM}успешных:${NC} ${BRIGHT_GREEN}${up_ok:-0}${NC}   ${DIM}ошибок:${NC} ${BRIGHT_RED}${up_fail:-0}${NC}"
    echo ""

    local user_lines
    user_lines=$(echo "$parsed" | grep '^U|' | sort -t'|' -k3 -rn)
    if [ -n "$user_lines" ]; then
        echo -e "  ${BOLD}Пользователи${NC}"
        while IFS='|' read -r _ uname ucur urx utx uips; do
            echo -e "  ${GREEN}${SYM_OK}${NC} ${BOLD}${uname}${NC}  активных: ${ucur}  ${SYM_DOWN} $(format_bytes "$urx")  ${SYM_UP} $(format_bytes "$utx")  IP: ${uips}"
        done <<< "$user_lines"
        echo ""
    fi
}
