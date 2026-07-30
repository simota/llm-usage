import Foundation
import Security

// MARK: - Wire types
//
// Shape recorded in docs/feasibility.md §2. `limits` is the normalised view and
// is preferred; the flat five_hour / seven_day pair is kept as a fallback in
// case an older build omits it.

private struct OAuthUsage: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
    }

    struct Scope: Decodable {
        struct Model: Decodable { let displayName: String? }
        let model: Model?
    }

    struct Limit: Decodable {
        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
        /// Which window is actually metering right now.
        let isActive: Bool?
    }

    struct Money: Decodable {
        let amountMinor: Double?
        let currency: String?
        let exponent: Int?
    }

    struct Spend: Decodable {
        let used: Money?
        let limit: Money?
        let percent: Double?
        let enabled: Bool?
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let limits: [Limit]?
    let spend: Spend?
}

// MARK: - Provider

/// Reads Claude.ai subscription limits from the OAuth usage endpoint, using the
/// token Claude Code already holds in the keychain.
///
/// Read-only by design. The access token lasts about an hour and only Claude Code
/// refreshes it; performing the refresh here would rotate the refresh token
/// server-side and, without writing the new one back, would invalidate the user's
/// Claude Code login. So an expired token is surfaced as staleness and the
/// keychain is re-read each cycle to pick up whatever Claude Code last wrote.
final class ClaudeProvider: @unchecked Sendable, UsageProviding {
    /// Overridable the same way AgyProvider takes its port: the throttle and retry
    /// path is unreachable against the real endpoint on demand, and shipping it
    /// unexercised is how "Rate limited" became a dead end in the first place.
    private static let endpoint: URL = {
        let fallback = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        return ProcessInfo.processInfo.environment["LLM_USAGE_CLAUDE_ENDPOINT"]
            .flatMap(URL.init(string:)) ?? fallback
    }()
    private static let service = "Claude Code-credentials"
    /// Below ~180s the endpoint drops into an aggressively rate-limited bucket.
    private static let pollInterval: TimeInterval = 300
    /// A throttle or a dead connection clears up on its own, so it deserves a
    /// retry sooner than the next poll — but backing off matters: the 429 bucket
    /// only widens if we keep knocking. Caps at the poll interval.
    private static let retryDelays: [TimeInterval] = [30, 60, 120, 300]

    private let onUpdate: @Sendable (UsageSource) -> Void
    private var timer: DispatchSourceTimer?
    private var lastGood: UsageSource?
    private var retryAttempt = 0
    private var retryScheduled = false
    private let queue = DispatchQueue(label: "llm-usage.claude")
    private lazy var userAgent = "claude-code/\(Self.claudeVersion() ?? "0.0.0")"
    private lazy var identity = Self.authStatus()

    init(onUpdate: @escaping @Sendable (UsageSource) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        refresh()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func refresh() {
        switch Self.credential() {
        case .missing:
            emitUnavailable(reason: "Not signed in to Claude Code")
        case .expired:
            // Not an error: Claude Code renews this the next time it runs.
            emitUnavailable(reason: "Token expired (launch Claude Code to renew)")
        case .token(let token):
            fetch(token: token)
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Credential

    private enum Credential {
        case token(String)
        case expired
        case missing
    }

    private static func credential() -> Credential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return .missing }

        // expiresAt is milliseconds since epoch.
        if let expiresAt = oauth["expiresAt"] as? Double,
           Date().timeIntervalSince1970 * 1000 >= expiresAt {
            return .expired
        }
        return .token(token)
    }

    // MARK: - Fetch

    private func fetch(token: String) {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Mandatory: without it the request lands in a heavily throttled bucket.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // Onto the provider's own queue: the retry bookkeeping below and the
            // timer that also calls `refresh()` must not interleave.
            self.queue.async {
                guard status == 200, let data else {
                    self.handleFailure(status: status, response: response)
                    return
                }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                guard let usage = try? decoder.decode(OAuthUsage.self, from: data) else {
                    self.emitUnavailable(reason: "Could not read the response")
                    return
                }
                var source = Self.normalise(usage)
                source.plan = self.identity.plan
                source.account = self.identity.account
                self.lastGood = source
                self.retryAttempt = 0
                self.onUpdate(source)
            }
        }.resume()
    }

    /// A throttle or an unreachable endpoint is temporary, and saying so matters:
    /// the first fetch after launch has no earlier reading to fall back on, so the
    /// card is left stating the problem and nothing else. Without a retry it stated
    /// it for a full poll interval.
    private func handleFailure(status: Int, response: URLResponse?) {
        var reason = Self.reason(for: status)

        if status == 429 || status == 0 {
            let delay = Self.retryAfter(response)
                ?? Self.retryDelays[min(retryAttempt, Self.retryDelays.count - 1)]
            retryAttempt += 1
            reason += " (retry \(Self.retryLabel(delay)))"
            scheduleRetry(after: delay)
        }
        emitUnavailable(reason: reason)
    }

    /// Not `Format.resetsIn`: a reset is minutes to days away and rounds to "in 0m"
    /// for the seconds a retry takes, which reads as "never".
    private static func retryLabel(_ delay: TimeInterval) -> String {
        delay < 60
            ? "in \(Int(delay.rounded()))s"
            : Format.resetsIn(Date().addingTimeInterval(delay))
    }

