import SwiftUI

// MARK: - Layout constants (docs/design.md §9)

enum Layout {
    static let panelWidth: CGFloat = 320
    static let padding: CGFloat = 12
    static let cardSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 6
    static let gaugeHeightPrimary: CGFloat = 6
    static let gaugeHeightSecondary: CGFloat = 4
    // Everything except the gauge is fixed; the gauge absorbs the remainder.
    // Sizing it explicitly is what overflowed the panel before — with a flexible
    // gauge the columns still line up but the row can no longer exceed the width.
    // Widest label is agy's "Claude/GPT 7d"; anything narrower ellipsises it
    // even at the minimum scale factor.
    static let labelColumn: CGFloat = 72
    static let percentColumn: CGFloat = 44
    static let resetColumn: CGFloat = 56
    static let sectionSpacing: CGFloat = 14
    static let rowMinHeight: CGFloat = 22
    /// One value where there used to be three (0.7 / 0.75 / 0.8) for the same
    /// job. The loosest is the one kept: "Claude/GPT 7d" needs all of it.
    static let minimumScale: CGFloat = 0.7
    /// WCAG 2.5.8. Controls that carry no native chrome reach it with padding
    /// plus an explicit `contentShape`.
    static let hitTarget: CGFloat = 24
    /// The pace marker's box. The glyph centres inside it, so the marker stays
    /// on the elapsed position whatever text size the system is set to.
    static let paceMarker: CGFloat = 9
    /// Holds the widest legend run — four severity glyphs — without pushing the
    /// explanation text out of a 320pt panel.
    static let legendSymbolColumn: CGFloat = 52
}

extension Severity {
    var color: Color {
        switch self {
        case .normal: return .accentColor
        case .caution: return .yellow
        case .warning: return .orange
        case .critical: return .red
        }
    }

    /// Shape, not hue, is what has to survive greyscale and colour blindness, so
    /// every level gets its own symbol and the colour only reinforces it.
    ///
    /// Round / square / triangular / polygonal — four silhouettes rather than
    /// four hues. Caution is the square and not `exclamationmark.circle.fill`
    /// because at 12pt that one and the octagon are the same blob.
    var symbolName: String {
        switch self {
        case .normal: return "circle.fill"
        case .caution: return "exclamationmark.square.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    /// The same four silhouettes with the fill taken out, for a figure that is
    /// no longer current. Outline already means "we cannot vouch for this"
    /// everywhere else in the panel, so the level survives without the mark
    /// claiming the number still holds.
    var lastKnownSymbolName: String {
        switch self {
        case .normal: return "circle"
        case .caution: return "exclamationmark.square"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon"
        }
    }

}

// MARK: - Spoken forms
//
// The visible strings are written for a 320pt column ("7d", "8/2(Sun)"), which
// VoiceOver reads as letters and punctuation. The accessibility layer restates
// them in words rather than widening what is drawn.

enum Spoken {
    static func windowLabel(_ label: String) -> String {
        var parts = label.split(separator: " ").map(String.init)
        guard let last = parts.last, let unit = last.last,
              let count = Int(last.dropLast()) else { return label }
        let word: String
        switch unit {
        case "h": word = "hour"
        case "d": word = "day"
        case "m": word = "minute"
        default: return label
        }
        parts[parts.count - 1] = "\(count) \(word) window"
        return parts.joined(separator: " ")
    }

    static func resets(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "no reset time" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "resetting now" }
        if seconds < 60 { return "resets in under a minute" }
        if seconds < 3600 { return "resets in \(Int(seconds / 60)) minutes" }
        if seconds < 86_400 {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            return "resets in \(h) hours \(m) minutes"
        }
        // Matches Format's deliberate en_US pinning rather than the system locale.
        let style = Date.FormatStyle(date: .complete, time: .omitted)
            .locale(Locale(identifier: "en_US"))
        return "resets \(date.formatted(style))"
    }

    static func pace(_ delta: Double?) -> String? {
        guard let delta else { return nil }
        return delta > 0
            ? "over pace by \(Int((delta * 100).rounded())) percent"
            : "on pace"
    }
}

// MARK: - Gauge

/// Track + fill + pace marker. The marker is what makes over-consumption legible
/// without doing arithmetic in your head (docs/design.md §4).
struct GaugeView: View {
    let usedPercent: Double
    let elapsedFraction: Double?
    let height: CGFloat
    let dimmed: Bool

