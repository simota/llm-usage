# Changelog

Notable changes, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the version numbers
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Tagging is the release process (README § Release). When cutting a version,
rename `Unreleased` to that version with its date and open a fresh `Unreleased`
above it — the tag is what publishes the zip, so the heading and the tag must
agree.

## [Unreleased]

### Fixed

- **macOS asked for keychain access again after every rebuild and every
  upgrade.** The token was read in-process with `SecItemCopyMatching`, which
  makes this app the accessing application — and the item's ACL names the
  applications it trusts by path and cdhash. The bundle is ad-hoc signed, so
  every build is a different application as far as the Keychain is concerned and
  starts out denied, prompting until it is approved again; on a machine where the
  app is rebuilt or upgraded regularly, "once, the first time" was in practice
  every few days. The read now runs `/usr/bin/security find-generic-password`,
  which is how Claude Code writes the item in the first place
  (`add-generic-password -U -a <user> -s "Claude Code-credentials"`): that binary
  is already on the item's trusted-application list, and being Apple-signed its
  identity never changes, so the read is authorised however often this app is
  rebuilt. Nothing new is granted — the ACL entry is Claude Code's own, only
  exercised and never modified — and the token still travels on a pipe rather
  than in an argument list. Failures still name what happened: `security` reports
  the Keychain OSStatus as an exit code truncated to a byte, and the four
  reachable ones — item absent, login keychain locked, access denied, prompt
  dismissed — are tabulated back to their status, so the note and the number in
  it mean what they did; a code with no status behind it is reported as the exit
  code it is rather than dressed up as an OSStatus that matches no documented
  constant. The wait on the child is bounded at ten seconds, because it runs on
  the serial queue that also owns the poll timer: a read left hanging on a dialog
  nobody answered would otherwise hold that queue for the rest of the session and
  freeze the card on its last value without saying why.

## [0.2.1] - 2026-07-31

### Fixed

- **The Claude Code card could say "Not signed in" right next to a known plan
  and account.** The Keychain read and the `claude auth status` call are two
  independent sources, and only the first fed the note line: any failure to
  read the Keychain item — item genuinely absent, access refused, or an
  unrecognised JSON shape — collapsed into the same "not signed in" message,
  even when `auth status` had just confirmed an account. On this machine the
  cause was the release bundle's ad-hoc signature changing cdhash on every
  rebuild, which invalidates the Keychain item's per-build access grant, so
  every fresh build starts out denied until the user re-approves it at the
  macOS prompt — the item was present and enumerable the whole time, not
  missing. The two sources are reconciled first: if the Keychain ever claims
  the item is absent while `auth status` reports an account, that combination
  is treated as a denied read rather than a real sign-out, checked against a
  fresh `auth status` call rather than a cached one so a genuine `claude
  logout` afterward still reads correctly. Short of that contradiction, the
  card distinguishes three failure modes on their own terms: absent stays
  "Not signed in to Claude Code," a denied read names the OSStatus and points
  at approving access (or unlocking the login keychain, when that's the
  actual block), and an unrecognised credential shape says so instead of
  pretending to be a sign-out. A failed `auth status` probe — the unresolved
  binary and bare-PATH failure this app has hit before — no longer reads as a
  sign-out either; only a probe that actually got an answer of "no account"
  does.
- The Claude provider's refresh now runs on the provider's own queue whichever
  thread asks for it. The panel's Refresh calls it from the main thread while
  the poll timer calls it from that queue, and the reconciliation above is the
  first thing on the path to *write* shared state rather than only read it —
  the same state the fetch completion already owned. It also gets the Keychain
  read off the main thread: that call blocks until the access prompt is
  answered, so a build the Keychain does not yet trust used to freeze the UI
  thread for as long as the dialog went unanswered.

## [0.2.0] - 2026-07-31

### Added

- **Severity you can see without colour.** Every level now carries an SF Symbol
  silhouette, with the tint as reinforcement rather than the only signal, so
  caution and critical are distinguishable to colour-blind users and are spoken
  by VoiceOver. The pace marker becomes a triangle above the track — hollow on
  pace, filled when not — so the 0–10% over-pace band, which carries no caption,
  still shows something.
- **Accessibility across the panel.** Each information-bearing row is an
  accessibility element with a label and a spoken value, including the over-pace
  state. Refresh is a real bordered button with a Cmd-R equivalent, a failed
  source gains a Retry, and the disclosure toggle has a hit target you can
  actually hit.
- **A legend behind "?"** in the footer, expanding to explain the marks and
  costing no height until asked for.
- Typography moves to semantic text styles, so the panel finally tracks the
  system text size; `monospacedDigit` is preserved on every numeric column.

### Fixed

- **The menu bar could not show a pace warning.** It switched to the loud figure
  only when the highest *used* percentage crossed 80, so a source burning through
  its window at nearly twice the sustainable rate sat at 56% used and never
  qualified — the pace warning, which is the point of the app, could not reach the
  one surface that is always visible. The gate now reads the binding window's
  projected consumption, the same figure the panel's headline is ranked by.
  Thresholds are unchanged at 80/75. Consequence, accepted deliberately:
  projection is amplified early in a window, so the gate fires more readily than
  the old rule did and the item stays quiet less often.
