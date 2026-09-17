import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import IOKit.hid
import SwiftUI

// MARK: - Normalized controller model

enum PadButton: String, CaseIterable, Codable, Identifiable, Hashable {
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dpadUp: return "D-pad up"
        case .dpadDown: return "D-pad down"
        case .dpadLeft: return "D-pad left"
        case .dpadRight: return "D-pad right"
        case .guide: return "Guide"
        default: return rawValue.uppercased()
        }
    }

    var shortTitle: String {
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

enum StickAxis: String {
    case leftX
    case leftY
    case rightX
    case rightY
}

enum ControllerInput {
    case button(PadButton, pressed: Bool)
    case trigger(PadButton, value: Double)
    case axis(StickAxis, value: Double)
}

struct ConnectedDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let vendorID: Int
    let productID: Int

    var displayName: String {
        String(format: "%@ · %04X:%04X", name, vendorID, productID)
    }
}

// MARK: - Xbox Series report adapter

/// The Xbox Series adapter mirrors herdr/plugins/gamepad/xbox-series.patch.
/// IOHIDValue removes the report ID; the remaining transport byte means the
/// standard GIP button bitmap starts at byte 3.
enum XboxSeriesDecoder {
    struct DecodedReport {
        let buttons: [(PadButton, Bool)]
        let triggers: [(PadButton, Double)]
        let axes: [(StickAxis, Double)]
    }

    private static let buttonMap: [(mask: UInt16, button: PadButton)] = [
        (1 << 4, .a), (1 << 5, .b), (1 << 6, .x), (1 << 7, .y),
        (1 << 2, .start), (1 << 3, .back),
        (1 << 8, .dpadUp), (1 << 9, .dpadDown),
        (1 << 10, .dpadLeft), (1 << 11, .dpadRight),
        (1 << 12, .lb), (1 << 13, .rb),
        (1 << 14, .l3), (1 << 15, .r3),
    ]

