# Multi-stage build for Rust indexer
FROM rust:1.75-slim as builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /app

# Copy manifest files
COPY Cargo.toml Cargo.lock ./
COPY core/Cargo.toml core/
COPY indexer/Cargo.toml indexer/

# Create dummy files to build dependencies
RUN mkdir -p core/src indexer/src && \
    echo "fn main() {}" > indexer/src/main.rs && \
    echo "pub fn dummy() {}" > core/src/lib.rs

# Build dependencies
RUN cargo build --release --bin indexer

# Remove dummy files
RUN rm -rf core/src indexer/src

# Copy actual source code
COPY core/src core/src
COPY indexer/src indexer/src

# Build the actual application
RUN touch indexer/src/main.rs && \
    cargo build --release --bin indexer

# Runtime stage
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy binary from builder
COPY --from=builder /app/target/release/indexer /usr/local/bin/indexer

# Copy migration files
COPY migrations /migrations

# Copy the backfill loop script
COPY scripts/backfill-loop.sh /usr/local/bin/backfill-loop.sh
RUN chmod +x /usr/local/bin/backfill-loop.sh

# Create non-root user
RUN useradd -m -u 1000 indexer && \
    chown -R indexer:indexer /migrations

USER indexer

# Set environment variables for AWS SDK to use IAM role
ENV AWS_REGION=us-east-1
ENV DATABASE_URL=postgresql://postgres:postgres@postgres:5432/hl_indexer

# Default to backfill command
ENTRYPOINT ["/usr/local/bin/indexer"]
CMD ["backfill"]