- **The summary line could contradict the cards beneath it.** It reported on the
  window that runs out soonest rather than the worst one on screen, and so could
  announce "All healthy" directly above an 87% card. Ranking is now by displayed
  severity first, with the projection as the tie-break.
- The `.tertiary` text tier is gone — at 1.83:1 it was the worst contrast in the
  panel, and nothing needed to be that quiet.

### Known limitations

- In light mode the yellow and orange severity symbols fail WCAG contrast; fixing
  it needs a custom tint rather than the system palette.
- Still no automated test suite. The offscreen panel renders now cover the stale,
  error, unconfigured and all-severity states that had never been drawn, and are
  the only regression evidence the project has.

## [0.1.2] - 2026-07-30

### Fixed

- **"Rate limited" was a dead end on the Claude Code card.** The OAuth usage
  endpoint throttles aggressively — restarting the app or running two copies is
  enough to earn a 429 — and a failure on the first fetch after launch has no
  earlier reading to fall back on, so the card showed the plan, the account and
  nothing else for a full five-minute poll. A 429 or a failed connection now
  retries with backoff (30s, 60s, 120s, 300s), honours the server's `Retry-After`
  when it sends one, and the card says when it will try again: "Rate limited
  (retry in 30s)".

### Added

- `LLM_USAGE_CLAUDE_ENDPOINT` overrides the usage endpoint, the way
  `LLM_USAGE_AGY_PORT` already overrides agy's, so the throttle-and-recover path
  can be exercised against a stub instead of shipped untested.

## [0.1.1] - 2026-07-30

### Fixed

- **Codex never appeared in the Homebrew build.** launchd and Finder hand a
  bundle `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so spawning `codex app-server`
  through `env` found nothing and the card sat empty with no explanation — while
  the same build worked from a terminal. Tools are now resolved against the usual
  install prefixes, falling back to the login shell's PATH for anything a version
  manager owns, and the child process inherits that PATH so an npm-installed CLI
  can still find `node`. The same lookup feeds `claude`, whose plan and account
  went missing for the same reason.
- A `codex app-server` that exits now says so on the card rather than leaving it
  blank, and a `codex` that is not installed at all reads "codex not found in
  PATH" instead of nothing.

## [0.1.0] - 2026-07-30

The first release. Everything below is new.

### Added

- **Menu bar item** that stays quiet until something needs attention: a
  monochrome template image, with the worst window's source, percentage and
  over-pace delta spelled out only when a threshold is crossed.
- **Panel** with one card per source — plan name, per-window gauges, reset time,
  and Claude Code's credit spend — ordered so the limit that runs out first is
  stated on the summary line before any detail.
- **The pace tick.** Every gauge carries a `▽` at the window's elapsed fraction;
  when the fill passes it the row says by how much you are over pace. Applies to
  all three sources, which is what makes a percentage actionable.
- **Claude Code source.** Reads the `Claude Code-credentials` keychain item
  read-only and calls the undocumented OAuth usage endpoint for the 5h window,
  the 7d window and credit spend; model-scoped limits appear on expand, and
  `claude` on `PATH` supplies plan and account.
- **Codex source.** Runs `codex app-server` as a child process and reads its
  push notifications for whichever rate-limit windows it reports.
- **Antigravity (`agy`) source.** Talks to the language server `agy` starts on
  localhost — no auth, and the port closes when `agy` exits.
- **Stale and partial-failure states.** A stale card dims, its dot goes hollow,
  and it states how old the value is rather than passing it off as current. One
  source failing leaves the other two rendering normally.
- **Refresh** every 30s, on window rollover, and on demand from the panel.
- **Homebrew tap and formula** (`brew tap simota/llm-usage …`), plus
  `make install` for a local build into `/Applications` (`PREFIX=` to redirect).
- **Tagged release workflow** building a universal, ad-hoc signed `.app`,
  verifying both architectures and the signature in the unpacked bundle, then
  rewriting the formula's version, url and sha256 on the default branch.
- **Diagnostics without a GUI**: `make probe` prints every source's normalised
  usage, `make panel` / `make icon` render the panel and menu bar artwork
  offscreen to PNG, and `scripts/probe-claude-oauth.sh` captures the raw OAuth
  response when a Claude Code update is suspected of changing the schema.

### Known limitations

- Requires macOS 13 or later; the release bundle is ad-hoc signed rather than
  notarised, so a keychain prompt reappears after each rebuild.
- No automated tests yet, and CI runs only on tags — nothing verifies a build on
  push or pull request.

[Unreleased]: https://github.com/simota/llm-usage/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/simota/llm-usage/releases/tag/v0.2.1
[0.2.0]: https://github.com/simota/llm-usage/releases/tag/v0.2.0
[0.1.2]: https://github.com/simota/llm-usage/releases/tag/v0.1.2
[0.1.1]: https://github.com/simota/llm-usage/releases/tag/v0.1.1
[0.1.0]: https://github.com/simota/llm-usage/releases/tag/v0.1.0
