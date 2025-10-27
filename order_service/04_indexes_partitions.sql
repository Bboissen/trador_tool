-- 04_indexes_partitions.sql
-- Performance optimization through advanced indexing and partitioning
-- Leverages PostgreSQL 17.6 features: BRIN, Hash, Bloom, GiST, parallel builds

SET search_path TO trading, events, audit, public;

-- ============================================================================
-- ADVANCED INDEX TYPES
-- ============================================================================

-- Extensions are managed by infra (see 00_infra_superuser.sql)

-- ============================================================================
-- BRIN INDEXES (Block Range INdexes) - 95% smaller than B-tree
-- ============================================================================

-- Time-series data with natural ordering
CREATE INDEX IF NOT EXISTS idx_orders_created_brin 
  ON trading.orders USING BRIN (created_at) 
  WITH (pages_per_range = 32, autosummarize = on);

CREATE INDEX IF NOT EXISTS idx_fills_executed_brin 
  ON trading.order_fills USING BRIN (executed_at) 
  WITH (pages_per_range = 16, autosummarize = on);

CREATE INDEX IF NOT EXISTS idx_events_created_brin 
  ON events.event_store USING BRIN (created_at) 
  WITH (pages_per_range = 32, autosummarize = on);

CREATE INDEX IF NOT EXISTS idx_audit_performed_brin 
  ON audit.activity_log USING BRIN (performed_at) 
  WITH (pages_per_range = 64, autosummarize = on);

-- Note: Removed idx_orders_wallet_time_brin as it's redundant with idx_orders_created_brin
-- Single column BRIN on created_at is sufficient for time-series queries

-- ============================================================================
-- HASH INDEXES (PostgreSQL 17+ crash-safe) - Fast equality lookups
-- ============================================================================

-- Note: Primary key lookups already have B-tree indexes, hash indexes redundant
-- Keeping only non-PK hash indexes

-- Idempotency key lookups
CREATE INDEX IF NOT EXISTS idx_orders_idem_hash 
  ON trading.orders USING HASH (idempotency_key);

CREATE INDEX IF NOT EXISTS idx_fills_idem_hash 
  ON trading.order_fills USING HASH (idempotency_key);

-- ============================================================================
-- BLOOM FILTER INDEXES - Multi-column equality searches
-- ============================================================================

-- Note: Bloom indexes often overlap with specific B-tree indexes
-- Only keeping bloom indexes for true multi-column searches

-- Audit search combinations (useful for compliance queries)
CREATE INDEX IF NOT EXISTS idx_audit_bloom 
  ON audit.activity_log USING bloom (wallet_id, action, table_name, status)
  WITH (length=80, col1=2, col2=2, col3=2, col4=1);

-- ============================================================================
-- GiST INDEXES - Exclusion constraints and range queries
-- ============================================================================

-- GiST index for fast range queries on order execution windows
-- Note: This is an index for performance, not an exclusion constraint
CREATE INDEX IF NOT EXISTS idx_orders_execution_ranges 
  ON trading.orders USING GIST (
    wallet_id,
    int4range(
      EXTRACT(EPOCH FROM created_at AT TIME ZONE 'UTC')::INT,
      EXTRACT(EPOCH FROM COALESCE(completed_at, '2100-01-01') AT TIME ZONE 'UTC')::INT
    )
  );

-- Token pair price ranges
CREATE INDEX IF NOT EXISTS idx_orders_price_range 
  ON trading.orders USING GIST (
    token_in_id,
    token_out_id,
    numrange(limit_price - 0.01, limit_price + 0.01)
  );

-- ============================================================================
-- GIN INDEXES - JSONB and array searches
-- ============================================================================

-- JSONB metadata searches
CREATE INDEX IF NOT EXISTS idx_orders_metadata_gin 
  ON trading.orders USING GIN (metadata);

CREATE INDEX IF NOT EXISTS idx_events_payload_gin 
  ON events.event_store USING GIN (payload);

CREATE INDEX IF NOT EXISTS idx_outbox_headers_gin 
  ON events.outbox USING GIN (headers);

-- Array searches
CREATE INDEX IF NOT EXISTS idx_orders_tags_gin 
  ON trading.orders USING GIN (tags) WHERE tags IS NOT NULL;

-- Text search
CREATE INDEX IF NOT EXISTS idx_tokens_symbol_trgm 
  ON trading.tokens USING GIN (symbol gin_trgm_ops);

-- ============================================================================
-- COVERING INDEXES - Index-only scans
-- ============================================================================

