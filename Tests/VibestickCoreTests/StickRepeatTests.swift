import XCTest
@testable import VibestickCore

final class StickRepeatTests: XCTestCase {
    private let tuning = StickTuning(
        deadZone: 0.25,
        repeatDelay: 0.4,
        repeatInterval: 0.08
    )

    func testDeadZoneRequiresMovementStrictlyBeyondThreshold() {
        var repeater = StickRepeater(tuning: tuning)

        XCTAssertEqual(
            repeater.update(axis: .leftX, value: 0.25, at: 10),
            []
        )
        XCTAssertEqual(
            repeater.update(axis: .leftX, value: 0.251, at: 10.1),
            [.leftRight]
        )
        XCTAssertTrue(repeater.isActive)
    }

    func testDirectionFiresImmediatelyThenRepeatsAfterDelayAtConfiguredInterval() {
        var repeater = StickRepeater(tuning: tuning)

        XCTAssertEqual(
            repeater.update(axis: .leftY, value: 1, at: 10),
            [.leftUp]
        )
        XCTAssertEqual(repeater.advance(to: 10.399), [])
        XCTAssertEqual(repeater.advance(to: 10.4), [.leftUp])
        XCTAssertEqual(repeater.advance(to: 10.479), [])
        XCTAssertEqual(repeater.advance(to: 10.48), [.leftUp])
    }

    func testEveryAxisMapsSignsToDirectionsAndReversalRestartsDelay() {
        let cases: [(StickAxis, Double, StickInput)] = [
            (.leftX, -1, .leftLeft),
            (.leftX, 1, .leftRight),
            (.leftY, -1, .leftDown),
            (.leftY, 1, .leftUp),
            (.rightX, -1, .rightLeft),
            (.rightX, 1, .rightRight),
            (.rightY, -1, .rightDown),
            (.rightY, 1, .rightUp),
        ]

        for (axis, value, expected) in cases {
            var repeater = StickRepeater(tuning: tuning)
            XCTAssertEqual(
                repeater.update(axis: axis, value: value, at: 10),
                [expected],
                "\(axis) at \(value)"
            )
        }

        var repeater = StickRepeater(tuning: tuning)
        XCTAssertEqual(
            repeater.update(axis: .rightX, value: -1, at: 20),
            [.rightLeft]
        )
        XCTAssertEqual(
            repeater.update(axis: .rightX, value: 1, at: 20.1),
            [.rightRight]
        )
        XCTAssertEqual(repeater.advance(to: 20.499), [])
        XCTAssertEqual(repeater.advance(to: 20.5), [.rightRight])
    }

    func testReleaseAndCancellationStopFutureOutput() {
        var released = StickRepeater(tuning: tuning)
        _ = released.update(axis: .leftX, value: 1, at: 10)

        XCTAssertEqual(
            released.update(axis: .leftX, value: 0.1, at: 10.2),
            []
        )
        XCTAssertFalse(released.isActive)
        XCTAssertEqual(released.advance(to: 11), [])

        var cancelled = StickRepeater(tuning: tuning)
        _ = cancelled.update(axis: .leftX, value: 1, at: 10)
        _ = cancelled.update(axis: .rightY, value: 1, at: 10.1)
        cancelled.cancel()

        XCTAssertFalse(cancelled.isActive)
        XCTAssertNil(cancelled.nextFireTime)
        XCTAssertEqual(cancelled.advance(to: 11), [])
    }

    func testEveryHigherPriorityRouteCancelsRepeatingStickInput() {
        let input = ControllerInput.button(.a, pressed: true)
        let higherPriorityRoutes: [InputRoute] = [
            .capture(input),
            .appWheel(input),
            .systemGesture(
                .button(.l3, pressed: true),
                binding: nil,
                action: nil
            ),
            .herdrLayer(input, action: nil),
        ]

        XCTAssertTrue(
            higherPriorityRoutes.allSatisfy(\.cancelsRepeatingStickInput)
        )
        XCTAssertFalse(
            InputRoute.appBinding(input, action: nil)
                .cancelsRepeatingStickInput
        )
        XCTAssertFalse(
            InputRoute.systemGesture(
                .button(.share, pressed: true),
                binding: .share,
                action: .overlay
            ).cancelsRepeatingStickInput
        )
    }

    func testLateAdvanceDoesNotBurstMissedRepeatsAndKeepsCadence() throws {
        var repeater = StickRepeater(tuning: tuning)
        _ = repeater.update(axis: .leftX, value: 1, at: 10)

        XCTAssertEqual(repeater.advance(to: 10.57), [.leftRight])
        XCTAssertEqual(
            try XCTUnwrap(repeater.nextFireTime),
            10.64,
            accuracy: 0.000_001
        )
    }

    func testScrollDeltaFollowsNaturalScrollingDirectionOnBothAxes() {
        XCTAssertEqual(
            ScrollDirection.up.delta(naturalScrolling: true),
            ScrollDelta(vertical: 1, horizontal: 0)
        )
        XCTAssertEqual(
            ScrollDirection.down.delta(naturalScrolling: false),
            ScrollDelta(vertical: 1, horizontal: 0)
        )
        XCTAssertEqual(
            ScrollDirection.left.delta(naturalScrolling: true),
            ScrollDelta(vertical: 0, horizontal: 1)
        )
        XCTAssertEqual(
            ScrollDirection.right.delta(naturalScrolling: false),
            ScrollDelta(vertical: 0, horizontal: 1)
        )
    }
}

@MainActor
final class SupportedAppStickMappingTests: XCTestCase {
    func testEverySupportedAppContextReceivesDefaultNavigationAndScrolling() {
        let store = ProfileStore(loadFromDisk: false)
        let apps = [
            AppContextClassifier.classify(
                bundleID: "com.mitchellh.ghostty",
                name: "Ghostty",
                herdrDetected: true
            ),
            AppContextClassifier.classify(
                bundleID: "com.mitchellh.ghostty",
                name: "Ghostty",
                herdrDetected: false
            ),
            FocusedApp(
                bundleID: "com.tinyspeck.slackmacgap",
                name: "Slack"
            ),
        ]

        for app in apps {
            XCTAssertEqual(
                store.stickMapping(for: .leftUp, app: app),
                .key(KeyChord(keyCode: 126)),
                app.name
            )
            XCTAssertEqual(
                store.stickMapping(for: .rightDown, app: app),
                .scroll(.down),
                app.name
            )
        }
    }
}
