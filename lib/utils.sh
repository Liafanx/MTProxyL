#!/bin/bash
# MTProxyL — утилиты

log_info()    { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[${SYM_CHECK}]${NC} $1"; }
log_warn()    { echo -e "  ${YELLOW}[${SYM_WARN}]${NC} $1" >&2; }
log_error()   { echo -e "  ${RED}[${SYM_CROSS}]${NC} $1" >&2; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "MTProxyL должен запускаться от root"
        exit 1
    fi
}

# Гвард для команд, бессмысленных/опасных в режиме reanimator
# (владение конфигом/движком, которого у reanimator-цели нет)
_require_manager_mode() {
    [ "${MTPROXYL_MODE:-manager}" = "manager" ] && return 0
    log_error "Команда недоступна в режиме reanimator (нет владения конфигом/движком цели)"
    return 1
}

# Гвард для операций, которые пишут в config.toml: в режиме супер эксперта
# конфиг ведёт пользователь, и любые правки менеджера всё равно были бы
# затёрты его файлом при следующем запуске.
_require_no_superexpert() {
    _superexpert_active 2>/dev/null || return 0
    log_error "Недоступно: включён режим супер эксперта — конфигом управляете вы"
    log_info "Правьте ${SUPEREXPERT_FILE} и перезапускайте прокси (или выключите режим)"
    return 1
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|pop|linuxmint|kali|raspbian|devuan|neon|zorin|elementary)
                echo "debian"; return ;;
            centos|rhel|fedora|rocky|alma|almalinux|oracle|ol|amzn|cloudlinux|navylinux|circle)
                echo "rhel"; return ;;
            alpine) echo "alpine"; return ;;
        esac
        # ID неизвестен — опираемся на ID_LIKE, чтобы производные дистрибутивы
        # (AlmaLinux, Rocky, Mint и т.п.) не отваливались в "unknown".
        case " ${ID_LIKE:-} " in
            *" debian "*|*" ubuntu "*)              echo "debian"; return ;;
            *" rhel "*|*" fedora "*|*" centos "*)   echo "rhel";   return ;;
            *" alpine "*)                            echo "alpine"; return ;;
        esac
        echo "unknown"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

# Экранирование строки для вставки в JSON-литерал.
# Нужно для машинного вывода (--json), который разбирает панель.
json_escape() {
    local _s="$1"
    _s="${_s//\\/\\\\}"
    _s="${_s//\"/\\\"}"
    _s="${_s//$'\t'/\\t}"
    _s="${_s//$'\r'/}"
    _s="${_s//$'\n'/\\n}"
    printf '%s' "$_s"
}

# Тот же результат, но в $_JSON_ESCAPE_OUT вместо stdout — для циклов, где
# "$(json_escape ...)" означает форк подшелла на каждый вызов.
_JSON_ESCAPE_OUT=""
json_escape_fast() {
    local _s="$1"
    _s="${_s//\\/\\\\}"
    _s="${_s//\"/\\\"}"
    _s="${_s//$'\t'/\\t}"
    _s="${_s//$'\r'/}"
    _s="${_s//$'\n'/\\n}"
    _JSON_ESCAPE_OUT="$_s"
}

format_bytes() {
    local bytes=$1
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if [ "$bytes" -lt 1024 ] 2>/dev/null; then
        echo "${bytes} Б"
    elif [ "$bytes" -lt 1048576 ] 2>/dev/null; then
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.1f", b/1024}') КБ"
    elif [ "$bytes" -lt 1073741824 ] 2>/dev/null; then
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1048576}') МБ"
    else
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1073741824}') ГБ"
    fi
}

