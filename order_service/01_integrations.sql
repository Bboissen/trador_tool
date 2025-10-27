-- 01_integrations.sql
-- Integration layer for Redis 8.2, Kafka 4.1, and Kubernetes
-- Includes: cache invalidation, event streaming, health checks, distributed systems

SET search_path TO trading, events, public;

-- ============================================================================
-- REDIS CACHE INVALIDATION
-- ============================================================================

-- Structured NOTIFY for Rust async integration
CREATE OR REPLACE FUNCTION events.notify_structured() 
RETURNS TRIGGER AS $$
DECLARE
  v_channel TEXT;
  v_payload JSONB;
  v_id TEXT;
  v_keys JSONB := '{}'::JSONB;
BEGIN
  -- Compact payload to avoid 8KB NOTIFY limit
  v_channel := format('evt_%s_%s', lower(TG_TABLE_NAME), lower(TG_OP));
  v_id := COALESCE(NEW.id::TEXT, OLD.id::TEXT);

  -- Build minimal keys by table
  IF v_id IS NOT NULL THEN
    v_keys := jsonb_build_object('id', v_id);
  ELSIF TG_TABLE_SCHEMA = 'trading' AND TG_TABLE_NAME = 'account_balances' THEN
    v_keys := jsonb_build_object(
      'wallet_id', COALESCE(NEW.wallet_id, OLD.wallet_id),
      'token_id', COALESCE(NEW.token_id, OLD.token_id)
    );
  ELSIF TG_TABLE_SCHEMA = 'trading' AND TG_TABLE_NAME = 'balance_reservations' THEN
    v_keys := jsonb_build_object(
      'wallet_id', COALESCE(NEW.wallet_id, OLD.wallet_id),
      'token_id', COALESCE(NEW.token_id, OLD.token_id),
      'order_id', COALESCE(NEW.order_id, OLD.order_id)
    );
  ELSIF TG_TABLE_SCHEMA = 'trading' AND TG_TABLE_NAME = 'health_checks' THEN
    v_keys := jsonb_build_object('component', COALESCE(NEW.component, OLD.component));
  ELSIF TG_TABLE_SCHEMA = 'trading' AND TG_TABLE_NAME = 'leader_election' THEN
    v_keys := jsonb_build_object('resource_name', COALESCE(NEW.resource_name, OLD.resource_name));
  ELSIF TG_TABLE_SCHEMA = 'events' AND TG_TABLE_NAME = 'consumer_positions' THEN
    v_keys := jsonb_build_object(
      'consumer_group', COALESCE(NEW.consumer_group, OLD.consumer_group),
      'partition_key', COALESCE(NEW.partition_key, OLD.partition_key),
      'stream_name', COALESCE(NEW.stream_name, OLD.stream_name)
    );
  END IF;

  v_payload := jsonb_build_object(
    'op', TG_OP,
    'table', TG_TABLE_NAME,
    'schema', TG_TABLE_SCHEMA,
    'ts', extract(epoch from now())::BIGINT,
    'keys', v_keys
  );
  
  PERFORM pg_notify(v_channel, v_payload::TEXT);
  
  -- Also send to a general channel for monitoring
  PERFORM pg_notify('db_events', v_payload::TEXT);
  
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Advanced cache invalidation with patterns
CREATE OR REPLACE FUNCTION trading.notify_cache_invalidation() 
RETURNS TRIGGER AS $$
DECLARE
  v_cache_keys TEXT[];
  v_entity_type TEXT;
  v_entity_id TEXT;
  v_operation TEXT;
