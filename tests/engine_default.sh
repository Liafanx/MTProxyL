#!/bin/bash
set -euo pipefail
exec </dev/null

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"; VERSION=test; GITHUB_RAW=http://x
source "$repo/lib/colors.sh" || true
for _lib in utils settings binengine install install_args; do source "$repo/lib/$_lib.sh"; done
SETTINGS_FILE="$test_dir/settings.conf"
draw_header() { :; }
binengine_arch() { echo x86_64; }
systemctl() { :; }
_fix_read_choice() { echo "${3:-$2}"; }
_FIX_ANS_ENGINE_VERSION=y

# Fresh install: Enter picks the binary.
ENGINE_BACKEND=docker
installer_pick_engine_backend >/dev/null
[ "$ENGINE_BACKEND" = binary ]
# Docker is the second option.
_FIX_ANS_ENGINE=2; installer_pick_engine_backend >/dev/null
[ "$ENGINE_BACKEND" = docker ]
# Reinstall over Docker: Enter keeps Docker.
_FIX_ANS_ENGINE=""; : > "$SETTINGS_FILE"; ENGINE_BACKEND=docker
installer_pick_engine_backend >/dev/null
[ "$ENGINE_BACKEND" = docker ]
# No telemt build for this CPU: Docker without asking.
rm -f "$SETTINGS_FILE"
binengine_arch() { return 1; }
installer_pick_engine_backend >/dev/null
[ "$ENGINE_BACKEND" = docker ]

echo 'engine default: ok'
