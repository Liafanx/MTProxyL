VERSION ?= 0.1.0
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: all frontend backend clean dev-frontend dev-backend hash-password release release-binaries

all: frontend backend

frontend:
	cd frontend && npm ci && npm run build

backend: frontend
	CGO_ENABLED=0 go build -ldflags="$(LDFLAGS)" -o mtproxyl-panel .

# Build static binaries for both architectures
release: frontend release-binaries

# То же без пересборки фронтенда: в CI он уже собран отдельным шагом (там же
# проверяются типы), и повторный npm ci + vite build стоил бы лишнюю минуту
# на каждый прогон.
release-binaries:
	@mkdir -p release
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="$(LDFLAGS)" -o release/mtproxyl-panel-x86_64-linux .
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="$(LDFLAGS)" -o release/mtproxyl-panel-aarch64-linux .
	cd release && for bin in mtproxyl-panel-*; do sha256sum "$$bin" > "$${bin}.sha256"; done
	@echo "Binaries in ./release/"

clean:
	rm -rf dist/ mtproxyl-panel release/ frontend/node_modules

dev-frontend:
	cd frontend && npm run dev

dev-backend:
	go run . --config config.toml

hash-password:
	@go run . hash-password
