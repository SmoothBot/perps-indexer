# Hyperliquid Indexer Database Schema

## Overview
This document describes the PostgreSQL database schema used by the Hyperliquid historical data indexer. All timestamps are stored in UTC.

## Tables

### 1. `hl_fills`
Historical fill/trade data from Hyperliquid.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | UUID | PRIMARY KEY, DEFAULT gen_random_uuid() | Unique identifier for each fill |
| `user_address` | VARCHAR(255) | NOT NULL | Ethereum address of the trader |
| `coin` | VARCHAR(50) | NOT NULL | Trading pair/coin symbol |
| `side` | VARCHAR(10) | NOT NULL | Trade side: 'BUY' or 'SELL' |
| `price` | DECIMAL(30,10) | NOT NULL | Execution price |
| `size` | DECIMAL(30,10) | NOT NULL | Trade size/volume |
| `fee` | DECIMAL(30,10) | NULL | Trading fee paid |
| `closed_pnl` | DECIMAL(30,10) | NULL | Realized PnL from closed positions |
| `timestamp` | TIMESTAMPTZ | NOT NULL | Trade execution timestamp |
| `block_number` | BIGINT | NULL | Blockchain block number |
| `source_id` | VARCHAR(255) | NULL | Source identifier for data tracking |
| `ingested_at` | TIMESTAMPTZ | DEFAULT NOW() | When the record was inserted |

**Indexes:**
- `idx_fills_user_timestamp`: ON (user_address, timestamp DESC)
- `idx_fills_coin_timestamp`: ON (coin, timestamp DESC)
- `idx_fills_timestamp`: ON (timestamp DESC)
- `idx_fills_block`: ON (block_number) WHERE block_number IS NOT NULL
- **UNIQUE**: ON (user_address, coin, timestamp, price, size) - Prevents duplicate fills

### 2. `hl_daily_stats`
Pre-aggregated daily statistics per coin.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `date` | DATE | NOT NULL | Trading date |
| `coin` | VARCHAR(50) | NOT NULL | Trading pair/coin symbol |
| `total_volume_usd` | DECIMAL(30,10) | | Total daily volume in USD |
| `buy_volume_usd` | DECIMAL(30,10) | | Total buy volume in USD |
| `sell_volume_usd` | DECIMAL(30,10) | | Total sell volume in USD |
| `total_trades` | INT | | Number of trades |
| `unique_traders` | INT | | Number of unique traders |
| `open_price` | DECIMAL(30,10) | | Opening price (first trade) |
| `high_price` | DECIMAL(30,10) | | Highest price of the day |
| `low_price` | DECIMAL(30,10) | | Lowest price of the day |
| `close_price` | DECIMAL(30,10) | | Closing price (last trade) |
| `updated_at` | TIMESTAMPTZ | DEFAULT NOW() | Last update timestamp |

**Constraints:**
- PRIMARY KEY: (date, coin)

**Indexes:**
- `idx_daily_stats_coin_date`: ON (coin, date DESC)

### 3. `hl_user_stats`
User trading statistics for specified time periods.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `user_address` | VARCHAR(255) | NOT NULL | Ethereum address of the trader |
| `period_start` | TIMESTAMPTZ | NOT NULL | Start of the statistics period |
| `period_end` | TIMESTAMPTZ | NOT NULL | End of the statistics period |
| `total_volume_usd` | DECIMAL(30,10) | | Total trading volume in USD |
| `total_trades` | INT | | Number of trades executed |
| `total_pnl` | DECIMAL(30,10) | | Total realized PnL |
| `total_fees` | DECIMAL(30,10) | | Total fees paid |
| `updated_at` | TIMESTAMPTZ | DEFAULT NOW() | Last update timestamp |

**Constraints:**
- PRIMARY KEY: (user_address, period_start, period_end)

**Indexes:**
- `idx_user_stats_address`: ON (user_address)
- `idx_user_stats_period`: ON (period_start, period_end)

### 4. `ingest_checkpoints`
Tracks ingestion progress for resumable processing.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `source` | VARCHAR(50) | PRIMARY KEY | Data source identifier (e.g., 's3', 'hl_http') |
| `cursor` | TEXT | | Pagination cursor for resuming |
| `last_record_ts` | TIMESTAMPTZ | | Timestamp of last processed record |
| `last_block_number` | BIGINT | | Last processed block number |
| `records_processed` | BIGINT | DEFAULT 0 | Total records processed |
| `updated_at` | TIMESTAMPTZ | DEFAULT NOW() | Last checkpoint update |
| `metadata` | JSONB | | Additional metadata (flexible storage) |

### 5. `hl_hourly_user_stats` (Materialized View)
Pre-aggregated hourly statistics per user and coin for fast analytics.

