import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import IOKit.hid


// MARK: - Normalized controller model

public enum PadButton: String, CaseIterable, Codable, Identifiable, Hashable {
    case a
    case b
    case x
    case y
    case lb
    case rb
    case lt
    case rt
    case back
    case start
    case l3
    case r3
    case dpadUp = "dpad_up"
    case dpadDown = "dpad_down"
    case dpadLeft = "dpad_left"
    case dpadRight = "dpad_right"
    case guide
    case share

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dpadUp: return "D-pad up"
        case .dpadDown: return "D-pad down"
        case .dpadLeft: return "D-pad left"
        case .dpadRight: return "D-pad right"
        case .guide: return "Guide"
        default: return rawValue.uppercased()
        }
    }

    public var shortTitle: String {
        switch self {
        case .dpadUp: return "D↑"
        case .dpadDown: return "D↓"
        case .dpadLeft: return "D←"
        case .dpadRight: return "D→"
        case .guide: return "Guide"
        default: return rawValue.uppercased()
        }
    }
}

public enum StickAxis: String, CaseIterable, Equatable, Hashable {
    case leftX
    case leftY
    case rightX
    case rightY
}

public enum ControllerInput: Equatable {
    case button(PadButton, pressed: Bool)
    case trigger(PadButton, value: Double)
    case axis(StickAxis, value: Double)
}

public struct ConnectedDevice: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let vendorID: Int
    public let productID: Int

    public init(id: String, name: String, vendorID: Int, productID: Int) {
        self.id = id
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
    }

    public var displayName: String {
        String(format: "%@ · %04X:%04X", name, vendorID, productID)
    }
}

// MARK: - Xbox Series report adapter

/// The Xbox Series adapter mirrors herdr/plugins/gamepad/xbox-series.patch.
/// IOHIDValue removes the report ID; the remaining transport byte means the
/// standard GIP button bitmap starts at byte 3.
public enum XboxSeriesDecoder {
    public struct DecodedReport {
        public let buttons: [(PadButton, Bool)]
        public let triggers: [(PadButton, Double)]
        public let axes: [(StickAxis, Double)]
    }

    private static let buttonMap: [(mask: UInt16, button: PadButton)] = [
        (1 << 4, .a), (1 << 5, .b), (1 << 6, .x), (1 << 7, .y),
        (1 << 2, .start), (1 << 3, .back),
        (1 << 8, .dpadUp), (1 << 9, .dpadDown),
        (1 << 10, .dpadLeft), (1 << 11, .dpadRight),
        (1 << 12, .lb), (1 << 13, .rb),
        (1 << 14, .l3), (1 << 15, .r3),
    ]

    public static func decode(_ bytes: [UInt8], previousButtons: UInt16) -> DecodedReport? {
        guard bytes.count >= 17 else { return nil }

        let buttons = UInt16(bytes[3]) | (UInt16(bytes[4]) << 8)
        let changed = buttons ^ previousButtons
        let buttonEvents = buttonMap.compactMap { entry -> (PadButton, Bool)? in
            guard changed & entry.mask != 0 else { return nil }
            return (entry.button, buttons & entry.mask != 0)
        }

        let leftTrigger = min(
            Double(UInt16(bytes[5]) | (UInt16(bytes[6]) << 8)) / 1023.0,
            1.0
        )
        let rightTrigger = min(
            Double(UInt16(bytes[7]) | (UInt16(bytes[8]) << 8)) / 1023.0,
            1.0
        )
        let triggerEvents: [(PadButton, Double)] = [
            (.lt, leftTrigger),
            (.rt, rightTrigger),
        ]

        let axes = (0..<4).map { index -> (StickAxis, Double) in
            let offset = 9 + index * 2
            let raw = Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
            let value = max(-1.0, min(1.0, Double(raw) / 32768.0))
            let axis: StickAxis
            switch index {
            case 0: axis = .leftX
            case 1: axis = .leftY
            case 2: axis = .rightX
            default: axis = .rightY
            }
            return (axis, value)
        }

        return DecodedReport(buttons: buttonEvents, triggers: triggerEvents, axes: axes)
    }
}

// MARK: - Raw HID input source

final class RawHIDControllerReader {
    private let manager: IOHIDManager
    private let onEvent: (ControllerEvent) -> Void
    private var started = false
    private var devices: [ObjectIdentifier: ConnectedDevice] = [:]
    private var lastXboxButtons: [ObjectIdentifier: UInt16] = [:]

