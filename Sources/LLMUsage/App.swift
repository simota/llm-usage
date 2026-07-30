import AppKit
import SwiftUI

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var sources: [UsageSource]
    @Published private(set) var lastRefreshed: Date?
    /// Drives the A/B swap in the menu bar. Hysteresis lives in `applyHysteresis`.
    @Published private(set) var showsWorstFigure = false

    private static let enterThreshold: Double = 80
    private static let exitThreshold: Double = 75

    private var providers: [UsageProviding] = []
    private var tick: Timer?
    private var lastResetRefresh: Date?

    init(sources: [UsageSource]? = nil) {
        self.sources = sources ?? [
            UsageSource.placeholder(id: "claude", name: "Claude Code"),
            UsageSource.placeholder(id: "codex", name: "Codex"),
            UsageSource.placeholder(id: "agy", name: "Antigravity"),
        ]
    }

    /// The most consumed window across every source that currently has data.
    var worst: UsageWindow? {
        sources.compactMap(\.worstWindow).max { $0.usedPercent < $1.usedPercent }
    }

    /// The window that will bite first, by projected end-of-window consumption.
    /// Ties go to whichever the source says is actively metering.
    var binding: (source: UsageSource, window: UsageWindow)? {
        sources
            .flatMap { source in source.windows.map { (source: source, window: $0) } }
            .max { a, b in
                let (pa, pb) = (a.window.projectedPercent(), b.window.projectedPercent())
                if pa != pb { return pa < pb }
                if a.window.isActive != b.window.isActive { return !a.window.isActive }
                return a.window.usedPercent < b.window.usedPercent
            }
    }

    /// One line naming the binding constraint. Replaces a header that only
    /// repeated the app's own name.
    struct Summary {
        let text: String
        let severity: Severity
        let isWarning: Bool
    }

    var summary: Summary {
        guard let (source, window) = binding else {
            return Summary(text: "No data", severity: .normal, isWarning: false)
        }
        let severity = Severity(usedPercent: window.usedPercent)
        let head = "\(source.displayName) \(window.label) \(Format.percent(window.usedPercent))"

        if Format.overPace(window) != nil {
            // The row already states the percentage; the header's job is to say
            // what it means for you. Over-pace is always red here, matching the
            // tick and the row caption.
            let detail = Format.exhaustion(window) ?? Format.overPace(window)!
            return Summary(text: "\(head) · \(detail)", severity: .critical, isWarning: true)
        }
        if window.usedPercent >= 60 {
            // High but keeping up: still worth an icon once it reaches warning.
            return Summary(text: "\(head) · \(Format.resetsIn(window.resetsAt))",
                           severity: severity, isWarning: severity >= .warning)
        }
        let nearest = sources.flatMap(\.windows).compactMap(\.resetsAt).min()
        return Summary(text: "All healthy · next reset \(Format.resetsIn(nearest))",
                       severity: .normal, isWarning: false)
    }

    func start() {
        providers = [
            CodexProvider { [weak self] result in
                Task { @MainActor in self?.apply(result, to: "codex") }
            },
            ClaudeProvider { [weak self] source in
                Task { @MainActor in self?.apply(.success(source), to: "claude") }
            },
            AgyProvider { [weak self] source in
                Task { @MainActor in self?.apply(.success(source), to: "agy") }
            },
        ]
        providers.forEach { $0.start() }

        // Re-render so relative timestamps and pace ticks keep moving.
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
                self?.refreshIfWindowRolledOver()
            }
        }
    }

    /// A window that has passed its reset time is showing pre-reset consumption
    /// until the next poll, which can be minutes away. Go and look immediately.
    private func refreshIfWindowRolledOver() {
        let now = Date()
        if let last = lastResetRefresh, now.timeIntervalSince(last) < 120 { return }

        let rolledOver = sources.contains { source in
            guard let updated = source.lastUpdated else { return false }
            return source.windows.contains { window in
                guard let resetsAt = window.resetsAt else { return false }
                return resetsAt < now && updated < resetsAt
            }
        }
        guard rolledOver else { return }
        lastResetRefresh = now
        refreshAll()
    }

    func refreshAll() {
        providers.forEach { $0.refresh() }
    }

    func stop() {
        tick?.invalidate()
        providers.forEach { $0.stop() }
        providers = []
    }

    private func apply(_ result: Result<UsageSource, Error>, to id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let source):
            sources[index] = source
            // A placeholder card is not a refresh; only real data moves the clock.
            if case .ok = source.state { lastRefreshed = Date() }
        case .failure(let error):
            sources[index].state = .error(error.localizedDescription)
        }
        applyHysteresis()
    }

    private func applyHysteresis() {
        guard let used = worst?.usedPercent else { return }
        if showsWorstFigure {
            if used < Self.exitThreshold { showsWorstFigure = false }
        } else if used >= Self.enterThreshold {
            showsWorstFigure = true
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no main window. Equivalent to LSUIElement
        // without needing an Info.plist, which keeps this a plain SwiftPM executable.
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Headless probe
//
// `LLMUsage --probe` exercises the provider and normalisation path without a GUI,
// so the data plumbing can be verified from a terminal.

enum Probe {
    static func run() -> Never {
        let collected = Mutex<[String: UsageSource]>([:])
        let codexArrived = DispatchSemaphore(value: 0)

        let codex = CodexProvider { result in
            switch result {
            case .success(let source):
                collected.withLock { $0[source.id] = source }
                codexArrived.signal()
            case .failure(let error):
                FileHandle.standardError.write(Data("codex: \(error)\n".utf8))
                codexArrived.signal()
            }
        }
        let claudeArrived = DispatchSemaphore(value: 0)
        let claude = ClaudeProvider { source in
            collected.withLock { $0[source.id] = source }
            claudeArrived.signal()
        }
        let agyArrived = DispatchSemaphore(value: 0)
        let agy = AgyProvider { source in
            collected.withLock { $0[source.id] = source }
            agyArrived.signal()
        }

        claude.start()
        agy.start()
        codex.start()
        if claudeArrived.wait(timeout: .now() + 20) == .timedOut {
            FileHandle.standardError.write(Data("claude: timed out after 20s\n".utf8))
        }
        if agyArrived.wait(timeout: .now() + 15) == .timedOut {
            FileHandle.standardError.write(Data("agy: timed out after 15s\n".utf8))
        }
        if codexArrived.wait(timeout: .now() + 20) == .timedOut {
            FileHandle.standardError.write(Data("codex: timed out after 20s\n".utf8))
        }
        codex.stop()
        claude.stop()
        agy.stop()

        let sources = collected.withLock { $0 }
        for id in ["claude", "codex", "agy"] {
            guard let source = sources[id] else { continue }
            print(describe(source))
        }
        exit(sources.isEmpty ? 1 : 0)
    }

    private static func describe(_ source: UsageSource) -> String {
        // agedState() is what the card renders, so report that rather than the
        // raw value — otherwise a stale source reads as ok here.
        var lines = ["source     : \(source.displayName)  plan=\(source.plan ?? "—")  "
                     + "account=\(source.account ?? "—")  "
                     + "state=\(source.agedState())  updated=\(Format.relative(source.lastUpdated))"]
        for w in source.windows {
            let pace = w.paceDelta().map { String(format: "%+.1f%%", $0 * 100) } ?? "n/a"
            lines.append("  window   : \(w.label)  used=\(Format.percent(w.usedPercent))  "
                         + "resets=\(Format.resetsIn(w.resetsAt))  pace=\(pace)")
        }
        for b in source.buckets {
            lines.append("  bucket   : \(b.label)  used=\(Format.percent(b.usedPercent))")
        }
        if let note = source.note { lines.append("  note     : \(note)") }
        return lines.joined(separator: "\n")
    }
}

/// `LLMUsage --icon <dir>` writes the menu bar artwork to PNG so it can be
/// inspected without hunting for it in the menu bar.
enum IconDump {
    static func run(directory: String) -> Never {
        func source(_ id: String, _ name: String, _ used: Double) -> UsageSource {
            var s = UsageSource(id: id, displayName: name)
            s.state = .ok
            s.lastUpdated = Date()
            s.windows = [UsageWindow(id: "\(id)-w", label: "w", usedPercent: used,
                                     resetsAt: nil, windowMinutes: nil)]
            return s
        }
        let demo = [
            source("claude", "Claude Code", 62),
            source("codex", "Codex", 55),
            source("agy", "Antigravity", 13),
        ]
        let hot = UsageWindow(id: "hot", label: "w", usedPercent: 82,
                              resetsAt: nil, windowMinutes: nil)

        let cases: [(String, NSImage)] = [
            ("menubar-bars", MenuBarIcon.image(sources: demo, worst: nil, showsWorstFigure: false)),
            ("menubar-bars-empty", MenuBarIcon.image(
                sources: demo.map { var s = $0; s.windows = []; s.state = .unconfigured; return s },
                worst: nil, showsWorstFigure: false)),
            ("menubar-figure", MenuBarIcon.image(sources: demo, worst: hot, showsWorstFigure: true)),
        ]

        for (name, image) in cases {
            guard let data = MenuBarIcon.png(image, scale: 8) else { continue }
            let path = (directory as NSString).appendingPathComponent("\(name).png")
            try? data.write(to: URL(fileURLWithPath: path))
            print("\(path)  \(Int(image.size.width))x\(Int(image.size.height))pt")
        }
        exit(0)
    }
}

/// Minimal lock box — provider callbacks are `@Sendable` and fire off-main.
final class Mutex<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()

    init(_ value: Value) { storage = value }

    @discardableResult
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body(&storage)
    }
}

@main
struct LLMUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = UsageStore()

    init() {
        let args = CommandLine.arguments
        if args.contains("--probe") { Probe.run() }
        if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
            IconDump.run(directory: args[i + 1])
        }
        if let i = args.firstIndex(of: "--appicon"), i + 1 < args.count {
            AppIconDump.run(directory: args[i + 1])
        }
        if let i = args.firstIndex(of: "--panel"), i + 1 < args.count {
            MainActor.assumeIsolated { PanelDump.run(directory: args[i + 1]) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
                .task { store.start() }
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