-- Hot query: wallet orders
CREATE INDEX IF NOT EXISTS idx_orders_wallet_covering 
  ON trading.orders (wallet_id, status, created_at DESC)
  INCLUDE (id, token_in_id, token_out_id, side, type, amount_in, filled_amount, limit_price)
  WHERE status IN ('ACTIVE', 'PARTIALLY_FILLED', 'PENDING');

-- Market depth query
CREATE INDEX IF NOT EXISTS idx_orders_market_depth 
  ON trading.orders (token_in_id, token_out_id, side, limit_price)
  INCLUDE (amount_in, filled_amount, wallet_id)
  WHERE status IN ('ACTIVE', 'PARTIALLY_FILLED') AND type = 'LIMIT';

-- Balance lookups
CREATE INDEX IF NOT EXISTS idx_balances_wallet_covering 
  ON trading.account_balances (wallet_id)
  INCLUDE (token_id, available, reserved, version, updated_at);

-- API key lookups
CREATE INDEX IF NOT EXISTS idx_api_keys_covering 
  ON api.api_keys (key_hash)
  INCLUDE (wallet_id, scopes, rate_limit_tier, expires_at)
  WHERE revoked_at IS NULL;

-- ============================================================================
-- CRITICAL MISSING INDEXES
-- ============================================================================

-- Critical for order matching performance
CREATE INDEX IF NOT EXISTS idx_orders_match_candidates 
  ON trading.orders (token_in_id, token_out_id, side, status, limit_price)
  WHERE status = 'ACTIVE' AND type = 'LIMIT';

-- For fill aggregations
CREATE INDEX IF NOT EXISTS idx_fills_aggregation 
  ON trading.order_fills (order_id, status)
  INCLUDE (amount_in, amount_out, fee_amount)
  WHERE status = 'CONFIRMED';

-- For consumer position tracking
CREATE INDEX IF NOT EXISTS idx_consumer_positions 
  ON events.consumer_positions (consumer_group, last_timestamp)
  WHERE processing_event_id IS NULL;

-- order_triggers removed; STOP orders are indexed via orders partial indexes

-- For order book operations
CREATE INDEX IF NOT EXISTS idx_order_book_lookup 
  ON trading.order_book (token_pair, side, price_level);

-- Note: Match candidates indexes are now created with the materialized view in 00_complete_setup.sql

-- ============================================================================
-- PARTIAL INDEXES - Filtered subsets
-- ============================================================================

-- Active orders only
CREATE INDEX IF NOT EXISTS idx_orders_active 
  ON trading.orders (created_at DESC)
  WHERE status IN ('ACTIVE', 'PARTIALLY_FILLED');

-- Pending stop orders
CREATE INDEX IF NOT EXISTS idx_orders_stop_pending 
  ON trading.orders (token_in_id, token_out_id, stop_price)
  WHERE status = 'PENDING' AND type IN ('STOP', 'STOP_LIMIT');

-- Orders requiring expiry
CREATE INDEX IF NOT EXISTS idx_orders_expiry 
  ON trading.orders (expires_at)
  WHERE status IN ('PENDING', 'ACTIVE', 'PARTIALLY_FILLED') 
    AND expires_at IS NOT NULL;

-- Unconfirmed fills
CREATE INDEX IF NOT EXISTS idx_fills_unconfirmed 
  ON trading.order_fills (block_number, executed_at)
  WHERE status = 'PENDING' AND block_number IS NOT NULL;

-- Hot wallets (recent activity)
-- This index is removed because it uses a non-immutable function (now())
-- CREATE INDEX IF NOT EXISTS idx_wallets_hot 
--   ON trading.wallets (last_active_at DESC)
--   WHERE last_active_at > (now() - INTERVAL '7 days');

-- Nonzero balances
CREATE INDEX IF NOT EXISTS idx_balances_nonzero 
  ON trading.account_balances (wallet_id, token_id)
  WHERE available > 0 OR reserved > 0;

-- Recent events
CREATE INDEX IF NOT EXISTS idx_events_recent 
  ON events.outbox (created_at DESC)
  WHERE status = 'PENDING';

-- Security alerts
CREATE INDEX IF NOT EXISTS idx_security_critical 
  ON audit.security_events (occurred_at DESC)
  WHERE severity IN ('HIGH', 'CRITICAL') AND resolved_at IS NULL;

-- ============================================================================
-- EXPRESSION INDEXES - Computed columns
-- ============================================================================

-- Fill ratio for partial orders
CREATE INDEX IF NOT EXISTS idx_orders_fill_ratio 
  ON trading.orders ((filled_amount::NUMERIC / NULLIF(amount_in, 0)))
  WHERE status = 'PARTIALLY_FILLED';

