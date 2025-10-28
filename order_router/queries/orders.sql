-- name: GetOrderBasic :one
SELECT
  id::text AS id,
  strategy_id,
  adapter_key,
  side::text   AS side,
  type::text   AS type,
  tif::text    AS tif,
  status::text AS status,
  amount_in::text       AS amount_in,
  filled_amount::text   AS filled_amount,
  created_at,
  updated_at
FROM trading.orders
WHERE id = $1;

-- name: GetOrderByIdempotencyBasic :one
SELECT
  id::text AS id,
  strategy_id,
  adapter_key,
  side::text   AS side,
  type::text   AS type,
  tif::text    AS tif,
  status::text AS status,
  amount_in::text       AS amount_in,
  filled_amount::text   AS filled_amount,
  created_at,
  updated_at
FROM trading.orders
WHERE idempotency_key = $1;
