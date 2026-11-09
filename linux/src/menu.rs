//! The tray menu as a text panel.
//!
//! Ubuntu's AppIndicator extension opens an item's menu on a single left click
//! and sends `Activate` only on a double click, so on GNOME the menu — not the
//! panel window — is what a click shows. It therefore carries the panel's
//! content: the summary, every card's rows, and the actions. A label takes no
//! colour, so the colour rides on each row's icon (`menu_icon.rs`): the usage
//! ring in the severity hue with the pace tick, and the card marks. The text
//! keeps a ▰▱ bar so lengths still compare down the column.
//! Everything here is a pure function of the store and the clock.

use jiff::Timestamp;

use crate::menu_icon::RowIcon;
use crate::model::{Severity, SourceState, UsageSource, UsageWindow, format};
use crate::store::UsageStore;

#[derive(Clone, Debug, PartialEq)]
pub enum Line {
    /// A row of usage. Clicking it opens the panel.
    Text(String, Option<RowIcon>),
    Separator,
}

const INDENT: &str = "    ";
const BAR_CELLS: usize = 10;

fn bar(used_percent: f64) -> String {
    let filled = ((used_percent / 100.0).clamp(0.0, 1.0) * BAR_CELLS as f64).round() as usize;
    "▰".repeat(filled) + &"▱".repeat(BAR_CELLS - filled)
}

fn text(text: impl Into<String>) -> Line {
    Line::Text(text.into(), None)
}

fn with_icon(text: impl Into<String>, icon: RowIcon) -> Line {
    Line::Text(text.into(), Some(icon))
}

pub fn lines(store: &UsageStore, now: Timestamp) -> Vec<Line> {
    let summary = store.summary(now);
    let mut out = vec![if summary.is_warning {
        with_icon(summary.text, RowIcon::Mark(summary.severity))
    } else {
        text(summary.text)
    }];
    for source in &store.sources {
        out.push(Line::Separator);
        card(source, now, &mut out);
    }
    out.push(Line::Separator);
    out.push(text(format!(
        "Last sample {}",
        format::relative(store.last_refreshed, now)
    )));
    out
}

fn card(source: &UsageSource, now: Timestamp, out: &mut Vec<Line>) {
    let state = source.aged_state(now);
    let severity = source
        .windows
        .iter()
        .map(|w| w.displayed_severity(now))
        .max()
        .unwrap_or(Severity::Normal);
    // Grey outlines for "we cannot vouch for this", as on the card header.
    let mark = match state {
        SourceState::Ok => RowIcon::Mark(severity),
        SourceState::Stale { .. } => RowIcon::Stale,
        SourceState::Error(_) => RowIcon::Error,
        SourceState::Unconfigured => RowIcon::Unconfigured,
    };
    let mut header = source.display_name.clone();
    if let Some(plan) = &source.plan {
        header += &format!(" · {plan}");
    }
    out.push(with_icon(header, mark));

    let row = |s: String| text(format!("{INDENT}{s}"));
    match &state {
        SourceState::Unconfigured => {
            out.push(row(source
                .note
                .clone()
                .unwrap_or_else(|| "Not configured".into())));
        }
        SourceState::Error(reason) => {
            out.push(row(reason.clone()));
            if let Some(note) = source.note.as_ref().filter(|n| *n != reason) {
                out.push(row(note.clone()));
            }
        }
        SourceState::Ok | SourceState::Stale { .. } => {
            for w in &source.windows {
                window_rows(w, now, out);
            }
            if let Some(spend) = &source.spend {
                out.push(with_icon(
                    format!(
                        "{INDENT}{}  {}  {}  {}",
                        spend.label,
                        bar(spend.used_percent),
                        format::percent(spend.used_percent),
                        spend.detail
                    ),
                    RowIcon::Fill {
                        used: spend.used_percent,
                        severity: Severity::from_used(spend.used_percent),
                    },
                ));
            }
            if let SourceState::Stale { since } = state {
                out.push(with_icon(
                    format!(
                        "{INDENT}Last known · {}",
                        format::relative(Some(since), now)
                    ),
                    RowIcon::Stale,
                ));
            }
            if let Some(note) = &source.note {
                out.push(row(note.clone()));
            }
            for bucket in source.meaningful_buckets() {
                out.push(row(format!(
                    "{}  {}",
                    bucket.label,
                    format::percent(bucket.used_percent)
                )));
            }
        }
    }
}

fn window_rows(w: &UsageWindow, now: Timestamp, out: &mut Vec<Line>) {
    if w.is_unused() {
        out.push(text(format!("{INDENT}{}  unused", w.label)));
        return;
    }
    out.push(with_icon(
        format!(
            "{INDENT}{}  {}  {}  {}",
            w.label,
            bar(w.used_percent),
            format::percent(w.used_percent),
            format::resets_in(w.resets_at, now)
        ),
        RowIcon::Gauge {
            used: w.used_percent,
            elapsed: w.elapsed_fraction(now),
            severity: w.displayed_severity(now),
        },
    ));
    if let Some(pace) = format::over_pace(w, now) {
        out.push(with_icon(
            format!("{INDENT}{INDENT}{pace}"),
            RowIcon::Mark(Severity::Critical),
        ));
    }
}

