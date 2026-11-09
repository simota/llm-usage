# LLM Usage

A macOS menu bar app — and a Linux tray app, built with Rust and gpui
([below](#linux)) — that shows how much of your Claude Code, Codex CLI, and
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

**Staleness is visible.** Claude Code's token can expire, and Antigravity's usage
command can fail or time out. The app never pretends a
stale number is current: the card dims, its header mark switches to an outline
glyph instead of a severity shape, and it states how old the value is.
The summary and menu bar use current samples only. The footer keeps the last successful
sample time when a fetch fails.

**Partial failure is normal.** One source going down leaves the other two
displaying normally. Only the broken card looks broken.

## Requirements

- macOS 13 or later
- Swift 6 toolchain (Xcode 16+)
- Whichever CLIs you want metered — each source is independent and optional

| Source | Needs | Notes |
|---|---|---|
| Codex | `codex` on `PATH` | Runs `codex app-server` as a child process and reads its push notifications |
| Claude Code | A Claude Code login; `claude` on `PATH` for the plan and account | Reads the `Claude Code-credentials` keychain item **read-only**, through the same `/usr/bin/security` Claude Code writes it with, so macOS does not prompt |
| Antigravity | Logged-in `agy` 1.1.11+ on `PATH` | Runs the read-only `/usage` command; the interactive CLI does not need to be open |

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

> The bundle is ad-hoc signed, so every build is a different application as far
> as macOS is concerned. The keychain read goes through `/usr/bin/security` for
> exactly that reason, and no longer asks for access after a rebuild.

## Linux

[`linux/`](linux) is the same app for Linux desktops, written in Rust with
[gpui](https://crates.io/crates/gpui). The providers, the normalised model, the
pace and severity rules, and the panel are ports of the Swift sources, and the
panel follows the same design spec.

It needs a desktop that hosts StatusNotifierItem tray icons — KDE Plasma, XFCE,
Cinnamon, or GNOME with the AppIndicator extension (on by default in Ubuntu).
Without one, the panel opens as a window at launch and closing it quits.

```sh
cd linux
make install     # ~/.local/bin/llm-usage, a menu entry, and an autostart entry
make uninstall
```

`PREFIX=` changes the install prefix and `AUTOSTART=0` skips the login item.
Building needs a Rust 1.88+ toolchain plus the xcb and xkbcommon headers
(`libxcb1-dev libxcb-xkb-dev libxkbcommon-dev libxkbcommon-x11-dev` on Debian
and Ubuntu).

```sh
make            # build, replace any running instance, start detached
make probe      # print every source's normalised usage, no GUI
make demo       # the panel on fixed data: FIXTURE=baseline|states|severity
make icon       # render the tray artwork to PNGs
make test       # unit tests; no real credentials or provider requests
make lint       # rustfmt and clippy, warnings as errors
```

What differs from macOS, and why:

- **Claude Code's token comes from `~/.claude/.credentials.json`**
  (`$CLAUDE_CONFIG_DIR/.credentials.json` when set). It is where Claude Code
  stores its login on Linux, in the same shape as the macOS keychain item. The
  file is only read, and the token is never refreshed, for the same reason as
  on macOS.
- **A single click shows the usage in the tray menu.** Ubuntu's AppIndicator
  extension opens an item's menu on a single click and activates it only on a
  double click, so the menu carries the panel's content as text: the summary,
  every source's rows, and the over-pace lines. A menu label takes no colour,
  so each row's icon carries it: a usage ring in the severity hue with the pace
  tick, and the card marks.
  Clicking a row, or Open Panel, opens the full panel. A host that sends
  `Activate` on a click opens the panel directly instead.
- **The tray icon is square and single-colour.** Tray hosts draw icons square,
  so the three bars and the hot-figure mode are laid out in a square. There is
  no template rendering, so the artwork is light for the usual dark panel;
  `LLM_USAGE_TRAY_THEME=dark` draws it dark for a light panel.
- **The panel is a separate process.** gpui ends its event loop when its last
  window closes, so a single process cannot keep the tray alive with the panel
  closed. The tray daemon owns the providers and holds no window. Clicking the
  icon starts `llm-usage --panel-view`, which draws what the daemon sends it
  and exits when it closes. As on macOS, the panel closes when it loses focus.
- **Placing the panel is up to the compositor.** Wayland does not let a client
  place a window beside the tray icon, so the panel opens where the
  compositor puts new windows.

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
swift test      # isolated regressions; no real credentials or provider requests
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

Providers start when the app launches and stop when it quits. Reopening the panel does
not start another fetch loop. The Homebrew service restarts crashes and respects Quit;
use `brew services restart llm-usage` to start it again after quitting.

`LLM_USAGE_CLAUDE_ENDPOINT` accepts only an HTTP(S) loopback URL for local fixtures.
An override uses the fixed `llm-usage-test-token` and skips Keychain and account lookups.
Other destinations are rejected before credentials are read.

## How it reads the data

Nothing is scraped from a terminal. Each source uses its CLI or usage API.

| Source | Path | Official? |
|---|---|---|
| Codex | `codex app-server` JSON-RPC `account/rateLimits/read` | Official — the schema can be machine-generated |
| Claude Code | `GET https://api.anthropic.com/api/oauth/usage` with the keychain token | Unofficial; an official API is [not planned](https://github.com/anthropics/claude-code/issues/45392) |
| Antigravity | `agy -p /usage --output-format json` | Supported read-only command since agy 1.1.11; no model turn or token usage |

All three are polled every 300 seconds. Codex also receives push updates, so it
stays current on its own.

Antigravity's CLI handles its own authentication. Older or unrecognized versions
are rejected before `/usage` runs, since older versions can interpret it as a
model prompt. The structured result supplies every quota window but no account
or plan, so those labels are omitted. The previous `LLM_USAGE_AGY_PORT` and
`LLM_USAGE_AGY_LOG_DIR` overrides are no longer used.

**Claude Code's token is never refreshed.** The refresh token rotates
server-side, so refreshing it from here would break your Claude Code login. The
app reads the keychain, and re-reads it each cycle to pick up whatever Claude
Code refreshed on its own.

The read runs `/usr/bin/security find-generic-password` — the same binary Claude
Code stores the item with, so it is already on the item's access list and its
Apple-signed identity never changes. An in-process read would instead be granted
to this build's signature alone and be denied, and prompt, after the next
rebuild. Nothing extra is granted: the access-list entry is Claude Code's own,
and the token comes back on a pipe rather than in an argument list.

Because CLI output and unofficial APIs can change, an update can break a source.
Each source degrades on its own rather than taking the app down.

## Docs

- [`docs/design.md`](docs/design.md) — the UI design spec, and the reasoning behind each decision
- [`docs/feasibility.md`](docs/feasibility.md) — how each data path was found, what was measured, and which paths were abandoned
- [`linux/`](linux) — the Linux port (Rust + gpui); its module docs map each file to the Swift source it ports
