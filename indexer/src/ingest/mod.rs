pub mod s3_source;

use crate::model::IngestBatch;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use indexer_core::Result;

#[async_trait]
pub trait IngestSource: Send + Sync {
    /// Fetch a page of data starting from the given timestamp
    async fn fetch_page(
        &self,
        start_from: DateTime<Utc>,
        cursor: Option<String>,
    ) -> Result<IngestBatch>;

    /// Get the source identifier
    fn source_id(&self) -> &str;

    /// Check if the source is healthy
    async fn health_check(&self) -> Result<()>;
}

pub use s3_source::S3Source;