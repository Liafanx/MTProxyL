#!/bin/bash
# MTProxyL — блокировка IP адресов и подсетей через nftables

IPBLOCK_TABLE="mtproxyl_block"
IPBLOCK_SERVICE="mtproxyl-block"
IPBLOCK_UNIT="/etc/systemd/system/${IPBLOCK_SERVICE}.service"
IPBLOCK_FILE="${INSTALL_DIR}/ipblock.list"
IPBLOCK_HITS="${INSTALL_DIR}/ipblock-hits.tsv"
IPBLOCK_SNAP="${INSTALL_DIR}/ipblock-hits.snap"

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
    local e="$1"; local addr="$e" mask=""
    [ -n "$e" ] || return 1
    if [[ "$e" == */* ]]; then
        addr="${e%%/*}"; mask="${e##*/}"
        [[ "$mask" =~ ^[0-9]{1,3}$ ]] || return 1
    fi
    if validate_ip_literal "$addr"; then
        [ -n "$mask" ] && { [ "$mask" -ge 0 ] && [ "$mask" -le 32 ] || return 1; }
        echo 4; return 0
    fi
    if [[ "$addr" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$addr" == *:* ]] && [[ ! "$addr" =~ :::+ ]]; then
        local dbl="${addr//[^:]/}"
        [ "${#dbl}" -le 8 ] || return 1
        [ -n "$mask" ] && { [ "$mask" -ge 0 ] && [ "$mask" -le 128 ] || return 1; }
        echo 6; return 0
    fi
    return 1
}

# Список живёт в файле: так в нём можно держать комментарии и переносить
# его целиком между серверами.
ipblock_ensure_file() {
    [ -f "$IPBLOCK_FILE" ] && return 0
    mkdir -p "$INSTALL_DIR"
    {
        echo "# Список заблокированных адресов и подсетей MTProxyL."
        echo "# Одна запись в строке, строки с # — комментарии."
        echo ""
        local x
        for x in ${IPBLOCK_LIST} ${IPBLOCK_LIST6}; do [ -n "$x" ] && echo "$x"; done
    } > "$IPBLOCK_FILE"
    chmod 600 "$IPBLOCK_FILE"
}

# В файле могут быть комментарии и опечатки — наружу отдаём только то,
# что действительно является адресом или подсетью.
ipblock_entries() {
    ipblock_ensure_file
    local e
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$IPBLOCK_FILE" 2>/dev/null | grep -v '^$' \
    | while read -r e; do
        ipblock_family "$e" >/dev/null && echo "$e"
      done
}

ipblock_bad_entries() {
    ipblock_ensure_file
    local e
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$IPBLOCK_FILE" 2>/dev/null | grep -v '^$' \
    | while read -r e; do
        ipblock_family "$e" >/dev/null || echo "$e"
      done
}

# Без конвейера: при set -o pipefail ранний выход grep -q роняет писателя
# по SIGPIPE, и статус всей цепочки становится 141 вместо нуля.
ipblock_has() {
    local e
    while IFS= read -r e; do
        [ "$e" = "$1" ] && return 0
    done <<< "$(ipblock_entries)"
    return 1
}

ipblock_count() { ipblock_entries | wc -l; }

_ipblock_elements() {
    local fam="$1" out="" e f
    while read -r e; do
        f=$(ipblock_family "$e") || continue
        [ "$f" = "$fam" ] || continue
        out="${out}${out:+, }${e}"
    done
    echo "$out"
}

ipblock_rules_active() { nft list table inet "$IPBLOCK_TABLE" &>/dev/null; }
ipblock_remove_rules() { nft delete table inet "$IPBLOCK_TABLE" 2>/dev/null || true; }

ipblock_apply() {
    command -v nft &>/dev/null || { log_error "nftables не установлен"; return 1; }
    ipblock_hits_sample 2>/dev/null || true
    if [ "${IPBLOCK_ENABLED}" != "true" ]; then
        ipblock_remove_rules
        return 0
    fi
    local v4 v6 verdict
    v4=$(ipblock_entries | _ipblock_elements 4)
    v6=$(ipblock_entries | _ipblock_elements 6)
    case "${IPBLOCK_ACTION}" in reject) verdict="reject" ;; *) verdict="drop" ;; esac

    ipblock_remove_rules
    local rules=""
    rules+="table inet ${IPBLOCK_TABLE} {\n"
    rules+="  set v4 {\n    type ipv4_addr\n    flags interval\n    counter\n"
    [ -n "$v4" ] && rules+="    elements = { ${v4} }\n"
    rules+="  }\n"
    rules+="  set v6 {\n    type ipv6_addr\n    flags interval\n    counter\n"
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
    local e="$1" comment="${2:-}" fam
    fam=$(ipblock_family "$e") || { log_error "Не похоже на адрес или подсеть: ${e}"; return 1; }
    ipblock_ensure_file
    if ipblock_has "$e"; then log_info "${e} уже в списке"; return 0; fi
    if [ -n "$comment" ]; then
        printf '%-18s # %s\n' "$e" "$comment" >> "$IPBLOCK_FILE"
    else
        echo "$e" >> "$IPBLOCK_FILE"
    fi
    ipblock_apply || return 1
    log_success "${e} заблокирован (${IPBLOCK_ACTION})"
}

