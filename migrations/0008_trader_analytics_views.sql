-- Migration: Create comprehensive trader and market analytics materialized views
-- These views optimize dashboard queries by pre-aggregating trader and market data

-- 1. trader_summary: Comprehensive trader statistics
DROP MATERIALIZED VIEW IF EXISTS trader_summary CASCADE;

CREATE MATERIALIZED VIEW trader_summary AS
SELECT
    f.exchange_id,
    f.user_address,
    -- Overall statistics
    COUNT(*) as total_trades,
    COUNT(DISTINCT f.market_id) as markets_traded,
    SUM(f.price * f.size) as total_volume,
    SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE 0 END) as buy_volume,
    SUM(CASE WHEN f.side = 'SELL' THEN f.price * f.size ELSE 0 END) as sell_volume,
    SUM(COALESCE(f.closed_pnl, 0)) as total_pnl,
    SUM(COALESCE(f.fee, 0)) as total_fees,
    AVG(f.price * f.size) as avg_trade_size,
    MAX(f.price * f.size) as max_trade_size,
    MIN(f.timestamp) as first_trade_time,
    MAX(f.timestamp) as last_trade_time,
    -- Time-based aggregations
    COUNT(CASE WHEN f.timestamp >= NOW() - INTERVAL '24 hours' THEN 1 END) as trades_24h,
    SUM(CASE WHEN f.timestamp >= NOW() - INTERVAL '24 hours' THEN f.price * f.size ELSE 0 END) as volume_24h,
    COUNT(CASE WHEN f.timestamp >= NOW() - INTERVAL '7 days' THEN 1 END) as trades_7d,
    SUM(CASE WHEN f.timestamp >= NOW() - INTERVAL '7 days' THEN f.price * f.size ELSE 0 END) as volume_7d,
    COUNT(CASE WHEN f.timestamp >= NOW() - INTERVAL '30 days' THEN 1 END) as trades_30d,
    SUM(CASE WHEN f.timestamp >= NOW() - INTERVAL '30 days' THEN f.price * f.size ELSE 0 END) as volume_30d
FROM fills f
GROUP BY f.exchange_id, f.user_address;

-- Create indexes for efficient querying
CREATE UNIQUE INDEX idx_trader_summary_unique
ON trader_summary(exchange_id, user_address);

CREATE INDEX idx_trader_summary_volume
ON trader_summary(total_volume DESC);

CREATE INDEX idx_trader_summary_pnl
ON trader_summary(total_pnl DESC);

CREATE INDEX idx_trader_summary_trades
ON trader_summary(total_trades DESC);

-- 2. trader_market_summary: Per-trader, per-market statistics
DROP MATERIALIZED VIEW IF EXISTS trader_market_summary CASCADE;

CREATE MATERIALIZED VIEW trader_market_summary AS
SELECT
    f.exchange_id,
    f.user_address,
    f.market_id,
    m.symbol,
    m.market_type,
    -- Trade statistics
    COUNT(*) as total_trades,
    SUM(f.price * f.size) as total_volume,
    SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE 0 END) as buy_volume,
    SUM(CASE WHEN f.side = 'SELL' THEN f.price * f.size ELSE 0 END) as sell_volume,
    SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE -f.price * f.size END) as net_volume,
    SUM(COALESCE(f.closed_pnl, 0)) as total_pnl,
    SUM(COALESCE(f.fee, 0)) as total_fees,
    AVG(f.price * f.size) as avg_trade_size,
    MAX(f.price * f.size) as max_trade_size,
    MIN(f.timestamp) as first_trade_time,
    MAX(f.timestamp) as last_trade_time,
    -- Win/Loss statistics
    COUNT(CASE WHEN f.closed_pnl > 0 THEN 1 END) as winning_trades,
    COUNT(CASE WHEN f.closed_pnl < 0 THEN 1 END) as losing_trades,
    SUM(CASE WHEN f.closed_pnl > 0 THEN f.closed_pnl ELSE 0 END) as total_profit,
    SUM(CASE WHEN f.closed_pnl < 0 THEN ABS(f.closed_pnl) ELSE 0 END) as total_loss
FROM fills f
JOIN markets m ON f.market_id = m.id
GROUP BY f.exchange_id, f.user_address, f.market_id, m.symbol, m.market_type;

-- Create indexes
CREATE UNIQUE INDEX idx_trader_market_summary_unique
ON trader_market_summary(exchange_id, user_address, market_id);

CREATE INDEX idx_trader_market_summary_user
ON trader_market_summary(exchange_id, user_address);

CREATE INDEX idx_trader_market_summary_market
ON trader_market_summary(exchange_id, market_id);

CREATE INDEX idx_trader_market_summary_volume
ON trader_market_summary(total_volume DESC);

-- 3. daily_market_stats: Daily aggregated market statistics
DROP MATERIALIZED VIEW IF EXISTS daily_market_stats CASCADE;

