use crate::ingest::IngestSource;
use crate::model::{Checkpoint, IngestBatch};
use crate::store::Store;
use chrono::{DateTime, Utc};
use indexer_core::backoff::retry_with_backoff;
use indexer_core::{Error, Result};
use metrics::{counter, gauge, histogram};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{debug, error, info, instrument, warn};

pub struct Pipeline {
    source: Arc<dyn IngestSource>,
    store: Arc<Store>,
    config: indexer_core::Config,
}

impl Pipeline {
    pub fn new(
        source: Arc<dyn IngestSource>,
        store: Arc<Store>,
        config: indexer_core::Config,
    ) -> Self {
        Self {
            source,
            store,
            config,
        }
    }

    #[instrument(skip(self))]
    pub async fn run_backfill(
        &self,
        end_at: Option<DateTime<Utc>>,
    ) -> Result<()> {
        let start_from = self.config.ingest.start_from
            .ok_or_else(|| Error::Config("start_from is required for backfill".to_string()))?;

        let end_at = end_at.unwrap_or_else(Utc::now);

        info!(
            start = %start_from,
            end = %end_at,
            "Starting backfill pipeline"
        );

        // First check if we already have data for this time range
        let (has_data, existing_count) = self.store.check_time_range_exists(start_from, end_at).await?;

        if has_data {
            // Check if we have complete data or just partial
            let missing_hours = self.store.get_missing_hours(start_from, end_at).await?;

            if missing_hours.is_empty() {
                info!(
                    start = %start_from,
                    end = %end_at,
                    existing_count = existing_count,
                    "⏩ Skipping backfill - complete data already exists for this time range. Save money! 💰"
                );
                return Ok(());
            } else {
                warn!(
                    start = %start_from,
                    end = %end_at,
                    existing_count = existing_count,
                    missing_hours = missing_hours.len(),
                    "⚠️ Found {} hours with missing/incomplete data. Will fetch all data to ensure completeness.",
                    missing_hours.len()
                );
                // Continue with backfill to fill gaps
            }
        }

        // Check for existing checkpoint
        let mut checkpoint = self.store
            .get_checkpoint(self.source.source_id())
            .await?
            .unwrap_or_else(|| Checkpoint::new(self.source.source_id().to_string()));

        // Use the requested start time if it's earlier than the checkpoint
        // This allows backfilling historical data gaps
        let current_start = if let Some(checkpoint_ts) = checkpoint.last_record_ts {
            if start_from < checkpoint_ts {
                // User wants to backfill earlier data, reset cursor for this range
                start_from
            } else {
                // Continue from checkpoint
                checkpoint_ts
            }
        } else {
            start_from
        };

        // Reset cursor if we're going back in time
        let cursor = if start_from < checkpoint.last_record_ts.unwrap_or(start_from) {
            None
        } else {
            checkpoint.cursor.clone()
        };

        // Create bounded channel for backpressure
        let (tx, mut rx) = mpsc::channel::<IngestBatch>(self.config.pipeline.channel_buffer_size);

        // Spawn fetcher task
        let fetcher = self.spawn_fetcher(tx, current_start, cursor.clone(), end_at);

        // Process batches
        let mut total_processed = checkpoint.records_processed;
        let mut last_checkpoint_save = Instant::now();
        let mut last_progress_update = Instant::now();
        let mut batches_processed = 0u64;
        let mut total_bytes_downloaded = 0u64;
        let pipeline_start_time = Instant::now();
        let mut any_checkpoint_updates = false;

        info!(
            "Starting to process data from {}",
            current_start.format("%Y-%m-%d %H:%M:%S UTC")
        );

        while let Some(batch) = rx.recv().await {
            let batch_size = batch.fills.len();
            batches_processed += 1;

            // Use actual bytes if available, otherwise estimate (roughly 100 bytes per fill record)
            let batch_bytes = batch.bytes_downloaded.unwrap_or((batch_size * 100) as u64);
            total_bytes_downloaded += batch_bytes;

            // Process batch with retries
            let inserted = retry_with_backoff(
                || self.store.insert_fills(&batch.fills),
                self.config.ingest.max_retries,
                self.config.ingest.retry_base_delay_ms,
                "insert_fills",
            )
            .await?;

            total_processed += inserted as i64;

            // Only update checkpoint if we're moving forward in time
            // This preserves the checkpoint for normal operation while allowing historical backfills
            let should_update_checkpoint = if let Some(last_fill) = batch.fills.last() {
                checkpoint.last_record_ts.map_or(true, |ts| last_fill.timestamp >= ts)
            } else {
                false
            };

            if should_update_checkpoint {
                if let Some(last_fill) = batch.fills.last() {
                    checkpoint.last_record_ts = Some(last_fill.timestamp);
                    checkpoint.last_block_number = last_fill.block_number;
                }
                checkpoint.cursor = batch.cursor.clone();
                checkpoint.records_processed = total_processed;
                any_checkpoint_updates = true;
            }

            // Show progress update every 5 seconds
            if last_progress_update.elapsed() > Duration::from_secs(5) {
                let progress_pct = if let Some(last_ts) = checkpoint.last_record_ts {
                    let total_duration = end_at.signed_duration_since(current_start);
                    let elapsed_duration = last_ts.signed_duration_since(current_start);
                    if total_duration.num_seconds() > 0 {
                        (elapsed_duration.num_seconds() as f64 / total_duration.num_seconds() as f64 * 100.0).min(100.0)
                    } else {
                        0.0
                    }
                } else {
                    0.0
                };

                // Calculate ETA
                let elapsed_secs = pipeline_start_time.elapsed().as_secs();
                let eta_str = if progress_pct > 0.0 && elapsed_secs > 0 {
                    let total_estimated_secs = (elapsed_secs as f64 / (progress_pct / 100.0)) as u64;
                    let remaining_secs = total_estimated_secs.saturating_sub(elapsed_secs);

                    if remaining_secs < 60 {
                        format!("{}s", remaining_secs)
                    } else if remaining_secs < 3600 {
                        format!("{}m {}s", remaining_secs / 60, remaining_secs % 60)
                    } else {
                        format!("{}h {}m", remaining_secs / 3600, (remaining_secs % 3600) / 60)
                    }
                } else {
                    "calculating...".to_string()
                };

                // Format download sizes
                let downloaded_mb = total_bytes_downloaded as f64 / (1024.0 * 1024.0);
                let estimated_total_mb = if progress_pct > 0.0 {
                    downloaded_mb / (progress_pct / 100.0)
                } else {
                    0.0
                };

                info!(
                    "📊 Progress: {:.1}% | Downloaded: {:.1}MB / ~{:.1}MB | Records: {} | ETA: {} | Current: {}",
                    progress_pct,
                    downloaded_mb,
                    estimated_total_mb,
                    total_processed,
                    eta_str,
                    checkpoint.last_record_ts
                        .map(|ts| ts.format("%Y-%m-%d %H:%M:%S").to_string())
                        .unwrap_or_else(|| "N/A".to_string())
                );
                last_progress_update = Instant::now();
            }

            // Save checkpoint periodically (only if we're updating it)
            if should_update_checkpoint &&
               last_checkpoint_save.elapsed() > Duration::from_secs(self.config.pipeline.checkpoint_interval_secs) {
                self.store.save_checkpoint(&checkpoint).await?;
                last_checkpoint_save = Instant::now();

                debug!(
                    processed = total_processed,
                    last_ts = ?checkpoint.last_record_ts,
                    "Checkpoint saved"
                );
            }

            // Update metrics
            gauge!("indexer_pipeline_queue_size").set(rx.len() as f64);
            histogram!("indexer_pipeline_batch_size").record(batch_size as f64);
        }

        // Final checkpoint save (only if we made forward progress)
        if any_checkpoint_updates {
            self.store.save_checkpoint(&checkpoint).await?;
        }

        // Wait for fetcher to complete
        fetcher.await.map_err(|e| Error::Internal(format!("Fetcher task panicked: {}", e)))??;

        let duration = checkpoint.last_record_ts.unwrap_or(start_from).signed_duration_since(start_from);
        let rate = if duration.num_seconds() > 0 {
            total_processed as f64 / duration.num_seconds() as f64
        } else {
            0.0
        };

        let total_mb = total_bytes_downloaded as f64 / (1024.0 * 1024.0);
        let elapsed_time = pipeline_start_time.elapsed();
        let throughput_mbps = if elapsed_time.as_secs() > 0 {
            (total_mb * 8.0) / elapsed_time.as_secs() as f64
        } else {
            0.0
        };

        info!(
            "✨ Backfill completed! Processed {} records | Downloaded: {:.1} MB | Rate: {:.0} records/sec | Throughput: {:.1} Mbps | Batches: {}",
            total_processed,
            total_mb,
            rate,
            throughput_mbps,
            batches_processed
        );

        Ok(())
    }

