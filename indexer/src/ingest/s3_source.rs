use super::IngestSource;
use crate::model::{Fill, IngestBatch, TradeSide};
use async_trait::async_trait;
use aws_sdk_s3::Client as S3Client;
use chrono::{DateTime, NaiveDate, Timelike, Utc};
use indexer_core::{Error, Result};
use serde::Deserialize;
use tracing::{debug, instrument};

// Schema v3: node_fills_by_block (July 27, 2025 onwards)
#[derive(Debug, Clone, Deserialize)]
struct FillByBlock {
    events: Vec<FillEvent>,
    block_number: i64,
    #[serde(default)]
    block_time: Option<String>,
    #[serde(default)]
    local_time: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct FillEvent(String, FillData); // (user_address, fill_data)

#[derive(Debug, Clone, Deserialize)]
struct FillData {
    px: String,
    sz: String,
    coin: String,
    side: String,
    time: i64,
    fee: Option<String>,
    #[serde(rename = "closedPnl")]
    closed_pnl: Option<String>,
}

// Schema v2: node_fills (May 25, 2025 to July 26, 2025)
#[derive(Debug, Clone, Deserialize)]
struct NodeFill {
    user: String,
    px: String,
    sz: String,
    coin: String,
    side: String,
    time: i64,
    fee: Option<String>,
    #[serde(rename = "closedPnl")]
    closed_pnl: Option<String>,
}

// Schema v1: node_trades (March 22, 2025 to May 24, 2025)
#[derive(Debug, Clone, Deserialize)]
struct NodeTrade {
    px: String,
    sz: String,
    coin: String,
    time: i64,
    side_info: Vec<SideInfo>,
}

#[derive(Debug, Clone, Deserialize)]
struct SideInfo {
    user: String,
    side: String,
    fee: Option<String>,
}

pub struct S3Source {
    client: S3Client,
    bucket: String,
    aws_profile: Option<String>,
}

impl S3Source {
    pub async fn new(bucket: String, aws_profile: Option<String>) -> Result<Self> {
        let mut config_loader = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .region(aws_config::Region::new("ap-northeast-1"));

        if let Some(profile) = &aws_profile {
            config_loader = config_loader.profile_name(profile);
        }

        let config = config_loader.load().await;

        let client = S3Client::new(&config);

        Ok(Self {
            client,
            bucket,
            aws_profile,
        })
    }

    fn determine_data_path(&self, date: DateTime<Utc>) -> &'static str {
        if date >= DateTime::parse_from_rfc3339("2025-07-27T00:00:00Z").unwrap().with_timezone(&Utc) {
            "node_fills_by_block/hourly"
        } else if date >= DateTime::parse_from_rfc3339("2025-05-25T00:00:00Z").unwrap().with_timezone(&Utc) {
            "node_fills/hourly"
        } else if date >= DateTime::parse_from_rfc3339("2025-03-22T00:00:00Z").unwrap().with_timezone(&Utc) {
            "node_trades/hourly"
        } else {
            "node_trades/hourly" // Default to oldest format
        }
    }

    async fn fetch_hour_data(&self, date: DateTime<Utc>, hour: u32) -> Result<(Vec<u8>, u64)> {
        let data_path = self.determine_data_path(date);
        let date_str = date.format("%Y%m%d").to_string();
        let key = format!("{}/{}/{}.lz4", data_path, date_str, hour);

        debug!(
            bucket = %self.bucket,
            key = %key,
            "Fetching S3 object"
        );

        let response = self.client
            .get_object()
            .bucket(&self.bucket)
            .key(&key)
            .request_payer(aws_sdk_s3::types::RequestPayer::Requester)
            .send()
            .await
            .map_err(|e| {
                let details = match e {
                    aws_sdk_s3::error::SdkError::ServiceError(ref err) => {
                        format!("S3 service error for key '{}': {:?}", key, err)
                    }
                    _ => format!("Failed to fetch S3 key '{}': {}", key, e),
                };
                Error::Ingest {
                    source_name: "s3".to_string(),
                    details,
                }
            })?;

        let body = response.body.collect().await
            .map_err(|e| Error::Ingest {
                source_name: "s3".to_string(),
                details: format!("Failed to read S3 body: {}", e),
            })?;

        let compressed_data = body.into_bytes();
        let compressed_size = compressed_data.len() as u64;

        // Decompress LZ4 data using the frame decoder which handles the LZ4 frame format
        use std::io::Read;
        let mut decoder = lz4_flex::frame::FrameDecoder::new(&compressed_data[..]);
        let mut decompressed = Vec::new();
        decoder.read_to_end(&mut decompressed)
            .map_err(|e| Error::Ingest {
                source_name: "s3".to_string(),
                details: format!("Failed to decompress LZ4 data: {}", e),
            })?;

        Ok((decompressed, compressed_size))
    }

