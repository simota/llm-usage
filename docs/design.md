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
| Every source under 80% (projected) | **Option A** triple gauge | Stay quiet, spend no width |
| Any source's projected usage at 80% or above | **Option B** worst-one numeric | Spend width to assert, but only when it matters |

The gate's input is now **`binding`'s projected figure** (`usedPercent / elapsedFraction`, §3.1) —
not raw `usedPercent`. It used to be raw usage, which meant a source running badly over-pace but not
yet at 80% *used* could never trip the gate — the app's headline feature (the pace marker) never
reached the one surface that's always visible. The "stay quiet, spend no width" intent above still
holds; what counts as "not quiet enough" is what changed. Threshold and hysteresis band stay at
enter-80/exit-75, unchanged from below.

Two honest costs that come with the fix, so a future reader doesn't mistake this for a free
improvement:

- **The gate amplifies early in a window.** `projectedPercent` only extrapolates once at least 10%
  of the window has elapsed (below that it falls back to raw `usedPercent`, to avoid dividing by
  something close to zero) — but at exactly that 10% mark, the multiplier is 10×. A source at 9%
  used, 9% elapsed, sits quietly under Option A; the same source one tick later, at 10% used / 10%
  elapsed, projects to 100% and can trip the gate outright. The threshold and deadband numbers (80/75)
  didn't move, but what they mean in terms of raw `usedPercent` now varies with how far into the
  window you are — narrower in absolute terms early on, identical to before once a window is mostly
  elapsed (`elapsed → 1` makes `projected → usedPercent`).
- **The gate and the displayed figure are no longer the same window.** When Option B is showing,
  the number on the menu bar is `worst`'s raw `usedPercent` (the most-consumed window, unchanged
  behaviour) — but *whether* Option B is showing is now decided by `binding`'s projection, which can
  be a different window entirely. It is possible to see Option B's numeric display naming one
  source's raw usage while a different, over-pace source is the reason the gate opened at all.

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
╭────────────────────────────────────────────────────╮
│  ⚠ Codex 7d 56% · maxes out 8/1(Sat) at this pace  │  ← summary line (§3.1)
│                                                    │
│  ◆ Claude Code                          Max        │
│    5h      ▓░░░░░░░░▽░░░    8%    in 3h14m         │
│    7d      ▓▓▓▓░░░░▽░░░░   43%    8/1(Sat)         │
│    Credits ▓▓▓▓▓░░░░░░░░   53%     $79.71          │
│    ⌄ By model (1)                                  │
│  ────────────────────────────────────────────────  │
│  ◆ Codex                                Pro        │
│    7d      ▓▓▓▓▓│▓▓░░░░░   56%    8/4(Tue)         │
│            ⚠ +27% over pace                        │
│  ────────────────────────────────────────────────  │
│  ◆ Antigravity                                     │
│    Gemini 5h ▓▓▓░░░▽░░░░   33%     in 59m          │
│    Claude/GPT 7d  unused                           │
│    ⓘ Shared with the desktop app and SDK           │
│    ⌄ By model (4)                                  │
│  ────────────────────────────────────────────────  │
│  Refresh  Quit                     12s ago         │
╰────────────────────────────────────────────────────╯
```

**Don't stack card surfaces.** A `.quaternary` fill blended into the background almost entirely and landed in a
half-state that was "neither surface nor whitespace." Separate with dividers and whitespace alone (the idiom macOS Control Center uses).

**Card order stays registration order (Claude → Codex → Antigravity) — not urgency order.**
Sorting the worst source to the top was considered and rejected: this panel refreshes every few
seconds, and a surface that reorders itself out from under a pointer that was about to click
something is a known calm-UI failure. The summary line (§3.1) is the promotion mechanism — it already
names the worst source in place, at the top, without moving anything else. Don't re-propose
urgency-sorting the cards without first changing how often the panel refreshes.

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

**Two different questions need two different windows, not one.** "Which limit runs out first" and
"what should the summary line say" sound like the same question and aren't:

**Picking the binding window** = the one with the highest "projected usage rate at window end". This
is §2's menu bar gate input, and it answers "which limit runs out first":

```
projected = usedPercent / elapsedFraction     (leave usedPercent as is when elapsed < 10%)
```

Above 100 it will hit the limit before the reset. Ties are settled by `is_active` (§6).

**Picking the headline window** — the one the table above actually renders — ranks by
`displayedSeverity` (§6) first, and only falls back to `binding`'s projection to break a severity
tie, then `is_active`, then raw `usedPercent`. The summary line used to speak for `binding` directly,
and that was a real bug, not a style choice: ordering by projection alone let a 35%-used window that
merely extrapolated badly outrank a visible 87%, so the panel could read `All healthy` directly above
two cards that were anything but. Severity has to be the primary key for a line that's allowed to
say "healthy" — and now it only says that once every window on screen is `.normal`. The projection
tie-break is kept so that among equally severe windows, the one that bites soonest is still the one
named — that part of the original intent survives.

A card's mark, the row inside that card, and the headline naming that card now all trace back to the
same `displayedSeverity` (§6), so they can no longer disagree about how bad something is.
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

Place a pace marker on the gauge at "the expected usage rate at this instant" (= the window elapsed
fraction) — an `arrowtriangle.down` glyph, **hollow when in-pace, filled solid when over-pace.** The
marker used to be a plain 2px rectangle that only changed hue; between 0% and +10% over pace (the
band below where the `+14% over pace` caption fires, see below) that red rectangle was the *only*
signal anywhere in the UI — nothing for a color-blind or greyscale-mode reader to catch. The shape
flip closes that gap without changing when the caption itself appears.

```
  ▓▓▓▓▓▓░▽░░░░░░   54%     fill has passed the tick → over-pace
  ▓▓▓░░░░▽░░░░░░   31%     short of the tick        → room to spare
