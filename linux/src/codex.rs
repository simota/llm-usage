//! Runs `codex app-server` as a child process and speaks line-delimited
//! JSON-RPC to it. Port of `Sources/LLMUsage/CodexProvider.swift`.
//!
//! Reads `account/rateLimits/read` once at startup, then relies on the server's
//! `account/rateLimits/updated` push notifications, with a slow poll as a backstop.

use std::collections::{BTreeMap, HashMap};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Arc;
use std::sync::mpsc::{RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::cli;
use crate::model::{SourceState, UsageSource, UsageSpend, UsageWindow, format, from_unix};
use crate::provider::{Emitter, Msg, Runner, Session, UpdateFn, UsageProvider};

// MARK: - Wire types (`codex app-server generate-json-schema`, docs/feasibility.md §1)

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct RateLimitWindow {
    used_percent: f64,
    window_duration_mins: Option<i64>,
    resets_at: Option<f64>,
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct CreditsSnapshot {
    has_credits: Option<bool>,
    unlimited: Option<bool>,
    balance: Option<String>,
}

/// A workspace spend control on this member. Amounts arrive as decimal strings.
#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct SpendControlLimit {
    limit: Option<String>,
    used: Option<String>,
    remaining_percent: Option<f64>,
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct RateLimitSnapshot {
    limit_id: Option<String>,
    limit_name: Option<String>,
    primary: Option<RateLimitWindow>,
    secondary: Option<RateLimitWindow>,
    credits: Option<CreditsSnapshot>,
    plan_type: Option<String>,
    individual_limit: Option<SpendControlLimit>,
    rate_limit_reached_type: Option<String>,
}

/// A free "Full reset" grant that can be spent to clear the rate limit early.
#[derive(Deserialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ResetCredit {
    status: Option<String>,
    expires_at: Option<f64>,
}

#[derive(Deserialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ResetCreditsSummary {
    available_count: Option<i64>,
    credits: Option<Vec<ResetCredit>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RateLimitsPayload {
    rate_limits: RateLimitSnapshot,
    rate_limits_by_limit_id: Option<BTreeMap<String, RateLimitSnapshot>>,
    rate_limit_reset_credits: Option<ResetCreditsSummary>,
    /// Null means unknown. The schema forbids inferring recovery from the
    /// percentages, so `false` is reported as-is even when they look low.
    ordinary_usage_allowed: Option<bool>,
}

#[derive(Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
struct AccountInfo {
    #[serde(rename = "type")]
    kind: Option<String>,
    email: Option<String>,
    plan_type: Option<String>,
}

#[derive(Deserialize)]
struct AccountPayload {
    account: Option<AccountInfo>,
}

#[derive(Deserialize)]
struct RpcResult<T> {
    result: T,
}

#[derive(Deserialize)]
struct RpcError {
    code: i64,
    message: String,
}

#[derive(Deserialize)]
struct RpcEnvelope {
    id: Option<i64>,
    method: Option<String>,
    error: Option<RpcError>,
}

// MARK: - Provider

pub enum MakeError {
    NotFound(String),
}

pub type MakeProcess = Arc<dyn Fn() -> Result<Command, MakeError> + Send + Sync>;

pub fn server_process() -> Result<Command, MakeError> {
    let resolution = cli::resolve("codex").ok_or_else(|| MakeError::NotFound("codex".into()))?;
    let mut command = Command::new(&resolution.path);
    command
        .arg("app-server")
        .env_clear()
        .envs(&resolution.environment);
    Ok(command)
}

pub struct CodexProvider {
    make_process: MakeProcess,
    request_timeout: Duration,
    poll_interval: Duration,
    runner: Runner<Event>,
}

impl CodexProvider {
    pub fn new(make_process: MakeProcess, update: UpdateFn) -> Self {
        Self::with_timing(
            make_process,
            Duration::from_secs(20),
            Duration::from_secs(300),
            update,
        )
    }

    pub fn with_timing(
        make_process: MakeProcess,
        request_timeout: Duration,
        poll_interval: Duration,
        update: UpdateFn,
    ) -> Self {
        Self {
            make_process,
            request_timeout,
            poll_interval,
            runner: Runner::new(update),
        }
    }
}

impl UsageProvider for CodexProvider {
    fn start(&self) {
        let (make, timeout, poll) = (
            self.make_process.clone(),
            self.request_timeout,
            self.poll_interval,
        );
        self.runner.start("codex", move |session| {
            Worker::new(make, timeout, poll, session).run()
        });
    }

    fn refresh(&self) {
        self.runner.refresh();
    }

    fn stop(&self) {
        self.runner.stop();
    }
}

pub enum Event {
    Line(u64, Vec<u8>),
    Eof(u64),
}

#[derive(PartialEq)]
enum State {
    Starting,
    Ready,
    Failed,
}

struct Pending {
    method: String,
    deadline: Instant,
}

struct Worker {
    make_process: MakeProcess,
    request_timeout: Duration,
    poll_interval: Duration,
    session: Session<Event>,
    state: State,
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    next_id: i64,
    generation: u64,
    cached_account: Option<AccountInfo>,
    published_account: Option<AccountInfo>,
    has_published_usage: bool,
    /// The per-credit rows cost the backend a separate lookup, so they are asked
    /// for only when the count has no matching rows on hand.
    reset_details: Option<ResetCreditsSummary>,
    needs_reset_details: bool,
    pending: HashMap<i64, Pending>,
}

impl Worker {
    fn new(
        make_process: MakeProcess,
        request_timeout: Duration,
        poll_interval: Duration,
        session: Session<Event>,
    ) -> Self {
        Self {
            make_process,
            request_timeout,
            poll_interval,
            session,
            state: State::Failed,
            child: None,
            stdin: None,
            next_id: 1,
            generation: 0,
            cached_account: None,
            published_account: None,
            has_published_usage: false,
            reset_details: None,
            needs_reset_details: true,
            pending: HashMap::new(),
        }
    }

    fn emitter(&self) -> &Emitter {
        &self.session.emitter
    }

    fn run(mut self) {
        let mut next_poll = Instant::now() + self.poll_interval;
        self.connect();
        loop {
            let mut deadline = next_poll;
            if let Some(earliest) = self.pending.values().map(|p| p.deadline).min() {
                deadline = deadline.min(earliest);
            }
            match self
                .session
                .rx
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            {
                Ok(Msg::Refresh) => self.refresh(),
                Ok(Msg::Event(Event::Line(generation, line))) if generation == self.generation => {
                    self.dispatch(&line)
                }
                Ok(Msg::Event(Event::Eof(generation))) if generation == self.generation => {
                    self.server_exited()
                }
                Ok(Msg::Event(_)) => {}
                Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => break,
                Err(RecvTimeoutError::Timeout) => {
                    let now = Instant::now();
                    let expired = self
                        .pending
                        .iter()
                        .find(|(_, p)| p.deadline <= now)
                        .map(|(_, p)| p.method.clone());
                    if let Some(method) = expired {
                        self.fail(format!("Codex {method} timed out. Retry to reconnect."));
                    }
                    if now >= next_poll {
                        next_poll = now + self.poll_interval;
                        self.refresh();
                    }
                }
            }
            if !self.emitter().is_alive() {
                break;
            }
        }
        self.disconnect();
    }

    fn connect(&mut self) {
        self.disconnect();
        self.state = State::Starting;
        let mut command = match (self.make_process)() {
            Ok(command) => command,
            Err(MakeError::NotFound(tool)) => {
                self.state = State::Failed;
                let mut source = UsageSource::placeholder("codex", "Codex");
                source.note = Some(format!("{tool} not found in PATH"));
                self.emitter().source(source);
                return;
            }
        };
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(e) => return self.fail(format!("Could not start codex app-server: {e}")),
        };
        let stdout = child.stdout.take().expect("stdout is piped");
        self.stdin = child.stdin.take();
        self.child = Some(child);
        let generation = self.generation;
        let tx: Sender<Msg<Event>> = self.session.tx.clone();
        std::thread::Builder::new()
            .name("llm-usage-codex-read".into())
            .spawn(move || {
                let mut reader = BufReader::new(stdout);
                loop {
                    let mut line = Vec::new();
                    match reader.read_until(b'\n', &mut line) {
                        Ok(0) | Err(_) => {
                            let _ = tx.send(Msg::Event(Event::Eof(generation)));
                            return;
                        }
                        Ok(_) => {
                            if line.last() == Some(&b'\n') {
                                line.pop();
                            }
                            if tx.send(Msg::Event(Event::Line(generation, line))).is_err() {
                                return;
                            }
                        }
                    }
                }
            })
            .expect("spawn codex reader");
        self.send(
            "initialize",
            json!({"clientInfo": {"name": "llm-usage", "title": "LLM Usage", "version": env!("CARGO_PKG_VERSION")}}),
        );
    }

    fn refresh(&mut self) {
        match self.state {
            State::Starting => {}
            State::Failed => self.connect(),
            State::Ready => {
                let running = self
                    .child
                    .as_mut()
                    .is_some_and(|c| c.try_wait().ok().flatten().is_none());
                if !running {
                    return self.connect();
                }
                if !self.pending.is_empty() {
                    return;
                }
                // Recheck identity before every snapshot so an external login
                // cannot attach usage from one account to the previous address.
                self.send("account/read", json!({}));
            }
        }
    }

    /// A server we terminated on purpose never gets here: its reader carries an
    /// older generation.
    fn server_exited(&mut self) {
        let status = self.child.as_mut().and_then(|child| {
            let until = Instant::now() + Duration::from_millis(500);
            loop {
                if let Some(status) = child.try_wait().ok().flatten() {
                    return Some(status);
                }
                if Instant::now() >= until {
                    return None;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        });
        let code = status
            .and_then(|s| {
                use std::os::unix::process::ExitStatusExt;
                s.code().or(s.signal())
            })
            .map(|c| c.to_string())
            .unwrap_or_else(|| "unknown".into());
        self.fail(format!("codex app-server exited (status {code})"));
    }

    fn disconnect(&mut self) {
        self.generation += 1;
        self.pending.clear();
        self.cached_account = None;
        self.reset_details = None;
        self.needs_reset_details = true;
        self.stdin = None;
        if let Some(mut child) = self.child.take() {
            // Off this thread: a server that ignores SIGTERM must not hold the
            // worker for the grace period.
            std::thread::spawn(move || cli::terminate(&mut child));
        }
    }

    fn fail(&mut self, message: String) {
        self.disconnect();
        self.state = State::Failed;
        self.emitter().emit(Err(message));
    }

    // MARK: - Transport

    fn send(&mut self, method: &str, params: Value) {
        let id = self.next_id;
        self.next_id += 1;
        self.pending.insert(
            id,
            Pending {
                method: method.to_string(),
                deadline: Instant::now() + self.request_timeout,
            },
        );
        self.write(json!({"id": id, "method": method, "params": params}));
    }

    fn write(&mut self, mut message: Value) {
        message["jsonrpc"] = json!("2.0");
        let mut line = serde_json::to_vec(&message).expect("serialisable");
        line.push(b'\n');
        let written = match self.stdin.as_mut() {
            Some(stdin) => stdin.write_all(&line).and_then(|()| stdin.flush()).is_ok(),
            None => false,
        };
        if !written {
            self.fail("Codex is disconnected. Retry to reconnect.".into());
        }
    }

    fn dispatch(&mut self, line: &[u8]) {
        let Ok(envelope) = serde_json::from_slice::<RpcEnvelope>(line) else {
            return;
        };
        let Some(id) = envelope.id else {
            if self.state != State::Ready {
                return;
            }
            match envelope.method.as_deref() {
                Some("account/updated") => {
                    self.pending.clear();
                    self.cached_account = None;
                    self.reset_details = None;
                    self.needs_reset_details = true;
                    if self.has_published_usage {
                        self.has_published_usage = false;
                        self.emitter()
                            .source(UsageSource::placeholder("codex", "Codex"));
                    }
                    self.refresh();
                }
                // Pushes are sparse. Refetch a complete snapshot and its identity.
                Some("account/rateLimits/updated") => self.refresh(),
                _ => {}
            }
            return;
        };
        let Some(request) = self.pending.remove(&id) else {
            return;
        };
        if let Some(error) = envelope.error {
            return self.fail(format!(
                "Codex {} failed ({}): {}",
                request.method, error.code, error.message
            ));
        }
        fn decode<T: DeserializeOwned>(line: &[u8]) -> Option<T> {
            serde_json::from_slice::<RpcResult<T>>(line)
                .ok()
                .map(|r| r.result)
        }
        let invalid = format!("Codex returned an invalid {} response.", request.method);
        match request.method.as_str() {
            "initialize" => {
                if decode::<Value>(line).is_none_or(|v| !v.is_object()) {
                    return self.fail(invalid);
                }
                self.write(json!({"method": "initialized"}));
                if self.state != State::Starting {
                    return;
                }
                self.state = State::Ready;
                self.refresh();
            }
            "account/read" => {
                let Some(payload) = decode::<AccountPayload>(line) else {
                    return self.fail(invalid);
                };
                let account = payload.account;
                if self.has_published_usage && account != self.published_account {
                    self.has_published_usage = false;
                    let mut source = UsageSource::placeholder("codex", "Codex");
                    source.account = account.as_ref().and_then(|a| a.email.clone());
                    source.plan = plan_name(account.as_ref().and_then(|a| a.plan_type.as_deref()));
                    self.emitter().source(source);
                    self.reset_details = None;
                    self.needs_reset_details = true;
                }
                self.cached_account = account;
                let params = if self.needs_reset_details {
                    Value::Null
                } else {
                    json!({"excludeResetCreditDetails": true})
                };
                self.send("account/rateLimits/read", params);
            }
            "account/rateLimits/read" => {
                let Some(payload) = decode::<RateLimitsPayload>(line) else {
                    return self.fail(invalid);
                };
                let resets = self.reset_credits(payload.rate_limit_reset_credits.clone());
                let mut source = normalise(&payload, resets.as_ref());
                source.account = self.cached_account.as_ref().and_then(|a| a.email.clone());
                self.published_account = self.cached_account.clone();
                self.has_published_usage = true;
                self.emitter().source(source);
            }
            _ => {}
        }
    }

    /// A summary without rows reuses the last rows while the count still
    /// matches; otherwise the next read asks for them again.
    fn reset_credits(
        &mut self,
        summary: Option<ResetCreditsSummary>,
    ) -> Option<ResetCreditsSummary> {
        let count = summary.as_ref().and_then(|s| s.available_count);
        if summary.as_ref().is_some_and(|s| s.credits.is_some()) {
            self.reset_details = summary.clone();
        } else if let Some(cached) = self.reset_details.clone()
            && cached.available_count == count
        {
            return Some(cached);
        } else {
            self.reset_details = None;
        }
        self.needs_reset_details = self.reset_details.is_none() && count.unwrap_or(0) > 0;
        self.reset_details.clone().or(summary)
    }
}

// MARK: - Normalisation

fn normalise(payload: &RateLimitsPayload, resets: Option<&ResetCreditsSummary>) -> UsageSource {
    let snapshot = &payload.rate_limits;
    let mut source = UsageSource::new("codex", "Codex");
    source.plan = plan_name(snapshot.plan_type.as_deref());
    source.stale_after = 600.0;
    source.last_updated = Some(jiff::Timestamp::now());
    source.state = SourceState::Ok;

    let mut windows: Vec<UsageWindow> = [
        window(snapshot.primary.as_ref(), "codex-primary".into(), None),
        window(snapshot.secondary.as_ref(), "codex-secondary".into(), None),
    ]
    .into_iter()
    .flatten()
    .collect();

    // Each additional metered limit is a window in its own right — Spark has its
    // own duration and its own reset.
    for (key, snap) in payload.rate_limits_by_limit_id.iter().flatten() {
        if Some(key) == snapshot.limit_id.as_ref() {
            continue;
        }
        let label = short_label(snap.limit_name.as_deref()).unwrap_or_else(|| key.clone());
        windows.extend(window(
            snap.primary.as_ref(),
            format!("codex-{key}-primary"),
            Some(&label),
        ));
        windows.extend(window(
            snap.secondary.as_ref(),
            format!("codex-{key}-secondary"),
            Some(&label),
        ));
    }
    source.windows = windows;
    source.spend = spend_row(snapshot.individual_limit.as_ref());
    source.note = notes(snapshot, resets, payload.ordinary_usage_allowed);
    source
}

/// "pro" -> "Pro", "self_serve_business_usage_based" -> "Self Serve Business Usage Based".
fn plan_name(kind: Option<&str>) -> Option<String> {
    kind.map(|k| {
        k.replace('_', " ")
            .split(' ')
            .map(|word| {
                let mut chars = word.chars();
                match chars.next() {
                    Some(first) => first
                        .to_uppercase()
                        .chain(chars.flat_map(char::to_lowercase))
                        .collect(),
                    None => String::new(),
                }
            })
            .collect::<Vec<String>>()
            .join(" ")
    })
}

fn spend_row(limit: Option<&SpendControlLimit>) -> Option<UsageSpend> {
    let limit = limit?;
    let remaining = limit.remaining_percent?;
    let detail = [limit.used.as_deref(), limit.limit.as_deref()]
        .into_iter()
        .flatten()
        .map(amount)
        .collect::<Vec<_>>()
        .join(" / ");
    Some(UsageSpend {
        label: "Spend".into(),
        used_percent: 100.0 - remaining,
        detail,
    })
}

/// "58716.3917850000" -> "58,716.39": up to two decimals, grouped thousands.
pub fn amount(value: &str) -> String {
    let Ok(number) = value.parse::<f64>() else {
        return value.to_string();
    };
    let rounded = format!("{:.2}", number.abs());
    let (whole, fraction) = rounded.split_once('.').unwrap_or((&rounded, ""));
    let fraction = fraction.trim_end_matches('0');
    let mut grouped = String::new();
    for (i, digit) in whole.chars().enumerate() {
        if i > 0 && (whole.len() - i) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    let sign = if number < 0.0 && !rounded.trim_matches(['0', '.']).is_empty() {
        "-"
    } else {
        ""
    };
    if fraction.is_empty() {
        format!("{sign}{grouped}")
    } else {
        format!("{sign}{grouped}.{fraction}")
    }
}

/// Why ordinary usage is blocked, when the server says it is.
fn blocked_reason(kind: Option<&str>, usage_allowed: Option<bool>) -> Option<&'static str> {
    match kind {
        Some("rate_limit_reached") => Some("Limit reached"),
        Some("workspace_owner_credits_depleted" | "workspace_member_credits_depleted") => {
            Some("Workspace credits depleted")
        }
        Some("workspace_owner_usage_limit_reached" | "workspace_member_usage_limit_reached") => {
            Some("Workspace usage limit reached")
        }
        _ => (usage_allowed == Some(false)).then_some("Usage blocked"),
    }
}

fn notes(
    snapshot: &RateLimitSnapshot,
    resets: Option<&ResetCreditsSummary>,
    usage_allowed: Option<bool>,
) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();
    // Leads the line: it overrides whatever the percentages suggest.
    if let Some(blocked) =
        blocked_reason(snapshot.rate_limit_reached_type.as_deref(), usage_allowed)
    {
        parts.push(blocked.into());
    }
    // Free rate-limit resets: the most actionable thing on this card when the
    // weekly limit is running hot, and they expire.
    let available: Vec<&ResetCredit> = resets
        .and_then(|r| r.credits.as_ref())
        .map(|c| {
            c.iter()
                .filter(|c| c.status.as_deref() == Some("available"))
                .collect()
        })
        .unwrap_or_default();
    let count = resets
        .and_then(|r| r.available_count)
        .unwrap_or(available.len() as i64);
    if count > 0 {
        let soonest = available
            .iter()
            .filter_map(|c| c.expires_at)
            .fold(None, |m: Option<f64>, e| Some(m.map_or(e, |m| m.min(e))))
            .and_then(from_unix);
        let deadline = soonest
            .map(|d| {
                format!(
                    " (first expires {})",
                    format::resets_in(Some(d), jiff::Timestamp::now())
                )
            })
            .unwrap_or_default();
        parts.push(format!(
            "{count} free reset{}{deadline}",
            if count == 1 { "" } else { "s" }
        ));
    }
    // Only worth a line when there is actually a balance.
    if let Some(credits) = &snapshot.credits
        && credits.unlimited != Some(true)
        && credits.has_credits == Some(true)
        && let Some(balance) = &credits.balance
        && balance.parse::<f64>().is_ok_and(|a| a != 0.0)
    {
        parts.push(format!("Credit balance {balance}"));
    }
    (!parts.is_empty()).then(|| parts.join(" · "))
}

fn window(w: Option<&RateLimitWindow>, id: String, label: Option<&str>) -> Option<UsageWindow> {
    let w = w?;
    let duration = label_for_minutes(w.window_duration_mins);
    let label = match label {
        Some(l) => format!("{l} {duration}"),
        None => duration,
    };
    Some(UsageWindow::new(
        id,
        label,
        w.used_percent,
        w.resets_at.and_then(from_unix),
        w.window_duration_mins,
    ))
}

/// "GPT-5.3-Codex-Spark" -> "Spark": the trailing component is what
/// distinguishes one limit from another inside this card.
fn short_label(name: Option<&str>) -> Option<String> {
    let name = name.filter(|n| !n.is_empty())?;
    Some(name.split('-').next_back().unwrap_or(name).to_string())
}

fn label_for_minutes(minutes: Option<i64>) -> String {
    match minutes {
        Some(300) => "5h".into(),
        Some(10_080) => "7d".into(),
        Some(m) => format!("{}h", m / 60),
        None => "—".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc::{Receiver, channel};

    const USAGE: &str = r#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":50,"windowDurationMins":300,"resetsAt":2000000000},"secondary":null,"planType":"pro"},"rateLimitsByLimitId":{"spark":{"limitName":"GPT-Codex-Spark","primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":99,"windowDurationMins":10080}}}}"#;

    fn server(initialize: &str, account: &str, usage: &str) -> String {
        format!(
            r#"
while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -nE 's/.*"id":([0-9]+).*/\1/p')
    case "$line" in
        *'"method":"initialized"'*) ready=yes ;;
        *'"method":"initialize"'*)
            {initialize}
            printf '{{"id":%s,"result":{{}}}}\n' "$id"
            ;;
        *rateLimits*read*)
            {usage}
            printf '{{"id":%s,"result":%s}}\n' "$id" '{USAGE}'
            ;;
        *account*read*)
            if [ "$ready" != yes ]; then
                printf '{{"id":%s,"error":{{"code":-32002,"message":"Not initialized"}}}}\n' "$id"
                continue
            fi
            {account}
            printf '{{"id":%s,"result":{{"account":{{"type":"chatgpt","email":"one@example.test","planType":"pro"}}}}}}\n' "$id"
            ;;
    esac
