use serde::Deserialize;
use sqlx::PgPool;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use indexer_core::Result;
use tracing::{debug, info, warn};

/// Market metadata cache
pub struct MarketRegistry {
    pool: PgPool,
    exchange_id: i32,
    markets: Arc<RwLock<HashMap<String, MarketInfo>>>,
    api_endpoint: String,
}

#[derive(Debug, Clone)]
pub struct MarketInfo {
    pub id: i32,
    pub market_id: String,
    pub symbol: String,
    pub market_type: MarketType,
    pub base_asset: String,
    pub quote_asset: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum MarketType {
    Spot,
    Perp,
}

impl std::fmt::Display for MarketType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MarketType::Spot => write!(f, "spot"),
            MarketType::Perp => write!(f, "perp"),
        }
    }
}

// Hyperliquid API response structures
#[derive(Debug, Deserialize)]
struct HyperliquidMeta {
    universe: Vec<AssetInfo>,
}

#[derive(Debug, Deserialize)]
struct HyperliquidSpotMeta {
    tokens: Vec<SpotToken>,
    universe: Vec<SpotAsset>,
}

#[derive(Debug, Deserialize)]
struct AssetInfo {
    name: String,
    #[serde(rename = "szDecimals")]
    sz_decimals: u32,
}

#[derive(Debug, Deserialize)]
struct SpotToken {
    name: String,
    #[serde(rename = "tokenId")]
    token_id: String,
    #[serde(rename = "isCanonical")]
    is_canonical: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct SpotAsset {
    name: String,
    tokens: Vec<u32>,
}

impl MarketRegistry {
    pub async fn new(pool: PgPool, exchange_id: i32) -> Result<Self> {
        let api_endpoint = "https://api.hyperliquid.xyz/info".to_string();

        let registry = Self {
            pool,
            exchange_id,
            markets: Arc::new(RwLock::new(HashMap::new())),
            api_endpoint,
        };

        // Load existing markets from database
        registry.load_markets_from_db().await?;

        // Fetch latest metadata from API
        if let Err(e) = registry.refresh_metadata().await {
            warn!("Failed to refresh market metadata from API: {}", e);
        }

        Ok(registry)
    }

    async fn load_markets_from_db(&self) -> Result<()> {
        let markets = sqlx::query!(
            r#"
            SELECT id, market_id, symbol, market_type, base_asset, quote_asset
            FROM markets
            WHERE exchange_id = $1 AND is_active = true
            "#,
            self.exchange_id
        )
        .fetch_all(&self.pool)
        .await?;

        let mut cache = self.markets.write().await;
        for market in markets {
            let market_type = match market.market_type.as_str() {
                "spot" => MarketType::Spot,
                "perp" => MarketType::Perp,
                _ => continue,
            };

            let info = MarketInfo {
                id: market.id,
                market_id: market.market_id.clone(),
                symbol: market.symbol,
                market_type,
                base_asset: market.base_asset.unwrap_or_else(|| market.market_id.clone()),
                quote_asset: market.quote_asset.unwrap_or_else(|| "USD".to_string()),
            };

            cache.insert(market.market_id, info);
        }

        info!("Loaded {} markets from database", cache.len());
        Ok(())
    }

    pub async fn refresh_metadata(&self) -> Result<()> {
        info!("Refreshing market metadata from Hyperliquid API");

        let client = reqwest::Client::new();

        // Fetch perpetual markets metadata
        let perp_response = client
            .post(&self.api_endpoint)
            .json(&serde_json::json!({
                "type": "meta"
            }))
            .send()
            .await?;

        let perp_meta: HyperliquidMeta = perp_response.json().await?;

        // Process perpetual markets
        for asset in &perp_meta.universe {
            let market_id = &asset.name;
            let symbol = format!("{}-USD", market_id);

            self.upsert_market(
                market_id,
                &symbol,
                MarketType::Perp,
                market_id,
                "USD",
            ).await?;
        }

        // Fetch spot markets metadata
        let spot_response = client
            .post(&self.api_endpoint)
            .json(&serde_json::json!({
                "type": "spotMeta"
            }))
            .send()
            .await?;

        let spot_meta: HyperliquidSpotMeta = spot_response.json().await?;

        // Process spot markets - use tokens array for market info
        for (index, token) in spot_meta.tokens.iter().enumerate() {
            let market_id = format!("@{}", index);
            let symbol = format!("{}/USD", token.name);

            self.upsert_market(
                &market_id,
                &symbol,
                MarketType::Spot,
                &token.name,
                "USD",
            ).await?;
        }

        info!(
            "Refreshed metadata: {} perps, {} spot markets",
            perp_meta.universe.len(),
            spot_meta.tokens.len()
        );

        Ok(())
    }

    async fn upsert_market(
        &self,
        market_id: &str,
        symbol: &str,
        market_type: MarketType,
        base_asset: &str,
        quote_asset: &str,
    ) -> Result<()> {
        let id = sqlx::query_scalar!(
            r#"
            INSERT INTO markets (exchange_id, market_id, symbol, market_type, base_asset, quote_asset)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (exchange_id, market_id) DO UPDATE SET
                symbol = EXCLUDED.symbol,
                market_type = EXCLUDED.market_type,
                base_asset = EXCLUDED.base_asset,
                quote_asset = EXCLUDED.quote_asset,
                updated_at = NOW()
            RETURNING id
            "#,
            self.exchange_id,
            market_id,
            symbol,
            market_type.to_string(),
            base_asset,
            quote_asset
        )
        .fetch_one(&self.pool)
        .await?;

        // Update cache
        let info = MarketInfo {
            id,
            market_id: market_id.to_string(),
            symbol: symbol.to_string(),
            market_type,
            base_asset: base_asset.to_string(),
            quote_asset: quote_asset.to_string(),
        };

        self.markets.write().await.insert(market_id.to_string(), info);

        Ok(())
    }

    pub async fn get_or_create_market(&self, market_id: &str) -> Result<i32> {
        // Check cache first
        {
            let cache = self.markets.read().await;
            if let Some(info) = cache.get(market_id) {
                return Ok(info.id);
            }
        }

        // Not in cache, try to get from database or create
        let id = sqlx::query_scalar!(
            r#"SELECT get_or_create_market($1, $2) as "id!""#,
            self.exchange_id,
            market_id
        )
        .fetch_one(&self.pool)
        .await?;

        // Try to refresh metadata to get proper market info
        if let Err(e) = self.refresh_metadata().await {
            debug!("Failed to refresh metadata for new market {}: {}", market_id, e);
        }

        Ok(id)
    }

    pub async fn get_market_info(&self, market_id: &str) -> Option<MarketInfo> {
        self.markets.read().await.get(market_id).cloned()
    }
}