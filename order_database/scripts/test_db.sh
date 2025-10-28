#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}${BOLD}[info] Running DB exhaustive sanity tests against service 'db'...${NC}"

# Wait for PostgreSQL to be ready
MAX_ATTEMPTS=10
ATTEMPT=0
until docker compose exec db pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-orders}" > /dev/null 2>&1 || [ $ATTEMPT -eq $MAX_ATTEMPTS ]; do
  echo -e "${YELLOW}[warn] Waiting for DB to be ready... (attempt $((ATTEMPT+1))/$MAX_ATTEMPTS)${NC}"
  sleep 1
  ATTEMPT=$((ATTEMPT+1))
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
  echo -e "${RED}[fail] DB did not become ready after $MAX_ATTEMPTS attempts. Exiting.${NC}"
  exit 1
fi

echo -e "${GREEN}[info] DB is ready. Starting tests.${NC}"

docker compose exec -T db psql \
  -v ON_ERROR_STOP=1 \
  -v CGREEN=$'\033[0;32m' \
  -v CBLUE=$'\033[0;34m' \
  -v CYELLOW=$'\033[1;33m' \
  -v CRED=$'\033[0;31m' \
  -v CBOLD=$'\033[1m' \
  -v CNC=$'\033[0m' \
  -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-orders}" <<'SQL'
\pset pager off
\pset format aligned
\pset tuples_only off
\timing on

\echo :CBLUE '== Pre-clean (truncate) ==' :CNC
SET client_min_messages = warning;
SET search_path = trading, events, public;

-- Pre-clean to make the script re-runnable
TRUNCATE TABLE 
  events.saga_steps,
  events.sagas,
  events.outbox,
  trading.order_fills,
  trading.orders,
  events.snapshots,
  events.consumer_positions,
  events.projections,
  events.event_store
RESTART IDENTITY CASCADE;

\echo :CBLUE '== Ensure wide test partitions ==' :CNC
-- Ensure wide partitions exist for tests (drop if present for idempotency)
DROP TABLE IF EXISTS events.outbox_p0;
CREATE TABLE events.outbox_p0 PARTITION OF events.outbox FOR VALUES FROM ('2000-01-01') TO ('2100-01-01');

DROP TABLE IF EXISTS trading.order_fills_p0;
CREATE TABLE trading.order_fills_p0 PARTITION OF trading.order_fills FOR VALUES FROM ('2000-01-01') TO ('2100-01-01');

\echo :CBLUE '== Seed minimal FK fixtures ==' :CNC
-- Minimal seed for FKs
INSERT INTO trading.networks (name, chain_id, is_testnet)
VALUES ('testnet', 99999, true)
ON CONFLICT (name) DO NOTHING;

\echo :CBLUE '== Insert fully-populated order ==' :CNC
  -- Create a fully populated order using the API function
  -- Test idempotency: call twice with the same idempotency_key
  DO $$
  DECLARE 
    v_network_id INT;
    v_order_id UUID;
  BEGIN
    SELECT id INTO v_network_id FROM trading.networks WHERE name = 'testnet' LIMIT 1;
    
    v_order_id := api.create_order(
        1, v_network_id, v_network_id, 'adapter-1',
        'idem-1', 'asset_in', 'asset_out', 'BUY', 'LIMIT', 'GTC',
        false, true, 1.5000, 'CROSS', 1000000000000000000,
        900000000000000000, 100.123456789012345678, NULL, 0.0100,
        ARRAY['tag-a','tag-b'], '{}'::jsonb, '{}'::jsonb
    );
    
    -- Call again with same idempotency_key - should return same ID, not error
    PERFORM api.create_order(
        1, v_network_id, v_network_id, 'adapter-1',
        'idem-1', 'asset_in', 'asset_out', 'BUY', 'LIMIT', 'GTC',
        false, true, 1.5000, 'CROSS', 1000000000000000000,
        900000000000000000, 100.123456789012345678, NULL, 0.0100,
        ARRAY['tag-a','tag-b'], '{}'::jsonb, '{}'::jsonb
    );
  END$$;
  \echo :CGREEN '[ok] api.create_order called, idempotency verified' :CNC

  -- Verify initial status is PENDING
  DO $$
  DECLARE v_status trading.order_status; BEGIN
    SELECT status INTO v_status FROM trading.orders WHERE idempotency_key = 'idem-1';
    IF v_status != 'PENDING' THEN RAISE EXCEPTION 'Expected order status to be PENDING, got %', v_status; END IF;
  END$$;
  \echo :CGREEN '[ok] initial order status is PENDING' :CNC

