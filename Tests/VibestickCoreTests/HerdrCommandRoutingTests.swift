import XCTest
@testable import VibestickCore

@MainActor
final class HerdrCommandRoutingTests: XCTestCase {
    private let prefix = KeyChord(keyCode: 11, modifiers: [.control])

    func testHerdrBasePresetEmitsEveryLiteralShortcut() throws {
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )

        XCTAssertEqual(
            try XCTUnwrap(AppPresetCatalog.bindings(for: herdr)),
            [
                .a: .key(KeyChord(keyCode: 36)),
                .b: .key(KeyChord(keyCode: 49)),
                .x: .key(KeyChord(keyCode: 53)),
                .y: .sequence([prefix, KeyChord(keyCode: 5)]),
                .lt: .key(KeyChord(keyCode: 126, modifiers: [.shift])),
                .rt: .key(KeyChord(keyCode: 125, modifiers: [.shift])),
                .lb: .sequence([prefix, KeyChord(keyCode: 35)]),
                .rb: .sequence([prefix, KeyChord(keyCode: 45)]),
                .start: .sequence([prefix, KeyChord(keyCode: 124)]),
                .dpadLeft: .key(KeyChord(keyCode: 4, modifiers: [.control])),
                .dpadDown: .sequence([prefix, KeyChord(keyCode: 38)]),
                .dpadUp: .sequence([prefix, KeyChord(keyCode: 40)]),
                .dpadRight: .key(KeyChord(keyCode: 37, modifiers: [.control])),
            ]
        )
    }

    func testHerdrLayerPresetEmitsEveryLiteralShortcut() {
        let store = ProfileStore(loadFromDisk: false)
        let actions = Dictionary(
            uniqueKeysWithValues: PadButton.allCases.compactMap { button in
                store.herdrLayerAction(for: button).map { (button, $0) }
            }
        )
        let expected: [PadButton: BindingAction] = [
            .a: .sequence([prefix, KeyChord(keyCode: 6)]),
            .b: .sequence([prefix, KeyChord(keyCode: 9)]),
            .y: .sequence([prefix, KeyChord(keyCode: 27)]),
            .x: .sequence([prefix, KeyChord(keyCode: 48)]),
            .rb: .sequence([prefix, KeyChord(keyCode: 8)]),
            .start: .sequence([prefix, KeyChord(keyCode: 123)]),
            .lb: .sequence([
                prefix,
                KeyChord(keyCode: 32, modifiers: [.shift]),
            ]),
            .rt: .sequence([
                prefix,
                KeyChord(keyCode: 44, modifiers: [.shift]),
            ]),
            .lt: .sequence([prefix, KeyChord(keyCode: 1)]),
        ]

        XCTAssertEqual(actions, expected)
    }

    func testHoldingBackExecutesEveryConfiguredHerdrLayerAction() throws {
        let store = ProfileStore(loadFromDisk: false)
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        let backDown = ControllerInput.button(.back, pressed: true)
        let layerInputs: [(PadButton, ControllerInput)] = [
            (.a, .button(.a, pressed: true)),
            (.b, .button(.b, pressed: true)),
            (.y, .button(.y, pressed: true)),
            (.x, .button(.x, pressed: true)),
            (.rb, .button(.rb, pressed: true)),
            (.start, .button(.start, pressed: true)),
            (.lb, .button(.lb, pressed: true)),
            (.rt, .trigger(.rt, value: 0.6)),
            (.lt, .trigger(.lt, value: 0.6)),
        ]

        for (button, input) in layerInputs {
            var router = CommandRouter()
            XCTAssertEqual(
                router.route(
                    backDown,
                    at: 10,
                    context: .init(),
                    profile: store,
                    app: herdr
                ),
                .herdrLayer(backDown, action: nil)
            )
            XCTAssertEqual(
                router.route(
                    input,
                    at: 10.1,
                    context: .init(),
                    profile: store,
                    app: herdr
                ),
                .herdrLayer(
                    input,
                    action: try XCTUnwrap(store.herdrLayerAction(for: button))
                ),
                button.title
            )
        }
    }

    func testTappingBackArmsOneCompleteLayerActionForTwoSeconds() throws {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        let backDown = ControllerInput.button(.back, pressed: true)
        let backUp = ControllerInput.button(.back, pressed: false)
        let yDown = ControllerInput.button(.y, pressed: true)
        let expectedAction = try XCTUnwrap(store.herdrLayerAction(for: .y))

        XCTAssertEqual(
            router.route(
                backDown,
                at: 10,
                context: .init(),
                profile: store,
                app: herdr
            ),
            .herdrLayer(backDown, action: nil)
        )
        XCTAssertEqual(
            router.route(
                backUp,
                at: 10.1,
                context: .init(),
                profile: store,
                app: herdr
            ),
            .herdrLayer(backUp, action: nil)
        )
        XCTAssertEqual(
            router.route(
                yDown,
                at: 12,
                context: .init(),
                profile: store,
                app: herdr
            ),
            .herdrLayer(yDown, action: expectedAction)
        )
        XCTAssertEqual(
            router.route(
                yDown,
                at: 12.2,
                context: .init(),
                profile: store,
                app: herdr
            ),
            .appBinding(yDown, action: store.action(for: .y, app: herdr))
        )
    }

    func testTappingBackAgainCancelsTheArmedLayer() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )

        for (input, timestamp) in [
            (ControllerInput.button(.back, pressed: true), 10),
            (ControllerInput.button(.back, pressed: false), 10.1),
            (ControllerInput.button(.back, pressed: true), 10.2),
            (ControllerInput.button(.back, pressed: false), 10.3),
        ] {
            XCTAssertEqual(
                router.route(
                    input,
                    at: timestamp,
                    context: .init(),
                    profile: store,
                    app: herdr
                ),
                .herdrLayer(input, action: nil)
            )
        }

        let aDown = ControllerInput.button(.a, pressed: true)
        XCTAssertEqual(
            router.route(
                aDown,
                at: 10.4,
                context: .init(),
                profile: store,
                app: herdr
            ),
            .appBinding(aDown, action: store.action(for: .a, app: herdr))
        )
    }

    func testHoldingBackWhileArmedExecutesALayerActionInsteadOfCancelling() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        for (input, timestamp) in [
            (ControllerInput.button(.back, pressed: true), 10),
            (ControllerInput.button(.back, pressed: false), 10.1),
            (ControllerInput.button(.back, pressed: true), 10.2),
        ] {
            _ = router.route(
                input,
                at: timestamp,
                context: .init(),
                profile: store,
                app: herdr
            )
        }

        let aDown = ControllerInput.button(.a, pressed: true)
        XCTAssertEqual(
            router.route(
                aDown,
                at: 10.3,
                context: .init(),
                profile: store,
                app: herdr
            ),
            .herdrLayer(
                aDown,
                action: store.herdrLayerAction(for: .a)
            )
        )
    }

    func testUnavailableMappedOutputCannotArmALatentLayerAction() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        for input in [
            ControllerInput.button(.back, pressed: true),
            ControllerInput.button(.back, pressed: false),
        ] {
            _ = router.route(
                input,
                context: .init(mappedOutputAvailable: false),
                profile: store,
                app: herdr
            )
        }

        let aDown = ControllerInput.button(.a, pressed: true)
        XCTAssertEqual(
            router.route(
                aDown,
                context: .init(mappedOutputAvailable: true),
                profile: store,
                app: herdr
            ),
            .appBinding(aDown, action: store.action(for: .a, app: herdr))
        )
    }

    func testArmedLayerExpiresWithoutChangingTheNextBaseAction() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        _ = router.route(
            .button(.back, pressed: true),
            at: 10,
            context: .init(),
            profile: store,
            app: herdr
        )
        _ = router.route(
            .button(.back, pressed: false),
            at: 10.1,
            context: .init(),
            profile: store,
            app: herdr
        )

        let aDown = ControllerInput.button(.a, pressed: true)
        XCTAssertEqual(
            router.route(
                aDown,
                at: 10.1 + CommandRouter.herdrLayerArmDuration + 0.001,
                context: .init(),
                profile: store,
                app: herdr
            ),
            .appBinding(aDown, action: store.action(for: .a, app: herdr))
        )
    }

    func testTransientCleanupCancelsAnArmedLayer() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        _ = router.route(
            .button(.back, pressed: true),
            at: 10,
            context: .init(),
            profile: store,
            app: herdr
        )
        _ = router.route(
            .button(.back, pressed: false),
            at: 10.1,
            context: .init(),
            profile: store,
            app: herdr
        )

        router.resetTransientState()

        let aDown = ControllerInput.button(.a, pressed: true)
        XCTAssertEqual(
            router.route(
                aDown,
                at: 10.2,
                context: .init(),
                profile: store,
                app: herdr
            ),
            .appBinding(aDown, action: store.action(for: .a, app: herdr))
        )
    }

    func testHerdrLayerOverrideReplacesThePreset() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        let override = BindingAction.key(
            KeyChord(keyCode: 18, modifiers: [.command])
        )
        store.setHerdrLayerOverride(override, for: .a)
        _ = router.route(
            .button(.back, pressed: true),
            context: .init(),
            profile: store,
            app: herdr
        )
        let aDown = ControllerInput.button(.a, pressed: true)

        XCTAssertEqual(
            router.route(
                aDown,
                context: .init(),
                profile: store,
                app: herdr
            ),
            .herdrLayer(aDown, action: override)
        )
    }

    func testOrdinaryGhosttyNeverReceivesHerdrBaseOrLayerActions() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let ordinaryGhostty = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: false
        )
        let backDown = ControllerInput.button(.back, pressed: true)
        let yDown = ControllerInput.button(.y, pressed: true)

        XCTAssertEqual(
            router.route(
                backDown,
                context: .init(),
                profile: store,
                app: ordinaryGhostty
            ),
            .appBinding(backDown, action: BindingAction.none)
        )
        XCTAssertEqual(
            router.route(
                yDown,
                context: .init(),
                profile: store,
                app: ordinaryGhostty
            ),
            .appBinding(
                yDown,
                action: GhosttyPreset.bindings[.y]
            )
        )
        XCTAssertNotEqual(
            GhosttyPreset.bindings[.y],
            HerdrPreset.bindings[.y]
        )
        XCTAssertNotEqual(
            GhosttyPreset.bindings[.y],
            HerdrLayerPreset.bindings[.y]
        )
    }
}
