import Foundation

// MARK: - Wire types
//
// Mirrors GetAccountRateLimitsResponse from `codex app-server generate-json-schema`.
// See docs/feasibility.md §1.

private struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
}

private struct CreditsSnapshot: Decodable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?
}

private struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let planType: String?
}

/// A free "Full reset" grant that can be spent to clear the rate limit early.
private struct ResetCredit: Decodable {
    let status: String?
    let expiresAt: Double?
}

private struct ResetCreditsSummary: Decodable {
    let availableCount: Int?
    let credits: [ResetCredit]?
}

private struct RateLimitsPayload: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: ResetCreditsSummary?
}

private struct AccountInfo: Decodable, Equatable {
    let type: String?
    let email: String?
    let planType: String?
}

private struct AccountPayload: Decodable {
    let account: AccountInfo?
}

private struct RPCResult<Value: Decodable>: Decodable {
    let result: Value
}

private struct InitializedPayload: Decodable {}

private struct RPCError: Decodable {
    let code: Int
    let message: String
}

private struct RPCEnvelope: Decodable {
    let id: Int?
    let method: String?
    let error: RPCError?
}

// MARK: - Provider

/// Common shape for everything that feeds a card.
protocol UsageProviding: AnyObject, Sendable {
    func start()
    func refresh()
    func stop()
}

/// Runs `codex app-server` as a child process and speaks line-delimited JSON-RPC to it.
///
/// Reads `account/rateLimits/read` once at startup, then relies on the server's
/// `account/rateLimits/updated` push notifications, with a slow poll as a backstop.
final class CodexProvider: @unchecked Sendable, UsageProviding {
    private let onUpdate: @Sendable (Result<UsageSource, Error>) -> Void
    private let makeProcess: @Sendable () throws -> Process
    private let requestTimeout: TimeInterval
    private let pollInterval: TimeInterval
    // Transport callbacks and all mutable provider state share this queue.
    private let queue = DispatchQueue(label: "llm-usage.codex")
    private let queueKey = DispatchSpecificKey<Void>()
    private enum State { case starting, ready, failed, stopped }
    private var state: State = .stopped
    private var process: Process?
    private var stdin: FileHandle?
    private var nextID = 1
    private var generation = 0
    private var cachedAccount: AccountInfo?
    private var publishedAccount: AccountInfo?
    private var hasPublishedUsage = false
    private var pollTimer: DispatchSourceTimer?
    private struct PendingRequest {
        let method: String
        let timeout: DispatchWorkItem
    }
    private var pending: [Int: PendingRequest] = [:]

    /// A server we terminated on purpose is not a failure worth a red card.
    private struct ServerExited: LocalizedError {
        let status: Int32
        var errorDescription: String? { "codex app-server exited (status \(status))" }
    }

