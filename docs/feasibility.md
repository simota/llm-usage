# Feasibility study: AI CLI usage menu-bar app

**Date**: 2026-07-30
**Scope**: A native macOS menu-bar app that displays the usage (limits) of Claude Code / Codex CLI / Antigravity CLI (agy)
**Verdict**: **Feasible (GO)**

CLI versions at the time of investigation:

| CLI | Version | Path |
|---|---|---|
| Claude Code | 2.1.220 | `~/.local/bin/claude` |
| Codex CLI | 0.146.0 | `/opt/homebrew/bin/codex` |
| agy (Antigravity CLI) | 1.1.8 | `~/.local/bin/agy` |

---

## Summary

Difficulty ranks as **Codex (official API) < agy (no auth required, session-scoped) < Claude Code (unofficial, token-dependent)**.
**A real response was captured from all 3 sources.** GO overall.

| Source | Tier | Access path | Officialness | Evidence |
|---|---|---|---|---|
| Codex | A | `codex app-server` JSON-RPC `account/rateLimits/read` | Official (schema can be generated) | **Real response captured** |
| Claude Code | B | **OAuth usage endpoint** (adopted) / statusline hook (rejected) | Unofficial (an official API is not planned) | **Real response captured** |
| agy | B | `RetrieveUserQuotaSummary` on the **local language server** (no auth required) | Internal protocol, but confined to localhost | **Real response captured** |

> agy was initially assumed to need the internal `cloudcode-pa.googleapis.com` API (Tier C, OAuth required), but
> measurement showed that **the local language server agy itself starts serves the same data without auth**,
> so it was promoted to Tier B. See §3 for details and for why the Tier C path was abandoned.

---

## 1. Codex — Tier A (captured)

### Path: app-server JSON-RPC

Start `codex app-server` over stdio and call `account/rateLimits/read` (no params) with newline-delimited JSON-RPC.

The response actually captured:

```json
{
  "id": 2,
  "result": {
    "rateLimits": {
      "limitId": "codex",
      "limitName": null,
      "primary": { "usedPercent": 54, "windowDurationMins": 10080, "resetsAt": 1785902965 },
      "secondary": null,
      "credits": { "hasCredits": false, "unlimited": false, "balance": "0" },
      "individualLimit": null,
      "spendControlReached": false,
      "planType": "pro",
      "rateLimitReachedType": null
    },
    "rateLimitsByLimitId": {
      "codex": { "...": "same as above" },
      "codex_bengalfox": {
        "limitName": "GPT-5.3-Codex-Spark",
        "primary": { "usedPercent": 0, "windowDurationMins": 10080, "resetsAt": 1786001695 },
        "planType": "pro"
      }
    },
    "rateLimitResetCredits": { "...": "..." }
  }
}
```

Reproduction (two requests: `initialize` → `account/rateLimits/read`):

```python
import json, subprocess, time
p = subprocess.Popen(["codex", "app-server"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True, bufsize=1)
def send(o): p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"clientInfo": {"name": "llm-usage", "title": "llm-usage", "version": "0.0.1"}}})
send({"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": None})

while True:
    m = json.loads(p.stdout.readline())
    if m.get("id") == 2:
        print(json.dumps(m, indent=2)); break
```

### What it gives us

- **`rateLimitResetCredits`** carries the free "Full reset" grants: `availableCount` plus each credit's
  `status` / `expiresAt` / `title`. **They expire, and they are the most actionable thing to know when a limit is tight**
  (`account/rateLimitResetCredit/consume` exists for spending them, but this app only displays)
- **Every entry in `rateLimitsByLimitId` is an independent window.** `GPT-5.3-Codex-Spark`
  (`codex_bengalfox`) has its own `resetsAt` and `windowDurationMins`, separate from the main limit.
  Collapsing it into a percent-only bucket loses the reset time and hides it at 0%, so treat it as a window.
  The display name is the last element of `limitName` (`GPT-5.3-Codex-Spark` → `Spark`) — the full string does not fit the label column
- **An `account/rateLimits/updated` push notification** exists, so a resident process can update passively with no polling
- `account/read` → `{"account":{"type":"chatgpt","email":"…","planType":"pro"}}` gives the account
- `account/usage/read` returns **statistics, not limits** (`lifetimeTokens` / `peakDailyTokens` /
  `currentStreakDays` / daily token buckets). Out of scope for this app