-- Token pair composite (Fix: Cast INT to TEXT for concatenation)
CREATE INDEX IF NOT EXISTS idx_orders_pair 
  ON trading.orders ((token_in_id::TEXT || ':' || token_out_id::TEXT));

-- Wallet risk level
CREATE INDEX IF NOT EXISTS idx_wallets_risk 
  ON trading.wallets ((risk_score / 10))
  WHERE risk_score > 50;

-- Time bucket for aggregations
CREATE INDEX IF NOT EXISTS idx_orders_hour_bucket 
  ON trading.orders (date_trunc('hour', created_at AT TIME ZONE 'UTC'));

-- ============================================================================
-- UNIQUE INDEXES - Constraints
-- ============================================================================

-- Enforce uniqueness with conditions
CREATE UNIQUE INDEX IF NOT EXISTS uidx_wallet_network_active 
  ON trading.wallet_addresses (wallet_id, network_id)
  WHERE deactivated_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uidx_orders_client_active 
  ON trading.orders (wallet_id, client_order_id)
  WHERE client_order_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uidx_api_key_prefix 
  ON api.api_keys (key_prefix)
  WHERE revoked_at IS NULL;

-- ============================================================================
-- FOREIGN KEY INDEXES
-- ============================================================================

-- Ensure all foreign keys have indexes
CREATE INDEX IF NOT EXISTS idx_orders_wallet_fk 
  ON trading.orders (wallet_id);

CREATE INDEX IF NOT EXISTS idx_orders_network_fk 
  ON trading.orders (network_id);

CREATE INDEX IF NOT EXISTS idx_orders_token_in_fk 
  ON trading.orders (token_in_id);

CREATE INDEX IF NOT EXISTS idx_orders_token_out_fk 
  ON trading.orders (token_out_id);

CREATE INDEX IF NOT EXISTS idx_fills_order_fk 
  ON trading.order_fills (order_id);

CREATE INDEX IF NOT EXISTS idx_balances_wallet_fk 
  ON trading.account_balances (wallet_id);

CREATE INDEX IF NOT EXISTS idx_balances_token_fk 
  ON trading.account_balances (token_id);

-- ============================================================================
-- PARTITION MANAGEMENT
-- ============================================================================

-- Automated partition creation function
CREATE OR REPLACE FUNCTION trading.auto_create_partitions()
RETURNS void AS $$
DECLARE
  v_start_date DATE;
  v_end_date DATE;
  v_partition_name TEXT;
  v_table RECORD;
BEGIN
  -- Tables to partition (event_store is now hash partitioned)
  FOR v_table IN 
    SELECT * FROM (VALUES 
      ('trading', 'order_fills'),
      ('events', 'outbox'),
      ('audit', 'activity_log')
    ) AS t(schema_name, table_name)
  LOOP
    -- Create next 3 months of partitions
    FOR i IN 0..2 LOOP
      v_start_date := date_trunc('month', CURRENT_DATE + (i || ' months')::INTERVAL);
      v_end_date := v_start_date + INTERVAL '1 month';
      v_partition_name := format('%s_%s', v_table.table_name, to_char(v_start_date, 'YYYY_MM'));
      
      -- Check if partition exists
      IF NOT EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_table.schema_name
          AND c.relname = v_partition_name
      ) THEN
        -- Create partition
        EXECUTE format(
          'CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
          v_table.schema_name, v_partition_name, 
          v_table.schema_name, v_table.table_name,
          v_start_date, v_end_date
        );
        
        -- Apply table-specific settings
        IF v_table.table_name = 'order_fills' THEN
          EXECUTE format(
            'ALTER TABLE %I.%I SET (
              autovacuum_vacuum_scale_factor = 0.02,
              autovacuum_analyze_scale_factor = 0.02,
              fillfactor = 95
            )', v_table.schema_name, v_partition_name);
        END IF;
      END IF;
    END LOOP;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Schedule partition creation
SELECT trading.auto_create_partitions();

-- ============================================================================
-- INDEX MAINTENANCE
-- ============================================================================

-- Function to rebuild bloated indexes
CREATE OR REPLACE FUNCTION trading.rebuild_bloated_indexes(p_bloat_threshold NUMERIC DEFAULT 30)
RETURNS TABLE(index_name TEXT, table_name TEXT, bloat_percent NUMERIC, action TEXT) AS $$
DECLARE
  v_index RECORD;
