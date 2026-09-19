import Foundation

public struct OutputCleanup: OptionSet, Equatable {
    public let rawValue: UInt8

    public static let cancelPendingRoutes = OutputCleanup(rawValue: 1 << 0)
    public static let closeAppWheel = OutputCleanup(rawValue: 1 << 1)

    public static let suspendMappedOutput: OutputCleanup = [
        .cancelPendingRoutes,
    ]
    public static let all: OutputCleanup = [
        .cancelPendingRoutes,
        .closeAppWheel,
    ]

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

public enum OutputLifecycleEvent {
    case setPaused(Bool)
    case setBindingsEditing(Bool)
    case setTargetControllerConnected(Bool)
    case setAccessibilityGranted(Bool)
    case appContextChanged(FocusedApp)
    case shutdown
}

/// Owns session-only output availability and the cleanup required when output
/// becomes unavailable.
public struct OutputLifecycle {
    public private(set) var isPaused = false
    public private(set) var isBindingsEditing = false
    public private(set) var isTerminated = false
    public private(set) var appContext: FocusedApp?
    public private(set) var targetControllerConnected: Bool
    public private(set) var accessibilityGranted: Bool
    private var heldControls: Set<PadButton> = []

    public init(
        appContext: FocusedApp? = nil,
        targetControllerConnected: Bool = false,
        accessibilityGranted: Bool = false
    ) {
        self.appContext = appContext
        self.targetControllerConnected = targetControllerConnected
        self.accessibilityGranted = accessibilityGranted
    }

    public var mappedOutputAvailable: Bool {
        !isTerminated &&
            !isPaused &&
            !isBindingsEditing &&
            targetControllerConnected &&
            accessibilityGranted
    }

    @discardableResult
    public mutating func setHeld(
        _ button: PadButton,
        pressed: Bool
    ) -> Bool {
        if pressed {
            return heldControls.insert(button).inserted
        }
        return heldControls.remove(button) != nil
    }

    public func isHeld(_ button: PadButton) -> Bool {
        heldControls.contains(button)
    }

    public var hasHeldControls: Bool {
        !heldControls.isEmpty
    }

    public func allows(_ route: InputRoute) -> Bool {
        guard !isTerminated, targetControllerConnected else { return false }

        if isBindingsEditing {
            switch route {
            case .capture:
                return true
            case let .systemGesture(_, binding, action):
                return binding == .share && (action == nil || action == .overlay)
            case .appWheel, .herdrLayer, .appBinding:
                return false
            }
        }

        switch route {
        case .capture, .appWheel:
            return true
        case .herdrLayer, .appBinding:
            return mappedOutputAvailable
        case let .systemGesture(_, binding, action):
            guard binding == .share || binding == .longL3 else {
                return binding == nil || mappedOutputAvailable
            }
            guard let action else { return true }
            return !action.requiresAccessibility || mappedOutputAvailable
        }
    }

    @discardableResult
    public mutating func handle(_ event: OutputLifecycleEvent) -> OutputCleanup {
        guard !isTerminated else { return [] }

        switch event {
        case let .setPaused(paused):
            guard paused != isPaused else { return [] }
            isPaused = paused
            return paused ? cleanUp(.suspendMappedOutput) : []
        case let .setBindingsEditing(editing):
            guard editing != isBindingsEditing else { return [] }
            isBindingsEditing = editing
            return cleanUp(.all)
        case let .setTargetControllerConnected(connected):
            guard connected != targetControllerConnected else { return [] }
            targetControllerConnected = connected
            return connected ? [] : cleanUp(.all)
        case let .setAccessibilityGranted(granted):
            guard granted != accessibilityGranted else { return [] }
            accessibilityGranted = granted
            return granted ? [] : cleanUp(.suspendMappedOutput)
        case let .appContextChanged(app):
            guard app != appContext else { return [] }
            let hadAppContext = appContext != nil
            appContext = app
            return hadAppContext ? cleanUp(.all) : []
        case .shutdown:
            isTerminated = true
            return cleanUp(.all)
        }
    }

    private mutating func cleanUp(_ cleanup: OutputCleanup) -> OutputCleanup {
        heldControls.removeAll()
        return cleanup
    }
}

private extension BindingAction {
    var requiresAccessibility: Bool {
        switch self {
        case .key, .sequence:
            return true
        case .none, .overlay, .switchApp:
            return false
        }
    }
}
