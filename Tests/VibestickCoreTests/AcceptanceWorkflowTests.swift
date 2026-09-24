import Foundation
import XCTest

final class AcceptanceWorkflowTests: XCTestCase {
    func testWorkflowBuildsFromCleanSourceAndRecordsPassingEvidence() throws {
        let fixture = try AcceptanceWorkflowFixture()
        defer { fixture.remove() }
        let evidenceURL = fixture.root.appendingPathComponent("evidence")

        let process = try fixture.run(evidenceURL: evidenceURL)

        XCTAssertEqual(process.terminationStatus, 0)
        let invocations = try fixture.invocations()
        XCTAssertEqual(
            Array(invocations.prefix(5)),
            [
                "--version",
                "package clean",
                "test",
                "build -c release",
                "build -c release --show-bin-path",
            ]
        )
        let codesignInvocation = try XCTUnwrap(invocations.last)
        XCTAssertTrue(
            codesignInvocation.hasPrefix(
                "codesign --force --deep --sign - "
            )
        )
        XCTAssertTrue(
            codesignInvocation.hasSuffix(
                "/\(fixture.root.lastPathComponent)/Vibestick.app"
            )
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
        let checklist = try String(
            contentsOf: evidenceURL.appendingPathComponent("manual-checklist.md")
        )
        XCTAssertTrue(checklist.contains("Bluetooth Low Energy (`045E:0B13`)"))
        XCTAssertTrue(checklist.contains("USB `045E:0B12` is not qualified for Share"))
        let log = try String(
            contentsOf: evidenceURL.appendingPathComponent("workflow.log")
        )
        XCTAssertTrue(log.contains("Clean source tree"))
        XCTAssertTrue(log.contains("Automated tests"))
        XCTAssertTrue(log.contains("Source-built application"))
    }

    func testWorkflowUsesConfiguredCodeSigningIdentity() throws {
        let fixture = try AcceptanceWorkflowFixture()
        defer { fixture.remove() }
        let evidenceURL = fixture.root.appendingPathComponent("evidence")

        let process = try fixture.run(
            evidenceURL: evidenceURL,
            environment: [
                "VIBESTICK_CODESIGN_IDENTITY": "Vibestick Local Code Signing"
            ]
        )

        XCTAssertEqual(process.terminationStatus, 0)
        let codesignInvocation = try XCTUnwrap(try fixture.invocations().last)
        XCTAssertTrue(
            codesignInvocation.hasPrefix(
                "codesign --force --deep --sign Vibestick Local Code Signing " +
                    "--identifier com.enkelm.vibestick "
            )
        )
        XCTAssertTrue(
            codesignInvocation.hasSuffix(
                "/\(fixture.root.lastPathComponent)/Vibestick.app"
            )
        )
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

    func testWorkflowRejectsSourceThatCannotBeIdentifiedByItsCommit() throws {
        let fixture = try AcceptanceWorkflowFixture()
        defer { fixture.remove() }
        let evidenceURL = fixture.root.appendingPathComponent("evidence")

        let process = try fixture.run(
            evidenceURL: evidenceURL,
            environment: ["DIRTY_SOURCE": "1"]
        )

        XCTAssertEqual(process.terminationStatus, 65)
        XCTAssertEqual(try fixture.invocations(), ["--version"])
        XCTAssertEqual(
            try String(contentsOf: evidenceURL.appendingPathComponent("result.txt")),
            "outcome=FAIL\nexit_code=65\n"
        )
        let log = try String(
            contentsOf: evidenceURL.appendingPathComponent("workflow.log")
        )
        XCTAssertTrue(log.contains("Source tree is not clean"))
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

        let projectRoot = try Self.locateProjectRoot(
            from: URL(fileURLWithPath: #filePath)
        )
        try fileManager.copyItem(
            at: projectRoot.appendingPathComponent("acceptance.sh"),
            to: root.appendingPathComponent("acceptance.sh")
        )
        try copyChecklist(from: projectRoot)
        try copyBuildFiles(from: projectRoot)
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
        environment["ACCEPTANCE_BUILD_BIN"] = root
            .appendingPathComponent("fixture-build-bin")
            .path
        environment["VIBESTICK_CODESIGN_IDENTITY"] = "-"
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

    private func copyBuildFiles(from projectRoot: URL) throws {
        try fileManager.copyItem(
            at: projectRoot.appendingPathComponent("build.sh"),
            to: root.appendingPathComponent("build.sh")
        )
        let appResources = root.appendingPathComponent("App")
        try fileManager.createDirectory(
            at: appResources,
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(
            at: projectRoot.appendingPathComponent("App/Info.plist"),
            to: appResources.appendingPathComponent("Info.plist")
        )
        let buildBin = root.appendingPathComponent("fixture-build-bin")
        try fileManager.createDirectory(
            at: buildBin,
            withIntermediateDirectories: true
        )
        try writeExecutable(
            "#!/bin/sh\nexit 0\n",
            to: buildBin.appendingPathComponent("Vibestick")
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
            elif [[ "$*" == "build -c release --show-bin-path" ]]; then
                print "$ACCEPTANCE_BUILD_BIN"
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
            if [[ "$*" == "rev-parse HEAD" ]]; then
                print "fixture-commit"
            elif [[ "$*" == "status --porcelain=v1 --untracked-files=all" &&
                    "${DIRTY_SOURCE:-0}" == "1" ]]; then
                print " M acceptance.sh"
            fi
            """,
            to: bin.appendingPathComponent("git")
        )
        try writeExecutable(
            """
            #!/bin/zsh
            print -r -- "codesign $*" >> "$ACCEPTANCE_INVOCATIONS"
            """,
            to: bin.appendingPathComponent("codesign")
        )
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private static func locateProjectRoot(from fileURL: URL) throws -> URL {
        var candidate = fileURL.deletingLastPathComponent()
        while candidate.path != "/" {
            let manifest = candidate.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw CocoaError(
            .fileNoSuchFile,
            userInfo: [NSFilePathErrorKey: "Package.swift"]
        )
    }
}
