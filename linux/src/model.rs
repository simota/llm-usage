//! The normalised model. Every provider maps onto these types so the panel only
//! ever renders one shape. Port of `Sources/LLMUsage/Model.swift`; see
//! docs/design.md §11.

use jiff::{SignedDuration, Timestamp, tz::TimeZone};
use serde::{Deserialize, Serialize};

/// One rate-limit window (Codex weekly, Claude 5h/7d, an agy group bucket, …).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UsageWindow {
    pub id: String,
    /// Short column label: "5h", "7d", "Gemini 5h".
    pub label: String,
    /// 0...100. Providers that report *remaining* invert before constructing this.
    pub used_percent: f64,
    pub resets_at: Option<Timestamp>,
    pub window_minutes: Option<i64>,
    /// The window currently doing the metering, where the source tells us
    /// (Claude's `is_active`). Used to break ties when picking what binds.
    pub is_active: bool,
}

impl UsageWindow {
    pub fn new(
        id: impl Into<String>,
        label: impl Into<String>,
        used_percent: f64,
        resets_at: Option<Timestamp>,
        window_minutes: Option<i64>,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            used_percent,
            resets_at,
            window_minutes,
            is_active: false,
        }
    }

    pub fn is_unused(&self) -> bool {
        self.used_percent < 0.5
    }

    /// Linear extrapolation to the end of the window: >100 means the limit
    /// arrives before the reset does.
    pub fn projected_percent(&self, now: Timestamp) -> f64 {
        match self.elapsed_fraction(now) {
            Some(elapsed) if elapsed >= 0.1 => (self.used_percent / elapsed).min(999.0),
            _ => self.used_percent,
        }
    }

    /// When the current burn rate reaches 100%, if that happens before the
    /// window resets. `None` means the allowance outlasts the window.
    pub fn projected_exhaustion(&self, now: Timestamp) -> Option<Timestamp> {
        if self.used_percent >= 100.0 {
            return Some(now);
        }
        let resets_at = self.resets_at?;
        let minutes = self.window_minutes.filter(|m| *m > 0)?;
        if resets_at <= now || self.used_percent <= 0.0 {
            return None;
        }
        let elapsed = self.elapsed_fraction(now).filter(|e| *e >= 0.1)?;
        let rate = self.used_percent / elapsed; // percent consumed per whole window
        if rate <= 100.0 {
            return None; // finishes the window inside the limit
        }
        let fraction_at_limit = 100.0 / rate;
        if fraction_at_limit <= elapsed {
            return None; // already over
        }
        let span = minutes as f64 * 60.0;
        Some(add_secs(resets_at, -span + fraction_at_limit * span))
    }

    pub fn exhausts_before(&self, other: &UsageWindow, now: Timestamp) -> bool {
        let first = self.projected_exhaustion(now).unwrap_or(Timestamp::MAX);
        let second = other.projected_exhaustion(now).unwrap_or(Timestamp::MAX);
        if first != second {
            return first < second;
        }
        if self.is_active != other.is_active {
            return self.is_active;
        }
        if self.used_percent != other.used_percent {
            return self.used_percent > other.used_percent;
        }
        self.id < other.id
    }

    pub fn displayed_severity(&self, now: Timestamp) -> Severity {
        Severity::escalated(Severity::from_used(self.used_percent), self.pace_delta(now))
    }

    /// Where the pace tick sits: how far through the window we are, 0...1.
    /// `None` when the window length or reset time is unknown.
    pub fn elapsed_fraction(&self, now: Timestamp) -> Option<f64> {
        let resets_at = self.resets_at?;
        let minutes = self.window_minutes.filter(|m| *m > 0)?;
        let span = minutes as f64 * 60.0;
        let start = add_secs(resets_at, -span);
        Some((secs_between(start, now) / span).clamp(0.0, 1.0))
    }

    /// Positive means consuming faster than the window refills. See docs/design.md §4.
    pub fn pace_delta(&self, now: Timestamp) -> Option<f64> {
        self.elapsed_fraction(now)
            .map(|elapsed| self.used_percent / 100.0 - elapsed)
    }
}

/// A finer-grained bucket shown only when a card is expanded.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UsageBucket {
    pub id: String,
    pub label: String,
    pub used_percent: f64,
}

/// A spending allowance rather than a rate-limit window: no reset, no pace.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UsageSpend {
    pub label: String,
    pub used_percent: f64,
    /// Right-hand column, e.g. "$79.71".
    pub detail: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum SourceState {
    Ok,
    Stale { since: Timestamp },
    Error(String),
    Unconfigured,
}