BEGIN
  v_entity_type := TG_TABLE_NAME;
  v_operation := TG_OP;
  v_entity_id := COALESCE(NEW.id, OLD.id)::TEXT;
  
  -- Build cache key patterns based on entity type
  CASE v_entity_type
    WHEN 'orders' THEN
      v_cache_keys := ARRAY[
        format('order:%s', v_entity_id),
        format('wallet:%s:orders', COALESCE(NEW.wallet_id, OLD.wallet_id)),
        format('market:%s:%s:*', COALESCE(NEW.token_in_id, OLD.token_in_id), 
                                  COALESCE(NEW.token_out_id, OLD.token_out_id))
      ];
      
    WHEN 'account_balances' THEN
      v_cache_keys := ARRAY[
        format('balance:%s:%s', COALESCE(NEW.wallet_id, OLD.wallet_id), 
                                COALESCE(NEW.token_id, OLD.token_id)),
        format('wallet:%s:balances', COALESCE(NEW.wallet_id, OLD.wallet_id)),
        format('wallet:%s:portfolio', COALESCE(NEW.wallet_id, OLD.wallet_id))
      ];
      
    WHEN 'order_fills' THEN
      v_cache_keys := ARRAY[
        format('order:%s:fills', COALESCE(NEW.order_id, OLD.order_id)),
        format('fills:recent:*')
      ];
      
    ELSE
      v_cache_keys := ARRAY[format('%s:%s', v_entity_type, v_entity_id)];
  END CASE;
  
  -- Insert invalidation records
  INSERT INTO trading.cache_invalidations (cache_key, entity_type, entity_id, operation)
  SELECT unnest(v_cache_keys), v_entity_type, v_entity_id, v_operation;
  
  -- Send async notification for immediate processing
  PERFORM pg_notify('cache_invalidation', json_build_object(
    'keys', v_cache_keys,
    'entity_type', v_entity_type,
    'entity_id', v_entity_id,
    'operation', v_operation
  )::TEXT);
  
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Apply cache invalidation triggers
CREATE TRIGGER trg_orders_cache 
  AFTER INSERT OR UPDATE OR DELETE ON trading.orders
  FOR EACH ROW EXECUTE FUNCTION trading.notify_cache_invalidation();

CREATE TRIGGER trg_balances_cache 
  AFTER INSERT OR UPDATE OR DELETE ON trading.account_balances
  FOR EACH ROW EXECUTE FUNCTION trading.notify_cache_invalidation();

CREATE TRIGGER trg_fills_cache 
  AFTER INSERT OR UPDATE OR DELETE ON trading.order_fills
  FOR EACH ROW EXECUTE FUNCTION trading.notify_cache_invalidation();

-- Batch cache invalidation processing with SKIP LOCKED
CREATE OR REPLACE FUNCTION trading.process_cache_invalidations_batch(p_batch_size INT DEFAULT 100)
RETURNS TABLE(processed_count INT, failed_count INT, keys TEXT[]) AS $$
DECLARE
  v_processed INT := 0;
  v_failed INT := 0;
  v_keys TEXT[];
BEGIN
  WITH batch AS (
    SELECT id, cache_key
    FROM trading.cache_invalidations
    WHERE status = 'PENDING'
      AND retry_count < 3
    ORDER BY created_at
    LIMIT p_batch_size
    FOR UPDATE SKIP LOCKED  -- Critical for concurrent processing
  ),
  updated AS (
    UPDATE trading.cache_invalidations ci
    SET 
      status = 'PROCESSED',
      processed_at = now()
    FROM batch
    WHERE ci.id = batch.id
    RETURNING ci.cache_key
  )
  SELECT array_agg(cache_key) INTO v_keys FROM updated;
  
  -- Fix: Use array length instead of ROW_COUNT which would be 1 from SELECT
  v_processed := COALESCE(cardinality(v_keys), 0);
  
  -- Mark failed items for retry with exponential backoff
  UPDATE trading.cache_invalidations
  SET 
    retry_count = retry_count + 1,
    status = CASE 
      WHEN retry_count >= 2 THEN 'FAILED'
      ELSE 'PENDING'
    END
  WHERE status = 'PENDING'
    AND created_at < now() - (INTERVAL '1 minute' * power(2, retry_count));
  
  GET DIAGNOSTICS v_failed = ROW_COUNT;
  
  RETURN QUERY SELECT v_processed, v_failed, v_keys;
END;
$$ LANGUAGE plpgsql;

-- Function to process cache invalidations (legacy compatibility)
CREATE OR REPLACE FUNCTION trading.process_cache_invalidations(p_batch_size INT DEFAULT 100)
RETURNS TABLE(processed_count INT, failed_count INT) AS $$
BEGIN
  RETURN QUERY 
  SELECT processed_count, failed_count 
  FROM trading.process_cache_invalidations_batch(p_batch_size);
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- KAFKA EVENT STREAMING (CDC)
-- ============================================================================

