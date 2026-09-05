import Foundation
import XCTest
@testable import LLMUsage

final class CodexProviderTests: XCTestCase {
    private static let usage = #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":50,"windowDurationMins":300,"resetsAt":2000000000},"secondary":null,"planType":"pro"},"rateLimitsByLimitId":{"spark":{"limitName":"GPT-Codex-Spark","primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":99,"windowDurationMins":10080}}}}"#

    private static func process(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["PATH": "/usr/bin:/bin"]
        return process
    }

    private static func server(initialize: String = "", account: String = "", usage: String = "") -> String {
        #"""
        while IFS= read -r line; do
            id=$(printf '%s' "$line" | sed -nE 's/.*"id":([0-9]+).*/\1/p')
            case "$line" in
                *'"method":"initialized"'*) ready=yes ;;
                *'"method":"initialize"'*)
                    \#(initialize)
                    printf '{"id":%s,"result":{}}\n' "$id"
                    ;;
                *rateLimits*read*)
                    \#(usage)
                    printf '{"id":%s,"result":%s}\n' "$id" '\#(Self.usage)'
                    ;;
                *account*read*)
                    if [ "$ready" != yes ]; then
                        printf '{"id":%s,"error":{"code":-32002,"message":"Not initialized"}}\n' "$id"
                        continue
                    fi
                    \#(account)
                    printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"one@example.test","planType":"pro"}}}\n' "$id"
                    ;;
            esac
        done
        """#
    }

    func testHandshakeWaitsForInitializationAndKeepsBothAdditionalWindows() {
        let received = expectation(description: "complete authenticated snapshot")
        let results = Mutex<[UsageSource]>([])
        let script = Self.server(initialize: "sleep 0.05")
        let provider = CodexProvider(makeProcess: { Self.process(script) }) { result in
            switch result {
            case .success(let source) where source.state == .ok:
                results.withLock { $0.append(source) }
                received.fulfill()
            case .failure(let error): XCTFail(error.localizedDescription)
            default: XCTFail("Initial identity lookup must not publish an incomplete sample")
            }
        }
        provider.start()
        wait(for: [received], timeout: 3)
        provider.stop()
        let source = results.withLock { $0.first }
        XCTAssertEqual(source?.account, "one@example.test")
        XCTAssertEqual(source?.windows.map(\.id), ["codex-primary", "codex-spark-primary", "codex-spark-secondary"])
        XCTAssertEqual(source?.windows.map(\.label), ["5h", "Spark 5h", "Spark 7d"])
        XCTAssertEqual(source?.worstWindow?.usedPercent, 99)
    }

    func testRPCErrorIsReportedWithRequestMethod() {
        let failed = expectation(description: "RPC authentication error")
        let script = Self.server(account: #"""
            printf '{"id":%s,"error":{"code":401,"message":"Not authenticated"}}\n' "$id"
            continue
            """#)
        let provider = CodexProvider(makeProcess: { Self.process(script) }) { result in
            guard case .failure(let error) = result else { return }
            XCTAssertTrue(error.localizedDescription.contains("account/read"))
            XCTAssertTrue(error.localizedDescription.contains("Not authenticated"))
            failed.fulfill()
        }
        provider.start()
        wait(for: [failed], timeout: 3)
        provider.stop()
    }

    func testInitializeErrorDoesNotFetchUsage() {
        let failed = expectation(description: "initialize error")
        let script = Self.server(initialize: #"""
            printf '{"id":%s,"error":{"code":-32602,"message":"Unsupported client"}}\n' "$id"
            continue
            """#)
        let provider = CodexProvider(makeProcess: { Self.process(script) }) { result in
            switch result {
            case .failure(let error):
                XCTAssertTrue(error.localizedDescription.contains("initialize"))
                failed.fulfill()
            case .success: XCTFail("An initialization error must not publish usage")
            }
        }
        provider.start()
        wait(for: [failed], timeout: 3)
        provider.stop()
    }

    func testRefreshReconnectsAfterServerExit() {
        let failed = expectation(description: "first server exited")
        let received = expectation(description: "replacement server returned usage")
        let starts = Mutex(0)
        let script = Self.server()
        let provider = CodexProvider(makeProcess: {
            let count = starts.withLock { $0 += 1; return $0 }
            return Self.process(count == 1 ? "exit 7" : script)
        }) { result in
            switch result {
            case .failure: failed.fulfill()
            case .success(let source) where source.state == .ok: received.fulfill()
            default: break
            }
        }
        provider.start()
        wait(for: [failed], timeout: 3)
        provider.refresh()
        wait(for: [received], timeout: 3)
        provider.stop()
        XCTAssertEqual(starts.withLock { $0 }, 2)
    }

    func testTimeoutCanBeRetriedAndDuplicateStartsAreIgnored() {
        let failed = expectation(description: "silent server timed out")
        let received = expectation(description: "retry succeeded")
        let starts = Mutex(0)
        let script = Self.server()
        let provider = CodexProvider(makeProcess: {
            let count = starts.withLock { $0 += 1; return $0 }
            return Self.process(count == 1 ? "while IFS= read -r line; do :; done" : script)
        }, requestTimeout: 0.2) { result in
            switch result {
            case .failure(let error):
                XCTAssertTrue(error.localizedDescription.contains("timed out"))
                failed.fulfill()
            case .success(let source) where source.state == .ok: received.fulfill()
            default: break
            }
        }
        provider.start()
        provider.start()
        wait(for: [failed], timeout: 3)
        XCTAssertEqual(starts.withLock { $0 }, 1)
        provider.refresh()
        wait(for: [received], timeout: 3)
        provider.stop()
        XCTAssertEqual(starts.withLock { $0 }, 2)
    }

    func testAccountChangeClearsOldUsageBeforeNewSnapshot() {
        let first = expectation(description: "first account snapshot")
        let second = expectation(description: "second account snapshot")
        let samples = Mutex<[UsageSource]>([])
        let script = Self.server(account: #"""
            accounts=$((accounts + 1))
            if [ "$accounts" -gt 1 ]; then
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"two@example.test","planType":"plus"}}}\n' "$id"
                continue
            fi
            """#, usage: #"""
            if [ "$accounts" -gt 1 ]; then
                printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300},"planType":"plus"}}}\n' "$id"
                continue
            fi
            """#)
        let provider = CodexProvider(makeProcess: { Self.process(script) }) { result in
            guard case .success(let source) = result else { return }
            samples.withLock { $0.append(source) }
            if source.state == .ok {
                if source.account == "one@example.test" { first.fulfill() }
                if source.account == "two@example.test" { second.fulfill() }
            }
        }
        provider.start()
        wait(for: [first], timeout: 3)
        provider.refresh()
        wait(for: [second], timeout: 3)
        provider.stop()
        let secondAccount = samples.withLock { $0.filter { $0.account == "two@example.test" } }
        XCTAssertEqual(secondAccount.count, 2)
        XCTAssertEqual(secondAccount.first?.state, .unconfigured)
        XCTAssertEqual(secondAccount.first?.windows, [])
        XCTAssertEqual(secondAccount.last?.windows.first?.usedPercent, 10)
    }

    func testUnknownResponseIDCannotPublishSnapshot() {
        let received = expectation(description: "only matching response accepted")
        let samples = Mutex<[UsageSource]>([])
        let script = Self.server(usage: #"""
            printf '{"id":99999,"result":{"rateLimits":{"primary":{"usedPercent":100}}}}\n'
            """#)
        let provider = CodexProvider(makeProcess: { Self.process(script) }) { result in
            guard case .success(let source) = result, source.state == .ok else { return }
            samples.withLock { $0.append(source) }
            received.fulfill()
        }
        provider.start()
        wait(for: [received], timeout: 3)
        provider.stop()
        XCTAssertEqual(samples.withLock { $0.count }, 1)
        XCTAssertEqual(samples.withLock { $0.first?.windows.first?.usedPercent }, 50)
    }

    func testAccountNotificationInvalidatesOlderInFlightResponse() {
        let received = expectation(description: "only the new account snapshot is published")
        let samples = Mutex<[UsageSource]>([])
        let script = Self.server(account: #"""
            accounts=$((accounts + 1))
            if [ "$accounts" -gt 1 ]; then
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"two@example.test"}}}\n' "$id"
                continue
            fi
            """#, usage: #"""
            if [ "$accounts" -eq 1 ]; then
                old_id=$id
                printf '{"method":"account/updated","params":{"authMode":"chatgpt"}}\n'
                continue
            fi
            printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":100}}}}\n' "$old_id"
            printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":10}}}}\n' "$id"
            continue
            """#)
        let provider = CodexProvider(makeProcess: { Self.process(script) }) { result in
            guard case .success(let source) = result, source.state == .ok else { return }
            samples.withLock { $0.append(source) }
            received.fulfill()
        }
        provider.start()
        wait(for: [received], timeout: 3)
        provider.stop()
        XCTAssertEqual(samples.withLock { $0.count }, 1)
        XCTAssertEqual(samples.withLock { $0.first?.account }, "two@example.test")
        XCTAssertEqual(samples.withLock { $0.first?.windows.first?.usedPercent }, 10)
    }

    func testStoppedProviderCanStartAgain() {
        let first = expectation(description: "first start")
        let second = expectation(description: "second start")
        let starts = Mutex(0)
        let received = Mutex(0)
        let script = Self.server()
        let provider = CodexProvider(makeProcess: {
            starts.withLock { $0 += 1 }
            return Self.process(script)
        }) { result in
            guard case .success(let source) = result, source.state == .ok else { return }
            let count = received.withLock { $0 += 1; return $0 }
            if count == 1 { first.fulfill() }
            else { second.fulfill() }
        }
        provider.start()
        wait(for: [first], timeout: 3)
        provider.stop()
        provider.start()
        wait(for: [second], timeout: 3)
        provider.stop()
        XCTAssertEqual(starts.withLock { $0 }, 2)
    }

    func testStopCancelsPendingTimeoutAndPreventsLateCallbacks() {
        let started = expectation(description: "mock process created")
        let unexpected = expectation(description: "callback after stop")
        unexpected.isInverted = true
        let provider = CodexProvider(makeProcess: {
            started.fulfill()
            return Self.process("while IFS= read -r line; do :; done")
        }, requestTimeout: 0.1) { _ in unexpected.fulfill() }
        provider.start()
        wait(for: [started], timeout: 3)
        provider.stop()
        provider.refresh()
        wait(for: [unexpected], timeout: 0.2)
    }
}