format_duration() {
    local secs=$1
    [[ "$secs" =~ ^-?[0-9]+$ ]] || secs=0
    [ "$secs" -lt 1 ] && { echo "0с"; return; }
    local days=$((secs / 86400))
    local hours=$(( (secs % 86400) / 3600 ))
    local mins=$(( (secs % 3600) / 60 ))
    if [ "$days" -gt 0 ]; then echo "${days}д ${hours}ч ${mins}м"
    elif [ "$hours" -gt 0 ]; then echo "${hours}ч ${mins}м"
    elif [ "$mins" -gt 0 ]; then echo "${mins}м"
    else echo "${secs}с"; fi
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_domain() {
    local d="$1"
    [ -z "$d" ] && return 1
    [[ "$d" =~ ^[a-zA-Z0-9.-]+$ ]] && [[ "$d" =~ \. ]]
}

detect_tls_cert_len() {
    local domain="$1"
    [ -n "$domain" ] || return 1
    command -v openssl &>/dev/null || return 1

    local _pem=""
    if command -v timeout &>/dev/null; then
        _pem=$(timeout 8 openssl s_client -servername "$domain" -connect "${domain}:443" -showcerts </dev/null 2>/dev/null | \
            awk '/-----BEGIN CERTIFICATE-----/{p=1} p{print} /-----END CERTIFICATE-----/{exit}')
    else
        _pem=$(openssl s_client -servername "$domain" -connect "${domain}:443" -showcerts </dev/null 2>/dev/null | \
            awk '/-----BEGIN CERTIFICATE-----/{p=1} p{print} /-----END CERTIFICATE-----/{exit}')
    fi

    [ -n "$_pem" ] || return 1

    local _len
    _len=$(printf '%s\n' "$_pem" | openssl x509 -outform DER 2>/dev/null | wc -c | tr -d ' ')
    [[ "$_len" =~ ^[0-9]+$ ]] || return 1
    [ "$_len" -ge 512 ] && [ "$_len" -le 65535 ] || return 1

    echo "$_len"
}

# Смыть то, что осталось в буфере терминала. После ssh-copy-id с несколькими
# попытками пароля лишние Enter отвечали за пользователя на следующий вопрос,
# и он проскакивал незаметно.
drain_tty_input() {
    [ -t 0 ] || return 0
    local _junk
    while read -r -t 0.05 -n 256 _junk 2>/dev/null; do :; done
    return 0
}

# ── Swap на маленькой машине ──────────────────────────────────
# Сборка панели, docker и telemt на 1 ГБ без подкачки заканчиваются OOM:
# процесс убивает ядро, а установка выглядит зависшей.
SWAPFILE_PATH="/swapfile"
SWAPFILE_SIZE_MB=1024
# Порог в МиБ: у «гигабайтной» машины free показывает чуть меньше 1024.
LOW_RAM_THRESHOLD_MB=1024

total_ram_mb() {
    awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}

# Проверять «-s /proc/swaps» нельзя: у файлов procfs размер всегда нулевой,
# и подкачка выглядела выключенной, даже когда работала.
swap_active() {
    awk 'NR>1 {found=1} END {exit !found}' /proc/swaps 2>/dev/null
}

# Свободно на разделе, где будет лежать файл подкачки, в МиБ.
_swap_target_free_mb() {
    df -Pm "$(dirname "$SWAPFILE_PATH")" 2>/dev/null | awk 'NR==2 {print $4}'
}

create_swapfile() {
    local _mb="${1:-$SWAPFILE_SIZE_MB}"
    if [ -e "$SWAPFILE_PATH" ]; then
        log_warn "${SWAPFILE_PATH} уже существует — не трогаем"
        return 1
    fi
    local _free; _free=$(_swap_target_free_mb)
    # Запас: файл ровно по размеру свободного места оставит систему без диска.
    if [ -n "$_free" ] && [ "$_free" -lt $((_mb + 512)) ]; then
        log_error "На диске свободно ${_free} МБ — для файла подкачки ${_mb} МБ мало"
        return 1
    fi

    log_info "Создаём файл подкачки ${_mb} МБ в ${SWAPFILE_PATH}..."
    if ! fallocate -l "${_mb}M" "$SWAPFILE_PATH" 2>/dev/null; then
        # fallocate не работает на некоторых ФС — тогда медленно, но верно.
        dd if=/dev/zero of="$SWAPFILE_PATH" bs=1M count="$_mb" status=none 2>/dev/null || {
            log_error "Не удалось создать ${SWAPFILE_PATH}"
            rm -f "$SWAPFILE_PATH"
            return 1
        }
    fi
    chmod 600 "$SWAPFILE_PATH"
    if ! mkswap "$SWAPFILE_PATH" >/dev/null 2>&1 || ! swapon "$SWAPFILE_PATH" 2>/dev/null; then
        log_error "Подкачку включить не вышло — в контейнерах (OpenVZ, LXC) это запрещено"
        swapoff "$SWAPFILE_PATH" 2>/dev/null || true
        rm -f "$SWAPFILE_PATH"
        return 1
    fi
    grep -qF "$SWAPFILE_PATH" /etc/fstab 2>/dev/null || \
        echo "${SWAPFILE_PATH} none swap sw 0 0" >> /etc/fstab
    log_success "Подкачка включена: ${_mb} МБ, переживёт перезагрузку"
    return 0
}

# Предлагаем подкачку там, где памяти мало и её нет. Ответ по умолчанию — да:
# без неё установка на такой машине падает чаще, чем проходит.
offer_swap_if_low_ram() {
    local _ram; _ram=$(total_ram_mb)
    [ "${_ram:-0}" -gt 0 ] || return 0
    [ "$_ram" -le "$LOW_RAM_THRESHOLD_MB" ] || return 0
    if swap_active; then
        log_info "Памяти ${_ram} МБ, подкачка уже есть — хорошо"
        return 0
    fi

    echo ""
    log_warn "Памяти ${_ram} МБ и подкачки нет"
    echo -e "  ${DIM}Docker, движок и сборка панели на такой машине упираются в${NC}"
    echo -e "  ${DIM}нехватку памяти: ядро убивает процесс, а установка выглядит${NC}"
    echo -e "  ${DIM}зависшей. Файл подкачки ${SWAPFILE_SIZE_MB} МБ это лечит.${NC}"
    echo -en "  ${BOLD}Создать файл подкачки ${SWAPFILE_SIZE_MB} МБ? [Y/n]:${NC} "
    local _yn; _fix_read _yn ""
    [[ "$_yn" =~ ^[nN] ]] && { log_info "Пропускаем. Создать позже: mtproxyl swap on"; return 0; }
    create_swapfile "$SWAPFILE_SIZE_MB" || \
        log_warn "Продолжаем без подкачки — следите за памятью"
    return 0
}

swap_status() {
    local _ram; _ram=$(total_ram_mb)
    echo -e "  ${BOLD}Память:${NC}   ${_ram} МБ"
    if swap_active; then
        local _sw; _sw=$(awk 'NR>1 {s+=$3} END {printf "%d", s/1024}' /proc/swaps 2>/dev/null)
        echo -e "  ${BOLD}Подкачка:${NC} ${GREEN}есть${NC} ${DIM}(${_sw} МБ)${NC}"
        awk 'NR>1 {printf "    %s  %d МБ\n", $1, $3/1024}' /proc/swaps 2>/dev/null
    else
        echo -e "  ${BOLD}Подкачка:${NC} ${DIM}нет${NC}"
        [ "${_ram:-0}" -le "$LOW_RAM_THRESHOLD_MB" ] && \
            log_warn "Памяти мало — на такой машине установка может упереться в OOM"
    fi
}

swap_off_and_remove() {
    check_root
    swap_active || { log_info "Подкачка не включена"; return 0; }
    [ -f "$SWAPFILE_PATH" ] || { log_error "Файл ${SWAPFILE_PATH} не наш — выключайте сами"; return 1; }
    swapoff "$SWAPFILE_PATH" 2>/dev/null || { log_error "Выключить подкачку не вышло"; return 1; }
    sed -i "\|^${SWAPFILE_PATH} |d" /etc/fstab 2>/dev/null || true
    rm -f "$SWAPFILE_PATH"
    log_success "Подкачка выключена, файл удалён"
}

handle_swap_command() {
    case "${1:-status}" in
        status|"") swap_status ;;
        on|add)
            check_root
            swap_active && { log_info "Подкачка уже включена"; swap_status; return 0; }
            create_swapfile "${2:-$SWAPFILE_SIZE_MB}" ;;
        off|remove) swap_off_and_remove ;;
        *)
            echo -e "  ${BOLD}Файл подкачки:${NC}"
            echo -e "    ${GREEN}swap status${NC}     Память и подкачка сейчас"
            echo -e "    ${GREEN}swap on${NC} [МБ]    Создать и включить (по умолчанию ${SWAPFILE_SIZE_MB} МБ)"
            echo -e "    ${GREEN}swap off${NC}        Выключить и удалить ${SWAPFILE_PATH}"
            ;;
    esac
}