    init(onEvent: @escaping (ControllerEvent) -> Void) {
        self.onEvent = onEvent
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Xbox One/Series devices expose the GIP report as vendor-defined HID.
        // Match both usages used by macOS. Excluding Apple's synthetic HID
        // device prevents a second logical copy of every physical input.
        let matches: [[String: Any]] = [
            [
                kIOHIDVendorIDKey as String: TargetController.vendorID,
                kIOHIDProductIDKey as String: TargetController.productID,
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_GamePad,
                "GCSyntheticDevice": kCFBooleanFalse as Any,
            ],
            [
                kIOHIDVendorIDKey as String: TargetController.vendorID,
                kIOHIDProductIDKey as String: TargetController.productID,
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Joystick,
                "GCSyntheticDevice": kCFBooleanFalse as Any,
            ],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
    }

    func start() -> Bool {
        guard !started else { return true }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<RawHIDControllerReader>
                .fromOpaque(context)
                .takeUnretainedValue()
                .handleConnected(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<RawHIDControllerReader>
                .fromOpaque(context)
                .takeUnretainedValue()
                .handleDisconnected(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<RawHIDControllerReader>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        started = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        return started
    }

    func stop() {
        guard started else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        started = false
        devices.removeAll()
        lastXboxButtons.removeAll()
    }

    func connectedDevices() -> [ConnectedDevice] {
        Dictionary(grouping: devices.values, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.displayName < $1.displayName }
    }

    private func handleConnected(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard devices[key] == nil else { return }
        let connectedDevice = describe(device)
        let alreadyConnected = devices.values.contains { $0.id == connectedDevice.id }
        devices[key] = connectedDevice
        if !alreadyConnected {
            onEvent(.connected(connectedDevice))
        }
    }

    private func handleDisconnected(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard let connectedDevice = devices.removeValue(forKey: key) else { return }
        lastXboxButtons.removeValue(forKey: key)
        if !devices.values.contains(where: { $0.id == connectedDevice.id }) {
            onEvent(.disconnected(connectedDevice))
        }
    }

    private func describe(_ device: IOHIDDevice) -> ConnectedDevice {
        let name = IOHIDDeviceGetProperty(
            device,
            kIOHIDProductKey as CFString
        ) as? String ?? "Xbox Wireless Controller"
        let vendor = (
            IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber
        )?.intValue ?? 0
        let product = (
            IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber
        )?.intValue ?? 0
        let location = (
            IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber
        )?.uint32Value ?? 0
        return ConnectedDevice(
            id: String(format: "%04X:%04X:%08X", vendor, product, location),
            name: name,
            vendorID: vendor,
            productID: product
        )
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let device = IOHIDElementGetDevice(element)
        let deviceID = ObjectIdentifier(device)
        let raw = IOHIDValueGetIntegerValue(value)

        // This is the exact vendor-defined path from xbox-series.patch.
        if page == 0xFF00 && usage == 0x20 {
            let length = Int(IOHIDValueGetLength(value))
            let pointer = IOHIDValueGetBytePtr(value)
            guard length >= 17 else { return }
            let bytes = Array(UnsafeBufferPointer(start: pointer, count: length))
            handleXboxReport(bytes, deviceID: deviceID)
            return
        }

        if page == UInt32(kHIDPage_Button) {
            guard let button = genericButton(for: usage) else { return }
            onEvent(.input(.button(button, pressed: raw != 0)))
            return
        }

        guard page == UInt32(kHIDPage_GenericDesktop) else { return }
        guard usage != UInt32(kHIDUsage_GD_GamePad), usage != UInt32(kHIDUsage_GD_Joystick) else { return }
        let lower = IOHIDElementGetLogicalMin(element)
        let upper = IOHIDElementGetLogicalMax(element)
        guard upper > lower else { return }
        let normalized = Double(raw - lower) / Double(upper - lower)

        switch usage {
        case 0x32:
            emitTrigger(.lt, value: normalized)
        case 0x35:
            emitTrigger(.rt, value: normalized)
        case 0x30:
            emitAxis(.leftX, value: normalized * 2.0 - 1.0)
        case 0x31:
            emitAxis(.leftY, value: normalized * 2.0 - 1.0)
        case 0x33:
            emitAxis(.rightX, value: normalized * 2.0 - 1.0)
        case 0x34:
            emitAxis(.rightY, value: normalized * 2.0 - 1.0)
        default:
            break
        }
    }

    private func handleXboxReport(_ bytes: [UInt8], deviceID: ObjectIdentifier) {
        let previousButtons = lastXboxButtons[deviceID] ?? 0
        guard let report = XboxSeriesDecoder.decode(bytes, previousButtons: previousButtons) else { return }
        let buttons = UInt16(bytes[3]) | (UInt16(bytes[4]) << 8)
        lastXboxButtons[deviceID] = buttons

        for (button, pressed) in report.buttons {
            onEvent(.input(.button(button, pressed: pressed)))
        }

        for (button, value) in report.triggers {
            emitTrigger(button, value: value)
        }

        for (axis, value) in report.axes {
            emitAxis(axis, value: value)
        }
    }

    private func genericButton(for usage: UInt32) -> PadButton? {
        switch usage {
        case 1: return .a
        case 2: return .b
        case 3: return .x
        case 4: return .y
        case 5: return .lb
        case 6: return .rb
        case 7: return .l3
        case 8: return .r3
        case 9: return .start
        case 10: return .back
        case 11: return .guide
        case 12: return .dpadUp
        case 13: return .dpadDown
        case 14: return .dpadLeft
        case 15: return .dpadRight
        default: return nil
        }
    }

    private func emitTrigger(_ button: PadButton, value: Double) {
        onEvent(.input(.trigger(button, value: max(0.0, min(1.0, value)))))
    }

    private func emitAxis(_ axis: StickAxis, value: Double) {
        let clamped = max(-1.0, min(1.0, value))
        onEvent(.input(.axis(axis, value: clamped)))
    }
}

// MARK: - Keyboard bindings and persistence

public struct KeyModifiers: OptionSet, Codable, Hashable {
    public let rawValue: UInt8

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(event: NSEvent) {
        var result: KeyModifiers = []
        if event.modifierFlags.contains(.shift) { result.insert(.shift) }
        if event.modifierFlags.contains(.control) { result.insert(.control) }
        if event.modifierFlags.contains(.option) { result.insert(.option) }
        if event.modifierFlags.contains(.command) { result.insert(.command) }
        if event.modifierFlags.contains(.function) { result.insert(.function) }
        self = result
    }

    public var displayPrefix: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        if contains(.function) { result += "fn " }
        return result
    }

    public var cgFlags: CGEventFlags {
        var result: CGEventFlags = []
        if contains(.shift) { result.insert(.maskShift) }
        if contains(.control) { result.insert(.maskControl) }
        if contains(.option) { result.insert(.maskAlternate) }
        if contains(.command) { result.insert(.maskCommand) }
        if contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }
}

public struct KeyChord: Codable, Hashable {
    public let keyCode: UInt16
    public let modifiers: KeyModifiers

    public init(keyCode: UInt16, modifiers: KeyModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init(event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: KeyModifiers(event: event))
    }

    public var displayName: String {
        modifiers.displayPrefix + KeyNames.name(for: keyCode)
    }
}

public enum KeyNames {
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        50: "`", 51: "Delete", 53: "Escape", 54: "Right ⌘", 55: "Left ⌘",
        56: "Left ⇧", 57: "Caps Lock", 58: "Left ⌥", 59: "Left ⌃", 60: "Right ⇧",
        61: "Right ⌥", 62: "Right ⌃", 63: "fn", 65: "Keypad .", 67: "Keypad *",
        69: "Keypad +", 71: "Clear", 75: "Keypad /", 76: "Keypad Enter", 78: "Keypad -",
        81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3",
        86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8",
        92: "Keypad 9", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up",
        117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down",
        122: "F1", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
    ]

    public static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? String(format: "Key 0x%02X", keyCode)
    }
}

