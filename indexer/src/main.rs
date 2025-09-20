mod app;
mod ingest;
mod model;
mod pipeline;
mod store;

use clap::{Parser, Subcommand};
use indexer_core::{telemetry, Config};
use sqlx::postgres::PgPoolOptions;
use std::process;
use tracing::{error, info};

#[derive(Parser)]
#[clap(name = "indexer")]
#[clap(about = "Hyperliquid historical data indexer", version)]
struct Cli {
    #[clap(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Run database migrations
    Migrate,

    /// Backfill historical data
    Backfill {
        /// Override start timestamp (RFC3339 format)
        #[clap(long, env = "BACKFILL_START")]
        start: Option<chrono::DateTime<chrono::Utc>>,

        /// Override end timestamp (RFC3339 format)
        #[clap(long, env = "BACKFILL_END")]
        end: Option<chrono::DateTime<chrono::Utc>>,
    },

    /// Run continuous ingestion
    Run {
        /// Override start timestamp if no checkpoint exists
        #[clap(long, env = "RUN_START")]
        start: Option<chrono::DateTime<chrono::Utc>>,

        /// Backfill from this timestamp before starting live mode
        #[clap(long, env = "BACKFILL_FROM")]
        backfill_from: Option<chrono::DateTime<chrono::Utc>>,

        /// Backfill up to this timestamp before starting live mode (defaults to NOW)
        #[clap(long, env = "BACKFILL_TO")]
        backfill_to: Option<chrono::DateTime<chrono::Utc>>,
    },
}

#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        error!(error = %e, "Fatal error");
        process::exit(1);
    }
}

async fn run() -> anyhow::Result<()> {
    // Load configuration
    let mut config = Config::load()
        .map_err(|e| anyhow::anyhow!("Failed to load config: {}", e))?;

    // Initialize telemetry
    telemetry::init(&config.telemetry)?;

    let cli = Cli::parse();

    // Create database connection pool
    let pool = PgPoolOptions::new()
        .max_connections(config.database.max_connections)
        .min_connections(config.database.min_connections)
        .acquire_timeout(std::time::Duration::from_secs(
            config.database.connect_timeout_secs,
        ))
        .idle_timeout(std::time::Duration::from_secs(
            config.database.idle_timeout_secs,
        ))
        .connect(&config.database.url)
        .await?;

    match cli.command {
        Commands::Migrate => {
            info!("Running database migrations");
            sqlx::migrate!("../migrations").run(&pool).await?;
            info!("Migrations completed successfully");
        }

        Commands::Backfill { start, end } => {
            // Override config with CLI args
            if let Some(start) = start {
                config.ingest.start_from = Some(start);
            }

            info!(
                start = ?config.ingest.start_from,
                end = ?end,
                "Starting backfill"
            );

            let app = app::App::new(config, pool).await?;
            app.run_backfill(end).await?;
        }

        Commands::Run { start, backfill_from, backfill_to } => {
            // Override config with CLI args
            if let Some(start) = start {
                config.ingest.start_from = Some(start);
            }

            // If backfill_from is specified, run backfill first
            if let Some(backfill_start) = backfill_from {
                let backfill_end = backfill_to.unwrap_or_else(chrono::Utc::now);

                info!(
                    start = %backfill_start,
                    end = %backfill_end,
                    "Running backfill before starting live mode"
                );

                // Temporarily set start_from for backfill
                let original_start = config.ingest.start_from;
                config.ingest.start_from = Some(backfill_start);

                let app = app::App::new(config.clone(), pool.clone()).await?;
                app.run_backfill(Some(backfill_end)).await?;

                info!("Backfill completed, transitioning to live mode");

                // Restore original start_from for continuous mode
                config.ingest.start_from = original_start;
            }

            info!(
                start = ?config.ingest.start_from,
                "Starting continuous ingestion"
            );

            let app = app::App::new(config, pool).await?;
            app.run_continuous().await?;
        }
    }

    telemetry::shutdown();
    Ok(())
}