# Длина leaf-сертификата из готового файла. При Selfmask сертификат уже лежит
# на диске, а спрашивать его у домена по сети бесполезно: на 443 этого адреса
# отвечает сам прокси, а не наш nginx, и замер всегда проваливался.
tls_cert_len_from_file() {
    local _file="$1"
    [ -f "$_file" ] || return 1
    command -v openssl &>/dev/null || return 1
    local _len
    _len=$(awk '/-----BEGIN CERTIFICATE-----/{p=1} p{print} /-----END CERTIFICATE-----/{exit}' "$_file" \
        | openssl x509 -outform DER 2>/dev/null | wc -c | tr -d ' ')
    [[ "$_len" =~ ^[0-9]+$ ]] || return 1
    [ "$_len" -ge 512 ] && [ "$_len" -le 65535 ] || return 1
    echo "$_len"
}

# Второй аргумент — путь к своему сертификату: если он есть, берём длину из
# него, а сеть не трогаем вовсе.
auto_set_fake_cert_len() {
    local domain="$1" _file="${2:-}"
    [ -n "$domain" ] || return 1
    local _old="${FAKE_CERT_LEN:-2048}"
    local _new=""
    if [ -n "$_file" ]; then
        _new=$(tls_cert_len_from_file "$_file" 2>/dev/null) || _new=""
    fi
    [ -n "$_new" ] || _new=$(detect_tls_cert_len "$domain" 2>/dev/null) || return 1
    [ -n "$_new" ] || return 1
    if [ "$_new" != "$_old" ]; then
        FAKE_CERT_LEN="$_new"
        log_info "Auto-detected TLS cert length for '${domain}': ${FAKE_CERT_LEN} bytes (was ${_old})"
    else
        log_info "TLS cert length for '${domain}': ${FAKE_CERT_LEN} bytes"
    fi
    return 0
}

parse_human_bytes() {
    local input="${1:-0}"
    input="${input^^}"
    local num unit
    if [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)[[:space:]]*(B|K|KB|M|MB|G|GB|T|TB)?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]:-B}"
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"; return 0
    else
        echo "0"; return 1
    fi
    case "$unit" in
        B)        awk -v n="$num" 'BEGIN {printf "%d", n}' ;;
        K|KB)     awk -v n="$num" 'BEGIN {printf "%d", n * 1024}' ;;
        M|MB)     awk -v n="$num" 'BEGIN {printf "%d", n * 1048576}' ;;
        G|GB)     awk -v n="$num" 'BEGIN {printf "%d", n * 1073741824}' ;;
        T|TB)     awk -v n="$num" 'BEGIN {printf "%d", n * 1099511627776}' ;;
        *)        echo "0"; return 1 ;;
    esac
}

# Адрес сервера для ссылок и правил. IPv4 в приоритете: tg://-ссылка с голым
# IPv6 не открывается, а по цепочке через `||` сервис, ответивший пустотой с
# кодом 0, обрывал перебор — и адрес оставался пустым или приходил IPv6.
get_public_ip() {
    if [ -n "${CUSTOM_IP}" ]; then
        echo "${CUSTOM_IP}"; return 0
    fi
    local _svc _ip=""
    for _svc in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
        _ip=$(curl -4 -s --max-time 3 "$_svc" 2>/dev/null | tr -d '[:space:]')
        validate_ip_literal "$_ip" && { echo "$_ip"; return 0; }
    done
    # Наружу не достучались — берём свой глобальный IPv4, мимо docker-мостов.
    _ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
        | grep -vE '^(172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.)' | head -1)
    validate_ip_literal "$_ip" && { echo "$_ip"; return 0; }
    # IPv4 нет вовсе — отдаём IPv6: ссылка неудобна, но адрес верный.
    for _svc in https://api64.ipify.org https://ifconfig.me; do
        _ip=$(curl -s --max-time 3 "$_svc" 2>/dev/null | tr -d '[:space:]')
        [ -n "$_ip" ] && { echo "$_ip"; return 0; }
    done
    echo ""
}

# ── Публичные host/port для tg://-ссылок ───────────────────────
# [general.links] public_host/public_port — что идёт в ссылку, отдельно от
# того, где движок слушает. Источник зависит от режима.
proxy_link_host() {
    local _host=""
    if _superexpert_active 2>/dev/null; then
        _host=$(_toml_get_string_in_section "general.links" "public_host" "$SUPEREXPERT_FILE" 2>/dev/null)
    else
        _host=$(get_expert_override_value "general.links" "public_host" 2>/dev/null)
    fi
    [ -n "$_host" ] || _host=$(get_public_ip)
    echo "$_host"
}

# Хост для [general.links] public_host из настройки «IP/домен сервера».
# Пусто — движок определяет сам. IPv6-литерал тоже оставляем ему: в ссылку
# он идёт в скобках.
proxy_public_host() {
    local _v="${CUSTOM_IP:-}"
    [ -n "$_v" ] || return 1
    case "$_v" in *:*) return 1 ;; esac   # IPv6
    printf '%s' "$_v"
}

proxy_link_port() {
    local _port=""
    if _superexpert_active 2>/dev/null; then
        _port=$(_toml_get_string_in_section "general.links" "public_port" "$SUPEREXPERT_FILE" 2>/dev/null)
        [ -n "$_port" ] || _port=$(_toml_get_string_in_section "server" "port" "$SUPEREXPERT_FILE" 2>/dev/null)
    else
        _port=$(get_expert_override_value "general.links" "public_port" 2>/dev/null)
    fi
    [ -n "$_port" ] || _port="${PROXY_PORT}"
    echo "$_port"
}

