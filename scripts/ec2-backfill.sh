#!/bin/bash
set -e

# Script to run indexer backfill on EC2 with IAM role
# Assumes EC2 instance has proper IAM role attached with S3 access

# Configuration
START_DATE="${START_DATE:-2024-03-22T00:00:00Z}"
END_DATE="${END_DATE:-2024-03-23T00:00:00Z}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-hl_indexer}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-postgres}"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "Starting Hyperliquid Indexer Backfill"
echo "======================================="
echo "Start: $START_DATE"
echo "End: $END_DATE"
echo "Database: $DB_HOST:$DB_PORT/$DB_NAME"
echo "AWS Region: $AWS_REGION"
echo ""

# Build Docker image
echo "Building Docker image..."
docker build -t hl-indexer:latest .

# Run PostgreSQL if not using external database
if [ "$DB_HOST" = "localhost" ]; then
    echo "Starting local PostgreSQL..."
    docker run -d \
        --name indexer-postgres \
        -e POSTGRES_DB=$DB_NAME \
        -e POSTGRES_USER=$DB_USER \
        -e POSTGRES_PASSWORD=$DB_PASSWORD \
        -p $DB_PORT:5432 \
        -v $(pwd)/migrations:/docker-entrypoint-initdb.d:ro \
        postgres:15 \
        postgres \
        -c shared_buffers=2GB \
        -c work_mem=256MB \
        -c maintenance_work_mem=1GB \
        -c effective_cache_size=6GB \
        -c max_wal_size=2GB \
        -c checkpoint_timeout=15min

    # Wait for PostgreSQL to be ready
    echo "Waiting for PostgreSQL to be ready..."
    sleep 10

    # Run migrations
    echo "Running migrations..."
    docker exec -i indexer-postgres psql -U $DB_USER -d $DB_NAME < migrations/0001_complete_schema.sql
fi

# Run the indexer backfill
echo "Starting backfill process..."
docker run \
    --rm \
    --name hl-indexer-backfill \
    --network host \
    -e DATABASE_URL="postgresql://$DB_USER:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME" \
    -e AWS_REGION=$AWS_REGION \
    -e RUST_LOG=info,indexer=debug \
    -e INDEXER__TELEMETRY__ENABLED=false \
    -v ~/.aws:/home/indexer/.aws:ro \
    hl-indexer:latest \
    backfill \
    --start "$START_DATE" \
    --end "$END_DATE"

echo "Backfill complete!"

# Cleanup local PostgreSQL if used
if [ "$DB_HOST" = "localhost" ]; then
    echo "Cleaning up local PostgreSQL..."
    docker stop indexer-postgres
    docker rm indexer-postgres
fi