//! Claude.ai subscription limits from the OAuth usage endpoint, using the token
//! Claude Code already holds. Port of `Sources/LLMUsage/ClaudeProvider.swift`.
//!
//! On Linux Claude Code keeps its login in `~/.claude/.credentials.json`
//! (`$CLAUDE_CONFIG_DIR/.credentials.json` when that is set), in the same
//! `claudeAiOauth` shape the macOS keychain item holds. The file is only ever
//! read.
//!
//! Read-only by design. The access token lasts about an hour and only Claude
//! Code refreshes it; refreshing here would rotate the refresh token server-side
//! and, without writing the new one back, invalidate the user's Claude Code
//! login. An expired token is surfaced as staleness, and the file is re-read each
//! cycle to pick up whatever Claude Code last wrote.

use std::path::PathBuf;
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use jiff::Timestamp;
use serde::Deserialize;

use crate::cli;
use crate::model::{
    SourceState, UsageBucket, UsageSource, UsageSpend, UsageWindow, add_secs, format,
    parse_timestamp, secs_between,
};
use crate::provider::{Emitter, Msg, Runner, Session, UpdateFn, UsageProvider};

// MARK: - Wire types (docs/feasibility.md §2)

#[derive(Deserialize, Default)]
struct OAuthUsage {
    five_hour: Option<FlatWindow>,
    seven_day: Option<FlatWindow>,
    limits: Option<Vec<Limit>>,
    spend: Option<Spend>,
}

#[derive(Deserialize)]
struct FlatWindow {
    utilization: Option<f64>,
    resets_at: Option<String>,
}

#[derive(Deserialize)]
struct Limit {
    kind: Option<String>,
    percent: Option<f64>,
    resets_at: Option<String>,
    scope: Option<Scope>,
    /// Which window is actually metering right now.
    is_active: Option<bool>,
}

#[derive(Deserialize)]
struct Scope {
    model: Option<ScopeModel>,
}

#[derive(Deserialize)]
struct ScopeModel {
    display_name: Option<String>,
}

#[derive(Deserialize)]
struct Money {
    amount_minor: Option<f64>,
    currency: Option<String>,
    exponent: Option<i32>,
}

#[derive(Deserialize)]
struct Spend {
    used: Option<Money>,
    limit: Option<Money>,
    percent: Option<f64>,
    enabled: Option<bool>,
}

// MARK: - Endpoint

#[derive(Clone, Debug, PartialEq)]
pub enum Endpoint {
    Production,
    Test(String),
    Invalid,
}

const PRODUCTION_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const TEST_TOKEN: &str = "llm-usage-test-token";

impl Endpoint {
    /// `LLM_USAGE_CLAUDE_ENDPOINT` accepts only an HTTP(S) loopback URL with no
    /// credentials in it.
    pub fn configured(value: Option<&str>) -> Endpoint {
        let Some(value) = value else {
            return Endpoint::Production;
        };
        let lower = value.to_ascii_lowercase();
        let Some(rest) = lower
            .strip_prefix("http://")
            .or_else(|| lower.strip_prefix("https://"))
        else {
            return Endpoint::Invalid;
        };
        let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
        if authority.contains('@') {
            return Endpoint::Invalid;
        }
        let host = if authority.starts_with('[') {
            authority
                .split(']')
                .next()
                .map(|h| format!("{h}]"))
                .unwrap_or_default()
        } else {
            authority.split(':').next().unwrap_or("").to_string()
        };
        if ["localhost", "127.0.0.1", "[::1]"].contains(&host.as_str()) {
            Endpoint::Test(value.to_string())
        } else {
            Endpoint::Invalid
        }
    }

    fn url(&self) -> Option<&str> {
        match self {
            Endpoint::Production => Some(PRODUCTION_URL),
            Endpoint::Test(url) => Some(url),
            Endpoint::Invalid => None,
        }
    }
}

// MARK: - Credential

#[derive(Clone, Debug, PartialEq)]
pub enum Credential {
    Token(String),
    Expired,
    /// No credentials file exists.
    Missing,
    /// The file exists but could not be read. The remedy differs from `Missing`:
    /// fix the permission, not sign in.
    Unreadable(String),
    /// Read, but not in the shape this decoder expects — a change on Claude
    /// Code's side, not an access problem.
    Malformed,
}

/// Claude Code's own format, not ours: this is the one place that knows it.
pub fn parse_credential(text: &str, now: Timestamp) -> Credential {
    let Ok(root) = serde_json::from_str::<serde_json::Value>(text) else {
        return Credential::Malformed;
    };
    let oauth = &root["claudeAiOauth"];
    let Some(token) = oauth["accessToken"].as_str().filter(|t| !t.is_empty()) else {
        return Credential::Malformed;
    };
    // expiresAt is milliseconds since epoch.
    if let Some(expires_at) = oauth["expiresAt"].as_f64()
        && now.as_millisecond() as f64 >= expires_at
    {
        return Credential::Expired;
    }
    Credential::Token(token.to_string())
}

