import Foundation
import GameController

public enum TargetController {
    public static let vendorID = 0x045E
    public static let productID = 0x0B12
    public static let identifier = String(
        format: "%04X:%04X",
        vendorID,
        productID
    )
}

public enum ControllerBackend: String, CaseIterable, Equatable {
    case rawHID = "raw-hid"
    case gameController = "game-controller"
}

public enum ControllerEvent: Equatable {
    case connected(ConnectedDevice)
    case input(ControllerInput)
    case disconnected(ConnectedDevice)

    public var description: String {
        switch self {
        case let .connected(device):
            return "connected \(device.displayName)"
        case let .disconnected(device):
            return "disconnected \(device.displayName)"
        case let .input(.button(button, pressed)):
            return "\(button.rawValue) \(pressed ? "pressed" : "released")"
        case let .input(.trigger(button, value)):
            return String(format: "%@ %.3f", button.rawValue, value)
        case let .input(.axis(axis, value)):
            return String(format: "%@ %.3f", axis.rawValue, value)
        }
    }
}

/// Gives each physical control and lifecycle transition one production owner.
///
/// Raw HID remains authoritative for the target controller's established GIP
/// report and lifecycle. Game Controller contributes only Share, which the GIP
/// report does not expose. Game Controller's other events are still available
/// to diagnostics, but cannot duplicate production events.
public final class ControllerEventNormalizer {
    private var connectedDeviceID: String?
    private var buttons: [PadButton: Bool] = [:]
    private var triggers: [PadButton: Double] = [:]
    private var axes: [StickAxis: Double] = [:]

    public init() {}

    public func accept(
        _ event: ControllerEvent,
        from backend: ControllerBackend
    ) -> ControllerEvent? {
        guard owns(event, backend: backend) else { return nil }

        switch event {
        case let .connected(device):
            guard connectedDeviceID != device.id else { return nil }
            connectedDeviceID = device.id
        case let .disconnected(device):
            guard connectedDeviceID == device.id else { return nil }
            connectedDeviceID = nil
            buttons.removeAll()
            triggers.removeAll()
            axes.removeAll()
        case let .input(.button(button, pressed)):
            guard buttons[button] != pressed else { return nil }
            buttons[button] = pressed
        case let .input(.trigger(button, value)):
            guard changed(triggers[button], to: value, threshold: 0.02) else { return nil }
            triggers[button] = value
        case let .input(.axis(axis, value)):
            guard changed(axes[axis], to: value, threshold: 0.01) else { return nil }
            axes[axis] = value
        }
        return event
    }

    private func owns(_ event: ControllerEvent, backend: ControllerBackend) -> Bool {
        switch event {
        case .connected, .disconnected:
            return backend == .rawHID
        case let .input(.button(button, _)):
            return backend == (button == .share ? .gameController : .rawHID)
        case .input(.trigger), .input(.axis):
            return backend == .rawHID
        }
    }

    private func changed(
        _ previous: Double?,
        to value: Double,
        threshold: Double
    ) -> Bool {
        guard let previous else { return true }
        return abs(previous - value) >= threshold
    }
}

public struct ControllerDiagnosticRecord: Equatable {
    public let backend: ControllerBackend
    public let event: ControllerEvent

    public init(backend: ControllerBackend, event: ControllerEvent) {
        self.backend = backend
        self.event = event
    }

    public var description: String {
        "[\(backend.rawValue)] \(event.description)"
    }
}

public enum ControllerControl: Hashable {
    case button(PadButton)
    case axis(StickAxis)

    public var description: String {
        switch self {
        case let .button(button):
            return button.rawValue
        case let .axis(axis):
            return axis.rawValue
        }
    }
}

public struct ControllerDiagnosticCoverage {
    public static let requiredControls: Set<ControllerControl> = [
        .button(.a), .button(.b), .button(.x), .button(.y),
        .button(.lb), .button(.rb), .button(.lt), .button(.rt),
        .button(.back), .button(.start), .button(.l3), .button(.r3),
        .button(.dpadUp), .button(.dpadDown),
        .button(.dpadLeft), .button(.dpadRight),
        .button(.share),
        .axis(.leftX), .axis(.leftY), .axis(.rightX), .axis(.rightY),
    ]

    private var seen: [ControllerBackend: Set<ControllerControl>] = [:]

    public init() {}

    @discardableResult
    public mutating func record(_ record: ControllerDiagnosticRecord) -> Bool {
        let control: ControllerControl
        switch record.event {
        case let .input(.button(button, _)):
            control = .button(button)
        case let .input(.trigger(button, _)):
            control = .button(button)
        case let .input(.axis(axis, _)):
            control = .axis(axis)
        case .connected, .disconnected:
            return false
        }
        guard Self.requiredControls.contains(control) else { return false }
        return seen[record.backend, default: []].insert(control).inserted
    }

    public func missing(from backend: ControllerBackend) -> Set<ControllerControl> {
        Self.requiredControls.subtracting(seen[backend, default: []])
    }