| Column | Type | Description |
|--------|------|-------------|
| `user_address` | VARCHAR(255) | Ethereum address of the trader |
| `hour` | TIMESTAMPTZ | Hour bucket (truncated timestamp) |
| `coin` | VARCHAR(50) | Trading pair/coin symbol |
| `trade_count` | BIGINT | Number of trades in the hour |
| `volume` | NUMERIC | Total trading volume (price * size) |
| `total_pnl` | NUMERIC | Sum of realized PnL |
| `total_fees` | NUMERIC | Sum of fees paid |
| `avg_price` | NUMERIC | Average trade price |
| `max_price` | NUMERIC | Maximum trade price |
| `min_price` | NUMERIC | Minimum trade price |
| `buy_volume` | NUMERIC | Total buy volume |
| `sell_volume` | NUMERIC | Total sell volume |
| `buy_count` | BIGINT | Number of buy trades |
| `sell_count` | BIGINT | Number of sell trades |

**Indexes:**
- `idx_hourly_user_stats_user_hour`: ON (user_address, hour DESC)
- `idx_hourly_user_stats_hour`: ON (hour DESC)
- `idx_hourly_user_stats_coin_hour`: ON (coin, hour DESC)
- `idx_hourly_user_stats_user_coin_hour`: ON (user_address, coin, hour DESC)
- `idx_hourly_user_stats_unique`: UNIQUE ON (user_address, hour, coin) - Enables concurrent refresh

## Data Types

### Trade Side Values
- `'BUY'` - Buy order/long position
- `'SELL'` - Sell order/short position

### Source Identifiers
- `'s3'` - Data ingested from AWS S3 historical data
- `'hl_http'` - Data from HTTP API (deprecated)

## Common Queries

### Get recent fills for a user
```sql
SELECT * FROM hl_fills
WHERE user_address = '0x...'
ORDER BY timestamp DESC
LIMIT 100;
```

### Get daily volume for a coin
```sql
SELECT date, total_volume_usd, total_trades
FROM hl_daily_stats
WHERE coin = 'BTC-USD'
ORDER BY date DESC
LIMIT 30;
```

### Get top traders by volume
```sql
SELECT
    user_address,
    COUNT(*) as trade_count,
    SUM(price * size) as total_volume
FROM hl_fills
WHERE timestamp >= NOW() - INTERVAL '7 days'
GROUP BY user_address
ORDER BY total_volume DESC
LIMIT 100;
```

### Get hourly volume (using materialized view - fast)
```sql
SELECT
    hour,
    coin,
    trade_count,
    volume
FROM hl_hourly_user_stats
WHERE hour >= NOW() - INTERVAL '24 hours'
GROUP BY hour, coin, trade_count, volume
ORDER BY hour DESC, volume DESC;
```

### Get user's hourly performance
```sql
SELECT
    hour,
    coin,
    trade_count,
    volume,
    total_pnl,
    total_fees,
    buy_volume,
    sell_volume
FROM hl_hourly_user_stats
WHERE user_address = '0x...'
  AND hour >= NOW() - INTERVAL '7 days'
ORDER BY hour DESC;
```

### Get top performing hours by PnL
```sql
SELECT
    hour,
    SUM(total_pnl) as hour_pnl,
    SUM(volume) as hour_volume,
    SUM(trade_count) as total_trades,
    COUNT(DISTINCT user_address) as active_users
FROM hl_hourly_user_stats
WHERE hour >= NOW() - INTERVAL '30 days'
GROUP BY hour
ORDER BY hour_pnl DESC
LIMIT 100;
```

## Notes

1. **Decimal Precision**: All price and volume fields use DECIMAL(30,10) for high precision to handle both very large and very small values accurately.

2. **Deduplication**: The unique constraint on `hl_fills` prevents duplicate entries based on user, coin, timestamp, price, and size combination.

3. **Partitioning**: For production deployments with large data volumes, consider partitioning `hl_fills` by month:
   ```sql
   CREATE TABLE hl_fills_2025_01 PARTITION OF hl_fills
   FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
   ```

4. **Indexing Strategy**: Indexes are optimized for common query patterns:
   - Time-based queries (most recent data)
   - User-specific queries
   - Coin-specific analytics

5. **Checkpoint System**: The `ingest_checkpoints` table enables resumable ingestion, tracking progress per data source to handle interruptions gracefully.

## Data Freshness

- Historical data is ingested from S3 buckets with hourly granularity
- Checkpoints are saved every 60 seconds during ingestion
- Daily stats can be regenerated from fills data using the `update_daily_stats` stored procedure
- Hourly user stats materialized view should be refreshed after backfill operations:
  ```sql
  -- Refresh the materialized view (non-blocking)
  SELECT refresh_hourly_user_stats();

  -- Or manually with SQL
  REFRESH MATERIALIZED VIEW CONCURRENTLY hl_hourly_user_stats;
  ```