    private var paceDelta: Double? {
        guard let elapsedFraction else { return nil }
        return usedPercent / 100 - elapsedFraction
    }

    /// The marker's own tier: any positive delta at all.
    private var overPace: Bool { (paceDelta ?? 0) > 0 }

    /// The same escalation the card header uses, so the bar and the mark above
    /// it cannot make different claims about the same window.
    private var severity: Severity {
        Severity.escalated(Severity(usedPercent: usedPercent), paceDelta: paceDelta)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(severity.color)
                    .frame(width: geo.size.width * clamp(usedPercent / 100))
                if let elapsedFraction {
                    // This was a 2pt rectangle told apart from "keeping up" only
                    // by hue. Hollow versus filled says the same thing in shape,
                    // and sitting above the track rather than inside it, it is
                    // measured against the panel background instead of a 1.24:1
                    // track.
                    Image(systemName: overPace ? "arrowtriangle.down.fill" : "arrowtriangle.down")
                        .font(.caption2)
                        .foregroundStyle(overPace ? Color.red : Color.secondary)
                        .frame(width: Layout.paceMarker, height: Layout.paceMarker)
                        .offset(x: geo.size.width * clamp(elapsedFraction) - Layout.paceMarker / 2,
                                y: -(height / 2 + Layout.paceMarker / 2 - 1))
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
        .opacity(dimmed ? 0.4 : 1)
        // Decorative: the row states the same figures in its accessibility value.
        .accessibilityHidden(true)
    }

    private func clamp(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }
}

// MARK: - Window row

/// The shared column skeleton: label · gauge · percent · trailing.
/// Windows, unused windows and the spend line all use it so the columns line up.
private struct MeterRow<Trailing: View>: View {
    let label: String
    /// Set on windows the source is *not* currently metering, when it tells us
    /// which one it is. A glyph in the label column crowded it and shrank the
    /// text; carrying it in the figure's weight costs no layout at all.
    let deemphasised: Bool
    let usedPercent: Double
    let elapsedFraction: Double?
    let height: CGFloat
    let dimmed: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Layout.rowSpacing) {
            // agy labels carry a group name ("Claude/GPT 7d") and do not fit at
            // full size; shrink rather than truncate.
            Text(label)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(Layout.minimumScale)
                .frame(width: Layout.labelColumn, alignment: .leading)

            GaugeView(usedPercent: usedPercent, elapsedFraction: elapsedFraction,
                      height: height, dimmed: dimmed)

            // De-emphasis rides on weight rather than on a faded fill: the
            // figure is the row's whole point, so it may not drop below 4.5:1
            // to say "this is not the window doing the metering".
            Text(Format.percent(usedPercent))
                .font(.body.weight(deemphasised ? .regular : .semibold).monospacedDigit())
                .frame(width: Layout.percentColumn, alignment: .trailing)

            trailing()
                .frame(width: Layout.resetColumn, alignment: .trailing)
        }
        .frame(minHeight: Layout.rowMinHeight)
    }
}

private struct TrailingText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(Layout.minimumScale)
    }
}

struct WindowRow: View {
    /// Only so VoiceOver can say which card a row belongs to; nothing is drawn
    /// from it.
    let sourceName: String
    let window: UsageWindow
    let isPrimary: Bool
    let dimmed: Bool
    /// True only when the source reports which window is metering, so sources
    /// that never report it keep every figure at full weight.
    let deemphasised: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MeterRow(label: window.label,
                     deemphasised: deemphasised,
                     usedPercent: window.usedPercent,
                     elapsedFraction: window.elapsedFraction(),
                     height: isPrimary ? Layout.gaugeHeightPrimary : Layout.gaugeHeightSecondary,
                     dimmed: dimmed) {
                TrailingText(text: Format.resetsIn(window.resetsAt))
            }