    public func progressDescription(for backend: ControllerBackend) -> String {
        let missingControls = missing(from: backend)
        guard !missingControls.isEmpty else {
            return "\(backend.rawValue) COMPLETE: every required control was observed"
        }
        let seenCount = Self.requiredControls.count - missingControls.count
        let missingNames = missingControls
            .map(\.description)
            .sorted()
            .joined(separator: ", ")
        return "\(backend.rawValue) \(seenCount)/\(Self.requiredControls.count); missing: \(missingNames)"
    }
}

/// One normalized stream for the target controller.
///
/// IOHID owns exact-device discovery, connection lifecycle, and the established
/// GIP report. Game Controller is provisionally paired only when exactly one
/// target controller and one Xbox profile are present. It supplies Share and
/// mirrors all other controls to the diagnostic callback so an operator can
/// physically validate the pairing.
public final class ControllerReader {
    private enum ButtonKind {
        case digital
        case trigger
    }

    private struct ButtonMapping {
        let input: GCControllerButtonInput?
        let control: PadButton
        let kind: ButtonKind
    }

    private struct AxisMapping {
        let input: GCControllerAxisInput
        let axis: StickAxis
    }

    private let onEvent: (ControllerEvent) -> Void
    private let onDiagnostic: (ControllerDiagnosticRecord) -> Void
    private var normalizer = ControllerEventNormalizer()
    private var observers: [NSObjectProtocol] = []
    private var attachedControllers: [ObjectIdentifier: GCController] = [:]
    private var shareGestureStates: [ObjectIdentifier: GCControllerElement.SystemGestureState] = [:]
    private var started = false

    private lazy var rawReader = RawHIDControllerReader { [weak self] event in
        self?.handleRawEvent(event)
    }

    public init(
        onEvent: @escaping (ControllerEvent) -> Void,
        onDiagnostic: @escaping (ControllerDiagnosticRecord) -> Void = { _ in }
    ) {
        self.onEvent = onEvent
        self.onDiagnostic = onDiagnostic
    }

    public func start() -> Bool {
        guard !started else { return true }
        observeGameControllerLifecycle()
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        guard rawReader.start() else {
            removeGameControllerObservers()
            GCController.stopWirelessControllerDiscovery()
            return false
        }
        started = true
        attachEligibleGameController()
        return true
    }

    public func stop() {
        guard started else { return }
        detachAllGameControllers()
        removeGameControllerObservers()
        GCController.stopWirelessControllerDiscovery()
        rawReader.stop()
        normalizer = ControllerEventNormalizer()
        started = false
    }

    public func connectedDevices() -> [ConnectedDevice] {
        rawReader.connectedDevices()
    }

    public var diagnosticSummary: String {
        let targetCount = rawReader.connectedDevices().count
        let xboxProfiles = GCController.controllers().compactMap {
            $0.extendedGamepad as? GCXboxGamepad
        }
        let shareCount = xboxProfiles.compactMap(\.buttonShare).count
        let correlation: String
        if targetCount == 1, xboxProfiles.count == 1 {
            correlation = "candidate available (GameController does not expose hardware identity)"
        } else if targetCount == 0 {
            correlation = "waiting for target controller \(TargetController.identifier)"
        } else {
            correlation = "ambiguous (\(targetCount) target controller, \(xboxProfiles.count) Xbox profiles)"
        }
        return """
        Candidate backend: raw HID owns lifecycle and standard controls; Game Controller owns Share
        Target controller connections: \(targetCount)
        Xbox Game Controller profiles: \(xboxProfiles.count)
        Share elements: \(shareCount)
        Provisional pairing: \(correlation)
        """
    }

    private func emit(_ event: ControllerEvent, from backend: ControllerBackend) {
        onDiagnostic(ControllerDiagnosticRecord(backend: backend, event: event))
        guard let normalized = normalizer.accept(event, from: backend) else { return }
        onEvent(normalized)
    }

    private func handleRawEvent(_ event: ControllerEvent) {
        emit(event, from: .rawHID)
        switch event {
        case .connected:
            attachEligibleGameController()
        case .disconnected where rawReader.connectedDevices().isEmpty:
            detachAllGameControllers()
        case .input, .disconnected:
            break
        }
    }

