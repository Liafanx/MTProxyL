#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-telemt3516.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
CONFIG_DIR="$test_dir"
VERSION=dev
for lib in utils settings front web expert_catalog expert_mode config selfmask install_args; do source "$repo/lib/$lib.sh"; done
log_info() { :; }; log_warn() { echo "$*" >&2; }; log_error() { echo "$*" >&2; }; log_success() { :; }
_mktemp() { mktemp "$1/.test.XXXXXX"; }
fails() { if "$@" >"$test_dir/error" 2>&1; then echo "Unexpected success: $*" >&2; exit 1; fi; }

ENGINE=3.5.16
web_engine_version() { echo "$ENGINE"; }
web_public_addr() { echo '203.0.113.10:443'; }
PROXY_MODE=combined
WEB_ENABLED=true WEB_DOMAIN=web.example.org WEB_HOSTS='alt.example.org,other.example.org'
PROXY_DOMAIN=mask.example.org
SECRETS_LABELS=(alice)
SECRETS_KEYS=(000102030405060708090a0b0c0d0e0f)
SECRETS_ENABLED=(true)
SECRETS_QUOTA=(1073741824)
SECRETS_MAX_CONNS=(0) SECRETS_MAX_IPS=(0) SECRETS_EXPIRES=(0) SECRETS_ADTAG=('') SECRETS_RATE=('')
_validate_web_hosts 'Alt.Example.org,other.example.org'
for bad in 'web.example.org' 'alt.example.org,ALT.example.org' 'a.example.org,' ',a.example.org' 'a.example.org,,b.example.org' '192.0.2.1' 'a.example.org:443' 'a.example.org/path' 'a..org' '.a.org' '-a.org' 'a.org;id' 'a.org"' 'a.org|x' $'a.org\nb.org'; do
    fails _validate_web_hosts "$bad"
done
_validate_web_hosts '*.example.org,*'
[ "$(web_profile_count)" = 3 ]
[ -z "$(web_hosts_problems)" ]
web_sections_toml > "$test_dir/web.toml"
python3 - "$test_dir/web.toml" <<'PY'
import sys,tomllib
c=tomllib.load(open(sys.argv[1],'rb'))
v=c['web']['vhosts']
assert len(v)==1 and 'host' not in v[0]
assert v[0]['hosts']==['web.example.org','alt.example.org','other.example.org']
assert len(v[0]['profiles'])==1
PY
DETECTED_CONFIG_PATH="$test_dir/web.toml"
[ "$(web_target_hosts | paste -sd, -)" = web.example.org,alt.example.org,other.example.org ]
[ "$(web_target_host)" = web.example.org ]
stream=$(web_nginx_stream_block)
for host in web.example.org alt.example.org other.example.org; do grep -Fq "$host mtproxyl_web;" <<< "$stream"; done
WEB_FRONTEND=haproxy
cfg=$(web_haproxy_config)
grep -Fq '^alt[.]example[.]org$' <<< "$cfg"
! grep -q 'set-header Host' <<< "$cfg"
WEB_FRONTEND=nginx
ENGINE=3.5.14
fails web_sections_toml
ENGINE=3.5.16

save_expert_override web.retry_jitter enabled true
save_expert_override web.retry_jitter min_ms 50
save_expert_override web.retry_jitter max_ms 300
save_expert_override web.retry_jitter distribution triangular
save_expert_override web.retry_jitter peak_ms 125
[ -z "$(web_new_settings_problems)" ]
save_expert_override web.retry_jitter peak_ms 301
grep -q 'peak_ms' <<< "$(web_new_settings_problems)"
save_expert_override web.retry_jitter peak_ms 125
save_expert_override access user_quota_periods '{"alice":"monthly","removed":"weekly"}'
_expert_quota_period_move alice renamed
jq -e '.renamed == "monthly" and (has("alice") | not)' <<< "$(get_expert_override_value access user_quota_periods)" >/dev/null
_expert_quota_period_move renamed alice
fails _validate_quota_periods '{"alice":"yearly"}'
fails _validate_quota_periods '{"alice":"monthly\n[server]"}'
fails _validate_quota_periods 'null'
_apply_expert_overrides "$test_dir/web.toml" 2>"$test_dir/warnings"
grep -q 'removed' "$test_dir/warnings"
python3 - "$test_dir/web.toml" <<'PY'
import sys,tomllib
c=tomllib.load(open(sys.argv[1],'rb'))
assert c['web']['retry_jitter']==dict(enabled=True,min_ms=50,max_ms=300,distribution='triangular',peak_ms=125)
assert c['access']['user_quota_periods']=={'alice':'monthly'}
PY
ENGINE=3.5.15
printf '[general]\n' > "$test_dir/old.toml"
_apply_expert_overrides "$test_dir/old.toml" 2>"$test_dir/warnings"
! grep -q 'retry_jitter' "$test_dir/old.toml"
grep -q '3.5.16' "$test_dir/warnings"
ENGINE=3.5.16