done
"#
        )
    }

    fn provider(
        script: String,
        starts: Arc<AtomicUsize>,
        timeout: Duration,
    ) -> (CodexProvider, Receiver<Result<UsageSource, String>>) {
        let (tx, rx) = channel();
        let tx = Mutex::new(tx);
        let make: MakeProcess = Arc::new(move || {
            starts.fetch_add(1, Ordering::SeqCst);
            let mut c = Command::new("/bin/sh");
            c.args(["-c", &script])
                .env_clear()
                .env("PATH", "/usr/bin:/bin");
            Ok(c)
        });
        let p = CodexProvider::with_timing(
            make,
            timeout,
            Duration::from_secs(300),
            Arc::new(move |r| {
                let _ = tx.lock().unwrap().send(r);
            }),
        );
        (p, rx)
    }

    fn next(rx: &Receiver<Result<UsageSource, String>>) -> Result<UsageSource, String> {
        rx.recv_timeout(Duration::from_secs(3)).expect("an update")
    }

    #[test]
    fn handshake_waits_for_initialization_and_keeps_both_additional_windows() {
        let (p, rx) = provider(
            server("sleep 0.05", "", ""),
            Arc::default(),
            Duration::from_secs(20),
        );
        p.start();
        let source = next(&rx).unwrap();
        p.stop();
        assert_eq!(source.state, SourceState::Ok);
        assert_eq!(source.account.as_deref(), Some("one@example.test"));
        let ids: Vec<_> = source.windows.iter().map(|w| w.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "codex-primary",
                "codex-spark-primary",
                "codex-spark-secondary"
            ]
        );
        let labels: Vec<_> = source.windows.iter().map(|w| w.label.as_str()).collect();
        assert_eq!(labels, ["5h", "Spark 5h", "Spark 7d"]);
        assert_eq!(source.worst_window().unwrap().used_percent, 99.0);
        assert_eq!(source.plan.as_deref(), Some("Pro"));
    }

    #[test]
    fn rpc_error_is_reported_with_request_method() {
        let script = server(
            "",
            r#"printf '{"id":%s,"error":{"code":-32001,"message":"Not authenticated"}}\n' "$id"; continue"#,
            "",
        );
        let (p, rx) = provider(script, Arc::default(), Duration::from_secs(20));
        p.start();
        let error = next(&rx).unwrap_err();
        p.stop();
        assert!(
            error.contains("account/read") && error.contains("Not authenticated"),
            "{error}"
        );
    }

    #[test]
    fn refresh_reconnects_after_server_exit() {
        let starts = Arc::new(AtomicUsize::new(0));
        let (p, rx) = provider(
            "read -r line; exit 3".into(),
            starts.clone(),
            Duration::from_secs(20),
        );
        p.start();
        let error = next(&rx).unwrap_err();
        assert!(error.contains("exited (status 3)"), "{error}");
        p.refresh();
        let _ = next(&rx);
        p.stop();
        assert_eq!(starts.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn timeout_can_be_retried_and_duplicate_starts_are_ignored() {
        let starts = Arc::new(AtomicUsize::new(0));
        let (p, rx) = provider("sleep 5".into(), starts.clone(), Duration::from_millis(200));
        p.start();
        p.start();
        let error = next(&rx).unwrap_err();
        assert!(error.contains("timed out"), "{error}");
        assert_eq!(starts.load(Ordering::SeqCst), 1);
        p.refresh();
        let _ = next(&rx);
        p.stop();
        assert_eq!(starts.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn blocked_usage_spend_control_and_plan_are_surfaced() {
        let usage = r#"printf '{"id":%s,"result":%s}\n' "$id" '{"ordinaryUsageAllowed":false,"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":10080},"planType":"self_serve_business_usage_based","rateLimitReachedType":"workspace_member_credits_depleted","individualLimit":{"limit":"200.0000","used":"150.5000","remainingPercent":25,"resetsAt":2000000000}}}'; continue"#;
        let (p, rx) = provider(
            server("", "", usage),
            Arc::default(),
            Duration::from_secs(20),
        );
        p.start();
        let source = next(&rx).unwrap();
        p.stop();
        assert_eq!(
            source.plan.as_deref(),
            Some("Self Serve Business Usage Based")
        );
        assert_eq!(source.note.as_deref(), Some("Workspace credits depleted"));
        let spend = source.spend.unwrap();
        assert_eq!(spend.used_percent, 75.0);
        assert_eq!(spend.detail, "150.5 / 200");
    }

    #[test]
    fn reset_credit_rows_are_reused_while_the_count_matches() {
        let usage = r#"reads=$((reads + 1))
            case "$line" in *excludeResetCreditDetails*) used=2 ;; *) used=1 ;; esac
            if [ "$reads" -eq 1 ]; then credits='[{"id":"a","resetType":"codexRateLimits","status":"available","grantedAt":1,"expiresAt":4000000000}]'; else credits=null; fi
            printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":%s,"windowDurationMins":10080}},"rateLimitResetCredits":{"availableCount":1,"credits":%s}}}\n' "$id" "$used" "$credits"
            continue"#;
        let (p, rx) = provider(
            server("", "", usage),
            Arc::default(),
            Duration::from_secs(20),
        );
        p.start();
        let first = next(&rx).unwrap();
        assert_eq!(first.windows[0].used_percent, 1.0);
        p.refresh();
        let second = next(&rx).unwrap();
        p.stop();
        assert_eq!(second.windows[0].used_percent, 2.0);
        assert_eq!(first.note, second.note);
        assert!(second.note.unwrap().contains("first expires"));
    }

    #[test]
    fn account_change_clears_old_usage_before_new_snapshot() {
        let account = r#"reads=$((reads + 1))
            if [ "$reads" -gt 1 ]; then printf '{"id":%s,"result":{"account":{"email":"two@example.test","planType":"plus"}}}\n' "$id"; continue; fi"#;
        let (p, rx) = provider(
            server("", account, ""),
            Arc::default(),
            Duration::from_secs(20),
        );
        p.start();
        assert_eq!(
            next(&rx).unwrap().account.as_deref(),
            Some("one@example.test")
        );
        p.refresh();
        let cleared = next(&rx).unwrap();
        assert_eq!(cleared.state, SourceState::Unconfigured);
        assert!(cleared.windows.is_empty());
        assert_eq!(cleared.account.as_deref(), Some("two@example.test"));
        let fresh = next(&rx).unwrap();
        p.stop();
        assert_eq!(fresh.account.as_deref(), Some("two@example.test"));
        assert_eq!(fresh.state, SourceState::Ok);
    }

    #[test]
    fn stop_prevents_late_callbacks() {
        let (p, rx) = provider(
            server("sleep 0.3", "", ""),
            Arc::default(),
            Duration::from_secs(20),
        );
        p.start();
        std::thread::sleep(Duration::from_millis(50));
        p.stop();
        assert!(rx.recv_timeout(Duration::from_millis(600)).is_err());
    }

    #[test]
    fn amounts_are_grouped_with_at_most_two_decimals() {
        assert_eq!(amount("58716.3917850000"), "58,716.39");
        assert_eq!(amount("200.0000"), "200");
        assert_eq!(amount("150.5000"), "150.5");
        assert_eq!(amount("1234567"), "1,234,567");
        assert_eq!(amount("n/a"), "n/a");
    }
}
