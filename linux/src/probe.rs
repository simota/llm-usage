//! `llm-usage --probe` exercises the provider and normalisation path without a
//! GUI, so the data plumbing can be verified from a terminal.

use std::collections::HashMap;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::model::{UsageSource, format};
use crate::provider::UsageProvider;
use crate::{agy, claude, codex};

pub fn run() -> i32 {
    let (tx, rx) = channel::<(String, Result<UsageSource, String>)>();
    let sender = |id: &'static str| {
        let tx = Mutex::new(tx.clone());
        Arc::new(move |result| {
            let _ = tx.lock().unwrap().send((id.to_string(), result));
        })
    };
    let providers: Vec<Box<dyn UsageProvider>> = vec![
        Box::new(claude::ClaudeProvider::new(
            claude::Deps::system(),
            sender("claude"),
        )),
        Box::new(agy::AgyProvider::new(agy::Deps::system(), sender("agy"))),
        Box::new(codex::CodexProvider::new(
            Arc::new(codex::server_process),
            sender("codex"),
        )),
    ];
    providers.iter().for_each(|p| p.start());

    let deadline = Instant::now() + Duration::from_secs(20);
    let mut collected: HashMap<String, UsageSource> = HashMap::new();
    let mut answered = std::collections::HashSet::new();
    while answered.len() < 3 {
        let Ok((id, result)) = rx.recv_timeout(deadline.saturating_duration_since(Instant::now()))
        else {
            break;
        };
        match result {
            Ok(source) => {
                collected.insert(id.clone(), source);
            }
            Err(error) => eprintln!("{id}: {error}"),
        }
        answered.insert(id);
    }
    for id in ["claude", "codex", "agy"] {
        if !answered.contains(id) {
            eprintln!("{id}: timed out after 20s");
        }
    }
    providers.iter().for_each(|p| p.stop());

    for id in ["claude", "codex", "agy"] {
        if let Some(source) = collected.get(id) {
            println!("{}", describe(source));
        }
    }
    if collected.is_empty() { 1 } else { 0 }
}

fn describe(source: &UsageSource) -> String {
    let now = jiff::Timestamp::now();
    // aged_state is what the card renders, so report that rather than the raw
    // value — otherwise a stale source reads as ok here.
    let mut lines = vec![format!(
        "source     : {}  plan={}  account={}  state={}  updated={}",
        source.display_name,
        source.plan.as_deref().unwrap_or("—"),
        source.account.as_deref().unwrap_or("—"),
        source.aged_state(now),
        format::relative(source.last_updated, now)
    )];
    for w in &source.windows {
        let pace = w
            .pace_delta(now)
            .map(|d| format!("{:+.1}%", d * 100.0))
            .unwrap_or_else(|| "n/a".into());
        lines.push(format!(
            "  window   : {}  used={}  resets={}  pace={pace}",
            w.label,
            format::percent(w.used_percent),
            format::resets_in(w.resets_at, now)
        ));
    }
    for b in &source.buckets {
        lines.push(format!(
            "  bucket   : {}  used={}",
            b.label,
            format::percent(b.used_percent)
        ));
    }
    if let Some(spend) = &source.spend {
        lines.push(format!(
            "  spend    : {}  used={}  {}",
            spend.label,
            format::percent(spend.used_percent),
            spend.detail
        ));
    }
    if let Some(note) = &source.note {
        lines.push(format!("  note     : {note}"));
    }
    lines.join("\n")
}
