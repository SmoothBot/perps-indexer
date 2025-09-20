# Development Workflow

## Quick Commands

### Build & Test
```bash
just build      # Compile all crates
just test       # Run all tests
just bench      # Run benchmarks
just fmt        # Format code
just clippy     # Lint code
just ci         # Run full CI locally
```

### Development
```bash
just run        # Run indexer with default config
just watch      # Auto-rebuild on changes
just docs       # Generate and open docs
```

### Common Tasks

#### Adding a New Data Source
1. Create module in `indexer/src/ingest/`
2. Implement `IngestSource` trait
3. Add configuration in `core/src/config.rs`
4. Register in `indexer/src/app.rs`
5. Add tests in module
6. Add integration test
7. Update documentation

#### Adding a New Index Backend
1. Create module in `indexer/src/index/`
2. Implement `Indexer` trait
3. Add configuration options
4. Wire in `pipeline.rs`
5. Add benchmarks
6. Document performance characteristics

#### Performance Optimization
1. Profile first: `just profile <scenario>`
2. Benchmark baseline: `just bench -- --baseline`
3. Make changes
4. Benchmark again: `just bench`
5. Compare results
6. Document in commit message

## Testing Approach

### Test Levels
- **Unit**: Internal logic, single module
- **Integration**: Cross-module, real I/O
- **Property**: Invariants, fuzzing
- **Benchmark**: Performance regression

### Running Tests
```bash
just test              # All tests
just test-unit         # Unit tests only
just test-integration  # Integration tests
cargo test --doc       # Doc tests
```

## Debugging

### Logging
```bash
RUST_LOG=debug just run           # Debug level
RUST_LOG=indexer=trace just run   # Trace for indexer
RUST_LOG=warn,indexer=debug       # Mixed levels
```

### Performance
```bash
just profile cpu       # CPU profiling
just profile mem       # Memory profiling
just trace            # Generate trace for analysis
```

### Common Issues

#### High Memory Usage
1. Check channel bounds in `pipeline.rs`
2. Verify batch sizes in config
3. Profile with `just profile mem`
4. Look for unbounded growth in metrics

#### Slow Processing
1. Enable trace logging for timing
2. Check metrics for bottlenecks
3. Profile hot paths
4. Verify parallelism settings

#### Failed Ingestion
1. Check source connectivity
2. Verify credentials/permissions
3. Look for retry exhaustion in logs
4. Check circuit breaker status

## Release Process

### Version Bump
```bash
cargo set-version --bump minor    # Bump version
cargo set-version 1.2.3          # Set specific
```

### Release Checklist
1. [ ] Update CHANGELOG.md
2. [ ] Run `just ci`
3. [ ] Create git tag: `git tag -a v1.2.3`
4. [ ] Push tag: `git push origin v1.2.3`
5. [ ] CI builds and publishes
6. [ ] Update deployment docs

## Code Review

### Before Submitting PR
1. Run `just ci` locally
2. Self-review changes
3. Update relevant docs
4. Add tests for new code
5. Check metrics/logging
6. Verify error handling

### PR Description Template
```markdown
## Changes
- Brief description of what changed

## Type
- [ ] Bug fix
- [ ] Feature
- [ ] Performance
- [ ] Refactor

## Testing
- How was this tested?

## Performance Impact
- Expected impact on throughput/latency

## Checklist
- [ ] Tests pass
- [ ] Docs updated
- [ ] Metrics added
- [ ] No security issues
```

## Operational

### Monitoring
- Health endpoint: `http://localhost:8080/health`
- Metrics endpoint: `http://localhost:8080/metrics`
- Default dashboards in `docs/dashboards/`

### Configuration
- Environment variables override file config
- Config file: `config/default.toml`
- Override: `INDEXER_LOG_LEVEL=trace`
- Feature flags: `INDEXER_FEATURES=new_parser`

### Deployment
- Docker: `docker build -t indexer .`
- Kubernetes: `kubectl apply -f deploy/`
- Systemd: `sudo systemctl start indexer`

### Troubleshooting Commands
```bash
# Check configuration
just run -- check

# Validate config file
just run -- validate config/prod.toml

# Dry run
just run -- --dry-run

# Reindex specific range
just run -- reindex --from 2024-01-01 --to 2024-01-02
```