PROTOC ?= protoc
BUF ?= buf

.PHONY: proto
proto:
	@echo ">> generate protobuf stubs"
	@mkdir -p pkg/gen/tradinggateway/v1
	$(PROTOC) --go_out=pkg/gen --go-grpc_out=pkg/gen \
		--go_opt=paths=source_relative \
		--go-grpc_opt=paths=source_relative \
		proto/trading_gateway.proto

.PHONY: build
build:
	CGO_ENABLED=0 go build ./cmd/trading-gateway

.PHONY: test
test:
	go test ./...
