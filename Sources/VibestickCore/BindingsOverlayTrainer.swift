import Combine

public enum BindingsOverlayPresentation: Equatable {
    case translucent
    case interactive
}

/// Observable state for the pass-through bindings trainer.
///
/// The trainer follows the active app independently from the editor's pinned
/// app context, so merely showing the overlay never changes input ownership.
@MainActor
public final class BindingsOverlayTrainer: ObservableObject {
    @Published public private(set) var appContext = FocusedApp.unknown
    @Published public private(set) var pressed: Set<PadButton> = []
    @Published public private(set) var triggers: [PadButton: Double] = [:]
    @Published public private(set) var axes: [StickAxis: Double] = [:]
    @Published public private(set) var presentation =
        BindingsOverlayPresentation.translucent

    public init() {}

    public func follow(_ app: FocusedApp) {
        appContext = app
    }

    public func setPointerInteraction(active: Bool) {
        presentation = active ? .interactive : .translucent
    }

    public func observe(_ input: ControllerInput) {
        switch input {
        case let .button(button, isPressed):
            if isPressed {
                pressed.insert(button)
            } else {
                pressed.remove(button)
            }
        case let .trigger(button, value):
            triggers[button] = value
            if value >= 0.5 {
                pressed.insert(button)
            } else {
                pressed.remove(button)
            }
        case let .axis(axis, value):
            axes[axis] = value
        }
    }

    public func clearController() {
        pressed.removeAll()
        triggers.removeAll()
        axes.removeAll()
    }

    public func resolvedBinding(
        for button: PadButton,
        profile: ProfileStore
    ) -> ResolvedBinding {
        profile.resolvedBinding(for: button, app: appContext)
    }
}