CREATE MATERIALIZED VIEW daily_market_stats AS
SELECT
    f.exchange_id,
    f.market_id,
    m.symbol,
    m.market_type,
    DATE(f.timestamp) as trade_date,
    COUNT(*) as total_trades,
    COUNT(DISTINCT f.user_address) as unique_traders,
    SUM(f.price * f.size) as total_volume,
    SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE 0 END) as buy_volume,
    SUM(CASE WHEN f.side = 'SELL' THEN f.price * f.size ELSE 0 END) as sell_volume,
    AVG(f.price * f.size) as avg_trade_size,
    MAX(f.price * f.size) as max_trade_size,
    MIN(f.price) as low_price,
    MAX(f.price) as high_price,
    (array_agg(f.price ORDER BY f.timestamp ASC))[1] as open_price,
    (array_agg(f.price ORDER BY f.timestamp DESC))[1] as close_price,
    SUM(COALESCE(f.fee, 0)) as total_fees,
    SUM(COALESCE(f.closed_pnl, 0)) as total_pnl
FROM fills f
JOIN markets m ON f.market_id = m.id
GROUP BY f.exchange_id, f.market_id, m.symbol, m.market_type, DATE(f.timestamp);

-- Create indexes
CREATE UNIQUE INDEX idx_daily_market_stats_unique
ON daily_market_stats(exchange_id, market_id, trade_date);

CREATE INDEX idx_daily_market_stats_date
ON daily_market_stats(trade_date DESC);

CREATE INDEX idx_daily_market_stats_volume
ON daily_market_stats(total_volume DESC);

-- 4. large_trades: Cache of significant trades for whale tracking
DROP MATERIALIZED VIEW IF EXISTS large_trades CASCADE;

CREATE MATERIALIZED VIEW large_trades AS
SELECT
    f.id,
    f.exchange_id,
    f.market_id,
    m.symbol,
    m.market_type,
    f.user_address,
    f.side,
    f.price,
    f.size,
    (f.price * f.size) as volume_usd,
    f.fee,
    f.closed_pnl,
    f.timestamp,
    f.block_number,
    -- Classification
    CASE
        WHEN f.price * f.size >= 1000000 THEN 'mega_whale'
        WHEN f.price * f.size >= 500000 THEN 'large_whale'
        WHEN f.price * f.size >= 100000 THEN 'whale'
        WHEN f.price * f.size >= 50000 THEN 'large_trade'
        ELSE 'significant'
    END as trade_class
FROM fills f
JOIN markets m ON f.market_id = m.id
WHERE f.price * f.size >= 25000  -- Minimum threshold for large trades
ORDER BY f.timestamp DESC;

-- Create indexes
CREATE INDEX idx_large_trades_timestamp
ON large_trades(timestamp DESC);

CREATE INDEX idx_large_trades_volume
ON large_trades(volume_usd DESC);

CREATE INDEX idx_large_trades_user
ON large_trades(exchange_id, user_address);

CREATE INDEX idx_large_trades_market
ON large_trades(exchange_id, market_id);

CREATE INDEX idx_large_trades_class
ON large_trades(trade_class);

-- 5. hourly_ingest_stats: For monitoring data ingestion
DROP MATERIALIZED VIEW IF EXISTS hourly_ingest_stats CASCADE;

CREATE MATERIALIZED VIEW hourly_ingest_stats AS
SELECT
    f.exchange_id,
    DATE_TRUNC('hour', f.timestamp) as hour,
    COUNT(*) as total_fills,
    COUNT(DISTINCT f.user_address) as unique_traders,
    COUNT(DISTINCT f.market_id) as active_markets,
    SUM(f.price * f.size) as total_volume,
    MIN(f.timestamp) as first_fill_time,
    MAX(f.timestamp) as last_fill_time,
    -- Distribution by market
    jsonb_object_agg(
        m.symbol,
        jsonb_build_object(
            'count', COUNT(*) FILTER (WHERE m.symbol = m.symbol),
            'volume', SUM(f.price * f.size) FILTER (WHERE m.symbol = m.symbol)
        )
    ) as market_distribution
FROM fills f
JOIN markets m ON f.market_id = m.id
GROUP BY f.exchange_id, DATE_TRUNC('hour', f.timestamp);

-- Create indexes
CREATE UNIQUE INDEX idx_hourly_ingest_stats_unique
ON hourly_ingest_stats(exchange_id, hour);

CREATE INDEX idx_hourly_ingest_stats_hour
ON hourly_ingest_stats(hour DESC);

-- Update the refresh function to include new views
CREATE OR REPLACE FUNCTION refresh_all_materialized_views()
RETURNS void AS $$
BEGIN
    -- Refresh views in dependency order
    REFRESH MATERIALIZED VIEW CONCURRENTLY trader_summary;
    REFRESH MATERIALIZED VIEW CONCURRENTLY trader_market_summary;
    REFRESH MATERIALIZED VIEW CONCURRENTLY daily_market_stats;
    REFRESH MATERIALIZED VIEW CONCURRENTLY large_trades;
    REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_ingest_stats;
    REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_user_stats;
    REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_market_stats;
    REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_exchange_stats;
    REFRESH MATERIALIZED VIEW CONCURRENTLY market_summary;

    -- Log the refresh
    RAISE NOTICE 'Refreshed all materialized views at %', NOW();
END;
$$ LANGUAGE plpgsql;

-- Grant permissions
GRANT SELECT ON trader_summary TO PUBLIC;
GRANT SELECT ON trader_market_summary TO PUBLIC;
GRANT SELECT ON daily_market_stats TO PUBLIC;
GRANT SELECT ON large_trades TO PUBLIC;
GRANT SELECT ON hourly_ingest_stats TO PUBLIC;