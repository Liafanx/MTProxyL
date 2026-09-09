#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-engine-test.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
DOCKER_IMAGE_BASE=mtproxyl-telemt
REGISTRY_IMAGE=ghcr.io/liafanx/mtproxyl-telemt
TELEMT_MIN_VERSION=3.5.7
TELEMT_COMMIT=4ca7418
source "$repo/lib/utils.sh"
source "$repo/lib/docker.sh"
source "$repo/lib/engine.sh"
log_info() { :; }
log_success() { :; }
log_warn() { :; }
log_error() { echo "$*" >> "$test_dir/errors"; }
check_root() { :; }
read_line() { printf -v "$1" n; }
fail() { echo "FAIL: $*" >&2; exit 1; }
fixture() {
    printf '3.5.7-current\n' > "$INSTALL_DIR/.telemt_version"
    cat > "$test_dir/images" <<EOF
$DOCKER_IMAGE_BASE|3.5.7-current|sha256:current|20MB
$DOCKER_IMAGE_BASE|latest|sha256:current|20MB
$REGISTRY_IMAGE|latest|sha256:current|20MB
$DOCKER_IMAGE_BASE|3.5.6-previous|sha256:previous|19MB
$REGISTRY_IMAGE|3.5.6-previous|sha256:previous|19MB
$DOCKER_IMAGE_BASE|3.5.5-used|sha256:used|18MB
$DOCKER_IMAGE_BASE|3.5.4-unused|sha256:unused|17MB
$REGISTRY_IMAGE|3.5.4-unused|sha256:unused|17MB
$DOCKER_IMAGE_BASE|3.5.3-foreign|sha256:foreign|16MB
unrelated/project|stable|sha256:foreign|16MB
EOF
    : > "$test_dir/removed"
}
docker() {
    case "$1 ${2:-}" in
        'image ls') [ "${FAIL_INVENTORY:-0}" = 0 ] || return 1; cat "$test_dir/images" ;;
        'ps -aq') echo stopped-container ;;
        'inspect --format') echo sha256:used ;;
        'image inspect')
            [ "${RACE_TAG:-0}" = 0 ] || { echo sha256:changed; return; }
            awk -F'|' -v ref="${!#}" '$1 ":" $2 == ref {print $3}' "$test_dir/images" ;;
        'image rm')
            [ "$3" = -- ] || fail 'force deletion or missing delimiter'
            printf '%s\n' "$4" >> "$test_dir/removed"
            awk -F'|' -v ref="$4" '$1 ":" $2 != ref' "$test_dir/images" > "$test_dir/images.next"
            mv "$test_dir/images.next" "$test_dir/images" ;;
        'build --build-arg') cp "${!#}/Dockerfile" "$test_dir/Dockerfile"; return 1 ;;
        *) fail "unexpected Docker command: $*" ;;
    esac
}
fixture
engine_cleanup_images --json | jq -e '(.candidates|length)==2 and all(.candidates[]; .id=="sha256:unused")' >/dev/null || fail 'unsafe cleanup preview'
engine_cleanup_images --dry-run >/dev/null
engine_cleanup_images >/dev/null
[ ! -s "$test_dir/removed" ] || fail 'preview/decline deleted images'
engine_cleanup_images --yes >/dev/null
[ "$(wc -l < "$test_dir/removed")" = 2 ] || fail 'expected both unused aliases removed'
grep -q 'sha256:current' "$test_dir/images" || fail 'current removed'
grep -q 'sha256:previous' "$test_dir/images" || fail 'rollback removed'
grep -q 'sha256:used' "$test_dir/images" || fail 'stopped container image removed'
grep -q 'sha256:foreign' "$test_dir/images" || fail 'foreign tag image removed'
fixture
RACE_TAG=1
engine_cleanup_images --yes >/dev/null
[ ! -s "$test_dir/removed" ] || fail 'retagged image removed'
RACE_TAG=0
FAIL_INVENTORY=1
if engine_cleanup_images --yes >/dev/null; then fail 'inventory error ignored'; fi
[ ! -s "$test_dir/removed" ] || fail 'deleted after inventory failure'
FAIL_INVENTORY=0

if build_telemt_image source; then fail 'source build failure ignored'; fi
grep -q 'CARGO_BUILD_JOBS=1' "$test_dir/Dockerfile"
grep -q 'CARGO_PROFILE_RELEASE_LTO=off' "$test_dir/Dockerfile"
grep -q 'CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16' "$test_dir/Dockerfile"
build_line=$(sed -n 's/^RUN \(cargo build.*\)/\1/p' "$test_dir/Dockerfile")
(
    cargo() { return 42; }
    strip() { touch "$test_dir/strip-ran"; }
    cp() { touch "$test_dir/cp-ran"; }
    if eval "$build_line"; then fail 'RUN masked Cargo failure'; fi
)
[ ! -e "$test_dir/strip-ran" ] && [ ! -e "$test_dir/cp-ran" ] || fail 'post-build commands ran after failure'
! grep -q 'нужно минимум 2' "$test_dir/errors" || fail 'false RAM minimum'
eval "$(declare -f docker | sed '1s/docker/mock_docker/')"
_build_telemt_image_from_release() { return 1; }
docker() {
    case "$1 ${2:-}" in
        'image inspect') return 1 ;;
        'pull ghcr.io/liafanx/mtproxyl-telemt:latest') return 0 ;;
        pull*) return 1 ;;
        'run --rm') echo 'telemt 3.5.6' ;;
        tag*) fail 'stale latest was tagged as requested version' ;;
        *) mock_docker "$@" ;;
    esac
}
if build_telemt_image false; then fail 'stale latest accepted'; fi
echo 'PASS: cleanup preview/confirmation/protection/race/failure and low-memory build failure propagation'
