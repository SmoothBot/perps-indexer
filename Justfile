# Rust Indexer Justfile

# Load .env file
set dotenv-load

# Default recipe
default:
    @just --list

# Bootstrap the development environment
bootstrap:
    @echo "🚀 Setting up development environment..."
    @echo "📦 Updating Rust to latest stable..."
    rustup update stable
    rustup default stable
    rustup component add rustfmt clippy
    @echo "📦 Installing sqlx-cli..."
    cargo install sqlx-cli --no-default-features --features postgres --locked
    @echo "✅ Development environment ready!"

# Start local PostgreSQL with Docker
db-up:
    docker compose up -d postgres
    @echo "⏳ Waiting for PostgreSQL to be ready..."
    @sleep 3
    @echo "✅ PostgreSQL is running on localhost:5432"

# Stop local PostgreSQL
db-down:
    docker compose down

# Run database migrations
migrate:
    sqlx migrate run --source migrations --database-url ${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/hl_indexer}
    @echo "✅ Migrations applied"

# Rollback last migration
migrate-undo:
    sqlx migrate revert --source migrations --database-url ${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/hl_indexer}
    @echo "✅ Last migration reverted"

# Re-run all migrations (dangerous in production!)
migrate-redo: migrate-undo migrate
    @echo "✅ Migrations reset"

# Format code
fmt:
    cargo fmt --all

# Check formatting
fmt-check:
    cargo fmt --all -- --check

# Run clippy with strict settings
clippy:
    cargo clippy --all-targets --all-features -- -D warnings

# Run tests
test:
    cargo test --all

# Run tests with coverage (requires cargo-tarpaulin)
test-coverage:
    cargo tarpaulin --out Html --output-dir target/coverage

# Build the project
build:
    cargo build --release

# Run the indexer (migrate subcommand)
run-migrate:
    cargo run --bin indexer -- migrate

# Run backfill with optional start and end dates (or duration like "7d")
backfill START="" END="":
    #!/usr/bin/env bash
    ARGS=""

    # Check if START is a duration (e.g., "7d", "24h", "1w")
    if [ -n "{{START}}" ]; then
        if [[ "{{START}}" =~ ^([0-9]+)([dhw])$ ]]; then
            NUM="${BASH_REMATCH[1]}"
            UNIT="${BASH_REMATCH[2]}"

            case "$UNIT" in
                d)  # days
                    HOURS=$((NUM * 24))
                    ;;
                h)  # hours
                    HOURS=$NUM
                    ;;
                w)  # weeks
                    HOURS=$((NUM * 24 * 7))
                    ;;
            esac

            # Calculate start time from now minus duration
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS
                START_DATE=$(date -u -v-${HOURS}H '+%Y-%m-%dT%H:%M:%SZ')
            else
                # Linux
                START_DATE=$(date -u -d "${HOURS} hours ago" '+%Y-%m-%dT%H:%M:%SZ')
            fi

            echo "📊 Backfilling ${NUM}${UNIT} from $START_DATE"
            ARGS="$ARGS --start $START_DATE"
        else
            # Assume it's a date
            ARGS="$ARGS --start {{START}}"
        fi
    fi

    if [ -n "{{END}}" ]; then
        ARGS="$ARGS --end {{END}}"
    fi
    cargo run --release --bin indexer -- backfill $ARGS

# Run continuous ingestion with optional backfill duration (e.g., "just run 7d" or "just run 24h")
run DURATION="":
    #!/usr/bin/env bash
    if [ -n "{{DURATION}}" ]; then
        # Parse duration (e.g., 7d, 24h, 1w)
        if [[ "{{DURATION}}" =~ ^([0-9]+)([dhw])$ ]]; then
            NUM="${BASH_REMATCH[1]}"
            UNIT="${BASH_REMATCH[2]}"

            case "$UNIT" in
                d)  # days
                    HOURS=$((NUM * 24))
                    ;;
                h)  # hours
                    HOURS=$NUM
                    ;;
                w)  # weeks
                    HOURS=$((NUM * 24 * 7))
                    ;;
            esac

            # Calculate start time from now minus duration
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS
                BACKFILL_FROM=$(date -u -v-${HOURS}H '+%Y-%m-%dT%H:%M:%SZ')
            else
                # Linux
                BACKFILL_FROM=$(date -u -d "${HOURS} hours ago" '+%Y-%m-%dT%H:%M:%SZ')
            fi

            echo "📊 Starting run with ${NUM}${UNIT} backfill from $BACKFILL_FROM"
            cargo run --release --bin indexer -- run --backfill-from "$BACKFILL_FROM"
        else
            echo "❌ Invalid duration format. Use format like: 7d, 24h, 1w"
            exit 1
        fi
    else
        echo "🚀 Starting continuous ingestion (no backfill)"
        cargo run --release --bin indexer -- run
    fi

