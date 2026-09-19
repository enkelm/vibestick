import XCTest
@testable import VibestickCore

@MainActor
final class BindingsEditingTests: XCTestCase {
    func testAppBindingCanBeClearedAndResetToItsInheritedSource() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibestickBindingsEditingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(
            storageURL: directory.appendingPathComponent("config.json"),
            loadFromDisk: false
        )
        let app = FocusedApp(bundleID: "com.example.target", name: "Target")
        let fallback = BindingAction.key(
            KeyChord(keyCode: 36, modifiers: [.command])
        )

        store.editingGlobal = true
        store.setBinding(fallback, for: .a)
        store.beginEditing(app)

        XCTAssertTrue(store.isEditingBindings)
        XCTAssertEqual(
            store.resolvedBinding(for: .a, app: app),
            ResolvedBinding(action: fallback, source: .globalFallback)
        )

        store.setBinding(.none, for: .a)
        XCTAssertEqual(
            store.resolvedBinding(for: .a, app: app),
            ResolvedBinding(action: .none, source: .operatorOverride)
        )

        store.resetBinding(.a)
        XCTAssertEqual(
            store.resolvedBinding(for: .a, app: app),
            ResolvedBinding(action: fallback, source: .globalFallback)
        )
        XCTAssertNil(store.configuration.appProfiles[app.bundleID])

        store.endEditing()
        XCTAssertFalse(store.isEditingBindings)
    }

    func testEveryEditorSectionSupportsOverrideAndSingleBindingReset() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibestickBindingsEditingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(
            storageURL: directory.appendingPathComponent("config.json"),
            loadFromDisk: false
        )
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )

        store.beginEditing(herdr)
        XCTAssertEqual(
            store.availableEditingSections,
            [.systemBindings, .globalFallbacks, .appProfile, .herdrLayer, .stickMappings]
        )

        store.editingSection = .systemBindings
        let defaultShare = store.systemBinding(for: .share)
        store.setSystemBinding(.none, for: .share)
        XCTAssertEqual(store.systemBinding(for: .share), .none)
        XCTAssertTrue(store.isSystemBindingOverride(.share))
        store.resetSystemBinding(.share)
        XCTAssertEqual(store.systemBinding(for: .share), defaultShare)
        XCTAssertFalse(store.isSystemBindingOverride(.share))

        store.editingSection = .globalFallbacks
        store.setBinding(.key(KeyChord(keyCode: 0)), for: .guide)
        XCTAssertEqual(store.bindingSource(for: .guide), .globalFallback)
        store.resetBinding(.guide)
        XCTAssertEqual(store.bindingSource(for: .guide), .unbound)

        store.editingSection = .appProfile
        store.setBinding(.none, for: .a)
        XCTAssertEqual(store.bindingSource(for: .a), .operatorOverride)
        store.resetBinding(.a)
        XCTAssertEqual(store.bindingSource(for: .a), .preset)

        store.editingSection = .herdrLayer
        XCTAssertEqual(store.bindingSource(for: .a), .preset)
        store.setBinding(.none, for: .a)
        XCTAssertEqual(store.bindingSource(for: .a), .operatorOverride)
        store.resetBinding(.a)
        XCTAssertEqual(store.bindingSource(for: .a), .preset)

        store.editingSection = .stickMappings
        let defaultStick = store.stickMapping(for: .rightUp)
        store.setStickMapping(.none, for: .rightUp)
        XCTAssertTrue(store.isStickMappingOverride(.rightUp))
        store.resetStickMapping(.rightUp)
        XCTAssertEqual(store.stickMapping(for: .rightUp), defaultStick)
        XCTAssertFalse(store.isStickMappingOverride(.rightUp))
    }

    func testHerdrLayerAndAppProfileRemainSeparateAndSurviveRelaunch() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibestickBindingsEditingTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        let appAction = BindingAction.key(KeyChord(keyCode: 12, modifiers: [.command]))
        let layerAction = BindingAction.key(KeyChord(keyCode: 13, modifiers: [.control]))

        let store = ProfileStore(storageURL: url)
        store.beginEditing(herdr)
        store.editingSection = .appProfile
        store.setBinding(appAction, for: .y)
        store.editingSection = .herdrLayer
        store.setBinding(layerAction, for: .y)
        store.setStickMapping(.scroll(.left), for: .leftLeft)
        store.setSystemBinding(.none, for: .shortL3)

        let reloaded = ProfileStore(storageURL: url)
        XCTAssertEqual(reloaded.action(for: .y, app: herdr), appAction)
        XCTAssertEqual(reloaded.herdrLayerAction(for: .y), layerAction)
        XCTAssertEqual(reloaded.stickMapping(for: .leftLeft), .scroll(.left))
        XCTAssertEqual(reloaded.systemBinding(for: .shortL3), .none)
    }

    func testHerdrLayerSectionIsOnlyOfferedForPinnedHerdrContext() {
        let store = ProfileStore(loadFromDisk: false)
        store.beginEditing(
            FocusedApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty")
        )

        XCTAssertEqual(
            store.availableEditingSections,
            [.systemBindings, .globalFallbacks, .appProfile, .stickMappings]
        )
    }
}
