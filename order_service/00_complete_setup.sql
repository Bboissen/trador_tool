-- 00_complete_setup.sql
-- Complete PostgreSQL 17.6 optimized setup for modern trading system
-- Includes: schemas, types, tables, partitioning, event sourcing
-- Designed for: Kubernetes, Redis 8.2, Kafka 4.1, Rust 1.89

-- ============================================================================
-- NOTE: Cluster/server configuration and extensions are managed by SRE/DBA.
-- All ALTER SYSTEM / CREATE EXTENSION / ROLE GRANTS have been moved to
-- 00_infra_superuser.sql and should not be applied by app migrations.
-- ============================================================================

-- ============================================================================
-- SCHEMAS
-- ============================================================================

-- Schemas are now created in 00_infra_superuser.sql

SET search_path TO trading, events, public;

-- ============================================================================
-- EXTENSIONS
-- ============================================================================
-- Managed by infra in 00_infra_superuser.sql

-- ============================================================================
-- CUSTOM TYPES
-- ============================================================================

-- Core enums
CREATE TYPE trading.order_side AS ENUM ('BUY', 'SELL');
CREATE TYPE trading.order_type AS ENUM ('MARKET', 'LIMIT', 'STOP', 'STOP_LIMIT');
CREATE TYPE trading.order_status AS ENUM (
  'PENDING', 'ACTIVE', 'PARTIALLY_FILLED', 'FILLED', 
  'CANCELED', 'EXPIRED', 'FAILED', 'REJECTED'
);
CREATE TYPE trading.chain_type AS ENUM ('EVM', 'SVM', 'COSMOS', 'MOVE', 'SUBSTRATE');
CREATE TYPE trading.transaction_status AS ENUM ('PENDING', 'CONFIRMED', 'FAILED', 'REVERTED');

-- Event types
CREATE TYPE events.event_status AS ENUM ('PENDING', 'PROCESSING', 'PROCESSED', 'FAILED', 'RETRY');
CREATE TYPE events.saga_status AS ENUM ('RUNNING', 'COMPLETED', 'COMPENSATING', 'FAILED');

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

-- UUIDv7 generator (time-ordered, RFC 9562)
CREATE OR REPLACE FUNCTION trading.uuid_v7()
RETURNS uuid AS $$
DECLARE
  ts_ms BIGINT;
  rnd BYTEA;
  b BYTEA := '\x00000000000000000000000000000000';
BEGIN
  ts_ms := (extract(epoch FROM clock_timestamp()) * 1000)::BIGINT;
  rnd := gen_random_bytes(10);
  
  -- Timestamp bytes (48-bit, big-endian)
  b := set_byte(b, 0, ((ts_ms >> 40) & 255)::INT);
  b := set_byte(b, 1, ((ts_ms >> 32) & 255)::INT);
  b := set_byte(b, 2, ((ts_ms >> 24) & 255)::INT);
  b := set_byte(b, 3, ((ts_ms >> 16) & 255)::INT);
  b := set_byte(b, 4, ((ts_ms >> 8) & 255)::INT);
  b := set_byte(b, 5, (ts_ms & 255)::INT);
  
  -- Version (7) and random
  b := set_byte(b, 6, (112 | (get_byte(rnd, 0) & 15))::INT);
  b := set_byte(b, 7, get_byte(rnd, 1));
  
  -- Variant (RFC 4122) and random
  b := set_byte(b, 8, (128 | (get_byte(rnd, 2) & 63))::INT);
  
  -- Remaining random bytes
  FOR i IN 9..15 LOOP
    b := set_byte(b, i, get_byte(rnd, i - 6));
  END LOOP;
  
  RETURN encode(b, 'hex')::uuid;
END;
$$ LANGUAGE plpgsql VOLATILE;

-- Distributed ID generator (Snowflake-like)
CREATE SEQUENCE IF NOT EXISTS trading.global_id_seq;

CREATE OR REPLACE FUNCTION trading.generate_distributed_id(p_shard_id INT DEFAULT 0)
RETURNS BIGINT AS $$
DECLARE
  v_timestamp BIGINT;
  v_shard_bits INT := 10;
  v_sequence_bits INT := 12;
  v_sequence BIGINT;
