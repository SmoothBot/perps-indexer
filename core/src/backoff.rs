use backoff::backoff::Backoff;
use backoff::exponential::ExponentialBackoff;
use std::time::Duration;
use tracing::{debug, warn};

pub fn create_backoff(max_retries: u32, base_delay_ms: u64) -> ExponentialBackoff<backoff::SystemClock> {
    ExponentialBackoff {
        current_interval: Duration::from_millis(base_delay_ms),
        initial_interval: Duration::from_millis(base_delay_ms),
        randomization_factor: 0.5, // Add jitter
        multiplier: 2.0,
        max_interval: Duration::from_secs(60),
        max_elapsed_time: Some(Duration::from_secs(max_retries as u64 * 60)),
        ..ExponentialBackoff::default()
    }
}

pub async fn retry_with_backoff<F, Fut, T, E>(
    operation: F,
    max_retries: u32,
    base_delay_ms: u64,
    operation_name: &str,
) -> Result<T, E>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T, E>>,
    E: std::fmt::Display,
{
    let mut backoff = create_backoff(max_retries, base_delay_ms);
    let mut attempts = 0;

    loop {
        attempts += 1;

        match operation().await {
            Ok(result) => {
                if attempts > 1 {
                    debug!(
                        operation = operation_name,
                        attempts,
                        "Operation succeeded after retries"
                    );
                }
                return Ok(result);
            }
            Err(e) => {
                if attempts >= max_retries {
                    warn!(
                        operation = operation_name,
                        attempts,
                        error = %e,
                        "Operation failed after max retries"
                    );
                    return Err(e);
                }

                if let Some(duration) = backoff.next_backoff() {
                    warn!(
                        operation = operation_name,
                        attempt = attempts,
                        retry_after_ms = duration.as_millis(),
                        error = %e,
                        "Operation failed, retrying"
                    );
                    tokio::time::sleep(duration).await;
                } else {
                    warn!(
                        operation = operation_name,
                        attempts,
                        error = %e,
                        "Backoff exhausted"
                    );
                    return Err(e);
                }
            }
        }
    }
}