    private struct RequestFailed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(makeProcess: @escaping @Sendable () throws -> Process = CodexProvider.serverProcess,
         requestTimeout: TimeInterval = 20,
         pollInterval: TimeInterval = 300,
         onUpdate: @escaping @Sendable (Result<UsageSource, Error>) -> Void) {
        self.makeProcess = makeProcess
        self.requestTimeout = requestTimeout
        self.pollInterval = pollInterval
        self.onUpdate = onUpdate
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { stop() }

    func start() {
        queue.async { [self] in
            guard state == .stopped else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            timer.setEventHandler { [weak self] in self?.refreshOnQueue() }
            pollTimer = timer
            timer.resume()
            connect()
        }
    }

    private static func serverProcess() throws -> Process {
        guard let executable = CLI.path("codex") else { throw CLI.NotFound(tool: "codex") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["app-server"]
        proc.environment = CLI.environment(for: "codex")
        return proc
    }

    private func connect() {
        disconnect()
        state = .starting
        let currentGeneration = generation
        let proc: Process
        do {
            proc = try makeProcess()
        } catch let error as CLI.NotFound {
            state = .failed
            var source = UsageSource.placeholder(id: "codex", name: "Codex")
            source.note = error.errorDescription
            onUpdate(.success(source))
            return
        } catch {
            fail(error)
            return
        }
        let inPipe = Pipe(), outPipe = Pipe()
        // A server may exit between the running check and a write to its pipe.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] finished in
            self?.queue.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.fail(ServerExited(status: finished.terminationStatus))
            }
        }
        do {
            try proc.run()
        } catch {
            fail(error)
            return
        }
        process = proc
        stdin = inPipe.fileHandleForWriting
        let handle = outPipe.fileHandleForReading
        let callbackQueue = queue
        Thread.detachNewThread { [weak self] in
            defer { try? handle.close() }
            var buffer = Data()
            while true {
                // read(upToCount:) waits to fill its buffer on macOS pipes.
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<nl])
                    buffer.removeSubrange(buffer.startIndex...nl)
                    callbackQueue.async { [weak self] in
                        guard let self, self.generation == currentGeneration else { return }
                        self.dispatch(line: line)
                    }
                }
            }
        }
        send(method: "initialize", params: [
            "clientInfo": ["name": "llm-usage", "title": "LLM Usage", "version": "0.1.0"]
        ])
    }

    func refresh() {
        queue.async { [weak self] in self?.refreshOnQueue() }
    }

    private func refreshOnQueue() {
        switch state {
        case .stopped, .starting: return
        case .failed: connect()
        case .ready:
            guard process?.isRunning == true else { connect(); return }
            guard pending.isEmpty else { return }
            // Recheck identity before every snapshot so an external login cannot
            // attach usage from one account to the previous account's address.
            send(method: "account/read", params: [:])
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopOnQueue()
        } else {
            queue.sync { stopOnQueue() }
        }
    }

    private func stopOnQueue() {
        state = .stopped
        pollTimer?.cancel()
        pollTimer = nil
        disconnect()
    }

    private func disconnect() {
        generation += 1
        for request in pending.values { request.timeout.cancel() }
        pending.removeAll()
        cachedAccount = nil
        try? stdin?.close()
        stdin = nil
        if let proc = process {
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                }
            }
        }
        process = nil
    }

    private func fail(_ error: Error) {
        disconnect()
        state = .failed
        onUpdate(.failure(error))
    }

    // MARK: - Transport

    private func send(method: String, params: [String: Any]?) {
        let id = nextID
        nextID += 1
        let currentGeneration = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration, self.pending[id] != nil else { return }
            self.fail(RequestFailed(message: "Codex \(method) timed out. Retry to reconnect."))
        }
        pending[id] = PendingRequest(method: method, timeout: timeout)
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
        write(["id": id, "method": method, "params": params ?? NSNull()])
    }

    private func write(_ message: [String: Any]) {
        do {
            guard let stdin, process?.isRunning == true else {
                throw RequestFailed(message: "Codex is disconnected. Retry to reconnect.")
            }
            var payload = message
            payload["jsonrpc"] = "2.0"
            var line = try JSONSerialization.data(withJSONObject: payload)
            line.append(0x0A)
            try stdin.write(contentsOf: line)
        } catch {
            fail(error)
        }
    }

    private func dispatch(line: Data) {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(RPCEnvelope.self, from: line) else { return }
        if envelope.id == nil {
            guard state == .ready else { return }
            switch envelope.method {
            case "account/updated":
                for request in pending.values { request.timeout.cancel() }
                pending.removeAll()
                cachedAccount = nil
                if hasPublishedUsage {
                    hasPublishedUsage = false
                    onUpdate(.success(.placeholder(id: "codex", name: "Codex")))
                }
                refreshOnQueue()
            case "account/rateLimits/updated":
                // Pushes are sparse. Refetch a complete snapshot and its identity.
                refreshOnQueue()
            default: break
            }
            return
        }
        guard let id = envelope.id, let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        if let error = envelope.error {
            fail(RequestFailed(message: "Codex \(request.method) failed (\(error.code)): \(error.message)"))
            return
        }
        do {
            switch request.method {
            case "initialize":
                _ = try decoder.decode(RPCResult<InitializedPayload>.self, from: line)
                write(["method": "initialized"])
                guard state == .starting else { return }
                state = .ready
                refreshOnQueue()
            case "account/read":
                let account = try decoder.decode(RPCResult<AccountPayload>.self, from: line).result.account
                if hasPublishedUsage, account != publishedAccount {
                    hasPublishedUsage = false
                    var source = UsageSource.placeholder(id: "codex", name: "Codex")
                    source.account = account?.email
                    source.plan = account?.planType?.capitalized
                    onUpdate(.success(source))
                }
                cachedAccount = account
                send(method: "account/rateLimits/read", params: nil)
            case "account/rateLimits/read":
                let payload = try decoder.decode(RPCResult<RateLimitsPayload>.self, from: line).result
                var source = Self.normalise(payload)
                source.account = cachedAccount?.email
                publishedAccount = cachedAccount
                hasPublishedUsage = true
                onUpdate(.success(source))
            default: break
            }
        } catch {
            fail(RequestFailed(message: "Codex returned an invalid \(request.method) response."))
        }
    }

    // MARK: - Normalisation

    private static func normalise(_ payload: RateLimitsPayload) -> UsageSource {
        let snapshot = payload.rateLimits
        var source = UsageSource(id: "codex", displayName: "Codex")
        source.plan = snapshot.planType?.capitalized
        source.staleAfter = 600
        source.lastUpdated = Date()
        source.state = .ok

        // Each additional metered limit is a window in its own right — Spark has
        // its own duration and its own reset — so flattening them to a bucket
        // percentage threw away the reset time and hid them once they read 0%.
        let extras = (payload.rateLimitsByLimitId ?? [:])
            .sorted { $0.key < $1.key }
            .filter { key, _ in key != snapshot.limitId }
            .flatMap { key, snap in
                [window(snap.primary, id: "codex-\(key)-primary",
                        label: shortLabel(snap.limitName) ?? key),
                 window(snap.secondary, id: "codex-\(key)-secondary",
                        label: shortLabel(snap.limitName) ?? key)].compactMap { $0 }
            }

        source.windows = ([
            window(snapshot.primary, id: "codex-primary"),
            window(snapshot.secondary, id: "codex-secondary"),
        ].compactMap { $0 }) + extras

        source.note = notes(snapshot: snapshot, resets: payload.rateLimitResetCredits)
        return source
    }

    private static func notes(snapshot: RateLimitSnapshot,
                              resets: ResetCreditsSummary?) -> String? {
        var parts: [String] = []

        // Free rate-limit resets: the most actionable thing on this card when the
        // weekly limit is running hot, and they expire.
        let available = (resets?.credits ?? []).filter { $0.status == "available" }
        let count = resets?.availableCount ?? available.count
        if count > 0 {
            let soonest = available.compactMap(\.expiresAt).min()
                .map { Date(timeIntervalSince1970: $0) }
            let deadline = soonest.map { " (first expires \(Format.resetsIn($0)))" } ?? ""
            parts.append("\(count) free reset\(count == 1 ? "" : "s")\(deadline)")
        }

        // Only worth a line when there is actually a balance — "balance 0" on an
        // account with no credits is noise.
        if let credits = snapshot.credits, credits.unlimited != true,
           credits.hasCredits == true, let balance = credits.balance,
           let amount = Double(balance), amount != 0 {
            parts.append("Credit balance \(balance)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func window(_ w: RateLimitWindow?, id: String,
                               label: String? = nil) -> UsageWindow? {
        guard let w else { return nil }
        return UsageWindow(
            id: id,
            label: [label, self.label(forMinutes: w.windowDurationMins)]
                .compactMap { $0 }.joined(separator: " "),
            usedPercent: w.usedPercent,
            resetsAt: w.resetsAt.map { Date(timeIntervalSince1970: $0) },
            windowMinutes: w.windowDurationMins
        )
    }

    /// "GPT-5.3-Codex-Spark" -> "Spark". The full name needs ~124pt at label size,
    /// which no column width leaves room for; the trailing component is what
    /// distinguishes one limit from another and is unambiguous inside this card.
    private static func shortLabel(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return name.split(separator: "-").last.map(String.init) ?? name
    }

    private static func label(forMinutes minutes: Int?) -> String {
        switch minutes {
        case .some(300): return "5h"
        case .some(10_080): return "7d"
        case .some(let m): return "\(m / 60)h"
        case nil: return "—"
        }
    }
}