ipblock_del() {
    local e="$1"
    ipblock_has "$e" || { log_error "${e} в списке не найден"; return 1; }
    local tmp; tmp=$(mktemp)
    gawk -v t="$e" '{ l=$0; sub(/#.*/,"",l); gsub(/[[:space:]]/,"",l); if (l != t) print }' \
        "$IPBLOCK_FILE" > "$tmp" && mv "$tmp" "$IPBLOCK_FILE"
    chmod 600 "$IPBLOCK_FILE"
    ipblock_apply || return 1
    log_success "${e} разблокирован"
}

ipblock_clear() {
    ipblock_ensure_file
    { echo "# Список заблокированных адресов и подсетей MTProxyL."
      echo "# Одна запись в строке, строки с # — комментарии."; } > "$IPBLOCK_FILE"
    chmod 600 "$IPBLOCK_FILE"
    ipblock_apply || return 1
    log_success "Список очищен"
}

ipblock_export() { ipblock_ensure_file; cat "$IPBLOCK_FILE"; }

# Импорт принимает тот же формат, что и экспорт: записи и комментарии.
# Дефис вместо пути означает stdin — так список передаёт панель.
ipblock_import() {
    local src="$1" mode="${2:-replace}"
    if [ "$src" = "-" ]; then
        local _stdin; _stdin=$(mktemp)
        cat > "$_stdin"
        ipblock_import "$_stdin" "$mode"; local _rc=$?
        rm -f "$_stdin"
        return $_rc
    fi
    [ -r "$src" ] || { log_error "Файл не читается: ${src}"; return 1; }
    local bad=0 good=0 line clean
    while IFS= read -r line; do
        clean="${line%%#*}"; clean="${clean//[[:space:]]/}"
        [ -n "$clean" ] || continue
        if ipblock_family "$clean" >/dev/null; then good=$((good + 1)); else bad=$((bad + 1)); fi
    done < "$src"
    [ "$good" -gt 0 ] || { log_error "В файле нет ни одной корректной записи"; return 1; }
    ipblock_ensure_file
    if [ "$mode" = "replace" ]; then
        cp "$src" "$IPBLOCK_FILE"
    else
        # При добавлении не плодим дубликаты: уже известные записи пропускаем,
        # комментарии оставляем как есть.
        local _dup=0
        while IFS= read -r line; do
            clean="${line%%#*}"; clean="${clean//[[:space:]]/}"
            if [ -z "$clean" ]; then
                printf '%s\n' "$line" >> "$IPBLOCK_FILE"
            elif ipblock_has "$clean"; then
                _dup=$((_dup + 1))
            else
                printf '%s\n' "$line" >> "$IPBLOCK_FILE"
            fi
        done < "$src"
        [ "$_dup" -gt 0 ] && log_info "Уже было в списке: ${_dup}"
    fi
    chmod 600 "$IPBLOCK_FILE"
    ipblock_apply || return 1
    log_success "Импортировано записей: ${good}$([ "$bad" -gt 0 ] && echo ", пропущено некорректных: ${bad}")"
}

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
    cat > /etc/systemd/system/${IPBLOCK_SERVICE}-hits.service <<UNITEOF
[Unit]
Description=MTProxyL blocklist counters
[Service]
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/mtproxyl.sh block hits-sample
UNITEOF
    cat > /etc/systemd/system/${IPBLOCK_SERVICE}-hits.timer <<'UNITEOF'
[Unit]
Description=MTProxyL blocklist counters every 5 min
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
UNITEOF
    systemctl daemon-reload
    systemctl enable "$IPBLOCK_SERVICE" &>/dev/null || true
    systemctl enable --now "${IPBLOCK_SERVICE}-hits.timer" &>/dev/null || true
}

