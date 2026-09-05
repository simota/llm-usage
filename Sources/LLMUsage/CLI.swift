import Foundation
import Darwin

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

    struct Resolution: Sendable {
        let path: String
        let environment: [String: String]
    }

    final class Resolver: @unchecked Sendable {
        private struct State {
            var resolved: [String: Resolution] = [:]
            var shellDirectories: [String]?
        }

        private let state = Mutex(State())
        private let inherited: [String: String]
        private let prefixes: [String]
        private let readShellPath: @Sendable () -> [String]

        init(environment: [String: String], prefixes: [String],
             readShellPath: @escaping @Sendable () -> [String]) {
            inherited = environment
            self.prefixes = prefixes
            self.readShellPath = readShellPath
        }

        func resolve(_ tool: String) -> Resolution? {
            state.withLock { state in
                if let cached = state.resolved[tool] { return cached }
                let usual = directories(inheritedPath + prefixes)
                var searchPath = usual
                var hit = executable(tool, in: searchPath)
                if hit == nil {
                    if state.shellDirectories == nil { state.shellDirectories = readShellPath() }
                    // A login shell's runtime must win over a different version in a default prefix.
                    searchPath = directories((state.shellDirectories ?? []) + usual)
                    hit = executable(tool, in: searchPath)
                }
                guard let hit else { return nil }
                var environment = inherited
                environment["PATH"] = searchPath.joined(separator: ":")
                let resolution = Resolution(path: hit, environment: environment)
                state.resolved[tool] = resolution
                return resolution
            }
        }

        func environment() -> [String: String] {
            state.withLock { state in
                var environment = inherited
                environment["PATH"] = directories((state.shellDirectories ?? []) + inheritedPath + prefixes)
                    .joined(separator: ":")
                return environment
            }
        }

        private var inheritedPath: [String] {
            (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        }

        private func directories(_ paths: [String]) -> [String] {
            var seen = Set<String>()
            return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
        }

        private func executable(_ tool: String, in paths: [String]) -> String? {
            paths.first { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }
                .map { "\($0)/\(tool)" }
        }
    }

    private static let resolver = Resolver(environment: ProcessInfo.processInfo.environment,
                                           prefixes: prefixes, readShellPath: readLoginShellPath)

    /// Absolute path to `tool`, or nil when it is not installed anywhere we can see.
    static func path(_ tool: String) -> String? {
        resolver.resolve(tool)?.path
    }

    /// The environment a child tool should run with: ours, but with a PATH wide enough
    /// for the tool to find its own dependencies — an npm-installed CLI is a script
    /// that has to be able to spawn `node`.
    static func environment(for tool: String? = nil) -> [String: String] {
        if let tool, let resolved = resolver.resolve(tool) { return resolved.environment }
        return resolver.environment()
    }

    private static func readLoginShellPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard case .success(let output) = run(
            executable: shell, arguments: ["-lic", "printf '\\nLLM_USAGE_PATH=%s\\n' \"$PATH\""], timeout: 5
        ), let path = output.split(separator: "\n").last(where: { $0.hasPrefix("LLM_USAGE_PATH=") })
        else { return [] }
        return path.dropFirst("LLM_USAGE_PATH=".count).split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") }
    }

    enum RunFailure: Error, Equatable {
        case notRun
        case timedOut
        case exitCode(Int32)
        case outputTooLarge
    }

    /// Nonblocking reads keep a child (or a descendant holding stdout open) from
    /// defeating the deadline. Output is bounded and never written to disk.
    static func run(executable: String, arguments: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval = 10,
                    acceptedExitCodes: Set<Int32> = [0]) -> Result<String, RunFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let reader = pipe.fileHandleForReading
        let fd = reader.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        defer {
            try? reader.close()
            try? pipe.fileHandleForWriting.close()
        }
        do { try process.run() } catch { return .failure(.notRun) }
        try? pipe.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        var failure: RunFailure?
        while true {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                failure = .timedOut
                break
            }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
                if output.count > 1_048_576 {
                    failure = .outputTooLarge
                    break
                }
                continue
            }
            if !process.isRunning { break }
            if count == 0 {
                // A process may close stdout and keep running. POLLHUP would spin.
                Thread.sleep(forTimeInterval: 0.02)
            } else {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 20)
            }
        }
        if let failure {
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 0.2)
                }
            }
            return .failure(failure)
        }
        guard process.terminationReason == .exit,
              acceptedExitCodes.contains(process.terminationStatus)
        else { return .failure(.exitCode(process.terminationStatus)) }
        return .success(String(decoding: output, as: UTF8.self))
    }
}
