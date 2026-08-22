#!/bin/bash
# MTProxyL — блокировка IP адресов и подсетей через nftables

IPBLOCK_TABLE="mtproxyl_block"
IPBLOCK_SERVICE="mtproxyl-block"
IPBLOCK_UNIT="/etc/systemd/system/${IPBLOCK_SERVICE}.service"
IPBLOCK_ENABLED="false"
IPBLOCK_ACTION="drop"
IPBLOCK_LIST=""
IPBLOCK_LIST6=""

ipblock_action_title() {
    case "${IPBLOCK_ACTION:-drop}" in
        reject) echo "reject (отвечать отказом)" ;;
        *)      echo "drop (молча отбрасывать)" ;;
    esac
}

# Возвращает 4 или 6 для корректной записи, иначе ненулевой код.
ipblock_family() {
    local e="$1" addr="$e" mask=""
    [ -n "$e" ] || return 1
    if [[ "$e" == */* ]]; then
        addr="${e%%/*}"; mask="${e##*/}"
        [[ "$mask" =~ ^[0-9]{1,3}$ ]] || return 1
    fi
    if validate_ip_literal "$addr"; then
        [ -n "$mask" ] && { [ "$mask" -ge 0 ] && [ "$mask" -le 32 ] || return 1; }
        echo 4; return 0
    fi
    # IPv6: только допустимые символы и не больше одного «::»
    if [[ "$addr" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$addr" == *:* ]]; then
        local dbl="${addr//[^:]/}"
        [[ "$addr" =~ :::+ ]] && return 1
        [ "${#dbl}" -le 8 ] || return 1
        [ -n "$mask" ] && { [ "$mask" -ge 0 ] && [ "$mask" -le 128 ] || return 1; }
        echo 6; return 0
    fi
    return 1
}

ipblock_has() {
    local e="$1" x
    for x in ${IPBLOCK_LIST} ${IPBLOCK_LIST6}; do
        [ "$x" = "$e" ] && return 0
    done
    return 1
}

_ipblock_elements() {
    local out="" x
    for x in $1; do
        [ -n "$x" ] || continue
        out="${out}${out:+, }${x}"
    done
    echo "$out"
}

ipblock_rules_active() {
    nft list table inet "$IPBLOCK_TABLE" &>/dev/null
}

ipblock_remove_rules() {
    nft delete table inet "$IPBLOCK_TABLE" 2>/dev/null || true
}

ipblock_apply() {
    command -v nft &>/dev/null || { log_error "nftables не установлен"; return 1; }
    if [ "${IPBLOCK_ENABLED}" != "true" ]; then
        ipblock_remove_rules
        return 0
    fi
    local v4 v6 verdict
    v4=$(_ipblock_elements "${IPBLOCK_LIST}")
    v6=$(_ipblock_elements "${IPBLOCK_LIST6}")
    case "${IPBLOCK_ACTION}" in reject) verdict="reject" ;; *) verdict="drop" ;; esac

    ipblock_remove_rules
    local rules=""
    rules+="table inet ${IPBLOCK_TABLE} {\n"
    rules+="  set v4 {\n    type ipv4_addr\n    flags interval\n"
    [ -n "$v4" ] && rules+="    elements = { ${v4} }\n"
    rules+="  }\n"
    rules+="  set v6 {\n    type ipv6_addr\n    flags interval\n"
    [ -n "$v6" ] && rules+="    elements = { ${v6} }\n"
    rules+="  }\n"
    rules+="  chain input {\n"
    rules+="    type filter hook input priority filter - 10; policy accept;\n"
    rules+="    ip saddr @v4 counter ${verdict}\n"
    rules+="    ip6 saddr @v6 counter ${verdict}\n"
    rules+="  }\n"
    rules+="}\n"
    if ! printf "%b" "$rules" | nft -f - 2>/dev/null; then
        log_error "Не удалось применить правила блокировки"
        return 1
    fi
    return 0
}

ipblock_add() {
    local e="$1" fam
    fam=$(ipblock_family "$e") || { log_error "Не похоже на адрес или подсеть: ${e}"; return 1; }
    if ipblock_has "$e"; then
        log_info "${e} уже в списке"
        return 0
    fi
    if [ "$fam" = "6" ]; then
        IPBLOCK_LIST6="${IPBLOCK_LIST6}${IPBLOCK_LIST6:+ }${e}"
    else
        IPBLOCK_LIST="${IPBLOCK_LIST}${IPBLOCK_LIST:+ }${e}"
    fi
    save_settings
    ipblock_apply || return 1
    log_success "${e} заблокирован (${IPBLOCK_ACTION})"
}

ipblock_del() {
    local e="$1" x out=""
    ipblock_has "$e" || { log_error "${e} в списке не найден"; return 1; }
    for x in ${IPBLOCK_LIST}; do [ "$x" = "$e" ] || out="${out}${out:+ }${x}"; done
    IPBLOCK_LIST="$out"; out=""
    for x in ${IPBLOCK_LIST6}; do [ "$x" = "$e" ] || out="${out}${out:+ }${x}"; done
    IPBLOCK_LIST6="$out"
    save_settings
    ipblock_apply || return 1
    log_success "${e} разблокирован"
}

ipblock_clear() {
    IPBLOCK_LIST=""; IPBLOCK_LIST6=""
    save_settings
    ipblock_apply || return 1
    log_success "Список очищен"
}

# Правила nftables перезагрузку не переживают — поднимаем их юнитом при старте.
ipblock_install_unit() {
    command -v systemctl &>/dev/null || return 0
    cat > "$IPBLOCK_UNIT" <<UNITEOF
[Unit]
Description=MTProxyL IP blocklist
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${INSTALL_DIR}/mtproxyl.sh block apply

[Install]
WantedBy=multi-user.target
UNITEOF
    systemctl daemon-reload
    systemctl enable "$IPBLOCK_SERVICE" &>/dev/null || true
}

ipblock_remove_unit() {
    command -v systemctl &>/dev/null || return 0
    systemctl disable "$IPBLOCK_SERVICE" &>/dev/null || true
    rm -f "$IPBLOCK_UNIT"
    systemctl daemon-reload
}

ipblock_enable() {
    IPBLOCK_ENABLED="true"
    save_settings
    ipblock_apply || return 1
    ipblock_install_unit
    log_success "Блокировка включена (${IPBLOCK_ACTION})"
}

ipblock_disable() {
    IPBLOCK_ENABLED="false"
    save_settings
    ipblock_remove_rules
    ipblock_remove_unit
    log_success "Блокировка выключена"
}

ipblock_set_action() {
    case "${1:-}" in
        drop|reject) IPBLOCK_ACTION="$1" ;;
        *) log_error "Допустимо: drop | reject"; return 1 ;;
    esac
    save_settings
    ipblock_apply || return 1
    log_success "Действие: $(ipblock_action_title)"
}

