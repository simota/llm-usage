import Foundation
import XCTest
@testable import LLMUsage

@MainActor
final class AgyProviderTests: XCTestCase {
    func testRepeatedStartAndConcurrentRefreshShareOneFetch() async throws {
        let fixture = AgyFixture()
        defer { fixture.stop() }
        fixture.provider.start()
        fixture.provider.start()
        DispatchQueue.concurrentPerform(iterations: 20) { _ in fixture.provider.refresh() }

        let identity = try await fixture.server.request(at: 0)
        XCTAssertEqual(identity.request.url?.lastPathComponent, "GetUserStatus")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.server.requestCount, 1)
        fixture.server.respond(to: identity, body: Self.identity(account: "first@example.test"))

        let quota = try await fixture.server.request(at: 1)
        XCTAssertEqual(quota.request.url?.lastPathComponent, "RetrieveUserQuotaSummary")
        fixture.provider.refresh()
        fixture.provider.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.server.requestCount, 2)
        fixture.server.respond(to: quota, body: Self.quota(remaining: 0.2))
        let source = try await fixture.updates.source(at: 0)
        XCTAssertEqual(source.windows.first?.usedPercent, 80)
        XCTAssertEqual(source.account, "first@example.test")

        fixture.provider.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.server.requestCount, 2)
    }

    func testAccountChangeDoesNotReusePreviousQuotaAfterFailure() async throws {
        let fixture = AgyFixture()
        defer { fixture.stop() }
        fixture.provider.start()
        try await fixture.completeFetch(at: 0, account: "first@example.test", remaining: 0.2)
        _ = try await fixture.updates.source(at: 0)

        fixture.provider.refresh()
        let identity = try await fixture.server.request(at: 2)
        fixture.server.respond(to: identity, body: Self.identity(account: "second@example.test", plan: "Google AI Pro"))
        let quota = try await fixture.server.request(at: 3)
        fixture.server.respond(to: quota, status: 503, body: "{}")
        let failed = try await fixture.updates.source(at: 1)
        XCTAssertEqual(failed.account, "second@example.test")
        XCTAssertEqual(failed.plan, "Google AI Pro")
        XCTAssertTrue(failed.windows.isEmpty)
        XCTAssertNil(failed.lastUpdated)

        fixture.provider.refresh()
        try await fixture.completeFetch(at: 4, account: "second@example.test", remaining: 0.7)
        let recovered = try await fixture.updates.source(at: 2)
        XCTAssertEqual(recovered.account, "second@example.test")
        XCTAssertEqual(try XCTUnwrap(recovered.windows.first).usedPercent, 30, accuracy: 0.001)
        XCTAssertEqual(recovered.state, .ok)
    }

    func testFailedRefreshPreservesSuccessfulTimestampAndMarksStale() async throws {
        let fixture = AgyFixture()
        defer { fixture.stop() }
        fixture.provider.start()
        try await fixture.completeFetch(at: 0, account: "first@example.test", remaining: 0.2)
        let original = try await fixture.updates.source(at: 0)

        fixture.provider.refresh()
        let identity = try await fixture.server.request(at: 2)
        fixture.server.respond(to: identity, body: Self.identity(account: "first@example.test"))
        let quota = try await fixture.server.request(at: 3)
        fixture.server.respond(to: quota, status: 503, body: "{}")
        let failed = try await fixture.updates.source(at: 1)
        XCTAssertEqual(failed.windows, original.windows)
        XCTAssertEqual(failed.lastUpdated, original.lastUpdated)
        XCTAssertEqual(failed.state, .stale(since: try XCTUnwrap(original.lastUpdated)))

        fixture.provider.refresh()
        let unavailableIdentity = try await fixture.server.request(at: 4)
        fixture.server.respond(to: unavailableIdentity, status: 500, body: "{}")
        let unavailable = try await fixture.updates.source(at: 2)
        XCTAssertEqual(unavailable.lastUpdated, original.lastUpdated)
        XCTAssertEqual(unavailable.state, failed.state)
        XCTAssertEqual(fixture.server.requestCount, 5)
    }

    func testStopCancelsQuotaAndRestartIgnoresOldCompletion() async throws {
        let fixture = AgyFixture()
        defer { fixture.stop() }
        fixture.provider.start()
        let identity = try await fixture.server.request(at: 0)
        fixture.server.respond(to: identity, body: Self.identity(account: "first@example.test"))
        let oldQuota = try await fixture.server.request(at: 1)

        fixture.provider.stop()
        try await fixture.server.waitForCancellation(of: oldQuota)
        fixture.provider.refresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.server.requestCount, 2)
        XCTAssertEqual(fixture.updates.count, 0)

        fixture.provider.start()
        try await fixture.completeFetch(at: 2, account: "second@example.test", remaining: 0.5)
        let source = try await fixture.updates.source(at: 0)
        XCTAssertEqual(source.account, "second@example.test")
        XCTAssertEqual(source.windows.first?.usedPercent, 50)
        XCTAssertEqual(fixture.updates.count, 1)
    }

    func testStopDuringIdentityDoesNotStartQuota() async throws {
        let fixture = AgyFixture()
        defer { fixture.stop() }
        fixture.provider.start()
        let identity = try await fixture.server.request(at: 0)
        fixture.provider.stop()
        try await fixture.server.waitForCancellation(of: identity)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.server.requestCount, 1)
        XCTAssertEqual(fixture.updates.count, 0)
    }

    func testMissingPlanStillUpdatesAccount() async throws {
        let fixture = AgyFixture()
        defer { fixture.stop() }
        fixture.provider.start()
        let identity = try await fixture.server.request(at: 0)
        fixture.server.respond(to: identity, body: #"{"userStatus":{"email":"first@example.test"}}"#)
        let quota = try await fixture.server.request(at: 1)
        fixture.server.respond(to: quota, body: Self.quota(remaining: 1))
        let source = try await fixture.updates.source(at: 0)
        XCTAssertEqual(source.account, "first@example.test")
        XCTAssertNil(source.plan)
        XCTAssertEqual(source.state, .ok)
    }

    fileprivate static func identity(account: String, plan: String = "Google AI Ultra") -> String {
        """
        {"userStatus":{"email":"\(account)","userTier":{"name":"\(plan)"}}}
        """
    }

    fileprivate static func quota(remaining: Double) -> String {
        """
        {"response":{"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-5h","window":"5h","remainingFraction":\(remaining),"resetTime":"2026-09-06T01:00:00Z"}
        ]}]}}
        """
    }
}

