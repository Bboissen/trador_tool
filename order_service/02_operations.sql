-- 02_operations.sql
-- Core business operations using PostgreSQL 17.6 features
-- Includes: MERGE, set-based operations, saga orchestration, financial operations

SET search_path TO trading, events, public;

-- ============================================================================
-- FINANCIAL OPERATIONS WITH MERGE (PostgreSQL 17)
-- ============================================================================

-- Atomic balance update using MERGE
CREATE OR REPLACE FUNCTION trading.update_balance_merge(
  p_wallet_id INT,
  p_token_id INT,
  p_amount NUMERIC,
  p_operation TEXT,
  p_idempotency_key TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_result JSONB;
  v_new_balance NUMERIC;
  v_new_reserved NUMERIC;
  v_old_balance NUMERIC;
  v_old_reserved NUMERIC;
  v_rows_affected INT;
  v_error_message TEXT;
BEGIN
  -- Get the current values before the operation. If row doesn't exist, these will be NULL.
  SELECT available, reserved 
  INTO v_old_balance, v_old_reserved
  FROM trading.account_balances
  WHERE wallet_id = p_wallet_id AND token_id = p_token_id;
  
  -- Use MERGE for upsert with complex logic
  MERGE INTO trading.account_balances AS target
  USING (VALUES (p_wallet_id, p_token_id, p_amount)) AS source(wallet_id, token_id, amount)
  ON target.wallet_id = source.wallet_id AND target.token_id = source.token_id
  WHEN MATCHED AND (
    (p_operation IN ('DEPOSIT', 'RELEASE') AND source.amount != 0) OR -- Only update if amount is not zero for deposit/release
    (p_operation IN ('WITHDRAW', 'RESERVE') AND target.available >= source.amount AND source.amount > 0) OR -- Check available balance and positive amount
    (p_operation = 'CONSUME' AND target.reserved >= source.amount AND source.amount > 0) -- Check reserved balance and positive amount
  ) THEN
    UPDATE SET 
      available = CASE 
        WHEN p_operation IN ('DEPOSIT', 'RELEASE') THEN target.available + source.amount
        WHEN p_operation IN ('WITHDRAW', 'RESERVE') THEN target.available - source.amount
        ELSE target.available
      END,
      reserved = CASE
        WHEN p_operation = 'RESERVE' THEN target.reserved + source.amount
        WHEN p_operation IN ('RELEASE', 'CONSUME') THEN target.reserved - source.amount
        ELSE target.reserved
      END,
      version = target.version + 1,
      updated_at = now(),
      last_activity_at = now()
  WHEN NOT MATCHED AND p_operation = 'DEPOSIT' AND source.amount > 0 THEN -- Only insert new row if it's a positive deposit
    INSERT (wallet_id, token_id, available, reserved, version, last_activity_at)
    VALUES (source.wallet_id, source.token_id, source.amount, 0, 1, now())
  RETURNING available, reserved INTO v_new_balance, v_new_reserved;
  
  GET DIAGNOSTICS v_rows_affected = ROW_COUNT;

  IF v_rows_affected = 0 THEN
    -- No rows were inserted or updated. This implies operation failed or was a no-op.
    v_error_message := CASE
      WHEN p_amount = 0 THEN 'Zero amount operation, no state change'
      WHEN p_operation IN ('WITHDRAW', 'RESERVE', 'CONSUME') AND COALESCE(v_old_balance, 0) < p_amount THEN 'Insufficient available balance'
      WHEN p_operation = 'CONSUME' AND COALESCE(v_old_reserved, 0) < p_amount THEN 'Insufficient reserved balance'
      WHEN p_operation = 'DEPOSIT' AND v_old_balance IS NULL THEN 'Deposit to non-existent account with zero amount'
      ELSE 'Operation failed or no relevant state change occurred'
    END;

    RETURN jsonb_build_object(
      'success', false,
      'error', v_error_message,
      'operation', p_operation,
      'requested_amount', p_amount,
      'current_balance', COALESCE(v_old_balance, 0)::NUMERIC,
      'current_reserved', COALESCE(v_old_reserved, 0)::NUMERIC,
      'new_balance_after_attempt', COALESCE(v_new_balance, v_old_balance, 0)::NUMERIC,
      'new_reserved_after_attempt', COALESCE(v_new_reserved, v_old_reserved, 0)::NUMERIC
    );
  END IF;
  
  -- Log to event store (Fix: Generate proper UUID for wallet aggregate)
  PERFORM events.publish_event(
    trading.uuid_v7(),  -- Generate new event ID instead of invalid cast
    'balances',
    lower(p_operation),
    jsonb_build_object(
      'wallet_id', p_wallet_id,
      'token_id', p_token_id,
      'amount', p_amount,
      'new_balance', v_new_balance,
      'new_reserved', v_new_reserved,
      'idempotency_key', p_idempotency_key
    )
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'balance', v_new_balance,
    'reserved', v_new_reserved,
    'total', v_new_balance + v_new_reserved
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- ORDER OPERATIONS WITH EVENT SOURCING
-- ============================================================================

-- Create order with full validation and proper routing
CREATE OR REPLACE FUNCTION trading.create_order(p_order JSONB)
RETURNS JSONB AS $$
DECLARE
  v_order_id UUID;
  v_canonical_order_id UUID; -- Use this for the final order ID, whether new or existing
  v_wallet_id INT;
  v_amount_in NUMERIC;
  v_token_in_id INT;
  v_order_type trading.order_type;
  v_idempotency_key TEXT;
  v_reservation_result JSONB;
  v_initial_status trading.order_status;
BEGIN
  v_wallet_id := (p_order->>'wallet_id')::INT;
  v_amount_in := (p_order->>'amount_in')::NUMERIC;
  v_token_in_id := (p_order->>'token_in_id')::INT;
  v_order_type := COALESCE((p_order->>'type')::trading.order_type, 'MARKET'); -- Default to MARKET if unspecified
  v_idempotency_key := p_order->>'idempotency_key';
  v_initial_status := COALESCE((p_order->>'status')::trading.order_status, 'PENDING');

  -- Check if order already exists (idempotency)
  SELECT id INTO v_canonical_order_id
  FROM trading.orders
  WHERE wallet_id = v_wallet_id 
    AND idempotency_key = v_idempotency_key;

  -- If order exists, return its details immediately
  IF v_canonical_order_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'order_id', v_canonical_order_id,
      'status', 'EXISTING',
      'message', 'Order already exists with this idempotency key'
    );
  END IF;

  -- If not existing, generate a new ID and proceed with insertion attempt
  v_order_id := trading.uuid_v7();

  -- Check wallet status
  IF NOT EXISTS (
    SELECT 1 FROM trading.wallets 
    WHERE id = v_wallet_id 
      AND deactivated_at IS NULL 
      AND blacklisted_at IS NULL
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Wallet not active or blacklisted'
    );
  END IF;
  
  -- For STOP/STOP_LIMIT orders, do not reserve at creation; status remains PENDING
  IF v_order_type NOT IN ('STOP', 'STOP_LIMIT') THEN
    -- Reserve balance for order
    v_reservation_result := trading.update_balance_merge(
      v_wallet_id, v_token_in_id, v_amount_in, 'RESERVE', NULL
    );
    
    IF NOT (v_reservation_result->>'success')::BOOLEAN THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Insufficient balance for order'
      );
    END IF;
  END IF;
  
  -- Insert into main orders table
  BEGIN
    INSERT INTO trading.orders (
      id, wallet_id, network_id, token_in_id, token_out_id,
      side, type, status, idempotency_key, client_order_id,
      amount_in, amount_out_min, limit_price, stop_price,
      slippage_tolerance, expires_at, metadata, tags
    ) VALUES (
      v_order_id,
      v_wallet_id,
      (p_order->>'network_id')::INT,
      v_token_in_id,
      (p_order->>'token_out_id')::INT,
      (p_order->>'side')::trading.order_side,
      v_order_type,
      v_initial_status,
      p_order->>'idempotency_key',
      p_order->>'client_order_id',
      v_amount_in,
      (p_order->>'amount_out_min')::NUMERIC,
      (p_order->>'limit_price')::NUMERIC,
      (p_order->>'stop_price')::NUMERIC,
      (p_order->>'slippage_tolerance')::NUMERIC,
      (p_order->>'expires_at')::TIMESTAMPTZ,
      p_order->'metadata',
      (p_order->'tags')::TEXT[]
    );
    v_canonical_order_id := v_order_id; -- Successfully inserted, this is the canonical ID
  EXCEPTION
    WHEN unique_violation THEN
      -- Another transaction inserted the order concurrently
      SELECT id INTO v_canonical_order_id
      FROM trading.orders
      WHERE wallet_id = v_wallet_id 
        AND idempotency_key = v_idempotency_key;

      -- If we had made a reservation, release it
      IF v_order_type NOT IN ('STOP', 'STOP_LIMIT') THEN
        PERFORM trading.update_balance_merge(
          v_wallet_id, v_token_in_id, v_amount_in, 'RELEASE', NULL
        );
      END IF;

      RETURN jsonb_build_object(
        'success', true,
        'order_id', v_canonical_order_id,
        'status', 'EXISTING',
        'message', 'Order already exists (race condition handled)'
      );
  END;

  -- Create balance reservation record only for non-STOP orders, and only if a new order was actually created
  IF v_order_type NOT IN ('STOP', 'STOP_LIMIT') AND v_canonical_order_id = v_order_id THEN
    INSERT INTO trading.balance_reservations (wallet_id, token_id, order_id, amount, expires_at)
    VALUES (
      v_wallet_id, 
      v_token_in_id, 
      v_canonical_order_id, 
      v_amount_in,
      CASE 
        WHEN (p_order->>'expires_at') IS NOT NULL THEN (p_order->>'expires_at')::TIMESTAMPTZ
        ELSE NULL  -- NULL means tied to order lifecycle
      END
    ) ON CONFLICT DO NOTHING; -- Add ON CONFLICT DO NOTHING for reservation as well, for robustness
  END IF;
  
  -- Emit order created event
  PERFORM events.publish_event(
    v_canonical_order_id,
    'orders',
    'created',
    p_order || jsonb_build_object('order_id', v_canonical_order_id)
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_canonical_order_id,
    'status', 'PENDING'
  );
  