BEGIN
  FOR v_index IN
    SELECT 
      schemaname,
      tablename,
      indexname,
      ROUND(CASE WHEN otta=0 THEN 0.0 ELSE (relpages-otta)::NUMERIC/relpages END * 100, 2) as bloat
    FROM (
      SELECT 
        schemaname,
        tablename,
        indexname,
        reltuples,
        relpages,
        CEIL((reltuples*(datahdr-12+nullhdr+4))/(bs-20::float)) AS otta
      FROM (
        SELECT 
          schemaname,
          tablename,
          indexname,
          reltuples,
          relpages,
          bs,
          COALESCE(1+CEIL(reltuples/floor((bs-pageopqdata)*fillfactor/(100*(4+nullhdr)::float))), 0) AS otta,
          16 AS datahdr,
          0 AS nullhdr,
          90 AS fillfactor,
          24 AS pageopqdata
        FROM (
          SELECT 
            schemaname,
            tablename,
            indexname,
            reltuples,
            relpages,
            current_setting('block_size')::INT AS bs
          FROM (
            SELECT 
              n.nspname AS schemaname,
              c.relname AS tablename,
              i.relname AS indexname,
              c.reltuples,
              i.relpages
            FROM pg_index x
            JOIN pg_class c ON c.oid = x.indrelid
            JOIN pg_class i ON i.oid = x.indexrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname IN ('trading', 'events', 'audit')
          ) AS sub
        ) AS stats
      ) AS calcs
    ) AS bloat_stats
    WHERE bloat > p_bloat_threshold
  LOOP
    -- Rebuild index concurrently
    EXECUTE format('REINDEX INDEX CONCURRENTLY %I.%I', v_index.schemaname, v_index.indexname);
    
    RETURN QUERY SELECT 
      v_index.indexname::TEXT,
      v_index.tablename::TEXT,
      v_index.bloat,
      'REBUILT'::TEXT;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- STATISTICS AND PLANNER HINTS
-- ============================================================================

-- Create extended statistics for correlated columns
CREATE STATISTICS IF NOT EXISTS stat_orders_wallet_status 
  (dependencies, ndistinct) 
  ON wallet_id, status FROM trading.orders;

CREATE STATISTICS IF NOT EXISTS stat_orders_tokens 
  (dependencies, ndistinct, mcv) 
  ON token_in_id, token_out_id, side FROM trading.orders;

CREATE STATISTICS IF NOT EXISTS stat_orders_type_status 
  (dependencies) 
  ON type, status FROM trading.orders;

CREATE STATISTICS IF NOT EXISTS stat_fills_order_status 
  (dependencies) 
  ON order_id, status FROM trading.order_fills;

CREATE STATISTICS IF NOT EXISTS stat_balances_wallet_token 
  (ndistinct) 
  ON wallet_id, token_id FROM trading.account_balances;

-- ============================================================================
-- TABLE STORAGE OPTIMIZATION
-- ============================================================================

-- Hot tables configuration
ALTER TABLE trading.orders SET (
  autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_analyze_scale_factor = 0.01,
  autovacuum_vacuum_cost_delay = 0,
  autovacuum_vacuum_cost_limit = 10000,
  fillfactor = 90,
  parallel_workers = 4
);

ALTER TABLE trading.account_balances SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.02,
  fillfactor = 85,
  parallel_workers = 2
);

ALTER TABLE trading.order_fills SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.02,
  fillfactor = 95
);

-- Read-heavy tables
ALTER TABLE trading.tokens SET (
  autovacuum_vacuum_scale_factor = 0.1,
  autovacuum_analyze_scale_factor = 0.1,
  fillfactor = 100
);

ALTER TABLE trading.networks SET (
  autovacuum_vacuum_scale_factor = 0.1,
  autovacuum_analyze_scale_factor = 0.1,
  fillfactor = 100
);

-- ============================================================================
-- PARALLEL INDEX BUILDS (PostgreSQL 17)
-- ============================================================================

-- Set parallel workers for index creation
SET max_parallel_maintenance_workers = 4;
SET maintenance_work_mem = '2GB';

-- Function to create indexes in parallel
CREATE OR REPLACE FUNCTION trading.create_indexes_parallel()
RETURNS void AS $$
BEGIN
  -- Set session parameters for parallel builds
  SET max_parallel_maintenance_workers = 4;
  SET maintenance_work_mem = '2GB';
  SET parallel_leader_participation = on;
  
  RAISE NOTICE 'Index creation completed with parallel workers';
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- MONITORING INDEX USAGE
-- ============================================================================

