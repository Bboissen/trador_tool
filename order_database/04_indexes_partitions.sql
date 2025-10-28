-- Partial indexes to support price lookups per type
CREATE INDEX IF NOT EXISTS idx_orders_limit_price_limit
  ON trading.orders (limit_price)
  WHERE type = 'LIMIT';

CREATE INDEX IF NOT EXISTS idx_orders_limit_price_stop_limit
  ON trading.orders (limit_price)
  WHERE type = 'STOP_LIMIT';

CREATE INDEX IF NOT EXISTS idx_orders_stop_price_stop
  ON trading.orders (stop_price)
  WHERE type = 'STOP';

CREATE INDEX IF NOT EXISTS idx_orders_stop_price_stop_limit
  ON trading.orders (stop_price)
  WHERE type = 'STOP_LIMIT';

