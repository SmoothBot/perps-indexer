use crate::store::Store;
use chrono::{DateTime, Utc, Duration};
use indexer_core::Result;
use sqlx::PgPool;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{info, warn, instrument, debug};

/// Manages incremental updates to statistics tables
/// Runs concurrently in the background without blocking the main pipeline
pub struct IncrementalStatsUpdater {
    pool: PgPool,
    update_tx: mpsc::Sender<StatsUpdateRequest>,
    worker_handle: JoinHandle<()>,
}

#[derive(Debug, Clone)]
struct StatsUpdateRequest {
    start_time: DateTime<Utc>,
    end_time: DateTime<Utc>,
}

impl IncrementalStatsUpdater {
    pub fn new(pool: PgPool) -> Self {
        let pool_clone = pool.clone();
        let (update_tx, mut update_rx) = mpsc::channel::<StatsUpdateRequest>(1000);

        // Spawn background worker that processes stats updates
        let worker_handle = tokio::spawn(async move {
            let worker_pool = pool_clone;
            while let Some(request) = update_rx.recv().await {
                // Process updates in background without blocking
                match Self::process_update(&worker_pool, request.start_time, request.end_time).await {
                    Ok(_) => debug!(
                        "Successfully updated stats for {} to {}",
                        request.start_time.format("%Y-%m-%d %H:%M"),
                        request.end_time.format("%Y-%m-%d %H:%M")
                    ),
                    Err(e) => warn!("Failed to update stats: {}", e),
                }
            }
            info!("Stats updater worker shutting down");
        });

        Self {
            pool,
            update_tx,
            worker_handle,
        }
    }

    /// Queue stats update without blocking - returns immediately
    pub async fn queue_update(&self, start_time: DateTime<Utc>, end_time: DateTime<Utc>) -> Result<()> {
        let request = StatsUpdateRequest { start_time, end_time };

        // Try to send, but don't block if channel is full
        match self.update_tx.try_send(request) {
            Ok(_) => {
                debug!("Queued stats update for {} to {}",
                    start_time.format("%H:%M"),
                    end_time.format("%H:%M")
                );
            }
            Err(mpsc::error::TrySendError::Full(_)) => {
                debug!("Stats update queue full, skipping update");
            }
            Err(e) => {
                warn!("Failed to queue stats update: {}", e);
            }
        }

        Ok(())
    }

    /// Process update in background worker
    async fn process_update(pool: &PgPool, start_time: DateTime<Utc>, end_time: DateTime<Utc>) -> Result<()> {
        // Get list of unique hours that were affected
        let affected_hours = Self::get_affected_hours_static(pool, start_time, end_time).await?;

        if affected_hours.is_empty() {
            return Ok(());
        }

        debug!("Updating {} affected hours incrementally", affected_hours.len());

        // Update hours concurrently with limited parallelism
        use futures::future;
        use futures::stream::{self, StreamExt};

        let results = stream::iter(affected_hours.into_iter())
            .map(|hour| {
                let pool = pool.clone();
                async move {
                    Self::update_single_hour_static(&pool, hour).await
                }
            })
            .buffer_unordered(4) // Process up to 4 hours concurrently
            .collect::<Vec<_>>()
            .await;

        // Check for errors but don't fail the whole batch
        for result in results {
            if let Err(e) = result {
                warn!("Failed to update hour: {}", e);
            }
        }

        Ok(())
    }

    async fn get_affected_hours_static(pool: &PgPool, start: DateTime<Utc>, end: DateTime<Utc>) -> Result<Vec<DateTime<Utc>>> {
        let hours: Vec<DateTime<Utc>> = sqlx::query!(
            r#"
            SELECT DISTINCT DATE_TRUNC('hour', timestamp) as hour
            FROM fills
            WHERE timestamp >= $1 AND timestamp <= $2
            ORDER BY hour
            "#,
            start,
            end
        )
        .fetch_all(pool)
        .await?
        .into_iter()
        .map(|r| r.hour.unwrap())
        .collect();

        Ok(hours)
    }

