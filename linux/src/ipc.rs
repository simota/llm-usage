//! The line protocol between the tray daemon and the panel process: one JSON
//! value per line, daemon → panel on the panel's stdin and panel → daemon on
//! its stdout.
//!
//! Why two processes: gpui's Linux backends end the event loop when the last
//! window closes, and ignore `show: false`, so a gpui process cannot outlive
//! its panel. The daemon therefore holds no gpui at all, and the panel is a
//! short-lived child that exits when its window closes.

use std::io::Write;

use jiff::Timestamp;
use serde::{Deserialize, Serialize};

use crate::model::UsageSource;

#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ToPanel {
    /// Everything the panel draws. Sent on spawn and on every change.
    Snapshot {
        sources: Vec<UsageSource>,
        last_refreshed: Option<Timestamp>,
    },
    /// The tray was clicked while the panel was open.
    Toggle,
    /// "Open Panel" from the tray menu while the panel was open.
    Activate,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum FromPanel {
    Refresh,
    Quit,
}

pub fn write_line<T: Serialize>(out: &mut impl Write, message: &T) -> std::io::Result<()> {
    let mut line = serde_json::to_vec(message)?;
    line.push(b'\n');
    out.write_all(&line)?;
    out.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{SourceState, UsageWindow};

    #[test]
    fn snapshot_round_trips_every_field_the_panel_reads() {
        let now = Timestamp::from_second(1_800_000_000).unwrap();
        let mut source = UsageSource::new("claude", "Claude Code");
        source.state = SourceState::Stale { since: now };
        source.last_updated = Some(now);
        let mut window = UsageWindow::new("w", "5h", 42.5, Some(now), Some(300));
        window.is_active = true;
        source.windows = vec![window];
        source.note = Some("note".into());
        let message = ToPanel::Snapshot {
            sources: vec![source],
            last_refreshed: Some(now),
        };
        let mut buffer = Vec::new();
        write_line(&mut buffer, &message).unwrap();
        assert_eq!(buffer.last(), Some(&b'\n'));
        let back: ToPanel = serde_json::from_slice(&buffer).unwrap();
        assert_eq!(back, message);
        let mut buffer = Vec::new();
        write_line(&mut buffer, &FromPanel::Refresh).unwrap();
        assert_eq!(buffer, b"\"refresh\"\n");
    }
}
