#!/bin/bash
# shellcheck disable=SC2034
# Настройки ниже читают функции подключённых модулей.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/lib/utils.sh"
source "$repo/lib/availability.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
web_is_only_mode() { [ "$web_only" = true ]; }
web_public_port() { echo 8443; }
_availability_web_host() { [ -n "$web_host" ] && printf '%s' "$web_host"; }
_availability_config_public_host() { printf '%s' "$config_host"; }
_current_sni_domain() { printf '%s' "$PROXY_DOMAIN"; }
ip() { printf '%s\n' "$interface_addresses"; }
curl() { printf '%s' "$external_ip"; }
# Проверке не требуется DNS даже для чужого имени.
getent() { fail 'unexpected DNS lookup'; }

reset() {
    AVAILABILITY_HOST="" AVAILABILITY_PORT="" AVAILABILITY_SNI=""
    SELFMASK_ENABLED=true SELFMASK_CERT_MODE=selfsigned
    SELFMASK_DOMAIN=foreign.example.org PROXY_DOMAIN=foreign.example.org
    MTPROXYL_MODE=manager PROXY_PORT=443 DETECTED_PORT=""
    CUSTOM_IP=198.51.100.10 SERVER_IPS=""
    web_only=false web_host="" config_host=foreign.example.org
    interface_addresses="" external_ip=""
}
check() {
    local actual
    actual=$(availability_target)
    [ "$actual" = "$2" ] || fail "$1: $actual != $2"
}

reset
check 'foreign Selfmask domain' '198.51.100.10|443|foreign.example.org'
SELFMASK_DOMAIN=missing.example.org PROXY_DOMAIN=missing.example.org
check 'missing domain' '198.51.100.10|443|missing.example.org'
AVAILABILITY_SNI=other.example.org AVAILABILITY_PORT=9443
check 'custom SNI and port' '198.51.100.10|9443|other.example.org'
AVAILABILITY_HOST=probe.example.org
check 'manual host' 'probe.example.org|9443|other.example.org'

reset
CUSTOM_IP=foreign.example.org SERVER_IPS=203.0.113.20,203.0.113.21
check 'server address list instead of CUSTOM_IP domain' '203.0.113.20|443|foreign.example.org'
SERVER_IPS=all
interface_addresses=$'2: eth0 inet 198.51.100.30/24 scope global eth0\n3: warp inet 198.51.100.40/24 scope global warp'
check 'automatic server address list' '198.51.100.30|443|foreign.example.org'
SERVER_IPS=""
interface_addresses=$'2: docker0 inet 172.18.0.1/16 scope global docker0\n3: wg0 inet 203.0.113.50/24 scope global wg0\n4: eth0 inet 192.0.2.60/24 scope global eth0'
check 'public interface without tunnel addresses' '192.0.2.60|443|foreign.example.org'
interface_addresses="" external_ip=192.0.2.70
check 'external address behind NAT' '192.0.2.70|443|foreign.example.org'
external_ip='<html>error</html>'
check 'no known IP does not fall back to foreign host' '|443|foreign.example.org'

reset
SELFMASK_CERT_MODE=letsencrypt
check 'regular certificate' 'foreign.example.org|443|foreign.example.org'
SELFMASK_ENABLED=false
check 'without Selfmask' 'foreign.example.org|443|foreign.example.org'

reset
web_only=true web_host=web.example.org
check 'WEB-only keeps its own domain' 'web.example.org|8443|web.example.org'
web_host=foreign.example.org
check 'WEB-only using selfsigned Selfmask' '198.51.100.10|8443|foreign.example.org'

reset
MTPROXYL_MODE=reanimator DETECTED_PORT=7443
check 'reanimator keeps detected port' '198.51.100.10|7443|foreign.example.org'

echo 'availability target: ok'
