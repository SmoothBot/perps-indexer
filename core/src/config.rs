use chrono::{Duration, Utc};
use config::{ConfigError, Environment, File};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Config {
    pub database: DatabaseConfig,
    pub ingest: IngestConfig,
    pub pipeline: PipelineConfig,
    pub telemetry: TelemetryConfig,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DatabaseConfig {
    pub url: String,
    pub max_connections: u32,
    pub min_connections: u32,
    pub connect_timeout_secs: u64,
    pub idle_timeout_secs: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct IngestConfig {
    pub source: IngestSourceConfig,
    pub start_from: Option<chrono::DateTime<Utc>>,
    pub batch_size: usize,
    pub max_retries: u32,
    pub retry_base_delay_ms: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct IngestSourceConfig {
    pub s3_bucket: String,
    pub aws_profile: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct PipelineConfig {
    pub channel_buffer_size: usize,
    pub checkpoint_interval_secs: u64,
    pub shutdown_timeout_secs: u64,
    pub max_concurrent_batches: usize,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TelemetryConfig {
    pub log_level: String,
    pub log_format: LogFormat,
    pub metrics_enabled: bool,
    pub metrics_port: u16,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum LogFormat {
    Json,
    Pretty,
}

impl Config {
    pub fn load() -> Result<Self, ConfigError> {
        let mut builder = config::Config::builder();

        // Load default configuration
        builder = builder.add_source(config::Config::try_from(&Config::default())?);

        // Layer on config file if it exists
        if Path::new("config.toml").exists() {
            builder = builder.add_source(File::with_name("config"));
        }

        // Layer on environment variables (INDEXER_ prefix)
        builder = builder.add_source(
            Environment::with_prefix("INDEXER")
                .separator("__")
                .try_parsing(true),
        );

        let config = builder.build()?;
        let mut settings: Config = config.try_deserialize()?;

        // Apply default start_from if not set
        if settings.ingest.start_from.is_none() {
            settings.ingest.start_from = Some(Utc::now() - Duration::days(7));
        }

        settings.validate()?;
        Ok(settings)
    }

    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.database.url.is_empty() {
            return Err(ConfigError::Message("database.url is required".into()));
        }

        if self.ingest.batch_size == 0 {
            return Err(ConfigError::Message(
                "ingest.batch_size must be greater than 0".into(),
            ));
        }

        if self.pipeline.channel_buffer_size == 0 {
            return Err(ConfigError::Message(
                "pipeline.channel_buffer_size must be greater than 0".into(),
            ));
        }

        Ok(())
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            database: DatabaseConfig {
                url: "postgresql://postgres:postgres@localhost:5432/hl_indexer".to_string(),
                max_connections: 10,
                min_connections: 2,
                connect_timeout_secs: 10,
                idle_timeout_secs: 600,
            },
            ingest: IngestConfig {
                source: IngestSourceConfig {
                    s3_bucket: "hl-mainnet-node-data".to_string(),
                    aws_profile: None,
                },
                start_from: None, // Will be set to now() - 7 days in load()
                batch_size: 1000,
                max_retries: 3,
                retry_base_delay_ms: 1000,
            },
            pipeline: PipelineConfig {
                channel_buffer_size: 1000,
                checkpoint_interval_secs: 60,
                shutdown_timeout_secs: 30,
                max_concurrent_batches: 4,
            },
            telemetry: TelemetryConfig {
                log_level: "info".to_string(),
                log_format: LogFormat::Pretty,
                metrics_enabled: true,
                metrics_port: 9090,
            },
        }
    }
}