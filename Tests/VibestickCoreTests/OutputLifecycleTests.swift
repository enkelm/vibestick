import XCTest
@testable import VibestickCore

final class OutputLifecycleTests: XCTestCase {
    func testEmergencyPauseStopsMappedOutputForThisLaunchOnly() {
        var lifecycle = OutputLifecycle(
            targetControllerConnected: true,
            accessibilityGranted: true
        )

        XCTAssertTrue(lifecycle.mappedOutputAvailable)
        XCTAssertTrue(lifecycle.setHeld(.a, pressed: true))
        let cleanup = lifecycle.handle(.setPaused(true))
        XCTAssertEqual(cleanup, .suspendMappedOutput)
        XCTAssertFalse(cleanup.contains(.closeAppWheel))
        XCTAssertFalse(lifecycle.mappedOutputAvailable)
        XCTAssertFalse(lifecycle.isHeld(.a))
        XCTAssertEqual(lifecycle.handle(.setPaused(true)), [])

        let nextLaunch = OutputLifecycle(
            targetControllerConnected: true,
            accessibilityGranted: true
        )
        XCTAssertTrue(nextLaunch.mappedOutputAvailable)
    }

    func testPausePreservesRecoveryRoutesButBlocksMappedRoutes() {
        var lifecycle = OutputLifecycle(
            targetControllerConnected: true,
            accessibilityGranted: true
        )
        _ = lifecycle.handle(.setPaused(true))
        let share = ControllerInput.button(.share, pressed: true)
        let l3 = ControllerInput.button(.l3, pressed: true)
        let ordinary = ControllerInput.button(.a, pressed: true)

        XCTAssertTrue(
            lifecycle.allows(
                .systemGesture(share, binding: .share, action: .overlay)
            )
        )
        XCTAssertFalse(
            lifecycle.allows(
                .systemGesture(
                    share,
                    binding: .share,
                    action: .key(KeyChord(keyCode: 36))
                )
            )
        )
        XCTAssertTrue(
            lifecycle.allows(
                .systemGesture(l3, binding: .longL3, action: .switchApp)
            )
        )
        XCTAssertTrue(lifecycle.allows(.appWheel(ordinary)))
        XCTAssertFalse(
            lifecycle.allows(
                .systemGesture(
                    l3,
                    binding: .shortL3,
                    action: .key(KeyChord(keyCode: 50))
                )
            )
        )
        XCTAssertFalse(
            lifecycle.allows(
                .appBinding(
                    ordinary,
                    action: .key(KeyChord(keyCode: 36))
                )
            )
        )
        XCTAssertFalse(lifecycle.allows(.herdrLayer(ordinary)))
    }

    func testTargetControllerDisconnectCleansUpAndReconnectResumesWithoutAnotherAction() {
        var lifecycle = OutputLifecycle(
            targetControllerConnected: true,
            accessibilityGranted: true
        )
        _ = lifecycle.setHeld(.a, pressed: true)

        XCTAssertEqual(
            lifecycle.handle(.setTargetControllerConnected(false)),
            .all
        )
        XCTAssertFalse(lifecycle.mappedOutputAvailable)
        XCTAssertFalse(lifecycle.isHeld(.a))
        XCTAssertEqual(
            lifecycle.handle(.setTargetControllerConnected(false)),
            []
        )

        XCTAssertEqual(
            lifecycle.handle(.setTargetControllerConnected(true)),
            []
        )
        XCTAssertTrue(lifecycle.mappedOutputAvailable)
    }

    func testAppContextTransitionCleansUpBeforeAcceptingNewOutput() {
        let ghostty = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: false
        )
        let herdr = AppContextClassifier.classify(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            herdrDetected: true
        )
        var lifecycle = OutputLifecycle(
            appContext: ghostty,
            targetControllerConnected: true,
            accessibilityGranted: true
        )
        _ = lifecycle.setHeld(.a, pressed: true)

        XCTAssertEqual(
            lifecycle.handle(.appContextChanged(herdr)),
            .all
        )
        XCTAssertEqual(lifecycle.appContext, herdr)
        XCTAssertTrue(lifecycle.mappedOutputAvailable)
        XCTAssertFalse(lifecycle.isHeld(.a))
        XCTAssertEqual(
            lifecycle.handle(.appContextChanged(herdr)),
            []
        )
    }

    func testMissingAccessibilityKeepsRecoveryRoutesAvailable() {
        var lifecycle = OutputLifecycle(
            targetControllerConnected: true,
            accessibilityGranted: false
        )
        let share = ControllerInput.button(.share, pressed: true)
        let ordinary = ControllerInput.button(.a, pressed: true)

        XCTAssertFalse(lifecycle.mappedOutputAvailable)
        XCTAssertTrue(
            lifecycle.allows(
                .systemGesture(share, binding: .share, action: .overlay)
            )
        )
        XCTAssertFalse(
            lifecycle.allows(
                .appBinding(
                    ordinary,
                    action: .key(KeyChord(keyCode: 36))
                )
            )
        )

        XCTAssertEqual(
            lifecycle.handle(.setAccessibilityGranted(true)),
            []
        )
        XCTAssertTrue(lifecycle.mappedOutputAvailable)
        _ = lifecycle.setHeld(.a, pressed: true)
        XCTAssertEqual(
            lifecycle.handle(.setAccessibilityGranted(false)),
            .suspendMappedOutput
        )
        XCTAssertFalse(lifecycle.mappedOutputAvailable)
        XCTAssertFalse(lifecycle.isHeld(.a))
    }

    func testShutdownPermanentlyCleansUpThisLifecycle() {
        var lifecycle = OutputLifecycle(
            targetControllerConnected: true,
            accessibilityGranted: true
        )
        let share = ControllerInput.button(.share, pressed: true)

        XCTAssertEqual(lifecycle.handle(.shutdown), .all)
        XCTAssertTrue(lifecycle.isTerminated)
        XCTAssertFalse(lifecycle.mappedOutputAvailable)
        XCTAssertFalse(
            lifecycle.allows(
                .systemGesture(share, binding: .share, action: .overlay)
            )
        )
        XCTAssertEqual(lifecycle.handle(.shutdown), [])
    }
}