    async fn update_single_hour_static(pool: &PgPool, hour: DateTime<Utc>) -> Result<()> {
        // Use UPSERT pattern to update or insert hourly stats
        sqlx::query!(
            r#"
            INSERT INTO hourly_stats_incremental (
                hour, exchange_id, total_fills, unique_traders,
                total_volume, buy_volume, sell_volume,
                avg_trade_size, max_trade_size, min_trade_size,
                total_fees, avg_fee, last_updated
            )
            SELECT
                DATE_TRUNC('hour', f.timestamp) AS hour,
                f.exchange_id,
                COUNT(*) AS total_fills,
                COUNT(DISTINCT f.user_address) AS unique_traders,
                SUM(f.price * f.size) AS total_volume,
                SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE 0 END) AS buy_volume,
                SUM(CASE WHEN f.side = 'SELL' THEN f.price * f.size ELSE 0 END) AS sell_volume,
                AVG(f.price * f.size) AS avg_trade_size,
                MAX(f.price * f.size) AS max_trade_size,
                MIN(f.price * f.size) AS min_trade_size,
                SUM(COALESCE(f.fee, 0)) AS total_fees,
                AVG(COALESCE(f.fee, 0)) AS avg_fee,
                NOW() AS last_updated
            FROM fills f
            WHERE DATE_TRUNC('hour', f.timestamp) = $1
            GROUP BY DATE_TRUNC('hour', f.timestamp), f.exchange_id
            ON CONFLICT (hour, exchange_id) DO UPDATE SET
                total_fills = EXCLUDED.total_fills,
                unique_traders = EXCLUDED.unique_traders,
                total_volume = EXCLUDED.total_volume,
                buy_volume = EXCLUDED.buy_volume,
                sell_volume = EXCLUDED.sell_volume,
                avg_trade_size = EXCLUDED.avg_trade_size,
                max_trade_size = EXCLUDED.max_trade_size,
                min_trade_size = EXCLUDED.min_trade_size,
                total_fees = EXCLUDED.total_fees,
                avg_fee = EXCLUDED.avg_fee,
                last_updated = EXCLUDED.last_updated
            "#,
            hour
        )
        .execute(pool)
        .await?;

        Ok(())
    }

    /// Update market-specific hourly stats (static version for worker)
    async fn update_market_stats_static(pool: &PgPool, hour: DateTime<Utc>) -> Result<()> {
        sqlx::query!(
            r#"
            INSERT INTO hourly_market_stats_incremental (
                hour, exchange_id, market_id, symbol,
                total_fills, unique_traders, total_volume,
                buy_volume, sell_volume, open_price,
                high_price, low_price, close_price,
                last_updated
            )
            SELECT
                DATE_TRUNC('hour', f.timestamp) AS hour,
                f.exchange_id,
                f.market_id,
                m.symbol,
                COUNT(*) AS total_fills,
                COUNT(DISTINCT f.user_address) AS unique_traders,
                SUM(f.price * f.size) AS total_volume,
                SUM(CASE WHEN f.side = 'BUY' THEN f.price * f.size ELSE 0 END) AS buy_volume,
                SUM(CASE WHEN f.side = 'SELL' THEN f.price * f.size ELSE 0 END) AS sell_volume,
                (array_agg(f.price ORDER BY f.timestamp ASC))[1] AS open_price,
                MAX(f.price) AS high_price,
                MIN(f.price) AS low_price,
                (array_agg(f.price ORDER BY f.timestamp DESC))[1] AS close_price,
                NOW() AS last_updated
            FROM fills f
            INNER JOIN markets m ON f.market_id = m.id
            WHERE DATE_TRUNC('hour', f.timestamp) = $1
            GROUP BY DATE_TRUNC('hour', f.timestamp), f.exchange_id, f.market_id, m.symbol
            ON CONFLICT (hour, exchange_id, market_id) DO UPDATE SET
                total_fills = EXCLUDED.total_fills,
                unique_traders = EXCLUDED.unique_traders,
                total_volume = EXCLUDED.total_volume,
                buy_volume = EXCLUDED.buy_volume,
                sell_volume = EXCLUDED.sell_volume,
                open_price = EXCLUDED.open_price,
                high_price = EXCLUDED.high_price,
                low_price = EXCLUDED.low_price,
                close_price = EXCLUDED.close_price,
                last_updated = EXCLUDED.last_updated
            "#,
            hour
        )
        .execute(pool)
        .await?;

        Ok(())
    }

    /// Queue stats update for fills without blocking - returns immediately
    pub async fn queue_update_for_fills(&self, fills: &[crate::model::Fill]) -> Result<()> {
        if fills.is_empty() {
            return Ok(());
        }

        // Find time range of inserted fills
        let min_time = fills.iter().map(|f| f.timestamp).min().unwrap();
        let max_time = fills.iter().map(|f| f.timestamp).max().unwrap();

        // Queue update without blocking
        self.queue_update(min_time, max_time).await?;

        Ok(())
    }

    /// Gracefully shutdown the background worker
    pub async fn shutdown(self) {
        drop(self.update_tx);
        let _ = self.worker_handle.await;
    }
}