    #[instrument(skip(self))]
    pub async fn run_continuous(&self) -> Result<()> {
        info!("Starting continuous ingestion pipeline");

        // Get checkpoint or start from config
        let checkpoint = self.store
            .get_checkpoint(self.source.source_id())
            .await?
            .unwrap_or_else(|| Checkpoint::new(self.source.source_id().to_string()));

        let start_from = checkpoint.last_record_ts
            .or(self.config.ingest.start_from)
            .unwrap_or_else(|| Utc::now() - chrono::Duration::days(7));

        let mut current_start = start_from;
        let mut cursor = checkpoint.cursor;
        let mut total_processed = checkpoint.records_processed;

        // Create shutdown channel
        let (shutdown_tx, mut shutdown_rx) = mpsc::channel::<()>(1);

        // Setup signal handler
        let shutdown_tx_clone = shutdown_tx.clone();
        tokio::spawn(async move {
            match tokio::signal::ctrl_c().await {
                Ok(()) => {
                    info!("Shutdown signal received");
                    let _ = shutdown_tx_clone.send(()).await;
                }
                Err(e) => error!(error = %e, "Failed to listen for shutdown signal"),
            }
        });

        loop {
            tokio::select! {
                _ = shutdown_rx.recv() => {
                    info!("Shutting down pipeline");
                    break;
                }

                result = self.fetch_and_process_batch(current_start, cursor.clone()) => {
                    match result {
                        Ok((batch, inserted)) => {
                            total_processed += inserted as i64;

                            // Update state for next iteration
                            if let Some(last_fill) = batch.fills.last() {
                                current_start = last_fill.timestamp;
                            }
                            cursor = batch.cursor;

                            // Save checkpoint
                            let checkpoint = Checkpoint {
                                source: self.source.source_id().to_string(),
                                cursor: cursor.clone(),
                                last_record_ts: Some(current_start),
                                last_block_number: batch.fills.last().and_then(|f| f.block_number),
                                records_processed: total_processed,
                                updated_at: Utc::now(),
                                metadata: None,
                            };

                            self.store.save_checkpoint(&checkpoint).await?;

                            // If no more data, wait before polling again
                            if !batch.has_more {
                                tokio::time::sleep(Duration::from_secs(60)).await;
                            }
                        }
                        Err(e) if e.is_retryable() => {
                            warn!(error = %e, "Retryable error, backing off");
                            tokio::time::sleep(Duration::from_secs(30)).await;
                        }
                        Err(e) => {
                            return Err(e);
                        }
                    }
                }
            }
        }

        Ok(())
    }