generate_secret() {
    openssl rand -hex 16 2>/dev/null || {
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32
    }
}

domain_to_hex() {
    printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

build_faketls_secret() {
    local raw_secret="$1" domain="${2:-$PROXY_DOMAIN}"
    if [ "${MASKING_ENABLED:-true}" = "false" ]; then
        echo "dd${raw_secret}"
    else
        local domain_hex
        domain_hex=$(domain_to_hex "$domain")
        echo "ee${raw_secret}${domain_hex}"
    fi
}

# Какие виды ссылок движок принимает прямо сейчас — по одному имени в строке,
# в том же порядке, в каком telemt печатает их в журнале при запуске.
# У менеджера правду знает settings.conf: конфиг движка мы из него и
# генерируем. В режиме супер эксперта и у чужой цели конфиг ведём не мы,
# поэтому режимы читаем прямо из [general.modes]; ключа там нет — берём
# умолчание telemt (classic и secure выключены, tls включён).
engine_link_modes() {
    local _cfg="${1:-}"
    if [ -z "$_cfg" ] \
        && [ "${MTPROXYL_MODE:-manager}" = "manager" ] \
        && ! _superexpert_active 2>/dev/null; then
        [ "${MASKING_ENABLED:-true}" = "false" ] && echo "secure"
        echo "tls"
        return 0
    fi
    [ -n "$_cfg" ] || _cfg=$(_engine_config_path 2>/dev/null)
    local _c="" _s="" _t=""
    if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
        _c=$(_toml_get_string_in_section "general.modes" "classic" "$_cfg" 2>/dev/null)
        _s=$(_toml_get_string_in_section "general.modes" "secure"  "$_cfg" 2>/dev/null)
        _t=$(_toml_get_string_in_section "general.modes" "tls"     "$_cfg" 2>/dev/null)
    fi
    [ "$_c" = "true" ] && echo "classic"
    [ "$_s" = "true" ] && echo "secure"
    [ "$_t" != "false" ] && echo "tls"
    return 0
}

# Строки "вид|секрет" на один сырой секрет — по строке на каждый включённый
# вид ссылки. Пока маскировка была единственным переключателем, хватало
# одного секрета; с выключенной маскировкой движок принимает и dd, и ee, и
# показывать только один из них значило бы прятать половину рабочих ссылок.
build_link_secrets() {
    local _raw="$1" _domain="${2:-$PROXY_DOMAIN}" _cfg="${3:-}"
    local _mode _hex="" _has_dd=""
    while read -r _mode; do
        case "$_mode" in
            classic) printf 'classic|%s\n' "$_raw" ;;
            secure)  _has_dd=1; printf 'secure|dd%s\n' "$_raw" ;;
            tls)
                # ee без домена — не ссылка, а обрубок. Отдаём вместо неё dd:
                # так вело себя и старое построение ссылок.
                if [ -z "$_domain" ]; then
                    [ -n "$_has_dd" ] || printf 'secure|dd%s\n' "$_raw"
                    continue
                fi
                [ -n "$_hex" ] || _hex=$(domain_to_hex "$_domain")
                printf 'tls|ee%s%s\n' "$_raw" "$_hex" ;;
        esac
    done < <(engine_link_modes "$_cfg")
}

# Как называть вид ссылки в меню.
link_kind_title() {
    case "$1" in
        classic) echo "classic" ;;
        secure)  echo "dd · secure" ;;
        tls)     echo "ee · TLS" ;;
        *)       echo "$1" ;;
    esac
}

_iso_to_epoch() {
    local ts="$1"
    [ -z "$ts" ] && { echo "0"; return; }
    local ts_clean="${ts%%.*}"
    # Дробную часть отрезаем вместе с суффиксом Z — возвращаем его обратно,
    # но только если он действительно потерялся: иначе получалось "...ZZ",
    # и date отказывался разбирать штамп без дробной части.
    [[ "$ts" == *Z ]] && [[ "$ts_clean" != *Z ]] && ts_clean="${ts_clean}Z"
    local epoch
    epoch=$(date -d "${ts_clean}" +%s 2>/dev/null) && [ "$epoch" -gt 0 ] 2>/dev/null && { echo "$epoch"; return; }
    local ts_bb="${ts_clean%Z}"
    epoch=$(date -D '%Y-%m-%dT%H:%M:%S' -d "${ts_bb}" +%s 2>/dev/null) && [ "$epoch" -gt 0 ] 2>/dev/null && { echo "$epoch"; return; }
    echo "0"
}

# Ожидание apt lock
_wait_apt() {
    local _waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        [ $_waited -eq 0 ] && log_info "apt занят, ждём..."
        sleep 3; _waited=$((_waited + 3))
        [ $_waited -ge 60 ] && break
    done
}

# TUI helpers
_strlen() {
    local clean="$1"
    local esc=$'\033'
    clean="${clean//$'\\033'/$esc}"
    while [[ "$clean" == *"${esc}["* ]]; do
        local before="${clean%%${esc}\[*}"
        local rest="${clean#*${esc}\[}"
        local after="${rest#*m}"
        [ "$rest" = "$after" ] && break
        clean="${before}${after}"
    done
    echo "${#clean}"
}

