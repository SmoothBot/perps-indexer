-- Migration: Create hourly materialized views for dashboard performance optimization
-- This significantly improves query performance for dashboards by pre-aggregating hourly data

-- Drop existing materialized views if they exist
DROP MATERIALIZED VIEW IF EXISTS hourly_market_stats CASCADE;
DROP MATERIALIZED VIEW IF EXISTS hourly_exchange_stats CASCADE;

-- 1. Enhanced hourly_user_stats (already exists but we'll recreate with more fields)
DROP MATERIALIZED VIEW IF EXISTS hourly_user_stats CASCADE;

CREATE MATERIALIZED VIEW hourly_user_stats AS
SELECT
    date_trunc('hour', f.timestamp) AS hour,
    f.exchange_id,
    f.user_address,
    f.market_id,
    m.symbol,
    m.market_type,
    -- Volume metrics
    SUM(f.price * f.size) AS total_volume,
    SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE 0 END) AS buy_volume,
    SUM(CASE WHEN f.side = 'SELL' THEN f.price * f.size ELSE 0 END) AS sell_volume,
    SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE -f.price * f.size END) AS net_volume,
    -- Trade metrics
    COUNT(*) AS trade_count,
    COUNT(DISTINCT f.timestamp) AS unique_trade_times,
    AVG(f.price * f.size) AS avg_trade_size,
    MAX(f.price * f.size) AS max_trade_size,
    MIN(f.price * f.size) AS min_trade_size,
    -- PnL and fees
    SUM(COALESCE(f.closed_pnl, 0)) AS total_pnl,
    SUM(COALESCE(f.fee, 0)) AS total_fees,
    -- Price metrics
    MIN(f.price) AS min_price,
    MAX(f.price) AS max_price,
    (array_agg(f.price ORDER BY f.timestamp ASC))[1] AS open_price,
    (array_agg(f.price ORDER BY f.timestamp DESC))[1] AS close_price
FROM fills f
JOIN markets m ON f.market_id = m.id
GROUP BY
    date_trunc('hour', f.timestamp),
    f.exchange_id,
    f.user_address,
    f.market_id,
    m.symbol,
    m.market_type;

-- Create indexes for efficient querying
CREATE UNIQUE INDEX idx_hourly_user_stats_unique
ON hourly_user_stats(hour, exchange_id, user_address, market_id);

CREATE INDEX idx_hourly_user_stats_hour
ON hourly_user_stats(hour);

CREATE INDEX idx_hourly_user_stats_user
ON hourly_user_stats(user_address, hour);

CREATE INDEX idx_hourly_user_stats_market
ON hourly_user_stats(market_id, hour);

CREATE INDEX idx_hourly_user_stats_exchange
ON hourly_user_stats(exchange_id, hour);

-- 2. Hourly market-level statistics (for market overview and high-level dashboards)
CREATE MATERIALIZED VIEW hourly_market_stats AS
SELECT
    date_trunc('hour', f.timestamp) AS hour,
    f.exchange_id,
    f.market_id,
    m.symbol,
    m.market_type,
    -- Volume metrics
    SUM(f.price * f.size) AS total_volume,
    SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE 0 END) AS buy_volume,
    SUM(CASE WHEN f.side = 'SELL' THEN f.price * f.size ELSE 0 END) AS sell_volume,
    SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE -f.price * f.size END) AS net_volume,
    -- Trade metrics
    COUNT(*) AS trade_count,
    COUNT(DISTINCT f.user_address) AS unique_traders,
    AVG(f.price * f.size) AS avg_trade_size,
    STDDEV(f.price * f.size) AS trade_size_stddev,
    -- PnL and fees
    SUM(COALESCE(f.closed_pnl, 0)) AS total_pnl,
    SUM(COALESCE(f.fee, 0)) AS total_fees,
    AVG(COALESCE(f.fee, 0)) AS avg_fee,
    -- Price metrics
    MIN(f.price) AS min_price,
    MAX(f.price) AS max_price,
    AVG(f.price) AS avg_price,
    (array_agg(f.price ORDER BY f.timestamp ASC))[1] AS open_price,
    (array_agg(f.price ORDER BY f.timestamp DESC))[1] AS close_price,
    -- Size metrics
    SUM(f.size) AS total_size,
    AVG(f.size) AS avg_size
