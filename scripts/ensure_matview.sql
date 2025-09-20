-- Ensure the materialized view exists
DO $$
BEGIN
    -- Check if the materialized view exists
    IF NOT EXISTS (
        SELECT 1
        FROM pg_matviews
        WHERE schemaname = 'public'
        AND matviewname = 'hl_hourly_user_stats'
    ) THEN
        -- Create the materialized view
        CREATE MATERIALIZED VIEW hl_hourly_user_stats AS
        SELECT
            user_address,
            DATE_TRUNC('hour', timestamp) AS hour,
            coin,
            COUNT(*) AS trade_count,
            SUM(price * size) AS volume,
            SUM(closed_pnl) AS total_pnl,
            SUM(fee) AS total_fees
        FROM hl_fills
        GROUP BY user_address, DATE_TRUNC('hour', timestamp), coin;

        -- Create unique index for CONCURRENTLY refresh
        CREATE UNIQUE INDEX idx_hl_hourly_user_stats_unique
        ON hl_hourly_user_stats (user_address, hour, coin);

        -- Create additional indexes for performance
        CREATE INDEX idx_hl_hourly_user_stats_hour ON hl_hourly_user_stats(hour);
        CREATE INDEX idx_hl_hourly_user_stats_user ON hl_hourly_user_stats(user_address);
        CREATE INDEX idx_hl_hourly_user_stats_coin ON hl_hourly_user_stats(coin);

        RAISE NOTICE 'Materialized view hl_hourly_user_stats created successfully';
    ELSE
        RAISE NOTICE 'Materialized view hl_hourly_user_stats already exists';
    END IF;
END $$;