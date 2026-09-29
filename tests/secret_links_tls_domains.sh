#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-tls-domains.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir"
CONFIG_DIR="$test_dir/config"
SETTINGS_FILE="$test_dir/settings.conf"
VERSION=test
mkdir -p "$CONFIG_DIR"

# shellcheck source=/dev/null
source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"

raw=0123456789abcdef0123456789abcdef
cfg="$test_dir/telemt.toml"
_engine_config_path() { echo "$cfg"; }
_superexpert_active() { return 1; }
MTPROXYL_MODE=manager MASKING_ENABLED=true PROXY_DOMAIN=primary.example
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

# Без tls_domains — одна ссылка и прежний формат строки.
printf '[censorship]\ntls_domain = "primary.example"\n' > "$cfg"
[ "$(build_link_secrets "$raw")" = "tls|ee${raw}$(hex primary.example)" ]

# Однострочный массив, дубль основного домена и регистр отбрасываются.
cat > "$cfg" << 'TOML'
[censorship]
tls_domain = "primary.example"
tls_domains = ["secondary.example", "PRIMARY.example", 'third.example'] # комментарий

[other]
tls_domains = ["wrong.example"]
TOML
out=$(build_link_secrets "$raw")
[ "$(printf '%s\n' "$out" | wc -l)" -eq 3 ]
printf '%s\n' "$out" | grep -qx "tls|ee${raw}$(hex primary.example)|primary.example"
printf '%s\n' "$out" | grep -qx "tls|ee${raw}$(hex secondary.example)|secondary.example"
printf '%s\n' "$out" | grep -qx "tls|ee${raw}$(hex third.example)|third.example"
if printf '%s\n' "$out" | grep -q wrong.example; then echo 'Взят чужой раздел' >&2; exit 1; fi

# Многострочный массив.
cat > "$cfg" << 'TOML'
[censorship]
tls_domain = "primary.example"
tls_domains = [
  "secondary.example",
  # старый домен
  "old.example",
]
TOML
[ "$(build_link_secrets "$raw" | wc -l)" -eq 3 ]
[ "$(link_kind_title tls old.example)" = 'ee · TLS · old.example' ]
[ "$(link_kind_title tls)" = 'ee · TLS' ]

echo 'secret links with tls_domains: OK'
