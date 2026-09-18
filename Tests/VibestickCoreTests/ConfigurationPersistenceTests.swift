import XCTest
@testable import VibestickCore

@MainActor
final class ConfigurationPersistenceTests: XCTestCase {
    func testCleanLoadAndRoundTripEveryPersistedScope() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibestickConfigurationTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProfileStore(storageURL: url)
        XCTAssertEqual(store.configurationLoadOutcome, .noFile)
        XCTAssertEqual(
            store.configuration.schemaVersion,
            VibestickConfiguration.currentSchemaVersion
        )
        XCTAssertTrue(store.configuration.appProfiles.isEmpty)
        XCTAssertTrue(store.configuration.herdrLayerOverrides.isEmpty)

        let target = FocusedApp(bundleID: "com.example.target", name: "Target")
        let appOverride = BindingAction.key(KeyChord(keyCode: 36, modifiers: [.command]))
        store.beginEditing(target)
        store.setBinding(appOverride, for: .a)
        store.setSystemBinding(.none, for: .share)
        store.setHerdrLayerOverride(.key(KeyChord(keyCode: 45)), for: .rb)
        store.setStickMapping(.none, for: .rightLeft)

        let reloaded = ProfileStore(storageURL: url)
        XCTAssertEqual(reloaded.configurationLoadOutcome, .loaded)
        XCTAssertEqual(reloaded.configuration, store.configuration)
        XCTAssertEqual(reloaded.action(for: .a, app: target), appOverride)
        XCTAssertEqual(reloaded.configuration.appProfiles.count, 1)
        XCTAssertTrue(
            reloaded.configuration.appProfiles.values.allSatisfy { $0.count == 1 }
        )
        XCTAssertEqual(reloaded.configuration.herdrLayerOverrides.count, 1)
        XCTAssertEqual(reloaded.systemBinding(for: .share), .none)
        XCTAssertEqual(reloaded.herdrLayerOverride(for: .rb), .key(KeyChord(keyCode: 45)))
        XCTAssertEqual(reloaded.stickMapping(for: .rightLeft), .none)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(
            json["schemaVersion"] as? Int,
            VibestickConfiguration.currentSchemaVersion
        )
        XCTAssertNotNil(json["systemBindings"])
        XCTAssertNotNil(json["globalFallbackBindings"])
        XCTAssertNotNil(json["appProfiles"])
        XCTAssertNotNil(json["herdrLayerOverrides"])
        XCTAssertNotNil(json["stickMappings"])
    }

    func testRecognizablePrototypeConfigurationMigratesOnceAndKeepsBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibestickConfigurationTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let prototype = Data(
            """
            {
              "global": {
                "a": {"kind": "key", "keyCode": 36, "modifiers": 8},
                "b": {"kind": "none"}
              },
              "apps": {
                "com.example.target": {
                  "x": {"kind": "key", "keyCode": 53, "modifiers": 0}
                }
              }
            }
            """.utf8
        )
        try prototype.write(to: url)

        let migrated = ProfileStore(storageURL: url)
        guard case let .migrated(report) = migrated.configurationLoadOutcome else {
            return XCTFail("Expected a migration outcome")
        }
        XCTAssertTrue(report.skippedEntries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: report.backupURL), prototype)
        XCTAssertEqual(
            migrated.configuration.globalFallbackBindings[.a],
            .key(KeyChord(keyCode: 36, modifiers: [.command]))
        )
        XCTAssertEqual(
            migrated.configuration.appProfiles["com.example.target"],
            [.x: .key(KeyChord(keyCode: 53))]
        )
        let ordinary = FocusedApp(
            bundleID: "com.example.target",
            name: "Prototype app"
        )
        let herdr = FocusedApp(
            bundleID: "com.example.target",
            name: "Prototype app · Herdr",
            isHerdr: true
        )
        XCTAssertEqual(
            migrated.action(for: .x, app: ordinary),
            .key(KeyChord(keyCode: 53))
        )
        XCTAssertEqual(
            migrated.action(for: .x, app: herdr),
            .key(KeyChord(keyCode: 53))
        )
        XCTAssertTrue(migrated.configuration.herdrLayerOverrides.isEmpty)

        let reloaded = ProfileStore(storageURL: url)
        XCTAssertEqual(reloaded.configurationLoadOutcome, .loaded)
        XCTAssertEqual(reloaded.configuration, migrated.configuration)
    }

    func testPartialMigrationKeepsRecognizedSparseEntriesAndReportsSkippedPaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibestickConfigurationTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let prototype = Data(
            """
            {
              "global": {
                "a": {"kind": "key", "keyCode": 36, "modifiers": 8},
                "b": {"kind": "key"},
                "mystery": {"kind": "none"}
              },
              "apps": {
                "com.example.target": {
                  "x": {"kind": "key", "keyCode": 53, "modifiers": 0},
                  "unknown_button": {"kind": "none"}
                },
                "com.example.broken": "not a profile"
              }
            }
            """.utf8
        )
        try prototype.write(to: url)

        let migrated = ProfileStore(storageURL: url)
        guard case let .migrated(report) = migrated.configurationLoadOutcome else {
            return XCTFail("Expected a partial migration outcome")
        }

        XCTAssertEqual(
            Set(report.skippedEntries.map(\.path)),
            [
                "global.b",
                "global.mystery",
                "apps.com.example.target.unknown_button",
                "apps.com.example.broken",
            ]
        )
        XCTAssertEqual(try Data(contentsOf: report.backupURL), prototype)
        XCTAssertEqual(
            migrated.configuration.appProfiles["com.example.target"],
            [.x: .key(KeyChord(keyCode: 53))]
        )
        XCTAssertNil(migrated.configuration.appProfiles["com.example.broken"])
        XCTAssertEqual(
            migrated.configuration.globalFallbackBindings[.a],
            .key(KeyChord(keyCode: 36, modifiers: [.command]))
        )
        XCTAssertEqual(
            migrated.configuration.globalFallbackBindings[.b],
            .key(KeyChord(keyCode: 53))
        )
        XCTAssertTrue(migrated.configurationNotice?.contains("4 skipped entries") == true)
        XCTAssertTrue(migrated.configurationNotice?.contains("global.b") == true)
    }

    func testFutureSchemaIsLeftUnchangedAndBlocksSaving() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibestickConfigurationTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let future = Data(#"{"schemaVersion": 99, "futureData": "keep me"}"#.utf8)
        try future.write(to: url)

        let store = ProfileStore(storageURL: url)
        XCTAssertEqual(store.configurationLoadOutcome, .unsupportedFutureVersion(99))
        XCTAssertTrue(store.configurationNotice?.contains("newer than this Vibestick") == true)

        store.setSystemBinding(.none, for: .share)

        XCTAssertEqual(try Data(contentsOf: url), future)
        XCTAssertEqual(store.systemBinding(for: .share), .overlay)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["config.json"]
        )
    }

    func testCorruptConfigurationIsLeftUnchangedAndBlocksSaving() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibestickConfigurationTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let corrupt = Data(#"{"global":"#.utf8)
        try corrupt.write(to: url)

        let store = ProfileStore(storageURL: url)
        guard case .corrupt = store.configurationLoadOutcome else {
            return XCTFail("Expected a corrupt configuration outcome")
        }
        XCTAssertTrue(store.configurationNotice?.contains("left unchanged") == true)

        let target = FocusedApp(bundleID: "com.example.target", name: "Target")
        store.beginEditing(target)
        store.setBinding(.none, for: .a)

        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertTrue(store.configuration.appProfiles.isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["config.json"]
        )
    }
}