- `account/workspaceMessages/read` is empty, with `featureEnabled: false`
- Related methods: `account/usage/read` (token usage: `AccountTokenUsageSummary` / `AccountTokenUsageDailyBucket`), `account/read`, `account/rateLimitResetCredit/consume`
- **The schema can be machine-generated officially**, so keeping up with CLI updates can be automated:

  ```sh
  codex app-server generate-json-schema --out ./schema   # JSON Schema
  codex app-server generate-ts --out ./types             # TypeScript type definitions
  ```

  `ClientRequest.ts` enumerates every method name in a union, so breaking changes are detectable in CI.

### Fallback (offline)

The same values survive in the `token_count` events of `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`:

```json
"rate_limits":{"limit_id":"codex","primary":{"used_percent":54.0,"window_minutes":10080,
"resets_at":1785902965},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},
"plan_type":"pro"}
```

(snake_case here; camelCase via app-server. Same values.)

### Caveats

- On startup app-server initializes sqlite state under `~/.codex`. In a non-writable environment it exits
  immediately with `failed to initialize sqlite state runtime under ~/.codex` (confirmed under a sandbox)
- `WARNING: proceeding, even though we could not create PATH aliases` appears on stderr but is harmless. Parse stdout only

---

## 2. Claude Code — Tier B (captured)

### Path: OAuth usage endpoint

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <OAuth access token>
User-Agent: claude-code/<version>
```

The response actually captured (excerpted, formatted):

```json
{
  "five_hour": { "utilization": 8.0,  "resets_at": "2026-07-30T12:40:00.981771+00:00" },
  "seven_day": { "utilization": 43.0, "resets_at": "2026-08-01T09:00:00.981794+00:00" },
  "limits": [
    { "kind": "session",       "group": "session", "percent": 8,  "severity": "normal",
      "resets_at": "…", "scope": null, "is_active": false },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 43, "severity": "normal",
      "resets_at": "…", "scope": null, "is_active": true },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 11, "severity": "normal",
      "resets_at": "…", "scope": { "model": { "display_name": "Fable" } }, "is_active": false }
  ],
  "spend": {
    "used":  { "amount_minor": 7971,  "currency": "USD", "exponent": 2 },
    "limit": { "amount_minor": 15000, "currency": "USD", "exponent": 2 },
    "percent": 53, "severity": "normal", "enabled": true
  },
  "extra_usage": { "is_enabled": true, "monthly_limit": 15000, "used_credits": 7971.0,
                   "utilization": 53.14, "currency": "USD", "decimal_places": 2 },
  "seven_day_opus": null, "seven_day_sonnet": null, "…": null
}
```

- **Use the `limits` array.** It is already normalized into `kind` / `percent` / `severity` / `resets_at` / `scope` / `is_active`,
  and per-model allowances keep being added as `weekly_scoped`. Keep the flat `five_hour` /
  `seven_day` as a backward-compatible fallback
- `resets_at` is **RFC3339 (fractional seconds plus a `+00:00` offset)**. `withFractionalSeconds` is required
- `spend` gives extra credits (currency amount is `amount_minor` / 10^`exponent`)
- The many `seven_day_*` and codename-looking fields are all `null` today
- **The `User-Agent: claude-code/<version>` header is mandatory.** Without it you land in a harshly rate-limited
  bucket and get a permanent 429 ([#31637](https://github.com/anthropics/claude-code/issues/31637))
- With the correct UA, 180-second intervals are reported to be safe. This implementation uses 300
- **Unofficial.** The request for an official API, [#45392](https://github.com/anthropics/claude-code/issues/45392), is closed as *not planned*

### Auth and its constraints

- The token is a generic password in the macOS Keychain under the service name `Claude Code-credentials`.
  It is `claudeAiOauth.accessToken` in the JSON; expiry is `claudeAiOauth.expiresAt` (**milliseconds**)
- A native app can read it with `SecItemCopyMatching` (**a user-permission dialog appears the first time**)
- The plan name and the logged-in account come from `subscriptionType` (e.g. `max`)
  and `email` in `claude auth status --json`

> **The access token lives about an hour, and only Claude Code itself renews it.**
> Do not refresh it from here — the refresh token is rotated server-side, and unless the new value is written
> back to the Keychain this **breaks the user's Claude Code login**.
> So stay read-only: show stale on expiry and re-read the Keychain every time
> (picking up whatever Claude Code refreshed on its next run).
> If Claude Code has not run for over an hour, the values go stale.

### Rejected: statusline hook

The stdin JSON given to a statusline command includes `rate_limits.five_hour` / `.seven_day`, and it is
documented [officially](https://code.claude.com/docs/en/statusline). But it
**requires rewriting the user's `statusline.sh`**, and it only updates while Claude Code is running.
The OAuth path needs no config change and works even when Claude Code is not running (as long as the token is
alive), so that is what we adopted.

### Paths ruled out by investigation

- The `claude` CLI has no usage subcommand (only `agents` / `auth` / `doctor` / `mcp` / `plugin` /
  `project` / `setup-token` / `ultrareview` / `update` / `gateway` / `install` / `auto-mode`)
- The transcripts in `~/.claude/projects/**/*.jsonl` contain no rate limit information (only per-message
  `usage` token counts)
- There is no local cache file for limits anywhere under `~/.claude/`
  (`stats-cache.json` holds session statistics only, no limits)

### Recommendation

The OAuth path only. It needs no config change and does not depend on whether Claude Code is running.

---

## 3. agy (Antigravity CLI) — Tier B (captured)

### Path: local language server (no auth required)

On startup agy brings up a **language server process on localhost**. That language server exposes
`RetrieveUserQuotaSummary` over Connect (JSON over HTTP) and returns quotas **with no auth header**.
Since agy is already authenticated, this app never has to deal with OAuth at all.

```
POST http://localhost:<httpPort>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
Content-Type: application/json
Connect-Protocol-Version: 1

