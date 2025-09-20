use crate::config::{LogFormat, TelemetryConfig};
use metrics_exporter_prometheus::PrometheusBuilder;
use std::net::SocketAddr;
use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt, EnvFilter, Layer};

pub fn init(config: &TelemetryConfig) -> anyhow::Result<()> {
    // Initialize tracing
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(&config.log_level));

    let fmt_layer = match config.log_format {
        LogFormat::Json => fmt::layer()
            .json()
            .with_current_span(true)
            .with_span_list(true)
            .boxed(),
        LogFormat::Pretty => fmt::layer()
            .pretty()
            .with_thread_ids(true)
            .with_thread_names(true)
            .boxed(),
    };

    tracing_subscriber::registry()
        .with(env_filter)
        .with(fmt_layer)
        .init();

    // Initialize metrics
    if config.metrics_enabled {
        let addr: SocketAddr = ([0, 0, 0, 0], config.metrics_port).into();
        PrometheusBuilder::new()
            .with_http_listener(addr)
            .install()?;

        tracing::info!(
            port = config.metrics_port,
            "Metrics endpoint started at http://0.0.0.0:{}/metrics",
            config.metrics_port
        );
    }

    Ok(())
}

pub fn shutdown() {
    tracing::info!("Shutting down telemetry");
}

#[macro_export]
macro_rules! record_metric {
    (counter, $name:expr, $value:expr, $($label:tt = $label_value:expr),*) => {
        metrics::counter!($name, $($label => $label_value),*).increment($value);
    };
    (gauge, $name:expr, $value:expr, $($label:tt = $label_value:expr),*) => {
        metrics::gauge!($name, $($label => $label_value),*).set($value as f64);
    };
    (histogram, $name:expr, $value:expr, $($label:tt = $label_value:expr),*) => {
        metrics::histogram!($name, $($label => $label_value),*).record($value);
    };
}