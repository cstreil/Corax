//! Restart backoff for the supervised background loops (notifications, UI
//! events).
//!
//! A deterministic panic in one cycle must not turn into a one-restart-per-
//! second loop for the rest of the process life (audit N5): the delay doubles
//! from 1 s and is capped at 60 s. A cancellation is not a failure and ends the
//! loop instead of restarting it.

use std::time::Duration;

/// Longest delay between two restarts.
pub(crate) const MAX_DELAY: Duration = Duration::from_secs(60);

/// Delay after the `attempt`-th consecutive failure (0-based): 1, 2, 4, 8, 16,
/// 32, 60, 60, ...
pub(crate) fn delay(attempt: u32) -> Duration {
    let secs = 1u64
        .checked_shl(attempt.min(6))
        .unwrap_or(64)
        .min(MAX_DELAY.as_secs());
    Duration::from_secs(secs)
}

/// True when a task that ran this long counts as healthy, so its next failure
/// starts the backoff at 1 s again instead of continuing a stale streak.
pub(crate) fn ran_long_enough(elapsed: Duration) -> bool {
    elapsed >= MAX_DELAY
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_delay_doubles_and_is_capped() {
        let secs: Vec<u64> = (0..10).map(|attempt| delay(attempt).as_secs()).collect();
        assert_eq!(secs, vec![1, 2, 4, 8, 16, 32, 60, 60, 60, 60]);
        assert!(delay(u32::MAX) <= MAX_DELAY);
    }

    #[test]
    fn a_long_run_resets_the_streak() {
        assert!(!ran_long_enough(Duration::from_secs(59)));
        assert!(ran_long_enough(Duration::from_secs(60)));
        assert!(ran_long_enough(Duration::from_secs(600)));
    }
}
