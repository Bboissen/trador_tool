# Hyperliquid SDK Service

A containerized service providing REST and WebSocket connectivity to the Hyperliquid DEX using the official Python SDK.

## Features

- ✅ Official Hyperliquid Python SDK integration
- ✅ REST API connectivity
- ✅ WebSocket support for real-time data
- ✅ Comprehensive health checks (SDK, venue, optional heartbeat)
- ✅ Docker containerized with health monitoring
- ✅ Mainnet and Testnet support
- ✅ Production-ready logging and error handling

## Quick Start

### 1. Setup Environment

```bash
# Copy the example environment file
cp .env.example .env

# Edit .env with your configuration (optional)
nano .env
```

### 2. Build and Run

```bash
# Build the Docker image
docker-compose build

# Start the service
docker-compose up -d

# View logs
docker-compose logs -f hyperliquid_sdk
```

### 3. Check Health

```bash
# Check container health status
docker-compose ps

# Run health check manually
docker-compose exec hyperliquid_sdk python healthcheck.py
```

## Configuration

All configuration is done via environment variables in the `.env` file:

| Variable | Description | Default |
|----------|-------------|---------|
| `HYPERLIQUID_NETWORK` | Target network (`mainnet` or `testnet`) | `testnet` |
| `HYPERLIQUID_API_URL` | Mainnet API endpoint override | `https://api.hyperliquid.xyz` |
| `HYPERLIQUID_TESTNET` | Enable testnet mode | `true` |
| `HYPERLIQUID_TESTNET_API_URL` | Testnet API endpoint override | `https://api.hyperliquid-testnet.xyz` |
| `HYPERLIQUID_TESTNET_PUBLIC_KEY` | Testnet account public address | - |
| `HYPERLIQUID_TESTNET_PRIVATE_KEY` | Testnet private key for API/agent wallet | - |
| `HYPERLIQUID_TESTNET_ACCOUNT_ADDRESS` | Account wallet address (used for info/balance queries) | - |
| `BALANCE_MONITOR_INTERVAL` | Seconds between balance logs | `60` |
| `HEARTBEAT_URL` | Optional webhook for outbound health pings | - |
| `SERVICE_PORT` | Service port for health checks | `8080` |
| `LOG_LEVEL` | Logging level (DEBUG, INFO, WARNING, ERROR) | `INFO` |
| `HEALTHCHECK_INTERVAL` | Seconds between health checks | `30` |
| `HEALTHCHECK_TIMEOUT` | Health check timeout in seconds | `10` |

## Health Checks

The service implements three layers of health monitoring:

1. **SDK Reachability**: Tests the Hyperliquid SDK by fetching exchange time
2. **Venue Availability**: Checks Hyperliquid API endpoint availability
3. **Optional Heartbeat**: Sends status to external monitoring service

Health checks run automatically at the configured interval and are accessible via:

```bash
docker-compose exec hyperliquid_sdk python healthcheck.py
```

## Runtime Configuration File

The container writes a Hyperliquid-compatible `config.json` at `/app/runtime/config.json` when it starts. Values are sourced from the environment:

- `HYPERLIQUID_TESTNET_PUBLIC_KEY` / `HYPERLIQUID_TESTNET_PRIVATE_KEY`
- `HYPERLIQUID_KEYSTORE_PATH` (optional)
- `HYPERLIQUID_MULTI_SIG_USERS` (optional JSON list)

Update `.env` with your credentials before launching the container. The file is recreated on each start and never baked into the Docker image, keeping secrets out of source control.

## SDK Capabilities

The Hyperliquid SDK provides access to:

### Information API (Public)
- Market data and prices
- Order book data
- Trade history
- User positions and balances (with address)
- Funding rates
- Perpetual contract metadata

### Exchange API (Private - requires wallet)
- Place, cancel, and modify orders
- Manage positions
- Execute trades
- Transfer funds

### WebSocket API
- Real-time market data
- Order updates
- Position updates
- Trade feeds

## Development

### Local Testing

```bash
# Run the service locally without Docker
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies
pip install -e git+https://github.com/hyperliquid-dex/hyperliquid-python-sdk.git#egg=hyperliquid
pip install -r requirements.txt

# Run the service
python main.py
```

### Viewing Logs

```bash
# Follow logs
docker-compose logs -f hyperliquid_sdk

# View last 100 lines
docker-compose logs --tail=100 hyperliquid_sdk
```

### Rebuilding

```bash
# Rebuild after code changes
docker-compose build --no-cache

# Restart service
docker-compose restart hyperliquid_sdk
```

## Monitoring

### Container Status

```bash
# Check if container is healthy
docker-compose ps
# Should show "healthy" in the status

# Inspect health check details
docker inspect hyperliquid_sdk --format='{{json .State.Health}}' | jq
```

### External Monitoring

To enable external monitoring via webhook:

1. Sign up for a service like [Healthchecks.io](https://healthchecks.io)
2. Create a new check and copy the ping URL
3. Add to `.env`: `HEARTBEAT_URL=https://hc-ping.com/your-uuid-here`
4. Restart the service

## Troubleshooting

### Service won't start

```bash
# Check logs for errors
docker-compose logs hyperliquid_sdk

# Verify environment variables
docker-compose config
```

### Health checks failing

```bash
# Run health check with verbose output
docker-compose exec hyperliquid_sdk python healthcheck.py

# Test SDK directly
docker-compose exec hyperliquid_sdk python -c "from hyperliquid.info import Info; print(Info().exchange_time())"
```

### Network issues

```bash
# Check if container can reach Hyperliquid API
docker-compose exec hyperliquid_sdk curl -I https://api.hyperliquid.xyz/info

# Restart networking
docker-compose down
docker-compose up -d
```

## Production Deployment

For production use:

1. ✅ Set appropriate log levels (`LOG_LEVEL=WARNING`)
2. ✅ Configure external monitoring (`HEARTBEAT_URL`)
3. ✅ Use Docker resource limits
4. ✅ Set up log rotation (already configured in docker-compose.yml)
5. ✅ Never commit real private keys (use secrets management)
6. ✅ Monitor container health and set up alerts

## Resources

- [Hyperliquid Official SDK](https://github.com/hyperliquid-dex/hyperliquid-python-sdk)
- [Hyperliquid Documentation](https://hyperliquid.gitbook.io/hyperliquid-docs)
- [Hyperliquid API Docs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api)

## License

This adapter follows the license of the official Hyperliquid Python SDK.
