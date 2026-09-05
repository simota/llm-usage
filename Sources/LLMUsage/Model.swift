import Foundation

// MARK: - Normalised model
//
// Every provider maps onto these types so the views only ever render one shape.
// See docs/design.md §11.

/// One rate-limit window (Codex weekly, Claude 5h/7d, an agy group bucket, …).
struct UsageWindow: Identifiable, Sendable, Equatable {
    let id: String
    /// Short column label: "5h", "7d", "Gemini 5h".
    let label: String
    /// 0...100. Providers that report *remaining* invert before constructing this.
    let usedPercent: Double
    let resetsAt: Date?
    let windowMinutes: Int?
    /// The window currently doing the metering, where the source tells us
    /// (Claude's `is_active`). Used to break ties when picking what binds.
    var isActive: Bool = false

    var isUnused: Bool { usedPercent < 0.5 }

    /// Linear extrapolation to the end of the window: >100 means the limit
    /// arrives before the reset does. Compare exhaustion dates across durations.
    func projectedPercent(now: Date = Date()) -> Double {
        guard let elapsed = elapsedFraction(now: now), elapsed >= 0.1 else { return usedPercent }
        return min(usedPercent / elapsed, 999)
    }

    /// When the current burn rate reaches 100%, if that happens before the
    /// window resets. nil means the allowance outlasts the window.
    func projectedExhaustion(now: Date = Date()) -> Date? {
        if usedPercent >= 100 { return now }
        guard let resetsAt, let windowMinutes, windowMinutes > 0,
              resetsAt > now,
              let elapsed = elapsedFraction(now: now), elapsed >= 0.1,
              usedPercent > 0 else { return nil }

        let rate = usedPercent / elapsed          // percent consumed per whole window
        guard rate > 100 else { return nil }      // finishes the window inside the limit

        let fractionAtLimit = 100 / rate
        guard fractionAtLimit > elapsed else { return nil }  // already over

        let span = Double(windowMinutes) * 60
        return resetsAt.addingTimeInterval(-span).addingTimeInterval(fractionAtLimit * span)
    }

    func exhaustsBefore(_ other: UsageWindow, now: Date) -> Bool {
        let first = projectedExhaustion(now: now) ?? .distantFuture
        let second = other.projectedExhaustion(now: now) ?? .distantFuture
        if first != second { return first < second }
        if isActive != other.isActive { return isActive }
        if usedPercent != other.usedPercent { return usedPercent > other.usedPercent }
        return id < other.id
    }

    var displayedSeverity: Severity { displayedSeverity(now: Date()) }

    func displayedSeverity(now: Date) -> Severity {
        Severity.escalated(Severity(usedPercent: usedPercent), paceDelta: paceDelta(now: now))
    }

    /// Where the pace tick sits: how far through the window we are, 0...1.
    /// nil when the window length or reset time is unknown.
    func elapsedFraction(now: Date = Date()) -> Double? {
        guard let resetsAt, let windowMinutes, windowMinutes > 0 else { return nil }
        let span = Double(windowMinutes) * 60
        let start = resetsAt.addingTimeInterval(-span)
        return min(max(now.timeIntervalSince(start) / span, 0), 1)
    }

    /// Positive means consuming faster than the window refills. See docs/design.md §4.
    func paceDelta(now: Date = Date()) -> Double? {
        guard let elapsed = elapsedFraction(now: now) else { return nil }
        return usedPercent / 100 - elapsed
    }
}

/// A finer-grained bucket shown only when a card is expanded (Codex per-model limits).
struct UsageBucket: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let usedPercent: Double
}

/// A spending allowance rather than a rate-limit window: no reset, no pace.
/// Rendered as a gauge row so it can be compared against the windows above it.
struct UsageSpend: Sendable, Equatable {
    let label: String
    let usedPercent: Double
    /// Right-hand column, e.g. "$79.71".
    let detail: String
}

enum SourceState: Sendable, Equatable {
    case ok
    case stale(since: Date)
    case error(String)
    case unconfigured
}

