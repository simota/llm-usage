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
}

// MARK: - Gauge

/// Track + fill + pace tick. The tick is what makes over-consumption legible
/// without doing arithmetic in your head (docs/design.md §4).
struct GaugeView: View {
    let usedPercent: Double
    let elapsedFraction: Double?
    let height: CGFloat
    let dimmed: Bool

    private var severity: Severity { Severity(usedPercent: usedPercent) }

    private var overPace: Bool {
        guard let elapsedFraction else { return false }
        return usedPercent / 100 > elapsedFraction
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(severity.color)
                    .frame(width: geo.size.width * clamp(usedPercent / 100))
                if let elapsedFraction {
                    // Needs to stay legible against the track even when nothing
                    // is filled yet, so this is a foreground tone, not .secondary.
                    Rectangle()
                        .fill(overPace ? Color.red : Color.primary.opacity(0.55))
                        .frame(width: 2, height: height + 5)
                        .offset(x: geo.size.width * clamp(elapsedFraction) - 1)
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
        .opacity(dimmed ? 0.4 : 1)
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: Layout.labelColumn, alignment: .leading)

            GaugeView(usedPercent: usedPercent, elapsedFraction: elapsedFraction,
                      height: height, dimmed: dimmed)

            Text(Format.percent(usedPercent))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(deemphasised ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
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
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

struct WindowRow: View {
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

            // The pace tick alone does not say what it means; spell it out on the
            // one row where it matters (docs/design.md §4).
            if let pace = Format.overPace(window) {
                Label(pace, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.leading, Layout.labelColumn + Layout.rowSpacing)
            }
        }
    }
}

/// A window at zero does not need a gauge, a percentage and a reset time to say
/// "you have not touched this".
struct UnusedWindowRow: View {
    let window: UsageWindow

    var body: some View {
        HStack(spacing: Layout.rowSpacing) {
            Text(window.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: Layout.labelColumn, alignment: .leading)
            Text("unused")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 18)
    }
}

struct SpendRow: View {
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
    }
}

// MARK: - Card

struct SourceCardView: View {
    let source: UsageSource
    @State private var expanded = false

    private var state: SourceState { source.agedState() }

    /// Only Claude reports `is_active`; without it every figure stays primary.
    private var reportsActivity: Bool { source.windows.contains(where: \.isActive) }

    private var dimmed: Bool {
        if case .stale = state { return true }
        return false
    }

    private var dotFilled: Bool {
        if case .ok = state { return true }
        return false
    }

    private var dotColor: Color {
        switch state {
        case .ok: return Severity(usedPercent: source.worstWindow?.usedPercent ?? 0).color
        case .stale, .error, .unconfigured: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            header

            // Each source authenticates separately, so which login is being
            // metered is worth stating even when they all happen to match.
            if let account = source.account {
                Text(account)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, -3)
            }

            switch state {
            case .unconfigured:
                // The note is the instruction ("statusline hook not configured"), so
                // dropping it left the card saying nothing actionable.
                caption(source.note ?? "Not configured")

            case .error(let reason):
                caption(reason)
                if let note = source.note, note != reason { caption(note) }

            case .ok, .stale:
                ForEach(Array(source.windows.enumerated()), id: \.element.id) { index, window in
                    if window.isUnused {
                        UnusedWindowRow(window: window)
                    } else {
                        WindowRow(window: window, isPrimary: index == 0, dimmed: dimmed,
                                  deemphasised: reportsActivity && !window.isActive)
                    }
                }
                if let spend = source.spend {
                    SpendRow(spend: spend, dimmed: dimmed)
                }
                if case .stale(let since) = state {
                    caption("as of \(Format.relative(since))")
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
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: dotFilled ? "diamond.fill" : "diamond")
                .font(.system(size: 9))
                .foregroundStyle(dotColor)
            Text(source.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            if let plan = source.plan {
                // Provider-supplied and can be long ("Google AI Ultra"); never
                // let it push the name around.
                Text(plan)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(-1)
            }
        }
    }

    private var bucketDisclosure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Label("By model (\(source.meaningfulBuckets.count))",
                      systemImage: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(source.meaningfulBuckets) { bucket in
                    HStack(spacing: Layout.rowSpacing) {
                        Text(bucket.label)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .frame(width: 120, alignment: .leading)
                        Spacer(minLength: 0)
                        Text(Format.percent(bucket.usedPercent))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var store: UsageStore

    /// The conclusion, stated once, before any of the detail below it.
    private var summaryHeader: some View {
        let summary = store.summary
        return HStack(spacing: 5) {
            if summary.isWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(summary.severity.color)
            }
            Text(summary.text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            summaryHeader

            ForEach(Array(store.sources.enumerated()), id: \.element.id) { index, source in
                if index > 0 { Divider() }
                SourceCardView(source: source)
            }

            Divider()

            HStack(spacing: 14) {
                Button("Refresh") { store.refreshAll() }
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.relative(store.lastRefreshed))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            // Accent-coloured .plain rather than .buttonStyle(.link): the link
            // style does not survive offscreen rendering, so it cannot be checked
            // by --panel. This reads as actionable and is verifiable.
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .font(.system(size: 11))
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