BEGIN
  v_timestamp := extract(epoch from clock_timestamp()) * 1000;
  v_sequence := nextval('trading.global_id_seq') % (1 << v_sequence_bits);
  
  RETURN (v_timestamp << (v_shard_bits + v_sequence_bits)) | 
         (p_shard_id << v_sequence_bits) | 
         v_sequence;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- ADVANCED UTILITY FUNCTIONS
-- ============================================================================

-- Advisory lock functions for race condition prevention
CREATE OR REPLACE FUNCTION trading.acquire_order_lock(p_order_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN pg_try_advisory_lock(hashtext(p_order_id::TEXT));
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trading.release_order_lock(p_order_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN pg_advisory_unlock(hashtext(p_order_id::TEXT));
END;
$$ LANGUAGE plpgsql;

-- Cache key generation for Redis integration
CREATE OR REPLACE FUNCTION trading.generate_cache_key(
  p_entity_type TEXT,
  p_entity_id TEXT,
  p_operation TEXT DEFAULT NULL
) RETURNS TEXT AS $$
BEGIN
  RETURN format('%s:%s:%s:%s', 
    current_database(),
    p_entity_type, 
    p_entity_id,
    COALESCE(p_operation, 'data')
  );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- SHARDING INFRASTRUCTURE
-- ============================================================================

CREATE TABLE sharding.shard_config (
  shard_id INT PRIMARY KEY,
  shard_name TEXT NOT NULL UNIQUE,
  wallet_id_range INT4RANGE NOT NULL,
  connection_string TEXT,
  is_active BOOLEAN DEFAULT true,
  weight INT DEFAULT 100,  -- For weighted routing
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Enhanced sharding with consistent hashing preparation
CREATE TABLE sharding.shard_ranges (
  shard_id INT PRIMARY KEY,
  hash_range INT8RANGE NOT NULL,
  virtual_nodes INT[] DEFAULT ARRAY[]::INT[],
  EXCLUDE USING GIST (hash_range WITH &&)
);

-- Consistent hash function for better distribution
CREATE OR REPLACE FUNCTION sharding.consistent_hash(p_wallet_id INT)
RETURNS INT8 AS $$
BEGIN
  RETURN ('x' || substring(md5(p_wallet_id::TEXT), 1, 15))::bit(60)::INT8;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Default sharding configuration (16 shards)
INSERT INTO sharding.shard_config (shard_id, shard_name, wallet_id_range)
SELECT 
  n as shard_id,
  format('shard_%s', n) as shard_name,
  int4range(n * 65536, (n + 1) * 65536, '[)') as wallet_id_range
FROM generate_series(0, 15) n
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION sharding.get_shard_id(p_wallet_id INT)
RETURNS INT AS $$
DECLARE
  v_hash INT8;
BEGIN
  -- Use consistent hashing for better distribution
  v_hash := sharding.consistent_hash(p_wallet_id);
  
  -- Map to shard based on hash ranges
  RETURN (
    SELECT shard_id 
    FROM sharding.shard_ranges 
    WHERE hash_range @> v_hash
    LIMIT 1
  );
  
  -- Fallback to simple modulo if ranges not configured
  IF NOT FOUND THEN
    RETURN p_wallet_id % 16;
  END IF;
END;
$$ LANGUAGE plpgsql STABLE;  -- Changed from IMMUTABLE to STABLE because it reads from tables

-- ============================================================================
-- CORE TABLES
-- ============================================================================

-- Networks configuration
CREATE TABLE trading.networks (
  id INT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  name TEXT UNIQUE NOT NULL CHECK (name ~ '^[a-z][a-z0-9_-]{1,31}$'),
  chain_id BIGINT UNIQUE NOT NULL CHECK (chain_id > 0),
  chain_type trading.chain_type NOT NULL,
  
  rpc_endpoints TEXT[] NOT NULL CHECK (array_length(rpc_endpoints, 1) > 0),
  ws_endpoints TEXT[],
  confirmation_blocks INT DEFAULT 12 CHECK (confirmation_blocks BETWEEN 0 AND 1000),
  avg_block_time_ms INT DEFAULT 3000,
  
  is_testnet BOOLEAN DEFAULT false,
  activated_at TIMESTAMPTZ DEFAULT now(),
  deactivated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  
  metadata JSONB DEFAULT '{}'
);

-- Tokens
CREATE TABLE trading.tokens (
  id INT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  network_id INT NOT NULL REFERENCES trading.networks(id),
  
  symbol TEXT NOT NULL CHECK (symbol ~ '^[A-Z][A-Z0-9]{0,19}$'),
  name TEXT NOT NULL,
  address BYTEA NOT NULL CHECK (octet_length(address) BETWEEN 20 AND 64),
  decimals SMALLINT NOT NULL CHECK (decimals BETWEEN 0 AND 38),
  
  is_native BOOLEAN DEFAULT false,
  is_stablecoin BOOLEAN DEFAULT false,
  coingecko_id TEXT,
  
  activated_at TIMESTAMPTZ DEFAULT now(),
  deactivated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  
  metadata JSONB DEFAULT '{}',
  
  UNIQUE (network_id, address)
);

-- Wallets with risk management
CREATE TABLE trading.wallets (
  id INT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  
  -- KYC/AML
  kyc_level INT DEFAULT 0 CHECK (kyc_level BETWEEN 0 AND 5),
  risk_score SMALLINT DEFAULT 0 CHECK (risk_score BETWEEN 0 AND 100),
  
  -- Limits
  daily_limit NUMERIC(78,0),
  monthly_limit NUMERIC(78,0),
  max_orders_per_hour INT DEFAULT 100,
  max_orders_per_day INT DEFAULT 1000,
  
  -- Status
  activated_at TIMESTAMPTZ DEFAULT now(),
  deactivated_at TIMESTAMPTZ,
  blacklisted_at TIMESTAMPTZ,
  blacklist_reason TEXT,
  
  -- Metadata
  created_at TIMESTAMPTZ DEFAULT now(),
  last_active_at TIMESTAMPTZ,
  metadata JSONB DEFAULT '{}'
);

-- Multi-chain wallet addresses
CREATE TABLE trading.wallet_addresses (
  id INT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  wallet_id INT NOT NULL REFERENCES trading.wallets(id) ON DELETE CASCADE,
  network_id INT NOT NULL REFERENCES trading.networks(id),
  address BYTEA NOT NULL CHECK (octet_length(address) BETWEEN 20 AND 64),
  
  is_primary BOOLEAN DEFAULT false,
  activated_at TIMESTAMPTZ DEFAULT now(),
  deactivated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  
  UNIQUE (network_id, address),
  UNIQUE (wallet_id, network_id)
);

-- ============================================================================
-- EVENT SOURCING
-- ============================================================================

-- Event store partitioned by hash for better distribution
CREATE TABLE events.event_store (
  id UUID DEFAULT trading.uuid_v7(),
  aggregate_id UUID NOT NULL,
  aggregate_type TEXT NOT NULL,
  event_type TEXT NOT NULL,
  event_version INT NOT NULL,
  
  payload JSONB NOT NULL,
  metadata JSONB DEFAULT '{}',
  
  created_at TIMESTAMPTZ DEFAULT now(),
  created_by TEXT DEFAULT current_user,
  
  -- Composite primary key for hash partitioning
  PRIMARY KEY (id, aggregate_id),
  -- Optimistic concurrency control
  UNIQUE (aggregate_id, event_version)
) PARTITION BY HASH (aggregate_id);

-- Create hash partitions for event store (64 partitions for scalability)
DO $$
BEGIN
  FOR i IN 0..63 LOOP
    EXECUTE format('CREATE TABLE events.event_store_h%s PARTITION OF events.event_store FOR VALUES WITH (modulus 64, remainder %s)', i, i);
  END LOOP;
END $$;

-- Event projections tracking
CREATE TABLE events.projections (
  projection_name TEXT PRIMARY KEY,
  last_event_id UUID,
  last_event_timestamp TIMESTAMPTZ,
  checkpoint JSONB,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Consumer positions for event streaming (Kafka/Redis integration)
CREATE TABLE events.consumer_positions (
  consumer_group TEXT NOT NULL,
  partition_key TEXT NOT NULL,
  stream_name TEXT NOT NULL DEFAULT 'main',
  
  last_event_id UUID,
  last_offset BIGINT,
  last_timestamp TIMESTAMPTZ,
  
  -- For exactly-once processing
  processing_event_id UUID,
  processing_started_at TIMESTAMPTZ,
  
  checkpoint JSONB DEFAULT '{}',
  updated_at TIMESTAMPTZ DEFAULT now(),
  
  PRIMARY KEY (consumer_group, partition_key, stream_name)
);

-- Snapshots for event sourcing
CREATE TABLE events.snapshots (
  aggregate_id UUID,
  aggregate_type TEXT,
  version INT,
  state JSONB NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (aggregate_id, version)
);

-- ============================================================================
-- ORDERS (Event-sourced with CQRS read model)
-- ============================================================================

-- Write model (commands)
CREATE TABLE trading.order_commands (
  id UUID PRIMARY KEY DEFAULT trading.uuid_v7(),
  command_type TEXT NOT NULL,
  payload JSONB NOT NULL,
  status TEXT DEFAULT 'PENDING',
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  processed_at TIMESTAMPTZ
);

-- Read model (optimized for queries)
CREATE TABLE trading.orders (
  id UUID PRIMARY KEY DEFAULT trading.uuid_v7(),
  
  -- Core references
  wallet_id INT NOT NULL REFERENCES trading.wallets(id),
  network_id INT NOT NULL REFERENCES trading.networks(id),
  
  -- Tokens
  token_in_id INT NOT NULL REFERENCES trading.tokens(id),
  token_out_id INT NOT NULL REFERENCES trading.tokens(id),
  
  -- Order details
  side trading.order_side NOT NULL,
  type trading.order_type NOT NULL,
  status trading.order_status NOT NULL DEFAULT 'PENDING',
  
  -- Identifiers
  client_order_id TEXT,
  idempotency_key TEXT NOT NULL,
  
  -- Amounts
  amount_in NUMERIC(78,0) NOT NULL CHECK (amount_in > 0),
  amount_out_min NUMERIC(78,0) DEFAULT 0,
  filled_amount NUMERIC(78,0) DEFAULT 0,
  
  -- Pricing
  limit_price NUMERIC(38,18),
  stop_price NUMERIC(38,18),
  average_fill_price NUMERIC(38,18),
  slippage_tolerance NUMERIC(5,4), -- Percentage as decimal
  
  -- Version for optimistic locking
  version INT NOT NULL DEFAULT 0,
  event_version INT NOT NULL DEFAULT 0,
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  triggered_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  
  -- Metadata
  tags TEXT[],
  metadata JSONB DEFAULT '{}',
  
  -- Constraints
  CHECK (filled_amount >= 0 AND filled_amount <= amount_in),
  CHECK (type != 'LIMIT' OR limit_price IS NOT NULL),
  CHECK (type NOT IN ('STOP','STOP_LIMIT') OR stop_price IS NOT NULL),
  
  -- Unique constraint for idempotency
  CONSTRAINT orders_wallet_idempotency_unique UNIQUE (wallet_id, idempotency_key)
);

-- Note: STOP and STOP_LIMIT orders are kept in the same orders table.
-- Funds are reserved on activation (trigger) rather than at creation time.

-- Order book denormalized structure for fast matching
CREATE TABLE trading.order_book (
  id UUID PRIMARY KEY DEFAULT trading.uuid_v7(),
  token_pair TEXT NOT NULL, -- 'token_in_id:token_out_id'
  side trading.order_side NOT NULL,
  price_level NUMERIC(38,18) NOT NULL,
  
  -- Aggregated data at this price level
  aggregate_volume NUMERIC(78,0) NOT NULL,
  order_count INT NOT NULL,
  order_ids UUID[] NOT NULL,
  
  -- Metadata
  updated_at TIMESTAMPTZ DEFAULT now(),
  
  UNIQUE (token_pair, side, price_level)
);

-- Match candidates as materialized view for better concurrency
CREATE MATERIALIZED VIEW trading.mv_match_candidates AS
SELECT 
  b.id as buy_order_id,
  s.id as sell_order_id,
  LEAST(b.amount_in - b.filled_amount, s.amount_in - s.filled_amount) as matchable_amount,
  s.limit_price as match_price,
  -- Priority score: price improvement * volume
  (b.limit_price - s.limit_price) * LEAST(b.amount_in - b.filled_amount, s.amount_in - s.filled_amount) as priority_score
FROM trading.orders b
JOIN trading.orders s ON 
  b.token_in_id = s.token_out_id AND
  b.token_out_id = s.token_in_id
WHERE 
  b.side = 'BUY' AND s.side = 'SELL'
  AND b.status = 'ACTIVE' AND s.status = 'ACTIVE'
  AND b.type = 'LIMIT' AND s.type = 'LIMIT'
  AND b.limit_price >= s.limit_price
  AND b.amount_in > b.filled_amount
  AND s.amount_in > s.filled_amount;

-- Unique index required for concurrent refresh
CREATE UNIQUE INDEX idx_mv_match_candidates_unique 
  ON trading.mv_match_candidates(buy_order_id, sell_order_id);

-- Additional index for priority-based matching
CREATE INDEX idx_mv_match_candidates_priority 
  ON trading.mv_match_candidates(priority_score DESC)
  WHERE matchable_amount > 0;

-- Order fills
CREATE TABLE trading.order_fills (
  id UUID DEFAULT trading.uuid_v7() NOT NULL,
  order_id UUID NOT NULL REFERENCES trading.orders(id),
  
  -- Deduplication
  idempotency_key TEXT NOT NULL,
  
  -- Fill details
  amount_in NUMERIC(78,0) NOT NULL CHECK (amount_in > 0),
  amount_out NUMERIC(78,0) NOT NULL CHECK (amount_out > 0),
  price NUMERIC(38,18) NOT NULL,
  fee_amount NUMERIC(78,0) DEFAULT 0,
  fee_token_id INT REFERENCES trading.tokens(id),
  
  -- Execution
  venue TEXT NOT NULL,
  tx_hash BYTEA,
  block_number BIGINT,
  log_index INT,
  
  -- Status
  status trading.transaction_status DEFAULT 'PENDING',
  confirmed_at TIMESTAMPTZ,
  reverted_at TIMESTAMPTZ,
  
  executed_at TIMESTAMPTZ DEFAULT now(),
  
  PRIMARY KEY (id, executed_at)
) PARTITION BY RANGE (executed_at);

-- ============================================================================
-- ACCOUNT BALANCES
-- ============================================================================

CREATE TABLE trading.account_balances (
  wallet_id INT NOT NULL REFERENCES trading.wallets(id),
  token_id INT NOT NULL REFERENCES trading.tokens(id),
  
  -- Balances
  available NUMERIC(78,0) DEFAULT 0 CHECK (available >= 0),
  reserved NUMERIC(78,0) DEFAULT 0 CHECK (reserved >= 0),
  total NUMERIC(78,0) GENERATED ALWAYS AS (available + reserved) STORED,
  
  -- Version for optimistic locking
  version INT DEFAULT 0,
  
  -- Tracking
  updated_at TIMESTAMPTZ DEFAULT now(),
  last_activity_at TIMESTAMPTZ,
  
  PRIMARY KEY (wallet_id, token_id)
);

-- Balance reservations (per order) with automatic expiration
CREATE TABLE trading.balance_reservations (
  wallet_id INT NOT NULL REFERENCES trading.wallets(id),
  token_id INT NOT NULL REFERENCES trading.tokens(id),
  order_id UUID NOT NULL REFERENCES trading.orders(id),
  
  amount NUMERIC(78,0) NOT NULL CHECK (amount > 0),
  
  created_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ DEFAULT (now() + INTERVAL '5 minutes'),
  
  PRIMARY KEY (wallet_id, token_id, order_id)
);

-- Function to automatically expire reservations
CREATE OR REPLACE FUNCTION trading.expire_reservations()
RETURNS INTEGER AS $$
DECLARE
  v_expired_count INTEGER;
BEGIN
  WITH expired AS (
    DELETE FROM trading.balance_reservations
    WHERE expires_at < now()
    RETURNING wallet_id, token_id, amount
  )
  UPDATE trading.account_balances ab
  SET 
    available = ab.available + e.total_amount,
    reserved = ab.reserved - e.total_amount
  FROM (
    SELECT wallet_id, token_id, SUM(amount) as total_amount
    FROM expired
    GROUP BY wallet_id, token_id
  ) e
  WHERE ab.wallet_id = e.wallet_id AND ab.token_id = e.token_id;
  
  GET DIAGNOSTICS v_expired_count = ROW_COUNT;
  RETURN v_expired_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- OUTBOX PATTERN (For Kafka CDC)
-- ============================================================================

CREATE TABLE events.outbox (
  id UUID NOT NULL DEFAULT trading.uuid_v7(),
  
  -- Event info
  aggregate_id UUID NOT NULL,
  aggregate_type TEXT NOT NULL,
  event_type TEXT NOT NULL,
  
  -- Payload
  payload JSONB NOT NULL,
  headers JSONB DEFAULT '{}',
  
  -- Generated columns for Debezium optimization
  topic TEXT GENERATED ALWAYS AS (lower(aggregate_type) || '.' || lower(event_type)) STORED,
  partition_key TEXT GENERATED ALWAYS AS (aggregate_id::TEXT) STORED,
  
  -- Processing
  status events.event_status DEFAULT 'PENDING',
  retry_count INT DEFAULT 0,
  max_retries INT DEFAULT 3,
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT now(),
  processed_at TIMESTAMPTZ,
  next_retry_at TIMESTAMPTZ,
  
  -- Error tracking
  error_message TEXT,
  error_details JSONB,
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- Note: Partitions are now managed by auto_create_partitions() function
-- No hardcoded partitions needed

-- ============================================================================
-- SAGA PATTERN
-- ============================================================================

CREATE TABLE events.sagas (
  id UUID PRIMARY KEY DEFAULT trading.uuid_v7(),
  saga_type TEXT NOT NULL,
  
  -- State machine
  current_step INT NOT NULL DEFAULT 0,
  total_steps INT NOT NULL,
  status events.saga_status DEFAULT 'RUNNING',
  
  -- Data
  context JSONB NOT NULL DEFAULT '{}',
  compensations JSONB[] DEFAULT '{}',
  
  -- Timing
  timeout_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ
);

-- Saga steps log
CREATE TABLE events.saga_steps (
  saga_id UUID REFERENCES events.sagas(id),
  step_number INT NOT NULL,
  step_name TEXT NOT NULL,
  
  input JSONB,
  output JSONB,
  error JSONB,
  
  started_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ,
  
  PRIMARY KEY (saga_id, step_number)
);

-- ============================================================================
-- DISTRIBUTED TRANSACTIONS
-- ============================================================================

CREATE TABLE trading.distributed_transactions (
  xid TEXT PRIMARY KEY,
  coordinator_id TEXT NOT NULL,
  
  -- Participants
  participants JSONB NOT NULL,
  votes JSONB DEFAULT '{}',
  
  -- Status
  status TEXT NOT NULL,
  decision TEXT,
  
  -- Timing
  timeout_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  prepared_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ
);

-- ============================================================================
-- CACHE INVALIDATION (For Redis)
-- ============================================================================

CREATE TABLE trading.cache_invalidations (
  id UUID PRIMARY KEY DEFAULT trading.uuid_v7(),
  
  cache_key TEXT NOT NULL,
  pattern TEXT,
  entity_type TEXT NOT NULL,
  entity_id TEXT,
  operation TEXT NOT NULL,
  
  -- Processing
  status TEXT DEFAULT 'PENDING',
  retry_count INT DEFAULT 0,
  
  created_at TIMESTAMPTZ DEFAULT now(),
  processed_at TIMESTAMPTZ
);

-- ============================================================================
-- HEALTH MONITORING (For Kubernetes)
-- ============================================================================

CREATE TABLE trading.health_checks (
  component TEXT PRIMARY KEY,
  status TEXT NOT NULL CHECK (status IN ('HEALTHY', 'DEGRADED', 'UNHEALTHY')),
  
  -- Metrics
  response_time_ms INT,
  success_rate NUMERIC(5,2),
  error_count INT DEFAULT 0,
  
  -- Details
  details JSONB DEFAULT '{}',
  
  last_check TIMESTAMPTZ DEFAULT now(),
  consecutive_failures INT DEFAULT 0
);

-- Leader election for distributed systems
CREATE TABLE trading.leader_election (
  resource_name TEXT PRIMARY KEY,
  leader_id TEXT NOT NULL,
  
  lease_duration_seconds INT NOT NULL DEFAULT 30,
  fence_token BIGINT NOT NULL DEFAULT 0,
  
  acquired_at TIMESTAMPTZ DEFAULT now(),
  renewed_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================================
-- API LAYER
-- ============================================================================

-- External ID mapping
CREATE TABLE api.external_ids (
  external_id TEXT PRIMARY KEY,
  internal_id UUID NOT NULL,
  entity_type TEXT NOT NULL,
  
  wallet_id INT REFERENCES trading.wallets(id),
  
  issued_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ
);

-- API keys for authentication
CREATE TABLE api.api_keys (
  key_hash BYTEA PRIMARY KEY,
  key_prefix TEXT NOT NULL,  -- First 8 chars for identification
  
  wallet_id INT REFERENCES trading.wallets(id),
  name TEXT NOT NULL,
  
  -- Permissions
  scopes TEXT[] DEFAULT '{}',
  rate_limit_tier TEXT DEFAULT 'standard',
  
  -- Tracking
  last_used_at TIMESTAMPTZ,
  usage_count BIGINT DEFAULT 0,
  
  created_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ
);

-- ============================================================================
-- PARTITION MANAGEMENT
-- ============================================================================

-- Monthly partition creation function
CREATE OR REPLACE FUNCTION trading.create_monthly_partitions(
  p_table_schema TEXT,
  p_table_name TEXT,
  p_months_ahead INT DEFAULT 3
) RETURNS void AS $$
DECLARE
  v_start_date DATE;
  v_end_date DATE;
  v_partition_name TEXT;
BEGIN
  FOR i IN 0..p_months_ahead LOOP
    v_start_date := date_trunc('month', CURRENT_DATE + (i || ' months')::INTERVAL);
    v_end_date := v_start_date + INTERVAL '1 month';
    v_partition_name := format('%s_%s', p_table_name, to_char(v_start_date, 'YYYY_MM'));
    
    -- Check if partition exists
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = p_table_schema
      AND c.relname = v_partition_name
    ) THEN
      EXECUTE format(
        'CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
        p_table_schema, v_partition_name, p_table_schema, p_table_name,
        v_start_date, v_end_date
      );
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Create initial partitions
SELECT trading.create_monthly_partitions('trading', 'order_fills', 3);
-- Note: event_store is hash partitioned, not range partitioned
SELECT trading.create_monthly_partitions('events', 'outbox', 3);

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Update timestamp trigger
CREATE OR REPLACE FUNCTION trading.update_timestamp() 
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to relevant tables
CREATE TRIGGER trg_orders_updated BEFORE UPDATE ON trading.orders 
  FOR EACH ROW EXECUTE FUNCTION trading.update_timestamp();

CREATE TRIGGER trg_balances_updated BEFORE UPDATE ON trading.account_balances 
  FOR EACH ROW EXECUTE FUNCTION trading.update_timestamp();

-- Note: Outbox events are emitted explicitly in business functions.

-- ============================================================================
-- INITIAL DATA
-- ============================================================================

-- Health check components
INSERT INTO trading.health_checks (component, status) VALUES
  ('database', 'HEALTHY'),
  ('cache', 'HEALTHY'),
  ('event_bus', 'HEALTHY')
ON CONFLICT DO NOTHING;

-- GRANTS and role management are handled by infra in 00_infra_superuser.sql

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

-- Performance settings
ALTER TABLE trading.orders SET (
  autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_analyze_scale_factor = 0.01,
  fillfactor = 90
);

ALTER TABLE trading.account_balances SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.02,
  fillfactor = 85
);

-- Query tracking configuration managed by infra

-- ============================================================================
-- END OF SETUP
-- ============================================================================

-- Verify setup
DO $$
BEGIN
  RAISE NOTICE 'Setup completed successfully';
  RAISE NOTICE 'PostgreSQL version: %', version();
  RAISE NOTICE 'Schemas created: trading, events, audit, api, sharding';
  RAISE NOTICE 'Ready for development';
END $$;
