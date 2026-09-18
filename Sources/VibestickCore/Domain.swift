import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation


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

public enum StickAxis: String {
    case leftX
    case leftY
    case rightX
    case rightY
}

public enum ControllerInput {
    case button(PadButton, pressed: Bool)
    case trigger(PadButton, value: Double)
    case axis(StickAxis, value: Double)
}

public struct ConnectedDevice: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let vendorID: Int
    public let productID: Int

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

// MARK: - HID input source

public final class ControllerReader {
    private let manager: IOHIDManager
    private let onInput: (ControllerInput) -> Void
    private var started = false
    private var lastXboxButtons: [ObjectIdentifier: UInt16] = [:]
    private var lastXboxTriggerPressed: [ObjectIdentifier: (Bool, Bool)] = [:]
    private var lastAxis: [String: Double] = [:]

    public init(onInput: @escaping (ControllerInput) -> Void) {
        self.onInput = onInput
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Xbox One/Series devices expose the GIP report as vendor-defined HID.
        // Match both usages used by macOS. Excluding Apple's synthetic HID
        // device prevents a second logical copy of every physical input.
        let matches: [[String: Any]] = [
            [
                kIOHIDVendorIDKey as String: 0x045E,
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_GamePad,
                "GCSyntheticDevice": kCFBooleanFalse as Any,
            ],
            [
                kIOHIDVendorIDKey as String: 0x045E,
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Joystick,
                "GCSyntheticDevice": kCFBooleanFalse as Any,
            ],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
    }

    public func start() -> Bool {
        guard !started else { return true }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<ControllerReader>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        started = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        return started
    }

    public func stop() {
        guard started else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        started = false
        lastXboxButtons.removeAll()
        lastXboxTriggerPressed.removeAll()
        lastAxis.removeAll()
    }

    public func connectedDevices() -> [ConnectedDevice] {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices.map { device in
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Xbox controller"
            let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
            let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
            return ConnectedDevice(
                id: String(format: "%04X:%04X:%@", vendor, product, name),
                name: name,
                vendorID: vendor,
                productID: product
            )
        }.sorted { $0.displayName < $1.displayName }
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
            onInput(.button(button, pressed: raw != 0))
            return
        }

        guard page == UInt32(kHIDPage_GenericDesktop) else { return }
        guard usage != UInt32(kHIDUsage_GD_GamePad), usage != UInt32(kHIDUsage_GD_Joystick) else { return }
        let lower = IOHIDElementGetLogicalMin(element)
        let upper = IOHIDElementGetLogicalMax(element)
        guard upper > lower else { return }
        let valueKey = "\(deviceID)-\(usage)"
        let normalized = Double(raw - lower) / Double(upper - lower)

        switch usage {
        case 0x32:
            emitTrigger(.lt, value: normalized, key: valueKey)
        case 0x35:
            emitTrigger(.rt, value: normalized, key: valueKey)
        case 0x30:
            emitAxis(.leftX, value: normalized * 2.0 - 1.0, key: valueKey)
        case 0x31:
            emitAxis(.leftY, value: normalized * 2.0 - 1.0, key: valueKey)
        case 0x33:
            emitAxis(.rightX, value: normalized * 2.0 - 1.0, key: valueKey)
        case 0x34:
            emitAxis(.rightY, value: normalized * 2.0 - 1.0, key: valueKey)
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
            onInput(.button(button, pressed: pressed))
        }

        let previousTriggers = lastXboxTriggerPressed[deviceID] ?? (false, false)
        var triggerState = previousTriggers
        for (button, value) in report.triggers {
            let pressed = value >= 0.5
            if button == .lt {
                triggerState.0 = pressed
                if pressed != previousTriggers.0 {
                    onInput(.trigger(button, value: value))
                }
            } else {
                triggerState.1 = pressed
                if pressed != previousTriggers.1 {
                    onInput(.trigger(button, value: value))
                }
            }
        }
        lastXboxTriggerPressed[deviceID] = triggerState

        for (axis, value) in report.axes {
            let key = "\(deviceID)-axis-\(axis.rawValue)"
            guard changedEnough(key, value: value, threshold: 0.01) else { continue }
            onInput(.axis(axis, value: value))
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

    private func emitTrigger(_ button: PadButton, value: Double, key: String) {
        guard changedEnough(key, value: value, threshold: 0.02) else { return }
        onInput(.trigger(button, value: max(0.0, min(1.0, value))))
    }

    private func emitAxis(_ axis: StickAxis, value: Double, key: String) {
        let clamped = max(-1.0, min(1.0, value))
        guard changedEnough(key, value: clamped, threshold: 0.01) else { return }
        onInput(.axis(axis, value: clamped))
    }

    private func changedEnough(_ key: String, value: Double, threshold: Double) -> Bool {
        if let previous = lastAxis[key], abs(previous - value) < threshold { return false }
        lastAxis[key] = value
        return true
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

public enum HerdrPreset {
    private static let prefix = KeyChord(keyCode: 11, modifiers: [.control]) // ctrl+b

    static let bindings: [PadButton: BindingAction] = [
        .a: .sequence([prefix, KeyChord(keyCode: 6)]), // prefix+z: zoom
        .b: .sequence([prefix, KeyChord(keyCode: 9)]), // prefix+v: split vertical
        .x: .sequence([prefix, KeyChord(keyCode: 48)]), // prefix+tab: last pane
        .y: .sequence([prefix, KeyChord(keyCode: 5)]), // prefix+g: session navigator
        .lb: .sequence([prefix, KeyChord(keyCode: 35)]), // prefix+p: previous tab
        .rb: .sequence([prefix, KeyChord(keyCode: 45)]), // prefix+n: next tab
        .lt: .key(KeyChord(keyCode: 126, modifiers: [.shift])), // previous agent
        .rt: .key(KeyChord(keyCode: 125, modifiers: [.shift])), // next agent
        .start: .sequence([prefix, KeyChord(keyCode: 124)]), // prefix+right: next workspace
        .dpadLeft: .key(KeyChord(keyCode: 4, modifiers: [.control])), // ctrl+h
        .dpadDown: .sequence([prefix, KeyChord(keyCode: 38)]), // prefix+j
        .dpadUp: .sequence([prefix, KeyChord(keyCode: 40)]), // prefix+k
        .dpadRight: .key(KeyChord(keyCode: 37, modifiers: [.control])), // ctrl+l
    ]
}

public enum SlackPreset {
    static let bundleIDs = ["com.tinyspeck.slackmacgap"]

    public static func matches(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID) || bundleID.localizedCaseInsensitiveContains("slack")
    }

    /// Slack documents Command-Shift-H for starting, joining, leaving, or
    /// ending a huddle. Command-K is the quick switcher, so it is kept as a
    /// separate mapping; the editor still lets the user put it anywhere.
    static let bindings: [PadButton: BindingAction] = [
        .a: .key(KeyChord(keyCode: 4, modifiers: [.command, .shift])), // huddle toggle
        .b: .key(KeyChord(keyCode: 53)), // mark current conversation read
        .x: .key(KeyChord(keyCode: 40, modifiers: [.command])), // quick switcher
        .y: .key(KeyChord(keyCode: 45, modifiers: [.command])), // compose
        .lb: .key(KeyChord(keyCode: 0, modifiers: [.command, .shift])), // all unreads
        .rb: .key(KeyChord(keyCode: 5, modifiers: [.command])), // search
        .lt: .key(KeyChord(keyCode: 3, modifiers: [.command])), // find
        .rt: .key(KeyChord(keyCode: 44, modifiers: [.command])), // shortcut list
        .l3: .key(KeyChord(keyCode: 125, modifiers: [.option, .shift])), // next unread
        .r3: .key(KeyChord(keyCode: 126, modifiers: [.option, .shift])), // previous unread
        .dpadUp: .key(KeyChord(keyCode: 38, modifiers: [.command])), // latest unread
    ]
}

public enum GhosttyPreset {
    public static func matches(_ bundleID: String) -> Bool {
        bundleID.localizedCaseInsensitiveContains("ghostty")
    }

    /// Fallback bindings for ordinary Ghostty surfaces. Herdr surfaces use
    /// HerdrPreset instead, detected from the focused terminal title.
    static let bindings: [PadButton: BindingAction] = [
        .a: .key(KeyChord(keyCode: 17, modifiers: [.command])),
        .b: .key(KeyChord(keyCode: 13, modifiers: [.command])),
        .x: .key(KeyChord(keyCode: 33, modifiers: [.command, .shift])),
        .y: .key(KeyChord(keyCode: 30, modifiers: [.command, .shift])),
        .lb: .key(KeyChord(keyCode: 45, modifiers: [.command])),
        .start: .key(KeyChord(keyCode: 50, modifiers: [.command, .option])),
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

        guard let windowTitle = focusedWindowTitle(processID: application.processIdentifier) else {
            return true
        }
        let titles = response.result.snapshot.panes.flatMap {
            [$0.terminalTitle, $0.terminalTitleStripped].compactMap { $0 }
        }
        let normalizedWindow = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if titles.contains(where: {
            let normalizedTitle = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalizedTitle.isEmpty &&
                (normalizedWindow == normalizedTitle ||
                 normalizedWindow.contains(normalizedTitle) ||
                 normalizedTitle.contains(normalizedWindow))
        }) {
            return true
        }

        // Ghostty currently exposes its shell title, not Herdr's terminal
        // title, so title matching cannot distinguish surfaces reliably.
        // Prefer Herdr while its server is live; ordinary Ghostty resumes
        // native bindings as soon as the server is unavailable.
        return true
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
        if app.isHerdr { return HerdrPreset.bindings }
        if SlackPreset.matches(app.bundleID) { return SlackPreset.bindings }
        if GhosttyPreset.matches(app.bundleID) { return GhosttyPreset.bindings }
        return nil
    }

    public static func name(for app: FocusedApp) -> String? {
        if app.isHerdr { return "Herdr" }
        if SlackPreset.matches(app.bundleID) { return "Slack" }
        if GhosttyPreset.matches(app.bundleID) { return "Ghostty" }
        return nil
    }
}

public struct FocusedApp: Equatable {
    public let bundleID: String
    public let name: String
    public let isHerdr: Bool

    public init(bundleID: String, name: String, isHerdr: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.isHerdr = isHerdr
    }

    static let unknown = FocusedApp(bundleID: "", name: "Unknown app")
}





private struct PersistedConfig: Codable {
    public var global: [String: BindingAction]
    public var apps: [String: [String: BindingAction]]
}

@MainActor
public final class ProfileStore: ObservableObject {
    @Published public private(set) var focusedApp = FocusedApp.unknown
    @Published public private(set) var editingApp = FocusedApp.unknown
    @Published public private(set) var devices: [ConnectedDevice] = []
    @Published public private(set) var status = "Waiting for an Xbox controller"
    @Published public private(set) var accessibilityGranted = CGPreflightPostEventAccess()
    @Published public var editingGlobal = false

    private var global: [PadButton: BindingAction] = [:]
    private var appProfiles: [String: [PadButton: BindingAction]] = [:]
    private let storageURL: URL?

    private static let defaultBindings: [PadButton: BindingAction] = [
        .a: .key(KeyChord(keyCode: 49)),
        .b: .key(KeyChord(keyCode: 53)),
        .x: .none,
        .y: .none,
        .lb: .none,
        .rb: .none,
        .lt: .none,
        .rt: .none,
        .back: .overlay,
        .start: .switchApp,
        .guide: .none,
    ]

    public init(storageURL: URL? = nil, loadFromDisk: Bool = true) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.storageURL = appSupport.appendingPathComponent("Vibestick/config.json")
        }
        global = Self.defaultBindings
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
        if editingApp.bundleID.isEmpty { editingApp = focusedApp }
    }

    public func beginEditingFocusedApp() {
        editingApp = focusedApp
        editingGlobal = false
        announce("Editing \(focusedApp.name)'s app profile")
    }

    public func beginEditing(_ app: FocusedApp) {
        editingApp = app
        editingGlobal = false
    }

    public var appPresetName: String? {
        guard !editingGlobal else { return nil }
        return AppPresetCatalog.name(for: editingApp)
    }

    public func binding(for button: PadButton) -> BindingAction {
        if editingGlobal { return global[button] ?? .none }
        return appProfiles[editingApp.bundleID]?[button]
            ?? AppPresetCatalog.bindings(for: editingApp)?[button]
            ?? global[button]
            ?? .none
    }

    public func action(for button: PadButton, app: FocusedApp) -> BindingAction {
        appProfiles[app.bundleID]?[button]
            ?? AppPresetCatalog.bindings(for: app)?[button]
            ?? global[button]
            ?? .none
    }

    public func isOverride(for button: PadButton) -> Bool {
        !editingGlobal && appProfiles[editingApp.bundleID]?[button] != nil
    }

    public func isAppDefault(for button: PadButton) -> Bool {
        !editingGlobal &&
            !isOverride(for: button) &&
            AppPresetCatalog.bindings(for: editingApp)?[button] != nil
    }


    public func setBinding(_ action: BindingAction, for button: PadButton) {
        if editingGlobal {
            global[button] = action
            announce("Global · \(button.title) → \(action.displayName)")
        } else {
            guard !editingApp.bundleID.isEmpty else {
                announce("No focused app bundle ID; binding was not saved")
                return
            }
            var profile = appProfiles[editingApp.bundleID] ?? [:]
            profile[button] = action
            appProfiles[editingApp.bundleID] = profile
            announce("\(editingApp.name) · \(button.title) → \(action.displayName)")
        }
        save()
    }

    public func resetEditingApp() {
        guard !editingApp.bundleID.isEmpty else { return }
        appProfiles.removeValue(forKey: editingApp.bundleID)
        save()
        announce("Reset \(editingApp.name) to global defaults")
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

    private func load() {
        guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode(PersistedConfig.self, from: data)
            global = Self.decodeBindings(decoded.global, fallback: Self.defaultBindings)
            appProfiles = decoded.apps.mapValues { Self.decodeBindings($0, fallback: [:]) }
            status = "Loaded bindings from \(storageURL.lastPathComponent)"
        } catch {
            status = "Could not load bindings; using defaults (\(error.localizedDescription))"
        }
    }

    private func save() {
        guard let storageURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let config = PersistedConfig(
                global: global.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value },
                apps: appProfiles.reduce(into: [:]) { result, profile in
                    result[profile.key] = profile.value.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value }
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            status = "Could not save bindings (\(error.localizedDescription))"
        }
    }

    private static func decodeBindings(
        _ values: [String: BindingAction],
        fallback: [PadButton: BindingAction]
    ) -> [PadButton: BindingAction] {
        values.reduce(into: fallback) { result, entry in
            if let button = PadButton(rawValue: entry.key) { result[button] = entry.value }
        }
    }
}