pub fn credentials_path() -> PathBuf {
    match std::env::var_os("CLAUDE_CONFIG_DIR").filter(|v| !v.is_empty()) {
        Some(dir) => PathBuf::from(dir).join(".credentials.json"),
        None => PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
            .join(".claude/.credentials.json"),
    }
}

fn read_credential_file() -> Credential {
    use std::io::{ErrorKind, Read};
    let path = credentials_path();
    let file = match std::fs::File::open(&path) {
        Ok(file) => file,
        Err(e) if e.kind() == ErrorKind::NotFound => return Credential::Missing,
        Err(e) if e.kind() == ErrorKind::PermissionDenied => {
            return Credential::Unreadable(
                "Credentials file unreadable (permission denied)".into(),
            );
        }
        Err(e) => return Credential::Unreadable(format!("Credentials file unreadable ({e})")),
    };
    let mut text = String::new();
    if let Err(e) = file.take(1_048_577).read_to_string(&mut text) {
        return Credential::Unreadable(format!("Credentials file unreadable ({e})"));
    }
    if text.len() > 1_048_576 {
        return Credential::Unreadable("Credentials file was too large".into());
    }
    parse_credential(&text, Timestamp::now())
}

// MARK: - Identity

/// "Asked Claude Code and got an answer" (which may be no account at all — a
/// real sign-out) versus "couldn't ask".
#[derive(Clone, Debug, PartialEq)]
pub enum AuthProbe {
    Unreachable,
    Answered {
        plan: Option<String>,
        account: Option<String>,
    },
}

impl AuthProbe {
    pub fn plan(&self) -> Option<String> {
        match self {
            AuthProbe::Answered { plan, .. } => plan.clone(),
            AuthProbe::Unreachable => None,
        }
    }

    pub fn account(&self) -> Option<String> {
        match self {
            AuthProbe::Answered { account, .. } => account.clone(),
            AuthProbe::Unreachable => None,
        }
    }
}

/// `claude auth status --json` gives the plan and the signed-in address.
pub fn auth_status(executable: &str, environment: Option<&cli::Env>) -> AuthProbe {
    // A signed-out CLI returns valid status JSON with exit code 1.
    let Ok(json) = cli::run(
        executable,
        &["auth", "status", "--json"],
        environment,
        Duration::from_secs(10),
        &[0, 1],
        &|| false,
    ) else {
        return AuthProbe::Unreachable;
    };
    let Ok(serde_json::Value::Object(root)) = serde_json::from_str::<serde_json::Value>(&json)
    else {
        return AuthProbe::Unreachable;
    };
    // The token comes from the file a claude.ai login writes, while this answer
    // comes from whatever credential the CLI resolved. Under any other method
    // the address belongs to a different credential, so it must not label usage
    // fetched with the file's token. An older CLI that omits the field is taken
    // at its word.
    if let Some(method) = root.get("authMethod").and_then(|m| m.as_str())
        && method != "claude.ai"
    {
        return AuthProbe::Answered {
            plan: None,
            account: None,
        };
    }
    let plan = root
        .get("subscriptionType")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(capitalize_first);
    let account = root
        .get("email")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(String::from);
    AuthProbe::Answered { plan, account }
}

fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

fn system_auth_status() -> AuthProbe {
    match cli::resolve("claude") {
        Some(r) => auth_status(&r.path, Some(&r.environment)),
        None => AuthProbe::Unreachable,
    }
}

fn claude_version() -> Option<String> {
    // "2.1.220 (Claude Code)" -> "2.1.220"
    let r = cli::resolve("claude")?;
    let out = cli::run(
        &r.path,
        &["--version"],
        Some(&r.environment),
        Duration::from_secs(10),
        &[0],
        &|| false,
    )
    .ok()?;
    out.split_whitespace().next().map(String::from)
}

// MARK: - HTTP

pub struct HttpResponse {
    /// 0 when nothing came back at all.
    pub status: u16,
    pub retry_after: Option<String>,
    pub body: Vec<u8>,
}

pub type HttpFn = Arc<dyn Fn(&str, &str, &str) -> HttpResponse + Send + Sync>;