```

(`▽`/`▲` above stand in for the hollow/filled `arrowtriangle.down` in these ASCII mocks.)

### Calculation

```
windowStart   = resetsAt - windowDurationMins * 60
elapsedRatio  = (now - windowStart) / (windowDurationMins * 60)
paceDelta     = usedPercent / 100 - elapsedRatio
```

- `paceDelta > 0` → over-pace. Fill the triangle solid (red as reinforcement, not the only cue); the
  `+14% over pace` caption still only attaches once `paceDelta > +10%` (§6) — the shape change is
  what covers the narrower band below that threshold, where previously nothing did
- `paceDelta <= 0` → hollow triangle, secondary gray, no annotation

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
| 1 | header symbol (§6) + tool name + plan badge (right-aligned) | `.callout` symbol / `.headline` name / `.caption` badge |
| 1b | logged-in account | `.caption`, middle truncation |
| 2..n | window name + gauge + `%` + time to reset | `.subheadline` / **`.body` semibold `monospacedDigit`** / `.subheadline` `monospacedDigit` |
| pace annotation | `⚠ +27% over pace` | `.footnote` medium |
| last | disclosure toggle, notes, errors | `.subheadline` |

- **Typography is semantic, not point-sized.** Every row above is a semantic text style
  (`.caption`/`.footnote`/`.subheadline`/`.body`/`.headline`/`.callout`), not a fixed `.system(size:)`
  — the fixed sizes were what kept the panel from responding to Dynamic Type at all (14+ sites, zero
  semantic styles, before this pass). `.system(size:)` is zero in the view code now. The `%` column
  keeps `.body`, the largest text in the row, because it's the one figure every row exists to show;
  de-emphasis for a non-metering window rides on weight (`.semibold` → `.regular`) rather than on a
  faded color, so it never drops the figure below 4.5:1 contrast to make the point.
- **`%` and times are always `.monospacedDigit`**. Without monospaced digits the width jitters on every
  refresh — this survives the semantic-type migration unchanged; it's the single largest regression
  risk in that pass and is called out here on purpose
- **Show the account on all three sources.** It duplicates when the addresses match, but authentication is
  independent per tool and can diverge. "Which login is being metered" is worth being able to confirm silently, and never more so than when they do match.
  Long addresses get middle truncation (`.truncationMode(.middle)`) to keep the domain
- Gauge height: 6pt for a primary window / 4pt for a secondary one, fully rounded at both ends
- Minimum row height 22pt
- **Every information-bearing row is one VoiceOver element.** `MeterRow`, `UnusedWindowRow`,
  `SpendRow`, the card header, and the summary line each combine into a single
  `accessibilityElement(children: .combine)` with an explicit label and value, so VoiceOver reads "Codex,
  7 day, 56 percent, over pace" instead of five disconnected glyphs. Purely decorative pieces (the gauge
  track, dividers) get `.accessibilityHidden(true)` — before this pass the view code had zero
  accessibility API usage of any kind.

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

Severity is carried by the header symbol's **shape**, with color as reinforcement rather than the
only signal (§1). A single `◆`/`◇` diamond could only ever say "there is a state," never which one —
converted to greyscale, all four `.ok` severities looked identical, and VoiceOver had no way to read
the distinction either. Every severity level gets its own silhouette — round, square, triangular,
polygonal — rather than sharing one and leaning on hue to tell them apart:

| State | Threshold | Gauge color | Header symbol | Secondary cue |
|---|---|---|---|---|
| normal | 0–59% | accent | `circle.fill` | — |
| caution | 60–79% | yellow | `exclamationmark.square.fill` | — |
| warning | 80–94% | orange | `exclamationmark.triangle.fill` | menu bar switches to Option B |
| critical | 95–100% | red | `exclamationmark.octagon.fill` | notification (optional) |
| **stale** | — | 40% opacity | `clock` | states `as of 12m ago` |
| **error** | — | dashed placeholder | `xmark.octagon` | reason + `Retry` |
| **unconfigured** | — | gray | `circle.dashed` | `Configure →` |

`.ok` takes the four filled severity shapes above; the three no-data states each get their own fixed
outline-style glyph instead of borrowing one — "we cannot tell you" is not a severity, so it doesn't
scale on the same axis as caution → critical. Caution isn't merged into normal's circle: at 12pt,
`exclamationmark.circle.fill` and the octagon read as the same blob, which is why caution is a square
instead — four legible silhouettes, not three plus a near-duplicate. Each symbol also carries an
`accessibilityValue` naming the state in words, so VoiceOver isn't left inferring severity from a
glyph name it can't see.

A card's mark is the *worst* severity across its own windows — not one window's `usedPercent` paired
with a different window's pace, which is how a card used to out-rank or under-rank every row printed
underneath it. When the summary line (§3.1) is naming this same card, the card's mark is raised to
match the headline's severity too, so the card the summary points at can never show a calmer mark
than the sentence sitting above it.

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

`Retry` calls the same `refreshAll()` as the panel's own Refresh control — there is no per-source
refresh, and this isn't the place to add one. The button lives on the broken card because that's
where the user is looking when something needs recovering (Nielsen #9), not because it only refreshes
that source.

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

### Legend

A first run cannot learn what a hollow triangle over a bar means from the panel alone — nothing in
it says so. A footer `?` control expands an inline legend explaining the pace marker and all seven
symbols above; collapsed, it costs zero standing height, so nobody pays for an explanation they
don't need on the two-hundredth glance. It fixes discoverability's *ceiling*, not its floor — a
2-second glance still won't teach the vocabulary, and isn't supposed to.

It is a real `Button`, so VoiceOver reaches it in normal reading order and the legend rows it opens
are ordinary accessible text, not an image. `.help()` is layered on **in addition to** that, for the
pointer, never instead of the accessible affordance. Both a tooltip and motion on the legend's
disclosure were flagged as non-goals in the direction that shaped this pass — decorative chrome and
added motion generally aren't wanted here — but this one case was reviewed and kept deliberately: the
toggle reuses the same 0.15s `easeOut` already used for the per-model disclosure (§3.3), so it isn't
a new animation vocabulary, and the tooltip only ever restates what the accessible label already
says. Record this as an accepted, reviewed exception rather than rediscovering it as drift later.

---

## 7. Visual language

- **Material**: leave the panel background to the system material (`.regularMaterial` / Liquid Glass).
  No background color of our own, so it follows OS generations automatically
- **Cards**: no fill, no corner radius. See §3, "Don't stack card surfaces" — an earlier draft of this
  section specified `.quaternary` fill at 8pt radius, which flatly contradicted §3 within the same
  document. It was never a live disagreement, just a line nobody deleted once §3's own experiment
  (fill blending into the background, landing in neither-surface-nor-whitespace) settled the question.
  §3 is the rule; this entry is gone so the document stops arguing with itself.
- **Icons: rejected, per-source vendor marks.** An earlier draft substituted an SF Symbol per source in
  place of the trademarked logos (Claude Code → `sparkle`, Codex → `chevron.left.forwardslash.chevron.right`,
  agy → `arrow.up.forward.circle`). This was never built, and it should stay that way: the header symbol
  slot now carries *state* — severity, staleness, error (§6) — and a fixed brand glyph in that same slot
  would collide with it on every card, every refresh. The card's name text already says which source it
  is; the symbol's job is to say how it's doing, not who it is.
- **Color**: semantic colors only. No hardcoded hex. Light and dark both supported. **Known gap,
  pre-existing**: `Severity.color`'s `.yellow` and `.orange` measure roughly 1.4:1 and 2.2:1 against
  the light-mode panel background — well under WCAG 1.4.11's 3:1 for non-text UI. This isn't new to
  this pass and isn't fixed by it: these are dynamic system colors, not a token choice, and the fix
  would be a custom tint, which the "use what the system supplies" direction rules out. Shape (§6)
  already carries the severity these colors reinforce, so the gap is contained rather than silent —
  but it's recorded here so it isn't rediscovered as a new regression later.
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
| `⌘R` | force-refresh every source — the keyboard equivalent of the Refresh button |
| `Esc` | close the panel |
| click a card | expand / collapse the per-model buckets |
| threshold exceeded | Notification Center (off by default, on via settings) |

**Not implemented**: an earlier draft of this spec described a refresh cooldown ("Claude shows a
cooldown to avoid 429s," the button disabled and reading `42s left`). That never shipped — `⌘R` and
the Refresh button both call the same unthrottled `refreshAll()`. If a hammered `⌘R` turns out to
actually draw 429s, add the cooldown then; don't carry speculative throttling in the doc as if it
were live behavior.

**Refresh, Quit, and the disclosure toggle all reach a real 24×24pt hit target (WCAG 2.5.8), but not
by the same route** — the glyph-sized version measured under 20×20pt, below both that and the HIG's
44×44, and none of the three drew a focus ring.

- **Refresh** is `.buttonStyle(.bordered)` — a real control, hit area and focus ring included. This
  is the one place `.bordered` was checked against `--panel` offscreen rendering and it survived;
  `.link` was the style that didn't (see the Retry button, §6, which is `.bordered` for the same
  reason).
- **Quit** stays `.plain`, on purpose, not as a fallback: it is the destructive action with no
  confirm step, so it keeps a visibly lighter weight than `Refresh` and sits at the opposite end of
  the row rather than beside it. Its 24pt hit area comes from an explicit `.frame(minHeight:)` +
  `.contentShape(Rectangle())`, the same mechanism as the disclosure toggle below — separation by
  position and chrome, not by fading a label to unreadable contrast.
- **The disclosure toggle** is also `.plain` + `.frame(minHeight: 24)` + `.contentShape(Rectangle())`.
  A chevron doesn't read as a bordered button at any size, so the fix here is the hit area alone, not
  a style change.

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

**There is no automated test suite** (no `.testTarget`, no `Tests/` directory). `--panel` and
`--icon` renders plus manual/visual review are the whole of verification; treat any claim of
"tested" elsewhere as meaning that, not an XCTest run.

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
