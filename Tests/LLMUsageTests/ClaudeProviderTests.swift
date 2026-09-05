import XCTest
@testable import LLMUsage

final class ClaudeProviderTests: XCTestCase {
    func testRetryAfterBlocksManualRefreshUntilDeadline() throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_000))
        let harness = ClaudeHTTPHarness()
        let updates = Mutex<[UsageSource]>([])
        let provider = makeProvider(harness, updates: updates, now: { clock.withLock { $0 } })
        defer { provider.stop() }
        provider.start()
        try awaitCount(harness, 1)
        harness.respond(0, status: 429, headers: ["Retry-After": "600"])
        try awaitUpdates(updates, 1)
        clock.withLock { $0 = $0.addingTimeInterval(300) }
        for _ in 0..<20 { provider.refresh() }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(harness.count, 1)
        clock.withLock { $0 = $0.addingTimeInterval(300) }
        provider.refresh()
        try awaitCount(harness, 2)
        harness.respond(1, status: 200)
        try awaitUpdates(updates, 2)
        XCTAssertEqual(updates.withLock { $0.last?.state }, .ok)
    }

    func testRepeatedStartAndRefreshKeepOnlyOneRequestInFlight() throws {
        let harness = ClaudeHTTPHarness()
        let updates = Mutex<[UsageSource]>([])
        let provider = makeProvider(harness, updates: updates)
        defer { provider.stop() }
        provider.start()
        try awaitCount(harness, 1)
        for _ in 0..<20 { provider.start(); provider.refresh() }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(harness.count, 1)
        harness.respond(0, status: 200)
        try awaitUpdates(updates, 1)
    }

    func testStopCancelsRequestAndRestartCanFetch() throws {
        let harness = ClaudeHTTPHarness()
        let updates = Mutex<[UsageSource]>([])
        let provider = makeProvider(harness, updates: updates)
        defer { provider.stop() }
        provider.start()
        try awaitCount(harness, 1)
        provider.stop()
        try eventually { harness.cancelledCount == 1 }
        provider.refresh()
        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertEqual(harness.count, 1)
        XCTAssertEqual(updates.withLock { $0.count }, 0)
        provider.start()
        try awaitCount(harness, 2)
        harness.respond(1, status: 200)
        try awaitUpdates(updates, 1)
    }

    func testStopCancelsScheduledRetry() throws {
        let harness = ClaudeHTTPHarness()
        let updates = Mutex<[UsageSource]>([])
        let provider = makeProvider(harness, updates: updates)
        provider.start()
        try awaitCount(harness, 1)
        harness.respond(0, status: 429, headers: ["Retry-After": "1"])
        try awaitUpdates(updates, 1)
        provider.stop()
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertEqual(harness.count, 1)
        XCTAssertEqual(updates.withLock { $0.count }, 1)
    }

    func testRestartDiscardsPreviousSessionsRetryDeadline() throws {
        let harness = ClaudeHTTPHarness()
        let updates = Mutex<[UsageSource]>([])
        let provider = makeProvider(harness, updates: updates)
        defer { provider.stop() }
        provider.start()
        try awaitCount(harness, 1)
        harness.respond(0, status: 429, headers: ["Retry-After": "600"])
        try awaitUpdates(updates, 1)
        provider.stop()
        provider.start()
        try awaitCount(harness, 2)
        harness.respond(1, status: 200)
        try awaitUpdates(updates, 2)
        XCTAssertEqual(updates.withLock { $0.last?.state }, .ok)
    }

    func testNewCredentialClearsOldIdentityAndLastGoodOnFailure() throws {
        let harness = ClaudeHTTPHarness()
        let updates = Mutex<[UsageSource]>([])
        let token = Mutex("fixture-first-token")
        let identity = Mutex<ClaudeProvider.AuthProbe>(.answered(plan: "Pro", account: "first@example.test"))
        let provider = makeProvider(harness, updates: updates,
                                    credential: { .token(token.withLock { $0 }) },
                                    identity: { identity.withLock { $0 } })
        defer { provider.stop() }
        provider.start()
        try awaitCount(harness, 1)
        harness.respond(0, status: 200)
        try awaitUpdates(updates, 1)
        XCTAssertEqual(updates.withLock { $0.last?.account }, "first@example.test")
        token.withLock { $0 = "fixture-second-token" }
        identity.withLock { $0 = .unreachable }
        provider.refresh()
        try awaitCount(harness, 2)
        harness.respond(1, status: 403)
        try awaitUpdates(updates, 2)
        let failed = try XCTUnwrap(updates.withLock { $0.last })
        XCTAssertNil(failed.account)
        XCTAssertNil(failed.plan)
        XCTAssertNil(failed.lastUpdated)
        XCTAssertTrue(failed.windows.isEmpty)
    }

    func testSameAccountTokenRefreshPreservesLastGoodOnTransientFailure() throws {
        for status in [503, 429] {
            let harness = ClaudeHTTPHarness()
            let updates = Mutex<[UsageSource]>([])
            let token = Mutex("fixture-first-token")
            let sampledAt = Date(timeIntervalSince1970: 2_000)
            let provider = makeProvider(harness, updates: updates,
                                        credential: { .token(token.withLock { $0 }) },
                                        identity: { .answered(plan: "Pro", account: "first@example.test") },
                                        now: { sampledAt })
            defer { provider.stop() }
            provider.start()
            try awaitCount(harness, 1)
            harness.respond(0, status: 200)
            try awaitUpdates(updates, 1)
            token.withLock { $0 = "fixture-refreshed-token" }
            provider.refresh()
            try awaitCount(harness, 2)
            XCTAssertEqual(harness.request(1).value(forHTTPHeaderField: "Authorization"),
                           "Bearer fixture-refreshed-token")
            harness.respond(1, status: status)
            try awaitUpdates(updates, 2)
            let failed = try XCTUnwrap(updates.withLock { $0.last })
            XCTAssertEqual(failed.account, "first@example.test")
            XCTAssertEqual(failed.plan, "Pro")
            XCTAssertEqual(failed.lastUpdated, sampledAt)
            XCTAssertEqual(failed.windows.first?.usedPercent, 25)
            XCTAssertEqual(failed.state, .stale(since: sampledAt))
        }
    }

    func testNewCredentialWithChangedOrUnknownAccountDiscardsPreviousSample() throws {
        for account: String? in ["second@example.test", nil] {
            let harness = ClaudeHTTPHarness()
            let updates = Mutex<[UsageSource]>([])
            let token = Mutex("fixture-first-token")
            let identity = Mutex<ClaudeProvider.AuthProbe>(.answered(plan: "Pro", account: "first@example.test"))
            let provider = makeProvider(harness, updates: updates,
                                        credential: { .token(token.withLock { $0 }) },
                                        identity: { identity.withLock { $0 } })
            defer { provider.stop() }
            provider.start()
            try awaitCount(harness, 1)
            harness.respond(0, status: 200)
            try awaitUpdates(updates, 1)
            token.withLock { $0 = "fixture-second-token" }
            identity.withLock { $0 = .answered(plan: "Max", account: account) }
            provider.refresh()
            try awaitCount(harness, 2)
            harness.respond(1, status: 503)
            try awaitUpdates(updates, 2)
            let failed = try XCTUnwrap(updates.withLock { $0.last })
            XCTAssertEqual(failed.account, account)
            XCTAssertEqual(failed.plan, "Max")
            XCTAssertNil(failed.lastUpdated)
            XCTAssertTrue(failed.windows.isEmpty)
            XCTAssertEqual(failed.state, .unconfigured)
        }
    }

    func testFailurePreservesSampleTimestampButIsNotHealthy() throws {
        let harness = ClaudeHTTPHarness()
        let updates = Mutex<[UsageSource]>([])
        let sampledAt = Date(timeIntervalSince1970: 2_000)
        let provider = makeProvider(harness, updates: updates, now: { sampledAt })
        defer { provider.stop() }
        provider.start()
        try awaitCount(harness, 1)
        harness.respond(0, status: 200)
        try awaitUpdates(updates, 1)
        provider.refresh()
        try awaitCount(harness, 2)
        harness.respond(1, status: 403)
        try awaitUpdates(updates, 2)
        let failed = try XCTUnwrap(updates.withLock { $0.last })
        XCTAssertEqual(failed.lastUpdated, sampledAt)
        XCTAssertEqual(failed.windows.first?.usedPercent, 25)
        XCTAssertEqual(failed.state, .stale(since: sampledAt))
    }

    func testMissingCredentialWithChangedAccountDiscardsPreviousSample() throws {
        let harness = ClaudeHTTPHarness()
        let updates = Mutex<[UsageSource]>([])
        let credential = Mutex<ClaudeProvider.Credential>(.token("fixture-first-token"))
        let identity = Mutex<ClaudeProvider.AuthProbe>(.answered(plan: "Pro", account: "first@example.test"))
        let provider = makeProvider(harness, updates: updates,
                                    credential: { credential.withLock { $0 } },
                                    identity: { identity.withLock { $0 } })
        defer { provider.stop() }
        provider.start()
        try awaitCount(harness, 1)
        harness.respond(0, status: 200)
        try awaitUpdates(updates, 1)
        credential.withLock { $0 = .missing }
        identity.withLock { $0 = .answered(plan: "Max", account: "second@example.test") }
        provider.refresh()
        try awaitUpdates(updates, 2)
        let failed = try XCTUnwrap(updates.withLock { $0.last })
        XCTAssertEqual(failed.account, "second@example.test")
        XCTAssertEqual(failed.plan, "Max")
        XCTAssertTrue(failed.windows.isEmpty)
        XCTAssertNil(failed.lastUpdated)
        XCTAssertEqual(harness.count, 1)
    }

    func testExitOneLogoutClearsCachedIdentityAndLastGood() throws {
        let executable = try authStatusFixture()
        defer { try? FileManager.default.removeItem(at: executable) }
        let environment = Mutex([
            "FIXTURE_AUTH_JSON": #"{"loggedIn":true,"subscriptionType":"pro","email":"first@example.test"}"#,
            "FIXTURE_AUTH_EXIT": "0"
        ])
        let harness = ClaudeHTTPHarness()
        let updates = Mutex<[UsageSource]>([])
        let credential = Mutex<ClaudeProvider.Credential>(.token("fixture-token"))
        let provider = makeProvider(harness, updates: updates,
                                    credential: { credential.withLock { $0 } },
                                    identity: {
            ClaudeProvider.authStatus(executable: executable.path, environment: environment.withLock { $0 })
        })
        defer { provider.stop() }
        provider.start()
        try awaitCount(harness, 1)
        harness.respond(0, status: 200)
        try awaitUpdates(updates, 1)
        XCTAssertEqual(updates.withLock { $0.last?.account }, "first@example.test")
        XCTAssertEqual(updates.withLock { $0.last?.plan }, "Pro")
        credential.withLock { $0 = .missing }
        environment.withLock {
            $0 = ["FIXTURE_AUTH_JSON": #"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#,
                  "FIXTURE_AUTH_EXIT": "1"]
        }
        provider.refresh()
        try awaitUpdates(updates, 2)
        let loggedOut = try XCTUnwrap(updates.withLock { $0.last })
        XCTAssertNil(loggedOut.account)
        XCTAssertNil(loggedOut.plan)
        XCTAssertNil(loggedOut.lastUpdated)
        XCTAssertTrue(loggedOut.windows.isEmpty)
        XCTAssertEqual(loggedOut.state, .unconfigured)
        XCTAssertEqual(loggedOut.note, "Not signed in to Claude Code")
        XCTAssertEqual(harness.count, 1)

        // Reusing the fixture token proves logout invalidated the token cache too.
        credential.withLock { $0 = .token("fixture-token") }
        environment.withLock {
            $0 = ["FIXTURE_AUTH_JSON": #"{"loggedIn":true,"subscriptionType":"max","email":"second@example.test"}"#,
                  "FIXTURE_AUTH_EXIT": "0"]
        }
        provider.refresh()
        try awaitCount(harness, 2)
        harness.respond(1, status: 200)
        try awaitUpdates(updates, 3)
        XCTAssertEqual(updates.withLock { $0.last?.account }, "second@example.test")
        XCTAssertEqual(updates.withLock { $0.last?.plan }, "Max")
    }

    func testAuthStatusRejectsFailuresAndMalformedOutput() throws {
        let executable = try authStatusFixture()
        defer { try? FileManager.default.removeItem(at: executable) }
        for (json, exitCode) in [("", "1"), ("not json", "1"), ("[]", "1"),
                                 (#"{"loggedIn":false}"#, "2")] {
            let probe = ClaudeProvider.authStatus(executable: executable.path,
                                                  environment: ["FIXTURE_AUTH_JSON": json,
                                                                "FIXTURE_AUTH_EXIT": exitCode])
            guard case .unreachable = probe else {
                XCTFail("Expected an unreachable probe for exit \(exitCode) with \(json)")
                continue
            }
        }
    }

    func testEndpointOverrideUsesOnlyMockCredential() throws {
        let harness = ClaudeHTTPHarness()
        let reads = Mutex(0)
        let updates = Mutex<[UsageSource]>([])
        let provider = makeProvider(harness, endpoint: .test(URL(string: "http://127.0.0.1:43210/usage")!),
                                    updates: updates,
                                    credential: { reads.withLock { $0 += 1 }; return .token("forbidden-fixture") },
                                    identity: { reads.withLock { $0 += 1 }; return .unreachable })
        defer { provider.stop() }
        provider.start()
        try awaitCount(harness, 1)
        XCTAssertEqual(harness.request(0).value(forHTTPHeaderField: "Authorization"), "Bearer llm-usage-test-token")
        XCTAssertEqual(reads.withLock { $0 }, 0)
        harness.respond(0, status: 200)
        try awaitUpdates(updates, 1)
    }

    func testExternalEndpointOverrideIsRejectedBeforeReadingCredentials() throws {
        let harness = ClaudeHTTPHarness()
        let reads = Mutex(0)
        let updates = Mutex<[UsageSource]>([])
        let endpoint = ClaudeProvider.Endpoint.configured(["LLM_USAGE_CLAUDE_ENDPOINT": "https://example.com/usage"])
        XCTAssertEqual(endpoint, .invalid)
        let provider = makeProvider(harness, endpoint: endpoint, updates: updates,
                                    credential: { reads.withLock { $0 += 1 }; return .missing })
        defer { provider.stop() }
        provider.start()
        try awaitUpdates(updates, 1)
        XCTAssertEqual(reads.withLock { $0 }, 0)
        XCTAssertEqual(harness.count, 0)
    }

    func testRetryAfterHTTPDateAndNonFiniteInput() throws {
        let url = URL(string: "https://example.test")!
        let now = Date(timeIntervalSince1970: 0)
        let dated = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                    headerFields: ["Retry-After": "Thu, 01 Jan 1970 00:10:00 GMT"])
        XCTAssertEqual(ClaudeProvider.retryAfter(dated, now: now), 600)
        let invalid = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "inf"])
        XCTAssertNil(ClaudeProvider.retryAfter(invalid, now: now))
    }

    private func authStatusFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try """
        #!/bin/sh
        [ "$*" = "auth status --json" ] || exit 64
        printf '%s\\n' "$FIXTURE_AUTH_JSON"
        exit "$FIXTURE_AUTH_EXIT"
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeProvider(_ harness: ClaudeHTTPHarness,
                              endpoint: ClaudeProvider.Endpoint = .production,
                              updates: Mutex<[UsageSource]>,
                              credential: @escaping @Sendable () -> ClaudeProvider.Credential = { .token("fixture-token") },
                              identity: @escaping @Sendable () -> ClaudeProvider.AuthProbe = { .answered(plan: nil, account: nil) },
                              now: @escaping @Sendable () -> Date = { Date() }) -> ClaudeProvider {
        ClaudeProvider(endpoint: endpoint, session: harness.session, credentialReader: credential,
                       identityReader: identity, now: now, onUpdate: { source in updates.withLock { $0.append(source) } })
    }

    private func awaitCount(_ harness: ClaudeHTTPHarness, _ count: Int) throws {
        try eventually { harness.count >= count }
        XCTAssertEqual(harness.count, count)
    }

    private func awaitUpdates(_ updates: Mutex<[UsageSource]>, _ count: Int) throws {
        try eventually { updates.withLock { $0.count >= count } }
        XCTAssertEqual(updates.withLock { $0.count }, count)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        XCTAssertTrue(condition(), "Timed out waiting for provider", file: file, line: line)
        if !condition() { throw HarnessFailure.timedOut }
    }

    private enum HarnessFailure: Error { case timedOut }
}

private final class ClaudeHTTPHarness: @unchecked Sendable {
    private struct State {
        var pending: [ClaudeURLProtocol] = []
        var cancelledCount = 0
    }
    private let state = Mutex(State())
    let session: URLSession
    private let id = UUID().uuidString

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-ID": id]
        session = URLSession(configuration: configuration)
        ClaudeURLProtocol.harnesses.withLock { $0[id] = WeakClaudeHarness(self) }
    }

    deinit {
        session.invalidateAndCancel()
        ClaudeURLProtocol.harnesses.withLock { $0.removeValue(forKey: id) }
    }

    var count: Int { state.withLock { $0.pending.count } }
    var cancelledCount: Int { state.withLock { $0.cancelledCount } }
    func request(_ index: Int) -> URLRequest { state.withLock { $0.pending[index].request } }
    func receive(_ protocolInstance: ClaudeURLProtocol) { state.withLock { $0.pending.append(protocolInstance) } }
    func cancelled() { state.withLock { $0.cancelledCount += 1 } }

    func respond(_ index: Int, status: Int, headers: [String: String] = [:]) {
        let pending = state.withLock { $0.pending[index] }
        let response = HTTPURLResponse(url: pending.request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        pending.client?.urlProtocol(pending, didReceive: response, cacheStoragePolicy: .notAllowed)
        pending.client?.urlProtocol(pending, didLoad: Data(#"{"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8))
        pending.client?.urlProtocolDidFinishLoading(pending)
    }
}

private final class ClaudeURLProtocol: URLProtocol, @unchecked Sendable {
    static let harnesses = Mutex<[String: WeakClaudeHarness]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var harness: ClaudeHTTPHarness? {
        guard let id = request.value(forHTTPHeaderField: "X-Fixture-ID") else { return nil }
        return Self.harnesses.withLock { $0[id]?.value }
    }
    override func startLoading() { harness?.receive(self) }
    override func stopLoading() { harness?.cancelled() }
}

private final class WeakClaudeHarness: @unchecked Sendable {
    weak var value: ClaudeHTTPHarness?
    init(_ value: ClaudeHTTPHarness) { self.value = value }
}