fn ureq_get(url: &str, token: &str, user_agent: &str) -> HttpResponse {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    let agent = AGENT.get_or_init(|| {
        ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(15)))
            .http_status_as_error(false)
            .build()
            .into()
    });
    match agent
        .get(url)
        .header("Authorization", &format!("Bearer {token}"))
        // Mandatory: without it the request lands in a heavily throttled bucket.
        .header("User-Agent", user_agent)
        .call()
    {
        Ok(mut response) => {
            let status = response.status().as_u16();
            let retry_after = response
                .headers()
                .get("Retry-After")
                .and_then(|v| v.to_str().ok())
                .map(String::from);
            let body = response
                .body_mut()
                .with_config()
                .limit(1_048_576)
                .read_to_vec()
                .unwrap_or_default();
            HttpResponse {
                status,
                retry_after,
                body,
            }
        }
        Err(_) => HttpResponse {
            status: 0,
            retry_after: None,
            body: Vec::new(),
        },
    }
}

/// `Retry-After` is either a delay in seconds or an HTTP date.
pub fn retry_after(value: Option<&str>, now: Timestamp) -> Option<f64> {
    let value = value?.trim();
    if value.is_empty() {
        return None;
    }
    if let Ok(seconds) = value.parse::<f64>() {
        return seconds.is_finite().then(|| seconds.max(1.0));
    }
    let date = jiff::fmt::rfc2822::parse(value).ok()?.timestamp();
    Some(secs_between(now, date).max(1.0))
}

// MARK: - Provider

pub struct Deps {
    pub endpoint: Endpoint,
    pub http: HttpFn,
    pub credential: Arc<dyn Fn() -> Credential + Send + Sync>,
    pub identity: Arc<dyn Fn() -> AuthProbe + Send + Sync>,
    pub version: Arc<dyn Fn() -> Option<String> + Send + Sync>,
    pub now: Arc<dyn Fn() -> Timestamp + Send + Sync>,
}

impl Deps {
    pub fn system() -> Deps {
        Deps {
            endpoint: Endpoint::configured(
                std::env::var("LLM_USAGE_CLAUDE_ENDPOINT").ok().as_deref(),
            ),
            http: Arc::new(ureq_get),
            credential: Arc::new(read_credential_file),
            identity: Arc::new(system_auth_status),
            version: Arc::new(claude_version),
            now: Arc::new(Timestamp::now),
        }
    }
}

/// Below ~180s the endpoint drops into an aggressively rate-limited bucket.
const POLL_INTERVAL: f64 = 300.0;
/// A throttle or a dead connection clears up on its own, so it deserves a retry
/// sooner than the next poll — but backing off matters: the 429 bucket only
/// widens if we keep knocking. Caps at the poll interval.
const RETRY_DELAYS: [f64; 4] = [30.0, 60.0, 120.0, 300.0];

pub struct ClaudeProvider {
    deps: Arc<Deps>,
    runner: Runner<()>,
}

impl ClaudeProvider {
    pub fn new(deps: Deps, update: UpdateFn) -> Self {
        Self {
            deps: Arc::new(deps),
            runner: Runner::new(update),
        }
    }
}

impl UsageProvider for ClaudeProvider {
    fn start(&self) {
        let deps = self.deps.clone();
        self.runner
            .start("claude", move |session| Worker::new(deps, session).run());
    }

    fn refresh(&self) {
        self.runner.refresh();
    }

    fn stop(&self) {
        self.runner.stop();
    }
}

struct Worker {
    deps: Arc<Deps>,
    session: Session<()>,
    last_good: Option<UsageSource>,
    retry_attempt: usize,
    retry_at: Option<Timestamp>,
    next_allowed_fetch_at: Option<Timestamp>,
    session_token: Option<String>,
    identity: AuthProbe,
    user_agent: Option<String>,
}

impl Worker {
    fn new(deps: Arc<Deps>, session: Session<()>) -> Self {
        Self {
            deps,
            session,
            last_good: None,
            retry_attempt: 0,
            retry_at: None,
            next_allowed_fetch_at: None,
            session_token: None,
            identity: AuthProbe::Unreachable,
            user_agent: None,
        }
    }

    fn now(&self) -> Timestamp {
        (self.deps.now)()
    }

    fn emitter(&self) -> &Emitter {
        &self.session.emitter
    }

    fn run(mut self) {
        let mut next_poll = std::time::Instant::now() + Duration::from_secs_f64(POLL_INTERVAL);
        self.attempt_fetch();
        loop {
            let instant_now = std::time::Instant::now();
            let mut wait = next_poll.saturating_duration_since(instant_now);
            if let Some(retry_at) = self.retry_at {
                let until = Duration::from_secs_f64(secs_between(self.now(), retry_at).max(0.0));
                wait = wait.min(until);
            }
            match self.session.rx.recv_timeout(wait) {
                Ok(Msg::Refresh) => {
                    self.attempt_fetch();
                    if !self.session.drain_refreshes(|()| {}) {
                        return;
                    }
                }
                Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => return,
                Ok(Msg::Event(())) => {}
                Err(RecvTimeoutError::Timeout) => {
                    if !self.emitter().is_alive() {
                        return;
                    }
                    if self.retry_at.is_some_and(|at| self.now() >= at) {
                        self.retry_at = None;
                        self.attempt_fetch();
                    }
                    if std::time::Instant::now() >= next_poll {
                        next_poll += Duration::from_secs_f64(POLL_INTERVAL);
                        self.attempt_fetch();
                    }
                }
            }
        }
    }

