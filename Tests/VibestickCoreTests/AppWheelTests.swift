import XCTest
@testable import VibestickCore

final class AppWheelTests: XCTestCase {
    func testCandidatesExcludeCurrentAndVibestickDeduplicateAndLimitToEight() {
        let applications = [
            application("current", name: "Current", applicationID: "app.current", isCurrent: true),
            application("current-copy", name: "Current Copy", applicationID: "app.current"),
            application("vibestick", name: "Vibestick", applicationID: "app.vibestick", isVibestick: true),
            application("vibestick-copy", name: "Vibestick Copy", applicationID: "app.vibestick"),
            application("accessory", name: "Accessory", applicationID: "app.accessory", isRegular: false),
            application("terminated", name: "Terminated", applicationID: "app.terminated", isTerminated: true),
            application("duplicate-old", name: "Duplicate", applicationID: "app.duplicate", recencyRank: 1),
            application("duplicate-new", name: "Duplicate", applicationID: "app.duplicate", recencyRank: 20),
        ] + (0..<10).map {
            application("app-\($0)", name: "App \($0)", applicationID: "app.\($0)", recencyRank: UInt64(10 - $0))
        }

        let candidates = AppWheelCandidates.make(from: applications)

        XCTAssertEqual(candidates.count, 8)
        XCTAssertEqual(candidates.first?.id, "duplicate-new")
        XCTAssertEqual(Set(candidates.map(\.applicationID)).count, candidates.count)
        XCTAssertFalse(candidates.contains { $0.applicationID == "app.current" })
        XCTAssertFalse(candidates.contains { $0.applicationID == "app.vibestick" })
        XCTAssertFalse(candidates.contains { $0.applicationID == "app.accessory" })
        XCTAssertFalse(candidates.contains { $0.applicationID == "app.terminated" })
    }

    func testCandidatesUseMostRecentUseThenAlphabeticalFallback() {
        let applications = [
            application("unknown-z", name: "Zulu", applicationID: "app.zulu"),
            application("older", name: "Beta", applicationID: "app.beta", recencyRank: 3),
            application("unknown-a", name: "Alpha", applicationID: "app.alpha"),
            application("newer-z", name: "Zulu Recent", applicationID: "app.zulu-recent", recencyRank: 8),
            application("newer-a", name: "Alpha Recent", applicationID: "app.alpha-recent", recencyRank: 8),
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

    func testApplicationIdentityFallsBackToStableAppMetadataBeforeProcessID() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Example.app")
        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/Example")

        XCTAssertEqual(
            AppWheelApplicationIdentity.make(
                bundleIdentifier: nil,
                bundleURL: bundleURL,
                executableURL: executableURL,
                localizedName: "Example",
                processIdentifier: 10
            ),
            AppWheelApplicationIdentity.make(
                bundleIdentifier: nil,
                bundleURL: bundleURL,
                executableURL: executableURL,
                localizedName: "Example",
                processIdentifier: 20
            )
        )
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
        applicationID: String,
        recencyRank: UInt64? = nil,
        isRegular: Bool = true,
        isTerminated: Bool = false,
        isCurrent: Bool = false,
        isVibestick: Bool = false
    ) -> AppWheelApplication {
        AppWheelApplication(
            id: id,
            name: name,
            applicationID: applicationID,
            recencyRank: recencyRank,
            isRegular: isRegular,
            isTerminated: isTerminated,
            isCurrent: isCurrent,
            isVibestick: isVibestick
        )
    }
}
