import Foundation

// MARK: - Wire types
//
// Shape recorded in docs/feasibility.md §3. Note the two inversions relative to
// the other providers: this reports what is *left*, not what is used, and its
// reset times are RFC3339 strings rather than epoch seconds.

private struct AgyBucket: Decodable {
    let bucketId: String?
    let displayName: String?
    let description: String?
    let window: String?
    let remainingFraction: Double?
    let resetTime: String?
}

private struct AgyGroup: Decodable {
    let displayName: String?
    let description: String?
    let buckets: [AgyBucket]?
}

private struct AgyQuotaSummary: Decodable {
    let groups: [AgyGroup]?
}

private struct AgyEnvelope: Decodable {
    let response: AgyQuotaSummary
}

// MARK: - Provider

/// Talks to the language server that agy starts on localhost.
///
/// This needs no credentials: agy has already authenticated, and we are asking
/// its own process. The cost is that data only exists while agy runs — when it
/// exits the port closes, which surfaces as staleness rather than as an error
/// (docs/design.md §6).
final class AgyProvider: @unchecked Sendable, UsageProviding {
    private static let service = "exa.language_server_pb.LanguageServerService"
    private static let pollInterval: TimeInterval = 300
    private static let windowMinutes = ["5h": 300, "weekly": 10_080]

    private let onUpdate: @Sendable (UsageSource) -> Void
    private let logDirectory: String
    private let forcedPort: Int?
    private let session: URLSession

    private var timer: DispatchSourceTimer?
    private var isStarted = false
    private var generation = 0
    private var fetchTask: URLSessionDataTask?
    private var cachedPort: Int?
    private var lastGood: UsageSource?
    private var cachedPlan: String?
    private var cachedAccount: String?
    private let queue = DispatchQueue(label: "llm-usage.agy")

