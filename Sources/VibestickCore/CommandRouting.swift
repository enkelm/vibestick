import Foundation

/// Transient application state that participates in input ownership.
///
/// A merely visible bindings overlay is intentionally absent: it observes the
/// normalized input stream without taking ownership.
public struct InputRoutingContext: Equatable {
    public let captureActive: Bool
    public let appWheelActive: Bool
    public let mappedOutputAvailable: Bool

    public init(
        captureActive: Bool = false,
        appWheelActive: Bool = false,
        mappedOutputAvailable: Bool = true
    ) {
        self.captureActive = captureActive
        self.appWheelActive = appWheelActive
        self.mappedOutputAvailable = mappedOutputAvailable
    }
}

/// The result of assigning one normalized controller input to exactly one
/// owner. Routes with an action have resolved configuration at routing time.
public enum InputRoute: Equatable {
    case capture(ControllerInput)
    case appWheel(ControllerInput)
    case systemGesture(
        ControllerInput,
        binding: SystemBinding?,
        action: BindingAction?
    )
    case herdrLayer(ControllerInput, action: BindingAction?)
    case appBinding(ControllerInput, action: BindingAction?)
}

/// The boundary between normalized controller events, ownership, profile
/// resolution, and platform-specific output.
@MainActor
public protocol OutputAction {
    func send(_ action: BindingAction, from button: PadButton, to app: FocusedApp)
}

@MainActor
public struct CommandRouter {
    public static let longL3Duration: TimeInterval = 0.65
    public static let herdrLayerArmDuration: TimeInterval = 2

    private enum SystemGestureInput {
        case l3(pressed: Bool)
        case share(pressed: Bool)
    }

    private enum L3State {
        case idle
        case pending(since: TimeInterval)
        case longResolved
    }

    private enum HerdrLayerState {
        case idle
        case backHeld(executedAction: Bool)
        case armed(until: TimeInterval)
        case cancelling
    }

    private var l3State = L3State.idle
    private var herdrLayerState = HerdrLayerState.idle
    private var activeTriggers: Set<PadButton> = []

    public init() {}

    public mutating func route(
        _ input: ControllerInput,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
        context: InputRoutingContext,
        profile: ProfileStore,
        app: FocusedApp
    ) -> InputRoute {
        let activatedButton = updateTriggerState(for: input)
        if context.captureActive {
            cancelPendingGesturesIfReleased(input)
            return .capture(input)
        }
        if context.appWheelActive {
            cancelPendingGesturesIfReleased(input)
            return .appWheel(input)
        }
        switch Self.systemGesture(for: input) {
        case let .share(pressed):
            return .systemGesture(
                input,
                binding: pressed ? .share : nil,
                action: pressed ? profile.systemBinding(for: .share) : nil
            )
        case let .l3(pressed):
            if pressed {
                if case .idle = l3State {
                    l3State = .pending(since: timestamp)
                }
                return .systemGesture(input, binding: nil, action: nil)
            }

            defer { l3State = .idle }
            guard case let .pending(since) = l3State else {
                return .systemGesture(input, binding: nil, action: nil)
            }
            let binding: SystemBinding = timestamp - since >= Self.longL3Duration
                ? .longL3
                : .shortL3
            return .systemGesture(
                input,
                binding: binding,
                action: profile.systemBinding(for: binding)
            )
        case nil:
            break
        }
        guard context.mappedOutputAvailable else {
            herdrLayerState = .idle
            return .appBinding(input, action: nil)
        }
        if app.isHerdr,
           let route = routeHerdrLayer(
               input,
               activatedButton: activatedButton,
               at: timestamp,
               profile: profile
           ) {
            return route
        }
        return .appBinding(
            input,
            action: activatedButton.map { profile.action(for: $0, app: app) }
        )
    }

    public mutating func resolveLongL3(
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
        context: InputRoutingContext,
        profile: ProfileStore
    ) -> InputRoute? {
        guard case let .pending(since) = l3State,
              timestamp - since >= Self.longL3Duration
        else { return nil }
        l3State = .longResolved
        guard !context.captureActive, !context.appWheelActive else { return nil }

        return .systemGesture(
            .button(.l3, pressed: true),
            binding: .longL3,
            action: profile.systemBinding(for: .longL3)
        )
    }

    public static func ownsSystemGesture(_ input: ControllerInput) -> Bool {
        systemGesture(for: input) != nil
    }

    public mutating func resetTransientState() {
        l3State = .idle
        herdrLayerState = .idle
        activeTriggers.removeAll()
    }

    public func action(
        for input: ControllerInput,
        profile: ProfileStore,
        app: FocusedApp
    ) -> BindingAction? {
        guard case let .button(button, pressed: true) = input else { return nil }
        return profile.action(for: button, app: app)
    }

    private mutating func cancelPendingGesturesIfReleased(
        _ input: ControllerInput
    ) {
        switch input {
        case .button(.l3, pressed: false):
            l3State = .idle
        case .button(.back, pressed: false):
            herdrLayerState = .idle
        default:
            break
        }
    }

    private mutating func updateTriggerState(
        for input: ControllerInput
    ) -> PadButton? {
        switch input {
        case let .button(button, pressed):
            return pressed ? button : nil
        case let .trigger(button, value):
            let pressed = value >= 0.5
            let wasPressed = activeTriggers.contains(button)
            if pressed {
                activeTriggers.insert(button)
            } else {
                activeTriggers.remove(button)
            }
            return pressed && !wasPressed ? button : nil
        case .axis:
            return nil
        }
    }

    private mutating func routeHerdrLayer(
        _ input: ControllerInput,
        activatedButton: PadButton?,
        at timestamp: TimeInterval,
        profile: ProfileStore
    ) -> InputRoute? {
        if case let .button(.back, pressed) = input {
            if pressed {
                if case let .armed(until) = herdrLayerState,
                   timestamp <= until {
                    herdrLayerState = .cancelling
                } else {
                    herdrLayerState = .backHeld(executedAction: false)
                }
            } else if case let .backHeld(executedAction) = herdrLayerState {
                herdrLayerState = executedAction
                    ? .idle
                    : .armed(until: timestamp + Self.herdrLayerArmDuration)
            } else if case .cancelling = herdrLayerState {
                herdrLayerState = .idle
            }
            return .herdrLayer(input, action: nil)
        }
        switch herdrLayerState {
        case .idle:
            return nil
        case .backHeld:
            guard let button = activatedButton,
                  let action = profile.herdrLayerAction(for: button)
            else {
                return .herdrLayer(input, action: nil)
            }
            herdrLayerState = .backHeld(executedAction: true)
            return .herdrLayer(input, action: action)
        case let .armed(until):
            guard timestamp <= until else {
                herdrLayerState = .idle
                return nil
            }
            guard let button = activatedButton,
                  let action = profile.herdrLayerAction(for: button)
            else {
                return .herdrLayer(input, action: nil)
            }
            herdrLayerState = .idle
            return .herdrLayer(input, action: action)
        case .cancelling:
            guard let button = activatedButton,
                  let action = profile.herdrLayerAction(for: button)
            else {
                return .herdrLayer(input, action: nil)
            }
            herdrLayerState = .backHeld(executedAction: true)
            return .herdrLayer(input, action: action)
        }
    }

    private static func systemGesture(
        for input: ControllerInput
    ) -> SystemGestureInput? {
        guard case let .button(button, pressed) = input else { return nil }
        switch button {
        case .l3:
            return .l3(pressed: pressed)
        case .share:
            return .share(pressed: pressed)
        default:
            return nil
        }
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
