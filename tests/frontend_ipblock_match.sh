#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/mtproxyl-ipblock-match.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT

[ -x "$repo/mtproxyl-panel/frontend/node_modules/.bin/tsc" ] || {
    echo 'Сначала выполните npm ci в mtproxyl-panel/frontend' >&2
    exit 1
}

"$repo/mtproxyl-panel/frontend/node_modules/.bin/tsc" \
    --target ES2020 --module commonjs --skipLibCheck --outDir "$tmp" \
    "$repo/mtproxyl-panel/frontend/src/lib/ipblock-match.ts"

node - "$tmp/ipblock-match.js" <<'JS'
const assert = require('node:assert/strict');
const { findBlockingEntry } = require(process.argv[2]);

assert.equal(findBlockingEntry('93.123.84.196', ['93.123.84.196']), '93.123.84.196');
assert.equal(findBlockingEntry('93.123.84.196', ['93.123.84.0/24']), '93.123.84.0/24');
assert.equal(findBlockingEntry('93.123.85.196', ['93.123.84.0/24']), null);
assert.equal(findBlockingEntry('192.0.2.1', ['0.0.0.0/0']), '0.0.0.0/0');
assert.equal(findBlockingEntry('2001:db8::2', ['2001:db8::/32']), '2001:db8::/32');
assert.equal(findBlockingEntry('2001:db9::2', ['2001:db8::/32']), null);
assert.equal(findBlockingEntry('::ffff:192.0.2.1', ['::ffff:192.0.2.0/120']), '::ffff:192.0.2.0/120');
assert.equal(findBlockingEntry('192.0.2.1', ['::ffff:192.0.2.0/120']), null);
assert.equal(findBlockingEntry('192.0.2.1', ['not-an-address', '192.0.2.0/33']), null);
// Подсети из вкладки «По подсети»: закрыта своим или более широким правилом.
assert.equal(findBlockingEntry('198.51.100.0/24', ['198.51.100.0/24']), '198.51.100.0/24');
assert.equal(findBlockingEntry('10.20.30.0/24', ['10.0.0.0/8']), '10.0.0.0/8');
assert.equal(findBlockingEntry('203.0.113.0/24', ['203.0.113.5']), null);
assert.equal(findBlockingEntry('2001:db8:0:1200::/56', ['2001:db8::/48']), '2001:db8::/48');
assert.equal(findBlockingEntry('2001:db8::/32', ['2001:db8::/48']), null);
console.log('frontend IP block matching: OK');
JS
