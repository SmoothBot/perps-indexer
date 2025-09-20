# Hyperliquid Historical Data Indexer

[![CI](https://github.com/example/rust-indexer/workflows/CI/badge.svg)](https://github.com/example/rust-indexer/actions)
[![License](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue.svg)](LICENSE)

Production-grade Rust indexer for ingesting Hyperliquid historical trading data from AWS S3 into PostgreSQL with comprehensive observability, fault tolerance, and performance optimization.

## Features

- **Incremental & Idempotent**: Checkpoint-based ingestion with automatic deduplication
- **Fault Tolerant**: Exponential backoff, retries, and graceful degradation
- **Observable**: Structured logging, Prometheus metrics, health endpoints
- **Performant**: Bounded channels, backpressure handling, concurrent processing
- **Configurable**: Environment variables, config files, CLI overrides
- **Production Ready**: Database migrations, Docker support, CI/CD pipeline

## Quick Start

### Prerequisites

- Rust 1.80+ (use `rustup update stable` to update)
- PostgreSQL 14+
- AWS CLI configured with **valid credentials** (for S3 bucket access)
- Docker & Docker Compose (optional)

### Setup

```bash
# Clone repository
git clone https://github.com/yourusername/rust-indexer.git
cd rust-indexer

# Install dependencies
just bootstrap

# Start PostgreSQL (with Docker)
just db-up

# Run migrations
just migrate

# Configure AWS credentials for S3 access
aws configure
# Enter your AWS Access Key ID, Secret Access Key, and set region to ap-northeast-1

# Copy and configure environment
cp .env.example .env
# Edit .env with your settings
```

### AWS Configuration

The indexer fetches historical data from the S3 bucket `hl-mainnet-node-data` in the `ap-northeast-1` region. You need valid AWS credentials with S3 read access to this bucket.

**Note**: The S3 bucket uses "requester pays", meaning you will be charged for data transfer costs (~$0.09 per GB).

### Running

```bash
# Backfill last 7 days (default)
just backfill

# Backfill specific date range
just backfill 2024-01-01T00:00:00Z

# Run continuous ingestion
just run

# Run with backfill before starting live mode
just run-with-backfill "2024-01-01T00:00:00Z"  # Backfill from date to NOW, then go live
just run-with-backfill "2024-01-01T00:00:00Z" "2024-01-20T00:00:00Z"  # Backfill range, then go live

# Or use cargo directly
cargo run --release --bin indexer -- backfill --start 2024-01-01T00:00:00Z
cargo run --release --bin indexer -- run
cargo run --release --bin indexer -- run --backfill-from 2024-01-01T00:00:00Z --backfill-to 2024-01-20T00:00:00Z
```

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│   AWS S3    │────▶│   Pipeline   │────▶│  PostgreSQL │
│ (HL Data)   │     │ (LZ4 Decode  │     │   (Indexed) │
└─────────────┘     │   & Process) │     └─────────────┘
                    └──────────────┘
                           │
                    ┌──────▼──────┐
                    │ Checkpoints │
                    │  (Resume)   │
                    └─────────────┘
```

### Components

- **Core Library** (`core/`): Shared utilities, error handling, configuration, and telemetry
- **Indexer Binary** (`indexer/`): Main application with pipeline implementation
- **Ingest**: S3 client for fetching historical data with LZ4 decompression
- **Store**: PostgreSQL operations with upsert and checkpoint management
- **Pipeline**: ETL orchestration with backpressure and retry logic

## Configuration

Configuration follows this precedence: CLI args > Environment vars > Config file > Defaults

### Environment Variables

```bash
# Database
INDEXER__DATABASE__URL=postgresql://user:pass@host:5432/dbname
INDEXER__DATABASE__MAX_CONNECTIONS=10

# Ingestion
INDEXER__INGEST__SOURCE__S3_BUCKET=hl-mainnet-node-data
INDEXER__INGEST__SOURCE__AWS_PROFILE=default  # Optional
INDEXER__INGEST__START_FROM=2025-03-22T00:00:00Z  # ISO 8601
INDEXER__INGEST__BATCH_SIZE=1000

# Pipeline
INDEXER__PIPELINE__CHANNEL_BUFFER_SIZE=1000
INDEXER__PIPELINE__CHECKPOINT_INTERVAL_SECS=60

# Telemetry
INDEXER__TELEMETRY__LOG_LEVEL=info
INDEXER__TELEMETRY__METRICS_PORT=9090
```

### Config File

Create `config.toml`:

```toml
[database]
url = "postgresql://localhost:5432/hl_indexer"
max_connections = 10

[ingest]
start_from = "2025-03-22T00:00:00Z"
batch_size = 1000

[ingest.source]
s3_bucket = "hl-mainnet-node-data"
aws_profile = "default"  # Optional
```

## Database Schema

### Main Tables

- **hl_fills**: Historical fill/trade data with indexes for efficient queries
- **hl_daily_stats**: Pre-aggregated daily statistics
- **hl_user_stats**: User trading metrics by period
- **ingest_checkpoints**: Resumable ingestion state tracking

### Migrations

```bash
# Run migrations
just migrate

# Rollback last migration
just migrate-undo

# Reset all migrations (DANGER!)
just migrate-redo
```

## Development

### Common Commands

```bash
# Development setup
just dev           # Start DB and run migrations

# Code quality
just fmt           # Format code
just clippy        # Lint with clippy
just test          # Run tests
just ci            # Run full CI locally

# Database inspection
just show-checkpoints       # View ingestion progress
just show-recent-fills 20   # Show recent data
just show-daily-stats 30    # Show daily statistics

# Utilities
just watch         # Auto-rebuild on changes
just docs          # Generate documentation
```

### Project Structure

```
rust-indexer/
├── core/              # Shared library (config, errors, telemetry)
├── indexer/           # Main binary
│   ├── src/
│   │   ├── ingest/   # Data source implementations
│   │   ├── model.rs  # Domain types
│   │   ├── store.rs  # Database operations
│   │   └── pipeline.rs # ETL orchestration
├── migrations/        # SQL migrations
└── Justfile          # Task automation
```

## Operations

### Monitoring

- **Metrics**: Prometheus endpoint at `:9090/metrics`
- **Health**: Health check endpoint (when implemented)
- **Logging**: Structured JSON logs with tracing

### Key Metrics

- `indexer_fills_inserted`: Number of fills inserted
- `indexer_checkpoints_saved`: Checkpoint saves
- `indexer_pipeline_queue_size`: Current queue depth
- `indexer_batch_duration_ms`: Processing time per batch
- `indexer_fetch_duration_ms`: API fetch latency

### Deployment

```bash
# Build release binary
cargo build --release

# Or use Docker
docker build -t hl-indexer:latest .
docker run -e DATABASE_URL=... hl-indexer:latest
```

### Production Checklist

- [ ] Configure connection pooling based on load
- [ ] Set appropriate rate limits for API
- [ ] Enable JSON logging for log aggregation
- [ ] Configure Prometheus scraping
- [ ] Set up alerting on key metrics
- [ ] Implement backup strategy for checkpoints
- [ ] Consider partitioning for hl_fills table at scale
- [ ] Set up read replicas for analytics queries

## Troubleshooting

### Common Issues

**Failed to connect to database**
- Check DATABASE_URL is correct
- Ensure PostgreSQL is running: `just db-up`
- Verify network connectivity

**Rate limit errors**
- Reduce `INDEXER__INGEST__RATE_LIMIT_PER_SECOND`
- Check API quota limits

**High memory usage**
- Decrease `INDEXER__PIPELINE__CHANNEL_BUFFER_SIZE`
- Reduce `INDEXER__INGEST__BATCH_SIZE`

**Checkpoint issues**
```bash
# View current checkpoint
just show-checkpoints

# Reset checkpoint (re-ingest from start)
just reset-checkpoint s3
```

## Performance Tuning

### Database
- Ensure proper indexes exist (created by migrations)
- Consider partitioning hl_fills by month for large datasets
- Tune PostgreSQL: increase shared_buffers, effective_cache_size
- Use connection pooling (configured via max_connections)

### Application
- Adjust batch_size based on memory and network
- Tune channel_buffer_size for backpressure
- Set max_concurrent_batches based on CPU cores
- Monitor metrics to identify bottlenecks

## Contributing

1. Fork the repository
2. Create a feature branch
3. Run `just ci` before committing
4. Submit a pull request

## License

MIT OR Apache-2.0