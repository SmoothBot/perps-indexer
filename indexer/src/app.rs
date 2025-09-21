use crate::ingest::S3Source;
use crate::pipeline::Pipeline;
use crate::store::Store;
use chrono::{DateTime, Utc};
use indexer_core::{Config, Result};
use sqlx::PgPool;
use std::sync::Arc;
use tracing::{info, instrument};

pub struct App {
    config: Config,
    store: Arc<Store>,
    pipeline: Pipeline,
}

impl App {
    #[instrument(skip(config, pool))]
    pub async fn new(config: Config, pool: PgPool) -> Result<Self> {
        info!("Initializing application");

        // Create store
        let store = Arc::new(Store::new(pool).await?);

        // Create S3 ingest source
        let source = S3Source::new(
            config.ingest.source.s3_bucket.clone(),
            config.ingest.source.aws_profile.clone(),
        ).await?;

        // Health check
        info!("Performing health checks");
        store.health_check().await?;
        // Note: We skip source.health_check() for S3 to avoid unnecessary requests

        // Create pipeline
        let pipeline = Pipeline::new(
            Arc::new(source),
            Arc::clone(&store),
            config.clone(),
        );

        Ok(Self {
            config,
            store,
            pipeline,
        })
    }

    pub async fn run_backfill(&self, end_at: Option<DateTime<Utc>>) -> Result<()> {
        self.pipeline.run_backfill(end_at).await
    }

    pub async fn run_continuous(&self) -> Result<()> {
        self.pipeline.run_continuous().await
    }
}