# Дополнение по числу символов, а не байтов: printf %-Ns считает байты, и
# колонки с кириллицей разъезжаются.
_pad() {
    local _s="$1" _w="${2:-0}" _plain _len
    _plain="${_s//[$'\x80'-$'\xbf']/}"
    _len=${#_plain}
    if [ "$_len" -ge "$_w" ]; then
        printf '%s' "$_s"
    else
        printf '%s%*s' "$_s" $(( _w - _len )) ''
    fi
}

# Обрезка строки до N символов с многоточием (для колонок таблиц)
_ellipsis() {
    local _s="$1" _w="${2:-0}" _plain
    _plain="${_s//[$'\x80'-$'\xbf']/}"
    [ "${#_plain}" -le "$_w" ] && { printf '%s' "$_s"; return; }
    printf '%s…' "${_s:0:$(( _w - 1 ))}"
}

_repeat() {
    local char="$1" count="$2" str
    printf -v str '%*s' "$count" ''
    printf '%s' "${str// /$char}"
}

draw_line() {
    local width="${1:-$TERM_WIDTH}" char="${2:-$BOX_H}" color="${3:-$DIM}"
    echo -e "${color}$(_repeat "$char" "$width")${NC}"
}

draw_header() {
    local title="$1"
    echo ""
    echo -e "  ${BRIGHT_CYAN}${SYM_ARROW} ${BOLD}${title}${NC}"
    echo -e "  ${DIM}$(_repeat '─' $((${#title} + 2)))${NC}"
}

draw_status() {
    local status="$1" label="${2:-}"
    case "$status" in
        running|up|true|enabled|active)
            echo -e "${BRIGHT_GREEN}${SYM_OK}${NC} ${GREEN}${label:-РАБОТАЕТ}${NC}" ;;
        stopped|down|false|disabled|inactive)
            echo -e "${BRIGHT_RED}${SYM_OK}${NC} ${RED}${label:-ОСТАНОВЛЕН}${NC}" ;;
        *)
            echo -e "${DIM}${SYM_OK}${NC} ${DIM}${label:-НЕИЗВЕСТНО}${NC}" ;;
    esac
}

press_any_key() {
    echo ""
    echo -en "  ${DIM}Нажмите любую клавишу...${NC}"
    read -rsn1
    read -rn 256 -t 0.05 _ 2>/dev/null || true
    echo ""
}

# Чтение строки после приглашения из отдельного echo: на пустом вводе
# readline завершает строку одним \r, и следующий вывод затирает приглашение.
# Ответ на вопрос мастера. При установке аргументами читать некому — берём
# заранее заданный ответ и печатаем его, чтобы лог выглядел как диалог.
_fix_read() {
    local _var="$1" _preset="${2-}"
    if [ "${MTPROXYL_NONINTERACTIVE:-false}" = "true" ]; then
        printf -v "$_var" '%s' "$_preset"
        echo "${_preset:-<по умолчанию>}"
        return 0
    fi
    read_line "$_var"
}

read_line() {
    local __var="$1" __ans=""
    # Неинтерактивный режим (панель, скрипты): подтверждения не спрашиваем.
    # Отдаём слово, которого ждут все подтверждающие ветки: 'yes' проходит
    # и строгие проверки [ "$_c" != "yes" ], и мягкие [[ =~ ^[yY] ]].
    if [ "${MTPROXYL_ASSUME_YES:-}" = "1" ]; then
        printf -v "$__var" '%s' "yes"
        return 0
    fi
    IFS= read -er __ans || true
    [ -z "$__ans" ] && [ -t 0 ] && echo ""
    printf -v "$__var" '%s' "$__ans"
}

read_choice() {
    local prompt="${1:-выбор}"
    local default="${2:-}"
    # В неинтерактивном режиме берём значение по умолчанию — оно везде
    # выставлено на рекомендуемый вариант.
    if [ "${MTPROXYL_ASSUME_YES:-}" = "1" ]; then
        echo "$default"
        return 0
    fi
    fix_tty_input
    # Сброс «набранного вперёд» имеет смысл только на терминале: из пайпа
    # это съело бы реальный ввод.
    [ -t 0 ] && { read -rn 256 -t 0.05 _ 2>/dev/null || true; }
    echo "" >&2
    local _p="  Введите ${prompt,,}"
    [ -n "$default" ] && _p+=" [${default}]"
    _p+=": "
    local choice
    read -erp "$_p" choice
    [ -z "$choice" ] && choice="$default"
    echo "$choice"
}

clear_screen() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo -e "${BRIGHT_CYAN}${BOLD}  MTProxyL${NC} ${DIM}v${VERSION}${NC} ${DIM}by LiafanX${NC}"
    echo -e "  ${DIM}$(_repeat '─' 30)${NC}"
}

fix_tty_input() {
    [ -t 0 ] || return 0
    # Запоминаем символ забоя: терминалы шлют либо ^? (0x7f), либо ^H (0x08),
    # а stty sane сбрасывает настройку пользователя.
    local _erase=""
    _erase=$(stty -a 2>/dev/null | sed -n 's/.*erase = \([^;]*\);.*/\1/p' | tr -d '[:space:]')
    stty sane 2>/dev/null || true
    stty iutf8 2>/dev/null || true
    case "$_erase" in
        '^H'|'^?') stty erase "$_erase" 2>/dev/null || true ;;
    esac
}

# ── Проверка обновлений ───────────────────────────────────────
_UPDATE_AVAILABLE=""

check_for_update() {
    local _remote_ver
    _remote_ver=$(curl -fsS --max-time 5 "${GITHUB_RAW}/version" 2>/dev/null | tr -d '[:space:]')
    [ -z "$_remote_ver" ] && return 0
    # Только строго новее: на dev-сборке локальная версия обгоняет ветку, и
    # «доступно обновление 1.4.9 → 1.4.8» звалось бы откатом назад.
    if _version_gt "$_remote_ver" "$VERSION"; then
        _UPDATE_AVAILABLE="$_remote_ver"
    else
        _UPDATE_AVAILABLE=""
    fi
}

# 0, если $1 строго новее $2.
_version_gt() {
    [ -n "$1" ] || return 1
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | tail -1)" = "$1" ]
}