    fn attempt_fetch(&mut self) {
        if !self.emitter().is_alive() {
            return;
        }
        if let Some(allowed) = self.next_allowed_fetch_at
            && self.now() < allowed
        {
            if self.retry_at.is_none() {
                self.retry_at = Some(allowed);
            }
            return;
        }
        self.retry_at = None;
        match self.deps.endpoint.clone() {
            Endpoint::Invalid => self.emit_unavailable("Test endpoint must use a loopback URL"),
            Endpoint::Test(_) => {
                // An endpoint override never reads credentials or attaches a real token.
                self.identity = AuthProbe::Answered {
                    plan: None,
                    account: None,
                };
                self.fetch(TEST_TOKEN);
            }
            Endpoint::Production => self.read_credential(),
        }
    }

    fn read_credential(&mut self) {
        match (self.deps.credential)() {
            Credential::Missing => {
                // Re-probe because a cached account may outlive logout or account
                // switching. An unreachable CLI is not evidence of logout; a
                // confirmed different account must discard the previous sample.
                let reprobe = (self.deps.identity)();
                if let AuthProbe::Answered { .. } = reprobe {
                    if reprobe.account() != self.identity.account() || reprobe.account().is_none() {
                        self.session_token = None;
                        self.last_good = None;
                    }
                    self.identity = reprobe;
                }
                if self.identity.account().is_some() {
                    self.emit_unavailable(
                        "Credentials file not found (sign in to Claude Code again)",
                    );
                } else {
                    self.emit_unavailable("Not signed in to Claude Code");
                }
            }
            // Not an error: Claude Code renews this the next time it runs.
            Credential::Expired => {
                self.emit_unavailable("Token expired (launch Claude Code to renew)")
            }
            Credential::Unreadable(reason) => self.emit_unavailable(&reason),
            Credential::Malformed => self.emit_unavailable(
                "Credential format not recognised (Claude Code may have changed it)",
            ),
            Credential::Token(token) => {
                if self.session_token.as_deref() != Some(token.as_str()) {
                    let reprobe = (self.deps.identity)();
                    // Tokens rotate within an account; keep its sample only when
                    // the new credential's account can be confirmed as the same one.
                    if reprobe.account().is_none() || reprobe.account() != self.identity.account() {
                        self.last_good = None;
                    }
                    self.session_token = Some(token.clone());
                    self.identity = reprobe;
                } else if self.identity == AuthProbe::Unreachable {
                    self.identity = (self.deps.identity)();
                }
                self.fetch(&token);
            }
        }
    }

    fn fetch(&mut self, token: &str) {
        let Some(url) = self.deps.endpoint.url().map(String::from) else {
            return;
        };
        let user_agent = if self.deps.endpoint == Endpoint::Production {
            self.user_agent
                .get_or_insert_with(|| {
                    format!(
                        "claude-code/{}",
                        (self.deps.version)().unwrap_or_else(|| "0.0.0".into())
                    )
                })
                .clone()
        } else {
            "llm-usage-test".to_string()
        };
        let response = (self.deps.http)(&url, token, &user_agent);
        if !self.emitter().is_alive() {
            return;
        }
        if response.status != 200 {
            self.handle_failure(response.status, response.retry_after.as_deref());
            return;
        }
        let Ok(usage) = serde_json::from_slice::<OAuthUsage>(&response.body) else {
            self.emit_unavailable("Could not read the response");
            return;
        };
        let mut source = normalise(usage);
        if source.state == SourceState::Ok {
            source.last_updated = Some(self.now());
        }
        source.plan = self.identity.plan();
        source.account = self.identity.account();
        if source.state == SourceState::Ok {
            self.last_good = Some(source.clone());
        }
        self.retry_attempt = 0;
        self.next_allowed_fetch_at = None;
        self.retry_at = None;
        self.emitter().source(source);
    }

