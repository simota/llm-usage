//! Antigravity usage through `agy`'s read-only print command. The CLI owns
//! login and local-server authentication; no session credentials are read here.
//! Port of `Sources/LLMUsage/AgyProvider.swift`.

use std::sync::Arc;
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use serde::Deserialize;

use crate::cli::{self, Env, Resolution, RunFailure};
use crate::model::{SourceState, UsageSource, UsageWindow, parse_timestamp};
use crate::provider::{Msg, Runner, Session, UpdateFn, UsageProvider};

// The read-only /usage command returns structured quota data in command.data.
// Fractions represent what remains, and reset times are RFC 3339 strings.
#[derive(Deserialize)]
struct AgyBucket {
    id: String,
    window: String,
    remaining_fraction: Option<f64>,
    reset_time: Option<String>,
}

#[derive(Deserialize)]
struct AgyGroup {
    name: String,
    buckets: Vec<AgyBucket>,
}

#[derive(Deserialize)]
struct AgyQuotaSummary {
    groups: Vec<AgyGroup>,
}

#[derive(Deserialize)]
struct AgyCommand {
    name: String,
    data: AgyQuotaSummary,
}

#[derive(Deserialize)]
struct AgyEnvelope {
    status: String,
    num_turns: i64,
    command: AgyCommand,
}

pub type CommandRunner = Arc<
    dyn Fn(&str, &[&str], &Env, Duration, &dyn Fn() -> bool) -> Result<String, RunFailure>
        + Send
        + Sync,
>;

pub struct Deps {
    pub resolve: Arc<dyn Fn() -> Option<Resolution> + Send + Sync>,
    pub run: CommandRunner,
}

impl Deps {
    pub fn system() -> Deps {
        Deps {
            resolve: Arc::new(|| cli::resolve("agy")),
            run: Arc::new(|path, args, env, timeout, cancelled| {
                cli::run(path, args, Some(env), timeout, &[0], cancelled)
            }),
        }
    }
}

const POLL_INTERVAL: Duration = Duration::from_secs(300);

#[derive(Clone, Copy, Debug, PartialEq)]
enum FetchFailure {
    Missing,
    Outdated,
    Failed,
    TimedOut,
    Unexpected,
}

impl FetchFailure {
    fn reason(self) -> &'static str {
        match self {
            FetchFailure::Missing => "agy not found (install Antigravity CLI)",
            FetchFailure::Outdated => "Update Antigravity CLI (agy 1.1.11+ required)",
            FetchFailure::Failed => "Antigravity unavailable (check agy /usage and login)",
            FetchFailure::TimedOut => "Antigravity usage request timed out",
            FetchFailure::Unexpected => "Unexpected Antigravity response (update agy)",
        }
    }
}

pub struct AgyProvider {
    deps: Arc<Deps>,
    runner: Runner<()>,
}

impl AgyProvider {
    pub fn new(deps: Deps, update: UpdateFn) -> Self {
        Self {
            deps: Arc::new(deps),
            runner: Runner::new(update),
        }
    }
}

impl UsageProvider for AgyProvider {
    fn start(&self) {
        let deps = self.deps.clone();
        self.runner.start("agy", move |session| run(deps, session));
    }

    fn refresh(&self) {
        self.runner.refresh();
    }

    /// Clears the session's alive flag, which the running command polls as its
    /// cancellation, so `cli::run` reaps its child promptly and nothing publishes.
    fn stop(&self) {
        self.runner.stop();
    }
}

fn run(deps: Arc<Deps>, session: Session<()>) {
    let mut last_good: Option<UsageSource> = None;
    let mut next_poll = Instant::now() + POLL_INTERVAL;
    let fetch = |last_good: &mut Option<UsageSource>| {
        let emitter = session.emitter.clone();
        let result = read_usage(&deps, &|| !emitter.is_alive());
        if !emitter.is_alive() {
            return;
        }
        match result {
            Ok(source) => {
                *last_good = Some(source.clone());
                emitter.source(source);
            }
            Err(failure) => emitter.source(unavailable(last_good.as_ref(), failure.reason())),
        }
    };
    fetch(&mut last_good);
    if !session.drain_refreshes(|()| {}) {
        return;
    }
    loop {
        match session
            .rx
            .recv_timeout(next_poll.saturating_duration_since(Instant::now()))
        {
            Ok(Msg::Refresh) => {}
            Ok(Msg::Event(())) => continue,
            Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => next_poll = Instant::now() + POLL_INTERVAL,
        }
        fetch(&mut last_good);
        if !session.drain_refreshes(|()| {}) {
            return;
        }
    }
}

fn unavailable(last_good: Option<&UsageSource>, reason: &str) -> UsageSource {
    match last_good {
        Some(previous) => {
            let mut previous = previous.clone();
            previous.note = Some(reason.to_string());
            previous.state = match previous.last_updated {
                Some(since) => SourceState::Stale { since },
                None => SourceState::Error(reason.to_string()),
            };
            previous
        }
        None => {
            let mut placeholder = UsageSource::placeholder("agy", "Antigravity");
            placeholder.note = Some(reason.to_string());
            placeholder
        }
    }
}