            // The marker alone does not say what it means; spell it out on the
            // one row where it matters (docs/design.md §4). The symbol carries
            // the alarm, which is what lets the sentence itself be `.primary`
            // and clear 4.5:1 instead of sitting at red-on-white 3.33:1.
            if let pace = Format.overPace(window) {
                Label {
                    Text(pace)
                } icon: {
                    Image(systemName: Severity.critical.symbolName)
                        .foregroundStyle(Color.red)
                }
                .font(.footnote.weight(.medium))
                .padding(.leading, Layout.labelColumn + Layout.rowSpacing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sourceName), \(Spoken.windowLabel(window.label))")
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: String {
        var parts = ["\(Format.percent(window.usedPercent)) used",
                     Spoken.resets(window.resetsAt)]
        if let pace = Spoken.pace(window.paceDelta()) { parts.append(pace) }
        if deemphasised { parts.append("not the metering window") }
        return parts.joined(separator: ", ")
    }
}

/// A window at zero does not need a gauge, a percentage and a reset time to say
/// "you have not touched this".
struct UnusedWindowRow: View {
    let sourceName: String
    let window: UsageWindow

    var body: some View {
        HStack(spacing: Layout.rowSpacing) {
            Text(window.label)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(Layout.minimumScale)
                .frame(width: Layout.labelColumn, alignment: .leading)
            Text("unused")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sourceName), \(Spoken.windowLabel(window.label))")
        .accessibilityValue("unused")
    }
}

struct SpendRow: View {
    let sourceName: String
    let spend: UsageSpend
    let dimmed: Bool

    var body: some View {
        MeterRow(label: spend.label, deemphasised: false,
                 usedPercent: spend.usedPercent,
                 elapsedFraction: nil,
                 height: Layout.gaugeHeightSecondary,
                 dimmed: dimmed) {
            TrailingText(text: spend.detail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sourceName), \(spend.label)")
        .accessibilityValue("\(Format.percent(spend.usedPercent)) used, \(spend.detail)")
    }
}

// MARK: - Card

struct SourceCardView: View {
    let source: UsageSource
    let onRetry: () -> Void
    @State private var expanded = false

    private var state: SourceState { source.agedState() }

    /// Only Claude reports `is_active`; without it every figure stays primary.
    private var reportsActivity: Bool { source.windows.contains(where: \.isActive) }

    private var dimmed: Bool {
        if case .stale = state { return true }
        return false
    }

    /// The worst pace on the card — the same number the gauge markers use, not a
    /// second calculation.
    private var paceDelta: Double? {
        source.windows.compactMap { $0.paceDelta() }.max()
    }

    /// The worst of what this card's own rows show. It used to combine one
    /// window's consumption with a different window's pace, which is how a card
    /// could out-rank or under-rank every row inside it.
    ///
    /// The headline's window always belongs to some card's `windows`, so this is
    /// necessarily ≥ the headline severity for the card it names — which is why
    /// no separate highlight has to be passed in.
    private var severity: Severity {
        source.windows.map(\.displayedSeverity).max() ?? .normal
    }

