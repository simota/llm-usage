import XCTest
import AppKit
@testable import LLMUsage

final class UsageStoreTests: XCTestCase {
    @MainActor
    func testEarlierExhaustionWinsAcrossDifferentWindowDurations() {
        let now = Date()
        let short = UsageWindow(id: "short", label: "5h", usedPercent: 50,
                                resetsAt: now.addingTimeInterval(4 * 3600), windowMinutes: 300)
        let weekly = UsageWindow(id: "weekly", label: "7d", usedPercent: 40,
                                 resetsAt: now.addingTimeInterval(0.9 * 7 * 86400), windowMinutes: 10080)
        let store = UsageStore(sources: [source("test", windows: [short, weekly], updated: now)])

        XCTAssertEqual(short.projectedExhaustion(now: now)!.timeIntervalSince(now), 3600, accuracy: 0.01)
        XCTAssertEqual(weekly.projectedExhaustion(now: now)!.timeIntervalSince(now), 25.2 * 3600, accuracy: 0.01)
        XCTAssertEqual(store.binding?.window.id, "short")
        XCTAssertEqual(store.headline?.window.id, "short")
    }

    @MainActor
    func testStaleAndFailedValuesDoNotDriveCurrentHealth() {
        let now = Date()
        let quiet = UsageWindow(id: "quiet", label: "5h", usedPercent: 10, resetsAt: nil, windowMinutes: nil)
        let hot = UsageWindow(id: "hot", label: "7d", usedPercent: 99, resetsAt: nil, windowMinutes: nil)
        var failed = source("failed", windows: [hot], updated: now)
        failed.state = .error("Offline")
        let store = UsageStore(sources: [
            source("fresh", windows: [quiet], updated: now),
            source("old", windows: [hot], updated: now.addingTimeInterval(-3600)),
            failed,
        ])

        XCTAssertEqual(store.worst?.id, "quiet")
        XCTAssertEqual(store.headline?.source.id, "fresh")
        XCTAssertFalse(store.summary.text.contains("All healthy"))
        XCTAssertTrue(store.summary.text.contains("unavailable"))
    }

    @MainActor
    func testOnlyOldValuesCannotClaimHealthy() {
        let old = source("old", windows: [
            UsageWindow(id: "quiet", label: "5h", usedPercent: 10, resetsAt: nil, windowMinutes: nil),
        ], updated: Date().addingTimeInterval(-3600))
        let store = UsageStore(sources: [old])
        XCTAssertNil(store.worst)
        XCTAssertNil(store.binding)
        XCTAssertEqual(store.summary.text, "No current data")
        XCTAssertEqual(store.lastRefreshed, old.lastUpdated)
    }

    @MainActor
    func testApplicationLifecycleStartsWithoutPanelAndStopsOnce() {
        _ = NSApplication.shared
        let provider = StoreMockProvider()
        let store = UsageStore(makeProviders: { _ in [provider] })
        let delegate = AppDelegate(store: store)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        store.start()
        XCTAssertTrue(store.isStarted)
        XCTAssertEqual(provider.counts.withLock { $0.starts }, 1)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        store.stop()
        store.refreshAll()
        XCTAssertFalse(store.isStarted)
        XCTAssertEqual(provider.counts.withLock { $0.stops }, 1)
        XCTAssertEqual(provider.counts.withLock { $0.refreshes }, 0)
    }

    @MainActor
    func testSuccessClockUsesNewSampleTimeAndRejectsStoppedGeneration() async throws {
        let date = Date()
        let callbacks = Mutex<[UsageStore.Update]>([])
        let store = UsageStore(now: { date }, makeProviders: { update in
            callbacks.withLock { $0.append(update) }
            return [StoreMockProvider()]
        })
        let window = UsageWindow(id: "w", label: "5h", usedPercent: 10, resetsAt: nil, windowMinutes: nil)
        let sample = source("codex", windows: [window], updated: date.addingTimeInterval(-60))
        store.start()
        let oldUpdate = callbacks.withLock { $0[0] }
        oldUpdate(.success(sample), "codex")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.lastRefreshed, sample.lastUpdated)

        store.refreshAll()
        oldUpdate(.success(sample), "codex")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.lastRefreshAttempt, date)
        XCTAssertEqual(store.lastRefreshed, sample.lastUpdated)

        store.stop()
        store.start()
        var newer = sample
        newer.lastUpdated = date
        oldUpdate(.success(newer), "codex")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.lastRefreshed, sample.lastUpdated)

        callbacks.withLock { $0[1] }(.success(newer), "codex")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.lastRefreshed, date)
        store.stop()
    }

    @MainActor
    func testClockAgingClearsMenuBarWarning() {
        let clock = Mutex(Date())
        let hot = UsageWindow(id: "hot", label: "5h", usedPercent: 99, resetsAt: nil, windowMinutes: nil)
        let source = source("hot", windows: [hot], updated: clock.withLock { $0 })
        let store = UsageStore(sources: [source], now: { clock.withLock { $0 } })
        XCTAssertTrue(store.showsWorstFigure)
        clock.withLock { $0 = $0.addingTimeInterval(901) }
        store.updateClock()
        XCTAssertFalse(store.showsWorstFigure)
        XCTAssertNil(store.worst)
    }

    func testRolledOverWindowIsNotCurrentEvenBeforeStaleTimeout() {
        let date = Date()
        let window = UsageWindow(id: "expired", label: "5h", usedPercent: 90,
                                 resetsAt: date.addingTimeInterval(-1), windowMinutes: 300)
        let source = source("old", windows: [window], updated: date.addingTimeInterval(-2))
        XCTAssertFalse(source.hasCurrentData(now: date))
        XCTAssertNil(window.projectedExhaustion(now: date))
    }

    func testAlreadyExhaustedWindowWinsEvenWithoutDuration() {
        let date = Date()
        let exhausted = UsageWindow(id: "full", label: "5h", usedPercent: 100,
                                    resetsAt: nil, windowMinutes: nil)
        let future = UsageWindow(id: "future", label: "5h", usedPercent: 50,
                                 resetsAt: date.addingTimeInterval(4 * 3600), windowMinutes: 300)
        XCTAssertEqual(exhausted.projectedExhaustion(now: date), date)
        XCTAssertTrue(exhausted.exhaustsBefore(future, now: date))
    }

    private func source(_ id: String, windows: [UsageWindow], updated: Date) -> UsageSource {
        UsageSource(id: id, displayName: id, windows: windows, lastUpdated: updated, state: .ok)
    }
}

private final class StoreMockProvider: UsageProviding, @unchecked Sendable {
    let counts = Mutex((starts: 0, refreshes: 0, stops: 0))
    func start() { counts.withLock { $0.starts += 1 } }
    func refresh() { counts.withLock { $0.refreshes += 1 } }
    func stop() { counts.withLock { $0.stops += 1 } }
}
