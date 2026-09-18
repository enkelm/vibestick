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
        XCTAssertEqual(store.action(for: .a, app: target), .key(KeyChord(keyCode: 49)))
        let override = BindingAction.key(KeyChord(keyCode: 36, modifiers: [.command, .shift]))
        store.beginEditing(target)
        store.setBinding(override, for: .a)
        XCTAssertEqual(store.action(for: .a, app: target), override)
        XCTAssertEqual(store.action(for: .a, app: other), .key(KeyChord(keyCode: 49)))
        let reloaded = ProfileStore(storageURL: url)
        XCTAssertEqual(reloaded.action(for: .a, app: target), override)
        let slack = FocusedApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        XCTAssertEqual(ProfileStore(storageURL: url).action(for: .a, app: slack),
                       .key(KeyChord(keyCode: 4, modifiers: [.command, .shift])))
        XCTAssertEqual(ProfileStore(storageURL: url).action(for: .x, app: slack),
                       .key(KeyChord(keyCode: 40, modifiers: [.command])))
        let ghostty = FocusedApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty")
        XCTAssertEqual(ProfileStore(storageURL: url).action(for: .a, app: ghostty),
                       .key(KeyChord(keyCode: 17, modifiers: [.command])))
        XCTAssertEqual(ProfileStore(storageURL: url).action(for: .b, app: ghostty),
                       .key(KeyChord(keyCode: 13, modifiers: [.command])))
        let herdr = FocusedApp(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty · Herdr",
            isHerdr: true
        )
        XCTAssertEqual(
            ProfileStore(storageURL: url).action(for: .a, app: herdr),
            .sequence([
                KeyChord(keyCode: 11, modifiers: [.control]),
                KeyChord(keyCode: 6),
            ])
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

    func testCommandRouterResolvesOnlyPressedButtons() {
        let app = FocusedApp(bundleID: "com.example.target", name: "Target")
        let store = ProfileStore(loadFromDisk: false)
        let router = CommandRouter()

        XCTAssertEqual(
            router.action(for: .button(.a, pressed: true), profile: store, app: app),
            .key(KeyChord(keyCode: 49))
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

        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        XCTAssertEqual(
            herdr,
            FocusedApp(
                bundleID: "com.mitchellh.ghostty",
                name: "Ghostty · Herdr",
                isHerdr: true
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
