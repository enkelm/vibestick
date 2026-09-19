import XCTest
@testable import VibestickCore

@MainActor
final class SlackPresetTests: XCTestCase {
    private let slack = FocusedApp(
        bundleID: "com.tinyspeck.slackmacgap",
        name: "Slack"
    )

    func testCompleteSlackPresetMatchesMilestoneShortcuts() throws {
        let preset = try XCTUnwrap(AppPresetCatalog.bindings(for: slack))
        let store = ProfileStore(loadFromDisk: false)

        XCTAssertEqual(
            preset,
            [
                .a: .key(KeyChord(keyCode: 4, modifiers: [.command, .shift])),
                .b: .key(KeyChord(keyCode: 53)),
                .x: .key(KeyChord(keyCode: 40, modifiers: [.command])),
                .y: .key(KeyChord(keyCode: 45, modifiers: [.command])),
                .lb: .key(KeyChord(keyCode: 126, modifiers: [.option, .shift])),
                .rb: .key(KeyChord(keyCode: 125, modifiers: [.option, .shift])),
                .lt: .key(KeyChord(keyCode: 0, modifiers: [.command, .shift])),
                .rt: .key(KeyChord(keyCode: 5, modifiers: [.command])),
                .r3: .key(KeyChord(keyCode: 49, modifiers: [.command, .shift])),
                .dpadUp: .key(KeyChord(keyCode: 126, modifiers: [.option])),
                .dpadDown: .key(KeyChord(keyCode: 125, modifiers: [.option])),
                .dpadLeft: .key(KeyChord(keyCode: 33, modifiers: [.command])),
                .dpadRight: .key(KeyChord(keyCode: 30, modifiers: [.command])),
                .back: .key(KeyChord(keyCode: 18, modifiers: [.control])),
                .start: .key(KeyChord(keyCode: 46, modifiers: [.command, .shift])),
            ]
        )
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: StickInput.allCases.map {
                    ($0, store.stickMapping(for: $0, app: slack))
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

    func testSlackOverridesAreSparseAndResetRevealsPresetOrGlobalFallback() {
        let store = makeStore()
        let globalA = BindingAction.key(
            KeyChord(keyCode: 1, modifiers: [.control])
        )
        let globalGuide = BindingAction.key(
            KeyChord(keyCode: 2, modifiers: [.control])
        )
        let overriddenA = BindingAction.key(
            KeyChord(keyCode: 3, modifiers: [.control])
        )
        let overriddenGuide = BindingAction.key(
            KeyChord(keyCode: 4, modifiers: [.control])
        )

        store.editingGlobal = true
        store.setBinding(globalA, for: .a)
        store.setBinding(globalGuide, for: .guide)
        XCTAssertEqual(
            store.resolvedBinding(for: .a, app: slack),
            ResolvedBinding(
                action: .key(
                    KeyChord(keyCode: 4, modifiers: [.command, .shift])
                ),
                source: .preset
            )
        )

        store.beginEditing(slack)
        store.setBinding(overriddenA, for: .a)
        store.setBinding(overriddenGuide, for: .guide)
        XCTAssertEqual(
            store.resolvedBinding(for: .a, app: slack),
            ResolvedBinding(action: overriddenA, source: .operatorOverride)
        )
        XCTAssertEqual(
            store.resolvedBinding(for: .guide, app: slack),
            ResolvedBinding(
                action: overriddenGuide,
                source: .operatorOverride
            )
        )
        XCTAssertEqual(
            store.resolvedBinding(for: .x, app: slack),
            ResolvedBinding(
                action: .key(KeyChord(keyCode: 40, modifiers: [.command])),
                source: .preset
            )
        )

        store.resetEditingApp()
        XCTAssertEqual(
            store.resolvedBinding(for: .a, app: slack),
            ResolvedBinding(
                action: .key(
                    KeyChord(keyCode: 4, modifiers: [.command, .shift])
                ),
                source: .preset
            )
        )
        XCTAssertEqual(
            store.resolvedBinding(for: .guide, app: slack),
            ResolvedBinding(action: globalGuide, source: .globalFallback)
        )
    }

    func testSlackRetainsShareAndShortAndLongL3SystemMeanings() {
        let store = makeStore()
        let appOverride = BindingAction.key(
            KeyChord(keyCode: 0, modifiers: [.control])
        )
        store.beginEditing(slack)
        store.setBinding(appOverride, for: .l3)
        store.setBinding(appOverride, for: .share)

        var shortRouter = CommandRouter()
        let l3Pressed = ControllerInput.button(.l3, pressed: true)
        let l3Released = ControllerInput.button(.l3, pressed: false)
        XCTAssertEqual(
            shortRouter.route(
                l3Pressed,
                at: 10,
                context: .init(),
                profile: store,
                app: slack
            ),
            .systemGesture(l3Pressed, binding: nil, action: nil)
        )
        XCTAssertEqual(
            shortRouter.route(
                l3Released,
                at: 10 + CommandRouter.longL3Duration - 0.001,
                context: .init(),
                profile: store,
                app: slack
            ),
            .systemGesture(
                l3Released,
                binding: .shortL3,
                action: .key(
                    KeyChord(
                        keyCode: 50,
                        modifiers: [.command, .control, .option, .shift]
                    )
                )
            )
        )

        var longRouter = CommandRouter()
        _ = longRouter.route(
            l3Pressed,
            at: 20,
            context: .init(),
            profile: store,
            app: slack
        )
        XCTAssertEqual(
            longRouter.resolveLongL3(
                at: 20 + CommandRouter.longL3Duration + 0.001,
                context: .init(),
                profile: store
            ),
            .systemGesture(
                l3Pressed,
                binding: .longL3,
                action: .switchApp
            )
        )

        var shareRouter = CommandRouter()
        let sharePressed = ControllerInput.button(.share, pressed: true)
        XCTAssertEqual(
            shareRouter.route(
                sharePressed,
                context: .init(),
                profile: store,
                app: slack
            ),
            .systemGesture(
                sharePressed,
                binding: .share,
                action: .overlay
            )
        )
    }

    private func makeStore() -> ProfileStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return ProfileStore(
            storageURL: directory.appendingPathComponent("config.json"),
            loadFromDisk: false
        )
    }
}
