-- name: ListOrderFillsBasic :many
SELECT
  id::text       AS id,
  order_id::text AS order_id,
  idempotency_key,
  amount_in::text  AS amount_in,
  amount_out::text AS amount_out,
  price::text      AS price,
  status::text     AS status,
  executed_at
FROM trading.order_fills
WHERE order_id = $1
  AND ($2::timestamptz IS NULL OR executed_at > $2)
ORDER BY executed_at ASC
LIMIT $3;