{}
```

The response actually captured (formatted):

```json
{
  "response": {
    "groups": [
      {
        "displayName": "Gemini Models",
        "description": "Models within this group: Gemini Flash, Gemini Pro",
        "buckets": [
          { "bucketId": "gemini-weekly", "displayName": "Weekly Limit", "window": "weekly",
            "remainingFraction": 0.87022984, "resetTime": "2026-08-04T23:18:05Z",
            "description": "You have used some of your weekly limit, it will fully refresh in 5 days, 15 hours." },
          { "bucketId": "gemini-5h", "displayName": "Five Hour Limit", "window": "5h",
            "remainingFraction": 0.6951365, "resetTime": "2026-07-30T09:00:31Z",
            "description": "You have used some of your 5-hour limit, it will fully refresh in 1 hour, 4 minutes." }
        ]
      },
      {
        "displayName": "Claude and GPT models",
        "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
        "buckets": [
          { "bucketId": "3p-weekly", "displayName": "Weekly Limit", "window": "weekly",
            "remainingFraction": 1, "resetTime": "2026-08-06T07:55:32Z" },
          { "bucketId": "3p-5h", "displayName": "Five Hour Limit", "window": "5h",
            "remainingFraction": 1, "resetTime": "2026-07-30T12:55:32Z" }
        ]
      }
    ],
    "description": "Within each group, models share a weekly limit and a 5-hour limit. …"
  }
}
```

### How the data is shaped (differs from the other 2 sources)

| Item | agy | Codex / Claude Code |
|---|---|---|
| Direction of the measure | **`remainingFraction` (remaining, 0.0–1.0)** | `usedPercent` / `used_percentage` (consumed) |
| Reset time | **RFC3339 string** (`2026-08-04T23:18:05Z`) | Unix epoch seconds |
| Window length | **explicit in `window`: `"weekly"` / `"5h"`** | `windowDurationMins` / implicit 5h and 7d |
| Granularity | **model group × window** = 4 buckets | tool × window (+ per-model buckets) |

Normalization:

```
usedPercent = (1 - remainingFraction) * 100
resetsAt    = ISO8601 → epoch seconds
windowMins  = {"5h": 300, "weekly": 10080}[window]
```

- **Per model group, not per model.** Two groups: `Gemini Models` (Flash and Pro shared) and
  `Claude and GPT models` (Claude Opus / Sonnet / GPT-OSS shared)
- Because `window` is explicit, **the pace tick (`design.md` §4) can be computed for agy too**
- `description` carries human-readable text like "fully refresh in 5 days, 15 hours", usable verbatim as a tooltip
- The group-level `description` enumerates which models belong to it

### Plan name — `GetUserStatus`

Fetched from another method on the same language server.

```
POST http://localhost:<httpPort>/exa.language_server_pb.LanguageServerService/GetUserStatus
```

```json
{"userStatus":{
  "name":"…","email":"…",
  "userTier":{"id":"g1-ultra-lite-tier","name":"Google AI Ultra",
              "description":"Google AI Ultra",
              "upgradeSubscriptionUri":"https://antigravity.google/g1-upgrade",
              "availableCredits":[{"creditType":"GOOGLE_ONE_AI","minimumCreditAmountForUsage":"50"}]},
  "planStatus":{
    "planInfo":{"teamsTier":"TEAMS_TIER_PRO","planName":"Pro",
                "monthlyPromptCredits":50000,"monthlyFlowCredits":150000, "…":"…"},
    "availablePromptCredits":500,"availableFlowCredits":100}}}