impl std::fmt::Display for SourceState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SourceState::Ok => write!(f, "ok"),
            SourceState::Stale { since } => write!(f, "stale(since: {since})"),
            SourceState::Error(reason) => write!(f, "error(\"{reason}\")"),
            SourceState::Unconfigured => write!(f, "unconfigured"),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UsageSource {
    pub id: String,
    pub display_name: String,
    pub plan: Option<String>,
    /// Which login this source is metering. Sources authenticate separately, so
    /// these can legitimately differ from each other.
    pub account: Option<String>,
    pub windows: Vec<UsageWindow>,
    pub buckets: Vec<UsageBucket>,
    pub spend: Option<UsageSpend>,
    pub note: Option<String>,
    pub last_updated: Option<Timestamp>,
    pub state: SourceState,
    /// How long a value may sit before it reads as stale, in seconds.
    /// Per-source, see docs/design.md §6.
    pub stale_after: f64,
}

impl UsageSource {
    pub fn new(id: impl Into<String>, display_name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
            plan: None,
            account: None,
            windows: Vec::new(),
            buckets: Vec::new(),
            spend: None,
            note: None,
            last_updated: None,
            state: SourceState::Unconfigured,
            stale_after: 900.0,
        }
    }

    pub fn placeholder(id: &str, name: &str) -> Self {
        Self::new(id, name)
    }

    /// The window driving this card's colour — the most consumed one.
    pub fn worst_window(&self) -> Option<&UsageWindow> {
        max_by_used(self.windows.iter())
    }

    /// Buckets worth a disclosure row. Each provider drops its own redundant
    /// buckets before they get here.
    pub fn meaningful_buckets(&self) -> &[UsageBucket] {
        if self.buckets.iter().any(|b| b.used_percent >= 0.5) {
            &self.buckets
        } else {
            &[]
        }
    }

    /// Re-evaluates `Ok` against `stale_after`. Errors and placeholders are left alone.
    pub fn aged_state(&self, now: Timestamp) -> SourceState {
        let (SourceState::Ok, Some(last_updated)) = (&self.state, self.last_updated) else {
            return self.state.clone();
        };
        let rolled_over = self.windows.iter().any(|w| {
            w.resets_at
                .is_some_and(|reset| reset <= now && last_updated < reset)
        });
        if secs_between(last_updated, now) > self.stale_after || rolled_over {
            SourceState::Stale {
                since: last_updated,
            }
        } else {
            SourceState::Ok
        }
    }

    pub fn has_current_data(&self, now: Timestamp) -> bool {
        self.last_updated.is_some()
            && !self.windows.is_empty()
            && self.aged_state(now) == SourceState::Ok
    }
}

/// `Sequence.max(by: usedPercent)` — on ties the *last* maximum wins, as Swift's does.
pub fn max_by_used<'a>(windows: impl Iterator<Item = &'a UsageWindow>) -> Option<&'a UsageWindow> {
    windows.fold(None, |best: Option<&UsageWindow>, w| match best {
        Some(b) if w.used_percent < b.used_percent => Some(b),
        _ => Some(w),
    })
}

// MARK: - Severity

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Severity {
    Normal,
    Caution,
    Warning,
    Critical,
}

impl Severity {
    pub fn from_used(used_percent: f64) -> Self {
        if used_percent < 60.0 {
            Severity::Normal
        } else if used_percent < 80.0 {
            Severity::Caution
        } else if used_percent < 95.0 {
            Severity::Warning
        } else {
            Severity::Critical
        }
    }

    pub fn escalated(base: Severity, pace_delta: Option<f64>) -> Severity {
        match pace_delta {
            Some(delta) if delta > format::OVER_PACE_THRESHOLD => base.max(Severity::Critical),
            _ => base,
        }
    }
}

// MARK: - Time helpers

pub fn secs_between(from: Timestamp, to: Timestamp) -> f64 {
    to.duration_since(from).as_secs_f64()
}

pub fn add_secs(ts: Timestamp, secs: f64) -> Timestamp {
    ts.saturating_add(SignedDuration::from_secs_f64(secs))
        .unwrap_or(ts)
}

pub fn from_unix(secs: f64) -> Option<Timestamp> {
    Timestamp::from_microsecond((secs * 1_000_000.0) as i64).ok()
}

/// RFC 3339 with or without fractional seconds, any offset.
pub fn parse_timestamp(value: &str) -> Option<Timestamp> {
    value.parse::<Timestamp>().ok()
}

// MARK: - Formatting

pub mod format {
    use super::*;

    /// Over this, a window is called out as burning too fast.
    pub const OVER_PACE_THRESHOLD: f64 = 0.10;

    /// "8/6(Thu)" in the local time zone. English weekday on purpose: the rest
    /// of the panel is English (see `Format.displayLocale` in the Swift app).
    pub fn day(ts: Timestamp) -> String {
        ts.to_zoned(TimeZone::system())
            .strftime("%-m/%-d(%a)")
            .to_string()
    }

    /// docs/design.md §5 — "in 48m" / "in 3h08m" / "8/6(Thu)" / "now".
    pub fn resets_in(date: Option<Timestamp>, now: Timestamp) -> String {
        let Some(date) = date else {
            return "—".into();
        };
        let s = secs_between(now, date);
        if s <= 0.0 {
            return "now".into();
        }
        if s < 3600.0 {
            return format!("in {}m", (s / 60.0) as i64);
        }
        if s < 86_400.0 {
            let total = s as i64;
            return format!("in {}h{:02}m", total / 3600, (total % 3600) / 60);
        }
        day(date)
    }

