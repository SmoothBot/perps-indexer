use crate::market::MarketRegistry;
use crate::model::{Checkpoint, Fill};
use chrono::{DateTime, Utc};
use indexer_core::Result;
use bigdecimal::BigDecimal;
use std::str::FromStr;
use std::sync::Arc;
use metrics::counter;
use sqlx::PgPool;
use tracing::{debug, info, warn, instrument};

pub struct Store {
    pool: PgPool,
    exchange_id: i32,
    market_registry: Arc<MarketRegistry>,
}

impl Store {
    pub async fn new(pool: PgPool) -> Result<Self> {
        // Get Hyperliquid exchange ID
        let exchange_id: i32 = sqlx::query_scalar(
            "SELECT id FROM exchanges WHERE code = 'HL'"
        )
        .fetch_one(&pool)
        .await?;

        // Create market registry
        let market_registry = Arc::new(MarketRegistry::new(pool.clone(), exchange_id).await?);

        Ok(Self {
            pool,
            exchange_id,
            market_registry,
        })
    }

    #[instrument(skip(self, fills))]
    pub async fn insert_fills(&self, fills: &[Fill]) -> Result<usize> {
        if fills.is_empty() {
            return Ok(0);
        }

        // Process in large chunks for better throughput
        const CHUNK_SIZE: usize = 50000; // Optimal chunk size for PostgreSQL
        let mut total_inserted = 0;

        for chunk in fills.chunks(CHUNK_SIZE) {
            let inserted = self.bulk_insert_fills_chunk(chunk).await?;
            total_inserted += inserted;
        }

        counter!("indexer_fills_inserted", "source" => "s3").increment(total_inserted as u64);

        debug!(
            total = fills.len(),
            inserted = total_inserted,
            duplicates = fills.len() - total_inserted,
            "Inserted fills"
        );

        // Refresh materialized view after inserting fills
        if total_inserted > 0 {
            self.refresh_hourly_stats_view().await?;
        }

        Ok(total_inserted)
    }

    async fn bulk_insert_fills_chunk(&self, fills: &[Fill]) -> Result<usize> {
        // Use PostgreSQL COPY for maximum performance
        // First try COPY, fallback to multi-row VALUES if needed
        match self.bulk_insert_with_copy(fills).await {
            Ok(count) => Ok(count),
            Err(e) => {
                debug!("COPY failed, using multi-row VALUES: {:?}", e);
                self.bulk_insert_with_values_optimized(fills).await
            }
        }
    }

    async fn bulk_insert_with_copy(&self, fills: &[Fill]) -> Result<usize> {
        use sqlx::Connection;

        let mut conn = self.pool.acquire().await?;
        let mut tx = conn.begin().await?;

        // Use COPY with a temporary table to handle conflicts
        sqlx::query(
            r#"
            CREATE TEMP TABLE temp_fills (
                exchange_id INTEGER NOT NULL,
                market_id INTEGER NOT NULL,
                user_address VARCHAR(66) NOT NULL,
                side VARCHAR(4) NOT NULL,
                price NUMERIC(20, 10) NOT NULL,
                size NUMERIC(20, 10) NOT NULL,
                fee NUMERIC(20, 10),
                closed_pnl NUMERIC(20, 10),
                timestamp TIMESTAMPTZ NOT NULL,
                block_number BIGINT,
                source_id VARCHAR(100)
            ) ON COMMIT DROP
            "#
        )
        .execute(&mut *tx)
        .await?;

        // Use COPY to bulk insert data
        let copy_query = r#"COPY temp_fills (exchange_id, market_id, user_address, side, price, size, fee, closed_pnl, timestamp, block_number, source_id) FROM STDIN WITH (FORMAT csv, NULL '\N')"#;

        let mut copy_in = tx.copy_in_raw(copy_query).await?;

        // Build CSV data
        let mut csv_data = String::new();
        for fill in fills {
            // Get or create market
            let market_id = self.market_registry.get_or_create_market(&fill.coin).await?;

            use std::fmt::Write;
            write!(
                csv_data,
                "{},{},{},{},{},{},{},{},{},{},{}\n",
                self.exchange_id,
                market_id,
                fill.user_address,
                fill.side,
                fill.price,
                fill.size,
                fill.fee.map_or("\\N".to_string(), |f| f.to_string()),
                fill.closed_pnl.map_or("\\N".to_string(), |p| p.to_string()),
                fill.timestamp.to_rfc3339(),
                fill.block_number.map_or("\\N".to_string(), |b| b.to_string()),
                fill.source_id.as_deref().unwrap_or("\\N")
            ).map_err(|e| indexer_core::Error::Io(std::io::Error::new(std::io::ErrorKind::Other, e)))?;
        }

        copy_in.send(csv_data.as_bytes()).await?;
        copy_in.finish().await?;

        // Insert from temp table with conflict handling
        // Note: We need to specify columns explicitly since fills has an auto-generated id
        let result = sqlx::query(
            r#"
            INSERT INTO fills (exchange_id, market_id, user_address, side, price, size, fee, closed_pnl, timestamp, block_number, source_id)
            SELECT exchange_id, market_id, user_address, side, price, size, fee, closed_pnl, timestamp, block_number, source_id
            FROM temp_fills
            ON CONFLICT (exchange_id, user_address, market_id, timestamp, price, size)
            DO NOTHING
            "#
        )
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;

        Ok(result.rows_affected() as usize)
    }

