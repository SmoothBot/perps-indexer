# Grafana Dashboard for Hyperliquid Indexer

## Overview
This Grafana setup provides comprehensive visualization of Hyperliquid trading data with real-time analytics and monitoring capabilities.

## Features

### Dashboard Panels
1. **Hourly Trading Volume** - Time series chart showing volume trends
2. **Active Traders** - Current number of unique traders
3. **Total Trades** - Aggregate trade count
4. **Total Volume** - Sum of all trading volume in USD
5. **Total PnL** - Combined profit/loss across all traders
6. **Top Coins by Volume** - Pie chart of most traded coins
7. **Hourly PnL** - Time series of profit/loss over time
8. **Active Traders Over Time** - Trend of trader participation
9. **Top Traders** - Table showing highest volume traders with metrics
10. **Hourly Fees Collected** - Fee revenue visualization

### Interactive Filters
- **Time Range**: 1h, 6h, 12h, 24h, 7d, 30d
- **Coin Filter**: Select specific coin or view all
- **Auto-refresh**: 30-second intervals

## Quick Start

### 1. Start Services

```bash
# Start PostgreSQL and Grafana
docker-compose up -d postgres grafana

# Or start everything
docker-compose up -d
```

### 2. Access Grafana

Open your browser and navigate to:
```
http://localhost:3000
```

**Default Credentials:**
- Username: `admin`
- Password: `admin`

### 3. Dashboard Location

The Hyperliquid Trading Analytics dashboard is automatically provisioned and available at:
- Dashboard → Browse → Hyperliquid Trading Analytics

## Configuration

### Data Source
The PostgreSQL data source is automatically configured with:
- Host: `postgres:5432`
- Database: `hl_indexer`
- User: `postgres`
- Password: `postgres`
- SSL Mode: Disabled

### Refresh Materialized View
For best performance, refresh the materialized view after backfill operations:

```bash
docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "SELECT refresh_hourly_user_stats();"
```

## Dashboard Customization

### Modifying Queries
All panels use SQL queries against the `hl_hourly_user_stats` materialized view. You can edit any panel to modify the query.

Example query structure:
```sql
SELECT
  hour AS time,
  SUM(volume)::float AS "Total Volume"
FROM hl_hourly_user_stats
WHERE hour >= NOW() - INTERVAL '$time_range'
GROUP BY hour
ORDER BY hour ASC
```

### Adding New Panels
1. Click "Add panel" in the dashboard
2. Select PostgreSQL as the data source
3. Write your SQL query
4. Choose appropriate visualization type

### Useful Queries

**Trader Performance by Coin:**
```sql
SELECT
  coin,
  user_address,
  SUM(volume) as volume,
  SUM(total_pnl) as pnl,
  SUM(trade_count) as trades
FROM hl_hourly_user_stats
WHERE hour >= NOW() - INTERVAL '24 hours'
GROUP BY coin, user_address
ORDER BY volume DESC
```

**Hourly Buy vs Sell Volume:**
```sql
SELECT
  hour AS time,
  SUM(buy_volume)::float AS "Buy Volume",
  SUM(sell_volume)::float AS "Sell Volume"
FROM hl_hourly_user_stats
WHERE hour >= NOW() - INTERVAL '24 hours'
GROUP BY hour
ORDER BY hour ASC
```

**Most Profitable Hours:**
```sql
SELECT
  EXTRACT(hour FROM hour) as hour_of_day,
  AVG(total_pnl)::float as avg_pnl,
  SUM(total_pnl)::float as total_pnl
FROM hl_hourly_user_stats
GROUP BY hour_of_day
ORDER BY total_pnl DESC
```

## Troubleshooting

### Grafana Won't Start
```bash
# Check logs
docker-compose logs grafana

# Restart service
docker-compose restart grafana
```

### No Data Showing
1. Ensure PostgreSQL has data:
```bash
docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "SELECT COUNT(*) FROM hl_fills;"
```

2. Refresh materialized view:
```bash
docker exec hl_indexer_postgres psql -U postgres -d hl_indexer -c "REFRESH MATERIALIZED VIEW CONCURRENTLY hl_hourly_user_stats;"
```

### Connection Issues
Ensure both containers are on the same network:
```bash
docker network ls
docker network inspect rust-indexer_indexer_network
```

## Performance Tips

1. **Use Time Filters**: Always filter by time range to reduce query load
2. **Refresh Materialized Views**: Run after each backfill for latest data
3. **Index Usage**: The materialized view has optimized indexes for common queries
4. **Limit Results**: Use LIMIT clauses in table panels

## Export/Import Dashboards

### Export
1. Go to Dashboard settings (gear icon)
2. Click "JSON Model"
3. Copy the JSON

### Import
1. Click "+" → "Import"
2. Paste JSON or upload file
3. Select PostgreSQL data source
4. Click "Import"

## Additional Resources

- [Grafana Documentation](https://grafana.com/docs/)
- [PostgreSQL in Grafana](https://grafana.com/docs/grafana/latest/datasources/postgres/)
- [Dashboard Best Practices](https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/best-practices/)