ipblock_count() {
    local n=0 x
    for x in ${IPBLOCK_LIST} ${IPBLOCK_LIST6}; do n=$((n + 1)); done
    echo "$n"
}

# Счётчики берём из ядра: список в настройках и реальные правила могут
# разойтись, если таблицу снесли руками или после перезагрузки.
ipblock_hits() {
    local fam="$1"
    nft list chain inet "$IPBLOCK_TABLE" input 2>/dev/null \
        | grep -E "^\s+${fam} saddr" \
        | grep -oE 'counter packets [0-9]+' | awk '{print $3}' | head -1
}

ipblock_status_json() {
    local v4_json v6_json
    v4_json=$(printf '%s' "${IPBLOCK_LIST}" | tr ' ' '\n' | grep -c . 2>/dev/null || echo 0)
    v6_json=$(printf '%s' "${IPBLOCK_LIST6}" | tr ' ' '\n' | grep -c . 2>/dev/null || echo 0)
    local items="" x first=1
    for x in ${IPBLOCK_LIST} ${IPBLOCK_LIST6}; do
        [ "$first" = "1" ] || items="${items},"
        items="${items}\"${x}\""
        first=0
    done
    printf '{"enabled":%s,"action":"%s","rules_active":%s,"count":%s,"v4":%s,"v6":%s,"hits_v4":%s,"hits_v6":%s,"entries":[%s]}\n' \
        "$([ "${IPBLOCK_ENABLED}" = "true" ] && echo true || echo false)" \
        "${IPBLOCK_ACTION}" \
        "$(ipblock_rules_active && echo true || echo false)" \
        "$(ipblock_count)" "$v4_json" "$v6_json" \
        "$(ipblock_hits ip || echo 0)" "$(ipblock_hits ip6 || echo 0)" \
        "$items"
}

ipblock_status() {
    echo ""
    echo "  Блокировка IP адресов"
    echo "  ─────────────────────"
    echo "  Состояние:  $([ "${IPBLOCK_ENABLED}" = "true" ] && echo "включена" || echo "выключена")"
    echo "  Действие:   $(ipblock_action_title)"
    echo "  Правила:    $(ipblock_rules_active && echo "применены" || echo "нет")"
    echo "  В списке:   $(ipblock_count)"
    local h4 h6
    h4=$(ipblock_hits ip); h6=$(ipblock_hits ip6)
    [ -n "$h4" ] && echo "  Отбито v4:  ${h4}"
    [ -n "$h6" ] && echo "  Отбито v6:  ${h6}"
    echo ""
}

ipblock_show_list() {
    local x
    if [ -z "${IPBLOCK_LIST}${IPBLOCK_LIST6}" ]; then
        echo "  список пуст"
        return 0
    fi
    for x in ${IPBLOCK_LIST} ${IPBLOCK_LIST6}; do echo "  ${x}"; done
}

# Правила живут в ядре и перезагрузку не переживают — восстанавливаем при старте.
ipblock_reapply_all() {
    [ "${IPBLOCK_ENABLED}" = "true" ] || return 0
    ipblock_apply
}

handle_block_command() {
    local sub="${1:-status}"; shift 2>/dev/null || true
    case "$sub" in
        add)     if [ -n "${1:-}" ]; then ipblock_add "$1"; else log_error "Укажите адрес или подсеть"; fi ;;
        del|rm)  if [ -n "${1:-}" ]; then ipblock_del "$1"; else log_error "Укажите адрес или подсеть"; fi ;;
        list)    ipblock_show_list ;;
        clear)   ipblock_clear ;;
        on)      ipblock_enable ;;
        off)     ipblock_disable ;;
        action)  ipblock_set_action "${1:-}" ;;
        apply)   ipblock_apply ;;
        status)
            if [ "${1:-}" = "--json" ]; then ipblock_status_json; else ipblock_status; fi ;;
        *)
            echo "mtproxyl block {on|off|status [--json]|list|add IP|del IP|clear|action drop|reject}" ;;
    esac
}