```

- **Use `userTier.name` (`"Google AI Ultra"`) for the plan badge.** The account is `email` in the same response
- **Do not use `planStatus.planInfo.planName`.** That is the **per-seat pricing tier** inherited from the
  Antigravity / Windsurf lineage, on a different axis from the Google subscription. Even a Google AI Ultra
  subscriber gets `"Pro"` (`TEAMS_TIER_PRO`), which makes the plan look lower than it is.
  If `userTier` is missing, show no badge — a blank badge beats a wrong one
- **Do not use `cascadeModelConfigData.clientModelConfigs[].quotaInfo`.**
  It looks per-model, but it is really a duplicate of the owning group's values (all 11 Gemini models share one
  `remainingFraction`; the Claude/GPT ones are all 1). It adds nothing over
  `RetrieveUserQuotaSummary`
- **The meaning of `availablePromptCredits` / `availableFlowCredits` is undetermined.**
  If `500 / 50000` were monthly remaining it would mean 99% consumed, which contradicts the quota gauges showing 4% consumed.
  Most likely it is the balance of purchased flex credits, but that is unconfirmed, so do not turn it into a gauge

### Discovering the port

The language server uses **a random port per session**. The port is recorded in the log:

```
server.go:560] Language server listening on random port at 50449 for HTTPS (gRPC)
server.go:568] Language server listening on random port at 50450 for HTTP
```

- Log: `~/.gemini/antigravity-cli/log/cli-<YYYYMMDD_HHMMSS>.log`
- `~/.gemini/antigravity-cli/cli.log` is a symlink to the newest log
- Extract the HTTP port (the one Connect/JSON speaks) with `listening on random port at (\d+) for HTTP`

### Constraints

- **Only available while agy is running.** The port closes when it exits (confirmed by measurement)
  → the same nature as Claude Code's statusline path. Apply the stale design in `design.md` §6 as-is
- The quota is **shared** across the Antigravity desktop app, CLI, and SDK (the UI needs to note this)
- `exa.language_server_pb` is an internal protocol with no backward-compatibility guarantee. But the traffic is
  **confined to localhost**, with no credentials and nothing leaving the machine, so the risk is breakage, not leakage

### Abandoned paths and why

**① The `v1internal` internal API on `cloudcode-pa.googleapis.com` (the original Tier C assumption)**

Binary analysis got this far before hitting a dead end at auth:

- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`
- The request has a single `project` field (`RetrieveUserQuotaSummaryRequest.GetProject`).
  In the log `quotaProject=` is empty and the backend project ID is `default-cli-project`
- The Business plan uses `businessaicode.googleapis.com/locations.fetchQuotaStatus`

What the dead end consists of:

- `~/.gemini/oauth_creds.json` is **a different artifact, from Gemini CLI** (its mtime does not match actual agy use).
  Neither of the two OAuth clients embedded in the binary issued that refresh_token
  (the correct client_id / secret pair returns `unauthorized_client`, and a mismatched pair returns `invalid_client`,
  which confirms the pairing itself is right)
