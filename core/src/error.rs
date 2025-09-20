use thiserror::Error;

#[derive(Error, Debug)]
pub enum Error {
    #[error("configuration error: {0}")]
    Config(String),

    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    #[error("HTTP request failed: {0}")]
    Http(#[from] reqwest::Error),

    #[error("serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("ingest error from {source_name}: {details}")]
    Ingest { source_name: String, details: String },

    #[error("pipeline error: {0}")]
    Pipeline(String),

    #[error("rate limit exceeded, retry after {retry_after_secs} seconds")]
    RateLimit { retry_after_secs: u64 },

    #[error("checkpoint error: {0}")]
    Checkpoint(String),

    #[error("validation error: {0}")]
    Validation(String),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("internal error: {0}")]
    Internal(String),
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            Error::Database(_) | Error::Http(_) | Error::RateLimit { .. } | Error::Io(_)
        )
    }

    pub fn is_fatal(&self) -> bool {
        matches!(self, Error::Config(_) | Error::Validation(_))
    }
}