EXCEPTION
  WHEN OTHERS THEN
    -- Rollback any reservation on general error for non-STOP orders
    IF v_order_type NOT IN ('STOP', 'STOP_LIMIT') THEN
      PERFORM trading.update_balance_merge(
        v_wallet_id, v_token_in_id, v_amount_in, 'RELEASE', NULL
      );
    END IF;
    
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- SET-BASED OPERATIONS (PostgreSQL Strength)
-- ============================================================================

-- Batch activate stop orders from triggers table
CREATE OR REPLACE FUNCTION trading.activate_stop_orders_batch(
  p_market_prices JSONB[]  -- Array of {token_in_id, token_out_id, price}
) RETURNS JSONB AS $$
DECLARE
  v_activated_count INT := 0;
  v_results JSONB := '[]';
  v_row RECORD;
  v_reserve_success INT := 0;
  v_reserve_failed INT := 0;
BEGIN
  -- Build temporary table with market prices
  CREATE TEMP TABLE temp_market_prices (
    token_in_id INT,
    token_out_id INT,
    current_price NUMERIC
  ) ON COMMIT DROP;

  INSERT INTO temp_market_prices
  SELECT 
    (value->>'token_in_id')::INT,
    (value->>'token_out_id')::INT,
    (value->>'price')::NUMERIC
  FROM unnest(p_market_prices) AS value;

  -- Activate STOP/STOP_LIMIT orders in-place when conditions are met
  WITH activated AS (
    UPDATE trading.orders o
    SET 
      status = 'ACTIVE',
      type = CASE 
        WHEN type = 'STOP' THEN 'MARKET'
        WHEN type = 'STOP_LIMIT' THEN 'LIMIT'
        ELSE type
      END,
      triggered_at = now(),
      version = version + 1
    FROM temp_market_prices mp
    WHERE 
      o.token_in_id = mp.token_in_id
      AND o.token_out_id = mp.token_out_id
      AND o.status = 'PENDING'
      AND o.type IN ('STOP', 'STOP_LIMIT')
      AND (
        (o.side = 'BUY' AND o.stop_price >= mp.current_price) OR
        (o.side = 'SELL' AND o.stop_price <= mp.current_price)
      )
    RETURNING o.id, o.wallet_id, o.token_in_id, o.amount_in, o.side, o.stop_price, mp.current_price
  )
  SELECT 
    COUNT(*),
    jsonb_agg(jsonb_build_object(
      'order_id', id,
      'wallet_id', wallet_id,
      'side', side,
      'stop_price', stop_price,
      'trigger_price', current_price
    ))
  INTO v_activated_count, v_results
  FROM activated;

  -- Reserve funds for each activated order and create reservation record
  FOR v_row IN 
    SELECT id, wallet_id, token_in_id, amount_in
    FROM trading.orders
    WHERE id IN (
      SELECT (value->>'order_id')::UUID FROM jsonb_array_elements(COALESCE(v_results, '[]'::jsonb)) AS value
    )
  LOOP
    BEGIN
      IF (trading.update_balance_merge(v_row.wallet_id, v_row.token_in_id, v_row.amount_in, 'RESERVE', NULL)->>'success')::BOOLEAN THEN
        INSERT INTO trading.balance_reservations (wallet_id, token_id, order_id, amount)
        VALUES (v_row.wallet_id, v_row.token_in_id, v_row.id, v_row.amount_in)
        ON CONFLICT DO NOTHING;
        v_reserve_success := v_reserve_success + 1;
      ELSE
        -- Mark order rejected due to insufficient balance
        UPDATE trading.orders SET status = 'REJECTED', version = version + 1
        WHERE id = v_row.id;
        v_reserve_failed := v_reserve_failed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      UPDATE trading.orders SET status = 'FAILED', version = version + 1
      WHERE id = v_row.id;
      v_reserve_failed := v_reserve_failed + 1;
    END;
  END LOOP;

  -- Emit events for activated orders
  INSERT INTO events.outbox (aggregate_id, aggregate_type, event_type, payload)
  SELECT 
    (value->>'order_id')::UUID,
    'Order',
    'STOP_TRIGGERED',
    value
  FROM jsonb_array_elements(v_results) AS value;

  RETURN jsonb_build_object(
    'activated_count', v_activated_count,
    'reserve_success', v_reserve_success,
    'reserve_failed', v_reserve_failed,
    'orders', v_results
  );
