//! What the panel and the tray read: the sources, the summary line, and the
//! tray's mode. Port of the decision logic in `Sources/LLMUsage/UsageStore.swift`.
//! Provider lifecycle lives in `app.rs`; everything here is a pure function of
//! the sources and the clock, so it can be tested without a GUI.

use jiff::Timestamp;

use crate::model::{
    Severity, SourceState, UsageSource, UsageWindow, format, max_by_used, secs_between,
};

pub struct Summary {
    pub text: String,
    pub severity: Severity,
    pub is_warning: bool,
}

pub struct UsageStore {
    pub sources: Vec<UsageSource>,
    pub last_refreshed: Option<Timestamp>,
    pub last_refresh_attempt: Option<Timestamp>,
    pub shows_worst_figure: bool,
    last_reset_refresh: Option<Timestamp>,
}

impl Default for UsageStore {
    fn default() -> Self {
        Self::new(
            vec![
                UsageSource::placeholder("claude", "Claude Code"),
                UsageSource::placeholder("codex", "Codex"),
                UsageSource::placeholder("agy", "Antigravity"),
            ],
            Timestamp::now(),
        )
    }
}

/// `Sequence.min(by:)`: the first element nothing else beats.
fn min_by<T>(items: impl Iterator<Item = T>, less: impl Fn(&T, &T) -> bool) -> Option<T> {
    items.fold(None, |best, item| match best {
        Some(b) if !less(&item, &b) => Some(b),
        _ => Some(item),
    })
}

impl UsageStore {
    pub fn new(sources: Vec<UsageSource>, now: Timestamp) -> Self {
        let last_refreshed = sources.iter().filter_map(|s| s.last_updated).max();
        let mut store = Self {
            sources,
            last_refreshed,
            last_refresh_attempt: None,
            shows_worst_figure: false,
            last_reset_refresh: None,
        };
        store.apply_hysteresis(now);
        store
    }

    fn current_sources(&self, now: Timestamp) -> impl Iterator<Item = &UsageSource> {
        self.sources.iter().filter(move |s| s.has_current_data(now))
    }

    fn current_windows(
        &self,
        now: Timestamp,
    ) -> impl Iterator<Item = (&UsageSource, &UsageWindow)> {
        self.current_sources(now)
            .flat_map(|s| s.windows.iter().map(move |w| (s, w)))
    }

    pub fn worst(&self, now: Timestamp) -> Option<&UsageWindow> {
        max_by_used(self.current_sources(now).filter_map(|s| s.worst_window()))
    }

    /// The earliest predicted limit; raw consumption breaks ties without a prediction.
    #[cfg(test)]
    pub fn binding(&self, now: Timestamp) -> Option<(&UsageSource, &UsageWindow)> {
        min_by(self.current_windows(now), |a, b| {
            a.1.exhausts_before(b.1, now)
        })
    }

    /// Severity determines the subject; equally severe limits use exhaustion time.
    pub fn headline(&self, now: Timestamp) -> Option<(&UsageSource, &UsageWindow)> {
        min_by(self.current_windows(now), |a, b| {
            let (sa, sb) = (a.1.displayed_severity(now), b.1.displayed_severity(now));
            if sa != sb {
                return sa > sb;
            }
            a.1.exhausts_before(b.1, now)
        })
    }