    static func decode(_ bytes: [UInt8], previousButtons: UInt16) -> DecodedReport? {
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

final class ControllerReader {
    private let manager: IOHIDManager
    private let onInput: (ControllerInput) -> Void
    private var started = false
    private var lastXboxButtons: [ObjectIdentifier: UInt16] = [:]
    private var lastXboxTriggerPressed: [ObjectIdentifier: (Bool, Bool)] = [:]
    private var lastAxis: [String: Double] = [:]

    init(onInput: @escaping (ControllerInput) -> Void) {
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

    func start() -> Bool {
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

    func stop() {
        guard started else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        started = false
        lastXboxButtons.removeAll()
        lastXboxTriggerPressed.removeAll()
        lastAxis.removeAll()
    }

    func connectedDevices() -> [ConnectedDevice] {
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

struct KeyModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt8

    static let shift = KeyModifiers(rawValue: 1 << 0)
    static let control = KeyModifiers(rawValue: 1 << 1)
    static let option = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)
    static let function = KeyModifiers(rawValue: 1 << 4)

    init(rawValue: UInt8) {
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

    var displayPrefix: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        if contains(.function) { result += "fn " }
        return result
    }

    var cgFlags: CGEventFlags {
        var result: CGEventFlags = []
        if contains(.shift) { result.insert(.maskShift) }
        if contains(.control) { result.insert(.maskControl) }
        if contains(.option) { result.insert(.maskAlternate) }
        if contains(.command) { result.insert(.maskCommand) }
        if contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }
}

struct KeyChord: Codable, Hashable {
    let keyCode: UInt16
    let modifiers: KeyModifiers

    init(keyCode: UInt16, modifiers: KeyModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: KeyModifiers(event: event))
    }

    var displayName: String {
        modifiers.displayPrefix + KeyNames.name(for: keyCode)
    }
}

enum KeyNames {
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

    static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? String(format: "Key 0x%02X", keyCode)
    }
}

enum BindingAction: Equatable, Codable {
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

    var displayName: String {
        switch self {
        case .none: return "Unbound"
        case .overlay: return "Overlay"
        case .switchApp: return "Switch app"
        case let .key(chord): return chord.displayName
        case let .sequence(chords): return chords.map(\.displayName).joined(separator: " ")
        }
    }
}

enum HerdrPreset {
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

enum SlackPreset {
    static let bundleIDs = ["com.tinyspeck.slackmacgap"]

    static func matches(_ bundleID: String) -> Bool {
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

enum GhosttyPreset {
    static func matches(_ bundleID: String) -> Bool {
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

    static func focusedSurfaceIsHerdr() -> Bool {
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

enum AppPresetCatalog {
    static func bindings(for app: FocusedApp) -> [PadButton: BindingAction]? {
        if app.isHerdr { return HerdrPreset.bindings }
        if SlackPreset.matches(app.bundleID) { return SlackPreset.bindings }
        if GhosttyPreset.matches(app.bundleID) { return GhosttyPreset.bindings }
        return nil
    }

    static func name(for app: FocusedApp) -> String? {
        if app.isHerdr { return "Herdr" }
        if SlackPreset.matches(app.bundleID) { return "Slack" }
        if GhosttyPreset.matches(app.bundleID) { return "Ghostty" }
        return nil
    }
}

struct FocusedApp: Equatable {
    let bundleID: String
    let name: String
    let isHerdr: Bool

    init(bundleID: String, name: String, isHerdr: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.isHerdr = isHerdr
    }

    static let unknown = FocusedApp(bundleID: "", name: "Unknown app")
}





private struct PersistedConfig: Codable {
    var global: [String: BindingAction]
    var apps: [String: [String: BindingAction]]
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var focusedApp = FocusedApp.unknown
    @Published private(set) var editingApp = FocusedApp.unknown
    @Published private(set) var devices: [ConnectedDevice] = []
    @Published private(set) var status = "Waiting for an Xbox controller"
    @Published private(set) var accessibilityGranted = CGPreflightPostEventAccess()
    @Published var editingGlobal = false

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

    init(storageURL: URL? = nil, loadFromDisk: Bool = true) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.storageURL = appSupport.appendingPathComponent("Vibestick/config.json")
        }
        global = Self.defaultBindings
        if loadFromDisk { load() }
    }
    func refreshFocus(excluding bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let applicationBundleID = application.bundleIdentifier,
              applicationBundleID != bundleID
        else { return }
        let herdr = HerdrSurfaceDetector.focusedSurfaceIsHerdr()
        focusedApp = FocusedApp(
            bundleID: applicationBundleID,
            name: herdr ? "\(application.localizedName ?? applicationBundleID) · Herdr" : (application.localizedName ?? applicationBundleID),
            isHerdr: herdr
        )
        if editingApp.bundleID.isEmpty { editingApp = focusedApp }
    }

    func beginEditingFocusedApp() {
        editingApp = focusedApp
        editingGlobal = false
        announce("Editing \(focusedApp.name)'s app profile")
    }

    func beginEditing(_ app: FocusedApp) {
        editingApp = app
        editingGlobal = false
    }

    var appPresetName: String? {
        guard !editingGlobal else { return nil }
        return AppPresetCatalog.name(for: editingApp)
    }

    func binding(for button: PadButton) -> BindingAction {
        if editingGlobal { return global[button] ?? .none }
        return appProfiles[editingApp.bundleID]?[button]
            ?? AppPresetCatalog.bindings(for: editingApp)?[button]
            ?? global[button]
            ?? .none
    }

    func action(for button: PadButton, app: FocusedApp) -> BindingAction {
        appProfiles[app.bundleID]?[button]
            ?? AppPresetCatalog.bindings(for: app)?[button]
            ?? global[button]
            ?? .none
    }

    func isOverride(for button: PadButton) -> Bool {
        !editingGlobal && appProfiles[editingApp.bundleID]?[button] != nil
    }

    func isAppDefault(for button: PadButton) -> Bool {
        !editingGlobal &&
            !isOverride(for: button) &&
            AppPresetCatalog.bindings(for: editingApp)?[button] != nil
    }


    func setBinding(_ action: BindingAction, for button: PadButton) {
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

    func resetEditingApp() {
        guard !editingApp.bundleID.isEmpty else { return }
        appProfiles.removeValue(forKey: editingApp.bundleID)
        save()
        announce("Reset \(editingApp.name) to global defaults")
    }

    func setDevices(_ devices: [ConnectedDevice]) {
        self.devices = devices
    }

    func setAccessibility(_ granted: Bool = CGPreflightPostEventAccess()) {
        accessibilityGranted = granted
    }

    func announce(_ message: String) {
        status = message
    }

    func describe(_ app: FocusedApp) -> String {
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

// MARK: - Output actions

@MainActor
final class MacActions {
    private let state: ProfileStore

    init(state: ProfileStore) {
        self.state = state
    }

    func perform(_ action: BindingAction, from button: PadButton, target: FocusedApp) {
        switch action {
        case .none:
            state.announce("\(button.title) is unbound for \(target.name)")
        case .overlay:
            state.announce("Overlay is controlled by the app")
        case .switchApp:
            switchToNextApp()
        case let .key(chord):
            postKey(chord, target: target)
        case let .sequence(chords):
            for chord in chords { postKey(chord, target: target, announce: false) }
            if let last = chords.last {
                state.announce("Sent \(last.displayName) sequence to \(target.name)")
            }
        }
    }

    private func postKey(_ chord: KeyChord, target: FocusedApp, announce: Bool = true) {

        state.setAccessibility()
        guard state.accessibilityGranted else {
            state.announce("Accessibility is required; no key sent")
            return
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(chord.keyCode),
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(chord.keyCode),
                keyDown: false
              )
        else {
            state.announce("Could not create \(chord.displayName) keyboard event")
            return
        }
        down.flags = chord.modifiers.cgFlags
        up.flags = chord.modifiers.cgFlags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        if announce { state.announce("Sent \(chord.displayName) to \(target.name)") }
    }

    private func switchToNextApp() {
        let currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let candidates = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular &&
                    !$0.isTerminated &&
                    $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        guard !candidates.isEmpty else {
            state.announce("No other regular apps are running")
            return
        }

        let currentIndex = candidates.firstIndex { $0.bundleIdentifier == currentBundleID } ?? -1
        let next = candidates[(currentIndex + 1) % candidates.count]
        if next.activate(options: [.activateAllWindows]) {
            state.announce("Switched to \(next.localizedName ?? "app")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.state.refreshFocus()
            }
        } else {
            state.announce("macOS refused activation for \(next.localizedName ?? "app")")
        }
    }
}

// MARK: - Overlay state and key capture
@MainActor
final class OverlayUIState: ObservableObject {
    @Published var captureButton: PadButton?
}


@MainActor
final class ControllerVisualState: ObservableObject {
    @Published private(set) var pressed: Set<PadButton> = []
    @Published private(set) var triggers: [PadButton: Double] = [:]
    @Published private(set) var axes: [StickAxis: Double] = [:]

    func apply(_ input: ControllerInput) {
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
        objectWillChange.send()
    }
    func clear() {
        pressed.removeAll()
        triggers.removeAll()
        axes.removeAll()
        objectWillChange.send()
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct KeyCaptureView: NSViewRepresentable {
    let onCapture: (KeyChord) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        KeyCaptureNSView(onCapture: onCapture)
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

final class KeyCaptureNSView: NSView {
    var onCapture: (KeyChord) -> Void

    init(onCapture: @escaping (KeyChord) -> Void) {
        self.onCapture = onCapture
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        layer?.cornerRadius = 10
    }

    required init?(coder: NSCoder) {
        fatalError("KeyCaptureNSView does not support NSCoder")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        onCapture(KeyChord(event: event))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onCapture(KeyChord(event: event))
        return true
    }
}

@MainActor
final class OverlayController {
    private let state: ProfileStore
    private let visual: ControllerVisualState
    private let uiState = OverlayUIState()
    private var panel: OverlayPanel?
    init(state: ProfileStore, visual: ControllerVisualState) {
        self.state = state
        self.visual = visual
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        state.beginEditingFocusedApp()
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(
            rootView: OverlayView(
                state: state,
                visual: visual,
                uiState: uiState,
                close: { [weak panel] in panel?.orderOut(nil) }
            )
        )
        return panel
    }
}

// MARK: - Overlay UI

struct BindingChip: View {
    let button: PadButton
    let action: BindingAction
    let inherited: Bool
    let appDefault: Bool
    let pressed: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text(button.shortTitle)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(pressed ? .white : .primary)
                Text(action.displayName)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(actionColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 68, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(pressed ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: inherited ? 1 : 1.5)
            )
        }
        .buttonStyle(.plain)
        .help("Remap \(button.title)")
    }

    private var borderColor: Color {
        if !inherited { return Color.accentColor.opacity(0.9) }
        return appDefault ? Color.orange.opacity(0.65) : Color.white.opacity(0.13)
    }

    private var actionColor: Color {
        switch action {
        case .none: return .secondary
        case .overlay, .switchApp: return .orange
        case .key, .sequence: return inherited ? (appDefault ? .orange : .purple) : .mint
        }
    }
}

struct ControllerDiagram: View {
    let pressed: Set<PadButton>
    let axes: [StickAxis: Double]
    let triggers: [PadButton: Double]

    var body: some View {
        ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.17, green: 0.20, blue: 0.26), Color(red: 0.08, green: 0.10, blue: 0.14)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 226, height: 126)
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .rotationEffect(.degrees(0))

            HStack(spacing: 50) {
                stick(.leftX, .leftY)
                stick(.rightX, .rightY)
            }
            .offset(y: 18)

            DPadGraphic(pressed: pressed)
                .offset(x: -67, y: 14)

            FaceButtonsGraphic(pressed: pressed)
                .offset(x: 68, y: 7)

            HStack(spacing: 28) {
                tinyButton("BACK", active: pressed.contains(.back))
                tinyButton("START", active: pressed.contains(.start))
            }
            .offset(y: -39)

            Text("PADPILOT")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.35))
                .offset(y: -15)
        }
        .frame(width: 250, height: 150)
    }

    private func stick(_ xAxis: StickAxis, _ yAxis: StickAxis) -> some View {
        let x = axes[xAxis] ?? 0
        let y = axes[yAxis] ?? 0
        return ZStack {
            Circle().fill(Color.black.opacity(0.35)).frame(width: 31, height: 31)
            Circle().fill(Color.white.opacity(0.12)).frame(width: 23, height: 23)
            Circle().fill(Color.accentColor.opacity(0.7)).frame(width: 7, height: 7)
                .offset(x: x * 6, y: y * 6)
        }
    }

    private func tinyButton(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 5, weight: .bold, design: .rounded))
            .foregroundStyle(active ? .white : .white.opacity(0.4))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(active ? Color.accentColor : Color.white.opacity(0.08)))
    }
}

struct DPadGraphic: View {
    let pressed: Set<PadButton>

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(0.42))
                .frame(width: 13, height: 43)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(0.42))
                .frame(width: 43, height: 13)
            ForEach([PadButton.dpadUp, .dpadDown, .dpadLeft, .dpadRight], id: \.self) { button in
                Circle()
                    .fill(pressed.contains(button) ? Color.accentColor : Color.white.opacity(0.12))
                    .frame(width: 6, height: 6)
                    .offset(offset(for: button))
            }
        }
    }

    private func offset(for button: PadButton) -> CGSize {
        switch button {
        case .dpadUp: return CGSize(width: 0, height: -13)
        case .dpadDown: return CGSize(width: 0, height: 13)
        case .dpadLeft: return CGSize(width: -13, height: 0)
        case .dpadRight: return CGSize(width: 13, height: 0)
        default: return .zero
        }
    }
}

