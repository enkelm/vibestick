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
        FocusedApp(
            bundleID: bundleID,
            name: herdrDetected ? "\(name) · Herdr" : name,
            isHerdr: herdrDetected
        )
    }
}
