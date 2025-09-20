-- Migration: Add hourly user stats materialized view
-- This creates a pre-aggregated view of hourly statistics per user and coin

-- Create the materialized view for hourly user statistics
CREATE MATERIALIZED VIEW IF NOT EXISTS hl_hourly_user_stats AS
SELECT
    user_address,
    DATE_TRUNC('hour', timestamp) AS hour,
    coin,
    COUNT(*) AS trade_count,
    SUM(price * size) AS volume,
    SUM(closed_pnl) AS total_pnl,
    SUM(fee) AS total_fees,
    -- Additional useful metrics
    AVG(price) AS avg_price,
    MAX(price) AS max_price,
    MIN(price) AS min_price,
    SUM(CASE WHEN side = 'BUY' THEN price * size ELSE 0 END) AS buy_volume,
    SUM(CASE WHEN side = 'SELL' THEN price * size ELSE 0 END) AS sell_volume,
    COUNT(CASE WHEN side = 'BUY' THEN 1 END) AS buy_count,
    COUNT(CASE WHEN side = 'SELL' THEN 1 END) AS sell_count
FROM hl_fills
GROUP BY
    user_address,
    DATE_TRUNC('hour', timestamp),
    coin;

-- Create indexes for optimal query performance
CREATE INDEX IF NOT EXISTS idx_hourly_user_stats_user_hour
    ON hl_hourly_user_stats (user_address, hour DESC);

CREATE INDEX IF NOT EXISTS idx_hourly_user_stats_hour
    ON hl_hourly_user_stats (hour DESC);

CREATE INDEX IF NOT EXISTS idx_hourly_user_stats_coin_hour
    ON hl_hourly_user_stats (coin, hour DESC);

CREATE INDEX IF NOT EXISTS idx_hourly_user_stats_user_coin_hour
    ON hl_hourly_user_stats (user_address, coin, hour DESC);

-- Add a comment to describe the view
COMMENT ON MATERIALIZED VIEW hl_hourly_user_stats IS
    'Pre-aggregated hourly trading statistics per user and coin. Refresh after backfill runs.';

-- Create a function to refresh the materialized view
-- This can be called after backfill operations
CREATE OR REPLACE FUNCTION refresh_hourly_user_stats()
RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY hl_hourly_user_stats;
END;
$$ LANGUAGE plpgsql;

-- Add comment to the function
COMMENT ON FUNCTION refresh_hourly_user_stats() IS
    'Refreshes the hourly user stats materialized view. Call after backfill operations.';

-- Create a unique index to enable CONCURRENTLY refresh
-- This allows refreshing without locking the view for reads
CREATE UNIQUE INDEX IF NOT EXISTS idx_hourly_user_stats_unique
    ON hl_hourly_user_stats (user_address, hour, coin);