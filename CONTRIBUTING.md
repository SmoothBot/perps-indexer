# Contributing to Rust Indexer

Thank you for your interest in contributing to Rust Indexer! This document provides guidelines and information for contributors.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Coding Standards](#coding-standards)
- [Testing Guidelines](#testing-guidelines)
- [Documentation](#documentation)
- [Submitting Changes](#submitting-changes)
- [Review Process](#review-process)
- [Release Process](#release-process)

## Code of Conduct

This project adheres to the [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## Getting Started

### Prerequisites

- Rust 1.75+ (MSRV - Minimum Supported Rust Version)
- Git
- Docker (for integration tests)
- Just (optional, for convenience commands)

### Development Setup

1. **Fork and Clone**
   ```bash
   git clone https://github.com/YOUR_USERNAME/rust-indexer.git
   cd rust-indexer
   ```

2. **Install Dependencies**
   ```bash
   just install
   # or manually:
   rustup component add rustfmt clippy
   cargo install cargo-audit cargo-outdated cargo-machete
   pip install pre-commit
   pre-commit install
   ```

3. **Verify Setup**
   ```bash
   just check
   ```

### Project Structure

```
rust-indexer/
├── core/              # Shared library crate
│   ├── src/
│   │   ├── config.rs  # Configuration management
│   │   ├── error.rs   # Error types and handling
│   │   ├── telemetry.rs # Tracing and metrics
│   │   └── ...
├── indexer/           # Main binary crate
│   ├── src/
│   │   ├── pipeline.rs # Core pipeline logic
│   │   ├── ingest/    # Data ingestion
│   │   ├── transform/ # Data transformation
│   │   └── index/     # Data indexing
├── docs/              # Additional documentation
└── .github/           # CI/CD and templates
```

## Development Workflow

### Branch Strategy

- `main`: Stable release branch
- `develop`: Integration branch for features
- `feature/*`: Feature development branches
- `fix/*`: Bug fix branches
- `docs/*`: Documentation updates

### Workflow Steps

1. **Create Feature Branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make Changes**
   - Follow coding standards
   - Add tests for new functionality
   - Update documentation

3. **Test Changes**
   ```bash
   just check  # Runs fmt, clippy, test, audit
   ```

4. **Commit Changes**
   ```bash
   git add .
   git commit -m "feat: add new pipeline component"
   ```

5. **Push and Create PR**
   ```bash
   git push origin feature/your-feature-name
   # Create PR via GitHub UI
   ```

### Commit Message Format

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, etc.)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Build process or auxiliary tool changes
- `perf`: Performance improvements
- `ci`: CI/CD changes

Examples:
```
feat(pipeline): add retry mechanism for failed batches
fix(config): handle missing configuration file gracefully
docs: update installation instructions
test(transform): add unit tests for data normalization
```

## Coding Standards

### Rust Style Guide

We follow the [Rust Style Guide](https://doc.rust-lang.org/style-guide/) with project-specific additions:

#### Formatting
- Use `rustfmt` with the project's configuration
- Line length: 100 characters
- 4 spaces for indentation
- Unix line endings

#### Naming Conventions
- `snake_case` for functions, variables, modules
- `PascalCase` for types, structs, enums
- `SCREAMING_SNAKE_CASE` for constants
- `kebab-case` for crate names

#### Code Organization
```rust
// Order of items in modules:
// 1. use statements (std, external crates, internal)
// 2. Constants
// 3. Type definitions
// 4. Public structs/enums
// 5. Implementations
// 6. Private helpers
// 7. Tests

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use tracing::{error, info};

use crate::error::IndexerError;

const DEFAULT_BATCH_SIZE: usize = 1000;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PipelineConfig {
    pub batch_size: usize,
    pub max_concurrent_batches: usize,
}

impl PipelineConfig {
    pub fn new() -> Self {
        Self {
            batch_size: DEFAULT_BATCH_SIZE,
            max_concurrent_batches: 10,
        }
    }
}
```

#### Error Handling
- Use `thiserror` for error types
- Provide context with error chains
- Log errors at appropriate levels
- Use `Result<T, E>` for fallible operations

```rust
use thiserror::Error;

#[derive(Error, Debug)]
pub enum PipelineError {
    #[error("Configuration error: {message}")]
    Config { message: String },

    #[error("Processing failed for batch {batch_id}")]
    Processing { batch_id: u64, source: Box<dyn std::error::Error + Send + Sync> },

    #[error("IO error")]
    Io(#[from] std::io::Error),
}
```

#### Async Programming
- Use `async/await` with Tokio
- Prefer bounded channels for backpressure
- Handle cancellation gracefully
- Use `tokio::select!` for multiple futures

```rust
use tokio::sync::mpsc;
use tokio::time::{timeout, Duration};

async fn process_with_timeout(data: Data) -> Result<ProcessedData, ProcessingError> {
    timeout(Duration::from_secs(30), process_data(data))
        .await
        .map_err(|_| ProcessingError::Timeout)?
}
```

#### Documentation
- Use `///` for public API documentation
- Include examples in doc comments
- Document invariants and panics
- Use `//!` for module-level documentation

```rust
/// Processes a batch of documents through the transformation pipeline.
///
/// This function applies all configured transformations to the input documents
/// and returns the processed results. The operation respects cancellation
/// tokens and implements timeout handling.
///
/// # Arguments
///
/// * `documents` - A vector of documents to process
/// * `config` - Transformation configuration
/// * `cancel_token` - Cancellation token for graceful shutdown
///
/// # Returns
///
/// Returns `Ok(Vec<ProcessedDocument>)` on success, or an error if processing fails.
///
/// # Errors
///
/// This function will return an error if:
/// - Document validation fails
/// - Transformation plugins encounter errors
/// - The operation times out
/// - The operation is cancelled
///
/// # Examples
///
/// ```rust
/// use indexer::transform::{process_batch, TransformConfig};
///
/// let config = TransformConfig::default();
/// let documents = vec![/* ... */];
/// let result = process_batch(documents, &config, cancel_token).await?;
/// ```
pub async fn process_batch(
    documents: Vec<Document>,
    config: &TransformConfig,
    cancel_token: CancellationToken,
) -> Result<Vec<ProcessedDocument>, TransformError> {
    // Implementation...
}
```

## Testing Guidelines

### Test Structure

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use tokio::sync::Notify;

    #[tokio::test]
    async fn test_pipeline_processes_batch_successfully() {
        // Arrange
        let config = PipelineConfig::new();
        let pipeline = Pipeline::new(config).await.unwrap();
        let test_data = create_test_documents(10);

        // Act
        let result = pipeline.process_batch(test_data).await;

        // Assert
        assert!(result.is_ok());
        let processed = result.unwrap();
        assert_eq!(processed.len(), 10);
    }

    #[test]
    fn test_config_validation_rejects_invalid_batch_size() {
        let mut config = PipelineConfig::new();
        config.batch_size = 0;

        let result = config.validate();

        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ConfigError::InvalidBatchSize));
    }
}
```

### Test Categories

1. **Unit Tests**: Test individual functions and methods
   ```bash
   cargo test --lib
   ```

2. **Integration Tests**: Test component interactions
   ```bash
   cargo test --test integration
   ```

3. **Property Tests**: Use `proptest` for property-based testing
   ```rust
   use proptest::prelude::*;

   proptest! {
       #[test]
       fn test_pipeline_preserves_document_count(
           docs in prop::collection::vec(any::<TestDocument>(), 1..1000)
       ) {
           let rt = tokio::runtime::Runtime::new().unwrap();
           rt.block_on(async {
               let result = process_documents(docs.clone()).await.unwrap();
               prop_assert_eq!(result.len(), docs.len());
           });
       }
   }
   ```

4. **Benchmark Tests**: Use `criterion` for performance testing
   ```rust
   use criterion::{black_box, criterion_group, criterion_main, Criterion};

   fn benchmark_pipeline(c: &mut Criterion) {
       let rt = tokio::runtime::Runtime::new().unwrap();
       c.bench_function("pipeline_1000_docs", |b| {
           b.to_async(&rt).iter(|| async {
               let docs = create_test_documents(1000);
               black_box(process_documents(docs).await.unwrap())
           })
       });
   }
   ```

### Test Data and Fixtures

- Use builder pattern for test data
- Create reusable test fixtures
- Mock external dependencies
- Use `wiremock` for HTTP service mocking

```rust
pub struct TestDocumentBuilder {
    id: Option<String>,
    content: Option<String>,
    metadata: HashMap<String, String>,
}

impl TestDocumentBuilder {
    pub fn new() -> Self {
        Self {
            id: None,
            content: None,
            metadata: HashMap::new(),
        }
    }

    pub fn with_id(mut self, id: impl Into<String>) -> Self {
        self.id = Some(id.into());
        self
    }

    pub fn with_content(mut self, content: impl Into<String>) -> Self {
        self.content = Some(content.into());
        self
    }

    pub fn build(self) -> Document {
        Document {
            id: self.id.unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
            content: self.content.unwrap_or_else(|| "test content".to_string()),
            metadata: self.metadata,
        }
    }
}
```

## Documentation

### Types of Documentation

1. **API Documentation**: Generated from doc comments
2. **User Guide**: High-level usage instructions (README.md)
3. **Architecture Documentation**: Design decisions and structure
4. **Runbook**: Operational procedures

### Writing Guidelines

- Write for your audience (users vs. developers)
- Include practical examples
- Keep documentation up-to-date with code changes
- Use diagrams for complex architectures
- Provide troubleshooting guides

### Architecture Decision Records (ADRs)

Document significant decisions in `docs/adr/`:

```markdown
# ADR-001: Choose Tracing Framework

## Status
Accepted

## Context
We need observability for the indexer pipeline...

## Decision
We will use the `tracing` crate...

## Consequences
- Pros: Structured logging, OpenTelemetry integration
- Cons: Learning curve for team
```

## Submitting Changes

### Pull Request Checklist

Before submitting a PR, ensure:

- [ ] Code follows style guidelines
- [ ] All tests pass (`just check`)
- [ ] New functionality has tests
- [ ] Documentation is updated
- [ ] Commit messages follow convention
- [ ] PR description is complete
- [ ] No merge conflicts

### PR Description Template

Use the provided [PR template](.github/PULL_REQUEST_TEMPLATE.md) and include:

- Clear description of changes
- Motivation and context
- Breaking changes (if any)
- Testing instructions
- Related issues

### Security Considerations

For security-related changes:

- Follow secure coding practices
- Update threat model if needed
- Consider backward compatibility
- Document security implications
- Request security review

## Review Process

### Review Criteria

Reviewers will check:

1. **Correctness**: Does the code work as intended?
2. **Performance**: Are there performance implications?
3. **Security**: Are there security considerations?
4. **Maintainability**: Is the code readable and maintainable?
5. **Testing**: Are there adequate tests?
6. **Documentation**: Is documentation complete and accurate?

### Review Timeline

- Initial review: 2-3 business days
- Follow-up reviews: 1-2 business days
- Security reviews: 3-5 business days

### Addressing Feedback

- Respond to all review comments
- Ask questions if feedback is unclear
- Make requested changes promptly
- Update tests and documentation as needed

## Release Process

### Version Strategy

We follow [Semantic Versioning](https://semver.org/):

- **Major**: Breaking changes
- **Minor**: New features (backward compatible)
- **Patch**: Bug fixes (backward compatible)

### Release Checklist

1. Update version numbers
2. Update CHANGELOG.md
3. Run full test suite
4. Create release PR
5. Tag release after merge
6. Publish to crates.io
7. Update documentation

### Hotfix Process

For critical issues:

1. Create hotfix branch from main
2. Apply minimal fix
3. Fast-track review process
4. Release immediately
5. Backport to develop

## Getting Help

- 📖 [Documentation](https://docs.rs/rust-indexer)
- 💬 [GitHub Discussions](https://github.com/example/rust-indexer/discussions)
- 🐛 [Issue Tracker](https://github.com/example/rust-indexer/issues)
- 📧 [Maintainer Email](mailto:maintainers@example.com)

## Recognition

Contributors will be:

- Listed in CONTRIBUTORS.md
- Mentioned in release notes
- Invited to maintainer discussions (for significant contributions)

Thank you for contributing to Rust Indexer! 🦀