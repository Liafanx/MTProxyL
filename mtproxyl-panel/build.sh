#!/usr/bin/env bash
set -euo pipefail

echo "=== MTProxyL-Panel Builder ==="
echo ""

# Check Docker
if ! docker version &>/dev/null; then
  echo "ERROR: Docker is not running."
  exit 1
fi

PLATFORMS="${1:-linux/amd64,linux/arm64}"

echo "[1/4] Building frontend..."
docker build --target frontend -t mtproxyl-panel-frontend .

echo "[2/4] Building binaries for: ${PLATFORMS}..."
mkdir -p release

for platform in ${PLATFORMS//,/ }; do
  os="${platform%/*}"
  arch="${platform#*/}"

  if [ "$arch" = "arm64" ]; then
    label="aarch64"
  else
    label="x86_64"
  fi

  outname="mtproxyl-panel-${label}-${os}"
  echo "  -> ${outname}"

  docker build \
    --build-arg TARGETARCH="${arch}" \
    --platform "${platform}" \
    -t "mtproxyl-panel-builder-${arch}" .

  container_id=$(docker create "mtproxyl-panel-builder-${arch}")
  docker cp "${container_id}:/usr/local/bin/mtproxyl-panel" "./release/${outname}"
  docker rm "${container_id}" >/dev/null 2>&1
done

echo "[3/4] Generating checksums..."
cd release
for bin in mtproxyl-panel-*; do
  sha256sum "$bin" > "${bin}.sha256"
done
cd ..

echo "[4/4] Done!"
echo ""
echo "Binaries in ./release/:"
ls -lh release/
