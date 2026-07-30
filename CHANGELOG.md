# Changelog

Notable changes, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the version numbers
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Tagging is the release process (README § Release). When cutting a version,
rename `Unreleased` to that version with its date and open a fresh `Unreleased`
above it — the tag is what publishes the zip, so the heading and the tag must
agree.

## [Unreleased]

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

[Unreleased]: https://github.com/simota/llm-usage/commits/main
