# Order-Gateway TODO Checklist

This checklist tracks the Go order-gateway, Postgres schema, and upcoming gRPC work. The current stack runs locally via docker-compose with Postgres 18 and a minimal HTTP health/DB probe.

## 0) Scope Reset and Repo Layout
- [ ] Confirm we are resetting to: keep `README.md` and `order_service` API-gateway template only.
- [ ] Archive or remove other directories (adapters, old gateway, examples) after sign-off.
- [ ] Establish new top-level layout: `order_service/` (Go), `adapters/` (Rust per venue), `proto/`, `infra/`, `ci/`.

## 1) Toolchains and Versions
- [x] Go toolchain pinned to 1.25 (build image uses golang:1.25).
- [ ] Rust toolchain pinned to 1.90 (not in scope for this milestone).
- [x] Postgres 18 in local/dev (container tag and init scripts).
- [ ] Protobuf toolchain: `buf`, `protoc`, Go plugins pinned.

## 2) Database Schema (Postgres 18)
- [x] Init scripts loaded in correct order (`00a_infra_superuser.sql` before `00b_complete_setup.sql`).
- [ ] Validate SQL in `order_service` defines canonical entities: `orders`, `order_events`, `venues`, `accounts`, `balances` (if applicable).
- [ ] Ensure keys/constraints: `orders(id uuid pk)`, `idempotency_key unique`, FK to `venues`, cascade rules.
- [ ] Enumerations for `order_status`, `order_side`, `time_in_force` aligned to venue-agnostic semantics.
- [ ] Indexes for latency paths: `(venue_id,status,created_at)`, `(client_order_id)`, `(idempotency_key)`.
- [ ] Outbox/inbox tables for reliable messaging (eventual RabbitMQ publishing + idempotent consumption).
- [ ] Partitioning strategy (by day or venue) if throughput requires; verify in SQL files or defer with a note.

## 3) Protobuf Contracts (Source of Truth for APIs)
- [ ] Define `proto/trading/v1/trading.proto` for order service public API (gRPC) matching SQL schema types.
- [ ] Define `proto/adapter/v1/adapter.proto` for venue adapter gRPC (Place/Cancel/Status + execution stream).
- [ ] Define `proto/events/v1/events.proto` for RabbitMQ payloads (OrderAccepted, OrderUpdated, Fill, CancelRejected).
- [ ] Map SQL columns -> proto fields precisely (names, types, enums). Document mapping comments in the .proto files.
- [ ] Oneof blocks for price types (limit/market) and trigger parameters; explicit `idempotency_key` field.
- [ ] Backward-compat reserved fields and stable package names; add buf-breaking checks.

## 4) Codegen and Language Bindings
- [ ] Configure `buf.gen.yaml` for Go (gRPC + gRPC-Gateway JSON), and Rust (tonic/prost) stubs.
- [ ] Generate Go stubs into `order_service/pkg/gen/...` and Rust stubs into `adapters/<venue>/crate` or a shared crate.
- [ ] Verify codegen compiles on Go 1.25 and Rust 1.90 in CI.

## 5) Order Gateway Service (Go)
- [x] Minimal HTTP server with `/health`, `/ready` and DB probe `/orders/count`.
- [x] DB access via `pgxpool` and readiness ping.
- [ ] Bootstrap gRPC server with context timeouts and interceptors.
- [ ] Implement `PlaceOrder`, `CancelOrder`, `GetOrder` (DB-backed using existing SQL functions).
- [ ] Idempotency: enforce on `(wallet_id, idempotency_key)`.
- [ ] Config: env-driven, structured logs, basic metrics.

