import AppKit
import SwiftUI

/// `LLMUsage --panel <dir>` renders the panel offscreen in both appearances.
///
/// The panel is only reachable by clicking the menu bar item, which makes layout
/// regressions expensive to catch. Rendering it to a file makes column alignment,
/// truncation and overflow checkable directly.
@MainActor
enum PanelDump {
    static func run(directory: String) -> Never {
        // Baseline: all three sources `.ok`. Kept byte-identical in intent to
        // the original fixture so this stays comparable across audits.
        renderPair(prefix: "panel", sources: fixture(), directory: directory)

        // The `.stale` / `.error` / `.unconfigured` branches of
        // SourceCardView's `switch state` have never been rendered by
        // `fixture()` above — see docs/design.md's restyle audit §7. This
        // fixture is what makes them checkable at all.
        renderPair(prefix: "panel-states", sources: statesFixture(), directory: directory)

        // Same sources as the baseline, forced to the largest Dynamic Type
        // step, to answer whether the fixed `Layout.labelColumn/percentColumn/
        // resetColumn` widths overflow or truncate (design.md §9's regression
        // guard) once text can no longer shrink to fit.
        renderPair(prefix: "panel-a11y", sources: fixture(), directory: directory, accessibilitySize: true)

        // Neither `fixture()` nor `statesFixture()` ever produces `.caution` or
        // `.warning` — only `.normal` and `.critical` show up by accident. And
        // no fixture puts a window 0-10% over pace, the one band where
        // `Format.overPace` prints no caption at all and the escalated shape is
        // the only signal (Severity.escalated's own doc comment). This fixture
        // is what makes all four severity silhouettes, and that silent band,
        // checkable.
        renderPair(prefix: "panel-severity", sources: severityFixture(), directory: directory)

        // `UsageStore.summary` now names the worst `displayedSeverity` across
        // *every* window on screen (App.swift's `headline`), not the binding
        // window — so "All healthy" can only be true, and can only be checked,
        // when every window everywhere is `.normal` and on pace. No existing
        // fixture does that: `fixture()` has a 56% window and `severityFixture()`
        // exists specifically to put caution/warning/critical on screen.
        renderPair(prefix: "panel-healthy", sources: healthyFixture(), directory: directory)

        // The other summary branch `severityFixture()` can't isolate: it puts
        // a `.warning` window on screen too, so its headline names *that*
        // instead. A dedicated fixture where the worst window is `.caution`
        // and nothing else outranks it is the only way to see "high but
        // keeping up" on the summary line by itself, rather than folding a
        // second conclusion into the all-healthy render above.
        renderPair(prefix: "panel-caution", sources: cautionHeadlineFixture(), directory: directory)

        exit(0)
    }

    /// Renders one fixture's light/dark pair.
    ///
    /// ImageRenderer, not NSHostingView.cacheDisplay: the latter captures only
    /// layer-backed shapes and drops SwiftUI text entirely.
    private static func renderPair(prefix: String, sources: [UsageSource], directory: String,
                                    accessibilitySize: Bool = false) {
        let store = UsageStore(sources: sources)

        for (name, scheme) in [("\(prefix)-light", ColorScheme.light),
                               ("\(prefix)-dark", ColorScheme.dark)] {
            let base = PanelView(store: store)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.14) : Color(white: 0.97))

            // Type-erased only here, to keep the two branches (plain vs.
            // Dynamic-Type-forced) from needing two near-duplicate render blocks.
            let content = accessibilitySize
                ? AnyView(base.dynamicTypeSize(.accessibility1))
                : AnyView(base)

            let renderer = ImageRenderer(content: content)
            renderer.scale = 2

            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else { continue }