END;
$$ LANGUAGE plpgsql;

-- Batch expire orders
CREATE OR REPLACE FUNCTION trading.expire_orders_batch()
RETURNS JSONB AS $$
DECLARE
  v_expired_count INT;
  v_released_amount NUMERIC;
BEGIN
  -- Use MERGE to expire and release in one operation
  WITH expired_orders AS (
    UPDATE trading.orders
    SET 
      status = 'EXPIRED',
      completed_at = now(),
      version = version + 1
    WHERE 
      status IN ('PENDING', 'ACTIVE', 'PARTIALLY_FILLED')
      AND expires_at IS NOT NULL
      AND expires_at < now()
    RETURNING id, wallet_id, token_in_id, amount_in - filled_amount as unreserved_amount
  ),
  released_reservations AS (
    DELETE FROM trading.balance_reservations r
    USING expired_orders e
    WHERE r.order_id = e.id
    RETURNING r.amount
  ),
  balance_updates AS (
    -- Release reserved amounts back to available
    UPDATE trading.account_balances ab
    SET 
      available = ab.available + agg.total_amount,
      reserved = ab.reserved - agg.total_amount,
      version = ab.version + 1
    FROM (
      SELECT 
        e.wallet_id,
        e.token_in_id,
        SUM(e.unreserved_amount) as total_amount
      FROM expired_orders e
      GROUP BY e.wallet_id, e.token_in_id
    ) agg
    WHERE ab.wallet_id = agg.wallet_id 
      AND ab.token_id = agg.token_in_id
    RETURNING ab.available
  )
  SELECT 
    (SELECT COUNT(*) FROM expired_orders),
    (SELECT SUM(amount) FROM released_reservations)
  INTO v_expired_count, v_released_amount;
  
  RETURN jsonb_build_object(
    'expired_count', v_expired_count,
    'released_amount', v_released_amount,
    'timestamp', now()
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- MATCHING ENGINE OPERATIONS
-- ============================================================================

-- Find matching orders for a given order
CREATE OR REPLACE FUNCTION trading.find_matches(p_order_id UUID, p_limit INT DEFAULT 10)
RETURNS TABLE(
  match_order_id UUID,
  match_price NUMERIC,
  available_amount NUMERIC,
  match_score NUMERIC
) AS $$
DECLARE
  v_order RECORD;
BEGIN
  -- Get the order details
  SELECT * INTO v_order
  FROM trading.orders
  WHERE id = p_order_id;
  
  IF NOT FOUND THEN
    RETURN;
  END IF;
  
  -- Find matching orders
  RETURN QUERY
  SELECT 
    o.id as match_order_id,
    o.limit_price as match_price,
    o.amount_in - o.filled_amount as available_amount,
    -- Calculate match score (higher is better)
    CASE 
      WHEN v_order.side = 'BUY' THEN 
        (1.0 / o.limit_price) * (o.amount_in - o.filled_amount)
      ELSE 
        o.limit_price * (o.amount_in - o.filled_amount)
    END as match_score
  FROM trading.orders o
  WHERE 
    -- Opposite side
    o.side != v_order.side
    -- Matching token pairs
    AND o.token_in_id = v_order.token_out_id
    AND o.token_out_id = v_order.token_in_id
    -- Active orders only
    AND o.status IN ('ACTIVE', 'PARTIALLY_FILLED')
    -- Price compatibility
    AND (
      (v_order.side = 'BUY' AND o.limit_price <= v_order.limit_price) OR
      (v_order.side = 'SELL' AND o.limit_price >= v_order.limit_price)
    )
  ORDER BY match_score DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- Execute a match between two orders with advisory locks
CREATE OR REPLACE FUNCTION trading.execute_match(
  p_order_a UUID,
  p_order_b UUID,
  p_amount NUMERIC,
  p_price NUMERIC
) RETURNS JSONB AS $$
DECLARE
  v_order_a RECORD;
  v_order_b RECORD;
  v_fill_id_a UUID;
  v_fill_id_b UUID;
  v_locked_a BOOLEAN;
  v_locked_b BOOLEAN;
  v_amount_a_in NUMERIC; -- Actual amount_in for order A
  v_amount_a_out NUMERIC; -- Actual amount_out for order A
  v_amount_b_in NUMERIC; -- Actual amount_in for order B
  v_amount_b_out NUMERIC; -- Actual amount_out for order B
BEGIN
  -- Acquire advisory locks to prevent race conditions
  v_locked_a := trading.acquire_order_lock(p_order_a);
  v_locked_b := trading.acquire_order_lock(p_order_b);
  
  IF NOT v_locked_a OR NOT v_locked_b THEN
    -- Release any acquired locks
    IF v_locked_a THEN PERFORM trading.release_order_lock(p_order_a); END IF;
    IF v_locked_b THEN PERFORM trading.release_order_lock(p_order_b); END IF;
    
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Could not acquire locks for orders'
    );
  END IF;
  
  -- Lock both orders
  SELECT * INTO v_order_a FROM trading.orders WHERE id = p_order_a FOR UPDATE;
  SELECT * INTO v_order_b FROM trading.orders WHERE id = p_order_b FOR UPDATE;
  
  -- Validate match
  IF v_order_a.side = v_order_b.side THEN
    RETURN jsonb_build_object('success', false, 'error', 'Orders on same side');
  END IF;
  
  IF v_order_a.token_in_id != v_order_b.token_out_id OR 
     v_order_a.token_out_id != v_order_b.token_in_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Token mismatch');
  END IF;
  
  -- Determine actual amounts for each order based on their side
  IF v_order_a.side = 'BUY' THEN
    v_amount_a_in := p_amount * p_price; -- Buyer pays in token_in (quote token)
    v_amount_a_out := p_amount;         -- Buyer receives token_out (base token)

    v_amount_b_in := p_amount;         -- Seller pays in token_in (base token)
    v_amount_b_out := p_amount * p_price; -- Seller receives token_out (quote token)
  ELSE -- v_order_a.side = 'SELL'
    v_amount_a_in := p_amount;         -- Seller pays in token_in (base token)
    v_amount_a_out := p_amount * p_price; -- Seller receives token_out (quote token)

    v_amount_b_in := p_amount * p_price; -- Buyer pays in token_in (quote token)
    v_amount_b_out := p_amount;         -- Buyer receives token_out (base token)
  END IF;

  -- Create fills
  v_fill_id_a := trading.uuid_v7();
  v_fill_id_b := trading.uuid_v7();
  
  INSERT INTO trading.order_fills (
    id, order_id, idempotency_key, amount_in, amount_out, 
    price, venue, status, fee_amount, fee_token_id
  ) VALUES 
    (v_fill_id_a, p_order_a, 'match_' || p_order_a || '_' || p_order_b,
     v_amount_a_in, v_amount_a_out, p_price, 'INTERNAL', 'CONFIRMED', 0, NULL),
    (v_fill_id_b, p_order_b, 'match_' || p_order_b || '_' || p_order_a,
     v_amount_b_in, v_amount_b_out, p_price, 'INTERNAL', 'CONFIRMED', 0, NULL);
  
  -- Update order filled amounts
  UPDATE trading.orders
  SET 
    filled_amount = filled_amount + CASE WHEN id = p_order_a THEN v_amount_a_in ELSE v_amount_b_in END,
    status = CASE 
      WHEN filled_amount + CASE WHEN id = p_order_a THEN v_amount_a_in ELSE v_amount_b_in END >= amount_in THEN 'FILLED'
      ELSE 'PARTIALLY_FILLED'
    END,
    average_fill_price = (
      (COALESCE(average_fill_price, 0) * filled_amount + p_price * p_amount) / 
      (filled_amount + p_amount)
    ),
    version = version + 1
  WHERE id IN (p_order_a, p_order_b);
  
  -- Update balances with proper accounting
  -- Order A: Token Out (received), Token In (consumed from reserved)
  PERFORM trading.update_balance_merge(
    v_order_a.wallet_id, v_order_a.token_out_id, v_amount_a_out, 'DEPOSIT'
  );
  PERFORM trading.update_balance_merge(
    v_order_a.wallet_id, v_order_a.token_in_id, v_amount_a_in, 'CONSUME'
  );
  
  -- Order B: Token Out (received), Token In (consumed from reserved)
  PERFORM trading.update_balance_merge(
    v_order_b.wallet_id, v_order_b.token_out_id, v_amount_b_out, 'DEPOSIT'
  );
  PERFORM trading.update_balance_merge(
    v_order_b.wallet_id, v_order_b.token_in_id, v_amount_b_in, 'CONSUME'
  );
  
  -- Update reservation records
  -- For order A, reduce reservation by v_amount_a_in (since that was the reserved token)
  UPDATE trading.balance_reservations
  SET amount = amount - v_amount_a_in
  WHERE order_id = p_order_a;

  -- For order B, reduce reservation by v_amount_b_in (since that was the reserved token)
  UPDATE trading.balance_reservations
  SET amount = amount - v_amount_b_in
  WHERE order_id = p_order_b;
  
  -- Clean up zero reservations
  DELETE FROM trading.balance_reservations
  WHERE amount <= 0;
  
  -- Emit match event
  PERFORM events.publish_event(
    p_order_a,
    'matches',
    'executed',
    jsonb_build_object(
      'order_a', p_order_a,
      'order_b', p_order_b,
      'amount', p_amount,
      'price', p_price,
      'fill_a', v_fill_id_a,
      'fill_b', v_fill_id_b
    )
  );
  
  -- Release advisory locks
  PERFORM trading.release_order_lock(p_order_a);
  PERFORM trading.release_order_lock(p_order_b);
  
  RETURN jsonb_build_object(
    'success', true,
    'fill_a', v_fill_id_a,
    'fill_b', v_fill_id_b,
    'amount', p_amount,
    'price', p_price
  );
  
