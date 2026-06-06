BINARY := httpsvc
CMD := ./cmd/httpsvc
LDFLAGS := -s -w -X github.com/txsvc/httpsvc/internal/server.Version=$(VERSION)
CONTAINERFILE := deploy/Containerfile
IMAGE ?= httpsvc
IMAGE_TAG ?= latest
PLATFORMS ?= linux/amd64,linux/arm64

.PHONY: all build test run clean tidy image push run-container

all: test

build:
	go build -ldflags "$(LDFLAGS)" -o bin/$(BINARY) $(CMD)

test:
	go test ./...

run:
	go run $(CMD) run --config deploy/Caddyfile --adapter caddyfile

tidy:
	go mod tidy

clean:
	rm -rf bin/

image:
	podman manifest rm $(IMAGE):$(IMAGE_TAG) 2>/dev/null || true
	podman build --platform $(PLATFORMS) \
		--build-arg VERSION=$(VERSION) \
		--manifest $(IMAGE):$(IMAGE_TAG) \
		-f $(CONTAINERFILE) .

push:
	podman manifest push $(IMAGE):$(IMAGE_TAG)

run-container:
	podman run --rm -p 8080:80 \
		-e HTTPSVC_LISTEN=http:// \
		$(IMAGE):$(IMAGE_TAG)
