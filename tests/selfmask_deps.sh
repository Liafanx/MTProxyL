#!/bin/bash
# Зависимости Selfmask ставятся менеджером пакетов дистрибутива (issue #73).
set -uo pipefail
cd "$(dirname "$0")/.."

fn=$(sed -n '/^_selfmask_install_deps()/,/^}/p' lib/selfmask.sh)
[ -n "$fn" ] || { echo "FAIL: нет _selfmask_install_deps" >&2; exit 1; }
eval "$fn"

log_info() { :; }
log_success() { :; }
log_error() { echo "$*" >&2; }
_wait_apt() { :; }
SELFMASK_CERT_MODE=selfsigned
calls=""
apt-get() { calls+="apt-get $*; "; return 0; }
dnf() { calls+="dnf $*; "; return 0; }
yum() { calls+="yum $*; "; return 0; }
apk() { calls+="apk $*; "; return 0; }

# RHEL/AlmaLinux: rpm, имена pcre2/zlib, установка через dnf.
detect_os() { echo rhel; }
rpm() { [ "${2:-}" = ca-certificates ] && return 0; return 1; }
calls=""
_selfmask_install_deps >/dev/null || { echo "FAIL: rhel вернул ошибку" >&2; exit 1; }
[ "$calls" = "dnf install -y pcre2 zlib; " ] || { echo "FAIL rhel: $calls" >&2; exit 1; }

# Debian/Ubuntu: dpkg и apt-get, только недостающий пакет.
detect_os() { echo debian; }
dpkg() { [ "${2:-}" = zlib1g ] && return 1; return 0; }
calls=""
_selfmask_install_deps >/dev/null || { echo "FAIL: debian вернул ошибку" >&2; exit 1; }
[ "$calls" = "apt-get update -qq; apt-get install -y -qq zlib1g; " ] || { echo "FAIL debian: $calls" >&2; exit 1; }

# Alpine: apk.
detect_os() { echo alpine; }
apk() {
    case "$1 $2" in "info -e") [ "${3:-}" = zlib ] && return 1; return 0 ;; esac
    calls+="apk $*; "; return 0
}
calls=""
_selfmask_install_deps >/dev/null || { echo "FAIL: alpine вернул ошибку" >&2; exit 1; }
[ "$calls" = "apk add --no-cache zlib; " ] || { echo "FAIL alpine: $calls" >&2; exit 1; }

echo "OK selfmask_deps"