struct FaceButtonsGraphic: View {
    let pressed: Set<PadButton>

    var body: some View {
        ZStack {
            face("Y", .y, x: 0, y: -17)
            face("X", .x, x: -17, y: 0)
            face("B", .b, x: 17, y: 0)
            face("A", .a, x: 0, y: 17)
        }
    }

    private func face(_ title: String, _ button: PadButton, x: CGFloat, y: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(pressed.contains(button) ? .white : .white.opacity(0.65))
            .frame(width: 22, height: 22)
            .background(Circle().fill(pressed.contains(button) ? Color.accentColor : Color.white.opacity(0.1)))
            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
            .offset(x: x, y: y)
    }
}

struct OverlayView: View {
    @ObservedObject var state: ProfileStore
    @ObservedObject var visual: ControllerVisualState
    @ObservedObject var uiState: OverlayUIState
    let close: () -> Void

    private let topButtons: [PadButton] = [.back, .start, .guide]
    private let leftButtons: [PadButton] = [.lb, .lt, .l3]
    private let rightButtons: [PadButton] = [.rb, .rt, .r3]
    private let dpadButtons: [PadButton] = [.dpadUp, .dpadLeft, .dpadRight, .dpadDown]
    private let faceButtons: [PadButton] = [.y, .x, .b, .a]

