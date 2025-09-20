# Rust Indexer Project

## Project Overview
High-performance, production-grade Rust indexer service implementing an ETL pipeline:
**Ingest → Transform → Index → Serve**

## Architecture
```
┌─────────┐     ┌────────────┐     ┌─────────┐     ┌──────────┐
│ Sources │────▶│ Transform  │────▶│  Index  │────▶│  Query   │
│ (Files, │     │ (Validate, │     │ (Store, │     │  (API,   │
│  APIs)  │     │  Enrich)   │     │ Search) │     │ Metrics) │
└─────────┘     └────────────┘     └─────────┘     └──────────┘
     ▲               ▲                   ▲               ▲
     │               │                   │               │
     └───────────────┴───────────────────┴───────────────┘
                    Backpressure & Retry Logic
```

## Core Principles
1. **Performance First**: Zero-copy where possible, bounded channels, backpressure
2. **Operational Excellence**: Comprehensive observability, graceful degradation
3. **Type Safety**: Leverage Rust's type system, minimal unsafe code
4. **Idempotency**: All operations must be safely retryable
5. **Testing**: Property-based testing, benchmarks, integration tests

## Project Structure
```
rust-indexer/
├── core/                 # Shared library (domain, utilities)
│   ├── src/
│   │   ├── config.rs    # Configuration management
│   │   ├── error.rs     # Error types and handling
│   │   ├── telemetry.rs # Tracing and logging
│   │   ├── metrics.rs   # Metrics facade
│   │   ├── backoff.rs   # Retry logic
│   │   └── parallel.rs  # Concurrency utilities
│   └── Cargo.toml
├── indexer/             # Main binary
│   ├── src/
│   │   ├── main.rs      # CLI entry point
│   │   ├── app.rs       # Application wiring
│   │   ├── ingest/      # Data sources
│   │   ├── transform/   # Data processing
│   │   ├── index/       # Storage backends
│   │   ├── pipeline.rs  # ETL orchestration
│   │   └── health.rs    # Health checks
│   └── Cargo.toml
├── benches/             # Performance benchmarks
├── docs/                # Architecture and operations
└── tests/               # Integration tests
```

## Key Dependencies
- **tokio**: Async runtime
- **tracing**: Structured logging
- **clap**: CLI interface
- **serde**: Serialization
- **metrics**: Telemetry
- **thiserror**: Error handling
- **backoff**: Retry logic
- **criterion**: Benchmarking

## Performance Targets
- Throughput: 100k records/sec baseline
- Latency: p99 < 100ms for indexing
- Memory: < 1GB for 1M records in flight
- Startup: < 1 second cold start

## Operational Requirements
- Graceful shutdown with drain
- Health/readiness endpoints
- Structured logging (JSON)
- Prometheus metrics
- Feature flags for rollout
- Circuit breakers for dependencies