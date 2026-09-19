import XCTest
@testable import VibestickCore

@MainActor
final class BindingsOverlayTrainerTests: XCTestCase {
    func testTrainerFollowsAppContextAndShowsItsResolvedBindings() {
        let store = ProfileStore(loadFromDisk: false)
        let trainer = BindingsOverlayTrainer()
        let ghostty = FocusedApp(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty"
        )
        let unknown = FocusedApp(
            bundleID: "com.example.unknown",
            name: "Unknown"
        )
        let fallback = BindingAction.key(
            KeyChord(keyCode: 0, modifiers: [.command])
        )
        store.editingGlobal = true
        store.setBinding(fallback, for: .a)

        trainer.follow(ghostty)
        XCTAssertEqual(
            trainer.resolvedBinding(for: .a, profile: store),
            ResolvedBinding(
                action: .key(KeyChord(keyCode: 36)),
                source: .preset
            )
        )

        trainer.follow(unknown)
        XCTAssertEqual(
            trainer.resolvedBinding(for: .a, profile: store),
            ResolvedBinding(action: fallback, source: .globalFallback)
        )
    }

    func testTrainerObservesControllerWhileMappedOutputIsPaused() {
        let trainer = BindingsOverlayTrainer()
        var lifecycle = OutputLifecycle(
            targetControllerConnected: true,
            accessibilityGranted: true
        )
        _ = lifecycle.handle(.setPaused(true))
        let button = ControllerInput.button(.a, pressed: true)
        let trigger = ControllerInput.trigger(.lt, value: 0.75)
        let axis = ControllerInput.axis(.leftX, value: -0.5)

        XCTAssertFalse(
            lifecycle.allows(.appBinding(button, action: BindingAction.none))
        )
        trainer.observe(button)
        trainer.observe(trigger)
        trainer.observe(axis)

        XCTAssertEqual(trainer.pressed, [.a, .lt])
        XCTAssertEqual(trainer.triggers[.lt], 0.75)
        XCTAssertEqual(trainer.axes[.leftX], -0.5)
    }

    func testPointerInteractionEmphasizesTheTranslucentTrainer() {
        let trainer = BindingsOverlayTrainer()

        XCTAssertEqual(trainer.presentation, .translucent)

        trainer.setPointerInteraction(active: true)
        XCTAssertEqual(trainer.presentation, .interactive)

        trainer.setPointerInteraction(active: false)
        XCTAssertEqual(trainer.presentation, .translucent)
    }

    func testTrainerObservesPassThroughInputWhileShareKeepsSystemOwnership() {
        let trainer = BindingsOverlayTrainer()
        let store = ProfileStore(loadFromDisk: false)
        let app = FocusedApp(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty"
        )
        var router = CommandRouter()
        let ordinary = ControllerInput.button(.a, pressed: true)
        let share = ControllerInput.button(.share, pressed: true)
        trainer.follow(app)

        trainer.observe(ordinary)
        XCTAssertEqual(
            router.route(
                ordinary,
                context: .init(),
                profile: store,
                app: app
            ),
            .appBinding(ordinary, action: store.action(for: .a, app: app))
        )

        trainer.observe(share)
        XCTAssertEqual(
            router.route(
                share,
                context: .init(),
                profile: store,
                app: app
            ),
            .systemGesture(share, binding: .share, action: .overlay)
        )
        XCTAssertEqual(trainer.pressed, [.a, .share])
    }
}