-- Enhanced outbox processing
CREATE OR REPLACE FUNCTION events.publish_event(
  p_aggregate_id UUID,
  p_aggregate_type TEXT,
  p_event_type TEXT,
  p_payload JSONB,
  p_partition_key TEXT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_event_id UUID;
  v_headers JSONB;
BEGIN
  v_event_id := trading.uuid_v7();
  
  -- Build event headers
  v_headers := jsonb_build_object(
    'event_id', v_event_id,
    'timestamp', extract(epoch from now()),
    'source', current_database(),
    'user', current_user,
    'partition_key', COALESCE(p_partition_key, p_aggregate_id::TEXT)
  );
  
  INSERT INTO events.outbox (
    id, aggregate_id, aggregate_type, event_type, 
    payload, headers, status
  ) VALUES (
    v_event_id, p_aggregate_id, p_aggregate_type, p_event_type,
    p_payload, v_headers, 'PENDING'
  );
  
  -- Notify Kafka producer
  PERFORM pg_notify('kafka_event', json_build_object(
    'event_id', v_event_id,
    'topic', lower(p_aggregate_type || '.' || p_event_type),
    'partition_key', COALESCE(p_partition_key, p_aggregate_id::TEXT)
  )::TEXT);
  
  RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

-- Process outbox events optimized for Debezium/Kafka
CREATE OR REPLACE FUNCTION events.process_outbox(p_batch_size INT DEFAULT 100)
RETURNS TABLE(
  event_id UUID,
  topic TEXT,
  partition_key TEXT,
  payload JSONB
) AS $$
BEGIN
  RETURN QUERY
  WITH batch AS (
    SELECT 
      o.id,
      o.topic,  -- Now using generated column
      o.partition_key,  -- Now using generated column
      jsonb_build_object(
        'aggregate_id', o.aggregate_id,
        'aggregate_type', o.aggregate_type,
        'event_type', o.event_type,
        'payload', o.payload,
        'metadata', o.headers,
        'timestamp', extract(epoch from o.created_at)::BIGINT
      ) as event_payload
    FROM events.outbox o
    WHERE o.status = 'PENDING'
      AND (o.next_retry_at IS NULL OR o.next_retry_at <= now())
    ORDER BY o.created_at
    LIMIT p_batch_size
    FOR UPDATE SKIP LOCKED
  )
  UPDATE events.outbox o
  SET 
    status = 'PROCESSING',
    processed_at = now()
  FROM batch
  WHERE o.id = batch.id
  RETURNING batch.id, batch.topic, batch.partition_key, batch.event_payload;
END;
$$ LANGUAGE plpgsql;

-- Update consumer position for exactly-once semantics
CREATE OR REPLACE FUNCTION events.update_consumer_position(
  p_consumer_group TEXT,
  p_partition_key TEXT,
  p_event_id UUID,
  p_offset BIGINT DEFAULT NULL
) RETURNS void AS $$
BEGIN
  INSERT INTO events.consumer_positions (
    consumer_group, partition_key, last_event_id, last_offset, last_timestamp
  ) VALUES (
    p_consumer_group, p_partition_key, p_event_id, p_offset, now()
  )
  ON CONFLICT (consumer_group, partition_key, stream_name) DO UPDATE
  SET 
    last_event_id = EXCLUDED.last_event_id,
    last_offset = EXCLUDED.last_offset,
    last_timestamp = EXCLUDED.last_timestamp,
    processing_event_id = NULL,
    processing_started_at = NULL,
    updated_at = now();
END;
$$ LANGUAGE plpgsql;

-- Mark events as processed
CREATE OR REPLACE FUNCTION events.confirm_event_processed(p_event_ids UUID[])
RETURNS void AS $$
BEGIN
  UPDATE events.outbox
  SET status = 'PROCESSED'
  WHERE id = ANY(p_event_ids);
END;
$$ LANGUAGE plpgsql;

-- Handle failed events
CREATE OR REPLACE FUNCTION events.mark_event_failed(
  p_event_id UUID,
  p_error_message TEXT
) RETURNS void AS $$
BEGIN
  UPDATE events.outbox
  SET 
    status = CASE 
      WHEN retry_count >= max_retries THEN 'FAILED'
      ELSE 'PENDING'
    END,
    retry_count = retry_count + 1,
    next_retry_at = CASE 
      WHEN retry_count < max_retries 
      THEN now() + (INTERVAL '1 minute' * pow(2, retry_count))::INTERVAL
      ELSE NULL
    END,
    error_message = p_error_message,
    error_details = COALESCE(error_details, '[]'::JSONB) || 
                    jsonb_build_object(
                      'timestamp', now(),
                      'error', p_error_message
                    )
  WHERE id = p_event_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- KUBERNETES INTEGRATION
-- ============================================================================

-- Liveness probe (simple connectivity check)
CREATE OR REPLACE FUNCTION trading.k8s_liveness()
RETURNS JSONB AS $$
BEGIN
  RETURN jsonb_build_object(
    'status', 'alive',
    'timestamp', now(),
    'database', current_database(),
    'version', version()
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'error', SQLERRM
    );
END;
$$ LANGUAGE plpgsql;

-- Readiness probe (comprehensive health check)
CREATE OR REPLACE FUNCTION trading.k8s_readiness()
RETURNS JSONB AS $$
DECLARE
  v_checks JSONB := '{}';
  v_is_ready BOOLEAN := true;
  v_connection_count INT;
  v_replication_lag BIGINT;
BEGIN
  -- Check connection pool
  SELECT COUNT(*) INTO v_connection_count
  FROM pg_stat_activity
  WHERE datname = current_database();
  
  v_checks := v_checks || jsonb_build_object(
    'connections', jsonb_build_object(
      'current', v_connection_count,
      'max', current_setting('max_connections')::INT,
      'healthy', v_connection_count < (current_setting('max_connections')::INT * 0.8)
    )
  );
  
  IF v_connection_count >= (current_setting('max_connections')::INT * 0.8) THEN
    v_is_ready := false;
  END IF;
  
  -- Check replication status
  IF pg_is_in_recovery() THEN
    SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())
    INTO v_replication_lag;
    
    v_checks := v_checks || jsonb_build_object(
      'replication', jsonb_build_object(
        'role', 'replica',
        'lag_bytes', v_replication_lag,
        'healthy', v_replication_lag < 10000000  -- 10MB lag threshold
      )
    );
    
    IF v_replication_lag > 10000000 THEN
      v_is_ready := false;
    END IF;
  ELSE
    v_checks := v_checks || jsonb_build_object(
      'replication', jsonb_build_object(
        'role', 'primary',
        'healthy', true
      )
    );
  END IF;
  
  -- Check critical tables
  BEGIN
    PERFORM 1 FROM trading.orders LIMIT 1;
    v_checks := v_checks || jsonb_build_object('orders_table', 'accessible');
  EXCEPTION
    WHEN OTHERS THEN
      v_checks := v_checks || jsonb_build_object('orders_table', 'error: ' || SQLERRM);
      v_is_ready := false;
  END;
  
  -- Check disk space
  v_checks := v_checks || jsonb_build_object(
    'disk_space', jsonb_build_object(
      'database_size', pg_database_size(current_database()),
      'largest_table', (
        SELECT pg_size_pretty(pg_total_relation_size(c.oid))
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'trading'
        ORDER BY pg_total_relation_size(c.oid) DESC
        LIMIT 1
      )
    )
  );
  
  RETURN jsonb_build_object(
    'ready', v_is_ready,
    'checks', v_checks,
    'timestamp', now()
  );
