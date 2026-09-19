import XCTest
@testable import VibestickCore

final class AppWheelTests: XCTestCase {
    func testCandidatesExcludeCurrentAndVibestickDeduplicateAndLimitToEight() {
        let applications = [
            application("current", name: "Current", bundleID: "app.current", isCurrent: true),
            application("current-copy", name: "Current Copy", bundleID: "app.current"),
            application("vibestick", name: "Vibestick", bundleID: "app.vibestick", isVibestick: true),
            application("vibestick-copy", name: "Vibestick Copy", bundleID: "app.vibestick"),
            application("accessory", name: "Accessory", bundleID: "app.accessory", isRegular: false),
            application("terminated", name: "Terminated", bundleID: "app.terminated", isTerminated: true),
            application("duplicate-old", name: "Duplicate", bundleID: "app.duplicate", recentUse: 1),
            application("duplicate-new", name: "Duplicate", bundleID: "app.duplicate", recentUse: 20),
        ] + (0..<10).map {
            application("app-\($0)", name: "App \($0)", bundleID: "app.\($0)", recentUse: UInt64(10 - $0))
        }

        let candidates = AppWheelCandidates.make(from: applications)

        XCTAssertEqual(candidates.count, 8)
        XCTAssertEqual(candidates.first?.id, "duplicate-new")
        XCTAssertEqual(Set(candidates.map(\.bundleID)).count, candidates.count)
        XCTAssertFalse(candidates.contains { $0.bundleID == "app.current" })
        XCTAssertFalse(candidates.contains { $0.bundleID == "app.vibestick" })
        XCTAssertFalse(candidates.contains { $0.bundleID == "app.accessory" })
        XCTAssertFalse(candidates.contains { $0.bundleID == "app.terminated" })
    }

    func testCandidatesUseMostRecentUseThenAlphabeticalFallback() {
        let applications = [
            application("unknown-z", name: "Zulu", bundleID: "app.zulu"),
            application("older", name: "Beta", bundleID: "app.beta", recentUse: 3),
            application("unknown-a", name: "Alpha", bundleID: "app.alpha"),
            application("newer-z", name: "Zulu Recent", bundleID: "app.zulu-recent", recentUse: 8),
            application("newer-a", name: "Alpha Recent", bundleID: "app.alpha-recent", recentUse: 8),
        ]

        XCTAssertEqual(
            AppWheelCandidates.make(from: applications).map(\.id),
            ["newer-a", "newer-z", "older", "unknown-a", "unknown-z"]
        )
    }

    func testRecencyTracksLatestUseWithoutChangingOnRead() {
        var recency = AppWheelRecency()

        recency.recordUse(of: "app.alpha")
        recency.recordUse(of: "app.beta")
        let alpha = recency.rank(for: "app.alpha")
        recency.recordUse(of: "app.alpha")

        XCTAssertEqual(alpha, 1)
        XCTAssertEqual(recency.rank(for: "app.beta"), 2)
        XCTAssertEqual(recency.rank(for: "app.alpha"), 3)
        XCTAssertNil(recency.rank(for: "app.unknown"))
    }

    func testWheelBeginsWithoutSelectionAndRetainsSelectionInDeadZone() {
        var interaction = AppWheelInteraction()

        interaction.begin(itemCount: 4)
        XCTAssertNil(interaction.selectedIndex)

        interaction.updateSelection(x: 1, y: 0)
        XCTAssertEqual(interaction.selectedIndex, 1)

        interaction.updateSelection(x: 0, y: 0)
        XCTAssertEqual(interaction.selectedIndex, 1)

        interaction.begin(itemCount: 4)
        XCTAssertNil(interaction.selectedIndex)
    }

    func testAPressActivatesOnlyExplicitSelection() {
        var interaction = AppWheelInteraction()
        interaction.begin(itemCount: 4)

        XCTAssertEqual(interaction.handle(button: .a, pressed: true), .none)
        interaction.updateSelection(x: 0, y: -1)
        XCTAssertEqual(interaction.handle(button: .a, pressed: false), .none)
        XCTAssertEqual(interaction.handle(button: .a, pressed: true), .activate(index: 2))
    }

    func testBPressCancelsAndL3ReleaseDoesNothing() {
        var interaction = AppWheelInteraction()
        interaction.begin(itemCount: 4)
        interaction.updateSelection(x: 0, y: 1)

        XCTAssertEqual(interaction.handle(button: .l3, pressed: false), .none)
        XCTAssertEqual(interaction.handle(button: .b, pressed: false), .none)
        XCTAssertEqual(interaction.handle(button: .b, pressed: true), .cancel)
    }

    @MainActor
    func testActiveWheelSuppressesEveryOrdinaryInput() {
        var router = CommandRouter()
        let store = ProfileStore(loadFromDisk: false)
        let app = FocusedApp(bundleID: "com.example.target", name: "Target")
        let action = BindingAction.key(KeyChord(keyCode: 36))
        store.beginEditing(app)
        store.setBinding(action, for: .a)

        let inputs: [ControllerInput] = [
            .button(.a, pressed: true),
            .button(.a, pressed: false),
            .trigger(.rt, value: 0.8),
            .axis(.rightX, value: 0.7),
        ]

        for input in inputs {
            XCTAssertEqual(
                router.route(
                    input,
                    context: .init(appWheelActive: true),
                    profile: store,
                    app: app
                ),
                .appWheel(input)
            )
        }
    }

    private func application(
        _ id: String,
        name: String,
        bundleID: String,
        recentUse: UInt64? = nil,
        isRegular: Bool = true,
        isTerminated: Bool = false,
        isCurrent: Bool = false,
        isVibestick: Bool = false
    ) -> AppWheelApplication {
        AppWheelApplication(
            id: id,
            name: name,
            bundleID: bundleID,
            recentUse: recentUse,
            isRegular: isRegular,
            isTerminated: isTerminated,
            isCurrent: isCurrent,
            isVibestick: isVibestick
        )
    }
}
