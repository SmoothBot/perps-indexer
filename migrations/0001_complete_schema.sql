-- Complete schema for multi-exchange trading data indexer
-- Supports both spot and perpetual markets

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
-- MATERIALIZED VIEWS
-- ============================================================================

-- Hourly aggregated statistics
CREATE MATERIALIZED VIEW hourly_user_stats AS
SELECT
    f.exchange_id,
    f.market_id,
    m.market_type,
    f.user_address,
    DATE_TRUNC('hour', f.timestamp) AS hour,
    COUNT(*) AS trade_count,
    SUM(f.volume_usd) AS volume,
    SUM(f.closed_pnl) AS total_pnl,
    SUM(f.fee) AS total_fees,
    AVG(f.price) AS avg_price,
    MIN(f.price) AS min_price,
    MAX(f.price) AS max_price
FROM fills f
JOIN markets m ON f.market_id = m.id
GROUP BY f.exchange_id, f.market_id, m.market_type, f.user_address, DATE_TRUNC('hour', f.timestamp);

CREATE INDEX idx_hourly_user_stats_exchange_hour ON hourly_user_stats(exchange_id, hour DESC);
CREATE INDEX idx_hourly_user_stats_market ON hourly_user_stats(market_id, hour DESC);
CREATE INDEX idx_hourly_user_stats_user ON hourly_user_stats(user_address, hour DESC);
CREATE INDEX idx_hourly_user_stats_market_type ON hourly_user_stats(market_type, hour DESC);

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