    private func observeGameControllerLifecycle() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                self?.handleGameControllerConnected(controller)
            },
            center.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                self?.handleGameControllerDisconnected(controller)
            },
        ]
    }

    private func removeGameControllerObservers() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    private func handleGameControllerConnected(_ controller: GCController) {
        emit(.connected(describe(controller)), from: .gameController)
        attachEligibleGameController()
    }

    private func handleGameControllerDisconnected(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        if attachedControllers.removeValue(forKey: key) != nil {
            clearHandlers(for: controller)
        }
        emit(.disconnected(describe(controller)), from: .gameController)
    }

    private func attachEligibleGameController() {
        guard rawReader.connectedDevices().count == 1 else {
            detachAllGameControllers()
            return
        }
        let candidates = GCController.controllers().filter {
            $0.extendedGamepad is GCXboxGamepad
        }
        guard candidates.count == 1, let controller = candidates.first else {
            detachAllGameControllers()
            return
        }
        let key = ObjectIdentifier(controller)
        let obsoleteControllers = attachedControllers.filter { $0.key != key }
        for (attachedKey, attachedController) in obsoleteControllers {
            clearHandlers(for: attachedController)
            attachedControllers.removeValue(forKey: attachedKey)
        }
        guard attachedControllers[key] == nil else { return }
        attachedControllers[key] = controller
        installHandlers(for: controller)
    }

    private func detachAllGameControllers() {
        attachedControllers.values.forEach(clearHandlers)
        attachedControllers.removeAll()
    }

    private func installHandlers(for controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        if let share = (gamepad as? GCXboxGamepad)?.buttonShare {
            shareGestureStates[ObjectIdentifier(controller)] = share.preferredSystemGestureState
            share.preferredSystemGestureState = .disabled
        }
        for mapping in buttonMappings(for: gamepad) {
            guard let input = mapping.input else { continue }
            switch mapping.kind {
            case .digital:
                observeButton(input, as: mapping.control)
            case .trigger:
                observeTrigger(input, as: mapping.control)
            }
        }
        for mapping in axisMappings(for: gamepad) {
            observeAxis(mapping.input, as: mapping.axis)
        }
    }

    private func clearHandlers(for controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        let key = ObjectIdentifier(controller)
        if let gestureState = shareGestureStates.removeValue(forKey: key) {
            (gamepad as? GCXboxGamepad)?.buttonShare?.preferredSystemGestureState = gestureState
        }
        buttonMappings(for: gamepad).forEach { $0.input?.valueChangedHandler = nil }
        axisMappings(for: gamepad).forEach { $0.input.valueChangedHandler = nil }
    }

    private func buttonMappings(for gamepad: GCExtendedGamepad) -> [ButtonMapping] {
        [
            ButtonMapping(input: gamepad.buttonA, control: .a, kind: .digital),
            ButtonMapping(input: gamepad.buttonB, control: .b, kind: .digital),
            ButtonMapping(input: gamepad.buttonX, control: .x, kind: .digital),
            ButtonMapping(input: gamepad.buttonY, control: .y, kind: .digital),
            ButtonMapping(input: gamepad.leftShoulder, control: .lb, kind: .digital),
            ButtonMapping(input: gamepad.rightShoulder, control: .rb, kind: .digital),
            ButtonMapping(input: gamepad.buttonMenu, control: .start, kind: .digital),
            ButtonMapping(input: gamepad.buttonOptions, control: .back, kind: .digital),
            ButtonMapping(input: gamepad.buttonHome, control: .guide, kind: .digital),
            ButtonMapping(input: gamepad.leftThumbstickButton, control: .l3, kind: .digital),
            ButtonMapping(input: gamepad.rightThumbstickButton, control: .r3, kind: .digital),
            ButtonMapping(input: gamepad.dpad.up, control: .dpadUp, kind: .digital),
            ButtonMapping(input: gamepad.dpad.down, control: .dpadDown, kind: .digital),
            ButtonMapping(input: gamepad.dpad.left, control: .dpadLeft, kind: .digital),
            ButtonMapping(input: gamepad.dpad.right, control: .dpadRight, kind: .digital),
            ButtonMapping(input: gamepad.leftTrigger, control: .lt, kind: .trigger),
            ButtonMapping(input: gamepad.rightTrigger, control: .rt, kind: .trigger),
            ButtonMapping(
                input: (gamepad as? GCXboxGamepad)?.buttonShare,
                control: .share,
                kind: .digital
            ),
        ]
    }

    private func axisMappings(for gamepad: GCExtendedGamepad) -> [AxisMapping] {
        [
            AxisMapping(input: gamepad.leftThumbstick.xAxis, axis: .leftX),
            AxisMapping(input: gamepad.leftThumbstick.yAxis, axis: .leftY),
            AxisMapping(input: gamepad.rightThumbstick.xAxis, axis: .rightX),
            AxisMapping(input: gamepad.rightThumbstick.yAxis, axis: .rightY),
        ]
    }

    private func observeButton(_ input: GCControllerButtonInput?, as button: PadButton) {
        input?.valueChangedHandler = { [weak self] _, value, _ in
            self?.emit(
                .input(.button(button, pressed: value >= 0.5)),
                from: .gameController
            )
        }
    }

    private func observeTrigger(_ input: GCControllerButtonInput, as trigger: PadButton) {
        input.valueChangedHandler = { [weak self] _, value, _ in
            self?.emit(
                .input(.trigger(trigger, value: Double(value))),
                from: .gameController
            )
        }
    }

    private func observeAxis(_ input: GCControllerAxisInput, as axis: StickAxis) {
        input.valueChangedHandler = { [weak self] _, value in
            self?.emit(
                .input(.axis(axis, value: Double(value))),
                from: .gameController
            )
        }
    }

    private func describe(_ controller: GCController) -> ConnectedDevice {
        ConnectedDevice(
            id: "game-controller-\(ObjectIdentifier(controller))",
            name: controller.vendorName ?? controller.productCategory,
            vendorID: 0,
            productID: 0
        )
    }
}