fn read_usage(deps: &Deps, is_cancelled: &dyn Fn() -> bool) -> Result<UsageSource, FetchFailure> {
    if is_cancelled() {
        return Err(FetchFailure::Failed);
    }
    let cli = (deps.resolve)().ok_or(FetchFailure::Missing)?;
    let failed = |e: RunFailure| match e {
        RunFailure::TimedOut => FetchFailure::TimedOut,
        _ => FetchFailure::Failed,
    };
    // Older releases can treat /usage as a model prompt in print mode. Check
    // support before invoking it, including after a CLI downgrade.
    let version = (deps.run)(
        &cli.path,
        &["--version"],
        &cli.environment,
        Duration::from_secs(3),
        is_cancelled,
    )
    .map_err(failed)?;
    if !supports_usage_command(&version) {
        return Err(FetchFailure::Outdated);
    }
    if is_cancelled() {
        return Err(FetchFailure::Failed);
    }
    let json = (deps.run)(
        &cli.path,
        &[
            "-p",
            "/usage",
            "--output-format",
            "json",
            "--print-timeout",
            "10s",
        ],
        &cli.environment,
        Duration::from_secs(10),
        is_cancelled,
    )
    .map_err(failed)?;
    let envelope: AgyEnvelope =
        serde_json::from_str(&json).map_err(|_| FetchFailure::Unexpected)?;
    let valid = envelope.status == "SUCCESS"
        && envelope.num_turns == 0
        && envelope.command.name == "usage"
        && envelope.command.data.groups.iter().all(|group| {
            group.buckets.iter().all(|bucket| {
                !bucket.id.is_empty()
                    && bucket
                        .remaining_fraction
                        .is_none_or(|f| f.is_finite() && (0.0..=1.0).contains(&f))
            })
        });
    if !valid {
        return Err(FetchFailure::Unexpected);
    }
    Ok(normalise(envelope.command.data))
}

pub fn supports_usage_command(version: &str) -> bool {
    let parts: Vec<&str> = version.trim().split('.').collect();
    if parts.len() != 3
        || !parts
            .iter()
            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
    {
        return false;
    }
    let (Ok(major), Ok(minor), Ok(patch)) = (
        parts[0].parse::<u64>(),
        parts[1].parse::<u64>(),
        parts[2].parse::<u64>(),
    ) else {
        return false;
    };
    major > 1 || (major == 1 && (minor > 1 || (minor == 1 && patch >= 11)))
}

fn normalise(summary: AgyQuotaSummary) -> UsageSource {
    let mut source = UsageSource::new("agy", "Antigravity");
    source.stale_after = 900.0;
    source.last_updated = Some(jiff::Timestamp::now());
    source.state = SourceState::Ok;
    source.note = Some("Shared with the desktop app and SDK".into());
    // /usage does not identify the account or plan. Keep both absent rather
    // than attaching an identity from another session to this snapshot.
    source.windows = summary
        .groups
        .iter()
        .flat_map(|group| {
            let short = short_name(&group.name);
            let mut windows: Vec<UsageWindow> = group
                .buckets
                .iter()
                .filter_map(|b| window(b, &short))
                .collect();
            windows.sort_by_key(|w| w.window_minutes.unwrap_or(i64::MAX));
            windows
        })
        .collect();
    source
}

fn window(bucket: &AgyBucket, group: &str) -> Option<UsageWindow> {
    let remaining = bucket.remaining_fraction?;
    let label = match bucket.window.as_str() {
        "weekly" => "7d",
        "" => "—",
        other => other,
    };
    let minutes = match bucket.window.as_str() {
        "5h" => Some(300),
        "weekly" => Some(10_080),
        _ => None,
    };
    Some(UsageWindow::new(
        bucket.id.clone(),
        format!("{group} {label}"),
        (1.0 - remaining) * 100.0,
        bucket.reset_time.as_deref().and_then(parse_timestamp),
        minutes,
    ))
}