public enum BindingAction: Equatable, Codable {
    case none
    case overlay
    case switchApp
    case key(KeyChord)
    case sequence([KeyChord])

    private enum Kind: String, Codable {
        case none
        case overlay
        case switchApp
        case key
        case sequence
    }

    private struct WireChord: Codable {
        let keyCode: UInt16
        let modifiers: UInt8
    }

    private struct Wire: Codable {
        let kind: Kind
        let keyCode: UInt16?
        let modifiers: UInt8?
        let chords: [WireChord]?
    }

    public init(from decoder: Decoder) throws {
        let wire = try Wire(from: decoder)
        switch wire.kind {
        case .none: self = .none
        case .overlay: self = .overlay
        case .switchApp: self = .switchApp
        case .key:
            guard let keyCode = wire.keyCode else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "key binding has no keyCode")
                )
            }
            self = .key(KeyChord(keyCode: keyCode, modifiers: KeyModifiers(rawValue: wire.modifiers ?? 0)))
        case .sequence:
            guard let chords = wire.chords, !chords.isEmpty else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "sequence binding has no chords")
                )
            }
            self = .sequence(chords.map { KeyChord(keyCode: $0.keyCode, modifiers: KeyModifiers(rawValue: $0.modifiers)) })
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .none:
            try Wire(kind: .none, keyCode: nil, modifiers: nil, chords: nil).encode(to: encoder)
        case .overlay:
            try Wire(kind: .overlay, keyCode: nil, modifiers: nil, chords: nil).encode(to: encoder)
        case .switchApp:
            try Wire(kind: .switchApp, keyCode: nil, modifiers: nil, chords: nil).encode(to: encoder)
        case let .key(chord):
            try Wire(kind: .key, keyCode: chord.keyCode, modifiers: chord.modifiers.rawValue, chords: nil).encode(to: encoder)
        case let .sequence(chords):
            let wireChords = chords.map { WireChord(keyCode: $0.keyCode, modifiers: $0.modifiers.rawValue) }
            try Wire(kind: .sequence, keyCode: nil, modifiers: nil, chords: wireChords).encode(to: encoder)
        }
    }

    public var displayName: String {
        switch self {
        case .none: return "Unbound"
        case .overlay: return "Overlay"
        case .switchApp: return "Switch app"
        case let .key(chord): return chord.displayName
        case let .sequence(chords): return chords.map(\.displayName).joined(separator: " ")
        }
    }
}

