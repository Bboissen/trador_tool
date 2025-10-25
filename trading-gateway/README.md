# Trading Gateway Scaffold

This service will front strategy clients with a low-latency gRPC API for order management. Key goals:

- Binary protocol (Protocol Buffers) and HTTP/2 transport for minimal overhead.
- Configurable multi-venue routing with per-venue JSON translators.
- Strong observability and health reporting from day one.
- Distroless deployment images, static binaries.

## High-Level Architecture

```
Strategy Client (gRPC)
    |
TradingGateway gRPC Server  <-- metrics/logs/health
    |
    |-- OrderFacade (validation, idempotency, audit append)
        |
        |-- VenueRouter (select adapter, provide creds)
              |
              |-- VenueAdapter (JSON builder, transport client)
                        |
                        '-- HTTP/WS to venue API
```

- **TradingGateway.proto**: defines `TradingGateway` service with `PlaceOrder`, `CancelOrder`, `GetOrderStatus`, `StreamFills`.
- **OrderFacade**: validates incoming messages, enforces idempotency, persists audit events (initially Timescale/Postgres; start with in-process append-only log).
- **VenueRouter**: selects adapter via config (single-venue at launch, multi-venue ready). Provides translator + HTTP client.
- **VenueAdapter**: translates normalized order into venue JSON, attaches auth, executes HTTP call, interprets venue response.

## Components to Reuse from `api-gateway`

| api-gateway file | Usage in trading-gateway |
| --- | --- |
| `config.go` | Reuse env helpers (`getenv`, `parseFloatEnv`, etc.). Extend for gRPC-specific settings (listen addr, TLS paths, venue configs). |
| `main.go` logging helpers | Reuse `setupLogger`, `getLogLevel`, `getLogFormat`, `getEnvironmentName`. |
| `middleware.go` request ID + rate limiter | Port concepts to unary gRPC interceptors (request ID, logging, auth placeholder, rate limiting). |
| `ratelimit.go` | Use token bucket logic behind unary interceptor, with TODO for eviction strategy. |

## Current Scaffold

```
trading-gateway/
├── cmd/trading-gateway/main.go       # Entry point (config, logging, server bootstrap)
├── internal/
│   ├── api/trading_service.go        # gRPC server implementation bridging proto ↔ domain
│   ├── config/config.go              # Env-driven settings
│   ├── interceptors/interceptors.go  # gRPC unary interceptors (request id, recovery, logging, rate limit)
│   ├── logging/logging.go            # slog setup (ported from api-gateway)
│   ├── order/                        # Facade + domain types + adapter registry
│   ├── ratelimit/ratelimit.go        # Token-bucket limiter (ported)
│   ├── server/server.go              # gRPC + metrics servers with health + reflection
│   └── venue/mock/adapter.go         # Placeholder adapter implementation
├── pkg/gen/proto/...                 # Generated protobuf + gRPC stubs
├── pkg/idempotency/cache.go          # TTL-based idempotency cache
├── proto/trading_gateway.proto       # Service contract
├── go.mod / go.sum                   # Module dependencies
└── Makefile                          # Build/test/proto placeholders
```

## Execution Walkthrough

1. **Bootstrap (`cmd/trading-gateway/main.go`)**  
   The process parses flags, loads environment configuration, sets up logging, constructs a `server.GatewayServer`, and blocks on `Serve` with signal-based cancellation.

2. **Server bring-up (`internal/server`)**  
   `GatewayServer` wires the unary interceptor chain (request ID, recovery, rate limit, logging), registers gRPC health + reflection, and starts both the gRPC listener and a small HTTP server exposing `/metrics`. On shutdown it marks health `NOT_SERVING`, gracefully drains RPCs, and gives the metrics server time to flush.

3. **Order routing (`internal/order`)**  
   The `Registry` stores venue adapters; `Gateway.Place` validates mandatory fields, checks the idempotency cache, and delegates to the adapter which handles venue-specific translation/transport. Results are cached when an idempotency key is supplied. `Cancel` and `Status` are pass-through helpers on the same adapter interface.

4. **Support layers**  
   - `internal/interceptors`: unary interceptors for request IDs (UUID v4 fallback), panic recovery (maps to gRPC status), rate limiting (token bucket), and structured logging.  
   - `pkg/idempotency`: simple TTL cache—swap for persistent storage when needed.  
   - `internal/venue/mock`: mock adapter used during early testing.

### Request lifecycle (planned)
```
client --> TradingGateway.PlaceOrder (gRPC)
          ↳ unary interceptors (request id → recovery → rate limit → logging)
          ↳ order.Gateway.Place
               ↳ validate input
               ↳ idempotency cache lookup (optional)
               ↳ registry.Adapter(venue).Place (venue-specific translator)
               ↳ idempotency cache store
          ↳ response marshalled to OrderResponse
```
`StreamFills` will follow a similar pattern once venue streaming adapters are introduced.

## Milestones

1. **Proto & Stubs**
   - Create `proto/trading_gateway.proto`.
   - Generate Go stubs under `pkg/gen`.
   - Include health (gRPC health checking) + reflection services.

2. **Core Server Scaffold**
   - `main.go`: config load, logger setup, gRPC server bootstrap.
   - Unary interceptors: logging, panic recovery, request ID.
   - `/metrics` via separate HTTP server (reuse from api-gateway).

3. **Domain Layer**
   - Internal order model + builder pattern.
   - Validator for required fields & numeric constraints.
   - Idempotency cache (in-memory LRU w/ TTL to start).

4. **Venue Adapter Abstraction**
   - Interface: `Translate(ctx, *Order) (*VenueRequest, error)` + `Execute`.
   - Config-driven translator definitions (YAML/JSON mapping rules).
   - Implement mock adapter to smoke-test pipeline.

5. **Persistence & Observability**
   - Append order events to Timescale/Postgres (deferred; initial stub writes to JSON log).
   - Prometheus metrics (`grpc_server_handled_total`, venue latency histogram, etc.).

6. **Packaging**
   - Multi-stage Dockerfile -> distroless.
   - Makefile targets for lint/test/build (use `buf` or `protoc` with docker).

## Next Steps

- Initialize Go module (`github.com/parallelbots/trading-gateway`).
- Draft protobuf service & messages.
- Scaffold gRPC server with logging + health + reflection.
- Run `go mod tidy` (network required) to resolve module dependencies, then `go test ./...`.
- Wire `make proto` to invoke `buf generate` or `protoc` for stub generation and commit generated code.
- Register real venue adapters in `cmd/trading-gateway/main.go` once translators/HTTP clients are ready.
