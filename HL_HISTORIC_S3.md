# AWS S3 Hyperliquid Historical Data Documentation

## Overview

Hyperliquid provides historical trading and market data through AWS S3 buckets. This document details all available data sources, their formats, access methods, and usage examples.

## Prerequisites

### Required Tools

1. **AWS CLI**
   - Installation guide: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
   - Configure with appropriate credentials

2. **LZ4 Compression Tool**
   - GitHub: https://github.com/lz4/lz4
   - Or install via package manager:
     ```bash
     # macOS
     brew install lz4

     # Ubuntu/Debian
     apt-get install lz4

     # RHEL/CentOS
     yum install lz4
     ```

### Important Notes

- **Requester Pays**: The requester of the data must pay for AWS transfer costs
- **Transfer Rate**: $0.09 per GB for data transfer out of AWS S3
- **Compression**: All data is LZ4 compressed to reduce transfer costs

## Data Buckets Overview

| Bucket | Description | Update Frequency | Data Types |
|--------|-------------|------------------|------------|
| `hyperliquid-archive` | Market data and asset contexts | Monthly | L2 book snapshots, asset contexts |
| `hl-mainnet-node-data` | Trade fills and node data | Real-time streaming | Fills, trades, blocks, transactions |

## 1. Market Data (hyperliquid-archive)

### Asset Market Data

#### L2 Book Snapshots

**Format**: `s3://hyperliquid-archive/market_data/[date]/[hour]/[datatype]/[coin].lz4`

- `[date]`: YYYYMMDD format (e.g., 20230916)
- `[hour]`: 0-23 (hour of day)
- `[datatype]`: Currently only `l2Book`
- `[coin]`: Trading symbol (e.g., BTC, ETH, SOL)

**Example Download**:
```bash
# Download SOL L2 book data for Sept 16, 2023, hour 9
aws s3 cp s3://hyperliquid-archive/market_data/20230916/9/l2Book/SOL.lz4 \
  /tmp/SOL.lz4 \
  --request-payer requester

# Decompress the file
unlz4 --rm /tmp/SOL.lz4

# View first few lines
head /tmp/SOL
```

#### Asset Contexts

**Format**: `s3://hyperliquid-archive/asset_ctxs/[date].csv.lz4`

- Contains asset context information for each day
- CSV format when decompressed

**Example Download**:
```bash
# Download asset contexts for a specific date
aws s3 cp s3://hyperliquid-archive/asset_ctxs/20230916.csv.lz4 \
  /tmp/asset_ctxs.csv.lz4 \
  --request-payer requester

# Decompress
unlz4 /tmp/asset_ctxs.csv.lz4

# View the CSV
cat /tmp/asset_ctxs.csv
```

### Data Not Available

The following data sets are **NOT** provided via S3:
- Candles/OHLCV data
- Spot asset data
- Real-time order book updates

*Note: You can use the Hyperliquid API to record these data sets yourself.*

## 2. Trade Data (hl-mainnet-node-data)

### Current Format: node_fills_by_block

**Path**: `s3://hl-mainnet-node-data/node_fills_by_block/hourly/[date]/[hour].lz4`

- Newest format (July 27, 2024 onwards)
- Fills grouped by blockchain block
- Streamed via `--write-fills --batch-by-block`

**Schema**:
```json
{
  "events": [
    [
      "0xUserAddress",
      {
        "px": "price",
        "sz": "size",
        "coin": "symbol",
        "side": "BUY/SELL",
        "time": timestamp_ms,
        "fee": "fee_amount",
        "closedPnl": "realized_pnl"
      }
    ]
  ],
  "block": block_number,
  "timestamp": unix_timestamp
}
```

**Example Download**:
```bash
# Download fills for March 22, 2024, hour 0
aws s3 cp s3://hl-mainnet-node-data/node_fills_by_block/hourly/20240322/0.lz4 \
  fills.lz4 \
  --request-payer requester \
  --profile YourAWSProfile

# Decompress
lz4 -d fills.lz4 fills.json

# Process the JSON lines
cat fills.json | jq '.'
```