    private func scheduleRetry(after delay: TimeInterval) {
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.refresh()
        }
    }

    /// `Retry-After` is either a delay in seconds or an HTTP date. Honouring the
    /// server's own number beats guessing at it.
    private static func retryAfter(_ response: URLResponse?) -> TimeInterval? {
        guard let value = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }

        if let seconds = TimeInterval(value) { return max(1, seconds) }
        guard let date = httpDateFormatter.date(from: value) else { return nil }
        return max(1, date.timeIntervalSinceNow)
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    private static func reason(for status: Int) -> String {
        switch status {
        case 0: return "Cannot connect"
        case 401, 403: return "Token expired (launch Claude Code to renew)"
        case 429: return "Rate limited"
        default: return "Unavailable (HTTP \(status))"
        }
    }

    /// Keeps the last reading visible and lets it age into `.stale` rather than
    /// blanking the card whenever the token lapses between Claude Code runs.
    private func emitUnavailable(reason: String) {
        if var previous = lastGood {
            previous.note = reason
            onUpdate(previous)
        } else {
            var placeholder = UsageSource.placeholder(id: "claude", name: "Claude Code")
            placeholder.plan = identity.plan
            placeholder.account = identity.account
            placeholder.note = reason
            onUpdate(placeholder)
        }
    }

    // MARK: - Normalisation

    private static func normalise(_ usage: OAuthUsage) -> UsageSource {
        var source = UsageSource(id: "claude", displayName: "Claude Code")
        source.staleAfter = 900
        source.lastUpdated = Date()
        source.state = .ok

        var windows: [UsageWindow] = []
        var buckets: [UsageBucket] = []

        for limit in usage.limits ?? [] {
            guard let percent = limit.percent else { continue }
            switch limit.kind {
            case "session":
                windows.append(window(id: "claude-5h", label: "5h", percent: percent,
                                      resetsAt: limit.resetsAt, minutes: 300,
                                      isActive: limit.isActive == true))
            case "weekly_all":
                windows.append(window(id: "claude-7d", label: "7d", percent: percent,
                                      resetsAt: limit.resetsAt, minutes: 10_080,
                                      isActive: limit.isActive == true))
            default:
                // weekly_scoped and any future kind: model-specific, shown on expand.
                let name = limit.scope?.model?.displayName ?? limit.kind ?? "scoped"
                buckets.append(UsageBucket(id: "claude-\(name)", label: name, usedPercent: percent))
            }
        }

        // Fallback for a payload without the normalised array.
        if windows.isEmpty {
            if let w = usage.fiveHour?.utilization {
                windows.append(window(id: "claude-5h", label: "5h", percent: w,
                                      resetsAt: usage.fiveHour?.resetsAt, minutes: 300))
            }
            if let w = usage.sevenDay?.utilization {
                windows.append(window(id: "claude-7d", label: "7d", percent: w,
                                      resetsAt: usage.sevenDay?.resetsAt, minutes: 10_080))
            }
        }

        guard !windows.isEmpty else {
            var placeholder = UsageSource.placeholder(id: "claude", name: "Claude Code")
            placeholder.note = "No limit data returned"
            return placeholder
        }

        // Fixed order (5h then 7d). Sorting by consumption would make the rows
        // swap places as usage moves, which reads as the panel glitching.
        source.windows = windows
        source.buckets = buckets
        source.spend = spendRow(usage.spend)
        return source
    }

    private static func window(id: String, label: String, percent: Double,
                               resetsAt: String?, minutes: Int,
                               isActive: Bool = false) -> UsageWindow {
        UsageWindow(id: id, label: label, usedPercent: percent,
                    resetsAt: resetsAt.flatMap(parseTimestamp), windowMinutes: minutes,
                    isActive: isActive)
    }

    /// Rendered as a gauge row rather than prose so it can be compared against
    /// the windows above it.
    private static func spendRow(_ spend: OAuthUsage.Spend?) -> UsageSpend? {
        guard let spend, spend.enabled == true,
              let used = spend.used, let limit = spend.limit,
              let usedMinor = used.amountMinor, let limitMinor = limit.amountMinor,
              limitMinor > 0 else { return nil }

        let divisor = pow(10.0, Double(limit.exponent ?? 2))
        let symbol = (limit.currency ?? "USD") == "USD" ? "$" : (limit.currency ?? "")
        return UsageSpend(
            label: "Credits",
            usedPercent: spend.percent ?? (usedMinor / limitMinor * 100),
            detail: String(format: "%@%.2f", symbol, usedMinor / divisor)
        )
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        // The endpoint sends fractional seconds and a +00:00 offset.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    // MARK: - CLI lookups (once per launch)

    private static func claudeVersion() -> String? {
        // "2.1.220 (Claude Code)" -> "2.1.220"
        run("claude", ["--version"])?
            .split(separator: " ").first.map(String.init)
    }

    /// `claude auth status --json` gives both the plan and the signed-in address.
    private static func authStatus() -> (plan: String?, account: String?) {
        guard let json = run("claude", ["auth", "status", "--json"]),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }

        let plan = (root["subscriptionType"] as? String).flatMap { type -> String? in
            type.isEmpty ? nil : type.prefix(1).uppercased() + type.dropFirst()
        }
        let account = (root["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (plan, account)
    }

    /// The tool is resolved rather than run through `env`: a bundle launched by launchd
    /// gets only the system PATH, which is why plan and account read "—" there while a
    /// terminal run filled them in (see `CLI`).
    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        guard let executable = CLI.path(tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = CLI.environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
