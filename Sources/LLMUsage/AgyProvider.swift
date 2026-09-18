import Foundation

// The read-only /usage command returns structured quota data in command.data.
// Fractions represent what remains, and reset times are RFC3339 strings.
private struct AgyBucket: Decodable {
    let id: String
    let window: String
    let remainingFraction: Double?
    let resetTime: String?

    enum CodingKeys: String, CodingKey {
        case id, window
        case remainingFraction = "remaining_fraction"
        case resetTime = "reset_time"
    }
}

private struct AgyGroup: Decodable {
    let name: String
    let buckets: [AgyBucket]
}

private struct AgyQuotaSummary: Decodable {
    let groups: [AgyGroup]
}

private struct AgyEnvelope: Decodable {
    let status: String
    let num_turns: Int
    let command: Command

    struct Command: Decodable {
        let name: String
        let data: AgyQuotaSummary
    }
}

/// Asks agy for usage through its read-only print command. The CLI owns login
/// and local-server authentication; no session credentials are read here.
final class AgyProvider: @unchecked Sendable, UsageProviding {
    typealias CommandRunner = @Sendable (
        String, [String], [String: String], TimeInterval, @Sendable () -> Bool
    ) -> Result<String, CLI.RunFailure>

    private static let pollInterval: TimeInterval = 300
    private static let windowMinutes = ["5h": 300, "weekly": 10_080]
    private let onUpdate: @Sendable (UsageSource) -> Void
    private let resolveCLI: @Sendable () -> CLI.Resolution?
    private let runCommand: CommandRunner
    private let queue = DispatchQueue(label: "llm-usage.agy")
    private let queueKey = DispatchSpecificKey<Void>()
    private var timer: DispatchSourceTimer?
    private var isStarted = false
    private var generation = 0
    private var cancellation: Mutex<Bool>?
    private var fetchFinished: DispatchGroup?
    private var lastGood: UsageSource?

