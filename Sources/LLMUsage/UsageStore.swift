import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    typealias Update = @Sendable (Result<UsageSource, Error>, String) -> Void
    typealias ProviderFactory = (@escaping Update) -> [UsageProviding]

    @Published private(set) var sources: [UsageSource]
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var lastRefreshAttempt: Date?
    @Published private(set) var showsWorstFigure = false

    private let makeProviders: ProviderFactory
    private let now: () -> Date
    private var providers: [UsageProviding] = []
    private var tick: Timer?
    private(set) var isStarted = false
    private var generation = 0
    private var lastResetRefresh: Date?

    init(sources: [UsageSource]? = nil, now: @escaping () -> Date = Date.init,
         makeProviders: @escaping ProviderFactory = UsageStore.defaultProviders) {
        self.sources = sources ?? [
            .placeholder(id: "claude", name: "Claude Code"),
            .placeholder(id: "codex", name: "Codex"),
            .placeholder(id: "agy", name: "Antigravity"),
        ]
        self.now = now
        self.makeProviders = makeProviders
        lastRefreshed = self.sources.compactMap(\.lastUpdated).max()
        applyHysteresis()
    }

    private var currentSources: [UsageSource] {
        let date = now()
        return sources.filter { $0.hasCurrentData(now: date) }
    }

    private var currentWindows: [(source: UsageSource, window: UsageWindow)] {
        currentSources.flatMap { source in source.windows.map { (source, $0) } }
    }

    var worst: UsageWindow? {
        currentSources.compactMap(\.worstWindow).max { $0.usedPercent < $1.usedPercent }
    }

    /// The earliest predicted limit; raw consumption breaks ties without a prediction.
    var binding: (source: UsageSource, window: UsageWindow)? {
        let date = now()
        return currentWindows.min { $0.window.exhaustsBefore($1.window, now: date) }
    }

    /// Severity determines the subject; equally severe limits use exhaustion time.
    var headline: (source: UsageSource, window: UsageWindow)? {
        let date = now()
        return currentWindows.min { a, b in
            let sa = a.window.displayedSeverity(now: date)
            let sb = b.window.displayedSeverity(now: date)
            if sa != sb { return sa > sb }
            return a.window.exhaustsBefore(b.window, now: date)
        }
    }

    struct Summary {
        let text: String
        let severity: Severity
        let isWarning: Bool
    }

    var summary: Summary {
        let date = now()
        let unavailable = sources.count - currentSources.count
        guard let (source, window) = headline else {
            return Summary(text: "No current data", severity: .normal, isWarning: false)
        }
        let suffix = unavailable > 0 ? " · \(unavailable) unavailable" : ""
        let severity = window.displayedSeverity(now: date)
        let head = "\(source.displayName) \(window.label) \(Format.percent(window.usedPercent))"
        if let overPace = Format.overPace(window, now: date) {
            return Summary(text: "\(head) · \(Format.exhaustion(window, now: date) ?? overPace)\(suffix)",
                           severity: severity, isWarning: true)
        }
        if severity > .normal {
            return Summary(text: "\(head) · \(Format.resetsIn(window.resetsAt, now: date))\(suffix)",
                           severity: severity, isWarning: true)
        }
        if unavailable > 0 {
            return Summary(text: "Current data healthy\(suffix)", severity: .normal, isWarning: false)
        }
        let nearest = currentWindows.compactMap { $0.window.resetsAt }.min()
        return Summary(text: "All healthy · next reset \(Format.resetsIn(nearest, now: date))",
                       severity: .normal, isWarning: false)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        generation += 1
        let startedGeneration = generation
        providers = makeProviders { [weak self] result, id in
            Task { @MainActor in
                guard let self, self.isStarted, self.generation == startedGeneration else { return }
                self.apply(result, to: id)
            }
        }
        lastRefreshAttempt = now()
        providers.forEach { $0.start() }
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isStarted, self.generation == startedGeneration else { return }
                self.updateClock()
            }
        }
    }

    func updateClock() {
        objectWillChange.send()
        applyHysteresis()
        let date = now()
        if let last = lastResetRefresh, date.timeIntervalSince(last) < 120 { return }
        let rolledOver = sources.contains { source in
            guard let updated = source.lastUpdated else { return false }
            return source.windows.contains { window in
                guard let reset = window.resetsAt else { return false }
                return reset < date && updated < reset
            }
        }
        guard rolledOver, isStarted else { return }
        lastResetRefresh = date
        refreshAll()
    }

    func refreshAll() {
        guard isStarted else { return }
        lastRefreshAttempt = now()
        providers.forEach { $0.refresh() }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        generation += 1
        tick?.invalidate()
        tick = nil
        providers.forEach { $0.stop() }
        providers = []
        lastResetRefresh = nil
    }

    private func apply(_ result: Result<UsageSource, Error>, to id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let source):
            let previous = sources[index].lastUpdated
            sources[index] = source
            if source.state == .ok, let updated = source.lastUpdated,
               updated > (previous ?? .distantPast) {
                lastRefreshed = max(lastRefreshed ?? updated, updated)
            }
        case .failure(let error):
            sources[index].state = .error(error.localizedDescription)
        }
        applyHysteresis()
    }

    private func applyHysteresis() {
        let date = now()
        // Projection is a threshold input, separate from the earliest limit's identity.
        let projected = currentWindows.map { $0.window.projectedPercent(now: date) }.max() ?? 0
        if showsWorstFigure {
            if projected < 75 { showsWorstFigure = false }
        } else if projected >= 80 {
            showsWorstFigure = true
        }
    }

    nonisolated private static func defaultProviders(update: @escaping Update) -> [UsageProviding] {
        [
            CodexProvider { update($0, "codex") },
            ClaudeProvider { update(.success($0), "claude") },
            AgyProvider { update(.success($0), "agy") },
        ]
    }
}
