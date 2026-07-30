# Design Spec: LLM Usage Menu Bar App

**Created**: 2026-07-30
**Target**: macOS native menu bar app (Swift 6 + SwiftUI `MenuBarExtra`)
**Basis**: the findings in [`feasibility.md`](./feasibility.md) (which data items each CLI exposes)

**Decided**: the menu bar presentation is a **hybrid of Option A and Option B** (§2).

---

## 1. Design principles

These are the basis for every decision that follows. When in doubt, come back here.

1. **The bar senses; the panel diagnoses**
   Don't line numbers up in the menu bar. Let it assert anomalies and nothing else.
2. **% alone is not enough to judge by**
   Treat "when does it reset" and "is the pace too fast" as information on par with the usage rate (§4).
3. **staleness is a first-class citizen**
   Claude Code's values go stale while it sits idle (see `feasibility.md` §2). Always show how old the value is.
4. **Assume partial failure**
   If one source goes down, the other two display normally. Only the broken card looks broken.
5. **Never depend on color alone**
   Fill ratio, icon shape, and the number itself also carry the state (color-vision deficiency).

---

## 2. Menu bar item

### Chosen approach: A + B hybrid

| Condition | Display | Intent |
|---|---|---|
| Every source under 80% | **Option A** triple gauge | Stay quiet, spend no width |
| Any source at 80% or above | **Option B** worst-one numeric | Spend width to assert, but only when it matters |

```
Normal (Option A)      Strained (Option B)
   ▁▅█                    ◕ 82%
   C X G
```

- Option A: 13pt wide × 16pt tall. Three bars — C(Claude) / X(Codex) / G(agy) — expressed as **fill height**. No numbers
- Option B: the dial for the strained source plus its number. Width is variable (up to ~39pt)

### The menu bar is monochrome (template image)

**The original idea of "showing state through color" is not used in the menu bar.** macOS flips the menu bar
foreground color automatically depending on wallpaper, dark/light mode, and accessibility settings, so a fixed color falls apart.
Draw monochrome with `NSImage.isTemplate = true` and **concentrate color in the panel**.

Carry the information without color:

