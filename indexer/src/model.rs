use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Fill {
    pub user_address: String,
    pub coin: String,
    pub side: TradeSide,
    pub price: f64,
    pub size: f64,
    pub fee: Option<f64>,
    pub closed_pnl: Option<f64>,
    pub timestamp: DateTime<Utc>,
    pub block_number: Option<i64>,
    pub source_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "text")]
#[sqlx(rename_all = "UPPERCASE")]
pub enum TradeSide {
    Buy,
    Sell,
}

impl std::fmt::Display for TradeSide {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TradeSide::Buy => write!(f, "BUY"),
            TradeSide::Sell => write!(f, "SELL"),
        }
    }
}

#[derive(Debug, Clone, FromRow)]
pub struct FillRow {
    pub id: Uuid,
    pub user_address: String,
    pub coin: String,
    pub side: String,
    pub price: rust_decimal::Decimal,
    pub size: rust_decimal::Decimal,
    pub fee: Option<rust_decimal::Decimal>,
    pub closed_pnl: Option<rust_decimal::Decimal>,
    pub timestamp: DateTime<Utc>,
    pub block_number: Option<i64>,
    pub source_id: Option<String>,
    pub ingested_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IngestBatch {
    pub fills: Vec<Fill>,
    pub cursor: Option<String>,
    pub has_more: bool,
    pub bytes_downloaded: Option<u64>,
}

#[derive(Debug, Clone, FromRow)]
pub struct Checkpoint {
    pub source: String,
    pub cursor: Option<String>,
    pub last_record_ts: Option<DateTime<Utc>>,
    pub last_block_number: Option<i64>,
    pub records_processed: i64,
    pub updated_at: DateTime<Utc>,
    pub metadata: Option<serde_json::Value>,
}

impl Checkpoint {
    pub fn new(source: String) -> Self {
        Self {
            source,
            cursor: None,
            last_record_ts: None,
            last_block_number: None,
            records_processed: 0,
            updated_at: Utc::now(),
            metadata: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DailyStats {
    pub date: chrono::NaiveDate,
    pub coin: String,
    pub total_volume_usd: f64,
    pub buy_volume_usd: f64,
    pub sell_volume_usd: f64,
    pub total_trades: i32,
    pub unique_traders: i32,
    pub open_price: Option<f64>,
    pub high_price: Option<f64>,
    pub low_price: Option<f64>,
    pub close_price: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserStats {
    pub user_address: String,
    pub period_start: DateTime<Utc>,
    pub period_end: DateTime<Utc>,
    pub total_volume_usd: f64,
    pub total_trades: i32,
    pub total_pnl: Option<f64>,
    pub total_fees: Option<f64>,
}