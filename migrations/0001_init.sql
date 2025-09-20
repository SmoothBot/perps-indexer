-- Initial schema for Hyperliquid historical data indexer
--
-- Design principles:
-- 1. Optimized for analytic queries with proper indexing
-- 2. Idempotent writes via ON CONFLICT clauses
-- 3. Checkpoint tracking for resumable ingestion
-- 4. Partitioning-ready structure (can be added later)

-- Extension for UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Main table for storing historical trade/fill data
CREATE TABLE IF NOT EXISTS hl_fills (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Core trade data
    user_address TEXT NOT NULL,
    coin TEXT NOT NULL,
    side TEXT NOT NULL CHECK (side IN ('BUY', 'SELL')),
    price NUMERIC(20, 8) NOT NULL,
    size NUMERIC(20, 8) NOT NULL,
    volume_usd NUMERIC(20, 2) GENERATED ALWAYS AS (price * size) STORED,

    -- Fees and PnL
    fee NUMERIC(20, 8),
    closed_pnl NUMERIC(20, 8),

    -- Timing
    timestamp TIMESTAMPTZ NOT NULL,
    block_number BIGINT,

    -- Metadata
    source_id TEXT, -- External ID from source system
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Ensure no duplicates
    CONSTRAINT unique_fill UNIQUE (user_address, coin, timestamp, price, size)
);

-- Indexes for common query patterns
CREATE INDEX idx_hl_fills_timestamp ON hl_fills(timestamp DESC);
CREATE INDEX idx_hl_fills_user_timestamp ON hl_fills(user_address, timestamp DESC);
CREATE INDEX idx_hl_fills_coin_timestamp ON hl_fills(coin, timestamp DESC);
CREATE INDEX idx_hl_fills_volume ON hl_fills(volume_usd DESC);
CREATE INDEX idx_hl_fills_block ON hl_fills(block_number) WHERE block_number IS NOT NULL;
CREATE INDEX idx_hl_fills_ingested_at ON hl_fills(ingested_at DESC);

-- Aggregated daily statistics (materialized for performance)
CREATE TABLE IF NOT EXISTS hl_daily_stats (
    date DATE NOT NULL,
    coin TEXT NOT NULL,

    -- Volume metrics
    total_volume_usd NUMERIC(20, 2) NOT NULL,
    buy_volume_usd NUMERIC(20, 2) NOT NULL,
    sell_volume_usd NUMERIC(20, 2) NOT NULL,

    -- Trade counts
    total_trades INTEGER NOT NULL,
    unique_traders INTEGER NOT NULL,

    -- Price metrics
    open_price NUMERIC(20, 8),
    high_price NUMERIC(20, 8),
    low_price NUMERIC(20, 8),
    close_price NUMERIC(20, 8),

    -- Metadata
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (date, coin)
);

CREATE INDEX idx_hl_daily_stats_date ON hl_daily_stats(date DESC);
CREATE INDEX idx_hl_daily_stats_volume ON hl_daily_stats(total_volume_usd DESC);

-- User statistics table
CREATE TABLE IF NOT EXISTS hl_user_stats (
    user_address TEXT NOT NULL,
    period_start TIMESTAMPTZ NOT NULL,
    period_end TIMESTAMPTZ NOT NULL,

    -- Volume metrics
    total_volume_usd NUMERIC(20, 2) NOT NULL,
    total_trades INTEGER NOT NULL,

    -- PnL metrics
    total_pnl NUMERIC(20, 8),
    total_fees NUMERIC(20, 8),

    -- Metadata
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (user_address, period_start)
);

CREATE INDEX idx_hl_user_stats_volume ON hl_user_stats(total_volume_usd DESC);
CREATE INDEX idx_hl_user_stats_period ON hl_user_stats(period_start DESC);

-- Checkpoint tracking for resumable ingestion
CREATE TABLE IF NOT EXISTS ingest_checkpoints (
    source TEXT PRIMARY KEY,
    cursor TEXT, -- Opaque cursor from data source
    last_record_ts TIMESTAMPTZ,
    last_block_number BIGINT,
    records_processed BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB -- Additional checkpoint data
);

-- Add comments for documentation
COMMENT ON TABLE hl_fills IS 'Historical fill/trade data from Hyperliquid';
COMMENT ON TABLE hl_daily_stats IS 'Pre-aggregated daily statistics for performance';
COMMENT ON TABLE hl_user_stats IS 'User trading statistics aggregated by period';
COMMENT ON TABLE ingest_checkpoints IS 'Ingestion progress tracking for resumability';

COMMENT ON COLUMN hl_fills.source_id IS 'External ID from the source system for deduplication';
COMMENT ON COLUMN hl_fills.volume_usd IS 'Computed USD volume (price * size)';
COMMENT ON COLUMN ingest_checkpoints.cursor IS 'Opaque pagination cursor from the data source';
COMMENT ON COLUMN ingest_checkpoints.metadata IS 'Additional checkpoint data (e.g., rate limit state)';