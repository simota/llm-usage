import AppKit
import SwiftUI

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: UsageStore

    override init() {
        store = UsageStore()
        super.init()
    }

    init(store: UsageStore) {
        self.store = store
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no main window. Equivalent to LSUIElement
        // without needing an Info.plist, which keeps this a plain SwiftPM executable.
        NSApp.setActivationPolicy(.accessory)
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
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
            PanelView(store: delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}
