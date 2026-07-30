# LLM Usage

A macOS menu bar app that shows how much of your Claude Code, Codex CLI, and
Antigravity CLI (`agy`) usage limits you have burned through — and whether you
are burning through them too fast.

The menu bar stays quiet until something needs attention. The panel tells you
which limit runs out first, when it resets, and whether your current pace will
hit the ceiling before it does.

```
╭────────────────────────────────────────────────────╮
│  ⚠ Codex 7d 56% · maxes out 8/1(Sat) at this pace  │
│                                                    │
│  ◆ Claude Code                          Max        │
│    5h      ▓░░░░░░░░▽░░░    8%    in 3h14m         │
│    7d      ▓▓▓▓░░░░▽░░░░   43%    8/1(Sat)         │
│    Credits ▓▓▓▓▓░░░░░░░░   53%     $79.71          │
│  ────────────────────────────────────────────────  │
│  ◆ Codex                                Pro        │
│    7d      ▓▓▓▓▓│▓▓░░░░░   56%    8/4(Tue)         │
│            ⚠ +27% over pace                        │
│  ────────────────────────────────────────────────  │
│  ◆ Antigravity                                     │
│    Gemini 5h ▓▓▓░░░▽░░░░   33%     in 59m          │
│    Claude/GPT 7d  unused                           │
│  ────────────────────────────────────────────────  │
│  Refresh  Quit                     12s ago         │
╰────────────────────────────────────────────────────╯
```

## What makes it different

**The pace tick.** A percentage alone cannot tell you whether you are overusing.
If 40% of a weekly window has elapsed and you have consumed 54%, you are on
track to hit the limit early. Every gauge carries a `▽` marker at the window's
elapsed fraction — when the fill passes the tick, you are over-pace, and the row
says by how much. It works on all three sources.

**Staleness is visible.** Claude Code's token goes stale while it sits idle, and
`agy`'s data is only reachable while `agy` is running. The app never pretends a
stale number is current: the card dims, its header mark switches to an outline
glyph instead of a severity shape, and it states how old the value is.

**Partial failure is normal.** One source going down leaves the other two
displaying normally. Only the broken card looks broken.

## Requirements

- macOS 13 or later
- Swift 6 toolchain (Xcode 16+)
- Whichever CLIs you want metered — each source is independent and optional

| Source | Needs | Notes |
|---|---|---|
| Codex | `codex` on `PATH` | Runs `codex app-server` as a child process and reads its push notifications |
| Claude Code | A Claude Code login; `claude` on `PATH` for the plan and account | Reads the `Claude Code-credentials` keychain item **read-only**. macOS prompts for access the first time |
| Antigravity | `agy` running | Talks to the language server `agy` starts on localhost. No auth needed, but the port closes when `agy` exits |

## Install

### Homebrew

```sh
brew tap simota/llm-usage https://github.com/simota/llm-usage
brew trust --formula simota/llm-usage/llm-usage
brew install llm-usage
brew services start llm-usage     # start it now and at every login
```

The tap URL is explicit because the repository has no `homebrew-` prefix, and
`brew trust` is what Homebrew 6 requires before it will load a third-party
formula.

It is a formula rather than a cask on purpose. Casks quarantine what they
install and Homebrew has removed every way to opt out, so a cask of an app that
is not Developer ID signed and notarised cannot be opened at all. Formula
downloads are not quarantined, and the ad-hoc signature the build applies is
enough for macOS to execute it.

`brew services start` is optional — `open $(brew --prefix)/opt/llm-usage/LLMUsage.app`
runs it once without a launchd agent. Symlink the bundle into `/Applications` to
reach it from Spotlight.

### From source

```sh
make install     # build a signed .app, put it in /Applications, and launch it
```

Override the destination with `PREFIX=` if `/Applications` is not writable:

```sh
make install PREFIX=$HOME/Applications
```

`make uninstall` removes it again.

> The bundle is ad-hoc signed, and a keychain ACL is bound to the signature.
> macOS will ask for keychain access again after each rebuild.

## Release

Tagging is the whole process. [`.github/workflows/release.yml`](.github/workflows/release.yml)
builds a universal `.app` on a macOS runner, verifies the signature survived the
zip, publishes it, and commits the new version and checksum into
[`Formula/llm-usage.rb`](Formula/llm-usage.rb) — which is what `brew install`
reads, since the tap is this repository.

```sh
make dist VERSION=0.2.0        # optional: build the same zip locally first
git tag v0.2.0 && git push origin v0.2.0
```

## Develop

```sh
make            # build, replace any running instance, start detached
make probe      # print every source's normalised usage to stdout, no GUI
make panel      # render the panel to PNGs (light and dark) and open them
make icon       # render the menu bar artwork to PNGs and open them
make dist       # build a universal .app and zip it, as the release workflow does
make help       # list every target
```

`make probe` is the fastest way to check the data plumbing — it exercises all
three providers and the normalisation path without launching a GUI:

```
source     : Codex  plan=Pro  account=…  state=ok  updated=2s ago
  window   : 7d  used=56%  resets=8/4(Tue)  pace=+27.0%
  bucket   : Spark  used=0%
```

`make panel` matters more than it looks: the panel only appears when you click
the menu bar, so overflow, truncation, and column misalignment are easy to miss
by eye. It renders offscreen in both appearances so you can actually inspect them.

## How it reads the data

Nothing is scraped from a terminal and nothing leaves your machine.

| Source | Path | Official? |
|---|---|---|
| Codex | `codex app-server` JSON-RPC `account/rateLimits/read` | Official — the schema can be machine-generated |
| Claude Code | `GET https://api.anthropic.com/api/oauth/usage` with the keychain token | Unofficial; an official API is [not planned](https://github.com/anthropics/claude-code/issues/45392) |
| Antigravity | `RetrieveUserQuotaSummary` on `agy`'s local language server | Internal protocol, but confined to localhost |

All three are polled every 300 seconds. Codex also receives push updates, so it
stays current on its own.

**Claude Code's token is never refreshed.** The refresh token rotates
server-side, so refreshing it from here would break your Claude Code login. The
app reads the keychain, and re-reads it each cycle to pick up whatever Claude
Code refreshed on its own.

Because two of the three paths are unofficial, a CLI update can break them.
Each source degrades on its own rather than taking the app down.

## Docs

- [`docs/design.md`](docs/design.md) — the UI design spec, and the reasoning behind each decision
- [`docs/feasibility.md`](docs/feasibility.md) — how each data path was found, what was measured, and which paths were abandoned
