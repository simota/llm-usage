import XCTest
@testable import LLMUsage

final class CLITests: XCTestCase {
    func testLoginShellResolutionUsesMatchingRuntimeBeforeDefaultRuntime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inherited = directory.appendingPathComponent("inherited")
        let login = directory.appendingPathComponent("login")
        try FileManager.default.createDirectory(at: inherited, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: login, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try executable(inherited.appendingPathComponent("fixture-runtime"), "#!/bin/sh\nprintf wrong")
        try executable(login.appendingPathComponent("fixture-runtime"), "#!/bin/sh\nprintf expected")
        try executable(login.appendingPathComponent("fixture-cli"), "#!/usr/bin/env fixture-runtime\n")
        let loginPath = login.path
        let resolver = CLI.Resolver(environment: ["PATH": inherited.path + ":/usr/bin:/bin"], prefixes: []) {
            [loginPath, "/usr/bin", "/bin"]
        }
        let resolution = try XCTUnwrap(resolver.resolve("fixture-cli"))
        let output = try CLI.run(executable: resolution.path, arguments: [],
                                 environment: resolution.environment).get()
        XCTAssertEqual(output, "expected")
        XCTAssertEqual(resolver.resolve("fixture-cli")?.environment, resolution.environment)
        XCTAssertEqual(resolver.environment()["PATH"]?.split(separator: ":").first, Substring(loginPath))
    }

    func testInheritedPathDoesNotConsultLoginShell() throws {
        let probes = Mutex(0)
        let resolver = CLI.Resolver(environment: ["PATH": "/bin:/usr/bin"], prefixes: []) {
            probes.withLock { $0 += 1 }
            return []
        }
        let resolution = try XCTUnwrap(resolver.resolve("sh"))
        XCTAssertEqual(resolution.path, "/bin/sh")
        XCTAssertEqual(resolution.environment["PATH"], "/bin:/usr/bin")
        XCTAssertEqual(probes.withLock { $0 }, 0)
    }

    func testNonzeroExitIsFailureEvenWithOutput() {
        let result = CLI.run(executable: "/bin/sh", arguments: ["-c", "printf misleading; exit 17"])
        XCTAssertEqual(result, .failure(.exitCode(17)))
    }

    func testTimeoutTerminatesProcessThatIgnoresTerm() {
        let start = Date()
        let result = CLI.run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        XCTAssertEqual(result, .failure(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testDescendantHoldingStdoutDoesNotBlockCompletedCommand() throws {
        let start = Date()
        let output = try CLI.run(executable: "/bin/sh", arguments: ["-c", "sleep 1 & printf done"], timeout: 0.3).get()
        XCTAssertEqual(output, "done")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
    }

    private func executable(_ url: URL, _ contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
