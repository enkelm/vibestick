import Foundation
import XCTest

final class AcceptanceWorkflowTests: XCTestCase {
    func testWorkflowBuildsFromCleanSourceAndRecordsPassingEvidence() throws {
        let fixture = try AcceptanceWorkflowFixture()
        defer { fixture.remove() }
        let evidenceURL = fixture.root.appendingPathComponent("evidence")

        let process = try fixture.run(evidenceURL: evidenceURL)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            try fixture.invocations(),
            ["--version", "package clean", "test", "build"]
        )
        XCTAssertEqual(
            try String(contentsOf: evidenceURL.appendingPathComponent("result.txt")),
            "outcome=PASS\nexit_code=0\n"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: evidenceURL.appendingPathComponent("manual-checklist.md").path
            )
        )
        let log = try String(
            contentsOf: evidenceURL.appendingPathComponent("workflow.log")
        )
        XCTAssertTrue(log.contains("Clean source tree"))
        XCTAssertTrue(log.contains("Automated tests"))
        XCTAssertTrue(log.contains("Source-built application"))
    }

    func testWorkflowStopsOnFailureAndRecordsFailingEvidence() throws {
        let fixture = try AcceptanceWorkflowFixture()
        defer { fixture.remove() }
        let evidenceURL = fixture.root.appendingPathComponent("evidence")

        let process = try fixture.run(
            evidenceURL: evidenceURL,
            environment: ["FAIL_SWIFT_TEST": "1"]
        )

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            try fixture.invocations(),
            ["--version", "package clean", "test"]
        )
        XCTAssertEqual(
            try String(contentsOf: evidenceURL.appendingPathComponent("result.txt")),
            "outcome=FAIL\nexit_code=23\n"
        )
    }
}

private final class AcceptanceWorkflowFixture {
    let root: URL

    private let fileManager = FileManager.default
    private var invocationLog: URL {
        root.appendingPathComponent("invocations.log")
    }

    init() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("VibestickAcceptanceTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try fileManager.copyItem(
            at: projectRoot.appendingPathComponent("acceptance.sh"),
            to: root.appendingPathComponent("acceptance.sh")
        )
        try copyChecklist(from: projectRoot)
        try writeExecutables()
    }

    func remove() {
        try? fileManager.removeItem(at: root)
    }

    func run(
        evidenceURL: URL,
        environment additions: [String: String] = [:]
    ) throws -> Process {
        let process = Process()
        process.executableURL = root.appendingPathComponent("acceptance.sh")
        process.arguments = [evidenceURL.path]
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            root.appendingPathComponent("bin").path,
            "/usr/bin",
            "/bin",
        ].joined(separator: ":")
        environment["ACCEPTANCE_INVOCATIONS"] = invocationLog.path
        environment.merge(additions) { _, addition in addition }
        process.environment = environment

        try process.run()
        process.waitUntilExit()
        return process
    }

    func invocations() throws -> [String] {
        try String(contentsOf: invocationLog)
            .split(separator: "\n")
            .map(String.init)
    }

    private func copyChecklist(from projectRoot: URL) throws {
        let docs = root.appendingPathComponent("docs")
        try fileManager.createDirectory(at: docs, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: projectRoot
                .appendingPathComponent("docs")
                .appendingPathComponent("initial-milestone-acceptance-checklist.md"),
            to: docs.appendingPathComponent("initial-milestone-acceptance-checklist.md")
        )
    }

    private func writeExecutables() throws {
        let bin = root.appendingPathComponent("bin")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/zsh
            print -r -- "$*" >> "$ACCEPTANCE_INVOCATIONS"
            if [[ "$*" == "--version" ]]; then
                print "Swift version fixture"
            elif [[ "$*" == "test" && "${FAIL_SWIFT_TEST:-0}" == "1" ]]; then
                print -u2 "fixture test failure"
                exit 23
            fi
            """,
            to: bin.appendingPathComponent("swift")
        )
        try writeExecutable(
            """
            #!/bin/zsh
            print -r -- "build" >> "$ACCEPTANCE_INVOCATIONS"
            mkdir -p "$PWD/Vibestick.app/Contents/MacOS"
            touch "$PWD/Vibestick.app/Contents/MacOS/Vibestick"
            chmod +x "$PWD/Vibestick.app/Contents/MacOS/Vibestick"
            """,
            to: root.appendingPathComponent("build.sh")
        )
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