public enum BindingSource: Equatable {
    case operatorOverride
    case preset
    case globalFallback
    case builtInDefault
    case unbound
}

public enum BindingEditorSection: String, CaseIterable, Equatable, Identifiable {
    case systemBindings
    case globalFallbacks
    case appProfile
    case herdrLayer
    case stickMappings

    public var id: String { rawValue }
}

public struct ResolvedBinding: Equatable {
    public let action: BindingAction
    public let source: BindingSource

    public init(action: BindingAction, source: BindingSource) {
        self.action = action
        self.source = source
    }
}

private enum HerdrShortcuts {
    static let prefix = KeyChord(keyCode: 11, modifiers: [.control]) // ctrl+b
}

public enum HerdrPreset {
    static let bindings: [PadButton: BindingAction] = [
        .a: .key(KeyChord(keyCode: 36)), // Return
        .b: .key(KeyChord(keyCode: 49)), // Space
        .x: .key(KeyChord(keyCode: 53)), // Escape
        .y: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 5)]), // prefix+g: session navigator
        .lb: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 35)]), // prefix+p: previous tab
        .rb: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 45)]), // prefix+n: next tab
        .lt: .key(KeyChord(keyCode: 126, modifiers: [.shift])), // previous agent
        .rt: .key(KeyChord(keyCode: 125, modifiers: [.shift])), // next agent
        .start: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 124)]), // prefix+right: next workspace
        .dpadLeft: .key(KeyChord(keyCode: 4, modifiers: [.control])), // ctrl+h
        .dpadDown: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 38)]), // prefix+j
        .dpadUp: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 40)]), // prefix+k
        .dpadRight: .key(KeyChord(keyCode: 37, modifiers: [.control])), // ctrl+l
    ]
}

public enum HerdrLayerPreset {
    static let bindings: [PadButton: BindingAction] = [
        .a: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 6)]), // prefix+z: zoom
        .b: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 9)]), // prefix+v: split vertical
        .y: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 27)]), // prefix+minus: split horizontal
        .x: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 48)]), // prefix+tab: last pane
        .rb: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 8)]), // prefix+c: new tab
        .start: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 123)]), // prefix+left: previous workspace
        .lb: .sequence([
            HerdrShortcuts.prefix,
            KeyChord(keyCode: 32, modifiers: [.shift]),
        ]), // prefix+shift+u: toggle sidebar
        .rt: .sequence([
            HerdrShortcuts.prefix,
            KeyChord(keyCode: 44, modifiers: [.shift]),
        ]), // prefix+?: help
        .lt: .sequence([HerdrShortcuts.prefix, KeyChord(keyCode: 1)]), // prefix+s: settings
    ]
}

public enum SlackPreset {
    static let bundleIDs = ["com.tinyspeck.slackmacgap"]

