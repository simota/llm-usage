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
    enum Endpoint: Equatable, Sendable {
        case production
        case test(URL)
        case invalid

        static func configured(_ environment: [String: String]) -> Endpoint {
            guard let override = environment["LLM_USAGE_CLAUDE_ENDPOINT"] else { return .production }
            guard let url = URL(string: override),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host?.lowercased() ?? ""),
                  url.user == nil, url.password == nil else { return .invalid }
            return .test(url)
        }

        var url: URL? {
            switch self {
            case .production: URL(string: "https://api.anthropic.com/api/oauth/usage")!
            case .test(let url): url
            case .invalid: nil
            }
        }
    }
    private static let service = "Claude Code-credentials"
    /// Below ~180s the endpoint drops into an aggressively rate-limited bucket.
    private static let pollInterval: TimeInterval = 300
    /// A throttle or a dead connection clears up on its own, so it deserves a
    /// retry sooner than the next poll — but backing off matters: the 429 bucket
    /// only widens if we keep knocking. Caps at the poll interval.
    private static let retryDelays: [TimeInterval] = [30, 60, 120, 300]

    private let onUpdate: @Sendable (UsageSource) -> Void
    private let endpoint: Endpoint
    private let session: URLSession
    private let credentialReader: @Sendable () -> Credential
    private let identityReader: @Sendable () -> AuthProbe
    private let versionReader: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private var timer: DispatchSourceTimer?
    private var lastGood: UsageSource?
    private var retryAttempt = 0
    private var retryTask: DispatchWorkItem?
    private var nextAllowedFetchAt: Date?
    private var fetchTask: URLSessionDataTask?
    private var inFlight = false
    private var running = false
    private var generation = 0
    private var sessionToken: String?
    private let queue = DispatchQueue(label: "llm-usage.claude")
    private lazy var userAgent = "claude-code/\(versionReader() ?? "0.0.0")"
    private var identity: AuthProbe = .unreachable

    convenience init(onUpdate: @escaping @Sendable (UsageSource) -> Void) {
        self.init(endpoint: .configured(ProcessInfo.processInfo.environment),
                  session: .shared, credentialReader: Self.credential,
                  identityReader: Self.authStatus, versionReader: Self.claudeVersion,
                  now: { Date() }, onUpdate: onUpdate)
    }

    init(endpoint: Endpoint, session: URLSession,
         credentialReader: @escaping @Sendable () -> Credential,
         identityReader: @escaping @Sendable () -> AuthProbe,
         versionReader: @escaping @Sendable () -> String? = { nil },
         now: @escaping @Sendable () -> Date = { Date() },
         onUpdate: @escaping @Sendable (UsageSource) -> Void) {
        self.endpoint = endpoint
        self.session = session
        self.credentialReader = credentialReader
        self.identityReader = identityReader
        self.versionReader = versionReader
        self.now = now
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.generation += 1
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            t.setEventHandler { [weak self] in self?.attemptFetch() }
            t.resume()
            self.timer = t
            self.attemptFetch()
        }
    }

    /// Hops onto the provider's queue rather than reading state on the caller's thread.
    /// The panel's Refresh calls this on the main thread while the timer calls it on
    /// `queue`, and both now *write* `identity` on the disagreement path below — as
    /// `lastGood` and the retry counters were already written from the fetch completion.
    /// One queue owns all of it.
    ///
    /// It also keeps the read off the main thread, which matters more than the race: it
    /// spawns `/usr/bin/security` and waits for it, and any Keychain read blocks for as
    /// long as an access dialog sits unanswered if it ever has to put one up. Observed
    /// with `make probe` when the read was an in-process `SecItemCopyMatching`, where the
    /// same call held the whole process until the prompt was dealt with.
    func refresh() {
        queue.async { [weak self] in self?.attemptFetch() }
    }

    private func attemptFetch() {
        guard running, !inFlight else { return }
        if let nextAllowedFetchAt, now() < nextAllowedFetchAt {
            scheduleRetry(at: nextAllowedFetchAt)
            return
        }
        retryTask?.cancel()
        retryTask = nil
        guard endpoint.url != nil else {
            emitUnavailable(reason: "Test endpoint must use a loopback URL")
            return
        }
        inFlight = true
        if case .test = endpoint {
            // An endpoint override never reads the Keychain or attaches a real token.
            identity = .answered(plan: nil, account: nil)
            fetch(token: "llm-usage-test-token")
        } else {
            readCredential()
        }
    }

    private func readCredential() {
        defer { if fetchTask == nil { inFlight = false } }
        switch credentialReader() {
        case .missing:
            // `authStatus()` runs `claude auth status` — a different process, unaffected by
            // this process's Keychain ACL. Re-probe because a cached account may outlive
            // logout or account switching. An unreachable CLI is not evidence of logout;
            // a confirmed different account must discard the previous usage sample.
            let reprobe = identityReader()
            if case .answered = reprobe {
                if reprobe.account != identity.account || reprobe.account == nil {
                    sessionToken = nil
                    lastGood = nil
                }
                identity = reprobe
            }
            if identity.account != nil {
                emitUnavailable(reason: Self.unreadableReason(.keychain(errSecItemNotFound)))
            } else {
                emitUnavailable(reason: "Not signed in to Claude Code")
            }
        case .expired:
            // Not an error: Claude Code renews this the next time it runs.
            emitUnavailable(reason: "Token expired (launch Claude Code to renew)")
        case .unreadable(let failure):
            emitUnavailable(reason: Self.unreadableReason(failure))
        case .malformed:
            emitUnavailable(reason: "Credential format not recognised (Claude Code may have changed it)")
        case .token(let token):
            if sessionToken != token {
                sessionToken = token
                lastGood = nil
                identity = identityReader()
            } else if case .unreachable = identity {
                identity = identityReader()
            }
            fetch(token: token)
        }
    }

    /// Why a read failed, in the short form: the note wraps at 320pt, so it says the one
    /// thing the reader can act on, and carries the number that makes a report of it
    /// diagnosable. Not every failure can be fixed by approving a prompt, so each says
    /// what actually happened: `errSecInteractionNotAllowed` means there is no session to
    /// host a prompt in at all (locked keychain, no UI); the reconciliation path in
    /// `readCredential()` passes `errSecItemNotFound` here, where there is nothing to
    /// approve or unlock — the item just couldn't be read; and a timeout means a prompt is
    /// most likely up and unanswered, which approving fixes on the next cycle.
    private static func unreadableReason(_ failure: ReadFailure) -> String {
        switch failure {
        case .keychain(errSecInteractionNotAllowed):
            return "Keychain locked (unlock the login keychain) [\(errSecInteractionNotAllowed)]"
        case .keychain(errSecItemNotFound):
            return "Keychain item unreadable [\(errSecItemNotFound)]"
        case .keychain(let status):
            return "Keychain access refused (approve the macOS prompt) [\(status)]"
        case .exitCode(let code):
            return "Keychain read failed (security exit \(code))"
        case .timedOut:
            return "Keychain read timed out (a macOS prompt may be waiting)"
        case .notRun:
            return "Could not run /usr/bin/security"
        case .outputTooLarge:
            return "Keychain response was too large"
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.generation += 1
            self.timer?.cancel()
            self.timer = nil
            self.retryTask?.cancel()
            self.retryTask = nil
            self.fetchTask?.cancel()
            self.fetchTask = nil
            self.inFlight = false
            self.retryAttempt = 0
            self.nextAllowedFetchAt = nil
            self.sessionToken = nil
            self.identity = .unreachable
            self.lastGood = nil
        }
    }

    // MARK: - Credential

    enum Credential: Sendable {
        case token(String)
        case expired
        /// No item by this service name exists in the Keychain.
        case missing
        /// The item could not be read: access refused, a locked keychain, a read that hung
        /// on an unanswered dialog. Distinct from `.missing` because the remedy is
        /// different — grant access or unlock, not sign in.
        case unreadable(ReadFailure)
        /// The item was read successfully but its JSON didn't have the shape this decoder
        /// expects — a schema change on Claude Code's side, not an access problem.
        case malformed
    }

    /// Read through `/usr/bin/security`, not `SecItemCopyMatching` — which is the whole
    /// reason this app stopped asking for Keychain access every few days.
    ///
    /// An in-process read makes *this app* the accessing application, and the item's ACL
    /// names the applications it trusts by (path, cdhash). The bundle is ad-hoc signed, so
    /// every rebuild — and every released version — is a different application as far as
    /// the Keychain is concerned, and each one is denied until the user approves it at the
    /// macOS prompt all over again. Rebuilding and upgrading are routine, so the prompt
    /// was routine.
    ///
    /// Claude Code writes the item by shelling out to `security`
    /// (`add-generic-password -U -a <user> -s "Claude Code-credentials"`), which leaves
    /// `/usr/bin/security` on the item's trusted-application list — an Apple-signed binary
    /// whose identity never changes. Reading through it is authorised for free, however
    /// often this app is rebuilt, and it widens nothing: the ACL entry is Claude Code's
    /// own, already there, and this only exercises it. The absolute path is deliberate
    /// rather than `CLI.path("security")` — what the ACL trusts is Apple's binary at that
    /// path, not whatever a PATH lookup finds first.
    ///
    /// Matched by service alone, as the in-process query was: the account is the login
    /// name today, and there is nothing to gain from pinning a second attribute.
    private static func credential() -> Credential {
        let output: String
        switch securityRead() {
        case .failure(.keychain(errSecItemNotFound)):
            return .missing
        case .failure(let failure):
            return .unreadable(failure)
        case .success(let text):
            output = text
        }
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return .malformed }

        // expiresAt is milliseconds since epoch.
        if let expiresAt = oauth["expiresAt"] as? Double,
           Date().timeIntervalSince1970 * 1000 >= expiresAt {
            return .expired
        }
        return .token(token)
    }

    private enum ReadResult {
        case success(String)
        case failure(ReadFailure)
    }

    /// Why a read failed. A Keychain status where one can be recovered; otherwise the exit
    /// code as itself, because pretending an unrecoverable one is an OSStatus prints a
    /// number that matches no documented constant.
    enum ReadFailure: Sendable {
        case keychain(OSStatus)
        case exitCode(Int32)
        /// Still running when the watchdog fired — most likely a dialog nobody answered.
        case timedOut
        /// `/usr/bin/security` would not run at all, so nothing was asked of the Keychain.
        case notRun
        case outputTooLarge
    }

    /// The read itself. stderr is dropped: `security` writes a human-readable line there,
    /// too long for a 320pt note, and the exit code is what this decides on. The token
    /// comes back on a pipe, never in an argument list, so it stays out of `ps`.
    ///
    /// The wait is bounded because this runs on the provider's serial queue, which also
    /// owns the poll timer: a `security` that sits on an unanswered dialog — a locked
    /// login keychain raises one, and so would an item whose ACL has stopped listing
    /// `/usr/bin/security` — would otherwise hold the queue for the rest of the session
    /// and freeze the card on its last value with nothing said. Same watchdog as
    /// `CLI.readLoginShellPath`. Ten seconds is far longer than a granted read needs
    /// (milliseconds) and far too short to answer a dialog in, deliberately: the point is
    /// to report the block and let the next cycle try again, by which time approving the
    /// dialog has made the read instant.
    private static func securityRead() -> ReadResult {
        switch CLI.run(executable: "/usr/bin/security",
                       arguments: ["find-generic-password", "-s", service, "-w"]) {
        case .success(let output):
            return .success(output.trimmingCharacters(in: .whitespacesAndNewlines))
        case .failure(.exitCode(let code)):
            return .failure(failure(forExit: code))
        case .failure(.timedOut): return .failure(.timedOut)
        case .failure(.notRun): return .failure(.notRun)
        case .failure(.outputTooLarge): return .failure(.outputTooLarge)
        }
    }

    /// `security` exits with the Keychain OSStatus truncated to the low byte an exit code
    /// can carry — `errSecItemNotFound` (-25300) arrives as 44 — and the high bytes are
    /// gone, so the status cannot be reconstructed arithmetically. The four that are
    /// actually reachable here are tabulated instead: the item is absent, the login
    /// keychain is locked, the user answered Deny, or the user dismissed the prompt.
    /// Anything else stays an exit code and is reported as one.
    private static func failure(forExit code: Int32) -> ReadFailure {
        switch code {
        case 44: return .keychain(errSecItemNotFound)
        case 36: return .keychain(errSecInteractionNotAllowed)
        case 51: return .keychain(errSecAuthFailed)
        case 128: return .keychain(errSecUserCanceled)
        default: return .exitCode(code)
        }
    }

    // MARK: - Fetch

    private func fetch(token: String) {
        guard let url = endpoint.url else { inFlight = false; return }
        let requestGeneration = generation
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Mandatory: without it the request lands in a heavily throttled bucket.
        request.setValue(endpoint == .production ? userAgent : "llm-usage-test", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // Onto the provider's own queue: the retry bookkeeping below and the
            // timer that also calls `refresh()` must not interleave.
            self.queue.async {
                guard self.running, self.generation == requestGeneration else { return }
                self.fetchTask = nil
                self.inFlight = false
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
                if source.state == .ok { source.lastUpdated = self.now() }
                source.plan = self.identity.plan
                source.account = self.identity.account
                if source.state == .ok { self.lastGood = source }
                self.retryAttempt = 0
                self.nextAllowedFetchAt = nil
                self.retryTask?.cancel()
                self.retryTask = nil
                self.onUpdate(source)
            }
        }
        fetchTask = task
        task.resume()
    }

    /// A throttle or an unreachable endpoint is temporary, and saying so matters:
    /// the first fetch after launch has no earlier reading to fall back on, so the
    /// card is left stating the problem and nothing else. Without a retry it stated
    /// it for a full poll interval.
    private func handleFailure(status: Int, response: URLResponse?) {
        var reason = Self.reason(for: status)

        if status == 429 || status == 0 {
            let delay = Self.retryAfter(response, now: now())
                ?? Self.retryDelays[min(retryAttempt, Self.retryDelays.count - 1)]
            retryAttempt += 1
            reason += " (retry \(Self.retryLabel(delay)))"
            let deadline = now().addingTimeInterval(delay)
            nextAllowedFetchAt = deadline
            scheduleRetry(at: deadline)
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

    private func scheduleRetry(at deadline: Date) {
        guard retryTask == nil, running else { return }
        let scheduledGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.generation == scheduledGeneration else { return }
            self.retryTask = nil
            self.attemptFetch()
        }
        retryTask = work
        queue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSince(now())), execute: work)
    }

    /// `Retry-After` is either a delay in seconds or an HTTP date. Honouring the
    /// server's own number beats guessing at it.
    static func retryAfter(_ response: URLResponse?, now: Date = Date()) -> TimeInterval? {
        guard let value = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }

        if let seconds = TimeInterval(value), seconds.isFinite { return max(1, seconds) }
        guard let date = httpDateFormatter.date(from: value) else { return nil }
        return max(1, date.timeIntervalSince(now))
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

    /// Keeps the last confirmed reading visible as stale when a new fetch fails.
    private func emitUnavailable(reason: String) {
        if var previous = lastGood {
            previous.note = reason
            previous.state = previous.lastUpdated.map { .stale(since: $0) } ?? .error(reason)
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

    // MARK: - CLI lookups

    private static func claudeVersion() -> String? {
        // "2.1.220 (Claude Code)" -> "2.1.220"
        run("claude", ["--version"])?
            .split(separator: " ").first.map(String.init)
    }

    /// Distinguishes "asked Claude Code and got an answer" (which may be no account at all —
    /// a real sign-out) from "couldn't ask" (unresolved `claude` binary, a process that
    /// wouldn't spawn, output that wouldn't parse). Collapsing the two into one `nil` used to
    /// make a failed probe indistinguishable from a confirmed sign-out; `readCredential()`
    /// relies on telling them apart.
    enum AuthProbe: Sendable {
        case unreachable
        case answered(plan: String?, account: String?)

        var plan: String? { if case .answered(let plan, _) = self { return plan }; return nil }
        var account: String? { if case .answered(_, let account) = self { return account }; return nil }
    }

    /// `claude auth status --json` gives both the plan and the signed-in address.
    private static func authStatus() -> AuthProbe {
        guard let json = run("claude", ["auth", "status", "--json"]),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unreachable }

        let plan = (root["subscriptionType"] as? String).flatMap { type -> String? in
            type.isEmpty ? nil : type.prefix(1).uppercased() + type.dropFirst()
        }
        let account = (root["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .answered(plan: plan, account: account)
    }

    /// The tool is resolved rather than run through `env`: a bundle launched by launchd
    /// gets only the system PATH, which is why plan and account read "—" there while a
    /// terminal run filled them in (see `CLI`).
    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        guard let executable = CLI.path(tool) else { return nil }
        guard case .success(let output) = CLI.run(executable: executable, arguments: arguments,
                                                 environment: CLI.environment(for: tool)) else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