    async fn bulk_insert_with_values_optimized(&self, fills: &[Fill]) -> Result<usize> {
        // Optimized multi-row VALUES with safe batch size
        // PostgreSQL has a limit of 65535 parameters, and we use 11 params per row
        const BATCH_SIZE: usize = 5000; // Safe batch size: 5000 * 11 = 55,000 params
        let mut total_inserted = 0;

        for batch in fills.chunks(BATCH_SIZE) {
            let mut tx = self.pool.begin().await?;

            // Build multi-row insert query
            // Get market IDs for all coins in batch first
            let mut market_ids = Vec::with_capacity(batch.len());
            for fill in batch {
                let market_id = self.market_registry.get_or_create_market(&fill.coin).await?;
                market_ids.push(market_id);
            }

            let mut values_strings = Vec::with_capacity(batch.len());
            let mut param_index = 1;

            for _ in batch {
                let placeholders: Vec<String> = (0..11)
                    .map(|i| format!("${}", param_index + i))
                    .collect();
                values_strings.push(format!("({})", placeholders.join(", ")));
                param_index += 11;
            }

            let query_string = format!(
                r#"
                INSERT INTO fills (
                    exchange_id, market_id, user_address, side, price, size,
                    fee, closed_pnl, timestamp, block_number, source_id
                ) VALUES {}
                ON CONFLICT (exchange_id, user_address, market_id, timestamp, price, size)
                DO NOTHING
                "#,
                values_strings.join(", ")
            );

            let mut query = sqlx::query(&query_string);

            // Bind all parameters
            for (fill, market_id) in batch.iter().zip(market_ids.iter()) {
                query = query
                    .bind(self.exchange_id)
                    .bind(market_id)
                    .bind(&fill.user_address)
                    .bind(fill.side.to_string())
                    .bind(BigDecimal::from_str(&fill.price.to_string()).ok())
                    .bind(BigDecimal::from_str(&fill.size.to_string()).ok())
                    .bind(fill.fee.and_then(|f| BigDecimal::from_str(&f.to_string()).ok()))
                    .bind(fill.closed_pnl.and_then(|p| BigDecimal::from_str(&p.to_string()).ok()))
                    .bind(fill.timestamp)
                    .bind(fill.block_number)
                    .bind(fill.source_id.as_deref());
            }

            let result = query.execute(&mut *tx).await?;
            total_inserted += result.rows_affected() as usize;

            tx.commit().await?;
        }

        Ok(total_inserted)
    }


    #[instrument(skip(self))]
    pub async fn get_checkpoint(&self, source: &str) -> Result<Option<Checkpoint>> {
        let checkpoint = sqlx::query_as!(
            Checkpoint,
            r#"
            SELECT source, cursor, last_record_ts, last_block_number,
                   records_processed, updated_at as "updated_at!", metadata
            FROM ingest_checkpoints
            WHERE exchange_id = $1 AND source = $2
            "#,
            self.exchange_id,
            source
        )
        .fetch_optional(&self.pool)
        .await?;

        Ok(checkpoint)
    }