# Машинная проверка обновления для панели. Root не нужен: только запрос к
# github. Сетевой сбой — не ошибка команды, о нём говорит поле error.
update_check_json() {
    local _latest _err="" _avail="false"
    _latest=$(curl -fsS --max-time 8 "${GITHUB_RAW}/version" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$_latest" ]; then
        _err="не удалось получить номер версии с github.com"
    elif ! [[ "$_latest" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        _err="github.com вернул не номер версии"
        _latest=""
    elif _version_gt "$_latest" "$VERSION"; then
        _avail="true"
    fi

    local _url=""
    [ -n "$_latest" ] && _url="https://github.com/${GITHUB_REPO}/releases/tag/v${_latest}"

    printf '{"current":"%s","latest":"%s","update_available":%s,"branch":"%s","release_url":"%s","error":"%s"}\n' \
        "$VERSION" "$_latest" "$_avail" "${GITHUB_BRANCH}" "$_url" "$_err"
}

# --no-restart: не перезапускать меню в конце. Из панели exec подменил бы
# процесс интерактивным TUI, которому неоткуда читать ввод.
self_update() {
    local _restart="true"
    [ "${1:-}" = "--no-restart" ] && _restart="false"

    echo ""
    draw_header "ОБНОВЛЕНИЕ MTPROXYL"
    echo ""

    log_info "Шаг 1/4: Скачивание основного скрипта..."
    # Рядом с целью, а не в /tmp: перенос между файловыми системами перезаписал
    # бы файл на месте, а его в этот момент читает работающий bash.
    local _tmp="${INSTALL_DIR}/.mtproxyl-update-$$.sh"

    if ! curl -fsS --retry 3 --retry-delay 2 --max-time 30 "${GITHUB_RAW}/mtproxyl.sh" -o "$_tmp" 2>/dev/null; then
        log_error "Не удалось скачать mtproxyl.sh"
        log_info "Проверьте интернет и доступность github.com"
        rm -f "$_tmp"
        return 1
    fi
    log_success "mtproxyl.sh скачан"

    log_info "Шаг 2/4: Проверка синтаксиса..."
    if ! bash -n "$_tmp" 2>/dev/null; then
        log_error "Ошибка синтаксиса в скачанном скрипте — обновление отменено"
        rm -f "$_tmp"
        return 1
    fi

    local _new_ver
    _new_ver=$(grep -m1 '^VERSION="' "$_tmp" | cut -d'"' -f2)
    if [ -z "$_new_ver" ]; then
        log_error "Не удалось определить версию нового скрипта"
        rm -f "$_tmp"
        return 1
    fi

    if [ "$_new_ver" = "$VERSION" ]; then
        log_success "Версия актуальна (v${VERSION})"
        rm -f "$_tmp"
        return 0
    fi

    log_info "Текущая версия: v${VERSION}"
    log_info "Новая версия:   v${_new_ver}"
    echo ""

    log_info "Шаг 3/4: Замена основного скрипта..."
    cp "${INSTALL_DIR}/mtproxyl.sh" "${INSTALL_DIR}/mtproxyl.sh.backup-$(date +%s)" 2>/dev/null || true
    mv "$_tmp" "${INSTALL_DIR}/mtproxyl.sh"
    chmod +x "${INSTALL_DIR}/mtproxyl.sh"
    log_success "mtproxyl.sh обновлён"
    echo ""

    log_info "Шаг 4/4: Обновление библиотек..."
    mkdir -p "$LIB_DIR"

    local _lib_list
    _lib_list=$(grep -oP 'for _lib in \K[^\n;]+' "${INSTALL_DIR}/mtproxyl.sh" 2>/dev/null | head -1 | tr -d '"' | tr -d "'")

    if [ -z "$_lib_list" ]; then
        log_warn "Не удалось извлечь список библиотек из нового скрипта"
        log_info "Используем резервный список"
        _lib_list="colors utils settings secrets config docker engine traffic availability dc warp tui_warp tgbot tui_tgbot geoblock geoip upstream backup nft selfmask panel detect tui_main tui_proxy tui_secrets tui_links tui_settings tui_security tui_traffic tui_engine tui_backup tui_expert tui_nft tui_selfmask tui_addons tui_detect expert_catalog expert_mode settings_cli install install_args migrate"
    fi

    local _total=0 _ok=0 _failed=0 _skipped=0
    local _failed_list=""

    for _w in $_lib_list; do _total=$((_total + 1)); done

    local _current=0
    local lib _lib_tmp
    for lib in $_lib_list; do
        _current=$((_current + 1))

        local _lib_tmp
        _lib_tmp=$(mktemp "${LIB_DIR}/.${lib}.sh.XXXXXX") || {
            echo -e "  ${RED}[${_current}/${_total}]${NC} ${lib}.sh — не удалось создать временный файл"
            _failed=$((_failed + 1))
            _failed_list="${_failed_list} ${lib}.sh"
            continue
        }

        if curl -fsS --retry 3 --retry-delay 2 --max-time 20 "${GITHUB_RAW}/lib/${lib}.sh" -o "$_lib_tmp" 2>/dev/null; then
            if bash -n "$_lib_tmp" 2>/dev/null; then
                mv "$_lib_tmp" "${LIB_DIR}/${lib}.sh"
                chmod 644 "${LIB_DIR}/${lib}.sh" 2>/dev/null || true
                echo -e "  ${GREEN}[${_current}/${_total}]${NC} ${lib}.sh ${GREEN}✓${NC}"
                _ok=$((_ok + 1))
            else
                rm -f "$_lib_tmp"
                echo -e "  ${YELLOW}[${_current}/${_total}]${NC} ${lib}.sh — ошибка синтаксиса, оставлена старая версия"
                _skipped=$((_skipped + 1))
                _failed_list="${_failed_list} ${lib}.sh"
            fi
        else
            rm -f "$_lib_tmp"
            echo -e "  ${RED}[${_current}/${_total}]${NC} ${lib}.sh — не удалось скачать"
            _failed=$((_failed + 1))
            _failed_list="${_failed_list} ${lib}.sh"
        fi

        sleep 0.15
    done

    echo ""
    echo -e "  ${BOLD}Итог обновления библиотек:${NC}"
    echo -e "    ${GREEN}Обновлено:${NC}     ${_ok}/${_total}"
    [ "$_skipped" -gt 0 ] && echo -e "    ${YELLOW}Пропущено:${NC}     ${_skipped} (ошибка синтаксиса)"
    [ "$_failed" -gt 0 ] && echo -e "    ${RED}Не удалось:${NC}    ${_failed}"
    echo ""

    if [ "$_failed" -gt 0 ] || [ "$_skipped" -gt 0 ]; then
        log_warn "Часть библиотек не обновилась:${_failed_list}"
        log_info "Старые версии файлов сохранены, можно продолжать работу"
        log_info "Повторите обновление позже: mtproxyl update"
        echo ""
    fi

    # Код бота живёт в том же репозитории и обновляется вместе со скриптом:
    # иначе бот однажды позовёт подкоманду, которой в его правах ещё нет.
    if tgbot_installed 2>/dev/null; then
        log_info "Обновляем телеграм-бота..."
        if tgbot_update_sources; then
            log_success "Телеграм-бот обновлён и перезапущен"
        else
            log_warn "Код бота обновить не удалось — повторите: mtproxyl tgbot update"
        fi
    fi

    log_success "MTProxyL обновлён: v${VERSION} → v${_new_ver}"
    if [ "$_restart" = "false" ]; then
        return 0
    fi
    log_info "Перезапуск..."
    exec "${INSTALL_DIR}/mtproxyl.sh"
}

# ── CLI-обработчики для быстрых команд ────────────────────────
handle_port_command() {
    local new_port="${1:-}"
    if [ -z "$new_port" ]; then
        echo -e "  ${BOLD}Порт:${NC} ${PROXY_PORT}"
        return 0
    fi
    _require_manager_mode || return 1
    _require_no_superexpert || return 1
    check_root
    if validate_port "$new_port"; then
        local _port_before="${PROXY_PORT}"
        PROXY_PORT="$new_port"
        save_settings
        log_success "Порт: ${PROXY_PORT}"
        # Правила гео-блокировки прибиты к порту: после смены они остались
        # бы висеть на старом и не защищали новый.
        if [ -n "${BLOCKLIST_COUNTRIES:-}" ] && [ "$_port_before" != "$PROXY_PORT" ]; then
            log_info "Перенос правил гео-блокировки на порт ${PROXY_PORT}..."
            geoblock_remove_all >/dev/null 2>&1 || true
            geoblock_reapply_all >/dev/null 2>&1 || true
            geoblock_rules_active && log_success "Гео-блокировка переприменена" \
                || log_warn "Гео-блокировку переприменить не удалось: mtproxyl geoblock reapply"
        fi
        if is_proxy_running; then
            load_secrets
            restart_proxy_container || true
        fi
    else
        log_error "Некорректный порт: ${new_port} (допустимо 1..65535)"
        return 1
    fi
}

handle_ip_command() {
    local new_ip="${1:-}"
    if [ -z "$new_ip" ]; then
        local current="${CUSTOM_IP:-$(get_public_ip 2>/dev/null)}"
        echo -e "  ${BOLD}IP:${NC} ${current}$([ -z "$CUSTOM_IP" ] && echo " ${DIM}(авто)${NC}")"
        return 0
    fi
    check_root
    case "$new_ip" in
        auto|clear|reset)
            CUSTOM_IP=""
            save_settings
            log_success "IP: авто ($(get_public_ip 2>/dev/null || echo '?'))"
            ;;
        *)
            CUSTOM_IP="$new_ip"
            save_settings
            log_success "IP: ${CUSTOM_IP}"
            ;;
    esac

    # Ссылки движок собирает из [general.links] public_host своего конфига:
    # без перегенерации смена IP меняла только то, что печатает CLI.
    if [ "${MTPROXYL_MODE:-manager}" = "manager" ] && ! _superexpert_active 2>/dev/null; then
        reload_proxy_config >/dev/null 2>&1 || true
    elif [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        log_info "В реаниматоре ссылки собирает цель — задайте у неё [general.links] public_host"
    fi
}

handle_domain_command() {
    local new_domain="${1:-}"
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] && [ -n "$new_domain" ]; then
        log_warn "Selfmask активен. Домен управляется через 'mtproxyl selfmask setup'"
        return 1
    fi
    if [ -z "$new_domain" ]; then
        echo -e "  ${BOLD}Домен:${NC} ${PROXY_DOMAIN}"
        return 0
    fi
    _require_manager_mode || return 1
    _require_no_superexpert || return 1
    check_root
    if validate_domain "$new_domain"; then
        local _old_domain="$PROXY_DOMAIN"
        PROXY_DOMAIN="$new_domain"
        auto_set_fake_cert_len "$PROXY_DOMAIN" 2>/dev/null || \
            log_warn "Не удалось определить TLS cert length для '${PROXY_DOMAIN}', оставляем ${FAKE_CERT_LEN:-2048}"
        save_settings
        log_success "Домен: ${PROXY_DOMAIN}"
        # Предложить обновить mask backend
        if [ "$MASKING_ENABLED" = "true" ] && [ "$PROXY_DOMAIN" != "$_old_domain" ]; then
            local _cur_mask="${MASKING_HOST:-$_old_domain}"
            if [ "$_cur_mask" = "$_old_domain" ] || [ -z "$MASKING_HOST" ]; then
                echo -en "  ${BOLD}Обновить mask backend на ${PROXY_DOMAIN}? [Y/n]:${NC} "
                local _mask_yn; read_line _mask_yn
                if [[ ! "$_mask_yn" =~ ^[nN] ]]; then
                    MASKING_HOST="$PROXY_DOMAIN"
                    save_settings
                    log_success "Mask backend: ${MASKING_HOST}:${MASKING_PORT:-443}"
                fi
            fi
        fi
        if is_proxy_running; then
            load_secrets
            restart_proxy_container || true
        fi
    else
        log_error "Некорректный домен: ${new_domain}"
        return 1
    fi
}

handle_mask_backend() {
    local input="${1:-}"
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] && [ -n "$input" ]; then
        log_warn "Selfmask активен. Локальный mask backend управляется через selfmask"
        return 1
    fi
    if [ -z "$input" ]; then
        echo -e "  ${BOLD}Mask backend:${NC} ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}"
        return 0
    fi
    _require_manager_mode || return 1
    _require_no_superexpert || return 1
    check_root
    # Парсим host:port или только host
    local new_host new_port
    if [[ "$input" =~ ^(.+):([0-9]+)$ ]]; then
        new_host="${BASH_REMATCH[1]}"
        new_port="${BASH_REMATCH[2]}"
    else
        new_host="$input"
        new_port=""
    fi
    [ -n "$new_host" ] && MASKING_HOST="$new_host"
    if [ -n "$new_port" ]; then
        if validate_port "$new_port"; then
            MASKING_PORT="$new_port"
        else
            log_error "Некорректный порт: ${new_port}"
            return 1
        fi
    fi
    auto_set_fake_cert_len "${MASKING_HOST:-${PROXY_DOMAIN}}" 2>/dev/null || \
        log_warn "Не удалось определить TLS cert length для '${MASKING_HOST:-${PROXY_DOMAIN}}'"
    save_settings
    log_success "Mask backend: ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}"
    if is_proxy_running; then
        load_secrets
        restart_proxy_container || true
    fi
}

