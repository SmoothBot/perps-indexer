-- Complete schema for multi-exchange trading data indexer
-- Consolidated migration combining all schema changes from 0001-0008
-- Supports both spot and perpetual markets with comprehensive analytics

-- Extension for UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- EXCHANGES TABLE
-- ============================================================================
CREATE TABLE exchanges (
    id SERIAL PRIMARY KEY,
    code VARCHAR(10) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL,
    is_active BOOLEAN DEFAULT true,
    api_endpoint VARCHAR(255),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Insert initial exchange
INSERT INTO exchanges (code, name, api_endpoint)
VALUES ('HL', 'Hyperliquid', 'https://api.hyperliquid.xyz');

-- ============================================================================
-- MARKETS TABLE
-- ============================================================================
CREATE TABLE markets (
    id SERIAL PRIMARY KEY,
    exchange_id INTEGER NOT NULL REFERENCES exchanges(id),
    market_id VARCHAR(20) NOT NULL,        -- Original ID from exchange (e.g., 'BTC', '@1')
    symbol VARCHAR(50) NOT NULL,           -- Display symbol (e.g., 'BTC-USD', 'PURR/USD')
    market_type VARCHAR(20) NOT NULL CHECK (market_type IN ('spot', 'perp')),
    base_asset VARCHAR(20),                -- e.g., 'BTC', 'PURR'
    quote_asset VARCHAR(20),               -- e.g., 'USD'
    is_active BOOLEAN DEFAULT true,
    decimals INTEGER DEFAULT 8,            -- Price decimals
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(exchange_id, market_id)
);

-- Indexes for markets
CREATE INDEX idx_markets_exchange_id ON markets(exchange_id);
CREATE INDEX idx_markets_market_id ON markets(market_id);
CREATE INDEX idx_markets_market_type ON markets(market_type);
CREATE INDEX idx_markets_symbol ON markets(symbol);
CREATE INDEX idx_markets_active ON markets(exchange_id, is_active) WHERE is_active = true;

-- ============================================================================
-- FILLS TABLE
-- ============================================================================
CREATE TABLE fills (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Relations
    exchange_id INTEGER NOT NULL REFERENCES exchanges(id),
    market_id INTEGER NOT NULL REFERENCES markets(id),

    -- Core trade data
    user_address VARCHAR(66) NOT NULL,
    side VARCHAR(4) NOT NULL CHECK (side IN ('BUY', 'SELL')),
    price NUMERIC(20, 10) NOT NULL,
    size NUMERIC(20, 10) NOT NULL,
    volume_usd NUMERIC(20, 10) GENERATED ALWAYS AS (price * size) STORED,

    -- Fees and PnL
    fee NUMERIC(20, 10),
    closed_pnl NUMERIC(20, 10),

    -- Timing
    timestamp TIMESTAMPTZ NOT NULL,
    block_number BIGINT,

    -- Metadata
    source_id TEXT,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Ensure no duplicates
    CONSTRAINT unique_fill UNIQUE (exchange_id, user_address, market_id, timestamp, price, size)
);

-- Indexes for fills
CREATE INDEX idx_fills_timestamp ON fills(timestamp DESC);
CREATE INDEX idx_fills_exchange_id ON fills(exchange_id);
CREATE INDEX idx_fills_market_id ON fills(market_id);
CREATE INDEX idx_fills_user_timestamp ON fills(user_address, timestamp DESC);
CREATE INDEX idx_fills_market_timestamp ON fills(market_id, timestamp DESC);
CREATE INDEX idx_fills_exchange_market_timestamp ON fills(exchange_id, market_id, timestamp DESC);
CREATE INDEX idx_fills_volume ON fills(volume_usd DESC);
CREATE INDEX idx_fills_block ON fills(block_number) WHERE block_number IS NOT NULL;
CREATE INDEX idx_fills_ingested_at ON fills(ingested_at DESC);

-- Composite indexes for common query patterns
CREATE INDEX idx_fills_exchange_user_timestamp ON fills(exchange_id, user_address, timestamp DESC);

-- ============================================================================
-- OPTIMIZATION INDEXES (from 0005)
-- ============================================================================
-- Index for joining fills with markets and filtering by market_type
CREATE INDEX idx_fills_market_id_timestamp ON fills(market_id, timestamp);

-- Composite index for common query patterns (side-based aggregations)
CREATE INDEX idx_fills_market_id_side_timestamp ON fills(market_id, side, timestamp);

-- Index for user address lookups combined with market_id
CREATE INDEX idx_fills_user_market_timestamp ON fills(user_address, market_id, timestamp);

-- Partial index for non-null closed_pnl values (speeds up PnL calculations)
CREATE INDEX idx_fills_market_pnl ON fills(market_id, timestamp) WHERE closed_pnl IS NOT NULL;

-- ============================================================================
-- DAILY STATS TABLE
-- ============================================================================
CREATE TABLE daily_stats (
    exchange_id INTEGER NOT NULL REFERENCES exchanges(id),
    market_id INTEGER NOT NULL REFERENCES markets(id),
    date DATE NOT NULL,

    -- Volume metrics
    total_volume_usd NUMERIC(20, 2) NOT NULL,
    buy_volume_usd NUMERIC(20, 2) NOT NULL,
    sell_volume_usd NUMERIC(20, 2) NOT NULL,

    -- Trade counts
    total_trades INTEGER NOT NULL,
    unique_traders INTEGER NOT NULL,

    -- Price metrics (OHLC)
    open_price NUMERIC(20, 10),
    high_price NUMERIC(20, 10),
    low_price NUMERIC(20, 10),
    close_price NUMERIC(20, 10),

    -- Metadata
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (exchange_id, market_id, date)
);

CREATE INDEX idx_daily_stats_date ON daily_stats(date DESC);
CREATE INDEX idx_daily_stats_exchange_market ON daily_stats(exchange_id, market_id, date DESC);
CREATE INDEX idx_daily_stats_volume ON daily_stats(total_volume_usd DESC);

-- ============================================================================
-- USER STATS TABLE
-- ============================================================================
CREATE TABLE user_stats (
    exchange_id INTEGER NOT NULL REFERENCES exchanges(id),
    user_address VARCHAR(66) NOT NULL,
    period_start TIMESTAMPTZ NOT NULL,
    period_end TIMESTAMPTZ NOT NULL,

    -- Volume metrics
    total_volume_usd NUMERIC(20, 2) NOT NULL,
    total_trades INTEGER NOT NULL,

    -- PnL metrics
    total_pnl NUMERIC(20, 10),
    total_fees NUMERIC(20, 10),

    -- Metadata
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (exchange_id, user_address, period_start)
);

CREATE INDEX idx_user_stats_volume ON user_stats(total_volume_usd DESC);
CREATE INDEX idx_user_stats_period ON user_stats(period_start DESC);
CREATE INDEX idx_user_stats_exchange ON user_stats(exchange_id, period_start DESC);

-- ============================================================================
-- CHECKPOINTS TABLE
-- ============================================================================
CREATE TABLE ingest_checkpoints (
    exchange_id INTEGER NOT NULL REFERENCES exchanges(id),
    source VARCHAR(50) NOT NULL,
    cursor TEXT,
    last_record_ts TIMESTAMPTZ,
    last_block_number BIGINT,
    records_processed BIGINT NOT NULL DEFAULT 0,
    metadata JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (exchange_id, source)
);

CREATE INDEX idx_checkpoints_exchange_source ON ingest_checkpoints(exchange_id, source);

-- ============================================================================
-- MATERIALIZED VIEWS (from 0006-0008)
-- ============================================================================

-- 1. Enhanced hourly_user_stats
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

CREATE INDEX idx_hourly_user_stats_hour ON hourly_user_stats(hour);
CREATE INDEX idx_hourly_user_stats_user ON hourly_user_stats(user_address, hour);
CREATE INDEX idx_hourly_user_stats_market ON hourly_user_stats(market_id, hour);
CREATE INDEX idx_hourly_user_stats_exchange ON hourly_user_stats(exchange_id, hour);

-- 2. Hourly market-level statistics
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

CREATE INDEX idx_hourly_market_stats_hour ON hourly_market_stats(hour);
CREATE INDEX idx_hourly_market_stats_market ON hourly_market_stats(market_id, hour);
CREATE INDEX idx_hourly_market_stats_symbol ON hourly_market_stats(symbol, hour);
CREATE INDEX idx_hourly_market_stats_type ON hourly_market_stats(market_type, hour);

-- 3. Hourly exchange-level statistics
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

CREATE INDEX idx_hourly_exchange_stats_hour ON hourly_exchange_stats(hour);
CREATE INDEX idx_hourly_exchange_stats_exchange ON hourly_exchange_stats(exchange_id, hour);

-- 4. Market summary view (from 0007)
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
CREATE UNIQUE INDEX idx_market_summary_unique ON market_summary(id);
CREATE INDEX idx_market_summary_exchange ON market_summary(exchange_id);
CREATE INDEX idx_market_summary_symbol ON market_summary(symbol);
CREATE INDEX idx_market_summary_type ON market_summary(market_type);
CREATE INDEX idx_market_summary_active ON market_summary(is_active);
CREATE INDEX idx_market_summary_volume ON market_summary(total_volume DESC);

-- 5. Trader analytics views (from 0008)

-- trader_summary: Comprehensive trader statistics
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
CREATE UNIQUE INDEX idx_trader_summary_unique ON trader_summary(exchange_id, user_address);
CREATE INDEX idx_trader_summary_volume ON trader_summary(total_volume DESC);
CREATE INDEX idx_trader_summary_pnl ON trader_summary(total_pnl DESC);
CREATE INDEX idx_trader_summary_trades ON trader_summary(total_trades DESC);

-- trader_market_summary: Per-trader, per-market statistics
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

CREATE INDEX idx_trader_market_summary_user ON trader_market_summary(exchange_id, user_address);
CREATE INDEX idx_trader_market_summary_market ON trader_market_summary(exchange_id, market_id);
CREATE INDEX idx_trader_market_summary_volume ON trader_market_summary(total_volume DESC);

-- daily_market_stats: Daily aggregated market statistics
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

CREATE INDEX idx_daily_market_stats_date ON daily_market_stats(trade_date DESC);
CREATE INDEX idx_daily_market_stats_volume ON daily_market_stats(total_volume DESC);

-- large_trades: Cache of significant trades for whale tracking
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
CREATE INDEX idx_large_trades_timestamp ON large_trades(timestamp DESC);
CREATE INDEX idx_large_trades_volume ON large_trades(volume_usd DESC);
CREATE INDEX idx_large_trades_user ON large_trades(exchange_id, user_address);
CREATE INDEX idx_large_trades_market ON large_trades(exchange_id, market_id);
CREATE INDEX idx_large_trades_class ON large_trades(trade_class);

-- hourly_ingest_stats: For monitoring data ingestion
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

CREATE INDEX idx_hourly_ingest_stats_hour ON hourly_ingest_stats(hour DESC);

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Function to get or create a market
CREATE OR REPLACE FUNCTION get_or_create_market(
    p_exchange_id INTEGER,
    p_market_id VARCHAR(20)
) RETURNS INTEGER AS $$
DECLARE
    v_market_pk INTEGER;
BEGIN
    -- Check if market exists
    SELECT id INTO v_market_pk
    FROM markets
    WHERE exchange_id = p_exchange_id AND market_id = p_market_id;

    IF v_market_pk IS NOT NULL THEN
        RETURN v_market_pk;
    END IF;

    -- Market doesn't exist, create with placeholder values
    -- The application will update with proper data from API
    INSERT INTO markets (
        exchange_id,
        market_id,
        symbol,
        market_type,
        base_asset,
        quote_asset
    ) VALUES (
        p_exchange_id,
        p_market_id,
        p_market_id, -- Use market_id as placeholder symbol
        CASE WHEN p_market_id LIKE '@%' THEN 'spot' ELSE 'perp' END,
        p_market_id,
        'USD'
    )
    ON CONFLICT (exchange_id, market_id) DO UPDATE
        SET updated_at = NOW()
    RETURNING id INTO v_market_pk;

    RETURN v_market_pk;
END;
$$ LANGUAGE plpgsql;

-- Function to refresh all materialized views
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

-- ============================================================================
-- PERMISSIONS
-- ============================================================================
GRANT SELECT ON hourly_user_stats TO PUBLIC;
GRANT SELECT ON hourly_market_stats TO PUBLIC;
GRANT SELECT ON hourly_exchange_stats TO PUBLIC;
GRANT SELECT ON market_summary TO PUBLIC;
GRANT SELECT ON trader_summary TO PUBLIC;
GRANT SELECT ON trader_market_summary TO PUBLIC;
GRANT SELECT ON daily_market_stats TO PUBLIC;
GRANT SELECT ON large_trades TO PUBLIC;
GRANT SELECT ON hourly_ingest_stats TO PUBLIC;

-- ============================================================================
-- COMMENTS
-- ============================================================================
COMMENT ON TABLE exchanges IS 'Trading exchanges/venues';
COMMENT ON TABLE markets IS 'Trading markets/instruments with metadata';
COMMENT ON TABLE fills IS 'Individual trade fills/executions';
COMMENT ON TABLE daily_stats IS 'Pre-aggregated daily statistics per market';
COMMENT ON TABLE user_stats IS 'User trading statistics aggregated by period';
COMMENT ON TABLE ingest_checkpoints IS 'Ingestion progress tracking for resumability';

COMMENT ON COLUMN markets.market_id IS 'Original market ID from exchange (e.g., BTC for perps, @1 for spot)';
COMMENT ON COLUMN markets.symbol IS 'Human-readable symbol (e.g., BTC-USD for perps, PURR/USD for spot)';
COMMENT ON COLUMN markets.market_type IS 'Type of market: spot or perp';
COMMENT ON COLUMN fills.volume_usd IS 'Computed USD volume (price * size)';
COMMENT ON COLUMN fills.closed_pnl IS 'Realized PnL for perpetual markets';