    pub fn summary(&self, now: Timestamp) -> Summary {
        let unavailable = self.sources.len() - self.current_sources(now).count();
        let Some((source, window)) = self.headline(now) else {
            return Summary {
                text: "No current data".into(),
                severity: Severity::Normal,
                is_warning: false,
            };
        };
        let suffix = if unavailable > 0 {
            format!(" · {unavailable} unavailable")
        } else {
            String::new()
        };
        let severity = window.displayed_severity(now);
        let head = format!(
            "{} {} {}",
            source.display_name,
            window.label,
            format::percent(window.used_percent)
        );
        if let Some(over_pace) = format::over_pace(window, now) {
            let detail = format::exhaustion(window, now).unwrap_or(over_pace);
            return Summary {
                text: format!("{head} · {detail}{suffix}"),
                severity,
                is_warning: true,
            };
        }
        if severity > Severity::Normal {
            let text = format!(
                "{head} · {}{suffix}",
                format::resets_in(window.resets_at, now)
            );
            return Summary {
                text,
                severity,
                is_warning: true,
            };
        }
        if unavailable > 0 {
            return Summary {
                text: format!("Current data healthy{suffix}"),
                severity: Severity::Normal,
                is_warning: false,
            };
        }
        let nearest = self
            .current_windows(now)
            .filter_map(|(_, w)| w.resets_at)
            .min();
        Summary {
            text: format!(
                "All healthy · next reset {}",
                format::resets_in(nearest, now)
            ),
            severity: Severity::Normal,
            is_warning: false,
        }
    }

    pub fn apply(&mut self, id: &str, result: Result<UsageSource, String>, now: Timestamp) {
        let Some(index) = self.sources.iter().position(|s| s.id == id) else {
            return;
        };
        match result {
            Ok(source) => {
                let previous = self.sources[index].last_updated;
                if source.state == SourceState::Ok
                    && let Some(updated) = source.last_updated
                    && previous.is_none_or(|p| updated > p)
                {
                    self.last_refreshed =
                        Some(self.last_refreshed.map_or(updated, |l| l.max(updated)));
                }
                self.sources[index] = source;
            }
            Err(message) => self.sources[index].state = SourceState::Error(message),
        }
        self.apply_hysteresis(now);
    }

    /// The 30-second tick. Returns true when a window rolled over since its
    /// sample, which deserves a refresh of every source (at most every 2 minutes).
    pub fn update_clock(&mut self, now: Timestamp) -> bool {
        self.apply_hysteresis(now);
        if self
            .last_reset_refresh
            .is_some_and(|last| secs_between(last, now) < 120.0)
        {
            return false;
        }
        let rolled_over = self.sources.iter().any(|source| {
            let Some(updated) = source.last_updated else {
                return false;
            };
            source.windows.iter().any(|w| {
                w.resets_at
                    .is_some_and(|reset| reset < now && updated < reset)
            })
        });
        if rolled_over {
            self.last_reset_refresh = Some(now);
        }
        rolled_over
    }

    pub fn mark_refresh_attempt(&mut self, now: Timestamp) {
        self.last_refresh_attempt = Some(now);
    }