    var body: some View {
        VStack(spacing: 0) {
            header
            scopeBar
            controllerArea
            footer
        }
        .padding(16)
        .frame(width: 520, height: 560)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
        .preferredColorScheme(.dark)
        .sheet(item: $uiState.captureButton) { button in
            KeyCaptureSheet(
                button: button,
                current: state.binding(for: button),
                onCapture: { chord in
                    state.setBinding(.key(chord), for: button)
                    uiState.captureButton = nil
                },
                onClear: {
                    state.setBinding(.none, for: button)
                    uiState.captureButton = nil
                },
                close: { uiState.captureButton = nil }
            )
        }
        .onExitCommand(perform: close)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vibestick")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("controller bindings")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(state.devices.first?.name ?? "No controller")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(state.accessibilityGranted ? "Keyboard output ready" : "Keyboard output needs Access")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(state.accessibilityGranted ? .mint : .orange)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Close overlay")
        }
        .padding(.bottom, 10)
    }

    private var scopeBar: some View {
        VStack(spacing: 6) {
            Picker("Profile", selection: $state.editingGlobal) {
                Text("Focused app").tag(false)
                Text("Global defaults").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: state.editingGlobal) { _, isGlobal in
                state.announce(isGlobal ? "Editing global defaults" : "Editing \(state.editingApp.name)'s profile")
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(state.editingGlobal ? Color.purple : Color.mint)
                    .frame(width: 6, height: 6)
                Text(state.editingGlobal ? "Fallback for every app" : state.describe(state.editingApp))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !state.editingGlobal {
                    Button("Reset app") { state.resetEditingApp() }
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .buttonStyle(.borderless)
                }
            }
            if let presetName = state.appPresetName, !state.editingGlobal {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                    Text("\(presetName) defaults active · edits save as app overrides")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.9))
                    Spacer()
                }
                if presetName == "Slack" {
                    Text("Huddle toggle ⌘⇧H · Quick Switcher ⌘K")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private var controllerArea: some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                ForEach(topButtons) { button in
                    chip(button)
                }
            }
            HStack(spacing: 6) {
                VStack(spacing: 5) {
                    ForEach(leftButtons) { button in
                        chip(button)
                    }
                    dpadGrid
                }
                ControllerDiagram(
                    pressed: visual.pressed,
                    axes: visual.axes,
                    triggers: visual.triggers
                )
                VStack(spacing: 5) {
                    ForEach(rightButtons) { button in
                        chip(button)
                    }
                    ForEach(faceButtons) { button in
                        chip(button)
                    }
                }
            }
            Text("Click any binding box to capture a key or chord")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxHeight: .infinity)
    }

    private var dpadGrid: some View {
        VStack(spacing: 2) {
            chip(.dpadUp)
            HStack(spacing: 2) {
                chip(.dpadLeft)
                chip(.dpadRight)
            }
            chip(.dpadDown)
        }
    }

    private var footer: some View {
        VStack(spacing: 7) {
            Divider().overlay(Color.white.opacity(0.1))
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(state.devices.isEmpty ? Color.orange : Color.mint)
                    .frame(width: 7, height: 7)
                Text(state.devices.isEmpty ? "Waiting for Xbox HID" : "Xbox HID connected")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                Spacer()
                Text(state.status)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Text("Back opens this overlay · Start switches apps")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if !state.accessibilityGranted {
                    Button("Request Access") {
                        CGRequestPostEventAccess()
                        state.setAccessibility()
                    }
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.top, 8)
    }

    private func chip(_ button: PadButton) -> some View {
        BindingChip(
            button: button,
            action: state.binding(for: button),
            inherited: !state.isOverride(for: button),
            appDefault: state.isAppDefault(for: button),
            pressed: visual.pressed.contains(button),
            onTap: { uiState.captureButton = button }
        )
    }
}