    fn parse_fills(&self, data: &[u8], date: DateTime<Utc>) -> Result<Vec<Fill>> {
        let mut fills = Vec::new();
        let data_str = std::str::from_utf8(data)
            .map_err(|e| Error::Validation(format!("Invalid UTF-8 data: {}", e)))?;

        // Each line is a JSON object
        for line in data_str.lines() {
            if line.is_empty() {
                continue;
            }

            if date >= DateTime::parse_from_rfc3339("2025-07-27T00:00:00Z").unwrap().with_timezone(&Utc) {
                // Parse as FillByBlock
                let block_data: FillByBlock = serde_json::from_str(line)
                    .map_err(|e| Error::Validation(format!("Failed to parse FillByBlock: {}", e)))?;

                for event in block_data.events {
                    match self.parse_fill_data(
                        event.0,
                        event.1,
                        Some(block_data.block_number),
                    ) {
                        Ok(fill) => fills.push(fill),
                        Err(e) => {
                            // Skip records with unknown side values
                            debug!("Skipping fill: {}", e);
                        }
                    }
                }
            } else if date >= DateTime::parse_from_rfc3339("2025-05-25T00:00:00Z").unwrap().with_timezone(&Utc) {
                // Parse as NodeFill
                let node_fill: NodeFill = serde_json::from_str(line)
                    .map_err(|e| Error::Validation(format!("Failed to parse NodeFill: {}", e)))?;

                let fill = self.parse_node_fill(node_fill)?;
                fills.push(fill);
            } else {
                // Parse as NodeTrade
                let node_trade: NodeTrade = serde_json::from_str(line)
                    .map_err(|e| Error::Validation(format!("Failed to parse NodeTrade: {}", e)))?;

                for side_info in &node_trade.side_info {
                    let fill = self.parse_trade_fill(
                        &node_trade,
                        side_info.clone(),
                    )?;
                    fills.push(fill);
                }
            }
        }

        Ok(fills)
    }

    fn parse_fill_data(
        &self,
        user_address: String,
        fill: FillData,
        block_number: Option<i64>,
    ) -> Result<Fill> {
        let side = match fill.side.to_uppercase().as_str() {
            "BUY" | "B" => TradeSide::Buy,
            "SELL" | "S" | "A" => TradeSide::Sell,  // A = Ask = Sell
            _ => return Err(Error::Validation(format!("Invalid side: {}", fill.side))),
        };

        let price = fill.px.parse::<f64>()
            .map_err(|_| Error::Validation(format!("Invalid price: {}", fill.px)))?;

        let size = fill.sz.parse::<f64>()
            .map_err(|_| Error::Validation(format!("Invalid size: {}", fill.sz)))?;

        let fee = fill.fee.and_then(|f| f.parse::<f64>().ok());
        let closed_pnl = fill.closed_pnl.and_then(|p| p.parse::<f64>().ok());

        let timestamp = DateTime::<Utc>::from_timestamp_millis(fill.time)
            .ok_or_else(|| Error::Validation(format!("Invalid timestamp: {}", fill.time)))?;

        Ok(Fill {
            user_address,
            coin: fill.coin,
            side,
            price,
            size,
            fee,
            closed_pnl,
            timestamp,
            block_number,
            source_id: None,
        })
    }

    fn parse_node_fill(&self, node_fill: NodeFill) -> Result<Fill> {
        let side = match node_fill.side.to_uppercase().as_str() {
            "BUY" | "B" => TradeSide::Buy,
            "SELL" | "S" | "A" => TradeSide::Sell,  // A = Ask = Sell
            _ => return Err(Error::Validation(format!("Invalid side: {}", node_fill.side))),
        };

        let price = node_fill.px.parse::<f64>()
            .map_err(|_| Error::Validation(format!("Invalid price: {}", node_fill.px)))?;

        let size = node_fill.sz.parse::<f64>()
            .map_err(|_| Error::Validation(format!("Invalid size: {}", node_fill.sz)))?;

        let fee = node_fill.fee.and_then(|f| f.parse::<f64>().ok());
        let closed_pnl = node_fill.closed_pnl.and_then(|p| p.parse::<f64>().ok());

        let timestamp = DateTime::<Utc>::from_timestamp_millis(node_fill.time)
            .ok_or_else(|| Error::Validation(format!("Invalid timestamp: {}", node_fill.time)))?;

        Ok(Fill {
            user_address: node_fill.user,
            coin: node_fill.coin,
            side,
            price,
            size,
            fee,
            closed_pnl,
            timestamp,
            block_number: None,
            source_id: None,
        })
    }