    public static func matches(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    /// Slack documents Command-Shift-H for starting, joining, leaving, or
    /// ending a huddle. Command-K is the quick switcher, so it is kept as a
    /// separate mapping; the editor still lets the user put it anywhere.
    static let bindings: [PadButton: BindingAction] = [
        .a: .key(KeyChord(keyCode: 4, modifiers: [.command, .shift])), // huddle toggle
        .b: .key(KeyChord(keyCode: 53)), // mark read or dismiss
        .x: .key(KeyChord(keyCode: 40, modifiers: [.command])), // quick switcher
        .y: .key(KeyChord(keyCode: 45, modifiers: [.command])), // compose
        .lb: .key(KeyChord(keyCode: 126, modifiers: [.option, .shift])), // previous unread
        .rb: .key(KeyChord(keyCode: 125, modifiers: [.option, .shift])), // next unread
        .lt: .key(KeyChord(keyCode: 0, modifiers: [.command, .shift])), // all unreads
        .rt: .key(KeyChord(keyCode: 5, modifiers: [.command])), // search
        .r3: .key(KeyChord(keyCode: 49, modifiers: [.command, .shift])), // huddle mute
        .dpadUp: .key(KeyChord(keyCode: 126, modifiers: [.option])), // previous conversation
        .dpadDown: .key(KeyChord(keyCode: 125, modifiers: [.option])), // next conversation
        .dpadLeft: .key(KeyChord(keyCode: 33, modifiers: [.command])), // back
        .dpadRight: .key(KeyChord(keyCode: 30, modifiers: [.command])), // forward
        .back: .key(KeyChord(keyCode: 18, modifiers: [.control])), // Home
        .start: .key(KeyChord(keyCode: 46, modifiers: [.command, .shift])), // Activity
    ]
}

public enum GhosttyPreset {
    static let bundleIDs = ["com.mitchellh.ghostty"]

    public static func matches(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    /// Conservative bindings for ordinary Ghostty surfaces. Herdr surfaces
    /// use HerdrPreset instead, after their focused terminal title is
    /// positively correlated with Herdr's focused pane.
    static let bindings: [PadButton: BindingAction] = [
        .a: .key(KeyChord(keyCode: 36)), // Return
        .b: .key(KeyChord(keyCode: 49)), // Space
        .x: .key(KeyChord(keyCode: 53)), // Escape
        .y: .key(KeyChord(keyCode: 48)), // Tab
        .lb: .key(KeyChord(keyCode: 33, modifiers: [.command, .shift])), // previous tab
        .rb: .key(KeyChord(keyCode: 30, modifiers: [.command, .shift])), // next tab
        .start: .key(KeyChord(keyCode: 17, modifiers: [.command])), // new tab
        .dpadUp: .key(KeyChord(keyCode: 126)),
        .dpadDown: .key(KeyChord(keyCode: 125)),
        .dpadLeft: .key(KeyChord(keyCode: 123)),
        .dpadRight: .key(KeyChord(keyCode: 124)),
    ]
}

private enum HerdrSurfaceDetector {
    private struct Snapshot: Decodable {
        struct Pane: Decodable {
            let paneID: String
            let terminalTitle: String?
            let terminalTitleStripped: String?

            enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
                case terminalTitle = "terminal_title"
                case terminalTitleStripped = "terminal_title_stripped"
            }
        }
        let focusedPaneID: String?
        let panes: [Pane]

        enum CodingKeys: String, CodingKey {
            case focusedPaneID = "focused_pane_id"
            case panes
        }
    }

    private struct Response: Decodable {
        struct Result: Decodable {
            let snapshot: Snapshot
        }
        let result: Result
    }

    public static func focusedSurfaceIsHerdr() -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.localizedName?.localizedCaseInsensitiveContains("ghostty") == true,
              let data = snapshotData(),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else { return false }

        let snapshot = response.result.snapshot
        let focusedPaneTitles = snapshot.panes
            .first { $0.paneID == snapshot.focusedPaneID }
            .map { [$0.terminalTitle, $0.terminalTitleStripped].compactMap { $0 } }
            ?? []
        return HerdrSurfaceIdentifier.matches(
            focusedWindowTitle: focusedWindowTitle(processID: application.processIdentifier),
            focusedHerdrPaneTitles: focusedPaneTitles
        )
    }

    private static func snapshotData() -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/herdr")
        process.arguments = ["api", "snapshot"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    private static func focusedWindowTitle(processID: pid_t) -> String? {
        let application = AXUIElementCreateApplication(processID)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        ) == .success,
              let focusedWindow
        else { return cgWindowTitle(processID: processID) }

        var title: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focusedWindow as! AXUIElement,
            kAXTitleAttribute as CFString,
            &title
        ) == .success,
           let title = title as? String,
           !title.isEmpty {
            return title
        }
        return cgWindowTitle(processID: processID)
    }

    private static func cgWindowTitle(processID: pid_t) -> String? {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return windows.first {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID &&
                ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }?[kCGWindowName as String] as? String
    }
}