-- Constraint: LIMIT requires limit_price
DO $$
BEGIN
  BEGIN
    INSERT INTO trading.orders (strategy_id, source_network_id, dest_network_id, adapter_key, idempotency_key, asset_in_ref, asset_out_ref, side, type, tif, amount_in)
    SELECT 1, id, id, 'adapter-1', 'idem-2', 'a', 'b', 'BUY', 'LIMIT', 'GTC', 10 FROM trading.networks WHERE name='testnet' LIMIT 1;
    RAISE EXCEPTION 'Expected check violation for missing limit_price with LIMIT type';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END$$;
\echo :CGREEN '[ok] LIMIT without limit_price rejected' :CNC

\echo :CBLUE '== Negative: STOP/STOP_LIMIT requires stop_price ==' :CNC
-- Constraint: STOP/STOP_LIMIT requires stop_price
DO $$
BEGIN
  BEGIN
    INSERT INTO trading.orders (strategy_id, source_network_id, dest_network_id, adapter_key, idempotency_key, asset_in_ref, asset_out_ref, side, type, tif, amount_in)
    SELECT 1, id, id, 'adapter-1', 'idem-3', 'a', 'b', 'SELL', 'STOP', 'GTC', 10 FROM trading.networks WHERE name='testnet' LIMIT 1;
    RAISE EXCEPTION 'Expected check violation for missing stop_price with STOP type';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END$$;
\echo :CGREEN '[ok] STOP without stop_price rejected' :CNC

\echo :CBLUE '== Negative: filled_amount cannot exceed amount_in ==' :CNC
-- Constraint: filled_amount <= amount_in
DO $$
BEGIN
  BEGIN
    UPDATE trading.orders SET filled_amount = amount_in + 1 
    WHERE id = (SELECT id FROM trading.orders WHERE idempotency_key = 'idem-1');
    RAISE EXCEPTION 'Expected check violation on filled_amount > amount_in';
  EXCEPTION WHEN check_violation THEN NULL; END;
END$$;
\echo :CGREEN '[ok] filled_amount constraint enforced' :CNC

\echo :CBLUE '== Trigger: updated_at on update ==' :CNC
-- Trigger: updated_at should change on update
UPDATE trading.orders SET filled_amount = 10 
WHERE id = (SELECT id FROM trading.orders WHERE idempotency_key = 'idem-1');
DO $$
DECLARE v_ok boolean; BEGIN
  SELECT (updated_at > created_at) INTO v_ok 
  FROM trading.orders WHERE id = (SELECT id FROM trading.orders WHERE idempotency_key = 'idem-1');
  IF NOT v_ok THEN RAISE EXCEPTION 'updated_at not greater than created_at after update'; END IF;