handle_sni_policy() {
    local new_policy="${1:-}"
    if [ -z "$new_policy" ]; then
        echo -e "  ${BOLD}SNI-политика:${NC} ${UNKNOWN_SNI_ACTION}"
        return 0
    fi
    check_root
    case "$new_policy" in
        mask|drop|accept|reject_handshake)
            UNKNOWN_SNI_ACTION="$new_policy"
            save_settings
            reload_proxy_config 2>/dev/null || true
            log_success "SNI-политика: ${UNKNOWN_SNI_ACTION}"
            ;;
        *)
            log_error "Допустимые значения: mask, drop, accept, reject_handshake"
            return 1
            ;;
    esac
}

validate_ip_literal() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    local -a octets=($ip)
    local o
    for o in "${octets[@]}"; do
        [ "$o" -ge 0 ] && [ "$o" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

show_cli_help() {
    echo ""
    echo -e "  ${BRIGHT_CYAN}${BOLD}MTProxyL${NC} ${DIM}v${VERSION}${NC} — Менеджер Telegram MTProto прокси"
    echo ""
    echo -e "  ${BOLD}Использование:${NC} mtproxyl <команда> [параметры]"
    echo ""
    echo -e "  ${BOLD}Прокси:${NC}         start | stop | restart | status [--json]"
    echo -e "  ${BOLD}Секреты:${NC}        secret add|remove|list|rotate|enable|disable|limits|link|qr|clone|rename"
    echo -e "  ${BOLD}Настройки:${NC}      port | ip | domain | mask-backend | config | settings list|set"
    echo -e "  ${BOLD}Движок:${NC}         engine status|list|update|rollback|rebuild"
    echo -e "  ${BOLD}Эксперт:${NC}        expert list|set|clear|edit"
    echo -e "  ${BOLD}Супер эксперт:${NC}  superexpert status|on|off|edit|show|write"
    echo -e "  ${BOLD}NFT:${NC}            nft apply|remove|service|drop|preset|smart|zapret2|zapret2-stop|zapret2-rm|zapret2-wscale"
    echo -e "  ${BOLD}Selfmask:${NC}       selfmask status|setup|apply|set|settable|verify|disable|menu"
    echo -e "  ${BOLD}Веб-панель:${NC}     panel status|install|restart|password|uninstall"
    echo -e "  ${BOLD}Телеграм-бот:${NC}   tgbot status|install|setup|start|stop|restart|logs|uninstall"
    echo -e "  ${BOLD}PQ проверка:${NC}    pq-check [домен[:порт]]"
    echo -e "  ${BOLD}Безопасность:${NC}   geoblock add|remove|list | upstream list|add|remove | sni-policy"
    echo -e "  ${BOLD}Мониторинг:${NC}     traffic | connections | metrics [live] | logs | health | info"
    echo -e "  ${BOLD}История IP:${NC}     ip-history status|flush|on|off"
    echo -e "  ${BOLD}Доступность:${NC}    availability status|check|details|target|on|off|token"
    echo -e "  ${BOLD}Telegram/WARP:${NC}  warp status|on socks|on iface|off|scan|location|endpoint|proto"
    echo -e "  ${BOLD}Бэкапы:${NC}         backup [--encrypt] | restore <файл>"
    echo -e "  ${BOLD}Переезд:${NC}        migrate <[user@]хост[:порт]> [--dry-run] ${DIM}(только менеджер)${NC}"
    echo -e "  ${BOLD}Подкачка:${NC}       swap status|on [МБ]|off"
    echo -e "  ${BOLD}Reanimator:${NC}     mode [manager|reanimator] | detect | edit-config\n                  install-telemt | uninstall-telemt"
    echo -e "  ${BOLD}Система:${NC}        install [аргументы] | menu | update [--no-restart] | update-check\n                  uninstall | version | help"
    echo -e "  ${DIM}Установка без вопросов: mtproxyl install --help${NC}"
    echo ""
}

# ── Проверка доступности порта ────────────────────────────────
is_port_available() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ! ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    elif command -v netstat &>/dev/null; then
        ! netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    else
        return 0
    fi
}

# Кто именно слушает порт — чтобы пользователь понимал, с чем конфликт
# (на сервере рядом может стоять свой telemt-бинарник, nginx, панель).
show_port_listener() {
    local _port="$1" _out=""
    if command -v ss &>/dev/null; then
        _out=$(ss -ltnp 2>/dev/null | awk -v p=":${_port}\$" '$4 ~ p {print}')
    elif command -v netstat &>/dev/null; then
        _out=$(netstat -ltnp 2>/dev/null | awk -v p=":${_port}\$" '$4 ~ p {print}')
    fi
    if [ -n "$_out" ]; then
        echo -e "  ${DIM}Порт занимает:${NC}"
        echo "$_out" | sed 's/^/    /'
    fi
    if command -v docker &>/dev/null; then
        local _dc
        _dc=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E "(^|[^0-9])${_port}->" || true)
        [ -n "$_dc" ] && { echo -e "  ${DIM}Docker-контейнеры на этом порту:${NC}"; echo "$_dc" | sed 's/^/    /'; }
    fi
}

find_free_metrics_port() {
    local start="${1:-9090}"
    local end="${2:-9199}"
    local p
    for ((p=start; p<=end; p++)); do
        if is_port_available "$p"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}
