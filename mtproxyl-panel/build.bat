@echo off
echo === MTProxyL-Panel Builder ===
echo.

REM Check Docker
docker version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Docker is not running. Start Docker Desktop first.
    exit /b 1
)

echo [1/3] Building Docker image for amd64 + arm64...

mkdir release 2>nul

echo   Building amd64...
docker build --build-arg TARGETARCH=amd64 --platform linux/amd64 -t mtproxyl-panel-builder-amd64 .
if errorlevel 1 (
    echo ERROR: Docker build failed for amd64.
    exit /b 1
)
docker create --name tpb-amd64 mtproxyl-panel-builder-amd64 >nul 2>&1
docker cp tpb-amd64:/usr/local/bin/mtproxyl-panel ./release/mtproxyl-panel-x86_64-linux
docker rm tpb-amd64 >nul 2>&1

echo   Building arm64...
docker build --build-arg TARGETARCH=arm64 --platform linux/arm64 -t mtproxyl-panel-builder-arm64 .
if errorlevel 1 (
    echo ERROR: Docker build failed for arm64.
    exit /b 1
)
docker create --name tpb-arm64 mtproxyl-panel-builder-arm64 >nul 2>&1
docker cp tpb-arm64:/usr/local/bin/mtproxyl-panel ./release/mtproxyl-panel-aarch64-linux
docker rm tpb-arm64 >nul 2>&1

echo [2/3] Generating checksums...
certutil -hashfile release\mtproxyl-panel-x86_64-linux SHA256 | findstr /v ":" > release\mtproxyl-panel-x86_64-linux.sha256
certutil -hashfile release\mtproxyl-panel-aarch64-linux SHA256 | findstr /v ":" > release\mtproxyl-panel-aarch64-linux.sha256

echo [3/3] Done!
echo.
echo Binaries in .\release\:
dir /b release\
echo.
echo These are static binaries — they work on any Linux (Debian, Ubuntu, Alpine, etc.)