    init(
        resolveCLI: @escaping @Sendable () -> CLI.Resolution? = {
            guard let path = CLI.path("agy") else { return nil }
            return CLI.Resolution(path: path, environment: CLI.environment(for: "agy"))
        },
        runCommand: @escaping CommandRunner = { path, arguments, environment, timeout, isCancelled in
            CLI.run(executable: path, arguments: arguments, environment: environment,
                    timeout: timeout, isCancelled: isCancelled)
        },
        onUpdate: @escaping @Sendable (UsageSource) -> Void
    ) {
        self.onUpdate = onUpdate
        self.resolveCLI = resolveCLI
        self.runCommand = runCommand
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            self.generation += 1
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            timer.setEventHandler { [weak self] in self?.beginFetch() }
            timer.resume()
            self.timer = timer
            self.beginFetch()
        }
    }

    func refresh() {
        queue.async { [weak self] in self?.beginFetch() }
    }

    private func beginFetch() {
        guard isStarted, cancellation == nil else { return }
        let cancelled = Mutex(false)
        cancellation = cancelled
        let finished = DispatchGroup()
        finished.enter()
        fetchFinished = finished
        let generation = generation
        let resolveCLI = resolveCLI
        let runCommand = runCommand
        let queue = queue
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.readUsage(resolveCLI: resolveCLI, runCommand: runCommand,
                                        isCancelled: { cancelled.withLock { $0 } })
            finished.leave()
            queue.async { [weak self] in
                guard let self, self.isStarted, self.generation == generation else { return }
                self.cancellation = nil
                self.fetchFinished = nil
                switch result {
                case .success(let source):
                    self.lastGood = source
                    self.onUpdate(source)
                case .failure(let failure):
                    self.emitUnavailable(reason: failure.rawValue)
                }
            }
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
        isStarted = false
        generation += 1
        timer?.cancel()
        timer = nil
        cancellation?.withLock { $0 = true }
        // App termination follows stop(), so let CLI.run reap its child first.
        // A stalled resolver must not prevent the application from quitting.
        _ = fetchFinished?.wait(timeout: .now() + 1)
        cancellation = nil
        fetchFinished = nil
        lastGood = nil
    }

    deinit { stop() }

    private enum FetchFailure: String, Error {
        case missing = "agy not found (install Antigravity CLI)"
        case outdated = "Update Antigravity CLI (agy 1.1.11+ required)"
        case failed = "Antigravity unavailable (check agy /usage and login)"
        case timedOut = "Antigravity usage request timed out"
        case unexpected = "Unexpected Antigravity response (update agy)"
    }

    private static func readUsage(
        resolveCLI: @Sendable () -> CLI.Resolution?, runCommand: CommandRunner,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Result<UsageSource, FetchFailure> {
        guard !isCancelled() else { return .failure(.failed) }
        guard let cli = resolveCLI() else { return .failure(.missing) }
        // Older releases can treat /usage as a model prompt in print mode.
        // Check support before invoking it, including after a CLI downgrade.
        let version = runCommand(cli.path, ["--version"], cli.environment, 3, isCancelled)
        guard case .success(let text) = version else {
            return .failure(version == .failure(.timedOut) ? .timedOut : .failed)
        }
        guard supportsUsageCommand(version: text) else { return .failure(.outdated) }
        guard !isCancelled() else { return .failure(.failed) }
        let output = runCommand(cli.path, ["-p", "/usage", "--output-format", "json",
                                          "--print-timeout", "10s"], cli.environment, 10, isCancelled)
        guard case .success(let json) = output else {
            return .failure(output == .failure(.timedOut) ? .timedOut : .failed)
        }
        guard let envelope = try? JSONDecoder().decode(AgyEnvelope.self, from: Data(json.utf8)),
              envelope.status == "SUCCESS", envelope.num_turns == 0,
              envelope.command.name == "usage",
              envelope.command.data.groups.allSatisfy({ group in
                  group.buckets.allSatisfy { bucket in
                      !bucket.id.isEmpty && (bucket.remainingFraction.map { $0.isFinite && (0...1).contains($0) } ?? true)
                  }
              }) else { return .failure(.unexpected) }
        return .success(normalise(envelope.command.data))
    }

    static func supportsUsageCommand(version: String) -> Bool {
        let text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return false }
        return major > 1 || (major == 1 && (minor > 1 || (minor == 1 && patch >= 11)))
    }

    private func emitUnavailable(reason: String) {
        if var previous = lastGood {
            previous.note = reason
            previous.state = previous.lastUpdated.map { .stale(since: $0) } ?? .error(reason)
            onUpdate(previous)
        } else {
            var placeholder = UsageSource.placeholder(id: "agy", name: "Antigravity")
            placeholder.note = reason
            onUpdate(placeholder)
        }
    }

    private static func normalise(_ summary: AgyQuotaSummary) -> UsageSource {
        var source = UsageSource(id: "agy", displayName: "Antigravity")
        source.staleAfter = 900
        source.lastUpdated = Date()
        source.state = .ok
        source.note = "Shared with the desktop app and SDK"
        // /usage does not identify the account or plan. Keep both absent rather
        // than attaching an identity from another session to this snapshot.
        source.windows = summary.groups.flatMap { group -> [UsageWindow] in
            let short = shortName(group.name)
            return group.buckets.compactMap { window($0, group: short) }
                .sorted { ($0.windowMinutes ?? Int.max) < ($1.windowMinutes ?? Int.max) }
        }
        return source
    }

    private static func window(_ bucket: AgyBucket, group: String) -> UsageWindow? {
        guard let remaining = bucket.remainingFraction else { return nil }
        let label = bucket.window == "weekly" ? "7d" : bucket.window.isEmpty ? "—" : bucket.window
        return UsageWindow(
            id: bucket.id, label: "\(group) \(label)", usedPercent: (1 - remaining) * 100,
            resetsAt: bucket.resetTime.flatMap(parseTimestamp),
            windowMinutes: windowMinutes[bucket.window]
        )
    }

    private static func shortName(_ displayName: String) -> String {
        guard !displayName.isEmpty else { return "—" }
        var name = displayName
        for suffix in [" Models", " models"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name.replacingOccurrences(of: " and ", with: "/")
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