END$$;
\echo :CGREEN '[ok] updated_at trigger verified' :CNC

  -- Create a second order to fill (MARKET order)
  DO $$
  DECLARE 
    v_network_id INT;
    v_order_id UUID;
    v_status trading.order_status;
  BEGIN
    SELECT id INTO v_network_id FROM trading.networks WHERE name = 'testnet' LIMIT 1;
    v_order_id := api.create_order(
        2, v_network_id, v_network_id, 'adapter-2',
        'idem-market-1', 'asset_in_m', 'asset_out_m', 'SELL', 'MARKET', 'IOC',
        false, false, NULL, NULL, 500000000000000000, -- 0.5e18
        NULL, NULL, NULL, 0.0050,
        ARRAY['market'], '{}'::jsonb, '{}'::jsonb
    );
    -- Verify initial status
    SELECT status INTO v_status FROM trading.orders WHERE id = v_order_id;
    IF v_status != 'PENDING' THEN RAISE EXCEPTION 'Expected MARKET order status to be PENDING, got %', v_status; END IF;
  
    -- Add first fill: order should be PARTIALLY_FILLED
    PERFORM api.add_order_fill(
        v_order_id, 'fill-market-1', 200000000000000000, 190000000000000000, 100.00, 1, 'fee-token', 'adapter-2'
    );
    SELECT status, filled_amount INTO v_status, v_order_filled_amount FROM trading.orders WHERE id = v_order_id;
    IF v_status != 'PARTIALLY_FILLED' THEN RAISE EXCEPTION 'Expected order status PARTIALLY_FILLED, got %', v_status; END IF;
    IF v_order_filled_amount != 200000000000000000 THEN RAISE EXCEPTION 'Expected filled_amount 0.2e18, got %', v_order_filled_amount; END IF;
  
    -- Add second fill (idempotent call, should not change anything)
    PERFORM api.add_order_fill(
        v_order_id, 'fill-market-1', 200000000000000000, 190000000000000000, 100.00, 1, 'fee-token', 'adapter-2'
    );
    SELECT filled_amount INTO v_order_filled_amount FROM trading.orders WHERE id = v_order_id;
    IF v_order_filled_amount != 200000000000000000 THEN RAISE EXCEPTION 'Expected filled_amount 0.2e18 (idempotent), got %', v_order_filled_amount; END IF;
  
    -- Add third fill: order should be FILLED
    PERFORM api.add_order_fill(
        v_order_id, 'fill-market-2', 300000000000000000, 280000000000000000, 101.00, 1.5, 'fee-token', 'adapter-2'
    );
    SELECT status, filled_amount FROM trading.orders WHERE id = v_order_id;
    IF v_status != 'FILLED' THEN RAISE EXCEPTION 'Expected order status FILLED, got %', v_status; END IF;
    IF v_order_filled_amount != 500000000000000000 THEN RAISE EXCEPTION 'Expected filled_amount 0.5e18, got %', v_order_filled_amount; END IF;
  END$$;
  \echo :CGREEN '[ok] api.add_order_fill called, order status and idempotency verified' :CNC
   
  -- events.event_store uniqueness on (aggregate_id, event_version)
  WITH e AS (
    SELECT gen_random_uuid() AS agg
  )
  INSERT INTO events.event_store (aggregate_id, aggregate_type, event_type, event_version, payload)
  SELECT agg, 'order', 'created', 1, '{"x":1}'::jsonb FROM e;
  \echo :CGREEN '[ok] event_store direct insert' :CNC
  DO $$
  DECLARE agg uuid; BEGIN
    SELECT aggregate_id INTO agg FROM events.event_store ORDER BY created_at DESC LIMIT 1;
    BEGIN
      INSERT INTO events.event_store (aggregate_id, aggregate_type, event_type, event_version, payload)
      VALUES (agg, 'order', 'updated', 1, '{}'::jsonb);
      RAISE EXCEPTION 'Expected unique violation on (aggregate_id, event_version)';
    EXCEPTION WHEN unique_violation THEN NULL; END;
  END$$;
  \echo :CGREEN '[ok] event_store unique constraint enforced' :CNC

\echo :CBLUE '== Insert outbox row ==' :CNC
-- events.outbox insert
INSERT INTO events.outbox (aggregate_id, aggregate_type, event_type, payload)
VALUES (gen_random_uuid(), 'order', 'created', '{}'::jsonb);
\echo :CGREEN '[ok] outbox direct insert' :CNC

\echo :CBLUE '== consumer_positions PK uniqueness ==' :CNC
-- events.consumer_positions PK uniqueness
INSERT INTO events.consumer_positions (consumer_group, partition_key, stream_name, checkpoint)
VALUES ('cg-1','p-1','main','{}');
\echo :CGREEN '[ok] consumer_positions direct insert' :CNC

-- Index usage checks via pg_stat_all_indexes
SET enable_seqscan = off;
-- Print plans to visually verify index usage (non-fatal)
\echo
\echo :CYELLOW :CBOLD 'EXPLAIN orders by PK:' :CNC
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM trading.orders WHERE id = (SELECT id FROM trading.orders WHERE idempotency_key = 'idem-1');

\echo
\echo :CYELLOW :CBOLD 'EXPLAIN orders by idempotency_key (unique):' :CNC
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM trading.orders WHERE idempotency_key = 'idem-1';

\echo
\echo :CYELLOW :CBOLD 'EXPLAIN event_store unique constraint:' :CNC
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM events.event_store
WHERE (aggregate_id, event_version) = (
  SELECT aggregate_id, event_version FROM events.event_store LIMIT 1
);

\echo
\echo :CYELLOW :CBOLD 'EXPLAIN outbox partition pkey:' :CNC
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM events.outbox_p0 WHERE (id, created_at) IN (
  SELECT id, created_at FROM events.outbox_p0 ORDER BY created_at DESC LIMIT 1
);

-- Cleanup: truncate data and drop wide test partitions
TRUNCATE TABLE 
  events.saga_steps,
  events.sagas,
  events.outbox,
  trading.order_fills,
  trading.orders CASCADE,
  events.snapshots,
  events.consumer_positions,
  events.projections,
  events.event_store
RESTART IDENTITY CASCADE;

DROP TABLE IF EXISTS trading.order_fills_p0;
DROP TABLE IF EXISTS events.outbox_p0;

-- done
SQL

echo -e "${GREEN}${BOLD}[ok] DB tests completed successfully.${NC}"