public enum AppPresetCatalog {
    public static func bindings(for app: FocusedApp) -> [PadButton: BindingAction]? {
        preset(for: app)?.bindings
    }

    public static func name(for app: FocusedApp) -> String? {
        preset(for: app)?.name
    }

    private struct Preset {
        let name: String
        let bindings: [PadButton: BindingAction]
    }

    private static func preset(for app: FocusedApp) -> Preset? {
        switch app.context {
        case .herdr:
            return Preset(name: "Herdr", bindings: HerdrPreset.bindings)
        case .ordinaryGhostty:
            return Preset(name: "Ghostty", bindings: GhosttyPreset.bindings)
        case .slack:
            return Preset(name: "Slack", bindings: SlackPreset.bindings)
        case .unknown:
            return nil
        }
    }
}

public enum AppContext: Equatable {
    case herdr
    case ordinaryGhostty
    case slack
    case unknown
}

struct AppProfileKey: RawRepresentable, Hashable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func herdr(bundleID: String) -> AppProfileKey {
        AppProfileKey(rawValue: "herdr:\(bundleID)")
    }
}

public struct FocusedApp: Equatable {
    public let bundleID: String
    public let name: String
    public let context: AppContext

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
        if GhosttyPreset.matches(bundleID) {
            context = .ordinaryGhostty
        } else if SlackPreset.matches(bundleID) {
            context = .slack
        } else {
            context = .unknown
        }
    }

    init(bundleID: String, name: String, context: AppContext) {
        self.bundleID = bundleID
        self.name = name
        self.context = context
    }

    public var isHerdr: Bool { context == .herdr }

    var profileKey: AppProfileKey {
        context == .herdr
            ? AppProfileKey.herdr(bundleID: bundleID)
            : AppProfileKey(rawValue: bundleID)
    }

    static let unknown = FocusedApp(bundleID: "", name: "Unknown app")
}

@MainActor
public final class ProfileStore: ObservableObject {
    @Published public private(set) var focusedApp = FocusedApp.unknown
    @Published public private(set) var editingApp = FocusedApp.unknown
    @Published public private(set) var devices: [ConnectedDevice] = []
    @Published public private(set) var status = "Waiting for an Xbox controller"
    @Published public private(set) var accessibilityGranted = CGPreflightPostEventAccess()
    @Published public private(set) var configuration = VibestickConfiguration.defaults
    @Published public private(set) var configurationLoadOutcome: ConfigurationLoadOutcome = .notLoaded
    @Published public private(set) var configurationNotice: String?
    @Published public var editingSection: BindingEditorSection = .appProfile
    @Published public private(set) var isEditingBindings = false

    private let storageURL: URL?

    public var editingGlobal: Bool {
        get { editingSection == .globalFallbacks }
        set { editingSection = newValue ? .globalFallbacks : .appProfile }
    }