    /// `.ok` takes the filled severity shapes; the three no-data states take
    /// outline ones, because "we cannot tell you" is not a severity.
    private var statusSymbol: String {
        switch state {
        case .ok: return severity.symbolName
        case .stale: return "clock"
        case .error: return "xmark.octagon"
        case .unconfigured: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        if case .ok = state { return severity.color }
        return .secondary
    }

    /// A stale or failed card still knows what it last saw, and dropping that
    /// let the headline name a severity the card never showed.
    ///
    /// The state symbol keeps saying "do not read this as current"; this second
    /// mark says what the figure was, in the same four silhouettes, one fill-step
    /// down. Outline is already this panel's word for "not current", so the level
    /// survives greyscale without the mark asserting the number still holds.
    /// Nothing is added below `.caution`, so a quiet stale card stays one clock.
    private var lastKnownSymbol: String? {
        if case .ok = state { return nil }
        guard severity > .normal else { return nil }
        return severity.lastKnownSymbolName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            header

            // Each source authenticates separately, so which login is being
            // metered is worth stating even when they all happen to match.
            if let account = source.account {
                Text(account)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, -3)
                    .accessibilityLabel("Account, \(account)")
            }

            switch state {
            case .unconfigured:
                // The note is the instruction ("statusline hook not configured"), so
                // dropping it left the card saying nothing actionable.
                caption(source.note ?? "Not configured")

            case .error(let reason):
                caption(reason)
                if let note = source.note, note != reason { caption(note) }
                // The card named what broke and offered nothing to do about it.
                // There is no per-source refresh, so this is the panel-wide one.
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Retry, refreshes every source")

            case .ok, .stale:
                ForEach(Array(source.windows.enumerated()), id: \.element.id) { index, window in
                    if window.isUnused {
                        UnusedWindowRow(sourceName: source.displayName, window: window)
                    } else {
                        WindowRow(sourceName: source.displayName, window: window,
                                  isPrimary: index == 0, dimmed: dimmed,
                                  deemphasised: reportsActivity && !window.isActive)
                    }
                }
                if let spend = source.spend {
                    SpendRow(sourceName: source.displayName, spend: spend, dimmed: dimmed)
                }
                if case .stale(let since) = state {
                    Label("Last known · \(Format.relative(since))", systemImage: "clock")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Before the disclosure: placed after, it read as the collapsed
                // section's contents.
                if let note = source.note { caption(note) }
                if !source.meaningfulBuckets.isEmpty {
                    bucketDisclosure
                }
            }
        }
        // No card fill: at .quaternary it was neither a surface nor absent, and
        // macOS panels of this kind separate by spacing rather than by stacking
        // planes.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                if let lastKnownSymbol {
                    Image(systemName: lastKnownSymbol)
                        .foregroundStyle(severity.color)
                }
            }
            .font(.callout)
            Text(source.displayName)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let plan = source.plan {
                // Provider-supplied and can be long ("Google AI Ultra"); never
                // let it push the name around.
                Text(plan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(Layout.minimumScale)
                    .layoutPriority(-1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(source.displayName)
        .accessibilityValue(spokenState)
    }

    private var spokenState: String {
        switch state {
        case .ok:
            var parts: [String] = []
            if let worst = source.worstWindow {
                parts.append("worst window \(Format.percent(worst.usedPercent)) used")
            }
            if let delta = paceDelta, delta > 0, let pace = Spoken.pace(delta) {
                parts.append(pace)
            }
            if let plan = source.plan { parts.append("plan \(plan)") }
            return parts.isEmpty ? "no data yet" : parts.joined(separator: ", ")
        case .stale(let since):
            return "stale, last updated \(Format.relative(since))\(lastKnownPhrase)"
        case .error(let reason):
            return "error, \(reason)\(lastKnownPhrase)"
        case .unconfigured:
            return "not configured"
        }
    }

    /// The spoken half of `lastKnownSymbol`. "Last known" is doing the same job
    /// the outline does visually — naming the figure without vouching for it.
    private var lastKnownPhrase: String {
        guard lastKnownSymbol != nil, let worst = source.worstWindow else { return "" }
        var phrase = ", last known \(Format.percent(worst.usedPercent)) used"
        if let delta = paceDelta, delta > Format.overPaceThreshold { phrase += ", over pace" }
        return phrase
    }

    private var bucketDisclosure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Label("By model (\(source.meaningfulBuckets.count))",
                      systemImage: expanded ? "chevron.up" : "chevron.down")
                    .font(.subheadline)
                    .frame(minHeight: Layout.hitTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("By model, \(source.meaningfulBuckets.count) entries")
            .accessibilityValue(expanded ? "expanded" : "collapsed")

            if expanded {
                ForEach(source.meaningfulBuckets) { bucket in
                    HStack(spacing: Layout.rowSpacing) {
                        Text(bucket.label)
                            .font(.subheadline)
                            .lineLimit(1)
                            .frame(width: 120, alignment: .leading)
                        Spacer(minLength: 0)
                        Text(Format.percent(bucket.usedPercent))
                            .font(.subheadline.monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(bucket.label)
                    .accessibilityValue("\(Format.percent(bucket.usedPercent)) used")
                }
            }
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var store: UsageStore
    @State private var legendExpanded = false

    /// The conclusion, stated once, before any of the detail below it.
    private var summaryHeader: some View {
        let summary = store.summary
        return HStack(spacing: 5) {
            if summary.isWarning {
                Image(systemName: summary.severity.symbolName)
                    .font(.callout)
                    .foregroundStyle(summary.severity.color)
            }
            Text(summary.text)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(Layout.minimumScale)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Summary")
        .accessibilityValue(summary.text.replacingOccurrences(of: "·", with: ","))
    }

    /// Nothing in the panel says what a hollow triangle over a bar means, so a
    /// first run cannot learn it. A standing legend line would spend height on
    /// every launch for something you read once; this is the system's own
    /// "explain this" affordance instead, and it costs nothing until asked.
    ///
    /// It is a real Button, so VoiceOver reaches it in reading order and the
    /// rows it opens are ordinary text. `.help()` is layered on for the pointer
    /// in addition to that, never instead of it.
    private var legendToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { legendExpanded.toggle() }
        } label: {
            Image(systemName: "questionmark.circle")
                .frame(minWidth: Layout.hitTarget, minHeight: Layout.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("What the marks mean")
        .accessibilityLabel("What the marks mean")
        .accessibilityValue(legendExpanded ? "expanded" : "collapsed")
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            legendRow(
                symbols: ["arrowtriangle.down", "arrowtriangle.down.fill"],
                text: "Pace marker: how far into the window you are. Filled means you have already used more than that.",
                spoken: "Hollow and filled triangle. Pace marker: how far into the window you are. Filled means you have already used more than that.")
            legendRow(
                symbols: [Severity.normal, .caution, .warning, .critical].map(\.symbolName),
                text: "Card mark: under 60%, then 60%, 80%, 95% used — or over pace.",
                spoken: "Circle, square, triangle, octagon. Card mark: under 60 percent, then 60, 80 and 95 percent used, or over pace.")
            legendRow(
                symbols: ["clock", "xmark.octagon", "circle.dashed"],
                text: "Outlines: the figures are stale, the fetch failed, or the source is not set up.",
                spoken: "Clock, crossed octagon, dashed circle. Outlines: the figures are stale, the fetch failed, or the source is not set up.")
        }
    }

    private func legendRow(symbols: [String], text: String, spoken: String) -> some View {
        HStack(alignment: .top, spacing: Layout.rowSpacing) {
            HStack(spacing: 2) {
                ForEach(symbols, id: \.self) { Image(systemName: $0) }
            }
            .frame(width: Layout.legendSymbolColumn, alignment: .leading)

            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            summaryHeader

            ForEach(Array(store.sources.enumerated()), id: \.element.id) { index, source in
                if index > 0 { Divider() }
                // No highlight is passed down: a card's own severity is the max
                // over its windows, and the headline's window is one of them, so
                // the card it names already ranks at least as high.
                SourceCardView(source: source, onRetry: { store.refreshAll() })
            }

            Divider()

            if legendExpanded { legend }

            HStack(spacing: Layout.rowSpacing) {
                Button("Refresh") { store.refreshAll() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("r", modifiers: .command)
                    .accessibilityLabel("Refresh every source")

                legendToggle

                Spacer(minLength: Layout.rowSpacing)

                Text(Format.relative(store.lastRefreshed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Last successful sample")
                    .accessibilityLabel("Last successful sample \(Format.relative(store.lastRefreshed))")

                // Quit used to sit beside Refresh at identical weight. It is the
                // destructive one and there is no confirm step, so it gets the
                // opposite end of the row and no button chrome — separation by
                // position and chrome rather than by fading a control label to
                // 3.9:1.
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit")
                        .padding(.horizontal, Layout.rowSpacing)
                        .frame(minHeight: Layout.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quit LLM Usage")
            }
            .font(.subheadline)
        }
        .padding(Layout.padding)
        .frame(width: Layout.panelWidth)
    }
}

// MARK: - Menu bar label

/// A+B hybrid (docs/design.md §2): three mini gauges normally, a single worst-source
/// figure once anything crosses the warning threshold.
///
/// The artwork is drawn in `MenuBarIcon` rather than composed here — SwiftUI shapes
/// placed directly in a `MenuBarExtra` label do not render.
struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Image(nsImage: MenuBarIcon.image(
            sources: store.sources,
            worst: store.worst,
            showsWorstFigure: store.showsWorstFigure))
    }
}