## 6) Venue Adapters (Rust, one per venue)
- [ ] Template binary (distroless) implementing `adapter.v1` gRPC: `Place`, `Cancel`, `Status`, and optional `StreamExecutions`.
- [ ] Map generic order to venue REST/on-chain, sign requests, enforce timeouts; return normalized status and IDs.
- [ ] Publish execution reports to RabbitMQ (or push over gRPC stream) with correlation IDs.
- [ ] In-memory ephemeral cache for outstanding orders only if needed; no durable DB in adapters.
- [ ] Telemetry parity with order service (logs/metrics/traces), per-venue secrets and auth models.

## 7) Messaging (RabbitMQ)
- [ ] Exchanges/queues: `orders.events.v1` (fanout/topic), `executions.events.v1`, DLX/DLQ for failures.
- [ ] Message schema = protobuf `events.v1`; content-type `application/x-protobuf` or JSON for debug.
- [ ] Publisher confirms enabled; consumers are idempotent with inbox table and dedup keys.
- [ ] Retry/TTL policy and dead-letter strategy documented and configured.

## 8) Latency/Performance Objectives
- [ ] Set SLOs: P99 place->ack < X ms, P99 update propagation < Y ms.
- [ ] DB: prepared statements, connection pool sizing, write batching for outbox.
- [ ] gRPC: keepalive, TLS off in dev, gzip disabled unless bandwidth-bound, deadlines per RPC.
- [ ] MQ: prefetch tuning, acks-on-persist, consumer concurrency caps.
- [ ] Profile hot paths; add benchmark harness (Go and Rust) for encode/decode + DB insert.

## 9) Reliability and Reconciliation
- [ ] Outbox/inbox patterns implemented and tested under crash/restart.
- [ ] Reconciliation job: periodic venue order status sync to correct drift.
- [ ] Circuit breakers and backoff for venue outages; fall back to queued submits/cancels.
- [ ] Exactly-once status application using `(order_id, venue_event_id)` or `(order_id, seq)`.

## 10) Security and Access
- [ ] Per-service secrets: DB URLs, MQ creds, venue keys stored in vault/secret manager; no secrets in images.
- [ ] Network policies to limit adapter egress to venue endpoints; TLS verification on.
- [ ] AuthN/Z for external clients of order service (mTLS or JWT), scoped API keys per bot.

## 11) Observability
- [ ] Structured logs with correlation IDs (`order_id`, `idempotency_key`, `venue_order_id`).
- [ ] Metrics: request latency, DB timings, MQ lag, adapter error rates, reconciliation deltas.
- [ ] Tracing across services with W3C context propagation; spans for DB and MQ operations.

- [x] Dockerfile (distroless) for Go order-gateway; non-root.
- [x] docker-compose for local: Postgres 18 + order-gateway.
- [ ] CI: lint, unit tests, buf lint/breaking, codegen verification, integration tests with services up.
- [ ] Rollouts: versioned images, canary or rolling; health gates; config via env.

## 13) Testing Strategy
- [ ] Unit tests for validation, state transitions, idempotency.
- [ ] Integration tests: end-to-end place->adapter->exec report->DB update using mock venue.
- [ ] Load tests to validate P99 latency and back-pressure behavior.
- [ ] Failure injection: MQ down, adapter errors, DB failover.

## 14) Acceptance Criteria (Milestone 0: Local Stack Up)
- [x] Postgres 18 starts and applies init SQL without errors.
- [x] Order-gateway connects to DB and exposes health/ready.
- [x] `/orders/count` responds (table exists, count returned).

## 15) Acceptance Criteria (Next Milestone: gRPC MVP)
- [ ] Place and cancel an order via gRPC; order persisted with idempotency.
- [ ] REST via gRPC-Gateway optional; health endpoints remain.
- [ ] Basic metrics for request latency and DB timings.

## 16) Open Questions
- [ ] Use `sqlc` vs hand-written queries for Go performance and type safety?
- [ ] gRPC stream from adapter vs MQ for executions (hybrid or single path)?
- [ ] Partitioning strategy timing (now vs post-MVP) given latency goals?
- [ ] On-chain adapter gas/nonce management model and failure semantics?