fn short_name(display_name: &str) -> String {
    if display_name.is_empty() {
        return "—".into();
    }
    let mut name = display_name;
    for suffix in [" Models", " models"] {
        if let Some(stripped) = name.strip_suffix(suffix) {
            name = stripped;
        }
    }
    name.replace(" and ", "/")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::mpsc::{Receiver, channel};

    pub const QUOTA: &str = r#"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.5,"reset_time":"2030-01-05T00:00:00Z"},{"id":"gemini-5h","window":"5h","remaining_fraction":0.75,"reset_time":"2030-01-01T00:00:00.5Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-5h","window":"5h","remaining_fraction":1,"reset_time":"2030-01-01T00:00:00Z"},{"id":"3p-weekly","window":"weekly","remaining_fraction":0,"reset_time":"2030-01-05T00:00:00Z"}]}]}}}"#;

    type Calls = Arc<Mutex<Vec<Vec<String>>>>;

    fn make(
        installed: bool,
        responses: Vec<Result<String, RunFailure>>,
    ) -> (AgyProvider, Calls, Receiver<UsageSource>) {
        let calls: Calls = Arc::default();
        let queue = Arc::new(Mutex::new(responses));
        let recorded = calls.clone();
        let deps = Deps {
            resolve: Arc::new(move || {
                installed.then(|| Resolution {
                    path: "/fixture/agy".into(),
                    environment: [("PATH".to_string(), "/fixture:/usr/bin:/bin".to_string())]
                        .into(),
                })
            }),
            run: Arc::new(move |path, args, env, _timeout, _cancelled| {
                assert_eq!(path, "/fixture/agy");
                assert_eq!(env["PATH"], "/fixture:/usr/bin:/bin");
                recorded
                    .lock()
                    .unwrap()
                    .push(args.iter().map(|a| a.to_string()).collect());
                if args == ["--version"] {
                    return Ok("1.2.5\n".into());
                }
                let mut q = queue.lock().unwrap();
                if q.is_empty() {
                    Err(RunFailure::NotRun)
                } else {
                    q.remove(0)
                }
            }),
        };
        let (tx, rx) = channel();
        let tx = Mutex::new(tx);
        let provider = AgyProvider::new(
            deps,
            Arc::new(move |r| {
                let _ = tx.lock().unwrap().send(r.unwrap());
            }),
        );
        (provider, calls, rx)
    }

    fn next(rx: &Receiver<UsageSource>) -> UsageSource {
        rx.recv_timeout(Duration::from_secs(3)).expect("an update")
    }

    #[test]
    fn usage_command_returns_all_windows() {
        let (provider, calls, rx) = make(true, vec![Ok(QUOTA.into())]);
        provider.start();
        let source = next(&rx);
        provider.stop();
        assert_eq!(
            calls.lock().unwrap()[1],
            [
                "-p",
                "/usage",
                "--output-format",
                "json",
                "--print-timeout",
                "10s"
            ]
        );
        assert_eq!(source.state, SourceState::Ok);
        let ids: Vec<_> = source.windows.iter().map(|w| w.id.as_str()).collect();
        assert_eq!(ids, ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"]);
        let labels: Vec<_> = source.windows.iter().map(|w| w.label.as_str()).collect();
        assert_eq!(
            labels,
            ["Gemini 5h", "Gemini 7d", "Claude/GPT 5h", "Claude/GPT 7d"]
        );
        let used: Vec<_> = source.windows.iter().map(|w| w.used_percent).collect();
        assert_eq!(used, [25.0, 50.0, 0.0, 100.0]);
        assert!(source.windows.iter().all(|w| w.resets_at.is_some()));
        assert_eq!(source.account, None);
        assert_eq!(source.plan, None);
    }

    #[test]
    fn failure_preserves_timestamp_and_refresh_recovers() {
        let (provider, _calls, rx) = make(
            true,
            vec![
                Ok(QUOTA.into()),
                Err(RunFailure::TimedOut),
                Ok(QUOTA.replace("0.75", "0.5")),
            ],
        );
        provider.start();
        let original = next(&rx);
        provider.refresh();
        let failed = next(&rx);
        assert_eq!(failed.windows, original.windows);
        assert_eq!(
            failed.state,
            SourceState::Stale {
                since: original.last_updated.unwrap()
            }
        );
        assert_eq!(
            failed.note.as_deref(),
            Some("Antigravity usage request timed out")
        );
        provider.refresh();
        let recovered = next(&rx);
        provider.stop();
        assert_eq!(recovered.state, SourceState::Ok);
        assert_eq!(recovered.windows[0].used_percent, 50.0);
    }

    #[test]
    fn missing_cli_does_not_run_commands() {
        let (provider, calls, rx) = make(false, vec![]);
        provider.start();
        let source = next(&rx);
        provider.stop();
        assert_eq!(
            source.note.as_deref(),
            Some("agy not found (install Antigravity CLI)")
        );
        assert!(calls.lock().unwrap().is_empty());
    }

    #[test]
    fn model_turns_and_out_of_range_fractions_are_rejected() {
        let (provider, _calls, rx) = make(
            true,
            vec![
                Ok(QUOTA.replace("\"num_turns\":0", "\"num_turns\":1")),
                Ok(QUOTA.replace("0.75", "1.5")),
            ],
        );
        provider.start();
        assert_eq!(
            next(&rx).note.as_deref(),
            Some("Unexpected Antigravity response (update agy)")
        );
        provider.refresh();
        assert_eq!(
            next(&rx).note.as_deref(),
            Some("Unexpected Antigravity response (update agy)")
        );
        provider.stop();
    }

    #[test]
    fn version_gate() {
        for v in ["1.1.11", "1.2.0", "2.0.0", "1.1.11\n"] {
            assert!(supports_usage_command(v), "{v}");
        }
        for v in [
            "1.1.10",
            "1.0.99",
            "0.9.0",
            "1.1",
            "1.1.11-beta",
            "v1.2.0",
            "",
        ] {
            assert!(!supports_usage_command(v), "{v}");
        }
    }
}