    fn parse_trade_fill(
        &self,
        trade: &NodeTrade,
        side_info: SideInfo,
    ) -> Result<Fill> {
        let side = match side_info.side.to_uppercase().as_str() {
            "BUY" | "B" => TradeSide::Buy,
            "SELL" | "S" | "A" => TradeSide::Sell,  // A = Ask = Sell
            _ => return Err(Error::Validation(format!("Invalid side: {}", side_info.side))),
        };

        let price = trade.px.parse::<f64>()
            .map_err(|_| Error::Validation(format!("Invalid price: {}", trade.px)))?;

        let size = trade.sz.parse::<f64>()
            .map_err(|_| Error::Validation(format!("Invalid size: {}", trade.sz)))?;

        let fee = side_info.fee.and_then(|f| f.parse::<f64>().ok());

        let timestamp = DateTime::<Utc>::from_timestamp_millis(trade.time)
            .ok_or_else(|| Error::Validation(format!("Invalid timestamp: {}", trade.time)))?;

        Ok(Fill {
            user_address: side_info.user,
            coin: trade.coin.clone(),
            side,
            price,
            size,
            fee,
            closed_pnl: None,
            timestamp,
            block_number: None,
            source_id: None,
        })
    }
}

#[async_trait]
impl IngestSource for S3Source {
    #[instrument(skip(self))]
    async fn fetch_page(
        &self,
        start_from: DateTime<Utc>,
        cursor: Option<String>,
    ) -> Result<IngestBatch> {
        // Parse cursor to determine current position
        let (current_date, current_hour) = if let Some(cursor) = cursor {
            let parts: Vec<&str> = cursor.split('_').collect();
            if parts.len() == 2 {
                let date = NaiveDate::parse_from_str(parts[0], "%Y%m%d")
                    .map_err(|e| Error::Validation(format!("Invalid cursor date: {}", e)))?;
                let hour = parts[1].parse::<u32>()
                    .map_err(|e| Error::Validation(format!("Invalid cursor hour: {}", e)))?;
                (date.and_hms_opt(hour, 0, 0).unwrap().and_utc(), hour)
            } else {
                (start_from, start_from.hour())
            }
        } else {
            (start_from, start_from.hour())
        };

        // Fetch data for the current hour
        let (data, bytes_downloaded) = self.fetch_hour_data(current_date, current_hour).await?;
        let fills = self.parse_fills(&data, current_date)?;

        // Calculate next cursor
        let mut next_date = current_date;
        let mut next_hour = current_hour + 1;
        if next_hour >= 24 {
            next_hour = 0;
            next_date = next_date + chrono::Duration::days(1);
        }

        let next_cursor = format!("{}_{}", next_date.format("%Y%m%d"), next_hour);

        // Check if we have more data (simple heuristic: check if we're not in the future)
        let has_more = next_date < Utc::now();

        debug!(
            fills_count = fills.len(),
            has_more,
            next_cursor = %next_cursor,
            "Fetched S3 data"
        );

        Ok(IngestBatch {
            fills,
            cursor: Some(next_cursor),
            has_more,
            bytes_downloaded: Some(bytes_downloaded),
        })
    }

    fn source_id(&self) -> &str {
        "s3"
    }

    async fn health_check(&self) -> Result<()> {
        // Try to list objects to verify access
        let result = self.client
            .list_objects_v2()
            .bucket(&self.bucket)
            .max_keys(1)
            .request_payer(aws_sdk_s3::types::RequestPayer::Requester)
            .send()
            .await;

        match result {
            Ok(_) => Ok(()),
            Err(e) => Err(Error::Ingest {
                source_name: self.source_id().to_string(),
                details: format!("S3 health check failed: {}", e),
            }),
        }
    }
}