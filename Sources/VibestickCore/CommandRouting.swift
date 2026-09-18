import Foundation

/// Transient presentation state that participates in input ownership.
///
/// A merely visible bindings overlay is intentionally absent: it observes the
/// normalized input stream without taking ownership.
public struct InputRoutingContext: Equatable {
    public let captureActive: Bool
    public let appWheelActive: Bool
    public let herdrLayerActive: Bool

    public init(
        captureActive: Bool = false,
        appWheelActive: Bool = false,
        herdrLayerActive: Bool = false
    ) {
        self.captureActive = captureActive
        self.appWheelActive = appWheelActive
        self.herdrLayerActive = herdrLayerActive
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
    case herdrLayer(ControllerInput)
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

    private enum L3State {
        case idle
        case pending
        case longResolved
    }

    private var l3State = L3State.idle

    public init() {}

    public mutating func route(
        _ input: ControllerInput,
        context: InputRoutingContext,
        profile: ProfileStore,
        app: FocusedApp
    ) -> InputRoute {
        if context.captureActive {
            cancelL3IfReleased(input)
            return .capture(input)
        }
        if context.appWheelActive {
            cancelL3IfReleased(input)
            return .appWheel(input)
        }
        if case let .button(.share, pressed) = input {
            return .systemGesture(
                input,
                binding: pressed ? .share : nil,
                action: pressed ? profile.systemBinding(for: .share) : nil
            )
        }
        if case let .button(.l3, pressed) = input {
            if pressed {
                if case .idle = l3State {
                    l3State = .pending
                }
                return .systemGesture(input, binding: nil, action: nil)
            }

            defer { l3State = .idle }
            guard case .pending = l3State else {
                return .systemGesture(input, binding: nil, action: nil)
            }
            return .systemGesture(
                input,
                binding: .shortL3,
                action: profile.systemBinding(for: .shortL3)
            )
        }
        if context.herdrLayerActive {
            return .herdrLayer(input)
        }
        return .appBinding(
            input,
            action: action(for: input, profile: profile, app: app)
        )
    }

    public mutating func resolveLongL3(
        context: InputRoutingContext,
        profile: ProfileStore
    ) -> InputRoute? {
        guard case .pending = l3State else { return nil }
        l3State = .longResolved
        guard !context.captureActive, !context.appWheelActive else { return nil }

        return .systemGesture(
            .button(.l3, pressed: true),
            binding: .longL3,
            action: profile.systemBinding(for: .longL3)
        )
    }

    public mutating func resetTransientState() {
        l3State = .idle
    }

    public func action(
        for input: ControllerInput,
        profile: ProfileStore,
        app: FocusedApp
    ) -> BindingAction? {
        guard case let .button(button, pressed: true) = input else { return nil }
        return profile.action(for: button, app: app)
    }

    private mutating func cancelL3IfReleased(_ input: ControllerInput) {
        guard case .button(.l3, pressed: false) = input else { return }
        l3State = .idle
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