    init(
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onUpdate: @escaping @Sendable (UsageSource) -> Void
    ) {
        self.onUpdate = onUpdate
        self.session = session
        logDirectory = environment["LLM_USAGE_AGY_LOG_DIR"]
            ?? NSString(string: "~/.gemini/antigravity-cli/log").expandingTildeInPath
        forcedPort = environment["LLM_USAGE_AGY_PORT"].flatMap(Int.init)
            .flatMap { (1...65_535).contains($0) ? $0 : nil }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            self.generation += 1
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            t.setEventHandler { [weak self] in self?.beginFetch() }
            t.resume()
            self.timer = t
            self.beginFetch()
        }
    }

    func refresh() {
        queue.async { [weak self] in self?.beginFetch() }
    }

    private func beginFetch() {
        guard isStarted, fetchTask == nil else { return }
        guard let port = forcedPort ?? cachedPort ?? discoverPort() else {
            emitUnavailable(reason: "Antigravity not running")
            return
        }
        cachedPort = port
        fetchIdentity(port: port, generation: generation)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStarted = false
            self.generation += 1
            self.timer?.cancel()
            self.timer = nil
            self.fetchTask?.cancel()
            self.fetchTask = nil
            self.cachedPort = nil
            self.cachedPlan = nil
            self.cachedAccount = nil
            self.lastGood = nil
        }
    }

    deinit {
        timer?.cancel()
        fetchTask?.cancel()
    }

    // MARK: - Port discovery

    /// The language server binds a fresh random port per session and only
    /// announces it in the log, so this is the only way to find it.
    private func discoverPort() -> Int? {
        let fm = FileManager.default

        // cli.log is agy's symlink to the active session log. Its startup line
        // is near the beginning, so avoid metadata-walking every archived log
        // and decoding a potentially very large active log on the cold path.
        let cliLog = ((logDirectory as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("cli.log")
        if let text = Self.logPrefix(at: cliLog), let port = Self.lastHTTPPort(in: text) {
            return port
        }

        // Preserve the old discovery path when the symlink is absent, broken,
        // or has an unexpected log format.
        guard let names = try? fm.contentsOfDirectory(atPath: logDirectory) else { return nil }

        let newest = names
            .filter { $0.hasPrefix("cli-") && $0.hasSuffix(".log") }
            .map { (logDirectory as NSString).appendingPathComponent($0) }
            .compactMap { path -> (String, Date)? in
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let date = attrs[.modificationDate] as? Date else { return nil }
                return (path, date)
            }
            .max { $0.1 < $1.1 }?.0

        guard let newest, let text = try? String(contentsOfFile: newest, encoding: .utf8) else {
            return nil
        }
        return Self.lastHTTPPort(in: text)
    }

    private static func logPrefix(at path: String, byteLimit: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteLimit), !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func lastHTTPPort(in log: String) -> Int? {
        let pattern = #"listening on random port at (\d+) for HTTP\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(log.startIndex..., in: log)
        guard let match = regex.matches(in: log, range: range).last,
              let portRange = Range(match.range(at: 1), in: log) else { return nil }
        return Int(log[portRange])
    }

    // MARK: - Fetch

    private func request(port: Int, method: String) -> URLRequest? {
        guard let url = URL(string: "http://localhost:\(port)/\(Self.service)/\(method)")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)
        return request
    }

    /// The plan and the signed-in address both come from here. The plan is
    /// `userTier.name` ("Google AI Ultra"), not from
    /// `planStatus.planInfo.planName`. Those are different axes: planName is the
    /// Antigravity/Windsurf-lineage seat tier and reads "Pro" even for a Google
    /// AI Ultra subscriber, which understates the account. No fallback to it —
    /// a blank badge beats a wrong one.
    ///
    /// `GetUserStatus` also carries per-model quota, but every model in a group
    /// repeats that group's figure, so it adds nothing over the summary call.
    private func fetchIdentity(port: Int, generation: Int) {
        guard let request = request(port: port, method: "GetUserStatus") else {
            emitUnavailable(reason: "Invalid Antigravity port")
            return
        }
        fetchTask = session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            self.queue.async {
                guard self.isStarted, self.generation == generation else { return }
                self.fetchTask = nil
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let data,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = root["userStatus"] as? [String: Any] else {
                    self.failedFetch(status: code)
                    return
                }

                let account = (status["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if self.lastGood?.account != account {
                    self.lastGood = nil
                }
                self.cachedAccount = account
                self.cachedPlan = ((status["userTier"] as? [String: Any])?["name"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 }
                // Confirm identity before quota so a new login never relabels
                // the previous account's successful reading.
                self.fetch(port: port, generation: generation)
            }
        }
        fetchTask?.resume()
    }

    private func fetch(port: Int, generation: Int) {
        guard let request = request(port: port, method: "RetrieveUserQuotaSummary") else {
            emitUnavailable(reason: "Invalid Antigravity port")
            return
        }

        fetchTask = session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            self.queue.async {
                guard self.isStarted, self.generation == generation else { return }
                self.fetchTask = nil
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data,
                      let envelope = try? JSONDecoder().decode(AgyEnvelope.self, from: data) else {
                    self.failedFetch(status: status)
                    return
                }
                var source = Self.normalise(envelope.response)
                source.plan = self.cachedPlan
                source.account = self.cachedAccount
                self.lastGood = source
                self.onUpdate(source)
            }
        }
        fetchTask?.resume()
    }

    private func failedFetch(status: Int) {
        cachedPort = nil
        emitUnavailable(reason: status == 0 ? "Antigravity not running"
                        : status == 200 ? "Unexpected Antigravity response"
                        : "Unavailable (HTTP \(status))")
    }

    /// Retains the last successful sample and its timestamp as explicitly stale.
    private func emitUnavailable(reason: String) {
        if var previous = lastGood {
            previous.note = reason
            previous.state = previous.lastUpdated.map { .stale(since: $0) } ?? .error(reason)
            onUpdate(previous)
        } else {
            var placeholder = UsageSource.placeholder(id: "agy", name: "Antigravity")
            placeholder.plan = cachedPlan
            placeholder.account = cachedAccount
            placeholder.note = reason
            onUpdate(placeholder)
        }
    }

    // MARK: - Normalisation

    private static func normalise(_ summary: AgyQuotaSummary) -> UsageSource {
        var source = UsageSource(id: "agy", displayName: "Antigravity")
        source.staleAfter = 900
        source.lastUpdated = Date()
        source.state = .ok
        source.note = "Shared with the desktop app and SDK"

        // Every window, in a stable order — never "the worst one per group".
        // That made a row's meaning change under the reader: Gemini's row was
        // the 5h limit while it was busy and silently became the weekly one
        // after it reset. Unused windows collapse to a single line in the view,
        // so showing them all costs little.
        source.windows = (summary.groups ?? []).flatMap { group -> [UsageWindow] in
            let short = shortName(group.displayName)
            return (group.buckets ?? [])
                .compactMap { window($0, group: short) }
                .sorted { rank($0) < rank($1) }
        }
        // The windows now carry everything the buckets did.
        source.buckets = []
        return source
    }

    /// Shorter windows first, matching Claude's 5h-then-7d ordering.
    private static func rank(_ window: UsageWindow) -> Int {
        window.windowMinutes ?? Int.max
    }

    private static func window(_ bucket: AgyBucket, group: String) -> UsageWindow? {
        guard let remaining = bucket.remainingFraction else { return nil }
        let windowKey = bucket.window ?? ""
        return UsageWindow(
            id: bucket.bucketId ?? "\(group)-\(windowKey)",
            label: "\(group) \(windowLabel(windowKey))",
            usedPercent: (1 - remaining) * 100,
            resetsAt: bucket.resetTime.flatMap(parseTimestamp),
            // Unknown window strings leave this nil, which suppresses the pace
            // tick rather than inventing a duration.
            windowMinutes: windowMinutes[windowKey]
        )
    }

    private static func windowLabel(_ window: String) -> String {
        switch window {
        case "5h": return "5h"
        case "weekly": return "7d"
        default: return window.isEmpty ? "—" : window
        }
    }

    /// "Gemini Models" -> "Gemini", "Claude and GPT models" -> "Claude/GPT".
    private static func shortName(_ displayName: String?) -> String {
        guard var name = displayName, !name.isEmpty else { return "—" }
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