### Legacy Format: node_fills

**Path**: `s3://hl-mainnet-node-data/node_fills/hourly/[date]/[hour].lz4`

- Used from May 25, 2024 to July 26, 2024
- Matches the API format
- Individual fill records

**Schema**:
```json
{
  "user": "0xUserAddress",
  "px": "price",
  "sz": "size",
  "coin": "symbol",
  "side": "BUY/SELL",
  "time": timestamp_ms,
  "fee": "fee_amount",
  "closedPnl": "realized_pnl"
}
```

### Legacy Format: node_trades

**Path**: `s3://hl-mainnet-node-data/node_trades/hourly/[date]/[hour].lz4`

- Used from March 22, 2024 to May 24, 2024
- Does NOT match the API format
- Contains both sides of trades

**Schema**:
```json
{
  "px": "price",
  "sz": "size",
  "coin": "symbol",
  "time": timestamp_ms,
  "side_info": [
    {
      "user": "0xUserAddress1",
      "side": "BUY",
      "fee": "fee_amount"
    },
    {
      "user": "0xUserAddress2",
      "side": "SELL",
      "fee": "fee_amount"
    }
  ]
}
```

## 3. Node Historical Data

### Explorer Blocks

**Path**: `s3://hl-mainnet-node-data/explorer_blocks/`

- Contains historical blockchain explorer block data
- Useful for blockchain analysis and verification

### L1 Transactions

**Path**: `s3://hl-mainnet-node-data/replica_cmds/`

- Historical L1 (Layer 1) transaction data
- Contains command replicas from the mainnet

## Python Implementation Examples

### Fetch and Process Trade Data

```python
import json
import subprocess
from datetime import datetime, timedelta
from collections import defaultdict

class HyperliquidS3Fetcher:
    def __init__(self, aws_profile=None):
        self.aws_profile = aws_profile or "default"

    def determine_data_path(self, date_obj):
        """Determine correct S3 path based on date"""
        if date_obj >= datetime(2024, 7, 27):
            return "s3://hl-mainnet-node-data/node_fills_by_block/hourly"
        elif date_obj >= datetime(2024, 5, 25):
            return "s3://hl-mainnet-node-data/node_fills/hourly"
        elif date_obj >= datetime(2024, 3, 22):
            return "s3://hl-mainnet-node-data/node_trades/hourly"
        else:
            raise ValueError(f"No data available before March 22, 2024")

    def fetch_hour_data(self, date_str, hour):
        """Fetch one hour of data"""
        date_obj = datetime.strptime(date_str, "%Y%m%d")
        s3_base = self.determine_data_path(date_obj)
        s3_path = f"{s3_base}/{date_str}/{hour}.lz4"
        local_file = f"temp_{date_str}_{hour}.lz4"

        # Download from S3
        cmd = [
            "aws", "s3", "cp", s3_path, local_file,
            "--request-payer", "requester",
            "--profile", self.aws_profile,
            "--quiet"
        ]

        try:
            result = subprocess.run(cmd, capture_output=True, timeout=30)
            if result.returncode != 0:
                return None

            # Decompress
            decompressed = local_file.replace('.lz4', '.json')
            subprocess.run(["lz4", "-d", local_file, decompressed], check=True)

            # Parse and return data
            with open(decompressed, 'r') as f:
                data = [json.loads(line) for line in f]

            # Cleanup
            subprocess.run(["rm", local_file, decompressed])

            return data

        except Exception as e:
            print(f"Error fetching {date_str} hour {hour}: {e}")
            return None

    def process_fills_data(self, data, date_obj):
        """Process data based on schema version"""
        user_volumes = defaultdict(float)

        for entry in data:
            if date_obj >= datetime(2024, 7, 27):
                # node_fills_by_block format
                for event in entry.get('events', []):
                    if len(event) >= 2:
                        user = event[0]
                        fill = event[1]
                        volume = float(fill['px']) * float(fill['sz'])
                        user_volumes[user] += volume

            elif date_obj >= datetime(2024, 5, 25):
                # node_fills format
                user = entry['user']
                volume = float(entry['px']) * float(entry['sz'])
                user_volumes[user] += volume

            else:
                # node_trades format
                px = float(entry['px'])
                sz = float(entry['sz'])
                for side in entry.get('side_info', []):
                    user = side['user']
                    # Split volume between participants
                    volume = (px * sz) / len(entry.get('side_info', []))
                    user_volumes[user] += volume

        return user_volumes
```

