# Parallel Bots Scaffold

This README maps every checked-in file to its purpose, highlights the key entry points you are likely to touch, and finishes with the current delivery stage for the project.

**Repo Map**
- `PROMPT.md` documents the long-term product brief and acceptance criteria for each service milestone.
- `report.md` snapshots the scaffold status so you can compare it against the prompt.
- `docker-compose.yml` launches the ARM64 stack (core, postgres, redis, prometheus, grafana) and pins observability mounts from `infra/`.
- `deploy/Dockerfile.core` performs the multi-stage build for the `core` binary, compiling in the builder stage and copying into `gcr.io/distroless/cc-debian12`.
- `ci/buildx-arm64.yml` provisions QEMU + buildx, builds the core image for `linux/arm64`, and executes `cargo test --workspace`.
- `infra/prometheus.yml` configures scraping of `core:9100/metrics`; `infra/grafana/dashboards/execution.json` seeds the starter dashboard Grafana loads on boot.

**Proto Contracts**
- `proto/marketdata.proto` defines `OutcomeQuote` streaming via `MarketData.StreamOutcomeBooks`, matching the broadcast market bus.
- `proto/trading.proto` publishes the `Trading` RPCs (`Place`, `Cancel`, `StreamReports`) and explicitly references `.google.protobuf.Empty` so tonic emits `prost_types::Empty`.
- `proto/control.proto` holds TODO stubs for MCP control flows (new_strategy/backtest/deploy) that will be populated in a later milestone.

**Rust Workspace – shared-proto**
- `rust/shared-proto/build.rs:33` runs `tonic_build`, writes `pb_descriptor.bin` for reflection, and binds `google.protobuf.Empty` to `::prost_types::Empty`.
- `rust/shared-proto/src/lib.rs:5` exposes generated `marketdata`, `trading`, and `control` modules plus the `descriptor_set()` helper used by reflection and tests.

**Rust Workspace – core crate**
- `rust/core/src/lib.rs:42` implements `CoreConfig::from_env`, parsing socket addresses, CSV feed path, and risk limits from environment variables with sensible defaults.
- `rust/core/src/lib.rs:107` runs the orchestrator: initializes telemetry, seeds metrics, hydrates the CSV feed on a background task, and launches the gRPC stack.
- `rust/core/src/grpc.rs:44` adapts `TradingApi` onto the order service and streams exec reports via `tokio::sync::broadcast`.
- `rust/core/src/grpc.rs:137` starts the tonic server, registers `tonic-health`, enables reflection by default (override with `GRPC_REFLECTION=false`), and serves the Trading + MarketData APIs.
- `rust/core/src/market_bus.rs:40` publishes quotes with freshness accounting, while `rust/core/src/market_bus.rs:53` loads CSV data and pushes it onto the bus.
- `rust/core/src/order_service.rs:138` enforces validation, risk checks, and client idempotency in `OrderServiceMem::place`, then simulates fills that update PnL + metrics.
- `rust/core/src/order_service.rs:180` manages cancel semantics, refusing mismatched venues or already-filled orders.
- `rust/core/src/risk.rs:54` guards venue exposure and max order quantity; `rust/core/src/risk.rs:95` tracks daily loss limits before halting trading.
- `rust/core/src/pnl.rs:39` computes realized PnL deltas, maintains running average prices, and refreshes unrealized gauges on new marks.
- `rust/core/src/metrics.rs:17` installs the Prometheus recorder, `rust/core/src/metrics.rs:65` drives uptime tracking, and `rust/core/src/metrics.rs:128` serves `/metrics` via Axum.
- `rust/core/src/errors.rs:7` defines typed domain errors and conversions to gRPC status for future richer error propagation.
- `rust/core/src/main.rs:5` boots the Tokio runtime and hands off to `CoreApp`.

**Rust Workspace – adapter-polymarket**
- `rust/adapter-polymarket/src/lib.rs:18` exposes the `PolymarketAdapter` façade with stubbed async methods that will gain real networking during Service 3.
- `rust/adapter-polymarket/src/capabilities.rs:17` returns the static capability profile exposed to strategies.
- `rust/adapter-polymarket/src/metrics.rs:9` registers a placeholder reconnect counter so instrumentation is ready once networking arrives.

**Rust Workspace – strategy-dutchbook**
- `rust/strategy-dutchbook/src/lib.rs:8` implements `compute_basket_cost`, `epsilon`, and `is_arb`, the shared Dutch-book primitives destined for the WASM host.
- `rust/strategy-dutchbook/tests/edge_math_tests.rs` validates invariants such as uniform asks producing no arb and permutation invariance.
- `rust/strategy-dutchbook/benches/compute.rs` scaffolds Criterion benchmarks to time the basket cost calculations across outcome counts.

**Tests, Data, and Fixtures**
- `rust/core/tests/order_service_tests.rs` covers idempotent placement, cancel paths, and simulated fills on the in-memory service.
- `rust/core/tests/market_bus_tests.rs` checks CSV ingestion plus broadcast fan-out behavior.
- `rust/core/tests/integration_tests.rs:40` boots both tonic services, feeds `sample_quotes.csv`, probes health via `grpc.health.v1.Health/Check`, and asserts trade + market flows.
- `rust/core/tests/data/sample_quotes.csv` supplies mock order book snapshots for tests and local CSV playback.
- `rust/adapter-polymarket/tests/adapter_polymarket_tests.rs` snapshots capability defaults and ensures metrics registration is idempotent.

**Infrastructure & Tooling**
- `deploy/Dockerfile.core:1` drives the release build used by Compose and CI.
- `infra/prometheus.yml:1` scrapes the metrics endpoint every 15 seconds.
- `infra/grafana/dashboards/execution.json` preloads uptime, order latency, and PnL panels for the Prometheus metrics.
- `ci/buildx-arm64.yml:8` defines the GitHub Actions job that cross-builds and tests the workspace.

**Current Stage**

We are at the Service 1 deliverable: shared protobufs, the core orchestrator (with health + reflection), Dutch-book math utilities, and baseline observability are production-ready; Polymarket networking (Service 3), the WASM strategy host (Service 4), Go-based MCP control plane, and persistence layers are explicitly planned but not yet implemented.
