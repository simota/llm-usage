import Foundation
import XCTest
@testable import LLMUsage

@MainActor
final class AgyProviderTests: XCTestCase {
    func testUsageCommandReturnsAllWindowsWithoutLocalServerAuthentication() async throws {
        let fixture = AgyFixture()
        defer { fixture.provider.stop() }
        fixture.provider.start()
        let command = try await fixture.usageCommand(at: 0)
        XCTAssertEqual(command.arguments, ["-p", "/usage", "--output-format", "json", "--print-timeout", "10s"])
        XCTAssertEqual(command.path, "/fixture/agy")
        XCTAssertEqual(command.environment["PATH"], "/fixture:/usr/bin:/bin")
        XCTAssertEqual(command.timeout, 10)
        command.respond(.success(Self.quota))
        let source = try await fixture.updates.source(at: 0)
        XCTAssertEqual(source.state, .ok)
        XCTAssertEqual(source.windows.map(\.id), ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])
        XCTAssertEqual(source.windows.map(\.label), ["Gemini 5h", "Gemini 7d", "Claude/GPT 5h", "Claude/GPT 7d"])
        XCTAssertEqual(source.windows.map(\.usedPercent), [25, 50, 0, 100])
        XCTAssertEqual(source.windows.map(\.windowMinutes), [300, 10_080, 300, 10_080])
        XCTAssertTrue(source.windows.allSatisfy { $0.resetsAt != nil })
        XCTAssertEqual(source.staleAfter, 900)
        XCTAssertNotNil(source.lastUpdated)
        XCTAssertNil(source.account)
        XCTAssertNil(source.plan)
    }

    func testRepeatedStartAndConcurrentRefreshShareOneFetch() async throws {
        let fixture = AgyFixture()
        defer { fixture.provider.stop() }
        fixture.provider.start()
        fixture.provider.start()
        DispatchQueue.concurrentPerform(iterations: 20) { _ in fixture.provider.refresh() }
        let version = try await fixture.commands.command(at: 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.commands.count, 1)
        version.respond(.success("1.2.5\n"))
        let usage = try await fixture.commands.command(at: 1)
        fixture.provider.refresh()
        fixture.provider.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.commands.count, 2)
        usage.respond(.success(Self.quota))
        _ = try await fixture.updates.source(at: 0)
        fixture.provider.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.commands.count, 2)
    }

    func testFailurePreservesTimestampAndRefreshRecovers() async throws {
        let fixture = AgyFixture()
        defer { fixture.provider.stop() }
        fixture.provider.start()
        let first = try await fixture.usageCommand(at: 0)
        first.respond(.success(Self.quota))
        let original = try await fixture.updates.source(at: 0)

        fixture.provider.refresh()
        let second = try await fixture.usageCommand(at: 2)
        second.respond(.failure(.timedOut))
        let failed = try await fixture.updates.source(at: 1)
        XCTAssertEqual(failed.windows, original.windows)
        XCTAssertEqual(failed.lastUpdated, original.lastUpdated)
        XCTAssertEqual(failed.state, .stale(since: try XCTUnwrap(original.lastUpdated)))
        XCTAssertEqual(failed.note, "Antigravity usage request timed out")

        fixture.provider.refresh()
        let third = try await fixture.usageCommand(at: 4)
        third.respond(.success(Self.quota.replacingOccurrences(of: "0.75", with: "0.5")))
        let recovered = try await fixture.updates.source(at: 2)
        XCTAssertEqual(recovered.state, .ok)
        XCTAssertEqual(recovered.windows.first?.usedPercent, 50)
    }

    func testMissingCLIDoesNotRunCommands() async throws {
        let fixture = AgyFixture(installed: false)
        defer { fixture.provider.stop() }
        fixture.provider.start()
        let source = try await fixture.updates.source(at: 0)
        XCTAssertEqual(fixture.commands.count, 0)
        XCTAssertEqual(source.note, "agy not found (install Antigravity CLI)")
        XCTAssertNil(source.lastUpdated)
    }

    func testOldOrUnknownVersionNeverRunsUsageAsAModelPrompt() async throws {
        for version in ["1.1.10", "1.0.99", "", "unknown", "1.2.5-preview", "1.2"] {
            let fixture = AgyFixture()
            fixture.provider.start()
            let command = try await fixture.commands.command(at: 0)
            command.respond(.success(version))
            let source = try await fixture.updates.source(at: 0)
            fixture.provider.stop()
            XCTAssertEqual(fixture.commands.count, 1, version)
            XCTAssertEqual(source.note, "Update Antigravity CLI (agy 1.1.11+ required)", version)
            XCTAssertTrue(source.windows.isEmpty)
        }
        for version in ["1.1.11", "1.1.28\n", "1.2.5", "2.0.0"] {
            XCTAssertTrue(AgyProvider.supportsUsageCommand(version: version), version)
        }
    }

    func testVersionFailureDoesNotRunUsage() async throws {
        for failure in [CLI.RunFailure.notRun, .exitCode(1), .timedOut, .outputTooLarge] {
            let fixture = AgyFixture()
            fixture.provider.start()
            let command = try await fixture.commands.command(at: 0)
            command.respond(.failure(failure))
            let source = try await fixture.updates.source(at: 0)
            fixture.provider.stop()
            XCTAssertEqual(fixture.commands.count, 1)
            XCTAssertNil(source.lastUpdated)
            XCTAssertNotEqual(source.state, .ok)
        }
    }

    func testMalformedOrFailedResponseNeverPublishesFreshUsage() async throws {
        let invalid = [
            "{}",
            Self.quota.replacingOccurrences(of: "\"SUCCESS\"", with: "\"ERROR\""),
            Self.quota.replacingOccurrences(of: "\"num_turns\":0", with: "\"num_turns\":1"),
            Self.quota.replacingOccurrences(of: "\"name\":\"usage\"", with: "\"name\":\"credits\""),
            Self.quota.replacingOccurrences(of: "\"groups\"", with: "\"unknown_groups\""),
            Self.quota.replacingOccurrences(of: "0.75", with: "1.25"),
            Self.quota.replacingOccurrences(of: "0.75", with: "-0.25"),
        ]
        for json in invalid {
            let fixture = AgyFixture()
            fixture.provider.start()
            let command = try await fixture.usageCommand(at: 0)
            command.respond(.success(json))
            let source = try await fixture.updates.source(at: 0)
            fixture.provider.stop()
            XCTAssertNil(source.lastUpdated)
            XCTAssertTrue(source.windows.isEmpty)
            XCTAssertEqual(source.note, "Unexpected Antigravity response (update agy)")
        }
    }

    func testEmptyGroupsAndDisabledBucketsAreValid() async throws {
        for data in [
            #"{"groups":[]}"#,
            #"{"groups":[{"name":"Gemini Models","buckets":[{"id":"disabled","window":"weekly"}]}]}"#,
        ] {
            let fixture = AgyFixture()
            fixture.provider.start()
            let command = try await fixture.usageCommand(at: 0)
            command.respond(.success(#"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":\#(data)}}"#))
            let source = try await fixture.updates.source(at: 0)
            fixture.provider.stop()
            XCTAssertEqual(source.state, .ok)
            XCTAssertTrue(source.windows.isEmpty)
        }
    }

    func testUnknownWindowAndInvalidResetDoNotInventPace() async throws {
        let fixture = AgyFixture()
        defer { fixture.provider.stop() }
        fixture.provider.start()
        let command = try await fixture.usageCommand(at: 0)
        command.respond(.success(Self.quota
            .replacingOccurrences(of: "\"5h\"", with: "\"daily\"")
            .replacingOccurrences(of: "2026-09-18T18:01:43Z", with: "unknown")))
        let source = try await fixture.updates.source(at: 0)
        let daily = try XCTUnwrap(source.windows.first { $0.id == "gemini-5h" })
        XCTAssertEqual(daily.label, "Gemini daily")
        XCTAssertNil(daily.windowMinutes)
        XCTAssertNil(daily.resetsAt)
        XCTAssertNil(daily.paceDelta())
    }

    func testStopDuringVersionCancelsWithoutStartingUsage() async throws {
        let fixture = AgyFixture()
        fixture.provider.start()
        let version = try await fixture.commands.command(at: 0)
        fixture.provider.stop()
        XCTAssertTrue(version.cancelled.withLock { $0 }, "stop must cancel the child before the app exits")
        try await version.waitForCancellation()
        fixture.provider.refresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.commands.count, 1)
        XCTAssertEqual(fixture.updates.count, 0)
    }

    func testRestartIgnoresCompletionFromCancelledGeneration() async throws {
        let fixture = AgyFixture()
        defer { fixture.provider.stop() }
        fixture.provider.start()
        let old = try await fixture.usageCommand(at: 0)
        old.ignoreCancellation.withLock { $0 = true }
        fixture.provider.stop()
        try await old.waitForCancellation()

        fixture.provider.start()
        let current = try await fixture.usageCommand(at: 2)
        current.respond(.success(Self.quota))
        _ = try await fixture.updates.source(at: 0)
        old.respond(.success(Self.quota.replacingOccurrences(of: "0.75", with: "0.5")))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.updates.count, 1)
    }

    // The shape is from agy -p /usage --output-format json, with fixture values.
    private static let quota = #"""
    {"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[
      {"name":"Gemini Models","buckets":[
        {"id":"gemini-weekly","window":"weekly","remaining_fraction":0.5,"reset_time":"2026-09-23T02:29:27Z"},
        {"id":"gemini-5h","window":"5h","remaining_fraction":0.75,"reset_time":"2026-09-18T18:01:43Z"}
      ]},
      {"name":"Claude and GPT models","buckets":[
        {"id":"3p-weekly","window":"weekly","remaining_fraction":0,"reset_time":"2026-09-25T14:45:08.123Z"},
        {"id":"3p-5h","window":"5h","remaining_fraction":1,"reset_time":"2026-09-18T19:45:08Z"}
      ]}
    ]}}}
    """#
}

private final class AgyFixture: @unchecked Sendable {
    let commands = AgyCommands()
    let updates = AgyUpdates()
    let provider: AgyProvider

    init(installed: Bool = true) {
        provider = AgyProvider(resolveCLI: {
            installed ? CLI.Resolution(path: "/fixture/agy", environment: ["PATH": "/fixture:/usr/bin:/bin"]) : nil
        }, runCommand: { [commands] path, arguments, environment, timeout, isCancelled in
            commands.run(path: path, arguments: arguments, environment: environment,
                         timeout: timeout, isCancelled: isCancelled)
        }) { [updates] in
            updates.append($0)
        }
    }

    @MainActor
    func usageCommand(at index: Int) async throws -> AgyCommand {
        let version = try await commands.command(at: index)
        XCTAssertEqual(version.arguments, ["--version"])
        XCTAssertEqual(version.timeout, 3)
        version.respond(.success("1.2.5\n"))
        return try await commands.command(at: index + 1)
    }
}

private final class AgyCommand: @unchecked Sendable {
    let path: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let ignoreCancellation = Mutex(false)
    let cancelled = Mutex(false)
    let result = Mutex<Result<String, CLI.RunFailure>?>(nil)

    init(path: String, arguments: [String], environment: [String: String], timeout: TimeInterval) {
        self.path = path
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }

    func respond(_ response: Result<String, CLI.RunFailure>) { result.withLock { $0 = response } }

    func waitForCancellation() async throws {
        let _: Bool = try await agyWait { self.cancelled.withLock { $0 } ? true : nil }
    }
}

private final class AgyCommands: @unchecked Sendable {
    private let values = Mutex<[AgyCommand]>([])
    var count: Int { values.withLock { $0.count } }

    func run(path: String, arguments: [String], environment: [String: String], timeout: TimeInterval,
             isCancelled: @Sendable () -> Bool) -> Result<String, CLI.RunFailure> {
        let command = AgyCommand(path: path, arguments: arguments, environment: environment, timeout: timeout)
        values.withLock { $0.append(command) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if isCancelled() {
                command.cancelled.withLock { $0 = true }
                if !command.ignoreCancellation.withLock({ $0 }) { return .failure(.cancelled) }
            }
            if let result = command.result.withLock({ $0 }) { return result }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return .failure(.timedOut)
    }

    func command(at index: Int) async throws -> AgyCommand {
        try await agyWait {
            self.values.withLock { $0.indices.contains(index) ? $0[index] : nil }
        }
    }
}

private final class AgyUpdates: @unchecked Sendable {
    private let values = Mutex<[UsageSource]>([])
    var count: Int { values.withLock { $0.count } }
    func append(_ value: UsageSource) { values.withLock { $0.append(value) } }

    func source(at index: Int) async throws -> UsageSource {
        try await agyWait {
            self.values.withLock { $0.indices.contains(index) ? $0[index] : nil }
        }
    }
}

private func agyWait<Value: Sendable>(_ value: @Sendable () -> Value?) async throws -> Value {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if let result = value() { return result }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw NSError(domain: "AgyProviderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for mock provider"])
}
