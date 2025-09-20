#!/bin/bash

echo "🔧 Fixing build issues..."

# Add missing dependencies to workspace Cargo.toml
echo "📦 Adding missing dependencies..."
cat >> Cargo.toml <<'EOF'

# Add missing deps
rust_decimal = { version = "1.36", features = ["serde"] }
EOF

# Fix sqlx features in workspace
sed -i '' 's/sqlx = { version = "0.8", features = \["runtime-tokio-rustls", "postgres", "chrono", "uuid", "migrate"\] }/sqlx = { version = "0.8", features = ["runtime-tokio-rustls", "postgres", "chrono", "uuid", "migrate", "bigdecimal"] }/' Cargo.toml

echo "✅ Dependencies fixed"
echo "🔧 Run 'cargo build' to compile the project"