ipblock_remove_unit() {
    command -v systemctl &>/dev/null || return 0
    systemctl disable "$IPBLOCK_SERVICE" &>/dev/null || true
    systemctl disable --now "${IPBLOCK_SERVICE}-hits.timer" &>/dev/null || true
    rm -f "$IPBLOCK_UNIT" "/etc/systemd/system/${IPBLOCK_SERVICE}-hits.service" \
          "/etc/systemd/system/${IPBLOCK_SERVICE}-hits.timer"
    systemctl daemon-reload
}

ipblock_enable() {
    IPBLOCK_ENABLED="true"; save_settings
    ipblock_apply || return 1
    ipblock_install_unit
    log_success "Блокировка включена (${IPBLOCK_ACTION})"
}

ipblock_disable() {
    ipblock_hits_sample 2>/dev/null || true
    IPBLOCK_ENABLED="false"; save_settings
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

_ipblock_set_counters() {
    nft list set inet "$IPBLOCK_TABLE" "$1" 2>/dev/null | tr '\n' ' ' \
    | gawk '{
        s=$0
        while (match(s, /([0-9a-fA-F:.]+(\/[0-9]+)?)[ \t]+counter packets ([0-9]+) bytes ([0-9]+)/, m)) {
            print m[1] "\t" m[3] "\t" m[4]
            s = substr(s, RSTART+RLENGTH)
        }
      }'
}

# Счётчики ядра обнуляются при перезагрузке и переприменении правил, поэтому
# копим дельты в файл: значение меньше сохранённого означает, что таблицу
# пересоздали, и текущее и есть дельта.
ipblock_hits_sample() {
    ipblock_rules_active || return 0
    mkdir -p "$INSTALL_DIR"; touch "$IPBLOCK_HITS" "$IPBLOCK_SNAP"
    local now; now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    { _ipblock_set_counters v4; _ipblock_set_counters v6; } \
    | gawk -F'\t' -v hits="$IPBLOCK_HITS" -v snap="$IPBLOCK_SNAP" -v now="$now" '
    BEGIN {
        while ((getline l < hits) > 0) { split(l,a,"\t"); hp[a[1]]=a[2]+0; hb[a[1]]=a[3]+0; hf[a[1]]=a[4]; hl[a[1]]=a[5] }
        close(hits)
        while ((getline l < snap) > 0) { split(l,a,"\t"); sp[a[1]]=a[2]+0; sb[a[1]]=a[3]+0 }
        close(snap)
    }
    { ip=$1; p=$2+0; b=$3+0; cp[ip]=p; cb[ip]=b
      dp = (ip in sp && p >= sp[ip]) ? p - sp[ip] : p
      db = (ip in sb && b >= sb[ip]) ? b - sb[ip] : b
      if (dp > 0) { hp[ip]+=dp; hb[ip]+=db; if (hf[ip]=="") hf[ip]=now; hl[ip]=now }
      else if (!(ip in hp)) { hp[ip]=0; hb[ip]=0; hf[ip]=now; hl[ip]="-" }
    }
    END {
        for (i in hp) printf "%s\t%d\t%d\t%s\t%s\n", i, hp[i], hb[i], (hf[i]==""?now:hf[i]), (hl[i]==""?"-":hl[i]) > (hits ".tmp")
        for (i in cp) printf "%s\t%d\t%d\n", i, cp[i], cb[i] > (snap ".tmp")
    }'
    [ -f "${IPBLOCK_HITS}.tmp" ] && mv "${IPBLOCK_HITS}.tmp" "$IPBLOCK_HITS"
    [ -f "${IPBLOCK_SNAP}.tmp" ] && mv "${IPBLOCK_SNAP}.tmp" "$IPBLOCK_SNAP"
    return 0
}

ipblock_hits_total() {
    [ -s "$IPBLOCK_HITS" ] || { echo 0; return 0; }
    gawk -F'\t' '{s+=$2} END {print s+0}' "$IPBLOCK_HITS"
}