FROM fills f
JOIN markets m ON f.market_id = m.id
GROUP BY
    date_trunc('hour', f.timestamp),
    f.exchange_id,
    f.market_id,
    m.symbol,
    m.market_type;

-- Create indexes for efficient querying
CREATE UNIQUE INDEX idx_hourly_market_stats_unique
ON hourly_market_stats(hour, exchange_id, market_id);

CREATE INDEX idx_hourly_market_stats_hour
ON hourly_market_stats(hour);

CREATE INDEX idx_hourly_market_stats_market
ON hourly_market_stats(market_id, hour);

CREATE INDEX idx_hourly_market_stats_symbol
ON hourly_market_stats(symbol, hour);

CREATE INDEX idx_hourly_market_stats_type
ON hourly_market_stats(market_type, hour);

-- 3. Hourly exchange-level statistics (for system monitoring and overview)
CREATE MATERIALIZED VIEW hourly_exchange_stats AS
SELECT
    date_trunc('hour', f.timestamp) AS hour,
    f.exchange_id,
    e.code AS exchange_code,
    e.name AS exchange_name,
    -- Overall metrics
    COUNT(*) AS total_fills,
    COUNT(DISTINCT f.user_address) AS unique_traders,
    COUNT(DISTINCT f.market_id) AS active_markets,
    -- Volume metrics
    SUM(f.price * f.size) AS total_volume,
    SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE 0 END) AS buy_volume,
    SUM(CASE WHEN f.side = 'SELL' THEN f.price * f.size ELSE 0 END) AS sell_volume,
    SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE -f.price * f.size END) AS net_volume,
    -- Trade size metrics
    AVG(f.price * f.size) AS avg_trade_size,
    MAX(f.price * f.size) AS max_trade_size,
    MIN(f.price * f.size) AS min_trade_size,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.price * f.size) AS median_trade_size,
    -- PnL and fees
    SUM(COALESCE(f.closed_pnl, 0)) AS total_pnl,
    SUM(COALESCE(f.fee, 0)) AS total_fees,
    AVG(COALESCE(f.fee, 0)) AS avg_fee,
    -- Market type breakdown
    SUM(CASE WHEN m.market_type = 'spot' THEN f.price * f.size ELSE 0 END) AS spot_volume,
    SUM(CASE WHEN m.market_type = 'perp' THEN f.price * f.size ELSE 0 END) AS perp_volume,
    COUNT(CASE WHEN m.market_type = 'spot' THEN 1 END) AS spot_trades,
    COUNT(CASE WHEN m.market_type = 'perp' THEN 1 END) AS perp_trades
FROM fills f
JOIN markets m ON f.market_id = m.id
JOIN exchanges e ON f.exchange_id = e.id
GROUP BY
    date_trunc('hour', f.timestamp),
    f.exchange_id,
    e.code,
    e.name;

-- Create indexes for efficient querying
CREATE UNIQUE INDEX idx_hourly_exchange_stats_unique
ON hourly_exchange_stats(hour, exchange_id);

CREATE INDEX idx_hourly_exchange_stats_hour
ON hourly_exchange_stats(hour);

CREATE INDEX idx_hourly_exchange_stats_exchange
ON hourly_exchange_stats(exchange_id, hour);

-- Function to refresh all materialized views
CREATE OR REPLACE FUNCTION refresh_hourly_materialized_views()
RETURNS void AS $$
BEGIN
    -- Refresh views in dependency order
    REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_user_stats;
    REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_market_stats;
    REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_exchange_stats;

    -- Log the refresh
    RAISE NOTICE 'Refreshed all hourly materialized views at %', NOW();
END;
$$ LANGUAGE plpgsql;

-- Grant appropriate permissions
GRANT SELECT ON hourly_user_stats TO PUBLIC;
GRANT SELECT ON hourly_market_stats TO PUBLIC;
GRANT SELECT ON hourly_exchange_stats TO PUBLIC;