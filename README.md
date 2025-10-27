# Order Gateway (Go) — Local Dev Stack

This repo currently focuses on a Go order-gateway service talking to a Postgres 18 database. The goal is to stand up a central order service (gRPC-first) that persists canonical order state and later dispatches to venue adapters.

What’s running now
- Postgres 18 with schema initialized from `order_service/*.sql`.
- Minimal Go service in `order-gateway/` exposing HTTP endpoints to verify DB connectivity:
  - `GET /health` liveness
  - `GET /ready` DB ping
  - `GET /orders/count` count from `trading.orders`

Quickstart
- Build and run: `docker compose up --build`
- Endpoints:
  - `http://localhost:8080/health`
  - `http://localhost:8080/ready`
  - `http://localhost:8080/orders/count`
- Reset the DB if init order changes: `docker compose down -v && docker compose up --build`

Versions
- Go 1.25 for the order-gateway build.
- Postgres 18 for the database container.

Repo map (relevant to current milestone)
- `docker-compose.yml` root stack: Postgres 18 + order-gateway service.
- `order-gateway/` Go HTTP service (to be expanded into gRPC + gRPC-Gateway):
  - `main.go` health/ready/orders count, pgx connection pool
  - `Dockerfile` multi-stage build (golang:1.25 → distroless)
  - `go.mod` pinning pgx v5
- `order_service/` Postgres image build with init SQL:
  - `Dockerfile` copies SQL and controls init order
  - `00_infra_superuser.sql` schemas, roles, extensions
  - `00_complete_setup.sql` core tables (including `trading.orders`)
  - `01_integrations.sql`, `02_operations.sql`, `03_security_monitoring.sql`, `04_indexes_partitions.sql`

Next steps
- Define protobufs aligned to `trading.orders` and generate Go stubs.
- Add a gRPC server to order-gateway and implement `PlaceOrder` with idempotency.
- Optionally expose REST via gRPC-Gateway; keep HTTP health/ready endpoints.

See `TODO.md` for a detailed checklist and milestone plan.