- fill height (usage rate)
- always draw the track for the unconsumed portion (so a source at 0% doesn't look like it has vanished)
- switching to Option B above 80% is itself the warning (no dependency on color)

### Draw with NSImage, not SwiftUI

`MenuBarExtra`'s label won't reliably render anything other than `Text` / `Image` (arbitrary SwiftUI shapes
silently come out empty). Build an `NSImage` in `MenuBarIcon` and pass it in via `Image(nsImage:)`.
`LLMUsage --icon <dir>` writes the render out as an 8× PNG for visual inspection.
- The switch is a 0.25s crossfade. **Hysteresis** keeps it from toggling constantly
  (enter Option B at 80%, return to Option A only once it drops below 75%)

### App icon

Draw the **same figure** as the menu bar (three gauges plus the always-drawn track), in color and full-bleed.
Where the menu bar side is a monochrome template, this one carries a palette because it is for Finder and the app switcher.

- Big Sur proportions: the drawing area is `824/1024` of the canvas, corner radius `185.4/1024`
- Background is a blue gradient (top `#5C94FF` → bottom `#1745CC`), bars are white
- Fill heights are 42% / 66% / 92% from the left (the same rising silhouette as the menu bar)
- **Generated in code** (`AppIcon.swift`). No binary assets committed; the geometry stays reviewable

```
make icns   # render 10 sizes and pack them into an .icns
make app    # assemble the .app with the icns included
```

macOS 26 applies Liquid Glass shading and beveling to an `.icns` on its own, so
**drawing flat is all this side has to do** (painting gloss in would double it up).

### Rejected: Option C, full text

```
   C62 X54 G18
```

The most information, but it crowds the menu bar and pushes other apps' icons out. **Not recommended**.

---

## 3. The panel

`MenuBarExtra(style: .window)`, 320pt wide.

```
╭──────────────────────────────────────────────╮
│  ⚠ Codex 7d 56% · +27% over pace             │  ← summary line (§3.1)
│                                              │
│  ◆ Claude Code                          Max  │
│    5h      ▓░░░░░░░░▽░░░    8%    in 3h14m   │
│    7d      ▓▓▓▓░░░░▽░░░░   43%    8/1(Sat)   │
│    Credits ▓▓▓▓▓░░░░░░░░   53%     $79.71    │
│    ⌄ By model (1)                            │
│  ────────────────────────────────────────    │
│  ◆ Codex                                Pro  │
│    7d      ▓▓▓▓▓│▓▓░░░░░   56%    8/4(Tue)   │
│            ⚠ +27% over pace                  │
│  ────────────────────────────────────────    │
│  ◆ Antigravity                               │
│    Gemini 5h ▓▓▓░░░▽░░░░   33%     in 59m    │
│    Claude/GPT 7d  unused                     │
│    ⓘ Shared with the desktop app and SDK     │
│    ⌄ By model (4)                            │
│  ────────────────────────────────────────    │
│  Refresh  Quit                     12s ago   │
╰──────────────────────────────────────────────╯
```

**Don't stack card surfaces.** A `.quaternary` fill blended into the background almost entirely and landed in a
half-state that was "neither surface nor whitespace." Separate with dividers and whitespace alone (the idiom macOS Control Center uses).

### 3.1 Summary line — put the conclusion first

The panel answered "how much have I used," but the actual question is
**"which one runs out first / am I overusing?"** Stop making people compare five gauges;
name it in a single line at the very top. The old `Usage ⟳ 0s ago` header repeated the app name and carried nothing, so it was replaced,
and the refresh time moved to the bottom right.

| Situation | Display |
|---|---|
| Over-pace present | `⚠ Codex 7d 56% · maxes out 8/1(Sat) at this pace` (red) |
| 60% or above, pace normal | `Codex 7d 82% · 8/4(Tue)` (icon at 80% and above) |
| All healthy | `All healthy · next reset in 3h14m` |
| No data | `No data` |

The % is the diagnosis, the date is what to do about it. **Put the hit date in the summary** and `+27% over pace` (%) in the row caption to split the roles.

```
rate            = usedPercent / elapsedFraction     (usage rate across the whole window)
fractionAtLimit = 100 / rate                        (only when rate > 100)
hit time        = windowStart + fractionAtLimit × span
```

**Picking the binding window** = the one with the highest "projected usage rate at window end":

```
projected = usedPercent / elapsedFraction     (leave usedPercent as is when elapsed < 10%)
```

Above 100 it will hit the limit before the reset. Ties are settled by `is_active` (§6).
Ordering by raw usage rate overvalues "a high % late in the window."

### 3.2 Collapse unused windows into one line

`Claude/GPT 7d ▏░░░░ 0% in 7d` spends a whole line saying only "not used," so
compress it to `Claude/GPT 7d  unused`.

### 3.3 `By model` is conditional

Don't show it on a card that merely restates the headline, or that has nothing but 0% buckets.
**The provider makes the call.** Whether something "restates the headline" is a question of meaning, not of numbers.
The first version compared values and collided unrelated things — Claude's `Fable 11%` disappeared because it happened to
equal `5h 11%`, and agy's `Gemini 5h 1%` disappeared against `Claude/GPT 7d 0%` from **a different group**,
within 1pt. The result was that the disclosure stopped appearing anywhere at all.

- **Codex**: drop the bucket matching the primary `limitId` (it is an alias of the headline)
- **Claude**: `weekly_scoped` is always a different thing, so keep it
- **agy**: the window covers every bucket, so it has none

The view only asks whether there is at least one bucket at 0.5% or above.

### With per-model expanded (Codex)

```
│  ◆ Codex                            Pro  │
│    7d     ▓▓▓▓▓▓░▽░░░░░░   54%    in 3d  │
│    ⌃ By model                            │
│      codex            ▓▓▓▓▓▓░░░░   54%   │
│      GPT-5.3-Spark    ░░░░░░░░░░    0%   │
│      Credit balance               $0.00  │
```

Each bucket of `rateLimitsByLimitId` (showing `limitName` when it exists, otherwise `limitId`) plus
`credits.balance` go into the disclosure area.

---

## 4. The pace tick (`▽`) — what sets this app apart

**A % alone doesn't tell you whether you're overusing.** If only 40% of the weekly window has elapsed and
54% is consumed, that is over-pace.

Place a `▽` marker on the gauge at "the expected usage rate at this instant" (= the window elapsed fraction).

```
  ▓▓▓▓▓▓░▽░░░░░░   54%     fill has passed the tick → over-pace
  ▓▓▓░░░░▽░░░░░░   31%     short of the tick        → room to spare
```

### Calculation

```
windowStart   = resetsAt - windowDurationMins * 60
elapsedRatio  = (now - windowStart) / (windowDurationMins * 60)
paceDelta     = usedPercent / 100 - elapsedRatio
```

- `paceDelta > 0` → over-pace. Turn the tick red and attach `+14% over pace` to the card
- `paceDelta <= 0` → the tick is secondary gray, no annotation

### Scope

Computable on all three sources:

| Source | Window length | Reset time | Usage rate |
|---|---|---|---|
| Codex | `windowDurationMins` (measured: 10080) | `resetsAt` (epoch seconds) | `usedPercent` |
| Claude Code | 5h / 7d (treated as fixed values) | `rate_limits.*.resets_at` (epoch seconds) | `used_percentage` |
| agy | **derived from `window` (`"5h"` / `"weekly"`)** (measured) | `resetTime` (RFC3339 string) | **the inverse of `remainingFraction`** |

Measurement confirmed that **all three sources are computable**. Only agy needs normalizing:

```
usedPercent = (1 - remainingFraction) * 100
resetsAt    = ISO8601(resetTime) → epoch seconds
windowMins  = {"5h": 300, "weekly": 10080}[window]
```

---

## 5. Anatomy of a card

| Row | Content | Typography |
|---|---|---|
| 1 | status dot `◆` + tool name + plan badge (right-aligned) | 13pt semibold / badge 10pt |
| 1b | logged-in account | 10pt tertiary, middle truncation |
| 2..n | window name + gauge + `%` + time to reset | 11pt / **13pt monospacedDigit** / 11pt secondary |
| last | disclosure toggle, annotations, errors | 11pt secondary |

- **`%` and times are always `.monospacedDigit`**. Without monospaced digits the width jitters on every refresh
- **Show the account on all three sources.** It duplicates when the addresses match, but authentication is
  independent per tool and can diverge. "Which login is being metered" is worth being able to confirm silently, and never more so than when they do match.
  Long addresses get middle truncation (`.truncationMode(.middle)`) to keep the domain
- Gauge height: 6pt for a primary window / 4pt for a secondary one, fully rounded at both ends
- Minimum row height 22pt

### Notation rules for reset times

| Time remaining | Notation |
|---|---|
| < 1 hour | `in 48m` |
| < 24 hours | `in 3h14m` |
| >= 24 hours | `8/4(Tue)` |
| already past | `now` |

Past 24 hours, go **absolute date**. `in 6d` is too coarse for a weekly window to plan a recovery around.
The weekday is attached because a weekly reset is remembered by which day of the week it lands on.

---

## 6. State design

| State | Threshold | Gauge color | Dot | Secondary cue |
|---|---|---|---|---|
| normal | 0–59% | accent | `◆` filled | — |
| notice | 60–79% | yellow | `◆` filled | — |
| warning | 80–94% | orange | `◆` filled | menu bar switches to Option B |
| danger | 95–100% | red | `◆` filled + pulse | notification (optional) |
| **stale** | — | 40% opacity | `◇` hollow | states `as of 12m ago` |
| **error** | — | dashed placeholder | `◇` gray | reason + `Retry` |
| **unconfigured** | — | gray | `◇` gray | `Configure →` |

### Rendering stale / error

```
│  ◇ Claude Code                        Max 20x  │
│    5h    ░░░░░░░░░░░░░░░░░░   62%     38m ago  │
│    ⓘ Token expired (launch Claude Code to renew)│
├────────────────────────────────────────────────┤
│  ◇ Antigravity                                 │
│    ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄  Unavailable             │
│    Credentials expired               Retry ↻   │
```

Thresholds for calling something stale (they differ per source):

| Source | Age treated as stale | Notes |
|---|---|---|
| Codex | 10 min | Shouldn't go stale at all, since there are push notifications |
| Claude Code | 15 min | OAuth polls every 300 seconds. Unobtainable while the token is expired |
| agy | 15 min | **Unobtainable while agy is closed** (the local language server dies). Shown as stale for the duration |

### Active window (`is_active`)

Claude's API returns `is_active` per window (**which window is metering right now**).
On sources that have it, drop the `%` of inactive windows to `.secondary` to tell them apart.
Putting a dot in the label column was rejected: it squeezed the 64pt column and shrank the labels.
**On sources that don't report `is_active`, leave every `%` primary**
(so the appearance doesn't diverge between sources).

### Stating over-pace

The tick alone doesn't convey what it means. On rows where `paceDelta > +10%`, attach
`⚠ +27% over pace` in red. Red is unified across the tick, the row caption, and the summary-line icon.

When agy is stopped, treat it as **stale, not error**. From the user's point of view it is only
"not updated because I'm not using agy" — not a failure.
Attach `Antigravity not running` as the annotation.

---

## 7. Visual language

- **Material**: leave the panel background to the system material (`.regularMaterial` / Liquid Glass).
  No background color of our own, so it follows OS generations automatically
- **Cards**: `.quaternary` fill, 8pt corner radius
- **Icons**: vendor logos are trademarks, so they aren't used. Substitute SF Symbols plus a letter mark
  - Claude Code → `sparkle`
  - Codex → `chevron.left.forwardslash.chevron.right`
  - agy → `arrow.up.forward.circle`
- **Color**: semantic colors only. No hardcoded hex. Light and dark both supported
- **Animation**:
  - value change → interpolate the gauge over 0.25s ease-out
  - reset reached → return to zero over 0.6s (a satisfying moment, so stage it)
  - danger pulse → 2.0s loop, opacity 1.0 ↔ 0.6

---

## 8. Interaction

| Action | Behavior |
|---|---|
| left click | open / close the panel |
| right click | short menu (Refresh / Settings / Quit) |
| `⌘R` | force-refresh every source (Claude shows a cooldown to avoid 429s) |
| `Esc` | close the panel |
| click a card | expand / collapse the per-model buckets |
| threshold exceeded | Notification Center (off by default, on via settings) |

While the `⌘R` cooldown runs, the refresh button is disabled and carries `42s left`.

---

## 9. Layout spec

```
panel width           320pt
outer padding          12pt
between cards           8pt
row gap within card     6pt
between sections       14pt   (with a divider)
label column           72pt   left-aligned, lineLimit(1), minimumScaleFactor(0.7)
gauge width        variable   (absorbs the remainder. 114pt effective)
gauge height            6pt   (primary) / 4pt (secondary)
% column               44pt   right-aligned, monospacedDigit
reset column           56pt   right-aligned
header height          28pt
footer height          32pt
minimum row height     22pt
```

**Getting the columns onto fixed widths matters more than anything else.** When the gauge's left edge and the `%` right edge
line up across all three sources, the eye runs straight down and the comparison is over in an instant.

### Don't fix the gauge width

**The original spec's "gauge fixed at 168pt" was wrong.** The row's real width came to
`64 + 168 + 44 + 52 + 6×3 = 346pt`, and adding 20 of card padding and 24 of outer padding made 390pt —
far past the 320pt panel, with both sides cut off.

Fix the fixed columns only and **let the gauge absorb the remainder** (`maxWidth: .infinity`).
Because every row's fixed columns are identical the gauge widths line up automatically too, and adding a column or changing wording can no longer overflow, structurally.

Available inner width: `320 − 12×2 = 296pt` (card padding dropped)
Effective gauge width: `296 − (72 + 44 + 56 + 6×3) = 106pt`

### Verify the layout with offscreen rendering

`LLMUsage --panel <dir>` writes out PNGs in both light and dark. The panel only appears once you click
the menu bar, so overflow, truncation, and column misalignment are easy to miss by eye.
Use `ImageRenderer` (`NSHostingView.cacheDisplay` drops text).

---

## 10. Phase 1 (Codex only) layout

Per the phased plan in [`feasibility.md`](./feasibility.md), Phase 1 starts with Codex alone.

```
╭──────────────────────────────────────────╮
│  Usage                       ⟳ 12s ago   │
├──────────────────────────────────────────┤
│  ◆ Codex                            Pro  │
│    7d     ▓▓▓▓▓▓░▽░░░░░░   54%    in 3d  │
│    ⌄ By model (2)                        │
├──────────────────────────────────────────┤
│  ◇ Claude Code              Configure →  │
│  ◇ Antigravity              Configure →  │
├──────────────────────────────────────────┤
│  Refresh  ·  Settings  ·  Quit           │
╰──────────────────────────────────────────╯
```

Placing the unsupported sources as "unconfigured cards" from the start means Phase 2 / 3 can be dropped in
without rebuilding the layout. The menu bar stays on Option A's three gauges, showing anything not yet fetched as an empty bar.

---

## 11. Implications for implementation

- **Keep the data model source-agnostic**
  Normalize onto `UsageSource { id, displayName, plan, windows, buckets, lastUpdated, state }`, which holds
  an array of `UsageWindow { label, usedPercent, resetsAt, windowDuration?, paceDelta? }`.
  Build the card view once and it renders all three sources.
- **Express `state` as an enum**
  `.ok / .stale(since:) / .error(reason:) / .unconfigured`. The table in §6 becomes the switch as written.
- **One gauge component**
  Primary vs secondary differ in height only. The pace tick is an optional overlay.
