import Foundation

/// The boundary between normalized controller events, profile resolution, and
/// platform-specific output. The executable coordinator remains responsible
/// for gesture precedence and presentation lifecycle.
@MainActor
public protocol OutputAction {
    func send(_ action: BindingAction, from button: PadButton, to app: FocusedApp)
}

@MainActor
public struct CommandRouter {
    public init() {}

    public func action(
        for input: ControllerInput,
        profile: ProfileStore,
        app: FocusedApp
    ) -> BindingAction? {
        guard case let .button(button, pressed: true) = input else { return nil }
        return profile.action(for: button, app: app)
    }
}

public enum AppContextClassifier {
    public static func classify(
        bundleID: String,
        name: String,
        herdrDetected: Bool
    ) -> FocusedApp {
        guard GhosttyPreset.matches(bundleID), herdrDetected else {
            return FocusedApp(bundleID: bundleID, name: name)
        }
        return FocusedApp(
            bundleID: bundleID,
            name: "\(name) · Herdr",
            context: .herdr
        )
    }
}

public enum HerdrSurfaceIdentifier {
    public static func matches(
        focusedWindowTitle: String?,
        focusedHerdrPaneTitles: [String]
    ) -> Bool {
        guard let focusedWindowTitle else { return false }
        let normalizedWindowTitle = normalize(focusedWindowTitle)
        let hasHerdrBrand = normalizedWindowTitle.hasPrefix("π > ") ||
            normalizedWindowTitle.hasPrefix("π - ")
        guard hasHerdrBrand else { return false }
        return focusedHerdrPaneTitles.contains {
            normalize($0) == normalizedWindowTitle
        }
    }

    private static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
