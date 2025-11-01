# Lighter Adapter Stack

This stack builds the official [Lighter Python SDK](https://github.com/elliottech/lighter-python) into a lightweight container that maintains both REST polling and WebSocket subscriptions.

## Prerequisites

- Docker Engine 26+
- Docker Compose v2.23+

## Setup

1. Copy the sample environment file and edit with real identifiers:

   ```shell
   cd adapter/Lighter
   cp env.example .env
   ```

2. Populate `.env`:

   - `LIGHTER_API_HOST` – REST base URL (defaults to mainnet).
   - `LIGHTER_WS_ORDER_BOOK_IDS` / `LIGHTER_WS_ACCOUNT_IDS` – comma-separated identifiers. At least one must be set.
   - Optional knobs: `LIGHTER_WS_HOST`, `LIGHTER_WS_PATH`, polling and health thresholds, log level.
   - REST auth (optional):
     - `LIGHTER_ACCOUNT_INDEX`, `LIGHTER_API_KEY_INDEX`, `LIGHTER_API_KEY_PRIVATE_KEY`
     - `LIGHTER_API_KEY` for header-based auth, `LIGHTER_REST_MARKET_IDS` for markets to fetch
     - `LIGHTER_AUTH_TOKEN_TTL_SECONDS` to tune refresh cadence for signed `auth` tokens
   - WebSocket logging (optional): set `LIGHTER_WS_LOG_PRETTY=true` to emit pretty-printed payloads at debug level.

## Running

```shell
docker compose up --build
```

The container runs `app/main.py`, which:

- Polls `RootApi.info()` at the configured interval.
- Fetches account detail when `LIGHTER_ACCOUNT_INDEX` is set, and, if the SDK exposes it, active orders for each `LIGHTER_REST_MARKET_IDS` when API credentials are present.
- Streams WebSocket updates for the configured order books/accounts (set at least one `LIGHTER_WS_ORDER_BOOK_IDS` or `LIGHTER_WS_ACCOUNT_IDS`).
- Persists heartbeat timestamps for health monitoring.

## Health Monitoring

`docker-compose.yml` registers a container health check that executes `app/healthcheck.py`. The script ensures:

- REST heartbeat fresher than `LIGHTER_HEALTH_MAX_REST_AGE_SECONDS`.
- WebSocket heartbeat fresher than `LIGHTER_HEALTH_MAX_WS_AGE_SECONDS` when subscriptions are configured.

Tune the thresholds in `.env` if the venue enforces tighter rate limits.

## Customising the Build

`docker-compose.yml` pins the SDK source to tag `v0.1.4`. To test other revisions, override the build args:

```shell
docker compose build \
  --build-arg LIGHTER_REPO_REF=v0.1.3
```

The base image can be swapped similarly with `--build-arg PYTHON_IMAGE=python:3.12.6-slim`.

## Platform

- The bundled signer binaries support Linux x86_64 and macOS arm64 only. The stack pins the Docker image to `linux/amd64`; on Apple Silicon this relies on Docker’s emulation layer. Ensure virtualization extensions are enabled if you see signer initialization failures.
