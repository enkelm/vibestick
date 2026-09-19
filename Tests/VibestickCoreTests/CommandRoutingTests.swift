import XCTest
@testable import VibestickCore

@MainActor
final class CommandRoutingTests: XCTestCase {
    func testXboxReportDecoding() throws {
        var bytes = Array(repeating: UInt8(0), count: 17)
        bytes[3] = 0x14
        bytes[5] = 0xFF; bytes[6] = 0x03
        bytes[10] = 0x80
        let report = try XCTUnwrap(XboxSeriesDecoder.decode(bytes, previousButtons: 0))
        XCTAssertTrue(report.buttons.contains { $0.0 == .a && $0.1 })
        XCTAssertTrue(report.buttons.contains { $0.0 == .start && $0.1 })
        XCTAssertEqual(try XCTUnwrap(report.triggers.first { $0.0 == .lt }?.1), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.axes.first { $0.0 == .leftX }?.1), -1, accuracy: 0.001)
    }

    func testProfileResolutionAndPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/config.json")
        let target = FocusedApp(bundleID: "com.example.target", name: "Target")
        let other = FocusedApp(bundleID: "com.example.other", name: "Other")
        let store = ProfileStore(storageURL: url, loadFromDisk: false)
        XCTAssertEqual(store.action(for: .a, app: target), .none)
        let override = BindingAction.key(KeyChord(keyCode: 36, modifiers: [.command, .shift]))
        store.beginEditing(target)
        store.setBinding(override, for: .a)
        XCTAssertEqual(store.action(for: .a, app: target), override)
        XCTAssertEqual(store.action(for: .a, app: other), .none)
        let reloaded = ProfileStore(storageURL: url)
        XCTAssertEqual(reloaded.action(for: .a, app: target), override)
        let slack = FocusedApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        XCTAssertEqual(ProfileStore(storageURL: url).action(for: .a, app: slack),
                       .key(KeyChord(keyCode: 4, modifiers: [.command, .shift])))
        XCTAssertEqual(ProfileStore(storageURL: url).action(for: .x, app: slack),
                       .key(KeyChord(keyCode: 40, modifiers: [.command])))
        let ghostty = FocusedApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty")
        XCTAssertEqual(ProfileStore(storageURL: url).action(for: .a, app: ghostty),
                       .key(KeyChord(keyCode: 36)))
        XCTAssertEqual(ProfileStore(storageURL: url).action(for: .b, app: ghostty),
                       .key(KeyChord(keyCode: 49)))
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        XCTAssertEqual(
            ProfileStore(storageURL: url).action(for: .a, app: herdr),
            .key(KeyChord(keyCode: 36))
        )
        XCTAssertEqual(
            ProfileStore(storageURL: url).action(for: .rb, app: herdr),
            .sequence([
                KeyChord(keyCode: 11, modifiers: [.control]),
                KeyChord(keyCode: 45),
            ])
        )
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testBindingResolutionUsesOverridePresetGlobalFallbackThenUnbound() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + "/config.json"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ProfileStore(storageURL: url, loadFromDisk: false)
        let ghostty = FocusedApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty")
        let unknown = FocusedApp(bundleID: "com.example.unknown", name: "Unknown")
        let global = BindingAction.key(KeyChord(keyCode: 0, modifiers: [.command]))
        let override = BindingAction.key(KeyChord(keyCode: 1, modifiers: [.command]))

        store.editingGlobal = true
        store.setBinding(global, for: .a)
        XCTAssertEqual(
            store.resolvedBinding(for: .a, app: ghostty),
            ResolvedBinding(
                action: .key(KeyChord(keyCode: 36)),
                source: .preset
            )
        )
        XCTAssertEqual(
            store.resolvedBinding(for: .a, app: unknown),
            ResolvedBinding(action: global, source: .globalFallback)
        )

        store.beginEditing(ghostty)
        store.setBinding(override, for: .a)
        XCTAssertEqual(
            store.resolvedBinding(for: .a, app: ghostty),
            ResolvedBinding(action: override, source: .operatorOverride)
        )

        store.resetEditingApp()
        XCTAssertEqual(
            store.resolvedBinding(for: .a, app: ghostty),
            ResolvedBinding(
                action: .key(KeyChord(keyCode: 36)),
                source: .preset
            )
        )
        XCTAssertEqual(
            store.resolvedBinding(for: .x, app: unknown),
            ResolvedBinding(action: .none, source: .unbound)
        )
    }

    func testHerdrAndOrdinaryGhosttyKeepSeparateSparseOverrides() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + "/config.json"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ProfileStore(storageURL: url, loadFromDisk: false)
        let ordinary = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: false
        )
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        let override = BindingAction.key(KeyChord(keyCode: 7, modifiers: [.option]))

        store.beginEditing(ordinary)
        store.setBinding(override, for: .a)

        XCTAssertEqual(store.action(for: .a, app: ordinary), override)
        XCTAssertNotEqual(store.action(for: .a, app: herdr), override)
        XCTAssertEqual(store.configuration.appProfiles.values.count, 1)
        XCTAssertEqual(store.configuration.appProfiles.values.first?.count, 1)
    }

    func testUnknownAppShipsWithNoOrdinaryKeyOrScrollOutput() {
        let store = ProfileStore(loadFromDisk: false)
        let unknown = FocusedApp(bundleID: "com.example.unknown", name: "Unknown")

        for button in PadButton.allCases {
            XCTAssertEqual(store.action(for: button, app: unknown), .none)
        }
        for input in StickInput.allCases {
            XCTAssertEqual(store.stickMapping(for: input, app: unknown), .none)
        }
    }

    func testCompleteGhosttyPresetIsConservative() throws {
        let ghostty = FocusedApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty")
        let preset = try XCTUnwrap(AppPresetCatalog.bindings(for: ghostty))
        let store = ProfileStore(loadFromDisk: false)

        XCTAssertEqual(
            preset,
            [
                .a: .key(KeyChord(keyCode: 36)),
                .b: .key(KeyChord(keyCode: 49)),
                .x: .key(KeyChord(keyCode: 53)),
                .y: .key(KeyChord(keyCode: 48)),
                .lb: .key(KeyChord(keyCode: 33, modifiers: [.command, .shift])),
                .rb: .key(KeyChord(keyCode: 30, modifiers: [.command, .shift])),
                .start: .key(KeyChord(keyCode: 17, modifiers: [.command])),
                .dpadUp: .key(KeyChord(keyCode: 126)),
                .dpadDown: .key(KeyChord(keyCode: 125)),
                .dpadLeft: .key(KeyChord(keyCode: 123)),
                .dpadRight: .key(KeyChord(keyCode: 124)),
            ]
        )
        XCTAssertFalse(
            preset.values.contains(
                .key(KeyChord(keyCode: 13, modifiers: [.command]))
            ),
            "The ordinary Ghostty preset must not close a window"
        )
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: StickInput.allCases.map {
                    ($0, store.stickMapping(for: $0, app: ghostty))
                }
            ),
            [
                .leftUp: .key(KeyChord(keyCode: 126)),
                .leftDown: .key(KeyChord(keyCode: 125)),
                .leftLeft: .key(KeyChord(keyCode: 123)),
                .leftRight: .key(KeyChord(keyCode: 124)),
                .rightUp: .scroll(.up),
                .rightDown: .scroll(.down),
                .rightLeft: .scroll(.left),
                .rightRight: .scroll(.right),
            ]
        )
    }

    func testCommandRouterResolvesOnlyPressedButtons() {
        let app = FocusedApp(bundleID: "com.example.target", name: "Target")
        let store = ProfileStore(loadFromDisk: false)
        let router = CommandRouter()

        XCTAssertEqual(
            router.action(for: .button(.a, pressed: true), profile: store, app: app),
            BindingAction.none
        )
        XCTAssertNil(router.action(for: .button(.a, pressed: false), profile: store, app: app))
        XCTAssertNil(router.action(for: .axis(.leftX, value: 1), profile: store, app: app))
    }

    func testAppContextClassifierRequiresPositiveHerdrDetection() {
        let ordinary = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: false
        )
        XCTAssertEqual(ordinary, FocusedApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty"))
        XCTAssertEqual(ordinary.context, .ordinaryGhostty)

        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        XCTAssertEqual(herdr.bundleID, "com.mitchellh.ghostty")
        XCTAssertEqual(herdr.name, "Ghostty · Herdr")
        XCTAssertEqual(herdr.context, .herdr)

        let supportedRegularApp = AppContextClassifier.classify(
            bundleID: "com.tinyspeck.slackmacgap",
            name: "Slack",
            herdrDetected: false
        )
        XCTAssertEqual(supportedRegularApp.context, .slack)

        let unknown = AppContextClassifier.classify(
            bundleID: "com.example.unsupported",
            name: "Unsupported",
            herdrDetected: false
        )
        XCTAssertEqual(unknown.context, .unknown)

        let lookalike = AppContextClassifier.classify(
            bundleID: "com.example.ghostty-helper",
            name: "Ghostty Helper",
            herdrDetected: true
        )
        XCTAssertEqual(lookalike.context, .unknown)
    }

    func testHerdrEvidenceOnlyAppliesToGhostty() {
        let app = AppContextClassifier.classify(
            bundleID: "com.example.unsupported",
            name: "Unsupported",
            herdrDetected: true
        )

        XCTAssertEqual(app.context, .unknown)
        XCTAssertFalse(app.isHerdr)
        XCTAssertEqual(app.name, "Unsupported")
    }

    func testHerdrSurfaceIdentificationFailsClosedWithoutCorrelatedTitles() {
        XCTAssertFalse(
            HerdrSurfaceIdentifier.matches(
                focusedWindowTitle: nil,
                focusedHerdrPaneTitles: ["π > Vibestick"]
            )
        )
        XCTAssertFalse(
            HerdrSurfaceIdentifier.matches(
                focusedWindowTitle: "ordinary shell",
                focusedHerdrPaneTitles: ["ordinary shell"]
            )
        )
        XCTAssertFalse(
            HerdrSurfaceIdentifier.matches(
                focusedWindowTitle: "π > Vibestick",
                focusedHerdrPaneTitles: []
            )
        )
        XCTAssertTrue(
            HerdrSurfaceIdentifier.matches(
                focusedWindowTitle: "  π > Vibestick  ",
                focusedHerdrPaneTitles: ["π > VIBESTICK"]
            )
        )
    }

    func testRadialSelection() {
        XCTAssertNil(RadialSelection.index(x: 0, y: 0, itemCount: 4))
        XCTAssertEqual(RadialSelection.index(x: 0, y: 1, itemCount: 4), 0)
        XCTAssertEqual(RadialSelection.index(x: 1, y: 0, itemCount: 4), 1)
        XCTAssertEqual(RadialSelection.index(x: 0, y: -1, itemCount: 4), 2)
        XCTAssertEqual(RadialSelection.index(x: -1, y: 0, itemCount: 4), 3)
    }
}
