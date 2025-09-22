-- Migration: Create market_summary materialized view for fast market overview queries
-- This view pre-aggregates all market statistics to avoid expensive JOINs with the fills table

DROP MATERIALIZED VIEW IF EXISTS market_summary CASCADE;

CREATE MATERIALIZED VIEW market_summary AS
SELECT
    m.id,
    m.exchange_id,
    m.market_id,
    m.symbol,
    m.market_type,
    m.base_asset,
    m.quote_asset,
    m.is_active,
    m.created_at as market_created_at,
    -- Aggregated statistics from fills
    COALESCE(stats.total_trades, 0) as total_trades,
    COALESCE(stats.unique_traders, 0) as unique_traders,
    COALESCE(stats.total_volume, 0) as total_volume,
    COALESCE(stats.buy_volume, 0) as buy_volume,
    COALESCE(stats.sell_volume, 0) as sell_volume,
    COALESCE(stats.avg_trade_size, 0) as avg_trade_size,
    COALESCE(stats.max_trade_size, 0) as max_trade_size,
    COALESCE(stats.min_trade_size, 0) as min_trade_size,
    COALESCE(stats.total_fees, 0) as total_fees,
    COALESCE(stats.total_pnl, 0) as total_pnl,
    stats.last_trade_time,
    stats.first_trade_time,
    -- 24h statistics
    COALESCE(stats_24h.volume_24h, 0) as volume_24h,
    COALESCE(stats_24h.trades_24h, 0) as trades_24h,
    COALESCE(stats_24h.unique_traders_24h, 0) as unique_traders_24h,
    -- 7d statistics
    COALESCE(stats_7d.volume_7d, 0) as volume_7d,
    COALESCE(stats_7d.trades_7d, 0) as trades_7d,
    COALESCE(stats_7d.unique_traders_7d, 0) as unique_traders_7d,
    -- 30d statistics
    COALESCE(stats_30d.volume_30d, 0) as volume_30d,
    COALESCE(stats_30d.trades_30d, 0) as trades_30d,
    COALESCE(stats_30d.unique_traders_30d, 0) as unique_traders_30d
FROM markets m
-- All-time statistics
LEFT JOIN (
    SELECT
        f.market_id,
        COUNT(*) as total_trades,
        COUNT(DISTINCT f.user_address) as unique_traders,
        SUM(f.price * f.size) as total_volume,
        SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE 0 END) as buy_volume,
        SUM(CASE WHEN f.side = 'SELL' THEN f.price * f.size ELSE 0 END) as sell_volume,
        AVG(f.price * f.size) as avg_trade_size,
        MAX(f.price * f.size) as max_trade_size,
        MIN(f.price * f.size) as min_trade_size,
        SUM(COALESCE(f.fee, 0)) as total_fees,
        SUM(COALESCE(f.closed_pnl, 0)) as total_pnl,
        MAX(f.timestamp) as last_trade_time,
        MIN(f.timestamp) as first_trade_time
    FROM fills f
    GROUP BY f.market_id
) stats ON m.id = stats.market_id
-- 24h statistics
LEFT JOIN (
    SELECT
        f.market_id,
        SUM(f.price * f.size) as volume_24h,
        COUNT(*) as trades_24h,
        COUNT(DISTINCT f.user_address) as unique_traders_24h
    FROM fills f
    WHERE f.timestamp >= NOW() - INTERVAL '24 hours'
    GROUP BY f.market_id
) stats_24h ON m.id = stats_24h.market_id
-- 7d statistics
LEFT JOIN (
    SELECT
        f.market_id,
        SUM(f.price * f.size) as volume_7d,
        COUNT(*) as trades_7d,
        COUNT(DISTINCT f.user_address) as unique_traders_7d
    FROM fills f
    WHERE f.timestamp >= NOW() - INTERVAL '7 days'
    GROUP BY f.market_id
) stats_7d ON m.id = stats_7d.market_id
-- 30d statistics
LEFT JOIN (
    SELECT
        f.market_id,
        SUM(f.price * f.size) as volume_30d,
        COUNT(*) as trades_30d,
        COUNT(DISTINCT f.user_address) as unique_traders_30d
    FROM fills f
    WHERE f.timestamp >= NOW() - INTERVAL '30 days'
    GROUP BY f.market_id
) stats_30d ON m.id = stats_30d.market_id;

-- Create indexes for efficient querying
CREATE UNIQUE INDEX idx_market_summary_unique
ON market_summary(id);

CREATE INDEX idx_market_summary_exchange
ON market_summary(exchange_id);

CREATE INDEX idx_market_summary_symbol
ON market_summary(symbol);

CREATE INDEX idx_market_summary_type
ON market_summary(market_type);

CREATE INDEX idx_market_summary_active
ON market_summary(is_active);

CREATE INDEX idx_market_summary_volume
ON market_summary(total_volume DESC);

-- Update the refresh function to include market_summary
CREATE OR REPLACE FUNCTION refresh_all_materialized_views()
RETURNS void AS $$
BEGIN
    -- Refresh views in dependency order
    REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_user_stats;
    REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_market_stats;
    REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_exchange_stats;
    REFRESH MATERIALIZED VIEW CONCURRENTLY market_summary;

    -- Log the refresh
    RAISE NOTICE 'Refreshed all materialized views at %', NOW();
END;
$$ LANGUAGE plpgsql;

-- Grant permissions
GRANT SELECT ON market_summary TO PUBLIC;