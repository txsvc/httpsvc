BINARY := httpsvc
CMD := ./cmd/httpsvc
LDFLAGS := -s -w -X github.com/txsvc/httpsvc/internal/server.Version=$(VERSION)
CONTAINERFILE := deploy/Containerfile
IMAGE ?= httpsvc
IMAGE_TAG ?= latest
GOOS ?= linux
GOARCH ?= amd64

.PHONY: all build build-linux test run clean tidy image run-container

all: test

build:
	go build -ldflags "$(LDFLAGS)" -o bin/$(BINARY) $(CMD)

build-linux:
	CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) \
		go build -ldflags "$(LDFLAGS)" -o bin/$(BINARY)-linux $(CMD)

test:
	go test ./...

run:
	go run $(CMD) run --config deploy/Caddyfile --adapter caddyfile

tidy:
	go mod tidy

clean:
	rm -rf bin/

image: build-linux
	podman build -f $(CONTAINERFILE) -t $(IMAGE):$(IMAGE_TAG) .

run-container:
	podman run --rm -p 8080:80 \
		-v httpsvc-data:/data \
		-e HTTPSVC_LISTEN=http:// \
		$(IMAGE):$(IMAGE_TAG)