    fn apply_hysteresis(&mut self, now: Timestamp) {
        // Projection is a threshold input, separate from the earliest limit's identity.
        let projected = self
            .current_windows(now)
            .map(|(_, w)| w.projected_percent(now))
            .fold(0.0, f64::max);
        if self.shows_worst_figure {
            if projected < 75.0 {
                self.shows_worst_figure = false;
            }
        } else if projected >= 80.0 {
            self.shows_worst_figure = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::add_secs;

    fn at(secs: i64) -> Timestamp {
        Timestamp::from_second(secs).unwrap()
    }

    fn source(id: &str, windows: Vec<UsageWindow>, updated: Timestamp) -> UsageSource {
        let mut s = UsageSource::new(id, id);
        s.windows = windows;
        s.last_updated = Some(updated);
        s.state = SourceState::Ok;
        s
    }

    #[test]
    fn earlier_exhaustion_wins_across_different_window_durations() {
        let now = at(1_800_000_000);
        let short = UsageWindow::new(
            "short",
            "5h",
            50.0,
            Some(add_secs(now, 4.0 * 3600.0)),
            Some(300),
        );
        let weekly = UsageWindow::new(
            "weekly",
            "7d",
            40.0,
            Some(add_secs(now, 0.9 * 7.0 * 86400.0)),
            Some(10080),
        );
        let store = UsageStore::new(vec![source("test", vec![short, weekly], now)], now);
        assert_eq!(store.binding(now).unwrap().1.id, "short");
        assert_eq!(store.headline(now).unwrap().1.id, "short");
    }

    #[test]
    fn stale_and_failed_values_do_not_drive_current_health() {
        let now = at(1_800_000_000);
        let quiet = UsageWindow::new("quiet", "5h", 10.0, None, None);
        let hot = UsageWindow::new("hot", "7d", 99.0, None, None);
        let mut failed = source("failed", vec![hot.clone()], now);
        failed.state = SourceState::Error("Offline".into());
        let store = UsageStore::new(
            vec![
                source("fresh", vec![quiet], now),
                source("old", vec![hot], add_secs(now, -3600.0)),
                failed,
            ],
            now,
        );
        assert_eq!(store.worst(now).unwrap().id, "quiet");
        assert_eq!(store.headline(now).unwrap().0.id, "fresh");
        let summary = store.summary(now);
        assert!(!summary.text.contains("All healthy"));
        assert!(summary.text.contains("2 unavailable"), "{}", summary.text);
    }

    #[test]
    fn only_old_values_cannot_claim_healthy() {
        let now = at(1_800_000_000);
        let old = source(
            "old",
            vec![UsageWindow::new("quiet", "5h", 10.0, None, None)],
            add_secs(now, -3600.0),
        );
        let updated = old.last_updated;
        let store = UsageStore::new(vec![old], now);
        assert!(store.worst(now).is_none());
        assert!(store.binding(now).is_none());
        assert_eq!(store.summary(now).text, "No current data");
        assert_eq!(store.last_refreshed, updated);
    }

    #[test]
    fn success_clock_uses_new_sample_time() {
        let now = at(1_800_000_000);
        let mut store = UsageStore::new(vec![UsageSource::placeholder("codex", "Codex")], now);
        let sample = source(
            "codex",
            vec![UsageWindow::new("w", "5h", 10.0, None, None)],
            add_secs(now, -60.0),
        );
        store.apply("codex", Ok(sample.clone()), now);
        assert_eq!(store.last_refreshed, sample.last_updated);
        // The same sample again does not move the clock.
        store.apply("codex", Ok(sample.clone()), now);
        assert_eq!(store.last_refreshed, sample.last_updated);
        let mut newer = sample;
        newer.last_updated = Some(now);
        store.apply("codex", Ok(newer), now);
        assert_eq!(store.last_refreshed, Some(now));
        store.apply("codex", Err("boom".into()), now);
        assert_eq!(store.sources[0].state, SourceState::Error("boom".into()));
    }

    #[test]
    fn clock_aging_clears_tray_warning() {
        let now = at(1_800_000_000);
        let hot = UsageWindow::new("hot", "5h", 99.0, None, None);
        let mut store = UsageStore::new(vec![source("hot", vec![hot], now)], now);
        assert!(store.shows_worst_figure);
        let later = add_secs(now, 901.0);
        store.update_clock(later);
        assert!(!store.shows_worst_figure);
        assert!(store.worst(later).is_none());
    }

    #[test]
    fn rollover_triggers_one_refresh_per_two_minutes() {
        let now = at(1_800_000_000);
        let w = UsageWindow::new("w", "5h", 10.0, Some(add_secs(now, 10.0)), Some(300));
        let mut store = UsageStore::new(vec![source("s", vec![w], now)], now);
        assert!(!store.update_clock(add_secs(now, 5.0)));
        assert!(store.update_clock(add_secs(now, 30.0)));
        assert!(!store.update_clock(add_secs(now, 60.0)));
        assert!(store.update_clock(add_secs(now, 160.0)));
    }

    #[test]
    fn healthy_summary_names_the_next_reset() {
        let now = at(1_800_000_000);
        let w = UsageWindow::new(
            "w",
            "5h",
            10.0,
            Some(add_secs(now, 48.0 * 60.0 + 5.0)),
            Some(300),
        );
        let store = UsageStore::new(vec![source("s", vec![w], now)], now);
        assert_eq!(store.summary(now).text, "All healthy · next reset in 48m");
    }
}
