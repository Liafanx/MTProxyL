#!/bin/bash
# Несколько публичных IP: SERVER_IPS, правила NFT и Zapret2 по списку,
# public_addr и сверка A-записи WEB по любому выбранному адресу.
set -u
cd "$(dirname "$0")/.." || exit 1
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
INSTALL_DIR="$d"
source lib/colors.sh 2>/dev/null; source lib/utils.sh 2>/dev/null; source lib/nft.sh 2>/dev/null
source lib/web.sh 2>/dev/null
log_success() { :; }; log_warn() { :; }; log_info() { :; }
fail=0
ok() { if eval "$2"; then echo "OK $1"; else echo "FAIL $1"; fail=1; fi; }

ok "пусто и all" '_validate_server_ips "" >/dev/null && _validate_server_ips all >/dev/null'
ok "список" '_validate_server_ips 203.0.113.10,203.0.113.11 >/dev/null'
ok "повтор, пробел, мусор — нет" '! _validate_server_ips 1.2.3.4,1.2.3.4 >/dev/null && ! _validate_server_ips "1.2.3.4, 1.2.3.5" >/dev/null && ! _validate_server_ips 1.2.3.4, >/dev/null && ! _validate_server_ips a.b >/dev/null'

ip() { cat <<'IP'
2: eth0    inet 203.0.113.10/24 brd 203.0.113.255 scope global eth0
2: eth0    inet 203.0.113.11/24 brd 203.0.113.255 scope global secondary eth0
3: docker0    inet 172.17.0.1/16 scope global docker0
4: wg0    inet 198.51.100.7/24 scope global wg0
5: eth1    inet 10.0.0.5/24 scope global eth1
IP
}
ok "на интерфейсах — только публичные, мимо туннелей" '[ "$(server_detect_public_ips | paste -sd, -)" = 203.0.113.10,203.0.113.11 ]'
SERVER_IPS=all
ok "all — найденные" '[ "$(server_ips | paste -sd, -)" = 203.0.113.10,203.0.113.11 ]'
SERVER_IPS=203.0.113.11
ok "список — как задан" '[ "$(server_ips)" = 203.0.113.11 ]'

SERVER_IPS=203.0.113.10,203.0.113.11
ok "nft: server → набор" '[ "$(nft_addr_spec server)" = "{ 203.0.113.10, 203.0.113.11 }" ]'
ok "nft: старая запись { a, b }" '[ "$(nft_addr_spec "{ 1.1.1.1, 2.2.2.2 }")" = "{ 1.1.1.1, 2.2.2.2 }" ]'
ok "nft: один адрес без скобок" '[ "$(nft_addr_spec 1.1.1.1)" = 1.1.1.1 ]'
ok "nft: пусто — без привязки" '! nft_addr_spec ""'
ok "валидатор NFT" '_validate_nft_addr_list server >/dev/null && _validate_nft_addr_list "{ 1.1.1.1, 2.2.2.2 }" >/dev/null && ! _validate_nft_addr_list all >/dev/null'

NFT_SCRIPT_FILE="$d/nft.sh"; NFT_MODE=smart; NFT_SERVER_IP=server; NFT_EXTRA_COUNT=0
generate_nft_script
ok "лимитер: правила на оба адреса" 'grep -q "ip daddr { 203.0.113.10, 203.0.113.11 } tcp dport" "$NFT_SCRIPT_FILE"'
ok "лимитер: счётчик по адресу клиента общий" '! grep "meter" "$NFT_SCRIPT_FILE" | grep -q "ip daddr . ip saddr"'
# Скрипт правил настоящим nft в отдельном сетевом пространстве.
if command -v nft >/dev/null && command -v unshare >/dev/null && [ "$(id -u)" = 0 ]; then
    nft_live() { unshare -n sh -c 'sh "$1" >/dev/null 2>&1 && nft list ruleset' _ "$NFT_SCRIPT_FILE"; }
    ok "лимитер: nft принимает набор адресов" 'nft_live | grep -q "ip daddr { 203.0.113.10, 203.0.113.11 } tcp dport 443"'
fi
    # Кривое правило: проверка в пустом пространстве не даёт снять рабочие.
    nft_apply_bad() {
        unshare -n bash -c '
            cd "$1"; INSTALL_DIR="$2"
            source lib/colors.sh; source lib/utils.sh; source lib/nft.sh
            _mktemp() { mktemp "$(dirname "$NFT_SCRIPT_FILE")/.tmp.XXXXXX"; }
            ensure_nftables_installed() { :; }; zapret2_in_effect() { return 1; }; web_is_only_mode() { return 1; }
            NFT_SCRIPT_FILE="$2/live.sh"; NFT_MODE=smart; NFT_EXTRA_COUNT=0
            NFT_SERVER_IP=203.0.113.10; apply_nft_rules >/dev/null 2>&1 || exit 2
            cp "$NFT_SCRIPT_FILE" "$2/good.sh"
            NFT_SERVER_IP=999.1.1.1; apply_nft_rules >/dev/null 2>&1 && exit 3
            cmp -s "$NFT_SCRIPT_FILE" "$2/good.sh" || exit 4
            nft list ruleset | grep -q "ip daddr 203.0.113.10 tcp dport 443" || exit 5
        ' _ "$PWD" "$d"
    }
    ok "лимитер: правило с ошибкой не снимает рабочие" 'nft_apply_bad'
SERVER_IPS=""
generate_nft_script
ok "лимитер: SERVER_IPS пуст — без привязки" '! grep -q "ip daddr" "$NFT_SCRIPT_FILE"'

SERVER_IPS=10.0.0.5,10.0.0.6
ZAPRET2_FILTER_IP_ENABLED=true; ZAPRET2_FILTER_IP=server
ok "zapret2: server → набор" '[ "$(zapret2_ip_match daddr)" = "ip daddr { 10.0.0.5, 10.0.0.6 } " ]'
ZAPRET2_FILTER_IP=10.0.0.5
ok "zapret2: один адрес как раньше" '[ "$(zapret2_ip_match saddr)" = "ip saddr 10.0.0.5 " ]'

# WEB: домен ведёт на второй выбранный адрес — он и есть public_addr,
# и предполёт не требует перевести A-запись на основной.
web_server_ip() { echo 203.0.113.10; }
web_domain_ips() { printf '198.51.100.1\n203.0.113.11\n'; }
web_domain() { echo web.example.com; }
SERVER_IPS=203.0.113.10,203.0.113.11
ok "public_addr — выбранный адрес из A-записи" '[ "$(web_public_ip)" = 203.0.113.11 ]'
SERVER_IPS=""
ok "без списка — как раньше, первый из A-записи" '[ "$(web_public_ip)" = 198.51.100.1 ]'

[ "$fail" = 0 ] && echo "server ips: ok"
exit "$fail"