private final class AgyFixture: @unchecked Sendable {
    let server = AgyMockServer()
    let updates = AgyUpdates()
    let session: URLSession
    let provider: AgyProvider

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgyMockProtocol.self]
        session = URLSession(configuration: configuration)
        provider = AgyProvider(session: session, environment: ["LLM_USAGE_AGY_PORT": String(server.port)]) { [updates] in
            updates.append($0)
        }
    }

    func stop() {
        provider.stop()
        session.invalidateAndCancel()
        AgyMockProtocol.registry.remove(port: server.port)
    }

    @MainActor
    func completeFetch(at index: Int, account: String, remaining: Double) async throws {
        let identity = try await server.request(at: index)
        server.respond(to: identity, body: AgyProviderTests.identity(account: account))
        let quota = try await server.request(at: index + 1)
        server.respond(to: quota, body: AgyProviderTests.quota(remaining: remaining))
    }
}

private final class AgyUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UsageSource] = []

    var count: Int { lock.withLock { values.count } }
    func append(_ value: UsageSource) { lock.withLock { values.append(value) } }

    func source(at index: Int) async throws -> UsageSource {
        try await agyWait {
            self.lock.withLock { self.values.indices.contains(index) ? self.values[index] : nil }
        }
    }
}

private final class AgyMockServer: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AgyMockProtocol] = []
    private var cancellations: Set<ObjectIdentifier> = []
    lazy var port = AgyMockProtocol.registry.add(self)

    var requestCount: Int { lock.withLock { requests.count } }
    func receive(_ request: AgyMockProtocol) { lock.withLock { requests.append(request) } }
    func cancel(_ request: AgyMockProtocol) {
        _ = lock.withLock { cancellations.insert(ObjectIdentifier(request)) }
    }

    func request(at index: Int) async throws -> AgyMockProtocol {
        try await agyWait {
            self.lock.withLock { self.requests.indices.contains(index) ? self.requests[index] : nil }
        }
    }

    func waitForCancellation(of request: AgyMockProtocol) async throws {
        let _: Bool = try await agyWait {
            self.lock.withLock { self.cancellations.contains(ObjectIdentifier(request)) ? true : nil }
        }
    }

    func respond(to request: AgyMockProtocol, status: Int = 200, body: String) {
        let response = HTTPURLResponse(url: request.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: Data(body.utf8))
        request.client?.urlProtocolDidFinishLoading(request)
    }
}

private final class AgyMockRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var nextPort = 40_000
    private var servers: [Int: AgyMockServer] = [:]

    func add(_ server: AgyMockServer) -> Int {
        lock.withLock {
            nextPort += 1
            servers[nextPort] = server
            return nextPort
        }
    }

    func server(port: Int) -> AgyMockServer? { lock.withLock { servers[port] } }
    func remove(port: Int) { _ = lock.withLock { servers.removeValue(forKey: port) } }
}

private final class AgyMockProtocol: URLProtocol, @unchecked Sendable {
    static let registry = AgyMockRegistry()
    private var server: AgyMockServer? {
        request.url?.port.flatMap { Self.registry.server(port: $0) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let server else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        server.receive(self)
    }
    override func stopLoading() { server?.cancel(self) }
}

private func agyWait<Value: Sendable>(_ value: @Sendable () -> Value?) async throws -> Value {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if let result = value() { return result }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw NSError(domain: "AgyProviderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for mock provider"])
}
