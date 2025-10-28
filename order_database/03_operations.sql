CREATE SCHEMA IF NOT EXISTS api; -- Public API for core operations

-- Function to enqueue an event into the outbox for reliable messaging
CREATE OR REPLACE FUNCTION api.enqueue_event(
    p_aggregate_id UUID,
    p_aggregate_type TEXT,
    p_event_type TEXT,
    p_payload JSONB,
    p_headers JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_event_id UUID;
BEGIN
    INSERT INTO events.outbox (
        aggregate_id, aggregate_type, event_type, payload, headers
    )
    VALUES (
        p_aggregate_id, p_aggregate_type, p_event_type, p_payload, p_headers
    )
    RETURNING id INTO v_event_id;

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION api.create_order(
    p_strategy_id INT,
    p_source_network_id INT,
    p_dest_network_id INT,
    p_adapter_key TEXT,
    p_idempotency_key TEXT,
    p_asset_in_ref TEXT,
    p_asset_out_ref TEXT,
    p_side trading.order_side,
    p_type trading.order_type,
    p_tif trading.order_tif,
    p_reduce_only BOOLEAN,
    p_post_only BOOLEAN,
    p_leverage NUMERIC(10,4),
    p_margin_mode trading.margin_mode,
    p_amount_in NUMERIC(78,0),
    p_amount_out_min NUMERIC(78,0),
    p_limit_price NUMERIC(38,18),
    p_stop_price NUMERIC(38,18),
    p_slippage_tolerance NUMERIC(5,4),
    p_tags TEXT[],
    p_metadata JSONB,
    p_execution_preferences JSONB
)
RETURNS UUID AS $$
DECLARE
    v_order_id UUID;
    v_existing_payload JSONB;
    v_expected_payload JSONB;
BEGIN
    BEGIN
        INSERT INTO trading.orders (
            strategy_id, source_network_id, dest_network_id, adapter_key,
            idempotency_key, asset_in_ref, asset_out_ref, side, type, tif,
            reduce_only, post_only, leverage, margin_mode, amount_in,
            amount_out_min, limit_price, stop_price, slippage_tolerance, tags, metadata, execution_preferences
        )
        VALUES (
            p_strategy_id, p_source_network_id, p_dest_network_id, p_adapter_key,
            p_idempotency_key, p_asset_in_ref, p_asset_out_ref, p_side, p_type, p_tif,
            p_reduce_only, p_post_only, p_leverage, p_margin_mode, p_amount_in,
            p_amount_out_min, p_limit_price, p_stop_price, p_slippage_tolerance, p_tags, p_metadata, p_execution_preferences
        )
        RETURNING id INTO v_order_id;

        -- Enqueue OrderCreated event
        PERFORM api.enqueue_event(
            v_order_id,
            'order',
            'OrderCreated',
            jsonb_build_object(
                'id', v_order_id,
                'strategy_id', p_strategy_id,
                'source_network_id', p_source_network_id,
                'dest_network_id', p_dest_network_id,
                'adapter_key', p_adapter_key,
                'idempotency_key', p_idempotency_key,
                'asset_in_ref', p_asset_in_ref,
                'asset_out_ref', p_asset_out_ref,
                'side', p_side,
                'type', p_type,
                'tif', p_tif,
                'reduce_only', p_reduce_only,
                'post_only', p_post_only,
                'leverage', p_leverage,
                'margin_mode', p_margin_mode,
                'amount_in', p_amount_in,
                'amount_out_min', p_amount_out_min,
                'limit_price', p_limit_price,
                'stop_price', p_stop_price,
                'slippage_tolerance', p_slippage_tolerance,
                'tags', p_tags,
                'metadata', p_metadata,
                'execution_preferences', p_execution_preferences
            )
        );
    EXCEPTION
        WHEN unique_violation THEN
            SELECT 
                id,
                jsonb_build_object(
                    'strategy_id', strategy_id,
                    'source_network_id', source_network_id,
                    'dest_network_id', dest_network_id,
                    'adapter_key', adapter_key,
                    'asset_in_ref', asset_in_ref,
                    'asset_out_ref', asset_out_ref,
                    'side', side,
                    'type', type,
                    'tif', tif,
                    'reduce_only', reduce_only,
                    'post_only', post_only,
                    'leverage', leverage,
                    'margin_mode', margin_mode,
                    'amount_in', amount_in,
                    'amount_out_min', amount_out_min,
                    'limit_price', limit_price,
                    'stop_price', stop_price,
                    'slippage_tolerance', slippage_tolerance,
                    'tags', to_jsonb(tags),
                    'metadata', metadata,
                    'execution_preferences', execution_preferences
                )
            INTO v_order_id, v_existing_payload
            FROM trading.orders
            WHERE idempotency_key = p_idempotency_key;

            IF v_order_id IS NULL THEN
                -- Re-raise if the unique violation is unrelated to the idempotency key
                RAISE;
            END IF;

            v_expected_payload := jsonb_build_object(
                'strategy_id', p_strategy_id,
                'source_network_id', p_source_network_id,
                'dest_network_id', p_dest_network_id,
                'adapter_key', p_adapter_key,
                'asset_in_ref', p_asset_in_ref,
                'asset_out_ref', p_asset_out_ref,
                'side', p_side,
                'type', p_type,
                'tif', p_tif,
                'reduce_only', p_reduce_only,
                'post_only', p_post_only,
                'leverage', p_leverage,
                'margin_mode', p_margin_mode,
                'amount_in', p_amount_in,
                'amount_out_min', p_amount_out_min,
                'limit_price', p_limit_price,
                'stop_price', p_stop_price,
                'slippage_tolerance', p_slippage_tolerance,
                'tags', to_jsonb(p_tags),
                'metadata', p_metadata,
                'execution_preferences', p_execution_preferences
            );

            IF v_existing_payload IS DISTINCT FROM v_expected_payload THEN
                RAISE EXCEPTION 'Idempotency payload mismatch for key % (order %)', p_idempotency_key, v_order_id
                    USING HINT = 'Repeat create_order calls must send identical arguments.';
            END IF;

            RETURN v_order_id;
    END;

    RETURN v_order_id;
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION api.add_order_fill(
    p_order_id UUID,
    p_idempotency_key TEXT,
    p_amount_in NUMERIC(78,0),
    p_amount_out NUMERIC(78,0),
    p_price NUMERIC(38,18),
    p_fee_amount NUMERIC(78,0) DEFAULT 0,
    p_fee_asset_ref TEXT DEFAULT NULL,
    p_adapter_key TEXT DEFAULT NULL,
    p_tx_hash BYTEA DEFAULT NULL,
    p_block_number BIGINT DEFAULT NULL,
    p_log_index INT DEFAULT NULL,
    p_status trading.transaction_status DEFAULT 'CONFIRMED'
)
RETURNS UUID AS $$
DECLARE
    v_fill_id UUID;
    v_order_amount_in NUMERIC(78,0);
    v_order_filled_amount NUMERIC(78,0);
    v_order_current_avg_price NUMERIC(38,18);
    v_new_filled_amount NUMERIC(78,0);
    v_new_avg_fill_price NUMERIC(38,18);
    v_was_inserted BOOLEAN := false;
BEGIN
    -- Acquire transaction-scoped advisory lock tied to this order
    PERFORM pg_advisory_xact_lock(hashtext(p_order_id::TEXT));

    -- Attempt to insert the order fill; detect whether this call created a new row
    WITH inserted AS (
        INSERT INTO trading.order_fills (
            order_id, idempotency_key, amount_in, amount_out, price, fee_amount, fee_asset_ref,
            adapter_key, tx_hash, block_number, log_index, status
        )
        VALUES (
            p_order_id, p_idempotency_key, p_amount_in, p_amount_out, p_price, p_fee_amount, p_fee_asset_ref,
            p_adapter_key, p_tx_hash, p_block_number, p_log_index, p_status
        )
        ON CONFLICT (order_id, idempotency_key) DO NOTHING
        RETURNING id
    )
    SELECT id, true INTO v_fill_id, v_was_inserted FROM inserted;

    IF NOT v_was_inserted THEN
        -- Row already existed; lock and reuse existing fill
        SELECT id INTO v_fill_id
        FROM trading.order_fills
        WHERE order_id = p_order_id
          AND idempotency_key = p_idempotency_key
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Order fill with idempotency key % not found for order %', p_idempotency_key, p_order_id;
        END IF;
    END IF;

    -- Update status/timestamps/metadata (applies to both new and existing rows)
    UPDATE trading.order_fills
    SET
        status = CASE WHEN status <> p_status THEN p_status ELSE status END,
        confirmed_at = CASE WHEN p_status = 'CONFIRMED' AND confirmed_at IS NULL THEN now() ELSE confirmed_at END,
        reverted_at = CASE WHEN p_status = 'REVERTED' AND reverted_at IS NULL THEN now() ELSE reverted_at END,
        adapter_key = COALESCE(p_adapter_key, adapter_key),
        tx_hash = COALESCE(p_tx_hash, tx_hash),
        block_number = COALESCE(p_block_number, block_number),
        log_index = COALESCE(p_log_index, log_index)
    WHERE id = v_fill_id;

    IF v_was_inserted THEN
        -- Update the parent order's filled_amount and average_fill_price only for new fills
        SELECT amount_in, filled_amount, average_fill_price
        INTO v_order_amount_in, v_order_filled_amount, v_order_current_avg_price
        FROM trading.orders
        WHERE id = p_order_id
        FOR UPDATE;

        v_new_filled_amount := v_order_filled_amount + p_amount_in;

        IF v_order_filled_amount = 0 THEN
            v_new_avg_fill_price := ROUND(p_price, 10);
        ELSE
            v_new_avg_fill_price := ROUND(
                (
                    (v_order_current_avg_price * v_order_filled_amount) + (p_price * p_amount_in)
                ) / v_new_filled_amount,
                10
            );
        END IF;

        UPDATE trading.orders
        SET
            filled_amount = v_new_filled_amount,
            average_fill_price = v_new_avg_fill_price,
            status = CASE
                WHEN v_new_filled_amount >= v_order_amount_in THEN 'FILLED'
                WHEN v_new_filled_amount > 0 THEN 'PARTIALLY_FILLED'
                ELSE 'OPEN'
            END
        WHERE id = p_order_id;

        -- Enqueue OrderFillAdded event only once per unique fill
        PERFORM api.enqueue_event(
            p_order_id,
            'order',
            'OrderFillAdded',
            jsonb_build_object(
                'order_id', p_order_id,
                'fill_id', v_fill_id,
                'amount_in', p_amount_in,
                'amount_out', p_amount_out,
                'price', p_price,
                'new_filled_amount', v_new_filled_amount,
                'new_avg_fill_price', v_new_avg_fill_price
            )
        );
    END IF;

    RETURN v_fill_id;
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION api.update_order_lifecycle(
    p_order_id UUID,
    p_new_status trading.order_status,
    p_triggered_at TIMESTAMPTZ DEFAULT NULL,
    p_completed_at TIMESTAMPTZ DEFAULT NULL,
    p_metadata JSONB DEFAULT NULL
)
RETURNS trading.order_status AS $$
DECLARE
    v_current_status trading.order_status;
    v_allowed BOOLEAN := false;
    v_final_status BOOLEAN;
    v_updated_triggered_at TIMESTAMPTZ;
    v_updated_completed_at TIMESTAMPTZ;
BEGIN
    SELECT status
    INTO v_current_status
    FROM trading.orders
    WHERE id = p_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % not found', p_order_id
            USING ERRCODE = 'P0002';
    END IF;

    IF v_current_status = p_new_status THEN
        UPDATE trading.orders
        SET
            triggered_at = COALESCE(p_triggered_at, triggered_at),
            completed_at = COALESCE(p_completed_at, completed_at),
            metadata = CASE
                WHEN p_metadata IS NOT NULL THEN COALESCE(metadata, '{}'::JSONB) || p_metadata
                ELSE metadata
            END,
            updated_at = now()
        WHERE id = p_order_id
        RETURNING triggered_at, completed_at
        INTO v_updated_triggered_at, v_updated_completed_at;

        RETURN p_new_status;
    END IF;

    CASE v_current_status
        WHEN 'PENDING' THEN
            v_allowed := p_new_status IN ('OPEN', 'CANCELLED', 'REJECTED', 'EXPIRED');
        WHEN 'OPEN' THEN
            v_allowed := p_new_status IN ('PARTIALLY_FILLED', 'FILLED', 'CANCELLED', 'REJECTED', 'EXPIRED');
        WHEN 'PARTIALLY_FILLED' THEN
            v_allowed := p_new_status IN ('FILLED', 'CANCELLED', 'REJECTED');
        ELSE
            v_allowed := false;
    END CASE;

    IF NOT v_allowed THEN
        RAISE EXCEPTION 'Illegal order status transition % -> % for order %', v_current_status, p_new_status, p_order_id
            USING ERRCODE = 'P0001',
                  HINT = 'Review allowed transitions: PENDING→OPEN/CANCELLED/REJECTED/EXPIRED, OPEN→PARTIALLY_FILLED/FILLED/CANCELLED/REJECTED/EXPIRED, PARTIALLY_FILLED→FILLED/CANCELLED/REJECTED.';
    END IF;

    v_final_status := p_new_status IN ('FILLED', 'CANCELLED', 'REJECTED', 'EXPIRED');

    UPDATE trading.orders
    SET
        status = p_new_status,
        triggered_at = COALESCE(
            p_triggered_at,
            CASE WHEN p_new_status = 'OPEN' AND triggered_at IS NULL THEN now() ELSE triggered_at END
        ),
        completed_at = COALESCE(
            p_completed_at,
            CASE WHEN v_final_status AND completed_at IS NULL THEN now() ELSE completed_at END
        ),
        metadata = CASE
            WHEN p_metadata IS NOT NULL THEN COALESCE(metadata, '{}'::JSONB) || p_metadata
            ELSE metadata
        END,
        updated_at = now()
    WHERE id = p_order_id
    RETURNING triggered_at, completed_at
    INTO v_updated_triggered_at, v_updated_completed_at;

    PERFORM api.enqueue_event(
        p_order_id,
        'order',
        'OrderStatusUpdated',
        jsonb_build_object(
            'order_id', p_order_id,
            'previous_status', v_current_status,
            'new_status', p_new_status,
            'triggered_at', v_updated_triggered_at,
            'completed_at', v_updated_completed_at
        )
    );

    RETURN p_new_status;
END;
$$ LANGUAGE plpgsql VOLATILE;