struct KeyCaptureSheet: View {
    let button: PadButton
    let current: BindingAction
    let onCapture: (KeyChord) -> Void
    let onClear: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 15) {
            VStack(spacing: 3) {
                Text("Remap \(button.title)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Current: \(current.displayName)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            KeyCaptureView(onCapture: onCapture)
                .frame(height: 64)
                .overlay(
                    Text("Press any key or modifier chord")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                )
            HStack {
                Button("Clear binding", action: onClear)
                    .buttonStyle(.borderless)
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 320, height: 220)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Application coordinator

@MainActor
final class ApplicationCoordinator: NSObject, NSApplicationDelegate {
    let state = ProfileStore()
    let visual = ControllerVisualState()
    private var reader: ControllerReader!
    private var actions: MacActions!
    private var overlay: OverlayController!
    private var statusItem: NSStatusItem!
    private var outputMenuItem: NSMenuItem?
    private var outputEnabled = false
    private var workspaceObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var held: Set<PadButton> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Vibestick started")
        actions = MacActions(state: state)
        overlay = OverlayController(state: state, visual: visual)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌘ Pad"
        statusItem.menu = makeMenu()

        state.refreshFocus()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.state.refreshFocus() }
        }

        reader = ControllerReader { [weak self] input in
            Task { @MainActor in self?.handle(input) }
        }
        if reader.start() {
            refreshDevices()
            state.announce(state.devices.isEmpty ? "Observe-only · no controller connected" : "Observe-only · output is off")
        } else {
            state.announce("Could not open Xbox HID monitor")
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
                self?.state.refreshFocus()
            }
        }
        let controllerDescription = state.devices.isEmpty
            ? "none detected"
            : state.devices.map(\.displayName).joined(separator: ", ")
        print("Controller: \(controllerDescription)")
        print("Focused app: \(state.describe(state.focusedApp))")
        print("Status: \(state.status)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseHeld()
        refreshTimer?.invalidate()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        reader?.stop()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open bindings overlay", action: #selector(openOverlay), keyEquivalent: "")
        let outputItem = menu.addItem(withTitle: "Enable output", action: #selector(toggleOutput), keyEquivalent: "")
        outputItem.state = .off
        outputMenuItem = outputItem
        menu.addItem(withTitle: "Request Accessibility", action: #selector(requestAccessibility), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Controller status", action: #selector(showStatus), keyEquivalent: "")
        menu.addItem(withTitle: "Reset focused app profile", action: #selector(resetFocusedProfile), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Vibestick", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func openOverlay() {
        overlay.toggle()
    }

    @objc private func toggleOutput() {
        outputEnabled.toggle()
        outputMenuItem?.state = outputEnabled ? .on : .off
        outputMenuItem?.title = outputEnabled ? "Disable output" : "Enable output"
        if outputEnabled {
            state.announce(state.accessibilityGranted ? "Output enabled · mappings are live" : "Output enabled · keyboard actions need Accessibility")
        } else {
            releaseHeld()
            state.announce("Output disabled · observe-only")
        }
    }

    @objc private func requestAccessibility() {
        CGRequestPostEventAccess()
        state.setAccessibility()
        state.announce(state.accessibilityGranted ? "Accessibility enabled" : "Accessibility still required")
    }

    @objc private func showStatus() {
        let devices = reader?.connectedDevices() ?? []
        let deviceText = devices.isEmpty ? "No real Xbox HID gamepad found." : devices.map(\.displayName).joined(separator: "\n")
        let permission = state.accessibilityGranted ? "Keyboard output: allowed" : "Keyboard output: Accessibility required"
        let alert = NSAlert()
        alert.messageText = "Vibestick status"
        alert.informativeText = "\(deviceText)\n\n\(permission)\nOutput: \(outputEnabled ? "enabled" : "off")\nOwner: standalone Vibestick\n\nStop Herdr's gamepad plugin before enabling this listener."
        alert.runModal()
    }

    @objc private func resetFocusedProfile() {
        state.beginEditingFocusedApp()
        state.resetEditingApp()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func refreshDevices() {
        state.setDevices(reader?.connectedDevices() ?? [])
    }

    private func handle(_ input: ControllerInput) {
        visual.apply(input)
        switch input {
        case let .button(button, pressed):
            handleButton(button, pressed: pressed)
        case let .trigger(button, value):
            handleButton(button, pressed: value >= 0.5)
        case .axis:
            break
        }
    }

    private func handleButton(_ button: PadButton, pressed: Bool) {
        guard pressed else {
            held.remove(button)
            return
        }
        guard !held.contains(button) else { return }
        held.insert(button)

        // The editor owns focus while open. Back remains a reliable close path
        // even if the user remapped its action.
        if overlay.isVisible {
            if button == .back { overlay.close() }
            return
        }

        let action = state.action(for: button, app: state.focusedApp)
        if action == .overlay {
            overlay.open()
            return
        }
        guard outputEnabled else {
            state.announce("Output is off · enable it from the menu")
            return
        }
        actions.perform(action, from: button, target: state.focusedApp)
    }

    private func releaseHeld() {
        held.removeAll()
        visual.clear()
    }
}

// MARK: - Deterministic checks

@MainActor
private func runSelfCheck() {
    var bytes = Array(repeating: UInt8(0), count: 17)
    bytes[3] = 0x14 // A + Start, matching the patch's bitmap positions.
    bytes[5] = 0xFF
    bytes[6] = 0x03 // 1023 / 1023 = 1.0 left trigger.
    bytes[9] = 0x00
    bytes[10] = 0x80 // signed -32768 left X.
    guard let report = XboxSeriesDecoder.decode(bytes, previousButtons: 0),
          report.buttons.contains(where: { $0.0 == .a && $0.1 }),
          report.buttons.contains(where: { $0.0 == .start && $0.1 }),
          report.triggers.contains(where: { $0.0 == .lt && abs($0.1 - 1.0) < 0.001 }),
          report.axes.contains(where: { $0.0 == .leftX && abs($0.1 + 1.0) < 0.001 })
    else {
        print("Self-check failed: Xbox Series report adapter")
        exit(1)
    }

    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Vibestick-self-check-\(UUID().uuidString)")
        .appendingPathComponent("config.json")
    let state = ProfileStore(storageURL: tempURL, loadFromDisk: false)
    let target = FocusedApp(bundleID: "com.example.target", name: "Target app")
    let other = FocusedApp(bundleID: "com.example.other", name: "Other")
    state.beginEditing(target)
    let inherited = state.action(for: .a, app: target)
    state.setBinding(.key(KeyChord(keyCode: 36, modifiers: [.command, .shift])), for: .a)
    let overridden = state.action(for: .a, app: target)
    let fallback = state.action(for: .a, app: other)
    let reloaded = ProfileStore(storageURL: tempURL, loadFromDisk: true)
    reloaded.beginEditing(target)
    let persisted = reloaded.action(for: .a, app: target)
    let slack = FocusedApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    reloaded.beginEditing(slack)
    let huddle = reloaded.action(for: .a, app: slack)
    let quickSwitcher = reloaded.action(for: .x, app: slack)
    let ghostty = FocusedApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty")
    reloaded.beginEditing(ghostty)
    let newTab = reloaded.action(for: .a, app: ghostty)
    let closeSurface = reloaded.action(for: .b, app: ghostty)
    let herdr = FocusedApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty · Herdr", isHerdr: true)
    reloaded.beginEditing(herdr)
    let herdrZoom = reloaded.action(for: .a, app: herdr)
    let herdrNextTab = reloaded.action(for: .rb, app: herdr)

    guard inherited == .key(KeyChord(keyCode: 49)),
          overridden == .key(KeyChord(keyCode: 36, modifiers: [.command, .shift])),
          fallback == .key(KeyChord(keyCode: 49)),
          persisted == overridden,
          huddle == .key(KeyChord(keyCode: 4, modifiers: [.command, .shift])),
          quickSwitcher == .key(KeyChord(keyCode: 40, modifiers: [.command])),
          newTab == .key(KeyChord(keyCode: 17, modifiers: [.command])),
          closeSurface == .key(KeyChord(keyCode: 13, modifiers: [.command])),
          herdrZoom == .sequence([KeyChord(keyCode: 11, modifiers: [.control]), KeyChord(keyCode: 6)]),
          herdrNextTab == .sequence([KeyChord(keyCode: 11, modifiers: [.control]), KeyChord(keyCode: 45)])
    else {
        print("Self-check failed: app-aware profile persistence")
        exit(1)
    }
    try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    print("Self-check passed: Xbox GIP decoding and app-aware bindings persist.")
}

@main
struct VibestickMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("--status") {
            let reader = ControllerReader { _ in }
            _ = reader.start()
            let devices = reader.connectedDevices()
            reader.stop()
            print(devices.isEmpty ? "No real Xbox HID gamepad found." : devices.map(\.displayName).joined(separator: "\n"))
            return
        }
        if arguments.contains("--self-check") {
            runSelfCheck()
            return
        }

        let application = NSApplication.shared
        let coordinator = ApplicationCoordinator()
        application.delegate = coordinator
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