EXCEPTION
  WHEN OTHERS THEN
    -- Always release locks on error
    PERFORM trading.release_order_lock(p_order_a);
    PERFORM trading.release_order_lock(p_order_b);
    RAISE;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- SAGA ORCHESTRATION
-- ============================================================================

-- Create a new saga
CREATE OR REPLACE FUNCTION events.create_saga(
  p_saga_type TEXT,
  p_context JSONB,
  p_steps TEXT[]
) RETURNS UUID AS $$
DECLARE
  v_saga_id UUID;
BEGIN
  v_saga_id := trading.uuid_v7();
  
  INSERT INTO events.sagas (
    id, saga_type, total_steps, context, status
  ) VALUES (
    v_saga_id, p_saga_type, array_length(p_steps, 1), p_context, 'RUNNING'
  );
  
  -- Initialize saga steps
  INSERT INTO events.saga_steps (saga_id, step_number, step_name)
  SELECT v_saga_id, ordinality, step_name
  FROM unnest(p_steps) WITH ORDINALITY AS step_name;
  
  RETURN v_saga_id;
END;
$$ LANGUAGE plpgsql;

-- Execute next saga step
CREATE OR REPLACE FUNCTION events.execute_saga_step(
  p_saga_id UUID,
  p_step_input JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_saga RECORD;
  v_step RECORD;
  v_result JSONB;
BEGIN
  -- Lock saga for update
  SELECT * INTO v_saga
  FROM events.sagas
  WHERE id = p_saga_id
  FOR UPDATE;
  
  IF NOT FOUND OR v_saga.status != 'RUNNING' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Saga not found or not running'
    );
  END IF;
  
  -- Get next step
  SELECT * INTO v_step
  FROM events.saga_steps
  WHERE saga_id = p_saga_id
    AND step_number = v_saga.current_step + 1;
  
  IF NOT FOUND THEN
    -- Saga completed
    UPDATE events.sagas
    SET status = 'COMPLETED', completed_at = now()
    WHERE id = p_saga_id;
    
    RETURN jsonb_build_object(
      'success', true,
      'status', 'COMPLETED'
    );
  END IF;
  
  -- Record step start
  UPDATE events.saga_steps
  SET 
    input = p_step_input,
    started_at = now()
  WHERE saga_id = p_saga_id
    AND step_number = v_step.step_number;
  
  -- Execute step based on type
  CASE v_step.step_name
    WHEN 'reserve_balance' THEN
      v_result := trading.update_balance_merge(
        (v_saga.context->>'wallet_id')::INT,
        (v_saga.context->>'token_id')::INT,
        (v_saga.context->>'amount')::NUMERIC,
        'RESERVE'
      );
      
    WHEN 'create_order' THEN
      v_result := trading.create_order(v_saga.context);
      
    WHEN 'execute_trade' THEN
      -- Custom trade execution logic
      v_result := jsonb_build_object('success', true);
      
    ELSE
      v_result := jsonb_build_object(
        'success', false,
        'error', 'Unknown step type'
      );
  END CASE;
  
  -- Record step result
  UPDATE events.saga_steps
  SET 
    output = v_result,
    completed_at = now()
  WHERE saga_id = p_saga_id
    AND step_number = v_step.step_number;
  
  -- Update saga progress
  IF (v_result->>'success')::BOOLEAN THEN
    UPDATE events.sagas
    SET 
      current_step = current_step + 1,
      context = context || v_result
    WHERE id = p_saga_id;
  ELSE
    -- Start compensation
    UPDATE events.sagas
    SET status = 'COMPENSATING'
    WHERE id = p_saga_id;
    
    -- Execute compensations
    PERFORM events.compensate_saga(p_saga_id);
  END IF;
  
  RETURN v_result;
