.PHONY: build test lint clean image image-push image-release run generate help deploy

BINARY_NAME := rosa-regional-frontend-api
IMAGE_REPO ?= quay.io/openshift/rosa-regional-frontend-api
IMAGE_TAG ?= latest
GIT_SHA := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Build the binary
build:
	go build -o $(BINARY_NAME) ./cmd/$(BINARY_NAME)

# Run tests
test:
	go test -v -race ./...

# Run tests with coverage
test-coverage:
	go test -v -race -coverprofile=coverage.out ./...
	go tool cover -html=coverage.out -o coverage.html

# Run linter
lint:
	golangci-lint run ./...

# Clean build artifacts
clean:
	rm -f $(BINARY_NAME)
	rm -f coverage.out coverage.html

# Build Docker image
image:
	docker build -t $(IMAGE_REPO):$(IMAGE_TAG) .
	docker tag $(IMAGE_REPO):$(IMAGE_TAG) $(IMAGE_REPO):$(GIT_SHA)

# Push Docker image
image-push: image
	docker push $(IMAGE_REPO):$(IMAGE_TAG)
	docker push $(IMAGE_REPO):$(GIT_SHA)

# Build and push multiarch image (linux/amd64, linux/arm64)
image-release:
	podman manifest create $(IMAGE_REPO):$(GIT_SHA)
	podman build --platform linux/amd64,linux/arm64 \
		--manifest $(IMAGE_REPO):$(GIT_SHA) .
	podman manifest push $(IMAGE_REPO):$(GIT_SHA) $(IMAGE_REPO):$(GIT_SHA)

# Run locally
run: build
	./$(BINARY_NAME) serve \
		--log-level=debug \
		--log-format=text \
		--maestro-url=http://localhost:8001 \
		--dynamodb-endpoint=http://localhost:8002

# Download dependencies
deps:
	go mod download
	go mod tidy

# Generate OpenAPI code (requires oapi-codegen)
generate:
	@echo "OpenAPI code generation not yet configured"
	@echo "Install oapi-codegen: go install github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@latest"

# Verify go.mod is tidy
verify:
	go mod tidy
	git diff --exit-code go.mod go.sum

# Deploy to Kubernetes/EKS cluster
deploy:
	kubectl apply -k deploy/kubernetes/

# All checks
all: deps lint test build

# Display available targets and their descriptions
help:
	@echo "Available targets:"
	@echo ""
	@echo "  build          Build the binary"
	@echo "  test           Run tests"
	@echo "  test-coverage  Run tests with coverage"
	@echo "  lint           Run linter"
	@echo "  clean          Clean build artifacts"
	@echo "  image          Build Docker image"
	@echo "  image-push     Push Docker image"
	@echo "  image-release  Build and push multiarch image (amd64 and arm64)"
	@echo "  run            Run locally"
	@echo "  deps           Download dependencies"
	@echo "  generate       Generate OpenAPI code (requires oapi-codegen)"
	@echo "  verify         Verify go.mod is tidy"
	@echo "  deploy         Deploy to Kubernetes/EKS cluster"
	@echo "  all            All checks (deps, lint, test, build)"
	@echo "  help           Display this help message"