/// dbusmenu reads `_` as a mnemonic marker; a literal one is written `__`.
pub fn escape(label: &str) -> String {
    label.replace('_', "__")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{UsageBucket, add_secs};

    /// Each line as its text plus a short tag for its icon.
    fn render(lines: &[Line]) -> Vec<String> {
        lines
            .iter()
            .map(|l| match l {
                Line::Text(t, None) => t.clone(),
                Line::Text(t, Some(icon)) => {
                    let tag = match icon {
                        RowIcon::Gauge { severity, .. } => format!("gauge:{severity:?}"),
                        RowIcon::Fill { severity, .. } => format!("fill:{severity:?}"),
                        RowIcon::Mark(severity) => format!("mark:{severity:?}"),
                        other => format!("{other:?}"),
                    };
                    format!("{t} [{tag}]")
                }
                Line::Separator => "---".into(),
            })
            .collect()
    }

    #[test]
    fn every_card_row_is_in_the_menu_with_its_colour() {
        let now = Timestamp::from_second(1_800_000_000).unwrap();
        let mut claude = UsageSource::new("claude", "Claude Code");
        claude.plan = Some("Max".into());
        claude.state = SourceState::Ok;
        claude.last_updated = Some(now);
        claude.windows = vec![
            UsageWindow::new(
                "5h",
                "5h",
                8.0,
                Some(add_secs(now, 3.0 * 3600.0 + 14.0 * 60.0)),
                Some(300),
            ),
            // 56% used with 2/7 of the week gone: +27% over pace.
            UsageWindow::new(
                "7d",
                "7d",
                56.0,
                Some(add_secs(now, 5.0 * 86_400.0)),
                Some(10_080),
            ),
            UsageWindow::new("x", "Spark 7d", 0.0, None, None),
        ];
        claude.buckets = vec![UsageBucket {
            id: "f".into(),
            label: "Fable".into(),
            used_percent: 11.0,
        }];
        claude.note = Some("2 free resets".into());
        let mut codex = UsageSource::new("codex", "Codex");
        codex.state = SourceState::Error("Cannot connect".into());
        let store = UsageStore::new(
            vec![
                claude,
                codex,
                UsageSource::placeholder("agy", "Antigravity"),
            ],
            now,
        );

        let lines = render(&lines(&store, now));
        assert!(
            lines[0].starts_with("Claude Code 7d 56% · maxes out")
                && lines[0].ends_with("[mark:Critical]"),
            "{}",
            lines[0]
        );
        assert_eq!(lines[2], "Claude Code · Max [mark:Critical]");
        assert_eq!(lines[3], "    5h  ▰▱▱▱▱▱▱▱▱▱  8%  in 3h14m [gauge:Normal]");
        assert!(
            lines[4].starts_with("    7d  ▰▰▰▰▰▰▱▱▱▱  56%  ")
                && lines[4].ends_with("[gauge:Critical]"),
            "{}",
            lines[4]
        );
        assert_eq!(lines[5], "        +27% over pace [mark:Critical]");
        assert_eq!(lines[6], "    Spark 7d  unused");
        assert_eq!(lines[7], "    2 free resets");
        assert_eq!(lines[8], "    Fable  11%");
        assert_eq!(lines[10..12], ["Codex [Error]", "    Cannot connect"]);
        assert_eq!(
            lines[13..15],
            ["Antigravity [Unconfigured]", "    Not configured"]
        );
        assert_eq!(
            lines.last().unwrap(),
            &format!("Last sample {}", format::relative(Some(now), now))
        );
    }

    #[test]
    fn stale_card_keeps_its_rows_and_says_so() {
        let now = Timestamp::from_second(1_800_000_000).unwrap();
        let since = add_secs(now, -52.0 * 60.0);
        let mut agy = UsageSource::new("agy", "Antigravity");
        agy.state = SourceState::Ok;
        agy.last_updated = Some(since);
        agy.windows = vec![UsageWindow::new("g", "Gemini 5h", 25.0, None, None)];
        let store = UsageStore::new(vec![agy], now);
        let lines = render(&lines(&store, now));
        assert_eq!(
            lines[2..5],
            [
                "Antigravity [Stale]",
                "    Gemini 5h  ▰▰▰▱▱▱▱▱▱▱  25%  — [gauge:Normal]",
                "    Last known · 52m ago [Stale]"
            ]
        );
        assert_eq!(lines[0], "No current data");
    }

    #[test]
    fn underscores_survive_the_mnemonic_parser() {
        assert_eq!(escape("self_serve_plan"), "self__serve__plan");
    }
}