WEB_HOSTS='*.example.org'
grep -q 'allow_wildcard_hosts' <<< "$(web_hosts_problems)"
save_expert_override web.limits memory_envelope_bytes 1610612736
save_expert_override web allow_wildcard_hosts true
grep -q 'внешний HAProxy' <<< "$(web_hosts_problems)"
WEB_FRONTEND=haproxy
PROXY_DOMAIN=mask.other.org
[ -z "$(web_hosts_problems)" ]
[ -z "$(web_limits_check)" ]
if command -v haproxy >/dev/null && command -v openssl >/dev/null; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=web.example.org \
        -keyout "$test_dir/key.pem" -out "$test_dir/cert.pem" >"$test_dir/openssl.log" 2>&1
    cat "$test_dir/cert.pem" "$test_dir/key.pem" > "$test_dir/frontend.pem"
    WEB_HAPROXY_CERT="$test_dir/frontend.pem"
    web_haproxy_config > "$test_dir/haproxy.cfg"
    haproxy -c -f "$test_dir/haproxy.cfg" >"$test_dir/haproxy.log" 2>&1 || { cat "$test_dir/haproxy.log"; exit 1; }
fi
save_expert_override web.limits memory_envelope_bytes 1342177280
grep -q 'резервы WEB' <<< "$(web_limits_check)"
save_expert_override web.limits memory_envelope_bytes 1610612736
WEB_HOSTS=alt.example.org
delete_expert_override web allow_wildcard_hosts

WEB_DECOY_MODE=http_upstream WEB_DECOY_UPSTREAM=http://localhost:18081 WEB_DECOY_RESOLVE=startup
_validate_web_upstream "$WEB_DECOY_UPSTREAM"
fails _validate_web_upstream http://8.8.8.8
fails _validate_web_upstream http://127.0.0.1:0
fails _validate_web_upstream http://origin.example.org/path
web_sections_toml > "$test_dir/dns.toml"
grep -q '^resolve = "startup"$' "$test_dir/dns.toml"

# Сертификат выпускается на все точные имена, в том числе при отдельном WEB cert.
_selfmask_cert_is_valid() { printf '%s\n' "$@" > "$test_dir/cert-check"; return 1; }
web_own_cert_dir() { echo "$test_dir/cert"; }
certbot() { printf '%s\n' "$@" > "$test_dir/certbot"; }
SELFMASK_DOMAIN=mask.example.org
_selfmask_obtain_web_cert
grep -qx alt.example.org "$test_dir/cert-check"
grep -qx alt.example.org "$test_dir/certbot"

_install_args_parse --web yes --web-domain web.example.org --web-hosts alt.example.org --web-decoy-resolve startup
_install_args_validate
[ "$_IA_WEB_HOSTS" = alt.example.org ]
_IA_WEB_HOSTS='a.org;id'
fails _install_args_validate

# Проверяем исходный формат конфигурации официальным бинарником, без запуска прокси.
if [ -n "${TELEMT_3516_BIN:-}" ]; then
    WEB_DECOY_MODE=empty WEB_DECOY_RESOLVE=never
    mkdir -p "$test_dir/web-empty"
    printf '' > "$test_dir/web-empty/index.html"
    printf '[server.api]\nenabled = false\n[access.users]\nalice = "000102030405060708090a0b0c0d0e0f"\n[access.user_data_quota]\nalice = 1073741824\n' > "$test_dir/engine.toml"
    web_listeners_toml >> "$test_dir/engine.toml"
    web_sections_toml >> "$test_dir/engine.toml"
    _apply_expert_overrides "$test_dir/engine.toml" 2>/dev/null
    "$TELEMT_3516_BIN" healthcheck "$test_dir/engine.toml"
    if [ -n "${TELEMT_3515_BIN:-}" ]; then
        ENGINE=3.5.15
        cp "$test_dir/engine.toml" "$test_dir/v15.toml"
        python3 - "$test_dir/v15.toml" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
p.write_text(re.sub(r'\n\[web.retry_jitter\][^[]*', '\n', p.read_text()))
PY
        "$TELEMT_3515_BIN" healthcheck "$test_dir/v15.toml"
    fi
fi
echo 'telemt 3.5.15/3.5.16: ok'