struct UsageSource: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    var plan: String?
    /// Which login this source is metering. Sources authenticate separately, so
    /// these can legitimately differ from each other.
    var account: String?
    var windows: [UsageWindow] = []
    var buckets: [UsageBucket] = []
    var spend: UsageSpend?
    var note: String?
    var lastUpdated: Date?
    var state: SourceState = .unconfigured
    /// How long a value may sit before it reads as stale. Per-source, see docs/design.md §6.
    var staleAfter: TimeInterval = 900

    /// The window driving this card's colour — the most consumed one.
    var worstWindow: UsageWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    /// Buckets worth a disclosure row.
    ///
    /// Whether a bucket merely restates a headline is a question about meaning,
    /// not about numbers, so each provider drops its own redundant buckets before
    /// they get here. Comparing values instead made unrelated pairs collide —
    /// Claude's Fable bucket vanished for happening to match its 5h window.
    var meaningfulBuckets: [UsageBucket] {
        buckets.contains { $0.usedPercent >= 0.5 } ? buckets : []
    }

    /// Re-evaluates `.ok` against `staleAfter`. Errors and placeholders are left alone.
    func agedState(now: Date = Date()) -> SourceState {
        guard case .ok = state, let lastUpdated else { return state }
        let rolledOver = windows.contains { window in
            guard let reset = window.resetsAt else { return false }
            return reset <= now && lastUpdated < reset
        }
        return now.timeIntervalSince(lastUpdated) > staleAfter || rolledOver
            ? .stale(since: lastUpdated)
            : .ok
    }

    func hasCurrentData(now: Date = Date()) -> Bool {
        lastUpdated != nil && !windows.isEmpty && agedState(now: now) == .ok
    }

    static func placeholder(id: String, name: String) -> UsageSource {
        UsageSource(id: id, displayName: name, state: .unconfigured)
    }
}

// MARK: - Severity

enum Severity: Int, Sendable, Comparable {
    case normal, caution, warning, critical

    init(usedPercent: Double) {
        switch usedPercent {
        case ..<60: self = .normal
        case ..<80: self = .caution
        case ..<95: self = .warning
        default: self = .critical
        }
    }

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    static func escalated(_ base: Severity, paceDelta: Double?) -> Severity {
        guard let paceDelta, paceDelta > Format.overPaceThreshold else { return base }
        return Swift.max(base, .critical)
    }
}

// MARK: - Formatting

enum Format {
    /// Over this, a window is called out as burning too fast.
    static let overPaceThreshold = 0.10

    // Pinned to English rather than Locale.current: the rest of the panel is
    // English, and a system locale of ja_JP otherwise rendered "8/1(土)" next to
    // "in 3h14m" in the same column.
    private static let displayLocale = Locale(identifier: "en_US")

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = displayLocale
        f.setLocalizedDateFormatFromTemplate("Md")
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = displayLocale
        f.setLocalizedDateFormatFromTemplate("E")
        return f
    }()

    /// docs/design.md §5 — "in 48m" / "in 3h08m" / "8/6(Thu)" / "now".
    ///
    /// Beyond a day, "in 6d" is too coarse to plan around; the calendar day is
    /// what you actually need in order to know when the allowance comes back.
    ///
    /// The "in " prefix is what lets this drop into prose ("next reset in 48m")
    /// as well as into the reset column.
    static func resetsIn(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "now" }
        if s < 3600 { return "in \(Int(s / 60))m" }
        if s < 86_400 {
            let h = Int(s) / 3600
            let m = (Int(s) % 3600) / 60
            return String(format: "in %dh%02dm", h, m)
        }
        return "\(dayFormatter.string(from: date))(\(weekdayFormatter.string(from: date)))"
    }

    /// "+38% over pace", or nil when the window is keeping up.
    static func overPace(_ window: UsageWindow, now: Date = Date()) -> String? {
        guard let delta = window.paceDelta(now: now), delta > overPaceThreshold else { return nil }
        return "+\(Int((delta * 100).rounded()))% over pace"
    }

    /// "maxes out 7/31(Thu) at this pace" — the actionable form of over-pace.
    /// A percentage tells you something is wrong; a date tells you when.
    static func exhaustion(_ window: UsageWindow, now: Date = Date()) -> String? {
        guard let exhaustsAt = window.projectedExhaustion(now: now) else { return nil }
        let s = exhaustsAt.timeIntervalSince(now)
        let when = s < 86_400
            ? resetsIn(exhaustsAt, now: now)
            : "\(dayFormatter.string(from: exhaustsAt))(\(weekdayFormatter.string(from: exhaustsAt)))"
        return "maxes out \(when) at this pace"
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "\(Int(s))s ago" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86_400))d ago"
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