# Run continuous ingestion with backfill first (explicit dates)
run-with-backfill BACKFILL_FROM BACKFILL_TO="":
    #!/usr/bin/env bash
    ARGS="--backfill-from {{BACKFILL_FROM}}"
    if [ -n "{{BACKFILL_TO}}" ]; then
        ARGS="$ARGS --backfill-to {{BACKFILL_TO}}"
    fi
    cargo run --release --bin indexer -- run $ARGS

# Run with custom config file
run-with-config CONFIG:
    INDEXER__CONFIG_FILE={{CONFIG}} cargo run --release --bin indexer -- run

# Check the project
check:
    cargo check --all

# Run benchmarks
bench:
    cargo bench

# Clean build artifacts
clean:
    cargo clean
    rm -rf target/

# Run CI pipeline locally
ci: fmt-check clippy test
    @echo "✅ CI checks passed!"

# Watch for changes and rebuild
watch:
    cargo watch -x build -x test

# Generate and open documentation
docs:
    cargo doc --no-deps --open

# Show database connection string
db-url:
    @echo ${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/hl_indexer}

# Connect to PostgreSQL with psql
db-connect:
    psql ${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/hl_indexer}

# Show current checkpoints
show-checkpoints:
    @psql ${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/hl_indexer} -c "SELECT * FROM ingest_checkpoints;"

# Show recent fills
show-recent-fills LIMIT="10":
    @psql ${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/hl_indexer} -c "SELECT * FROM hl_fills ORDER BY timestamp DESC LIMIT {{LIMIT}};"

# Show daily stats
show-daily-stats DAYS="7":
    @psql ${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/hl_indexer} -c "SELECT * FROM hl_daily_stats WHERE date >= CURRENT_DATE - INTERVAL '{{DAYS}} days' ORDER BY date DESC, total_volume_usd DESC;"

# Reset checkpoint (use with caution!)
reset-checkpoint SOURCE="s3":
    @psql ${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/hl_indexer} -c "DELETE FROM ingest_checkpoints WHERE source = '{{SOURCE}}';"
    @echo "⚠️  Checkpoint for {{SOURCE}} has been reset"

# Docker build
docker-build:
    docker build -t hl-indexer:latest .

# Run everything needed for local development
dev: db-up migrate
    @echo "✅ Ready for development!"
    @echo "Run 'just run' to start the indexer"

# Full reset (dangerous!)
reset: db-down clean
    @echo "⚠️  Everything has been reset"

# Refresh all materialized views
refresh-matview:
    @echo "🔄 Refreshing all materialized views..."
    @echo "  🔄 Refreshing hourly_user_stats..."
    @docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_user_stats;" 2>/dev/null || docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW hourly_user_stats;" 2>/dev/null || echo "    ⚠️  Failed to refresh hourly_user_stats"
    @echo "  🔄 Refreshing hourly_market_stats..."
    @docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_market_stats;" 2>/dev/null || docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW hourly_market_stats;" 2>/dev/null || echo "    ⚠️  Failed to refresh hourly_market_stats"
    @echo "  🔄 Refreshing hourly_exchange_stats..."
    @docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW CONCURRENTLY hourly_exchange_stats;" 2>/dev/null || docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW hourly_exchange_stats;" 2>/dev/null || echo "    ⚠️  Failed to refresh hourly_exchange_stats"
    @echo "  🔄 Refreshing market_summary..."
    @docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW CONCURRENTLY market_summary;" 2>/dev/null || docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW market_summary;" 2>/dev/null || echo "    ⚠️  Failed to refresh market_summary"
    @echo "  🔄 Refreshing trader_summary..."
    @docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW CONCURRENTLY trader_summary;" 2>/dev/null || docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW trader_summary;" 2>/dev/null || echo "    ⚠️  Failed to refresh trader_summary"
    @echo "  🔄 Refreshing trader_market_summary..."
    @docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW CONCURRENTLY trader_market_summary;" 2>/dev/null || docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW trader_market_summary;" 2>/dev/null || echo "    ⚠️  Failed to refresh trader_market_summary"
    @echo "  🔄 Refreshing daily_market_stats..."
    @docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW CONCURRENTLY daily_market_stats;" 2>/dev/null || docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW daily_market_stats;" 2>/dev/null || echo "    ⚠️  Failed to refresh daily_market_stats"
    @echo "  🔄 Refreshing large_trades..."
    @docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW CONCURRENTLY large_trades;" 2>/dev/null || docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW large_trades;" 2>/dev/null || echo "    ⚠️  Failed to refresh large_trades"
    @echo "✅ All materialized views refreshed"

# Create the materialized view if it doesn't exist
create-matview:
    @echo "📊 Creating materialized view if not exists..."
    @docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -f - < scripts/ensure_matview.sql 2>/dev/null || \
        echo "⚠️  Failed to create view. Check database connection."