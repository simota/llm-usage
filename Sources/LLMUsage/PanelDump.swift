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
        let store = UsageStore(sources: fixture())

        // ImageRenderer, not NSHostingView.cacheDisplay: the latter captures only
        // layer-backed shapes and drops SwiftUI text entirely.
        for (name, scheme) in [("panel-light", ColorScheme.light),
                               ("panel-dark", ColorScheme.dark)] {
            let content = PanelView(store: store)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.14) : Color(white: 0.97))

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
        exit(0)
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
}
