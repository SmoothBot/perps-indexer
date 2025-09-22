# EC2 Deployment Guide for Hyperliquid Indexer

## Prerequisites

1. **EC2 Instance Requirements**:
   - Ubuntu 22.04 or later
   - Minimum 8GB RAM (16GB+ recommended for production)
   - 100GB+ storage
   - IAM role attached with S3 read permissions for your data buckets

2. **IAM Role Configuration**:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "s3:GetObject",
           "s3:ListBucket"
         ],
         "Resource": [
           "arn:aws:s3:::your-bucket-name/*",
           "arn:aws:s3:::your-bucket-name"
         ]
       }
     ]
   }
   ```

## Deployment Options

### Option 1: Using Docker Compose (Recommended)

1. **Install Docker and Docker Compose**:
   ```bash
   sudo apt update
   sudo apt install -y docker.io docker-compose
   sudo usermod -aG docker ubuntu
   # Log out and back in for group changes to take effect
   ```

2. **Clone the repository**:
   ```bash
   git clone https://github.com/your-repo/rust-indexer.git
   cd rust-indexer
   ```

3. **Run with Docker Compose**:
   ```bash
   # For a specific date range
   docker-compose up --build

   # Or modify the command in docker-compose.yaml for your date range
   ```

### Option 2: Using the Bash Script

1. **Clone and prepare**:
   ```bash
   git clone https://github.com/your-repo/rust-indexer.git
   cd rust-indexer
   ```

2. **Run the backfill script**:
   ```bash
   # Set your date range
   export START_DATE="2024-03-22T00:00:00Z"
   export END_DATE="2024-03-23T00:00:00Z"

   # Run the script
   ./scripts/ec2-backfill.sh
   ```

### Option 3: Using systemd Service

1. **Copy service file**:
   ```bash
   sudo cp scripts/indexer-backfill.service /etc/systemd/system/
   ```

2. **Edit configuration**:
   ```bash
   sudo systemctl edit indexer-backfill.service
   ```
   Add your environment overrides:
   ```ini
   [Service]
   Environment="START_DATE=2024-03-22T00:00:00Z"
   Environment="END_DATE=2024-03-23T00:00:00Z"
   ```

3. **Start the service**:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl start indexer-backfill.service
   sudo systemctl status indexer-backfill.service
   ```

4. **View logs**:
   ```bash
   sudo journalctl -u indexer-backfill.service -f
   ```

## Using External PostgreSQL

If you have an existing PostgreSQL instance (RDS, etc.):

1. **Set environment variables**:
   ```bash
   export DB_HOST="your-database.region.rds.amazonaws.com"
   export DB_PORT="5432"
   export DB_NAME="hl_indexer"
   export DB_USER="postgres"
   export DB_PASSWORD="your-secure-password"
   ```

2. **Run migrations first**:
   ```bash
   psql -h $DB_HOST -U $DB_USER -d $DB_NAME < migrations/0001_complete_schema.sql
   ```

3. **Run the indexer**:
   ```bash
   ./scripts/ec2-backfill.sh
   ```

## Monitoring

### Check Docker logs:
```bash
docker logs -f hl-indexer-backfill
```

### Check PostgreSQL data:
```bash
docker exec -it indexer-postgres psql -U postgres -d hl_indexer -c "SELECT COUNT(*) FROM hl_fills;"
```

### Monitor system resources:
```bash
htop
docker stats
```

## Performance Tuning

### PostgreSQL Settings (already configured in scripts):
- `shared_buffers=2GB`
- `work_mem=256MB`
- `maintenance_work_mem=1GB`
- `effective_cache_size=6GB`
- `max_wal_size=2GB`

### Indexer Settings:
Adjust in the Docker run command or environment:
- `RUST_LOG=info` (or `debug` for more verbose output)
- `INDEXER__TELEMETRY__ENABLED=false` (disable telemetry for better performance)

## Troubleshooting

1. **IAM Permissions Issues**:
   ```bash
   # Test S3 access
   aws s3 ls s3://your-bucket-name/
   ```

2. **Out of Memory**:
   - Increase instance size
   - Reduce batch size in indexer configuration

3. **Slow Performance**:
   - Check disk I/O with `iostat`
   - Ensure instance has sufficient CPU and memory
   - Consider using instance-store backed instances for better I/O

4. **Database Connection Issues**:
   - Check security groups allow PostgreSQL port (5432)
   - Verify DATABASE_URL is correct
   - Check PostgreSQL logs: `docker logs indexer-postgres`

## Production Recommendations

1. Use dedicated RDS PostgreSQL instance
2. Enable automated backups
3. Set up CloudWatch monitoring
4. Use Auto Scaling Groups for horizontal scaling
5. Consider using ECS or EKS for container orchestration
6. Set up proper VPC with private subnets for database