    fn handle_failure(&mut self, status: u16, retry_after_header: Option<&str>) {
        let mut reason = reason_for(status);
        if status == 429 || status == 0 {
            let delay = retry_after(retry_after_header, self.now())
                .unwrap_or(RETRY_DELAYS[self.retry_attempt.min(RETRY_DELAYS.len() - 1)]);
            self.retry_attempt += 1;
            reason += &format!(" (retry {})", retry_label(delay, self.now()));
            let deadline = add_secs(self.now(), delay);
            self.next_allowed_fetch_at = Some(deadline);
            if self.retry_at.is_none() {
                self.retry_at = Some(deadline);
            }
        }
        self.emit_unavailable(&reason);
    }

    /// Keeps the last confirmed reading visible as stale when a new fetch fails.
    fn emit_unavailable(&self, reason: &str) {
        if let Some(mut previous) = self.last_good.clone() {
            previous.note = Some(reason.to_string());
            previous.state = match previous.last_updated {
                Some(since) => SourceState::Stale { since },
                None => SourceState::Error(reason.to_string()),
            };
            self.emitter().source(previous);
        } else {
            let mut placeholder = UsageSource::placeholder("claude", "Claude Code");
            placeholder.plan = self.identity.plan();
            placeholder.account = self.identity.account();
            placeholder.note = Some(reason.to_string());
            self.emitter().source(placeholder);
        }
    }
}

/// Not `format::resets_in`: a reset is minutes to days away and rounds to
/// "in 0m" for the seconds a retry takes, which reads as "never".
fn retry_label(delay: f64, now: Timestamp) -> String {
    if delay < 60.0 {
        format!("in {}s", delay.round() as i64)
    } else {
        format::resets_in(Some(add_secs(now, delay)), now)
    }
}

fn reason_for(status: u16) -> String {
    match status {
        0 => "Cannot connect".into(),
        401 | 403 => "Token expired (launch Claude Code to renew)".into(),
        429 => "Rate limited".into(),
        _ => format!("Unavailable (HTTP {status})"),
    }
}

// MARK: - Normalisation

fn normalise(usage: OAuthUsage) -> UsageSource {
    let mut source = UsageSource::new("claude", "Claude Code");
    source.stale_after = 900.0;
    source.last_updated = Some(Timestamp::now());
    source.state = SourceState::Ok;

    let mut windows = Vec::new();
    let mut buckets = Vec::new();
    for limit in usage.limits.unwrap_or_default() {
        let Some(percent) = limit.percent else {
            continue;
        };
        let active = limit.is_active == Some(true);
        match limit.kind.as_deref() {
            Some("session") => windows.push(window(
                "claude-5h",
                "5h",
                percent,
                limit.resets_at,
                300,
                active,
            )),
            Some("weekly_all") => windows.push(window(
                "claude-7d",
                "7d",
                percent,
                limit.resets_at,
                10_080,
                active,
            )),
            _ => {
                // weekly_scoped and any future kind: model-specific, shown on expand.
                let name = limit
                    .scope
                    .and_then(|s| s.model)
                    .and_then(|m| m.display_name)
                    .or(limit.kind)
                    .unwrap_or_else(|| "scoped".into());
                buckets.push(UsageBucket {
                    id: format!("claude-{name}"),
                    label: name,
                    used_percent: percent,
                });
            }
        }
    }

    // Fallback for a payload without the normalised array.
    if windows.is_empty() {
        if let Some(w) = usage.five_hour.as_ref().and_then(|w| w.utilization) {
            let reset = usage.five_hour.as_ref().and_then(|w| w.resets_at.clone());
            windows.push(window("claude-5h", "5h", w, reset, 300, false));
        }
        if let Some(w) = usage.seven_day.as_ref().and_then(|w| w.utilization) {
            let reset = usage.seven_day.as_ref().and_then(|w| w.resets_at.clone());
            windows.push(window("claude-7d", "7d", w, reset, 10_080, false));
        }
    }

    if windows.is_empty() {
        let mut placeholder = UsageSource::placeholder("claude", "Claude Code");
        placeholder.note = Some("No limit data returned".into());
        return placeholder;
    }

    // Fixed order (5h then 7d). Sorting by consumption would make the rows swap
    // places as usage moves, which reads as the panel glitching.
    source.windows = windows;
    source.buckets = buckets;
    source.spend = spend_row(usage.spend);
    source
}

fn window(
    id: &str,
    label: &str,
    percent: f64,
    resets_at: Option<String>,
    minutes: i64,
    active: bool,
) -> UsageWindow {
    let mut w = UsageWindow::new(
        id,
        label,
        percent,
        resets_at.as_deref().and_then(parse_timestamp),
        Some(minutes),
    );
    w.is_active = active;
    w
}

