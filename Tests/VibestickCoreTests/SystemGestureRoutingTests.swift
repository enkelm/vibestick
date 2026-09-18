import XCTest
@testable import VibestickCore

@MainActor
final class SystemGestureRoutingTests: XCTestCase {
    func testActiveCaptureOwnsInputAheadOfEveryOtherLayer() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let app = FocusedApp(bundleID: "com.example.target", name: "Target")
        let input = ControllerInput.button(.a, pressed: true)

        let route = router.route(
            input,
            context: InputRoutingContext(
                captureActive: true,
                appWheelActive: true,
                herdrLayerActive: true
            ),
            profile: store,
            app: app
        )

        XCTAssertEqual(route, .capture(input))
    }

    func testShareUsesConfiguredSystemBindingAheadOfHerdrLayer() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let app = FocusedApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty")
        let shortcut = BindingAction.key(
            KeyChord(keyCode: 3, modifiers: [.command, .option])
        )
        store.setSystemBinding(shortcut, for: .share)
        let input = ControllerInput.button(.share, pressed: true)

        let route = router.route(
            input,
            context: InputRoutingContext(herdrLayerActive: true),
            profile: store,
            app: app
        )

        XCTAssertEqual(
            route,
            .systemGesture(input, binding: .share, action: shortcut)
        )
    }

    func testShortL3ResolvesConfiguredActionExactlyOnceOnRelease() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let app = FocusedApp(bundleID: "com.example.target", name: "Target")
        let shortcut = BindingAction.key(
            KeyChord(
                keyCode: 50,
                modifiers: [.command, .control, .option, .shift]
            )
        )
        store.setSystemBinding(shortcut, for: .shortL3)
        let pressed = ControllerInput.button(.l3, pressed: true)
        let released = ControllerInput.button(.l3, pressed: false)

        XCTAssertEqual(
            router.route(pressed, context: .init(), profile: store, app: app),
            .systemGesture(pressed, binding: nil, action: nil)
        )
        XCTAssertEqual(
            router.route(released, context: .init(), profile: store, app: app),
            .systemGesture(released, binding: .shortL3, action: shortcut)
        )
        XCTAssertEqual(
            router.route(released, context: .init(), profile: store, app: app),
            .systemGesture(released, binding: nil, action: nil)
        )
    }

    func testLongL3ResolvesOnlyLongActionAndReleaseDoesNothing() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let app = FocusedApp(bundleID: "com.example.target", name: "Target")
        let longAction = BindingAction.key(
            KeyChord(keyCode: 17, modifiers: [.control])
        )
        store.setSystemBinding(longAction, for: .longL3)
        let pressed = ControllerInput.button(.l3, pressed: true)
        let released = ControllerInput.button(.l3, pressed: false)

        _ = router.route(pressed, context: .init(), profile: store, app: app)

        XCTAssertEqual(
            router.resolveLongL3(context: .init(), profile: store),
            .systemGesture(pressed, binding: .longL3, action: longAction)
        )
        XCTAssertNil(router.resolveLongL3(context: .init(), profile: store))
        XCTAssertEqual(
            router.route(released, context: .init(), profile: store, app: app),
            .systemGesture(released, binding: nil, action: nil)
        )
    }

    func testOwnershipFallsThroughAppWheelHerdrLayerAndAppBindingInOrder() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let app = FocusedApp(bundleID: "com.example.target", name: "Target")
        let appAction = BindingAction.key(KeyChord(keyCode: 36))
        store.beginEditing(app)
        store.setBinding(appAction, for: .a)
        let share = ControllerInput.button(.share, pressed: true)
        let ordinary = ControllerInput.button(.a, pressed: true)

        XCTAssertEqual(
            router.route(
                share,
                context: .init(appWheelActive: true, herdrLayerActive: true),
                profile: store,
                app: app
            ),
            .appWheel(share)
        )
        XCTAssertEqual(
            router.route(
                ordinary,
                context: .init(herdrLayerActive: true),
                profile: store,
                app: app
            ),
            .herdrLayer(ordinary)
        )
        XCTAssertEqual(
            router.route(ordinary, context: .init(), profile: store, app: app),
            .appBinding(ordinary, action: appAction)
        )
    }

    func testDisabledSystemBindingDoesNotFallThroughToAppProfile() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let app = FocusedApp(bundleID: "com.example.target", name: "Target")
        let appAction = BindingAction.key(KeyChord(keyCode: 36))
        store.beginEditing(app)
        store.setBinding(appAction, for: .l3)
        store.setSystemBinding(.none, for: .shortL3)
        let pressed = ControllerInput.button(.l3, pressed: true)
        let released = ControllerInput.button(.l3, pressed: false)

        _ = router.route(pressed, context: .init(), profile: store, app: app)

        XCTAssertEqual(
            router.route(released, context: .init(), profile: store, app: app),
            .systemGesture(
                released,
                binding: .shortL3,
                action: BindingAction.none
            )
        )
        XCTAssertEqual(store.action(for: .l3, app: app), appAction)
    }

    func testHigherPriorityOwnerCancelsPendingL3OnRelease() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let app = FocusedApp(bundleID: "com.example.target", name: "Target")
        let pressed = ControllerInput.button(.l3, pressed: true)
        let released = ControllerInput.button(.l3, pressed: false)

        _ = router.route(pressed, context: .init(), profile: store, app: app)
        XCTAssertEqual(
            router.route(
                released,
                context: .init(appWheelActive: true),
                profile: store,
                app: app
            ),
            .appWheel(released)
        )

        XCTAssertEqual(
            router.route(released, context: .init(), profile: store, app: app),
            .systemGesture(released, binding: nil, action: nil)
        )
    }
}