- Where agy's own credentials live has not been identified

Since the local language server returns the same data with no auth, **this path is not worth chasing**.

**② An on-disk quota cache**

The [official documentation](https://antigravity.google/docs/cli/commands/usage) says `/usage` performs
"a fresh check of your quotas on disk and from the backend service", but
**measurement disproved this**. Running `/usage` left `~/.gemini/antigravity-cli/cache/` completely untouched
(the newest cache entry was 12:14 against a 16:55 session), and no other file holding quotas was found.

The backend fetch itself is visible in the log:

```
quota_manager.go:44] doRefreshQuota: starting reload (force=true)
quota_manager.go:40] doRefreshQuota: skipped (throttled)
```

Note that `throttled` implies the language server also caps polling frequency.

---

## Implementation approach (native)

**Swift 6 + SwiftUI `MenuBarExtra`** (macOS 13+), an accessory app with `LSUIElement = true`.

| Source | How it is fetched | Update trigger |
|---|---|---|
| Codex | resident child process + newline-delimited JSON-RPC over `Process`/`Pipe` | `account/rateLimits/updated` push |
| Claude Code | token from the Keychain → `URLSession` to `/api/oauth/usage` | 300 s (180 s minimum) |
| agy | detect the HTTP port from the log → `URLSession` to the localhost Connect endpoint | around 300 s (the server throttles) |

Considerations:

- Keychain access means working out entitlements and signing (a local build with ad-hoc signing is fine for personal use).
  **Only Claude Code's OAuth path needs it** — agy turned out to need no auth
- Each source can fail independently → design so the others keep displaying when one goes down
- Always stamp every value with its fetch time so staleness is distinguishable in the UI
- agy's port changes every session. Watch the `cli.log` symlink and, on a failed connection,
  re-read the log to pick up the port again (following server restarts)

---

## Key risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Claude and agy depend on unofficial interfaces → breakage on CLI updates | Detect CLI versions + graceful degradation. For Codex, detect diffs in the generated schema in CI |
| 2 | 429 from the Claude OAuth endpoint | `User-Agent: claude-code/<version>` mandatory, 180 s minimum interval, statusline path as the default |
| 3 | Handling secrets (Claude's Keychain token) | Read-only, minimal time in memory, never sent anywhere. **agy is out of scope now that it needs no auth** |
| 4 | **Claude Code token expiry / staleness while agy is not running** | Make the "n minutes ago" display mandatory (`design.md` §6). Never refresh |
| 5 | agy quota shared with other clients | State explicitly in the UI that it is shared |
| 6 | agy's port changes every session | Re-detect each time from `cli.log`, re-fetch on connection failure |

---

## Recommended steps

- **Phase 0 (nearly done)** — pin down the raw data with scripts before writing Swift
  - [x] Codex: `account/rateLimits/read` measured
  - [x] **agy: `RetrieveUserQuotaSummary` on the local language server measured**
        (the originally assumed `v1internal` internal API dead-ended at auth → path changed)
  - [x] **Claude Code: `/api/oauth/usage` measured** (fetched with the Keychain token)
  - [x] ~~statusline path~~ — unnecessary once the OAuth path was adopted
- **Phase 1** — `MenuBarExtra` skeleton + Codex only (get something working on the one source we trust) ✅
- **Phase 2** — Claude Code support ✅ (OAuth path; the statusline hook is rejected)
- **Phase 3** — agy support ✅ (verified against a real language server)

> Phase 0 is done. Real data was captured from all 3 sources.

---

## References

- [Claude Code — Customize your status line](https://code.claude.com/docs/en/statusline)
- [anthropics/claude-code #45392 — API access to usage limits](https://github.com/anthropics/claude-code/issues/45392) (closed as not planned)
- [anthropics/claude-code #31637 — OAuth usage endpoint aggressively rate limits](https://github.com/anthropics/claude-code/issues/31637)
- [Google Antigravity Docs — Model Quotas (/usage)](https://antigravity.google/docs/cli/commands/usage)
- [OpenAI Codex — Pricing and limits](https://developers.openai.com/codex/pricing)
