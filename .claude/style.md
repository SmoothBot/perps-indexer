# Rust Style Guide

## Code Conventions

### API Design
- Prefer traits for abstraction boundaries
- Use `async_trait` only when necessary (prefer static dispatch)
- Return `Result<T>` from fallible operations
- Use newtypes for domain concepts (e.g., `RecordId(u64)`)
- Builder pattern for complex constructors

### Error Handling
```rust
// Always preserve context
use thiserror::Error;

#[derive(Error, Debug)]
pub enum IndexError {
    #[error("failed to ingest from {source}: {reason}")]
    IngestFailed { source: String, reason: String },

    #[error("transform validation failed: {0}")]
    ValidationError(String),
}

// Use Result alias
pub type Result<T> = std::result::Result<T, IndexError>;
```

### Concurrency Patterns
```rust
// Bounded channels for backpressure
let (tx, rx) = tokio::sync::mpsc::channel(1000);

// Graceful shutdown
let shutdown = tokio::sync::broadcast::channel(1);

// Select with biased ordering for priority
tokio::select! {
    biased;
    _ = shutdown_signal() => { /* cleanup */ }
    msg = rx.recv() => { /* process */ }
}
```

### Performance Guidelines
- Avoid allocations in hot paths
- Use `Cow<'a, str>` for maybe-owned strings
- Prefer `bytes::Bytes` for zero-copy
- Profile before optimizing
- Document performance characteristics in comments

### Testing Strategy
```rust
#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    // Unit tests: focused, fast
    #[test]
    fn test_specific_behavior() { }

    // Property tests: invariants
    proptest! {
        #[test]
        fn test_invariant(input in any::<String>()) { }
    }
}

// Integration tests in tests/
// Benchmarks in benches/
```

### Logging & Metrics
```rust
// Structured logging
tracing::info!(
    record_id = %id,
    duration_ms = elapsed.as_millis(),
    "processed record"
);

// Metrics with labels
metrics::counter!("indexer_records_total", "status" => "success").increment(1);
```

## Code Organization

### Module Structure
- One concept per module
- Public API at top of file
- Private implementation below
- Tests at bottom in `#[cfg(test)]` block

### Imports
```rust
// Standard library
use std::collections::HashMap;
use std::sync::Arc;

// External crates (alphabetical)
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

// Internal crates
use crate::config::Config;
use crate::error::Result;

// Local modules
use super::transform::Transformer;
```

### Documentation
```rust
/// Processes records through the indexing pipeline.
///
/// # Arguments
/// * `source` - Data source to ingest from
/// * `config` - Pipeline configuration
///
/// # Errors
/// Returns `IndexError::IngestFailed` if source is unavailable
///
/// # Example
/// ```
/// let pipeline = Pipeline::new(config)?;
/// pipeline.run(source).await?;
/// ```
pub async fn run(&self, source: Source) -> Result<()> {
```

## Security & Safety

### Input Validation
- Validate at system boundaries
- Use strong types (NonZeroU64, etc.)
- Sanitize user input
- Rate limit external operations

### Memory Safety
- Avoid `unsafe` unless absolutely necessary
- When using `unsafe`, wrap in safe abstraction
- Document safety invariants
- Use `#[deny(unsafe_code)]` in most modules

### Dependency Management
- Minimal dependencies
- Regular `cargo audit`
- Pin major versions
- Review transitive dependencies

## Commit Conventions
```
feat(ingest): add S3 source support
fix(transform): handle empty records correctly
perf(index): optimize batch writes
docs(api): update query examples
test(pipeline): add backpressure tests
refactor(config): simplify validation logic
```

## Review Checklist
- [ ] Tests pass locally (`just test`)
- [ ] Clippy warnings addressed (`just clippy`)
- [ ] Format checked (`just fmt`)
- [ ] Performance impact considered
- [ ] Error handling comprehensive
- [ ] Metrics/logging added
- [ ] Documentation updated
- [ ] Security implications reviewed