    /// "+38% over pace", or `None` when the window is keeping up.
    pub fn over_pace(window: &UsageWindow, now: Timestamp) -> Option<String> {
        let delta = window.pace_delta(now)?;
        (delta > OVER_PACE_THRESHOLD)
            .then(|| format!("+{}% over pace", (delta * 100.0).round() as i64))
    }

    /// "maxes out 7/31(Thu) at this pace" — the actionable form of over-pace.
    pub fn exhaustion(window: &UsageWindow, now: Timestamp) -> Option<String> {
        let at = window.projected_exhaustion(now)?;
        let when = if secs_between(now, at) < 86_400.0 {
            resets_in(Some(at), now)
        } else {
            day(at)
        };
        Some(format!("maxes out {when} at this pace"))
    }

    pub fn relative(date: Option<Timestamp>, now: Timestamp) -> String {
        let Some(date) = date else {
            return "—".into();
        };
        let s = secs_between(date, now).max(0.0);
        if s < 60.0 {
            format!("{}s ago", s as i64)
        } else if s < 3600.0 {
            format!("{}m ago", (s / 60.0) as i64)
        } else if s < 86_400.0 {
            format!("{}h ago", (s / 3600.0) as i64)
        } else {
            format!("{}d ago", (s / 86_400.0) as i64)
        }
    }

    /// Swift's `Double.rounded()` rounds half away from zero, as does `f64::round`.
    pub fn percent(value: f64) -> String {
        format!("{}%", value.round() as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(secs: i64) -> Timestamp {
        Timestamp::from_second(secs).unwrap()
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
        let e = short.projected_exhaustion(now).unwrap();
        assert!((secs_between(now, e) - 3600.0).abs() < 0.01);
        let e = weekly.projected_exhaustion(now).unwrap();
        assert!((secs_between(now, e) - 25.2 * 3600.0).abs() < 0.01);
        assert!(short.exhausts_before(&weekly, now));
    }

    #[test]
    fn rolled_over_window_is_not_current_even_before_stale_timeout() {
        let now = at(1_800_000_000);
        let window = UsageWindow::new("expired", "5h", 90.0, Some(add_secs(now, -1.0)), Some(300));
        let mut source = UsageSource::new("old", "old");
        source.windows = vec![window.clone()];
        source.last_updated = Some(add_secs(now, -2.0));
        source.state = SourceState::Ok;
        assert!(!source.has_current_data(now));
        assert_eq!(window.projected_exhaustion(now), None);
    }

    #[test]
    fn already_exhausted_window_wins_even_without_duration() {
        let now = at(1_800_000_000);
        let full = UsageWindow::new("full", "5h", 100.0, None, None);
        let future = UsageWindow::new(
            "future",
            "5h",
            50.0,
            Some(add_secs(now, 4.0 * 3600.0)),
            Some(300),
        );
        assert_eq!(full.projected_exhaustion(now), Some(now));
        assert!(full.exhausts_before(&future, now));
    }

    #[test]
    fn reset_formatting_matches_the_design_notation() {
        let now = at(1_800_000_000);
        assert_eq!(format::resets_in(None, now), "—");
        assert_eq!(format::resets_in(Some(add_secs(now, -5.0)), now), "now");
        assert_eq!(
            format::resets_in(Some(add_secs(now, 48.0 * 60.0 + 30.0)), now),
            "in 48m"
        );
        assert_eq!(
            format::resets_in(Some(add_secs(now, 3.0 * 3600.0 + 8.0 * 60.0)), now),
            "in 3h08m"
        );
        let far = format::resets_in(Some(add_secs(now, 3.0 * 86_400.0)), now);
        assert!(far.ends_with(')') && far.contains('/'), "{far}");
        assert_eq!(format::relative(Some(add_secs(now, -12.0)), now), "12s ago");
        assert_eq!(
            format::relative(Some(add_secs(now, -7200.0)), now),
            "2h ago"
        );
        assert_eq!(format::percent(42.5), "43%");
    }

    #[test]
    fn over_pace_escalates_severity_to_critical() {
        let now = at(1_800_000_000);
        // Half the window gone, 70% used: +20% over pace.
        let w = UsageWindow::new(
            "w",
            "5h",
            70.0,
            Some(add_secs(now, 2.5 * 3600.0)),
            Some(300),
        );
        assert_eq!(Severity::from_used(70.0), Severity::Caution);
        assert_eq!(w.displayed_severity(now), Severity::Critical);
        assert_eq!(
            format::over_pace(&w, now).as_deref(),
            Some("+20% over pace")
        );
    }

    #[test]
    fn timestamps_parse_with_and_without_fractions() {
        assert!(parse_timestamp("2026-08-01T12:00:00.123456+00:00").is_some());
        assert!(parse_timestamp("2026-08-01T12:00:00Z").is_some());
        assert!(parse_timestamp("not a date").is_none());
    }
}
