import Foundation

/// Finds command-line tools for a process that never saw a shell.
///
/// Finder and launchd hand a GUI bundle `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so
/// `env codex` finds nothing while the very same command works in a terminal — which
/// is how the Homebrew build shipped with a Codex card that never filled in. Search
/// the usual install prefixes first, since that resolves Homebrew without spawning
/// anything, and only ask the login shell when it does not: a version manager's PATH
/// exists nowhere else, but paying for a shell startup at launch is not worth it
/// until the cheap answer has failed.
enum CLI {
    /// Reported when a tool is nowhere to be found, so the card can say so instead of
    /// sitting empty.
    struct NotFound: LocalizedError {
        let tool: String
        var errorDescription: String? { "\(tool) not found in PATH" }
    }

    /// Where tools land when nobody chose a directory. Ordered by how likely the tool
    /// is to be there, not alphabetically.
    private static let prefixes: [String] = {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",            // Homebrew, Apple silicon
            "/usr/local/bin",               // Homebrew on Intel, and most install scripts
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.npm-global/bin",
            "\(home)/bin",
            "/opt/local/bin",               // MacPorts
        ]
    }()

    private static let resolved = Mutex<[String: String]>([:])
    private static let shellDirectories = Mutex<[String]?>(nil)

    /// Absolute path to `tool`, or nil when it is not installed anywhere we can see.
    static func path(_ tool: String) -> String? {
        if let hit = resolved.withLock({ $0[tool] }) { return hit }
        guard let hit = search(tool) else { return nil }
        resolved.withLock { $0[tool] = hit }
        return hit
    }

    /// The environment a child tool should run with: ours, but with a PATH wide enough
    /// for the tool to find its own dependencies — an npm-installed CLI is a script
    /// that has to be able to spawn `node`.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directories().joined(separator: ":")
        return environment
    }

    private static func search(_ tool: String) -> String? {
        if let directory = directories().first(where: { isExecutable("\($0)/\(tool)") }) {
            return "\(directory)/\(tool)"
        }
        return loginShellDirectories()
            .first { isExecutable("\($0)/\(tool)") }
            .map { "\($0)/\(tool)" }
    }

    /// Inherited PATH first: a terminal run should resolve exactly what the terminal
    /// would, and a developer's override has to win over a stale copy in `/usr/local`.
    private static func directories() -> [String] {
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (inherited + prefixes).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Asks the user's login shell for its PATH. Interactive as well as login, because
    /// zsh users overwhelmingly set PATH in `.zshrc`, which a non-interactive shell
    /// never reads.
    private static func loginShellDirectories() -> [String] {
        if let cached = shellDirectories.withLock({ $0 }) { return cached }
        let found = readLoginShellPath()
        shellDirectories.withLock { $0 = found }
        return found
    }

    private static func readLoginShellPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard isExecutable(shell) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        // Dotfiles are free to be chatty, and an interactive shell may object to
        // having no tty. Neither is our problem as long as stdout is the PATH.
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }

        // A dotfile that blocks — waiting on a prompt, say — must not hold up launch.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8)?
            .split(separator: ":")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") } ?? []
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