            let path = (directory as NSString).appendingPathComponent("\(name).png")
            try? data.write(to: URL(fileURLWithPath: path))
            print("\(path)  \(Int(image.size.width))x\(Int(image.size.height))pt")
        }
    }

    /// Deliberately worst-case: the longest agy labels, a source with buckets,
    /// an unconfigured source, and an over-pace window.
    private static func fixture() -> [UsageSource] {
        let now = Date()

        var claude = UsageSource(id: "claude", displayName: "Claude Code")
        claude.plan = "Max"
        claude.account = "shingo.imota@gmail.com"
        claude.state = .ok
        claude.lastUpdated = now
        claude.spend = UsageSpend(label: "Credits", usedPercent: 53, detail: "$79.71")
        claude.windows = [
            UsageWindow(id: "c5h", label: "5h", usedPercent: 8,
                        resetsAt: now.addingTimeInterval(3.25 * 3_600), windowMinutes: 300),
            UsageWindow(id: "c7d", label: "7d", usedPercent: 43,
                        resetsAt: now.addingTimeInterval(2 * 86_400), windowMinutes: 10_080,
                        isActive: true),
        ]
        claude.buckets = [UsageBucket(id: "cf", label: "Fable", usedPercent: 11)]

        var codex = UsageSource(id: "codex", displayName: "Codex")
        codex.plan = "Pro"
        codex.account = "shingo.imota@gmail.com"
        codex.state = .ok
        codex.lastUpdated = now
        codex.windows = [
            UsageWindow(id: "c1", label: "7d", usedPercent: 56,
                        resetsAt: now.addingTimeInterval(5 * 86_400),
                        windowMinutes: 10_080)
        ]
        codex.windows.append(
            UsageWindow(id: "cs", label: "Spark", usedPercent: 0,
                        resetsAt: now.addingTimeInterval(6 * 86_400), windowMinutes: 10_080))
        codex.note = "2 free resets (first expires 8/1(Fri))"

        var agy = UsageSource(id: "agy", displayName: "Antigravity")
        agy.plan = "Google AI Ultra"
        agy.account = "shingo.imota@gmail.com"
        agy.state = .ok
        agy.lastUpdated = now
        agy.note = "Shared with the desktop app and SDK"
        agy.windows = [
            UsageWindow(id: "a1", label: "Gemini 5h", usedPercent: 2,
                        resetsAt: now.addingTimeInterval(4 * 3_600), windowMinutes: 300),
            UsageWindow(id: "a2", label: "Gemini 7d", usedPercent: 13,
                        resetsAt: now.addingTimeInterval(6 * 86_400), windowMinutes: 10_080),
            UsageWindow(id: "a3", label: "Claude/GPT 5h", usedPercent: 0,
                        resetsAt: now.addingTimeInterval(5 * 3_600), windowMinutes: 300),
            UsageWindow(id: "a4", label: "Claude/GPT 7d", usedPercent: 0,
                        resetsAt: now.addingTimeInterval(7 * 86_400), windowMinutes: 10_080),
        ]

        return [claude, codex, agy]
    }

    /// Exercises the three `SourceCardView` branches `fixture()` never touches:
    /// `.stale`, `.error`, `.unconfigured`. Worst-case on purpose — the longest
    /// window labels ("Claude/GPT 7d") land on the dimmed/stale card, since
    /// dimming and long labels are the two things most likely to fight each
    /// other visually.
    private static func statesFixture() -> [UsageSource] {
        let now = Date()

        var stale = UsageSource(id: "agy", displayName: "Antigravity")
        stale.plan = "Google AI Ultra"
        stale.account = "shingo.imota@gmail.com"
        let staleSince = now.addingTimeInterval(-52 * 60)
        stale.lastUpdated = staleSince
        stale.state = .stale(since: staleSince)
        stale.note = "Shared with the desktop app and SDK"
        stale.windows = [
            UsageWindow(id: "a1", label: "Gemini 5h", usedPercent: 2,
                        resetsAt: now.addingTimeInterval(4 * 3_600), windowMinutes: 300),
            UsageWindow(id: "a2", label: "Gemini 7d", usedPercent: 13,
                        resetsAt: now.addingTimeInterval(6 * 86_400), windowMinutes: 10_080),
            UsageWindow(id: "a3", label: "Claude/GPT 7d", usedPercent: 91,
                        resetsAt: now.addingTimeInterval(7 * 86_400), windowMinutes: 10_080),
        ]

        // The longest realistic failure string a provider is likely to surface,
        // plus a note distinct from the reason: the `.error` branch renders
        // both, and only differing text proves both rows are actually there.
        var errored = UsageSource(id: "codex", displayName: "Codex")
        errored.plan = "Pro"
        errored.account = "shingo.imota@gmail.com"
        errored.state = .error("Rate-limit endpoint returned 503 (Service Unavailable)")
        errored.note = "Retrying automatically every 5 minutes"

        // No note override: this is what checks the `.unconfigured` branch's
        // own fallback text ("Not configured"), not a caller-supplied one.
        let unconfigured = UsageSource(id: "claude", displayName: "Claude Code")

        return [stale, errored, unconfigured]
    }

    /// Squarely-in-band `.caution` and `.warning` (Model.swift's thresholds are
    /// 60/80/95), plus a window 3-7% over pace — comfortably past zero,
    /// comfortably under `Format.overPaceThreshold` (10%). `Severity.escalated`
    /// only ever bumps a window to `.critical`, and only above that 10% line —
    /// there is no longer a mid-tier bump for a merely-positive delta — so the
    /// first two windows sit slightly *under* pace purely for a quiet read (a
    /// hollow marker, nothing to explain), not because pace could otherwise
    /// contaminate their band. The third sits at a `.normal` usedPercent below
    /// the escalation line entirely, so it shows the pace marker's *own* tier:
    /// the shape is the only thing that moves, severity does not.
    private static func severityFixture() -> [UsageSource] {
        let now = Date()

        var caution = UsageSource(id: "claude", displayName: "Claude Code")
        caution.plan = "Max"
        caution.account = "shingo.imota@gmail.com"
        caution.state = .ok
        caution.lastUpdated = now
        caution.windows = [
            // 70% used at 72% elapsed: squarely in Severity's [60, 80) band.
            // Under pace so the marker stays hollow, keeping the read to the
            // header dot and gauge fill alone.
            UsageWindow(id: "cw", label: "7d", usedPercent: 70,
                        resetsAt: now.addingTimeInterval(0.28 * 7 * 86_400), windowMinutes: 10_080),
        ]

        var warning = UsageSource(id: "codex", displayName: "Codex")
        warning.plan = "Pro"
        warning.account = "shingo.imota@gmail.com"
        warning.state = .ok
        warning.lastUpdated = now
        warning.windows = [
            // 87% used at 89% elapsed: squarely in [80, 95), same
            // under-pace treatment as above.
            UsageWindow(id: "ww", label: "7d", usedPercent: 87,
                        resetsAt: now.addingTimeInterval(0.11 * 7 * 86_400), windowMinutes: 10_080),
        ]

        var pacedOnly = UsageSource(id: "agy", displayName: "Antigravity")
        pacedOnly.plan = "Google AI Ultra"
        pacedOnly.account = "shingo.imota@gmail.com"
        pacedOnly.state = .ok
        pacedOnly.lastUpdated = now
        pacedOnly.windows = [
            // 35% used at 30% elapsed: paceDelta = 0.05 — over pace, but well
            // under the 10% escalation threshold, and usedPercent alone (35)
            // is `.normal`. Severity and colour do not move at all here; only
            // the pace marker (filled/red vs hollow/secondary) does.
            UsageWindow(id: "pw", label: "Gemini 5h", usedPercent: 35,
                        resetsAt: now.addingTimeInterval(0.70 * 300 * 60), windowMinutes: 300),
        ]

        return [caution, warning, pacedOnly]
    }

    /// Every window `.normal` (under 60%) *and* on or under pace, so the
    /// summary's "All healthy" branch is reachable and every card matches it:
    /// blue `circle.fill` header, blue gauge fill, hollow pace marker. On pace
    /// is load-bearing here — a `.normal` window that is merely over pace by
    /// under 10% still reads "All healthy" on the summary line (severity does
    /// not move, see `severityFixture()`), but it would show a filled marker
    /// that contradicts "all clear" at a glance, so this fixture avoids that
    /// case deliberately rather than leaving it to chance.
    private static func healthyFixture() -> [UsageSource] {
        let now = Date()

        var claude = UsageSource(id: "claude", displayName: "Claude Code")
        claude.plan = "Max"
        claude.account = "shingo.imota@gmail.com"
        claude.state = .ok
        claude.lastUpdated = now
        claude.spend = UsageSpend(label: "Credits", usedPercent: 28, detail: "$18.40")
        claude.windows = [
            UsageWindow(id: "c5h", label: "5h", usedPercent: 8,
                        resetsAt: now.addingTimeInterval(0.85 * 300 * 60), windowMinutes: 300),
            UsageWindow(id: "c7d", label: "7d", usedPercent: 30,
                        resetsAt: now.addingTimeInterval(0.65 * 10_080 * 60), windowMinutes: 10_080,
                        isActive: true),
        ]

        var codex = UsageSource(id: "codex", displayName: "Codex")
        codex.plan = "Pro"
        codex.account = "shingo.imota@gmail.com"
        codex.state = .ok
        codex.lastUpdated = now
        codex.windows = [
            UsageWindow(id: "cw", label: "7d", usedPercent: 22,
                        resetsAt: now.addingTimeInterval(0.75 * 10_080 * 60), windowMinutes: 10_080),
            UsageWindow(id: "cs", label: "Spark", usedPercent: 0,
                        resetsAt: now.addingTimeInterval(6 * 86_400), windowMinutes: 10_080),
        ]

        var agy = UsageSource(id: "agy", displayName: "Antigravity")
        agy.plan = "Google AI Ultra"
        agy.account = "shingo.imota@gmail.com"
        agy.state = .ok
        agy.lastUpdated = now
        agy.windows = [
            // Reused from `fixture()`: already under pace there, so kept as-is
            // rather than re-derived.
            UsageWindow(id: "a1", label: "Gemini 5h", usedPercent: 2,
                        resetsAt: now.addingTimeInterval(4 * 3_600), windowMinutes: 300),
            UsageWindow(id: "a2", label: "Gemini 7d", usedPercent: 13,
                        resetsAt: now.addingTimeInterval(6 * 86_400), windowMinutes: 10_080),
        ]

        return [claude, codex, agy]
    }

    /// Isolates the summary's other unrendered branch: `severity > .normal`
    /// but `Format.overPace` is nil, i.e. "high but keeping up" — one window
    /// squarely `.caution` (Model.swift's [60, 80)), on pace, with nothing
    /// else on screen at or above it.
    private static func cautionHeadlineFixture() -> [UsageSource] {
        let now = Date()

        var claude = UsageSource(id: "claude", displayName: "Claude Code")
        claude.plan = "Max"
        claude.account = "shingo.imota@gmail.com"
        claude.state = .ok
        claude.lastUpdated = now
        claude.windows = [
            // 70% used at 75% elapsed: the one window driving the headline.
            // `resetsAt` is `now + remaining-fraction * span`, so 75% elapsed
            // means passing 0.25 here, not 0.75 — inverting it once produced a
            // massive over-pace reading (25% elapsed at 70% used) that
            // escalated this straight to `.critical` instead of `.caution`.
            UsageWindow(id: "cw", label: "7d", usedPercent: 70,
                        resetsAt: now.addingTimeInterval(0.25 * 10_080 * 60), windowMinutes: 10_080),
        ]

        var codex = UsageSource(id: "codex", displayName: "Codex")
        codex.plan = "Pro"
        codex.account = "shingo.imota@gmail.com"
        codex.state = .ok
        codex.lastUpdated = now
        codex.windows = [
            UsageWindow(id: "cxw", label: "7d", usedPercent: 25,
                        resetsAt: now.addingTimeInterval(0.70 * 10_080 * 60), windowMinutes: 10_080),
        ]

        var agy = UsageSource(id: "agy", displayName: "Antigravity")
        agy.plan = "Google AI Ultra"
        agy.account = "shingo.imota@gmail.com"
        agy.state = .ok
        agy.lastUpdated = now
        agy.windows = [
            UsageWindow(id: "aw", label: "Gemini 7d", usedPercent: 10,
                        resetsAt: now.addingTimeInterval(6 * 86_400), windowMinutes: 10_080),
        ]

        return [claude, codex, agy]
    }
}