END;
$$ LANGUAGE plpgsql;

-- Leader election with fencing token
CREATE OR REPLACE FUNCTION trading.try_acquire_leadership(
  p_resource TEXT,
  p_leader_id TEXT,
  p_lease_seconds INT DEFAULT 30
) RETURNS JSONB AS $$
DECLARE
  v_current_leader TEXT;
  v_fence_token BIGINT;
  v_is_leader BOOLEAN;
BEGIN
  -- Try to acquire or renew leadership with fence token
  INSERT INTO trading.leader_election (
    resource_name, leader_id, lease_duration_seconds, fence_token
  ) VALUES (
    p_resource, p_leader_id, p_lease_seconds, 1
  )
  ON CONFLICT (resource_name) DO UPDATE
  SET 
    leader_id = CASE 
      -- Renew if same leader
      WHEN leader_election.leader_id = EXCLUDED.leader_id THEN EXCLUDED.leader_id
      -- Take over if lease expired
      WHEN leader_election.renewed_at < (now() - (leader_election.lease_duration_seconds || ' seconds')::INTERVAL) 
      THEN EXCLUDED.leader_id
      -- Keep current leader
      ELSE leader_election.leader_id
    END,
    fence_token = CASE
      -- Increment fence token on leader change
      WHEN leader_election.leader_id != EXCLUDED.leader_id 
        AND leader_election.renewed_at < (now() - (leader_election.lease_duration_seconds || ' seconds')::INTERVAL)
      THEN leader_election.fence_token + 1
      ELSE leader_election.fence_token
    END,
    renewed_at = CASE
      WHEN leader_election.leader_id = EXCLUDED.leader_id 
        OR leader_election.renewed_at < (now() - (leader_election.lease_duration_seconds || ' seconds')::INTERVAL)
      THEN now()
      ELSE leader_election.renewed_at
    END
  RETURNING leader_id, fence_token INTO v_current_leader, v_fence_token;
  
  v_is_leader := v_current_leader = p_leader_id;
  
  RETURN jsonb_build_object(
    'is_leader', v_is_leader,
    'leader_id', v_current_leader,
    'fence_token', v_fence_token,
    'lease_expires', now() + (p_lease_seconds || ' seconds')::INTERVAL
  );
