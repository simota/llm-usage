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

private struct AccountInfo: Decodable {
    let email: String?
}

private struct AccountPayload: Decodable {
    let account: AccountInfo?
}

private struct AccountEnvelope: Decodable {
    let result: AccountPayload?
}

private struct RPCEnvelope: Decodable {
    let id: Int?
    let method: String?
    let result: RateLimitsPayload?
    let params: RateLimitsPayload?
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
    private var process: Process?
    private var stdin: FileHandle?
    private var nextID = 1
    private var cachedAccount: String?
    private var lastGood: UsageSource?
    private var stopping = false
    private let lock = NSLock()

    /// A server we terminated on purpose is not a failure worth a red card.
    private struct ServerExited: LocalizedError {
        let status: Int32
        var errorDescription: String? { "codex app-server exited (status \(status))" }
    }

    private static let pollInterval: TimeInterval = 300

    init(onUpdate: @escaping @Sendable (Result<UsageSource, Error>) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        // Resolved rather than looked up through `env`: a bundle launched by launchd
        // or Finder has only the system PATH, so `env codex` failed silently and left
        // the card blank for every Homebrew install (see `CLI`).
        guard let executable = CLI.path("codex") else {
            // Metering Codex is optional, so this is a card that says what is missing,
            // not an error (docs/design.md §6).
            var source = UsageSource.placeholder(id: "codex", name: "Codex")
            source.note = CLI.NotFound(tool: "codex").errorDescription
            onUpdate(.success(source))
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["app-server"]
        // An npm-installed `codex` is a script that has to find `node` itself.
        proc.environment = CLI.environment()

        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        // The binary prints a PATH-alias warning to stderr; stdout is the protocol.
        proc.standardError = FileHandle.nullDevice

        // Without this the card just stays empty when the server dies on startup —
        // the failure mode that hid the PATH problem in the first place.
        proc.terminationHandler = { [weak self] finished in
            guard let self, !self.isStopping() else { return }
            self.onUpdate(.failure(ServerExited(status: finished.terminationStatus)))
        }

        do {
            try proc.run()
        } catch {
            onUpdate(.failure(error))
            return
        }

        process = proc
        stdin = inPipe.fileHandleForWriting

        let handle = outPipe.fileHandleForReading
        Thread.detachNewThread { [weak self] in self?.readLoop(handle) }

        send(method: "initialize", params: [
            "clientInfo": ["name": "llm-usage", "title": "LLM Usage", "version": "0.1.0"]
        ])
        refresh()

        Thread.detachNewThread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: Self.pollInterval)
                guard let self, self.process?.isRunning == true else { return }
                self.refresh()
            }
        }
    }

    func refresh() {
        send(method: "account/rateLimits/read", params: nil)
        if cachedAccount == nil { send(method: "account/read", params: [:]) }
    }

    func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
        process?.terminate()
        process = nil
    }

    private func isStopping() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    // MARK: - Transport

    private func send(method: String, params: [String: Any]?) {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()

        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        payload["params"] = params ?? NSNull()

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var line = data
        line.append(0x0A)
        do {
            try stdin?.write(contentsOf: line)
        } catch {
            onUpdate(.failure(error))
        }
    }

    private func readLoop(_ handle: FileHandle) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                dispatch(line: line)
            }
        }
    }

    private func dispatch(line: Data) {
        // account/read carries the signed-in address; try it first, since the
        // rate-limits shape would decode it as an empty result.
        if let account = try? JSONDecoder().decode(AccountEnvelope.self, from: line),
           let email = account.result?.account?.email, !email.isEmpty {
            cachedAccount = email
            if var previous = lastGood {
                previous.account = email
                onUpdate(.success(previous))
            }
            return
        }

        guard let env = try? JSONDecoder().decode(RPCEnvelope.self, from: line) else { return }
        // Either a reply to account/rateLimits/read, or an account/rateLimits/updated push.
        guard let payload = env.result ?? env.params else { return }
        var source = Self.normalise(payload)
        source.account = cachedAccount
        lastGood = source
        onUpdate(.success(source))
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
            .compactMap { key, snap in
                window(snap.primary, id: "codex-\(key)",
                       label: shortLabel(snap.limitName) ?? key)
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
            // A named limit identifies itself; appending "7d" only pushed it past
            // the label column, and the reset column already dates it.
            label: label ?? self.label(forMinutes: w.windowDurationMins),
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