fn spend_row(spend: Option<Spend>) -> Option<UsageSpend> {
    let spend = spend.filter(|s| s.enabled == Some(true))?;
    let used = spend.used?;
    let limit = spend.limit?;
    let used_minor = used.amount_minor?;
    let limit_minor = limit.amount_minor.filter(|l| *l > 0.0)?;
    let divisor = 10f64.powi(limit.exponent.unwrap_or(2));
    let currency = limit.currency.unwrap_or_else(|| "USD".into());
    let symbol = if currency == "USD" {
        "$".to_string()
    } else {
        currency
    };
    Some(UsageSpend {
        label: "Credits".into(),
        used_percent: spend.percent.unwrap_or(used_minor / limit_minor * 100.0),
        detail: format!("{symbol}{:.2}", used_minor / divisor),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::mpsc::{Receiver, channel};

    const USAGE: &str = r#"{"limits":[{"kind":"session","percent":25,"resets_at":"2030-01-01T00:00:00.000+00:00","is_active":true},{"kind":"weekly_all","percent":40,"resets_at":"2030-01-05T00:00:00+00:00"},{"kind":"weekly_scoped","percent":12,"scope":{"model":{"display_name":"Fable"}}}],"spend":{"enabled":true,"used":{"amount_minor":7971,"currency":"USD","exponent":2},"limit":{"amount_minor":15000,"currency":"USD","exponent":2}}}"#;

    struct Harness {
        requests: Arc<Mutex<Vec<(String, String)>>>,
        responses: Arc<Mutex<Vec<HttpResponse>>>,
        credential: Arc<Mutex<Credential>>,
        identity: Arc<Mutex<AuthProbe>>,
        credential_reads: Arc<Mutex<usize>>,
    }

    fn ok(body: &str) -> HttpResponse {
        HttpResponse {
            status: 200,
            retry_after: None,
            body: body.as_bytes().to_vec(),
        }
    }

    fn status(code: u16, retry: Option<&str>) -> HttpResponse {
        HttpResponse {
            status: code,
            retry_after: retry.map(String::from),
            body: Vec::new(),
        }
    }

    fn make(
        endpoint: Endpoint,
        responses: Vec<HttpResponse>,
    ) -> (ClaudeProvider, Harness, Receiver<UsageSource>) {
        let harness = Harness {
            requests: Arc::default(),
            responses: Arc::new(Mutex::new(responses)),
            credential: Arc::new(Mutex::new(Credential::Token("token-1".into()))),
            identity: Arc::new(Mutex::new(AuthProbe::Answered {
                plan: Some("Pro".into()),
                account: Some("first@example.test".into()),
            })),
            credential_reads: Arc::default(),
        };
        let (requests, responses) = (harness.requests.clone(), harness.responses.clone());
        let (credential, identity, reads) = (
            harness.credential.clone(),
            harness.identity.clone(),
            harness.credential_reads.clone(),
        );
        let deps = Deps {
            endpoint,
            http: Arc::new(move |_url, token, ua| {
                requests
                    .lock()
                    .unwrap()
                    .push((token.to_string(), ua.to_string()));
                let mut queue = responses.lock().unwrap();
                if queue.is_empty() {
                    status(0, None)
                } else {
                    queue.remove(0)
                }
            }),
            credential: Arc::new(move || {
                *reads.lock().unwrap() += 1;
                credential.lock().unwrap().clone()
            }),
            identity: Arc::new(move || identity.lock().unwrap().clone()),
            version: Arc::new(|| Some("9.9.9".into())),
            now: Arc::new(Timestamp::now),
        };
        let (tx, rx) = channel();
        let tx = Mutex::new(tx);
        let provider = ClaudeProvider::new(
            deps,
            Arc::new(move |result| {
                let _ = tx.lock().unwrap().send(result.expect("claude never fails"));
            }),
        );
        (provider, harness, rx)
    }

    fn next(rx: &Receiver<UsageSource>) -> UsageSource {
        rx.recv_timeout(Duration::from_secs(3)).expect("an update")
    }

    #[test]
    fn normalises_windows_buckets_and_spend() {
        let (provider, harness, rx) = make(Endpoint::Production, vec![ok(USAGE)]);
        provider.start();
        let source = next(&rx);
        provider.stop();
        assert_eq!(source.state, SourceState::Ok);
        assert_eq!(
            source
                .windows
                .iter()
                .map(|w| w.label.as_str())
                .collect::<Vec<_>>(),
            ["5h", "7d"]
        );
        assert!(source.windows[0].is_active && !source.windows[1].is_active);
        assert_eq!(source.buckets[0].label, "Fable");
        let spend = source.spend.unwrap();
        assert_eq!(spend.detail, "$79.71");
        assert!((spend.used_percent - 53.14).abs() < 0.01);
        assert_eq!(source.plan.as_deref(), Some("Pro"));
        assert_eq!(source.account.as_deref(), Some("first@example.test"));
        assert_eq!(
            harness.requests.lock().unwrap()[0],
            ("token-1".to_string(), "claude-code/9.9.9".to_string())
        );
    }

    #[test]
    fn retry_after_blocks_manual_refresh_until_deadline() {
        let (provider, harness, rx) = make(
            Endpoint::Production,
            vec![status(429, Some("120")), ok(USAGE)],
        );
        provider.start();
        let limited = next(&rx);
        assert_eq!(limited.note.as_deref(), Some("Rate limited (retry in 2m)"));
        provider.refresh();
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(harness.requests.lock().unwrap().len(), 1);
        assert!(rx.try_recv().is_err());
        provider.stop();
    }

    #[test]
    fn rate_limit_reason_names_the_retry() {
        let (provider, _harness, rx) = make(Endpoint::Production, vec![status(429, Some("30"))]);
        provider.start();
        assert_eq!(
            next(&rx).note.as_deref(),
            Some("Rate limited (retry in 30s)")
        );
        provider.stop();
    }

    #[test]
    fn failure_preserves_sample_timestamp_but_is_not_healthy() {
        let (provider, _harness, rx) =
            make(Endpoint::Production, vec![ok(USAGE), status(500, None)]);
        provider.start();
        let first = next(&rx);
        provider.refresh();
        let failed = next(&rx);
        provider.stop();
        assert_eq!(failed.last_updated, first.last_updated);
        assert_eq!(failed.windows[0].used_percent, 25.0);
        assert_eq!(
            failed.state,
            SourceState::Stale {
                since: first.last_updated.unwrap()
            }
        );
        assert_eq!(failed.note.as_deref(), Some("Unavailable (HTTP 500)"));
    }

    #[test]
    fn new_credential_with_changed_account_discards_previous_sample() {
        let (provider, harness, rx) =
            make(Endpoint::Production, vec![ok(USAGE), status(500, None)]);
        provider.start();
        next(&rx);
        *harness.credential.lock().unwrap() = Credential::Token("token-2".into());
        *harness.identity.lock().unwrap() = AuthProbe::Answered {
            plan: Some("Max".into()),
            account: Some("second@example.test".into()),
        };
        provider.refresh();
        let failed = next(&rx);
        provider.stop();
        assert_eq!(failed.account.as_deref(), Some("second@example.test"));
        assert_eq!(failed.plan.as_deref(), Some("Max"));
        assert!(failed.windows.is_empty());
        assert_eq!(failed.last_updated, None);
        assert_eq!(failed.state, SourceState::Unconfigured);
    }

    #[test]
    fn same_account_token_refresh_preserves_last_good() {
        let (provider, harness, rx) =
            make(Endpoint::Production, vec![ok(USAGE), status(500, None)]);
        provider.start();
        let first = next(&rx);
        *harness.credential.lock().unwrap() = Credential::Token("token-2".into());
        provider.refresh();
        let failed = next(&rx);
        provider.stop();
        assert_eq!(failed.account.as_deref(), Some("first@example.test"));
        assert_eq!(
            failed.state,
            SourceState::Stale {
                since: first.last_updated.unwrap()
            }
        );
        assert_eq!(harness.requests.lock().unwrap()[1].0, "token-2");
    }

    #[test]
    fn logout_clears_cached_identity_and_last_good() {
        let (provider, harness, rx) = make(Endpoint::Production, vec![ok(USAGE)]);
        provider.start();
        next(&rx);
        *harness.credential.lock().unwrap() = Credential::Missing;
        *harness.identity.lock().unwrap() = AuthProbe::Answered {
            plan: None,
            account: None,
        };
        provider.refresh();
        let out = next(&rx);
        provider.stop();
        assert_eq!(out.account, None);
        assert!(out.windows.is_empty());
        assert_eq!(out.state, SourceState::Unconfigured);
        assert_eq!(out.note.as_deref(), Some("Not signed in to Claude Code"));
        assert_eq!(harness.requests.lock().unwrap().len(), 1);
    }

    #[test]
    fn stop_prevents_late_callbacks_and_restart_fetches_again() {
        let (provider, harness, rx) = make(Endpoint::Production, vec![ok(USAGE), ok(USAGE)]);
        provider.start();
        provider.start();
        next(&rx);
        provider.stop();
        provider.refresh();
        std::thread::sleep(Duration::from_millis(50));
        assert!(rx.try_recv().is_err());
        provider.start();
        assert_eq!(next(&rx).state, SourceState::Ok);
        provider.stop();
        assert_eq!(harness.requests.lock().unwrap().len(), 2);
    }

    #[test]
    fn endpoint_override_uses_only_the_mock_credential() {
        let (provider, harness, rx) = make(
            Endpoint::configured(Some("http://127.0.0.1:8080/usage")),
            vec![ok(USAGE)],
        );
        provider.start();
        let source = next(&rx);
        provider.stop();
        assert_eq!(source.state, SourceState::Ok);
        assert_eq!(harness.requests.lock().unwrap()[0].0, TEST_TOKEN);
        assert_eq!(*harness.credential_reads.lock().unwrap(), 0);
        assert_eq!(source.account, None);
    }

    #[test]
    fn external_endpoint_override_is_rejected_before_reading_credentials() {
        for url in [
            "https://example.com/usage",
            "http://user:pw@localhost/x",
            "file:///etc/passwd",
            "http://localhost.evil.test/",
        ] {
            assert_eq!(Endpoint::configured(Some(url)), Endpoint::Invalid, "{url}");
        }
        assert!(matches!(
            Endpoint::configured(Some("http://[::1]:9/u")),
            Endpoint::Test(_)
        ));
        assert!(matches!(
            Endpoint::configured(Some("https://LOCALHOST/u")),
            Endpoint::Test(_)
        ));
        let (provider, harness, rx) = make(Endpoint::Invalid, vec![]);
        provider.start();
        assert_eq!(
            next(&rx).note.as_deref(),
            Some("Test endpoint must use a loopback URL")
        );
        provider.stop();
        assert_eq!(*harness.credential_reads.lock().unwrap(), 0);
        assert!(harness.requests.lock().unwrap().is_empty());
    }

    #[test]
    fn parse_reads_the_claude_code_credentials_shape() {
        let now = Timestamp::from_second(1_800_000_000).unwrap();
        let future = r#"{"claudeAiOauth":{"accessToken":"abc","expiresAt":1900000000000}}"#;
        let past = r#"{"claudeAiOauth":{"accessToken":"abc","expiresAt":1700000000000}}"#;
        assert_eq!(
            parse_credential(future, now),
            Credential::Token("abc".into())
        );
        assert_eq!(parse_credential(past, now), Credential::Expired);
        assert_eq!(
            parse_credential(r#"{"accessToken":"abc"}"#, now),
            Credential::Malformed
        );
        assert_eq!(
            parse_credential(r#"{"claudeAiOauth":{"accessToken":""}}"#, now),
            Credential::Malformed
        );
        assert_eq!(parse_credential("not json", now), Credential::Malformed);
    }

    #[test]
    fn retry_after_accepts_seconds_and_http_dates() {
        let now = Timestamp::from_second(1_800_000_000).unwrap();
        let dated = add_secs(now, 600.0)
            .strftime("%a, %d %b %Y %H:%M:%S GMT")
            .to_string();
        assert_eq!(retry_after(Some(&dated), now), Some(600.0));
        assert_eq!(retry_after(Some("45"), now), Some(45.0));
        assert_eq!(retry_after(Some("0"), now), Some(1.0));
        assert_eq!(retry_after(Some("inf"), now), None);
        assert_eq!(retry_after(Some("soon"), now), None);
        assert_eq!(retry_after(None, now), None);
    }

    #[test]
    fn auth_status_labels_only_a_claude_ai_login() {
        let dir = std::env::temp_dir().join(format!("llm-usage-auth-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("claude");
        let cases = [
            (
                r#"{"authMethod":"claude.ai","email":"a@example.test","subscriptionType":"max"}"#,
                0,
                Some("a@example.test"),
                Some("Max"),
            ),
            (
                r#"{"authMethod":"api_key","email":"a@example.test","subscriptionType":"max"}"#,
                0,
                None,
                None,
            ),
            (
                r#"{"email":"old@example.test","subscriptionType":"pro"}"#,
                0,
                Some("old@example.test"),
                Some("Pro"),
            ),
            (r#"{"loggedIn":false}"#, 1, None, None),
        ];
        for (json, code, account, plan) in cases {
            std::fs::write(
                &script,
                format!("#!/bin/sh\nprintf '%s' '{json}'\nexit {code}\n"),
            )
            .unwrap();
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
            let probe = auth_status(script.to_str().unwrap(), None);
            assert_eq!(probe.account().as_deref(), account, "{json}");
            assert_eq!(probe.plan().as_deref(), plan, "{json}");
            assert!(matches!(probe, AuthProbe::Answered { .. }));
        }
        std::fs::write(&script, "#!/bin/sh\nprintf 'not json'\n").unwrap();
        assert_eq!(
            auth_status(script.to_str().unwrap(), None),
            AuthProbe::Unreachable
        );
        std::fs::write(&script, "#!/bin/sh\nprintf '{}'\nexit 2\n").unwrap();
        assert_eq!(
            auth_status(script.to_str().unwrap(), None),
            AuthProbe::Unreachable
        );
        let _ = std::fs::remove_dir_all(dir);
    }
}