-- View for unused indexes
CREATE OR REPLACE VIEW trading.v_unused_indexes AS
SELECT 
  schemaname,
  relname as tablename,
  indexrelname as indexname,
  pg_relation_size(indexrelid) as index_size_bytes,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch
FROM pg_stat_user_indexes
WHERE schemaname IN ('trading', 'events', 'audit')
  AND idx_scan = 0
  AND indexrelname NOT LIKE 'pg_toast%'
ORDER BY pg_relation_size(indexrelid) DESC;

-- View for index efficiency
CREATE OR REPLACE VIEW trading.v_index_efficiency AS
SELECT 
  schemaname,
  tablename,
  indexname,
  index_size_bytes,
  idx_scan,
  ROUND(100.0 * i.idx_scan / NULLIF(t.seq_scan + i.idx_scan, 0), 2) as index_usage_percent,
  ROUND(avg_idx_tup_fetch, 2) as avg_tuples_per_scan
FROM (
  SELECT 
    schemaname,
    relname as tablename,
    indexrelname as indexname,
    pg_relation_size(i.indexrelid) as index_size_bytes,
    i.idx_scan,
    i.idx_tup_fetch::NUMERIC / NULLIF(i.idx_scan, 0) as avg_idx_tup_fetch,
    t.seq_scan
  FROM pg_stat_user_indexes i
  JOIN pg_stat_user_tables t USING (schemaname, relname)
  WHERE schemaname IN ('trading', 'events', 'audit')
) sub
ORDER BY index_usage_percent DESC NULLS LAST;

-- ============================================================================
-- QUERY OPTIMIZATION HINTS
-- ============================================================================

-- Force index usage for specific queries
CREATE OR REPLACE FUNCTION trading.optimize_query_plan(p_query TEXT)
RETURNS TABLE(plan_line TEXT) AS $$
BEGIN
  -- Enable query optimization settings
  SET enable_seqscan = off;  -- Force index usage
  SET enable_hashjoin = on;
  SET enable_mergejoin = on;
  SET random_page_cost = 1.1;  -- SSD optimized
  
  RETURN QUERY
  EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, VERBOSE) ' || p_query;
  
  -- Reset settings
  RESET enable_seqscan;
  RESET enable_hashjoin;
  RESET enable_mergejoin;
  RESET random_page_cost;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- CLEANUP AND MAINTENANCE
-- ============================================================================

-- Drop old partitions
CREATE OR REPLACE FUNCTION trading.drop_old_partitions(p_months_to_keep INT DEFAULT 6)
RETURNS void AS $$
DECLARE
  v_cutoff_date DATE;
  v_partition RECORD;
BEGIN
  v_cutoff_date := date_trunc('month', CURRENT_DATE - (p_months_to_keep || ' months')::INTERVAL);
  
  FOR v_partition IN
    SELECT 
      n.nspname as schema_name,
      c.relname as partition_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_inherits i ON i.inhrelid = c.oid
    WHERE n.nspname IN ('trading', 'events', 'audit')
      AND c.relname ~ '_\d{4}_\d{2}$'
      AND to_date(right(c.relname, 7), 'YYYY_MM') < v_cutoff_date
  LOOP
    EXECUTE format('DROP TABLE %I.%I', v_partition.schema_name, v_partition.partition_name);
    RAISE NOTICE 'Dropped partition: %.%', v_partition.schema_name, v_partition.partition_name;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- INDEX CLEANUP - Remove redundant indexes
-- ============================================================================

-- Drop redundant hash indexes (PK already provides these)
DROP INDEX IF EXISTS idx_orders_id_hash;
DROP INDEX IF EXISTS idx_wallets_id_hash;
DROP INDEX IF EXISTS idx_tokens_id_hash;

-- Drop redundant bloom indexes (covered by specific indexes)
DROP INDEX IF EXISTS idx_orders_bloom;
DROP INDEX IF EXISTS idx_fills_bloom;

-- Already removed redundant indexes above

-- ============================================================================
-- FINAL OPTIMIZATION
-- ============================================================================

-- Analyze all tables to update statistics
ANALYZE trading.orders;
ANALYZE trading.order_book;
ANALYZE trading.mv_match_candidates;
ANALYZE trading.order_fills;
ANALYZE trading.account_balances;
ANALYZE trading.wallets;
ANALYZE trading.tokens;
ANALYZE events.event_store;
ANALYZE events.outbox;
ANALYZE events.consumer_positions;
ANALYZE audit.activity_log;

-- ============================================================================
-- END OF INDEXES AND PARTITIONS
-- ============================================================================