END;
$$ LANGUAGE plpgsql;

-- StatefulSet pod identity
CREATE OR REPLACE FUNCTION trading.register_pod(
  p_pod_name TEXT,
  p_pod_ip INET,
  p_namespace TEXT DEFAULT 'default'
) RETURNS void AS $$
BEGIN
  INSERT INTO trading.health_checks (component, status, details)
  VALUES (
    p_pod_name,
    'HEALTHY',
    jsonb_build_object(
      'pod_ip', p_pod_ip::TEXT,
      'namespace', p_namespace,
      'started_at', now()
    )
  )
  ON CONFLICT (component) DO UPDATE
  SET 
    status = 'HEALTHY',
    details = health_checks.details || jsonb_build_object(
      'last_seen', now(),
      'pod_ip', p_pod_ip::TEXT
    ),
    last_check = now();
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- ORDERED OPERATIONS (Deadlock Prevention)
-- ============================================================================

-- Update balances in consistent order to prevent deadlocks
CREATE OR REPLACE FUNCTION trading.update_balances_ordered(
  p_updates JSONB[]  -- [{wallet_id, token_id, amount, operation}]
) RETURNS JSONB AS $$
DECLARE
  v_update JSONB;
  v_results JSONB[] := '{}';
  v_result JSONB;
