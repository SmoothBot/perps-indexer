-- Optimization indexes for market type filtering queries
-- These indexes significantly improve performance for dashboards that join fills with markets

-- Index for joining fills with markets and filtering by market_type
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fills_market_id_timestamp
ON fills(market_id, timestamp);

-- Index for market lookups by type
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_markets_market_type
ON markets(market_type);

-- Composite index for common query patterns (side-based aggregations)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fills_market_id_side_timestamp
ON fills(market_id, side, timestamp);

-- Index for user address lookups combined with market_id
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fills_user_market_timestamp
ON fills(user_address, market_id, timestamp);

-- Partial index for non-null closed_pnl values (speeds up PnL calculations)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fills_market_pnl
ON fills(market_id, timestamp)
WHERE closed_pnl IS NOT NULL;