END;
$$ LANGUAGE plpgsql;

-- Compensate saga (rollback)
CREATE OR REPLACE FUNCTION events.compensate_saga(p_saga_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_saga RECORD;
  v_compensation JSONB;
  v_step RECORD;
BEGIN
  SELECT * INTO v_saga
  FROM events.sagas
  WHERE id = p_saga_id;
  
  -- Execute compensations in reverse order
  FOR v_step IN 
    SELECT * FROM events.saga_steps
    WHERE saga_id = p_saga_id
      AND completed_at IS NOT NULL
    ORDER BY step_number DESC
  LOOP
    -- Execute compensation based on step type
    CASE v_step.step_name
      WHEN 'reserve_balance' THEN
        -- Release reservation
        PERFORM trading.update_balance_merge(
          (v_saga.context->>'wallet_id')::INT,
          (v_saga.context->>'token_id')::INT,
          (v_saga.context->>'amount')::NUMERIC,
          'RELEASE'
        );
        
      WHEN 'create_order' THEN
        -- Cancel order
        UPDATE trading.orders
        SET status = 'CANCELED'
        WHERE id = (v_step.output->>'order_id')::UUID;
        
      ELSE
        -- Custom compensation logic
        NULL;
    END CASE;
  END LOOP;
  
  -- Mark saga as failed
  UPDATE events.sagas
  SET status = 'FAILED', completed_at = now()
  WHERE id = p_saga_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'saga_id', p_saga_id,
    'status', 'COMPENSATED'
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- ANALYTICAL OPERATIONS
-- ============================================================================

-- Calculate market depth (uses materialized view for performance)
CREATE OR REPLACE FUNCTION trading.get_market_depth(
  p_token_in INT,
  p_token_out INT,
  p_levels INT DEFAULT 10
) RETURNS JSONB AS $$
DECLARE
  v_bids JSONB;
  v_asks JSONB;
  v_best_bid NUMERIC;
  v_best_ask NUMERIC;
  v_spread NUMERIC;
BEGIN
  -- Get buy orders (bids) from materialized view
  SELECT jsonb_agg(row_to_json(t) ORDER BY price DESC)
  INTO v_bids
  FROM (
    SELECT 
      price,
      volume,
      order_count
    FROM trading.mv_market_depth
    WHERE token_in_id = p_token_in
      AND token_out_id = p_token_out
      AND side = 'BUY'
    ORDER BY price DESC
    LIMIT p_levels
  ) t;
  
  -- Get sell orders (asks) from materialized view
  SELECT jsonb_agg(row_to_json(t) ORDER BY price)
  INTO v_asks
  FROM (
    SELECT 
      price,
      volume,
      order_count
    FROM trading.mv_market_depth
    WHERE token_in_id = p_token_out
      AND token_out_id = p_token_in
      AND side = 'SELL'
    ORDER BY price
    LIMIT p_levels
  ) t;
  
  -- Get best bid price
  SELECT MAX(price)
  INTO v_best_bid
  FROM trading.mv_market_depth
  WHERE token_in_id = p_token_in
    AND token_out_id = p_token_out
    AND side = 'BUY';
  
  -- Get best ask price
  SELECT MIN(price)
  INTO v_best_ask
  FROM trading.mv_market_depth
  WHERE token_in_id = p_token_out
    AND token_out_id = p_token_in
    AND side = 'SELL';
  
  -- Calculate spread (ask - bid, no cross-join needed)
  v_spread := CASE 
    WHEN v_best_ask IS NOT NULL AND v_best_bid IS NOT NULL 
    THEN v_best_ask - v_best_bid
    ELSE NULL
  END;
  
  RETURN jsonb_build_object(
    'token_in', p_token_in,
    'token_out', p_token_out,
    'bids', COALESCE(v_bids, '[]'),
    'asks', COALESCE(v_asks, '[]'),
    'spread', v_spread,
    'best_bid', v_best_bid,
    'best_ask', v_best_ask,
    'timestamp', now()
  );
END;
$$ LANGUAGE plpgsql;

-- Calculate wallet portfolio value
CREATE OR REPLACE FUNCTION trading.get_portfolio_value(
  p_wallet_id INT,
  p_base_token_id INT DEFAULT 1  -- Usually USDT or similar
) RETURNS JSONB AS $$
DECLARE
  v_positions JSONB;
  v_total_value NUMERIC := 0;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
    'token_id', token_id,
    'symbol', t.symbol,
    'balance', ab.total,
    'available', ab.available,
    'reserved', ab.reserved,
    'value', ab.total * COALESCE(
      -- Get latest price from fills
      (SELECT price FROM trading.order_fills f
       JOIN trading.orders o ON f.order_id = o.id
       WHERE o.token_in_id = ab.token_id
         AND o.token_out_id = p_base_token_id
       ORDER BY f.executed_at DESC
       LIMIT 1), 1)
  ))
  INTO v_positions
  FROM trading.account_balances ab
  JOIN trading.tokens t ON ab.token_id = t.id
  WHERE ab.wallet_id = p_wallet_id
    AND ab.total > 0;
  
  -- Ensure positions is an empty array, not NULL, for empty wallets
  v_positions := COALESCE(v_positions, '[]'::jsonb);
  
  SELECT SUM((value->>'value')::NUMERIC)
  INTO v_total_value
  FROM jsonb_array_elements(COALESCE(v_positions, '[]'::jsonb)) AS value;
  
  -- Ensure total_value is 0 when there are no positions
  v_total_value := COALESCE(v_total_value, 0);
  
  RETURN jsonb_build_object(
    'wallet_id', p_wallet_id,
    'positions', v_positions,
    'total_value', v_total_value,
    'base_token_id', p_base_token_id,
    'timestamp', now()
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- WINDOW FUNCTIONS FOR ANALYTICS
-- ============================================================================

-- Calculate wallet P&L with window functions
CREATE OR REPLACE FUNCTION trading.get_wallet_pnl(
  p_wallet_id INT,
  p_start_date TIMESTAMPTZ DEFAULT now() - INTERVAL '30 days',
  p_end_date TIMESTAMPTZ DEFAULT now()
) RETURNS TABLE (
  "timestamp" TIMESTAMPTZ,
  order_id UUID,
  side trading.order_side,
  amount_in NUMERIC,
  amount_out NUMERIC,
  pnl NUMERIC,
  running_pnl NUMERIC,
  daily_pnl NUMERIC,
  daily_volume NUMERIC
) AS $$
BEGIN
  RETURN QUERY
  WITH fills_pnl AS (
    SELECT 
      f.executed_at as timestamp,
      f.order_id,
      o.side,
      f.amount_in,
      f.amount_out,
      CASE 
        WHEN o.side = 'BUY' THEN f.amount_out - f.amount_in
        ELSE f.amount_in - f.amount_out
      END as pnl
    FROM trading.order_fills f
    JOIN trading.orders o ON f.order_id = o.id
    WHERE o.wallet_id = p_wallet_id
      AND f.status = 'CONFIRMED'
      AND f.executed_at BETWEEN p_start_date AND p_end_date
  )
  SELECT 
    timestamp,
    order_id,
    side,
    amount_in,
    amount_out,
    pnl,
    SUM(pnl) OVER (ORDER BY timestamp) as running_pnl,
    SUM(pnl) OVER (PARTITION BY date_trunc('day', timestamp)) as daily_pnl,
    SUM(amount_in) OVER (PARTITION BY date_trunc('day', timestamp)) as daily_volume
  FROM fills_pnl
  ORDER BY timestamp DESC;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- BATCH PROCESSING OPERATIONS
-- ============================================================================

-- Process pending fills from blockchain with SKIP LOCKED
CREATE OR REPLACE FUNCTION trading.process_blockchain_fills(
  p_fills JSONB[]
) RETURNS JSONB AS $$
DECLARE
  v_processed INT := 0;
  v_failed INT := 0;
  v_skipped INT := 0;
  v_fill JSONB;
  v_locked BOOLEAN;
BEGIN
  FOREACH v_fill IN ARRAY p_fills
  LOOP
    BEGIN
      -- First, try to select and lock the fill
      PERFORM 1 
      FROM trading.order_fills
      WHERE id = (v_fill->>'fill_id')::UUID
        AND status = 'PENDING'
      FOR UPDATE SKIP LOCKED;
      
      IF FOUND THEN
        -- Now update the locked row
        UPDATE trading.order_fills
        SET 
          status = (v_fill->>'status')::trading.transaction_status,
          block_number = (v_fill->>'block_number')::BIGINT,
          tx_hash = decode(v_fill->>'tx_hash', 'hex'),
          confirmed_at = CASE 
            WHEN (v_fill->>'status') = 'CONFIRMED' THEN now()
            ELSE confirmed_at
          END,
          reverted_at = CASE
            WHEN (v_fill->>'status') = 'REVERTED' THEN now()
            ELSE reverted_at
          END
        WHERE id = (v_fill->>'fill_id')::UUID;
        
        v_processed := v_processed + 1;
      ELSE
        v_skipped := v_skipped + 1;
      END IF;
      
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      
      -- Log error
      INSERT INTO events.outbox (
        aggregate_id, aggregate_type, event_type, payload, status
      ) VALUES (
        (v_fill->>'fill_id')::UUID,
        'Fill',
        'PROCESSING_FAILED',
        v_fill || jsonb_build_object('error', SQLERRM),
        'FAILED'
      );
    END;
  END LOOP;
  
  RETURN jsonb_build_object(
    'processed', v_processed,
    'failed', v_failed,
    'skipped', v_skipped,
    'total', array_length(p_fills, 1)
  );
END;
$$ LANGUAGE plpgsql;

-- Refresh match candidates materialized view
CREATE OR REPLACE FUNCTION trading.refresh_match_candidates()
RETURNS void AS $$
BEGIN
  -- Use CONCURRENTLY to avoid locking reads
  REFRESH MATERIALIZED VIEW CONCURRENTLY trading.mv_match_candidates;
END;
$$ LANGUAGE plpgsql;

-- Alternative: Get match candidates directly from materialized view
CREATE OR REPLACE FUNCTION trading.get_match_candidates(
  p_order_id UUID DEFAULT NULL,
  p_limit INT DEFAULT 100
)
RETURNS TABLE(
  buy_order_id UUID,
  sell_order_id UUID,
  matchable_amount NUMERIC,
  match_price NUMERIC,
  priority_score NUMERIC
) AS $$
BEGIN
  RETURN QUERY
  SELECT mc.*
  FROM trading.mv_match_candidates mc
  WHERE (p_order_id IS NULL OR 
         mc.buy_order_id = p_order_id OR 
         mc.sell_order_id = p_order_id)
    AND mc.matchable_amount > 0
  ORDER BY mc.priority_score DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- END OF OPERATIONS
-- ============================================================================