    #[instrument(skip(self))]
    pub async fn save_checkpoint(&self, checkpoint: &Checkpoint) -> Result<()> {
        sqlx::query!(
            r#"
            INSERT INTO ingest_checkpoints (
                exchange_id, source, cursor, last_record_ts, last_block_number,
                records_processed, updated_at, metadata
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            ON CONFLICT (exchange_id, source) DO UPDATE SET
                cursor = EXCLUDED.cursor,
                last_record_ts = EXCLUDED.last_record_ts,
                last_block_number = EXCLUDED.last_block_number,
                records_processed = EXCLUDED.records_processed,
                updated_at = EXCLUDED.updated_at,
                metadata = EXCLUDED.metadata
            "#,
            self.exchange_id,
            checkpoint.source,
            checkpoint.cursor,
            checkpoint.last_record_ts,
            checkpoint.last_block_number,
            checkpoint.records_processed,
            checkpoint.updated_at,
            checkpoint.metadata
        )
        .execute(&self.pool)
        .await?;

        counter!("indexer_checkpoints_saved").increment(1);

        debug!(
            source = checkpoint.source,
            records = checkpoint.records_processed,
            "Saved checkpoint"
        );

        Ok(())
    }

    #[instrument(skip(self))]
    pub async fn get_latest_fill_timestamp(&self) -> Result<Option<DateTime<Utc>>> {
        let result = sqlx::query!(
            r#"
            SELECT MAX(timestamp) as "max_timestamp"
            FROM fills
            WHERE exchange_id = $1
            "#,
            self.exchange_id
        )
        .fetch_one(&self.pool)
        .await?;

        Ok(result.max_timestamp)
    }

    #[instrument(skip(self))]
    pub async fn check_time_range_exists(&self, start: DateTime<Utc>, end: DateTime<Utc>) -> Result<(bool, i64)> {
        // Check if we have data for this time range and get the count
        let result = sqlx::query!(
            r#"
            SELECT COUNT(*) as "count!"
            FROM fills
            WHERE exchange_id = $1 AND timestamp >= $2 AND timestamp < $3
            "#,
            self.exchange_id,
            start,
            end
        )
        .fetch_one(&self.pool)
        .await?;

        let has_data = result.count > 0;
        debug!(
            start = %start,
            end = %end,
            count = result.count,
            has_data = has_data,
            "Checked time range for existing data"
        );

        Ok((has_data, result.count))
    }

    #[instrument(skip(self))]
    pub async fn get_missing_hours(&self, start: DateTime<Utc>, end: DateTime<Utc>) -> Result<Vec<DateTime<Utc>>> {
        // Get list of hours that have no data or very little data
        let result = sqlx::query!(
            r#"
            WITH hour_series AS (
                SELECT generate_series(
                    DATE_TRUNC('hour', $1::timestamptz),
                    DATE_TRUNC('hour', $2::timestamptz) - INTERVAL '1 hour',
                    INTERVAL '1 hour'
                ) AS hour
            ),
            hourly_counts AS (
                SELECT
                    DATE_TRUNC('hour', timestamp) AS hour,
                    COUNT(*) AS count
                FROM fills
                WHERE exchange_id = $3 AND timestamp >= $1 AND timestamp < $2
                GROUP BY DATE_TRUNC('hour', timestamp)
            )
            SELECT
                hs.hour AS "hour!"
            FROM hour_series hs
            LEFT JOIN hourly_counts hc ON hs.hour = hc.hour
            WHERE hc.count IS NULL OR hc.count < 1000  -- Hours with less than 1000 records are considered incomplete
            ORDER BY hs.hour
            "#,
            start,
            end,
            self.exchange_id
        )
        .fetch_all(&self.pool)
        .await?;

        let missing_hours: Vec<DateTime<Utc>> = result
            .into_iter()
            .map(|r| r.hour)
            .collect();

        if !missing_hours.is_empty() {
            info!(
                "Found {} hours with missing or incomplete data between {} and {}",
                missing_hours.len(),
                start.format("%Y-%m-%d %H:%M"),
                end.format("%Y-%m-%d %H:%M")
            );
        }

        Ok(missing_hours)
    }

    #[instrument(skip(self))]
    pub async fn update_daily_stats(&self, date: chrono::NaiveDate) -> Result<()> {
        sqlx::query!(
            r#"
            INSERT INTO daily_stats (
                exchange_id,
                market_id, date, total_volume_usd, buy_volume_usd, sell_volume_usd,
                total_trades, unique_traders, open_price, high_price, low_price, close_price
            )
            SELECT
                $2 as exchange_id,
                market_id,
                DATE(timestamp) as date,
                SUM(price * size) as total_volume_usd,
                SUM(CASE WHEN side = 'BUY' THEN price * size ELSE 0 END) as buy_volume_usd,
                SUM(CASE WHEN side = 'SELL' THEN price * size ELSE 0 END) as sell_volume_usd,
                COUNT(*) as total_trades,
                COUNT(DISTINCT user_address) as unique_traders,
                (array_agg(price ORDER BY timestamp ASC))[1] as open_price,
                MAX(price) as high_price,
                MIN(price) as low_price,
                (array_agg(price ORDER BY timestamp DESC))[1] as close_price
            FROM fills
            WHERE exchange_id = $2 AND DATE(timestamp) = $1
            GROUP BY market_id, DATE(timestamp)
            ON CONFLICT (exchange_id, market_id, date) DO UPDATE SET
                total_volume_usd = EXCLUDED.total_volume_usd,
                buy_volume_usd = EXCLUDED.buy_volume_usd,
                sell_volume_usd = EXCLUDED.sell_volume_usd,
                total_trades = EXCLUDED.total_trades,
                unique_traders = EXCLUDED.unique_traders,
                open_price = EXCLUDED.open_price,
                high_price = EXCLUDED.high_price,
                low_price = EXCLUDED.low_price,
                close_price = EXCLUDED.close_price,
                updated_at = NOW()
            "#,
            date,
            self.exchange_id
        )
        .execute(&self.pool)
        .await?;

        debug!(date = %date, "Updated daily stats");
        Ok(())
    }

    pub async fn health_check(&self) -> Result<()> {
        sqlx::query!("SELECT 1 as alive")
            .fetch_one(&self.pool)
            .await?;
        Ok(())
    }

    #[instrument(skip(self))]
    pub async fn refresh_hourly_stats_view(&self) -> Result<()> {
        // Track refresh time for performance monitoring
        let start = std::time::Instant::now();

        // List of materialized views to refresh
        let views = [
            // Original views
            "hourly_user_stats",
            "hourly_market_stats",
            "hourly_exchange_stats",
            "market_summary",
            // New trader analytics views
            "trader_summary",
            "trader_market_summary",
            "daily_market_stats",
            "large_trades",
            "hourly_ingest_stats",
        ];

        for view in &views {
            // Check if the materialized view exists first
            let view_exists = sqlx::query!(
                r#"
                SELECT EXISTS (
                    SELECT 1
                    FROM pg_matviews
                    WHERE schemaname = 'public'
                    AND matviewname = $1
                ) as "exists!"
                "#,
                view
            )
            .fetch_one(&self.pool)
            .await?;

            if view_exists.exists {
                // Only refresh if the view exists
                let query = format!("REFRESH MATERIALIZED VIEW CONCURRENTLY {}", view);
                match sqlx::query(&query)
                    .execute(&self.pool)
                    .await
                {
                    Ok(_) => {
                        let elapsed = start.elapsed();
                        info!(
                            view = view,
                            duration_ms = elapsed.as_millis(),
                            "Refreshed materialized view"
                        );
                        counter!("indexer_materialized_view_refreshes", "view" => view).increment(1);
                    }
                    Err(e) => {
                        // Log error but don't fail the operation
                        warn!(
                            view = view,
                            error = %e,
                            "Failed to refresh materialized view"
                        );
                        counter!("indexer_materialized_view_refresh_errors", "view" => view).increment(1);
                    }
                }
            } else {
                debug!(view = view, "Materialized view does not exist yet");
            }
        }

        let total_elapsed = start.elapsed();
        info!(
            total_duration_ms = total_elapsed.as_millis(),
            "Completed refreshing all materialized views"
        );

        Ok(())
    }
}