    async fn fetch_and_process_batch(
        &self,
        start_from: DateTime<Utc>,
        cursor: Option<String>,
    ) -> Result<(IngestBatch, usize)> {
        let start = Instant::now();

        // Fetch batch
        let batch = retry_with_backoff(
            || self.source.fetch_page(start_from, cursor.clone()),
            self.config.ingest.max_retries,
            self.config.ingest.retry_base_delay_ms,
            "fetch_page",
        )
        .await?;

        let fetch_duration = start.elapsed();
        histogram!("indexer_fetch_duration_ms").record(fetch_duration.as_millis() as f64);

        // Insert fills
        let inserted = self.store.insert_fills(&batch.fills).await?;

        let total_duration = start.elapsed();
        histogram!("indexer_batch_duration_ms").record(total_duration.as_millis() as f64);

        if let Some(bytes) = batch.bytes_downloaded {
            histogram!("indexer_batch_bytes").record(bytes as f64);
        }

        debug!(
            fetched = batch.fills.len(),
            inserted,
            bytes = ?batch.bytes_downloaded,
            duration_ms = total_duration.as_millis(),
            "Processed batch"
        );

        Ok((batch, inserted))
    }

    fn spawn_fetcher(
        &self,
        tx: mpsc::Sender<IngestBatch>,
        start_from: DateTime<Utc>,
        initial_cursor: Option<String>,
        end_at: DateTime<Utc>,
    ) -> JoinHandle<Result<()>> {
        let source = Arc::clone(&self.source);
        let config = self.config.clone();

        tokio::spawn(async move {
            let mut current_start = start_from;
            let mut cursor = initial_cursor;
            let mut fetched_batches = 0u64;
            let mut last_fetch_log = Instant::now();
            let mut total_fills_fetched = 0u64;

            info!(
                "🚀 Starting data fetch from {} to {}",
                start_from.format("%Y-%m-%d %H:%M:%S"),
                end_at.format("%Y-%m-%d %H:%M:%S")
            );

            loop {
                // Check if we've reached the end time
                if current_start >= end_at {
                    info!(
                        current = %current_start,
                        end = %end_at,
                        "✅ Reached end time"
                    );
                    break;
                }

                // Fetch batch with retries
                let batch = match retry_with_backoff(
                    || source.fetch_page(current_start, cursor.clone()),
                    config.ingest.max_retries,
                    config.ingest.retry_base_delay_ms,
                    "fetch_page",
                )
                .await {
                    Ok(batch) => batch,
                    Err(e) => {
                        error!(error = %e, "❌ Failed to fetch page after retries");
                        return Err(e);
                    }
                };

                let has_more = batch.has_more;
                let batch_fill_count = batch.fills.len();
                cursor = batch.cursor.clone();
                fetched_batches += 1;
                total_fills_fetched += batch_fill_count as u64;

                // Update current_start for next iteration
                if let Some(last_fill) = batch.fills.last() {
                    current_start = last_fill.timestamp;
                }

                // Log fetch progress periodically
                if last_fetch_log.elapsed() > Duration::from_secs(10) || fetched_batches == 1 {
                    info!(
                        "📥 Fetching: {} | Batch #{} with {} fills | Total: {} fills | Channel buffer: {}",
                        current_start.format("%Y-%m-%d %H:%M:%S"),
                        fetched_batches,
                        batch_fill_count,
                        total_fills_fetched,
                        config.pipeline.channel_buffer_size - tx.capacity()
                    );
                    last_fetch_log = Instant::now();
                }

                // Send batch through channel
                if tx.send(batch).await.is_err() {
                    warn!("Pipeline channel closed, stopping fetcher");
                    break;
                }

                // If no more data, we're done
                if !has_more {
                    info!("✅ No more data available");
                    break;
                }

                counter!("indexer_fetcher_batches").increment(1);
            }

            info!("📦 Fetcher completed: {} batches, {} fills total", fetched_batches, total_fills_fetched);

            Ok(())
        })
    }
}