# printf в bash считает байты, а не символы — кириллицу дополняем сами.
_ipblock_pad()  { local s="$1" w="$2"; local n=$(( w - ${#s} )); printf '%s' "$s"; [ "$n" -gt 0 ] && printf '%*s' "$n" ''; return 0; }
_ipblock_rpad() { local s="$1" w="$2"; local n=$(( w - ${#s} )); [ "$n" -gt 0 ] && printf '%*s' "$n" ''; printf '%s' "$s"; return 0; }

ipblock_hits_show() {
    ipblock_hits_sample
    [ -s "$IPBLOCK_HITS" ] || { echo "  срабатываний ещё не было"; return 0; }
    echo ""
    printf "  %s %s %s  %s %s\n" \
        "$(_ipblock_pad "адрес" 20)" "$(_ipblock_rpad "пакетов" 12)" "$(_ipblock_rpad "байт" 14)" \
        "$(_ipblock_pad "впервые" 20)" "последний раз"
    echo "  $(printf '─%.0s' $(seq 1 90))"
    sort -t$'\t' -k2,2nr "$IPBLOCK_HITS" | while IFS=$'\t' read -r ip p b f l; do
        printf "  %s %s %s  %s %s\n" \
            "$(_ipblock_pad "$ip" 20)" "$(_ipblock_rpad "$p" 12)" "$(_ipblock_rpad "$b" 14)" \
            "$(_ipblock_pad "${f:0:19}" 20)" "${l:0:19}"
    done
    echo ""
}

ipblock_hits_tsv() {
    ipblock_hits_sample
    [ -s "$IPBLOCK_HITS" ] || return 0
    sort -t$'\t' -k2,2nr "$IPBLOCK_HITS"
}

ipblock_hits_reset() { : > "$IPBLOCK_HITS"; : > "$IPBLOCK_SNAP"; log_success "Счётчики обнулены"; }

ipblock_status_json() {
    local items="" x first=1
    while read -r x; do
        [ "$first" = "1" ] || items="${items},"
        items="${items}\"${x}\""; first=0
    done < <(ipblock_entries)
    printf '{"enabled":%s,"action":"%s","rules_active":%s,"count":%s,"hits_total":%s,"entries":[%s]}\n' \
        "$([ "${IPBLOCK_ENABLED}" = "true" ] && echo true || echo false)" \
        "${IPBLOCK_ACTION}" \
        "$(ipblock_rules_active && echo true || echo false)" \
        "$(ipblock_count)" "$(ipblock_hits_total)" "$items"
}

ipblock_status() {
    echo ""
    echo "  Блокировка IP адресов"
    echo "  ─────────────────────"
    echo "  Состояние:  $([ "${IPBLOCK_ENABLED}" = "true" ] && echo "включена" || echo "выключена")"
    echo "  Действие:   $(ipblock_action_title)"
    echo "  Правила:    $(ipblock_rules_active && echo "применены" || echo "нет")"
    echo "  В списке:   $(ipblock_count)"
    echo "  Отбито:     $(ipblock_hits_total) пакетов"
    local _bad; _bad=$(ipblock_bad_entries | wc -l)
    [ "$_bad" -gt 0 ] && echo "  Непонятных строк в файле: ${_bad}"
    echo "  Файл:       ${IPBLOCK_FILE}"
    echo ""
}

ipblock_show_list() {
    local n; n=$(ipblock_count)
    if [ "$n" = "0" ]; then echo "  список пуст"; return 0; fi
    ipblock_export | sed 's/^/  /'
}

# Правила живут в ядре и перезагрузку не переживают — восстанавливаем при старте.
ipblock_reapply_all() {
    [ "${IPBLOCK_ENABLED}" = "true" ] || return 0
    ipblock_apply
}

handle_block_command() {
    local sub="${1:-status}"; shift 2>/dev/null || true
    case "$sub" in
        add)     if [ -n "${1:-}" ]; then ipblock_add "$1" "${2:-}"; else log_error "Укажите адрес или подсеть"; fi ;;
        del|rm)  if [ -n "${1:-}" ]; then ipblock_del "$1"; else log_error "Укажите адрес или подсеть"; fi ;;
        list)    ipblock_show_list ;;
        export)  ipblock_export ;;
        import)  if [ -n "${1:-}" ]; then ipblock_import "$1" "${2:-replace}"; else log_error "Укажите файл"; fi ;;
        clear)   ipblock_clear ;;
        on)      ipblock_enable ;;
        off)     ipblock_disable ;;
        action)  ipblock_set_action "${1:-}" ;;
        apply)   ipblock_apply ;;
        hits)
            if [ "${1:-}" = "--tsv" ]; then ipblock_hits_tsv; else ipblock_hits_show; fi ;;
        hits-sample) ipblock_hits_sample ;;
        hits-reset)  ipblock_hits_reset ;;
        status)
            if [ "${1:-}" = "--json" ]; then ipblock_status_json; else ipblock_status; fi ;;
        *)
            echo "mtproxyl block {on|off|status [--json]|list|add IP [коммент]|del IP|clear|export|import ФАЙЛ [replace|append]|hits|hits-reset|action drop|reject}" ;;
    esac
}
