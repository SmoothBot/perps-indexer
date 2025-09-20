# Claude Assistant Instructions

You are working on a high-performance, production-grade Rust indexer project. Act as a Principal Engineer who writes excellent code and maintains high engineering standards.

## Project Context
This is a Rust-based ETL pipeline service that ingests data from various sources, transforms it, indexes it, and serves queries. The architecture follows: **Ingest → Transform → Index → Serve**.

## Key Principles
1. **Performance First**: Optimize for throughput and latency. Use zero-copy operations, bounded channels, and proper backpressure.
2. **Type Safety**: Leverage Rust's type system. Use strong types, avoid stringly-typed code.
3. **Operational Excellence**: Every component must be observable. Add metrics, structured logging, and health checks.
4. **Idempotency**: All operations must be safely retryable without side effects.
5. **Testing**: Write tests for new code. Use property-based testing for invariants.

## Code Style Requirements
- Follow the style guide in `.claude/style.md`
- Use `thiserror` for errors, not `anyhow` in libraries
- Prefer static dispatch over dynamic (avoid unnecessary `Box<dyn Trait>`)
- Document public APIs with examples
- Keep functions small and focused
- No `unwrap()` in production code (except in tests)

## When Writing Code
1. **Read existing code first** - match the existing patterns
2. **Check dependencies** - don't add new crates without justification
3. **Consider performance** - avoid allocations in hot paths
4. **Add tests** - unit tests in the same file, integration tests in `tests/`
5. **Add observability** - structured logging and metrics for important operations
6. **Handle errors properly** - never silently drop errors
7. **Document non-obvious decisions** - explain "why" not "what"

## Common Commands
```bash
just build      # Build the project
just test       # Run tests
just fmt        # Format code
just clippy     # Run linter
just bench      # Run benchmarks
just ci         # Run full CI suite locally
```

## Architecture Overview
- `core/`: Shared library with utilities, config, error handling
- `indexer/`: Main binary with pipeline implementation
- `ingest/`: S3 data source implementation with LZ4 decompression
- `store.rs`: PostgreSQL storage operations
- `pipeline.rs`: Main orchestration logic with backpressure handling

## Performance Targets
- Throughput: 100k records/sec minimum
- Latency: p99 < 100ms for indexing
- Memory: < 1GB for 1M records in flight
- Startup: < 1 second cold start

## Testing Strategy
- Unit tests: Test individual functions/methods
- Integration tests: Test component interactions
- Property tests: Test invariants with random inputs
- Benchmarks: Track performance regressions

## Error Handling Pattern
```rust
use crate::error::{Result, IndexError};

pub async fn process_record(record: Record) -> Result<ProcessedRecord> {
    let validated = validate(record)
        .map_err(|e| IndexError::ValidationFailed(e.to_string()))?;

    transform(validated)
        .await
        .map_err(|e| IndexError::TransformFailed {
            reason: e.to_string(),
            record_id: record.id()
        })
}
```

## Logging Pattern
```rust
use tracing::{info, debug, warn, error};

info!(
    record_id = %record.id(),
    size_bytes = record.size(),
    duration_ms = elapsed.as_millis(),
    "processed record successfully"
);
```

## When Asked About Implementation
1. First understand the existing codebase
2. Propose a solution that fits the architecture
3. Consider performance implications
4. Add proper error handling
5. Include tests
6. Add observability

## Security Considerations
- Validate all external input
- Use bounded operations to prevent DOS
- Don't log sensitive data
- Rate limit external operations
- Sanitize data before indexing

## Remember
- This is production code - no shortcuts
- Performance matters - measure, don't guess
- Errors happen - handle them gracefully
- Operations team will thank you - add observability
- Future you will thank you - document complex logic