    public init(storageURL: URL? = nil, loadFromDisk: Bool = true) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.storageURL = appSupport.appendingPathComponent("Vibestick/config.json")
        }
        if loadFromDisk { load() }
    }
    public func refreshFocus(excluding bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let applicationBundleID = application.bundleIdentifier,
              applicationBundleID != bundleID
        else { return }
        focusedApp = AppContextClassifier.classify(
            bundleID: applicationBundleID,
            name: application.localizedName ?? applicationBundleID,
            herdrDetected: HerdrSurfaceDetector.focusedSurfaceIsHerdr()
        )
        if !isEditingBindings {
            editingApp = focusedApp
            if editingSection == .herdrLayer, !editingApp.isHerdr {
                editingSection = .appProfile
            }
        }
    }

    public func beginEditingFocusedApp() {
        editingApp = focusedApp
        if editingSection == .herdrLayer, !editingApp.isHerdr {
            editingSection = .appProfile
        }
        isEditingBindings = true
        announce("Editing \(focusedApp.name)'s app profile")
    }

    public func beginEditing(_ app: FocusedApp) {
        editingApp = app
        editingSection = .appProfile
        isEditingBindings = true
    }

    public func endEditing() {
        isEditingBindings = false
        editingApp = focusedApp
        if editingSection == .herdrLayer, !editingApp.isHerdr {
            editingSection = .appProfile
        }
    }

    public var availableEditingSections: [BindingEditorSection] {
        var sections: [BindingEditorSection] = [
            .systemBindings,
            .globalFallbacks,
            .appProfile,
        ]
        if editingApp.isHerdr {
            sections.append(.herdrLayer)
        }
        sections.append(.stickMappings)
        return sections
    }

    public var appPresetName: String? {
        guard editingSection == .appProfile else { return nil }
        return AppPresetCatalog.name(for: editingApp)
    }

    public func binding(for button: PadButton) -> BindingAction {
        switch editingSection {
        case .globalFallbacks:
            return configuration.globalFallbackBindings[button] ?? .none
        case .herdrLayer:
            return resolvedHerdrLayerBinding(for: button).action
        case .appProfile:
            return resolvedBinding(for: button, app: editingApp).action
        case .systemBindings, .stickMappings:
            return .none
        }
    }

    public func bindingSource(for button: PadButton) -> BindingSource {
        switch editingSection {
        case .globalFallbacks:
            return configuration.globalFallbackBindings[button] == nil
                ? .unbound
                : .globalFallback
        case .herdrLayer:
            return resolvedHerdrLayerBinding(for: button).source
        case .appProfile:
            return resolvedBinding(for: button, app: editingApp).source
        case .systemBindings, .stickMappings:
            return .unbound
        }
    }

    public func action(for button: PadButton, app: FocusedApp) -> BindingAction {
        resolvedBinding(for: button, app: app).action
    }

    public func resolvedBinding(for button: PadButton, app: FocusedApp) -> ResolvedBinding {
        if let action = configuration.appProfiles[app.profileKey.rawValue]?[button] {
            return ResolvedBinding(action: action, source: .operatorOverride)
        }
        if let action = AppPresetCatalog.bindings(for: app)?[button] {
            return ResolvedBinding(action: action, source: .preset)
        }
        if let action = configuration.globalFallbackBindings[button] {
            return ResolvedBinding(action: action, source: .globalFallback)
        }
        return ResolvedBinding(action: .none, source: .unbound)
    }

    public func resolvedHerdrLayerBinding(for button: PadButton) -> ResolvedBinding {
        if let action = configuration.herdrLayerOverrides[button] {
            return ResolvedBinding(action: action, source: .operatorOverride)
        }
        if let action = HerdrLayerPreset.bindings[button] {
            return ResolvedBinding(action: action, source: .preset)
        }
        return ResolvedBinding(action: .none, source: .unbound)
    }

    public func isOverride(for button: PadButton) -> Bool {
        bindingSource(for: button) == .operatorOverride
    }

    public func isAppDefault(for button: PadButton) -> Bool {
        bindingSource(for: button) == .preset
    }

    public func setBinding(_ action: BindingAction, for button: PadButton) {
        guard configurationAllowsChanges() else { return }
        switch editingSection {
        case .globalFallbacks:
            configuration.globalFallbackBindings[button] = action
            announce("Global · \(button.title) → \(action.displayName)")
        case .appProfile:
            guard !editingApp.bundleID.isEmpty else {
                announce("No focused app bundle ID; binding was not saved")
                return
            }
            let profileKey = editingApp.profileKey.rawValue
            var profile = configuration.appProfiles[profileKey] ?? [:]
            profile[button] = action
            configuration.appProfiles[profileKey] = profile
            announce("\(editingApp.name) · \(button.title) → \(action.displayName)")
        case .herdrLayer:
            configuration.herdrLayerOverrides[button] = action
            announce("Herdr layer · \(button.title) → \(action.displayName)")
        case .systemBindings, .stickMappings:
            return
        }
        save()
    }

    public func resetBinding(_ button: PadButton) {
        guard configurationAllowsChanges() else { return }
        switch editingSection {
        case .globalFallbacks:
            configuration.globalFallbackBindings.removeValue(forKey: button)
            announce("Reset global \(button.title) fallback")
        case .appProfile:
            removeAppOverride(for: button)
            announce("Reset \(editingApp.name) · \(button.title) to inherited default")
        case .herdrLayer:
            configuration.herdrLayerOverrides.removeValue(forKey: button)
            announce("Reset Herdr layer · \(button.title) to preset")
        case .systemBindings, .stickMappings:
            return
        }
        save()
    }

    public func resetEditingApp() {
        resetAppProfile(for: editingApp)
    }

    public func resetFocusedApp() {
        resetAppProfile(for: focusedApp)
    }

    private func resetAppProfile(for app: FocusedApp) {
        guard !app.bundleID.isEmpty else { return }
        guard configurationAllowsChanges() else { return }
        configuration.appProfiles.removeValue(forKey: app.profileKey.rawValue)
        save()
        announce("Reset \(app.name) to inherited defaults")
    }

    public func systemBinding(for binding: SystemBinding) -> BindingAction {
        configuration.systemBindings[binding] ?? .none
    }

    public func setSystemBinding(_ action: BindingAction, for binding: SystemBinding) {
        guard configurationAllowsChanges() else { return }
        configuration.systemBindings[binding] = action
        save()
    }

    public func isSystemBindingOverride(_ binding: SystemBinding) -> Bool {
        systemBinding(for: binding) != VibestickConfiguration.defaults.systemBindings[binding]
    }

    public func resetSystemBinding(_ binding: SystemBinding) {
        guard configurationAllowsChanges() else { return }
        configuration.systemBindings[binding] =
            VibestickConfiguration.defaults.systemBindings[binding]
        save()
        announce("Reset \(binding.rawValue) to its built-in default")
    }

    public func herdrLayerOverride(for button: PadButton) -> BindingAction? {
        configuration.herdrLayerOverrides[button]
    }

    public func herdrLayerAction(for button: PadButton) -> BindingAction? {
        configuration.herdrLayerOverrides[button] ??
            HerdrLayerPreset.bindings[button]
    }

    public func setHerdrLayerOverride(_ action: BindingAction?, for button: PadButton) {
        guard configurationAllowsChanges() else { return }
        configuration.herdrLayerOverrides[button] = action
        save()
    }

    public func stickMapping(for input: StickInput) -> StickMapping {
        configuration.stickMappings[input] ?? .none
    }

    public func stickMapping(for input: StickInput, app: FocusedApp) -> StickMapping {
        let hasAppProfile = configuration.appProfiles[app.profileKey.rawValue] != nil
        guard app.context != .unknown || hasAppProfile else {
            return .none
        }
        return stickMapping(for: input)
    }

    public func setStickMapping(_ mapping: StickMapping, for input: StickInput) {
        guard configurationAllowsChanges() else { return }
        configuration.stickMappings[input] = mapping
        save()
    }

    public func isStickMappingOverride(_ input: StickInput) -> Bool {
        stickMapping(for: input) != VibestickConfiguration.defaults.stickMappings[input]
    }

    public func resetStickMapping(_ input: StickInput) {
        guard configurationAllowsChanges() else { return }
        configuration.stickMappings[input] =
            VibestickConfiguration.defaults.stickMappings[input]
        save()
        announce("Reset \(input.rawValue) to its built-in default")
    }

    public func setStickTuning(_ tuning: StickTuning) {
        guard configurationAllowsChanges() else { return }
        configuration.stickTuning = tuning
        save()
    }

    public func setDevices(_ devices: [ConnectedDevice]) {
        self.devices = devices
    }

    public func setAccessibility(_ granted: Bool = CGPreflightPostEventAccess()) {
        accessibilityGranted = granted
    }

    public func announce(_ message: String) {
        status = message
    }

    public func describe(_ app: FocusedApp) -> String {
        app.bundleID.isEmpty ? app.name : "\(app.name) · \(app.bundleID)"
    }

    private func removeAppOverride(for button: PadButton) {
        let profileKey = editingApp.profileKey.rawValue
        guard var profile = configuration.appProfiles[profileKey] else { return }
        profile.removeValue(forKey: button)
        if profile.isEmpty {
            configuration.appProfiles.removeValue(forKey: profileKey)
        } else {
            configuration.appProfiles[profileKey] = profile
        }
    }

    private func configurationAllowsChanges() -> Bool {
        guard configurationLoadOutcome.allowsSaving else {
            announce(configurationNotice ?? "Configuration is read-only")
            return false
        }
        return true
    }

    private func load() {
        guard let storageURL else { return }
        let result = ConfigurationPersistence.load(from: storageURL)
        configuration = result.configuration
        configurationLoadOutcome = result.outcome
        configurationNotice = result.outcome.operatorNotice
        if let configurationNotice {
            status = configurationNotice
        } else if result.outcome == .loaded {
            status = "Loaded bindings from \(storageURL.lastPathComponent)"
        }
    }

    private func save() {
        guard let storageURL else { return }
        guard configurationLoadOutcome.allowsSaving else {
            status = configurationNotice ?? "Configuration is read-only"
            return
        }
        do {
            try ConfigurationPersistence.save(configuration, to: storageURL)
            if configurationLoadOutcome == .notLoaded || configurationLoadOutcome == .noFile {
                configurationLoadOutcome = .loaded
            }
        } catch {
            status = "Could not save bindings (\(error.localizedDescription))"
            configurationNotice = status
        }
    }
}