### Fetch Market Data

```python
def fetch_l2_book_snapshot(date_str, hour, coin, output_dir="/tmp"):
    """Fetch L2 book snapshot for a specific coin"""

    s3_path = f"s3://hyperliquid-archive/market_data/{date_str}/{hour}/l2Book/{coin}.lz4"
    local_file = f"{output_dir}/{coin}_{date_str}_{hour}.lz4"

    # Download
    cmd = [
        "aws", "s3", "cp", s3_path, local_file,
        "--request-payer", "requester"
    ]

    result = subprocess.run(cmd, capture_output=True)

    if result.returncode == 0:
        # Decompress
        decompressed = local_file.replace('.lz4', '')
        subprocess.run(["unlz4", "--rm", local_file])

        # Read and return data
        with open(decompressed, 'r') as f:
            return f.read()

    return None

# Example usage
book_data = fetch_l2_book_snapshot("20230916", 9, "SOL")
```

## Cost Optimization Tips

### 1. Batch Downloads
```bash
# Download multiple hours at once
for hour in {0..23}; do
  aws s3 cp s3://hl-mainnet-node-data/node_fills_by_block/hourly/20240322/${hour}.lz4 \
    data_${hour}.lz4 \
    --request-payer requester &
done
wait
```

### 2. Use AWS CLI Filters
```bash
# List available dates
aws s3 ls s3://hl-mainnet-node-data/node_fills_by_block/hourly/ \
  --request-payer requester
```

### 3. Parallel Processing
```python
from concurrent.futures import ThreadPoolExecutor

def fetch_day_parallel(date_str, max_workers=4):
    """Fetch all 24 hours in parallel"""
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = []
        for hour in range(24):
            future = executor.submit(fetch_hour_data, date_str, hour)
            futures.append(future)

        results = [f.result() for f in futures]
        return results
```

## Data Availability Timeline

| Start Date | End Date | Data Type | Location |
|------------|----------|-----------|----------|
| 2023-09-16 | Ongoing | Market Data | `hyperliquid-archive` |
| 2024-03-22 | 2024-05-24 | Trade Data (v1) | `node_trades` |
| 2024-05-25 | 2024-07-26 | Fill Data (v2) | `node_fills` |
| 2024-07-27 | Ongoing | Fill Data (v3) | `node_fills_by_block` |

## Error Handling

### Common Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| `NoSuchKey` | Data doesn't exist for that date/hour | Check data availability timeline |
| `AccessDenied` | Missing `--request-payer` flag | Add `--request-payer requester` |
| `InvalidRequest` | Wrong bucket or path | Verify path format and date |
| `RequestTimeout` | Network issues | Implement retry logic |

## Best Practices

1. **Always use `--request-payer requester`** flag for all S3 operations
2. **Implement checkpointing** for large data fetches to resume on failure
3. **Clean up temporary files** after processing to save disk space
4. **Use parallel downloads** for better throughput
5. **Compress processed data** before storing locally
6. **Monitor AWS costs** regularly as you pay for data transfer

## Additional Resources

- Official Hyperliquid Documentation: https://hyperliquid.gitbook.io/
- AWS S3 Pricing: https://aws.amazon.com/s3/pricing/
- LZ4 Documentation: https://github.com/lz4/lz4

## Support

For issues related to:
- **Data availability**: Check the Hyperliquid Discord or documentation
- **AWS access**: Verify your AWS credentials and permissions
- **Data format**: Refer to the schema documentation above