BEGIN
  -- Sort updates to prevent deadlocks
  FOR v_update IN
    SELECT value FROM unnest(p_updates) AS value
    ORDER BY (value->>'wallet_id')::INT, (value->>'token_id')::INT
  LOOP
    v_result := trading.update_balance_merge(
      (v_update->>'wallet_id')::INT,
      (v_update->>'token_id')::INT,
      (v_update->>'amount')::NUMERIC,
      v_update->>'operation',
      v_update->>'idempotency_key'
    );
    v_results := array_append(v_results, v_result);
  END LOOP;
  
  RETURN jsonb_build_object(
    'success', true,
    'results', to_jsonb(v_results)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- DISTRIBUTED LOCKING
-- ============================================================================

CREATE TABLE trading.distributed_locks (
  resource_id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL,
  lock_type TEXT NOT NULL CHECK (lock_type IN ('EXCLUSIVE', 'SHARED')),
  
  acquired_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  
  metadata JSONB DEFAULT '{}'
);

-- Try to acquire distributed lock
CREATE OR REPLACE FUNCTION trading.try_acquire_lock(
  p_resource_id TEXT,
  p_owner_id TEXT,
  p_lock_type TEXT DEFAULT 'EXCLUSIVE',
  p_timeout_seconds INT DEFAULT 60
) RETURNS BOOLEAN AS $$
DECLARE
  v_acquired BOOLEAN := false;
BEGIN
  -- Clean up expired locks
  DELETE FROM trading.distributed_locks
  WHERE resource_id = p_resource_id
    AND expires_at < now();
  
  IF p_lock_type = 'EXCLUSIVE' THEN
    -- Try to acquire exclusive lock
    INSERT INTO trading.distributed_locks (
      resource_id, owner_id, lock_type, expires_at
    ) VALUES (
      p_resource_id, p_owner_id, p_lock_type, 
      now() + (p_timeout_seconds || ' seconds')::INTERVAL
    )
    ON CONFLICT (resource_id) DO NOTHING;
    
    v_acquired := FOUND;
  ELSE
    -- Shared lock logic (multiple readers)
    INSERT INTO trading.distributed_locks (
      resource_id, owner_id, lock_type, expires_at
    ) 
    SELECT 
      p_resource_id, p_owner_id, p_lock_type,
      now() + (p_timeout_seconds || ' seconds')::INTERVAL
    WHERE NOT EXISTS (
      SELECT 1 FROM trading.distributed_locks
      WHERE resource_id = p_resource_id
        AND lock_type = 'EXCLUSIVE'
        AND expires_at > now()
    )
    ON CONFLICT (resource_id) DO NOTHING;
    
    v_acquired := FOUND;
  END IF;
  
  RETURN v_acquired;
END;
$$ LANGUAGE plpgsql;

-- Release distributed lock
CREATE OR REPLACE FUNCTION trading.release_lock(
  p_resource_id TEXT,
  p_owner_id TEXT
) RETURNS BOOLEAN AS $$
DECLARE
  v_released BOOLEAN;
BEGIN
  DELETE FROM trading.distributed_locks
  WHERE resource_id = p_resource_id
    AND owner_id = p_owner_id;
  
  GET DIAGNOSTICS v_released = ROW_COUNT;
  RETURN v_released > 0;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- CIRCUIT BREAKER PATTERN
-- ============================================================================

CREATE TABLE trading.circuit_breakers (
  service_name TEXT PRIMARY KEY,
  state TEXT NOT NULL CHECK (state IN ('CLOSED', 'OPEN', 'HALF_OPEN')),
  
  failure_count INT DEFAULT 0,
  success_count INT DEFAULT 0,
  last_failure_time TIMESTAMPTZ,
  
  -- Configuration
  failure_threshold INT DEFAULT 5,
  success_threshold INT DEFAULT 3,
  timeout_seconds INT DEFAULT 60,
  
  -- State transitions
  opened_at TIMESTAMPTZ,
  half_opened_at TIMESTAMPTZ,
  closed_at TIMESTAMPTZ,
  
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Circuit breaker state machine
CREATE OR REPLACE FUNCTION trading.circuit_breaker_record(
  p_service_name TEXT,
  p_success BOOLEAN
) RETURNS TEXT AS $$
DECLARE
  v_breaker RECORD;
  v_new_state TEXT;
BEGIN
  -- Get or create circuit breaker
  INSERT INTO trading.circuit_breakers (service_name, state, closed_at)
  VALUES (p_service_name, 'CLOSED', now())
  ON CONFLICT (service_name) DO NOTHING;
  
  SELECT * INTO v_breaker
  FROM trading.circuit_breakers
  WHERE service_name = p_service_name
  FOR UPDATE;
  
  v_new_state := v_breaker.state;
  
  -- State machine logic
  IF p_success THEN
    UPDATE trading.circuit_breakers
    SET 
      success_count = CASE 
        WHEN state = 'HALF_OPEN' THEN success_count + 1
        ELSE 0
      END,
      failure_count = 0,
      state = CASE
        WHEN state = 'HALF_OPEN' AND success_count + 1 >= success_threshold THEN 'CLOSED'
        ELSE state
      END,
      closed_at = CASE
        WHEN state = 'HALF_OPEN' AND success_count + 1 >= success_threshold THEN now()
        ELSE closed_at
      END,
      updated_at = now()
    WHERE service_name = p_service_name
    RETURNING state INTO v_new_state;
  ELSE
    UPDATE trading.circuit_breakers
    SET 
      failure_count = failure_count + 1,
      last_failure_time = now(),
      state = CASE
        WHEN state = 'CLOSED' AND failure_count + 1 >= failure_threshold THEN 'OPEN'
        WHEN state = 'HALF_OPEN' THEN 'OPEN'
        ELSE state
      END,
      opened_at = CASE
        WHEN (state = 'CLOSED' AND failure_count + 1 >= failure_threshold) 
          OR state = 'HALF_OPEN' THEN now()
        ELSE opened_at
      END,
      success_count = 0,
      updated_at = now()
    WHERE service_name = p_service_name
    RETURNING state INTO v_new_state;
  END IF;
  
  -- Check for timeout transition from OPEN to HALF_OPEN
  IF v_breaker.state = 'OPEN' 
    AND v_breaker.opened_at < now() - (v_breaker.timeout_seconds || ' seconds')::INTERVAL THEN
    UPDATE trading.circuit_breakers
    SET 
      state = 'HALF_OPEN',
      half_opened_at = now(),
      failure_count = 0,
      success_count = 0,
      updated_at = now()
    WHERE service_name = p_service_name
    RETURNING state INTO v_new_state;
  END IF;
  
  RETURN v_new_state;
END;
$$ LANGUAGE plpgsql;

-- Check if service is available
CREATE OR REPLACE FUNCTION trading.is_service_available(p_service_name TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  v_state TEXT;
BEGIN
  SELECT state INTO v_state
  FROM trading.circuit_breakers
  WHERE service_name = p_service_name;
  
  RETURN v_state IS NULL OR v_state != 'OPEN';
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- RATE LIMITING (Database backup for Redis)
-- ============================================================================

-- Sliding window rate limiter
CREATE OR REPLACE FUNCTION trading.check_rate_limit(
  p_key TEXT,
  p_limit INT,
  p_window_seconds INT
) RETURNS JSONB AS $$
DECLARE
  v_count INT;
  v_allowed BOOLEAN;
  v_reset_at TIMESTAMPTZ;
BEGIN
  v_reset_at := now() + (p_window_seconds || ' seconds')::INTERVAL;
  
  -- Count requests in sliding window
  SELECT COUNT(*) INTO v_count
  FROM trading.cache_invalidations  -- Reusing table for simplicity
  WHERE cache_key = p_key
    AND created_at > now() - (p_window_seconds || ' seconds')::INTERVAL;
  
  v_allowed := v_count < p_limit;
  
  IF v_allowed THEN
    -- Record this request
    INSERT INTO trading.cache_invalidations (
      cache_key, entity_type, operation, status
    ) VALUES (
      p_key, 'rate_limit', 'check', 'PROCESSED'
    );
  END IF;
  
  RETURN jsonb_build_object(
    'allowed', v_allowed,
    'limit', p_limit,
    'remaining', GREATEST(0, p_limit - v_count - 1),
    'reset_at', v_reset_at,
    'retry_after', CASE 
      WHEN NOT v_allowed THEN 
        EXTRACT(EPOCH FROM (v_reset_at - now()))::INT
      ELSE NULL
    END
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- MATERIALIZED VIEWS FOR PERFORMANCE
-- ============================================================================

-- Market depth materialized view
CREATE MATERIALIZED VIEW IF NOT EXISTS trading.mv_market_depth AS
WITH depth_levels AS (
  SELECT 
    token_in_id,
    token_out_id,
    side,
    limit_price,
    SUM(amount_in - filled_amount) as volume,
    COUNT(*) as order_count,
    array_agg(id ORDER BY created_at) as order_ids
  FROM trading.orders
  WHERE status IN ('ACTIVE', 'PARTIALLY_FILLED')
    AND type = 'LIMIT'
  GROUP BY token_in_id, token_out_id, side, limit_price
)
SELECT 
  token_in_id,
  token_out_id,
  side,
  limit_price as price,
  volume,
  order_count,
  SUM(volume) OVER (
    PARTITION BY token_in_id, token_out_id, side 
    ORDER BY 
      CASE WHEN side = 'BUY' THEN limit_price END DESC,
      CASE WHEN side = 'SELL' THEN limit_price END ASC
  ) as cumulative_volume,
  order_ids[1:3] as top_orders  -- Keep only top 3 for performance
FROM depth_levels;

CREATE UNIQUE INDEX idx_mv_depth_unique ON trading.mv_market_depth(token_in_id, token_out_id, side, price);
CREATE INDEX idx_mv_depth_lookup ON trading.mv_market_depth(token_in_id, token_out_id);

-- Function to refresh market depth asynchronously
CREATE OR REPLACE FUNCTION trading.refresh_market_depth_async()
RETURNS void AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY trading.mv_market_depth;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- MONITORING HELPERS
-- ============================================================================

-- Get integration status
CREATE OR REPLACE FUNCTION trading.get_integration_status()
RETURNS JSONB AS $$
DECLARE
  v_status JSONB := '{}';
BEGIN
  -- Cache invalidation queue
  v_status := v_status || jsonb_build_object(
    'cache_invalidation', jsonb_build_object(
      'pending', (SELECT COUNT(*) FROM trading.cache_invalidations WHERE status = 'PENDING'),
      'failed', (SELECT COUNT(*) FROM trading.cache_invalidations WHERE status = 'FAILED'),
      'processed_1h', (SELECT COUNT(*) FROM trading.cache_invalidations 
                       WHERE processed_at > now() - INTERVAL '1 hour')
    )
  );
  
  -- Event outbox
  v_status := v_status || jsonb_build_object(
    'event_outbox', jsonb_build_object(
      'pending', (SELECT COUNT(*) FROM events.outbox WHERE status = 'PENDING'),
      'processing', (SELECT COUNT(*) FROM events.outbox WHERE status = 'PROCESSING'),
      'failed', (SELECT COUNT(*) FROM events.outbox WHERE status = 'FAILED'),
      'processed_1h', (SELECT COUNT(*) FROM events.outbox 
                       WHERE processed_at > now() - INTERVAL '1 hour')
    )
  );
  
  -- Circuit breakers
  v_status := v_status || jsonb_build_object(
    'circuit_breakers', (
      SELECT jsonb_object_agg(service_name, state)
      FROM trading.circuit_breakers
    )
  );
  
  -- Leader election
  v_status := v_status || jsonb_build_object(
    'leaders', (
      SELECT jsonb_object_agg(resource_name, jsonb_build_object(
        'leader', leader_id,
        'expires', renewed_at + (lease_duration_seconds || ' seconds')::INTERVAL
      ))
      FROM trading.leader_election
    )
  );
  
  -- Consumer positions
  v_status := v_status || jsonb_build_object(
    'consumer_positions', (
      SELECT jsonb_object_agg(consumer_group, jsonb_build_object(
        'partitions', COUNT(DISTINCT partition_key),
        'last_update', MAX(updated_at),
        'lag_seconds', EXTRACT(EPOCH FROM (now() - MIN(last_timestamp)))
      ))
      FROM events.consumer_positions
      GROUP BY consumer_group
    )
  );
  
  RETURN v_status;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- STRUCTURED NOTIFY TRIGGERS
-- ============================================================================

-- Attach structured NOTIFY to critical tables for Rust async integration
CREATE TRIGGER notify_orders_changes
  AFTER INSERT OR UPDATE OR DELETE ON trading.orders
  FOR EACH ROW EXECUTE FUNCTION events.notify_structured();

CREATE TRIGGER notify_fills_changes
  AFTER INSERT ON trading.order_fills
  FOR EACH ROW EXECUTE FUNCTION events.notify_structured();

CREATE TRIGGER notify_balances_changes
  AFTER UPDATE ON trading.account_balances
  FOR EACH ROW 
  WHEN (OLD.available IS DISTINCT FROM NEW.available OR OLD.reserved IS DISTINCT FROM NEW.reserved)
  EXECUTE FUNCTION events.notify_structured();

-- ============================================================================
-- CLEANUP JOBS
-- ============================================================================

-- Clean up old processed events
CREATE OR REPLACE FUNCTION events.cleanup_processed_events(p_days_to_keep INT DEFAULT 7)
RETURNS INT AS $$
DECLARE
  v_deleted INT;
BEGIN
  DELETE FROM events.outbox
  WHERE status = 'PROCESSED'
    AND processed_at < now() - (p_days_to_keep || ' days')::INTERVAL;
  
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  
  -- Also clean up old cache invalidations
  DELETE FROM trading.cache_invalidations
  WHERE status = 'PROCESSED'
    AND processed_at < now() - INTERVAL '1 day';
  
  RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- END OF INTEGRATIONS
-- ============================================================================
