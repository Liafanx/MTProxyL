#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-docker-version.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir/state"
CONTAINER_NAME=mtproxyl
DOCKER_IMAGE_BASE=mtproxyl-telemt
REGISTRY_IMAGE=ghcr.io/liafanx/mtproxyl-telemt
TELEMT_MIN_VERSION=3.5.7
TELEMT_COMMIT=4ca7418
mkdir -p "$INSTALL_DIR"

source "$repo/lib/docker.sh"
engine_is_binary() { return 1; }
docker() {
    case "$1 ${2:-}" in
        'inspect -f') printf '%s\n' 'mtproxyl-telemt:3.4.25' ;;
        'image inspect') return 0 ;;
        *) return 1 ;;
    esac
}

remember_proxy_container_version
[ "$(cat "$INSTALL_DIR/.telemt_version")" = 3.4.25 ]
[ "$(stat -c '%a' "$INSTALL_DIR/.telemt_version")" = 600 ]

# Явно выбранную версию (update/rollback) текущий контейнер не перезаписывает.
printf '%s\n' 3.5.6 > "$INSTALL_DIR/.telemt_version"
remember_proxy_container_version
[ "$(cat "$INSTALL_DIR/.telemt_version")" = 3.5.6 ]

# Переприменение WEB зовёт build_telemt_image: выбранный образ на диске —
# версия остаётся, закреплённая не подтягивается.
log_info() { :; }; log_success() { :; }; log_warn() { :; }
pulled=""
docker() {
    case "$1 ${2:-}" in
        'image inspect') [ "$3" = mtproxyl-telemt:3.5.13-d3de986 ] || [ "$3" = mtproxyl-telemt:3.5.7-4ca7418 ] ;;
        'pull '*) pulled+="$2 "; return 1 ;;
        *) return 0 ;;
    esac
}
printf '%s\n' 3.5.13-d3de986 > "$INSTALL_DIR/.telemt_version"
build_telemt_image
[ "$(cat "$INSTALL_DIR/.telemt_version")" = 3.5.13-d3de986 ]
[ -z "$pulled" ]

# Выбранного образа нет — берём закреплённый.
printf '%s\n' 3.5.9-gone > "$INSTALL_DIR/.telemt_version"
build_telemt_image
[ "$(cat "$INSTALL_DIR/.telemt_version")" = 3.5.7-4ca7418 ]

echo 'docker restart version: OK'
