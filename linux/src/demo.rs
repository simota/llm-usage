//! `llm-usage --demo <fixture>` opens the panel on fixed data, with no
//! providers and no tray. The Linux counterpart of the macOS `--panel` dump
//! (`Sources/LLMUsage/PanelDump.swift`), whose fixtures these mirror: the panel
//! is only reachable from the tray, so states a live account rarely produces —
//! stale, error, every severity — would otherwise go unchecked.

use jiff::Timestamp;

use crate::model::{SourceState, UsageBucket, UsageSource, UsageSpend, UsageWindow, add_secs};

pub const NAMES: [&str; 3] = ["baseline", "states", "severity"];

pub fn fixture(name: &str) -> Option<Vec<UsageSource>> {
    let now = Timestamp::now();
    match name {
        "baseline" => Some(baseline(now)),
        "states" => Some(states(now)),
        "severity" => Some(severity(now)),
        _ => None,
    }
}

fn window(
    id: &str,
    label: &str,
    used: f64,
    resets_in: f64,
    minutes: i64,
    now: Timestamp,
) -> UsageWindow {
    UsageWindow::new(
        id,
        label,
        used,
        Some(add_secs(now, resets_in)),
        Some(minutes),
    )
}

fn source(id: &str, name: &str, plan: &str, now: Timestamp) -> UsageSource {
    let mut s = UsageSource::new(id, name);
    s.plan = Some(plan.into());
    s.account = Some("you@example.com".into());
    s.state = SourceState::Ok;
    s.last_updated = Some(now);
    s
}

const H: f64 = 3600.0;
const D: f64 = 86_400.0;

/// Deliberately worst-case: the longest agy labels, a source with buckets and
/// spend, an unused window, and an over-pace window.
fn baseline(now: Timestamp) -> Vec<UsageSource> {
    let mut claude = source("claude", "Claude Code", "Max", now);
    claude.spend = Some(UsageSpend {
        label: "Credits".into(),
        used_percent: 53.0,
        detail: "$79.71".into(),
    });
    let mut weekly = window("c7d", "7d", 43.0, 2.0 * D, 10_080, now);
    weekly.is_active = true;
    claude.windows = vec![window("c5h", "5h", 8.0, 3.25 * H, 300, now), weekly];
    claude.buckets = vec![UsageBucket {
        id: "cf".into(),
        label: "Fable".into(),
        used_percent: 11.0,
    }];

    let mut codex = source("codex", "Codex", "Pro", now);
    codex.windows = vec![
        window("c1", "7d", 56.0, 5.0 * D, 10_080, now),
        window("cs", "Spark 7d", 0.0, 6.0 * D, 10_080, now),
    ];
    codex.note = Some("2 free resets (first expires 8/1(Fri))".into());

    let mut agy = source("agy", "Antigravity", "Google AI Ultra", now);
    agy.note = Some("Shared with the desktop app and SDK".into());
    agy.windows = vec![
        window("a1", "Gemini 5h", 2.0, 4.0 * H, 300, now),
        window("a2", "Gemini 7d", 13.0, 6.0 * D, 10_080, now),
        window("a3", "Claude/GPT 5h", 0.0, 5.0 * H, 300, now),
        window("a4", "Claude/GPT 7d", 0.0, 7.0 * D, 10_080, now),
    ];
    vec![claude, codex, agy]
}

/// The stale, error and unconfigured branches of the card.
fn states(now: Timestamp) -> Vec<UsageSource> {
    let since = add_secs(now, -52.0 * 60.0);
    let mut stale = source("agy", "Antigravity", "Google AI Ultra", now);
    stale.last_updated = Some(since);
    stale.state = SourceState::Stale { since };
    stale.note = Some("Shared with the desktop app and SDK".into());
    stale.windows = vec![
        window("a1", "Gemini 5h", 2.0, 4.0 * H, 300, now),
        window("a2", "Gemini 7d", 13.0, 6.0 * D, 10_080, now),
        window("a3", "Claude/GPT 7d", 91.0, 7.0 * D, 10_080, now),
    ];

    let mut errored = source("codex", "Codex", "Pro", now);
    errored.last_updated = None;
    errored.state =
        SourceState::Error("Rate-limit endpoint returned 503 (Service Unavailable)".into());
    errored.note = Some("Retrying automatically every 5 minutes".into());

    vec![
        stale,
        errored,
        UsageSource::placeholder("claude", "Claude Code"),
    ]
}

/// Caution and warning in band, and a window over pace by less than the
/// escalation threshold, where only the marker's shape moves.
fn severity(now: Timestamp) -> Vec<UsageSource> {
    let mut caution = source("claude", "Claude Code", "Max", now);
    caution.windows = vec![window("cw", "7d", 70.0, 0.28 * 7.0 * D, 10_080, now)];
    let mut warning = source("codex", "Codex", "Pro", now);
    warning.windows = vec![window("ww", "7d", 87.0, 0.11 * 7.0 * D, 10_080, now)];
    let mut paced = source("agy", "Antigravity", "Google AI Ultra", now);
    paced.windows = vec![window(
        "pw",
        "Gemini 5h",
        35.0,
        0.70 * 300.0 * 60.0,
        300,
        now,
    )];
    vec![caution, warning, paced]
}
