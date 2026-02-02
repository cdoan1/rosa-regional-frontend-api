.PHONY: help build test test-coverage lint clean image image-push run deps generate verify all

BINARY_NAME := rosa-regional-frontend-api
IMAGE_REPO ?= quay.io/openshift/rosa-regional-frontend-api
IMAGE_TAG ?= latest
GIT_SHA := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GOOS ?= linux
GOARCH ?= amd64
PLATFORM ?= linux/amd64

.DEFAULT_GOAL := help

help: ## Display this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build the binary
	GOOS=$(GOOS) GOARCH=$(GOARCH) go build -o $(BINARY_NAME) ./cmd/$(BINARY_NAME)

test: ## Run tests
	go test -v -race ./...

test-coverage: ## Run tests with coverage
	go test -v -race -coverprofile=coverage.out ./...
	go tool cover -html=coverage.out -o coverage.html

lint: ## Run linter
	golangci-lint run ./...

clean: ## Clean build artifacts
	rm -f $(BINARY_NAME)
	rm -f coverage.out coverage.html

image: ## Build Docker image
	docker build --platform $(PLATFORM) -t $(IMAGE_REPO):$(IMAGE_TAG) .
	docker tag $(IMAGE_REPO):$(IMAGE_TAG) $(IMAGE_REPO):$(GIT_SHA)

image-push: image ## Push Docker image
	docker push $(IMAGE_REPO):$(IMAGE_TAG)
	docker push $(IMAGE_REPO):$(GIT_SHA)

run: build ## Run locally
	./$(BINARY_NAME) serve \
		--log-level=debug \
		--log-format=text \
		--maestro-url=http://localhost:8001 \
		--allowed-accounts=123456789012

deps: ## Download dependencies
	go mod download
	go mod tidy

generate: ## Generate OpenAPI code (requires oapi-codegen)
	@echo "OpenAPI code generation not yet configured"
	@echo "Install oapi-codegen: go install github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@latest"

verify: ## Verify go.mod is tidy
	go mod tidy
	git diff --exit-code go.mod go.sum

all: deps lint test build ## Run all checks
