import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import IOKit.hid
import SwiftUI
import VibestickCore

// MARK: - Output actions

@MainActor
final class MacActions: OutputAction {
    private let state: ProfileStore
    private let appActivated: () -> Void

    init(state: ProfileStore, appActivated: @escaping () -> Void) {
        self.state = state
        self.appActivated = appActivated
    }

    func send(_ action: BindingAction, from button: PadButton, to app: FocusedApp) {
        perform(action, from: button, target: app)
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
            appActivated()
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
    var isCapturing: Bool { uiState.captureButton != nil }

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
            panel.orderFrontRegardless()
            return
        }
        panel.center()
        panel.orderFrontRegardless()
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
            if let configurationNotice = state.configurationNotice {
                Text(configurationNotice)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text("Hold L3 for app wheel · A opens · B closes")
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

private enum AccessibilityOnboarding {
    private static let requestRecordedKey =
        "Vibestick.hasRequestedAccessibility"

    static func requestIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: requestRecordedKey) else { return }
        defaults.set(true, forKey: requestRecordedKey)
        CGRequestPostEventAccess()
    }
}

@MainActor
final class ApplicationCoordinator: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = ProfileStore()
    let visual = ControllerVisualState()
    private var reader: ControllerReader!
    private var actions: MacActions!
    private var overlay: OverlayController!
    private var appWheel: AppWheelController!
    private var statusItem: NSStatusItem!
    private var outputMenuItem: NSMenuItem?
    private var targetControllerStatusMenuItem: NSMenuItem?
    private var accessibilityStatusMenuItem: NSMenuItem?
    private var outputStatusMenuItem: NSMenuItem?
    private var appContextStatusMenuItem: NSMenuItem?
    private var workspaceObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var appWheelHoldTimer: Timer?
    private var appWheelSessionActive = false
    private var commandRouter = CommandRouter()
    private var outputLifecycle = OutputLifecycle()
    private var diagnostics: [ControllerDiagnosticRecord] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Vibestick started")
        actions = MacActions(
            state: state,
            appActivated: { [weak self] in self?.scheduleFocusRefresh() }
        )
        overlay = OverlayController(state: state, visual: visual)
        appWheel = AppWheelController(
            state: state,
            appActivated: { [weak self] in self?.scheduleFocusRefresh() }
        )
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌘ Pad"
        statusItem.menu = makeMenu()

        AccessibilityOnboarding.requestIfNeeded()
        refreshAccessibility()
        refreshFocus()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFocus() }
        }

        reader = ControllerReader(
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            },
            onDiagnostic: { [weak self] record in
                Task { @MainActor in self?.recordDiagnostic(record) }
            }
        )
        if reader.start() {
            refreshDevices()
            state.announce(activeOutputStatusMessage)
        } else {
            state.announce("Could not open Xbox HID monitor")
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
                self?.refreshAccessibility()
                self?.refreshFocus()
            }
        }
        refreshMenuStatus()
        let controllerDescription = state.devices.isEmpty
            ? "none detected"
            : state.devices.map(\.displayName).joined(separator: ", ")
        print("Controller: \(controllerDescription)")
        print("Focused app: \(state.describe(state.focusedApp))")
        print("Status: \(state.status)")
        if let configurationNotice = state.configurationNotice {
            print("Configuration: \(configurationNotice)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        applyLifecycle(.shutdown, clearVisualization: true)
        refreshTimer?.invalidate()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        reader?.stop()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open bindings overlay", action: #selector(openOverlay), keyEquivalent: "")
        menu.addItem(withTitle: "Toggle app wheel", action: #selector(toggleAppWheel), keyEquivalent: "")
        let outputItem = menu.addItem(withTitle: "Pause output", action: #selector(toggleOutput), keyEquivalent: "")
        outputItem.state = .off
        outputMenuItem = outputItem
        menu.addItem(withTitle: "Request Accessibility", action: #selector(requestAccessibility), keyEquivalent: "")
        menu.addItem(.separator())
        targetControllerStatusMenuItem = addStatusItem("Target controller: checking", to: menu)
        accessibilityStatusMenuItem = addStatusItem("Accessibility: checking", to: menu)
        outputStatusMenuItem = addStatusItem("Output: active", to: menu)
        appContextStatusMenuItem = addStatusItem("App context: checking", to: menu)
        menu.addItem(withTitle: "Show diagnostics", action: #selector(showStatus), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reset focused app profile", action: #selector(resetFocusedProfile), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Vibestick", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshAccessibility()
        refreshFocus()
        refreshMenuStatus()
    }

    private func addStatusItem(_ title: String, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return item
    }

    @objc private func openOverlay() {
        overlay.toggle()
    }

    @objc private func toggleAppWheel() {
        if appWheelSessionActive || appWheel.isVisible {
            appWheel.cancel()
            endAppWheelSessionIfIdle()
        } else {
            _ = beginAppWheelSession()
        }
    }

    @objc private func toggleOutput() {
        let pausing = !outputLifecycle.isPaused
        applyLifecycle(.setPaused(pausing))
        if pausing {
            state.announce("Emergency pause active · system controls remain available")
        } else {
            state.announce(activeOutputStatusMessage)
        }
    }

    @objc private func requestAccessibility() {
        CGRequestPostEventAccess()
        refreshAccessibility()
        state.announce(state.accessibilityGranted ? "Accessibility enabled" : "Accessibility still required")
    }

    @objc private func showStatus() {
        let devices = reader?.connectedDevices() ?? []
        let deviceText = devices.isEmpty
            ? "Target controller \(TargetController.identifier) not found."
            : devices.map(\.displayName).joined(separator: "\n")
        let permission = state.accessibilityGranted ? "Keyboard output: allowed" : "Keyboard output: Accessibility required"
        let configuration = state.configurationNotice.map { "\nConfiguration: \($0)" } ?? ""
        let trace = diagnostics.suffix(16).map(\.description).joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Vibestick status"
        alert.informativeText = """
        \(deviceText)

        \(reader.diagnosticSummary)

        \(permission)
        Output: \(outputLifecycle.isPaused ? "emergency pause" : "active")
        App context: \(state.describe(state.focusedApp))
        App wheel: always active · hold L3
        Owner: standalone Vibestick\(configuration)

        Recent controller events:
        \(trace.isEmpty ? "No events recorded." : trace)

        Stop Herdr's gamepad plugin before enabling this listener.
        """
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
        let devices = reader?.connectedDevices() ?? []
        let wasConnected = outputLifecycle.targetControllerConnected
        let isConnected = !devices.isEmpty
        state.setDevices(devices)
        applyLifecycle(
            .setTargetControllerConnected(isConnected),
            clearVisualization: wasConnected && !isConnected
        )
        if wasConnected && !isConnected {
            state.announce("Controller disconnected")
        } else if !wasConnected && isConnected {
            state.announce(
                outputLifecycle.isPaused
                    ? "Target controller connected · emergency pause remains active"
                    : "Target controller connected · output active"
            )
        }
    }

    private func recordDiagnostic(_ record: ControllerDiagnosticRecord) {
        diagnostics.append(record)
        if diagnostics.count > 100 {
            diagnostics.removeFirst(diagnostics.count - 100)
        }
    }

    private func handle(_ event: ControllerEvent) {
        switch event {
        case .connected, .disconnected:
            refreshDevices()
        case let .input(input):
            handle(input)
        }
    }

    private func handle(_ input: ControllerInput) {
        // Reclassify before tracking every fresh input so a context change
        // cleans up the old context before even a system gesture is accepted.
        refreshFocus()
        visual.apply(input)
        switch input {
        case let .button(button, pressed):
            handleButton(button, pressed: pressed)
        case let .trigger(button, value):
            handleTrigger(input, button: button, value: value)
        case .axis:
            route(input)
        }
    }

    private func handleButton(_ button: PadButton, pressed: Bool) {
        guard outputLifecycle.setHeld(button, pressed: pressed) else { return }
        if !pressed {
            if button == .l3 {
                appWheelHoldTimer?.invalidate()
                appWheelHoldTimer = nil
            }
        }

        let input = ControllerInput.button(button, pressed: pressed)
        let routed = route(input)
        if pressed,
           button == .l3,
           case .systemGesture(_, binding: nil, action: nil) = routed {
            beginAppWheelHold()
        }
        if !pressed {
            endAppWheelSessionIfIdle()
        }
    }

    private func handleTrigger(
        _ input: ControllerInput,
        button: PadButton,
        value: Double
    ) {
        let pressed = value >= 0.5
        outputLifecycle.setHeld(button, pressed: pressed)
        route(input)
        if !pressed {
            endAppWheelSessionIfIdle()
        }
    }

    private func beginAppWheelHold() {
        appWheelHoldTimer?.invalidate()
        appWheelHoldTimer = Timer.scheduledTimer(
            withTimeInterval: CommandRouter.longL3Duration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.outputLifecycle.isHeld(.l3) else { return }
                self.appWheelHoldTimer = nil
                guard let route = self.commandRouter.resolveLongL3(
                    context: self.routingContext,
                    profile: self.state
                ) else { return }
                self.handle(route)
            }
        }
    }

    @discardableResult
    private func beginAppWheelSession() -> Bool {
        guard appWheel.open() else { return false }
        appWheelSessionActive = true
        appWheel.updateSelection(
            x: visual.axes[.leftX] ?? 0,
            y: visual.axes[.leftY] ?? 0
        )
        return true
    }

    private func endAppWheelSessionIfIdle() {
        guard !appWheel.isVisible, !outputLifecycle.hasHeldControls else { return }
        appWheelSessionActive = false
    }

    @discardableResult
    private func route(_ input: ControllerInput) -> InputRoute {
        let context = routingContext
        let route = commandRouter.route(
            input,
            context: context,
            profile: state,
            app: state.focusedApp
        )
        handle(route)
        return route
    }

    private var routingContext: InputRoutingContext {
        InputRoutingContext(
            captureActive: overlay.isCapturing,
            appWheelActive: appWheelSessionActive || appWheel.isVisible,
            herdrLayerActive: false
        )
    }

    private func handle(_ route: InputRoute) {
        guard outputLifecycle.allows(route) else { return }

        switch route {
        case .capture, .herdrLayer:
            return
        case let .appWheel(input):
            handleAppWheelInput(input)
        case let .systemGesture(input, _, action),
             let .appBinding(input, action):
            guard let action else { return }
            perform(action, from: input)
        }
    }

    private func handleAppWheelInput(_ input: ControllerInput) {
        switch input {
        case let .button(button, pressed: true):
            if button == .a {
                appWheel.confirmSelection()
            } else if button == .b {
                appWheel.cancel()
            }
        case let .axis(axis, _):
            guard axis == .leftX || axis == .leftY else { return }
            appWheel.updateSelection(
                x: visual.axes[.leftX] ?? 0,
                y: visual.axes[.leftY] ?? 0
            )
        case .button, .trigger:
            return
        }
    }

    private func perform(_ action: BindingAction, from input: ControllerInput) {
        let button: PadButton
        switch input {
        case let .button(source, _), let .trigger(source, _):
            button = source
        case .axis:
            return
        }
        switch action {
        case .none:
            return
        case .overlay:
            overlay.toggle()
        case .switchApp:
            _ = beginAppWheelSession()
        case .key, .sequence:
            actions.perform(action, from: button, target: state.focusedApp)
        }
    }

    private func refreshFocus() {
        state.refreshFocus()
        applyLifecycle(.appContextChanged(state.focusedApp))
    }

    private func scheduleFocusRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.refreshFocus()
        }
    }

    private func refreshAccessibility() {
        state.setAccessibility()
        applyLifecycle(
            .setAccessibilityGranted(state.accessibilityGranted)
        )
    }

    private func applyLifecycle(
        _ event: OutputLifecycleEvent,
        clearVisualization: Bool = false
    ) {
        applyCleanup(outputLifecycle.handle(event))
        if clearVisualization {
            visual.clear()
        }
        refreshMenuStatus()
    }

    private func applyCleanup(_ cleanup: OutputCleanup) {
        if cleanup.contains(.cancelPendingRoutes) {
            appWheelHoldTimer?.invalidate()
            appWheelHoldTimer = nil
            commandRouter.resetTransientState()
        }
        if cleanup.contains(.closeAppWheel) {
            appWheel?.close()
            appWheelSessionActive = false
        }
    }

    private func refreshMenuStatus() {
        let targetControllerDescription = state.devices.first?.name ?? "disconnected"
        targetControllerStatusMenuItem?.title =
            "Target controller: \(targetControllerDescription)"
        accessibilityStatusMenuItem?.title = state.accessibilityGranted
            ? "Accessibility: granted"
            : "Accessibility: required"
        outputStatusMenuItem?.title = outputLifecycle.isPaused
            ? "Output: emergency pause"
            : "Output: active"
        appContextStatusMenuItem?.title = "App context: \(state.focusedApp.name)"
        outputMenuItem?.title = outputLifecycle.isPaused
            ? "Resume output"
            : "Pause output"
        outputMenuItem?.state = outputLifecycle.isPaused ? .on : .off
        statusItem?.button?.title = outputLifecycle.isPaused ? "⌘ Pad ⏸" : "⌘ Pad"
    }

    private var activeOutputStatusMessage: String {
        if !outputLifecycle.targetControllerConnected {
            return "Output active · waiting for target controller"
        }
        if !state.accessibilityGranted {
            return "Output active · keyboard actions need Accessibility"
        }
        return "Output active · mappings are live"
    }
}

@main
struct VibestickMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("--controller-diagnostic") {
            var coverage = ControllerDiagnosticCoverage()
            let reader = ControllerReader(
                onEvent: { event in
                    print("[normalized] \(event.description)")
                },
                onDiagnostic: { record in
                    print(record.description)
                    if coverage.record(record) {
                        print("[coverage] \(coverage.progressDescription(for: record.backend))")
                    }
                }
            )
            guard reader.start() else {
                print("Could not open target-controller input monitor.")
                exit(1)
            }
            print(reader.diagnosticSummary)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                print("\nDiscovery update:\n\(reader.diagnosticSummary)")
            }
            print("[coverage] \(coverage.progressDescription(for: .gameController))")
            print(
                "Exercise every control on \(TargetController.identifier), including Share; " +
                "verify Game Controller reports each control and normalized output appears once. " +
                "Press Control-C to stop."
            )
            RunLoop.main.run()
            return
        }
        if arguments.contains("--status") {
            let reader = ControllerReader(onEvent: { _ in })
            _ = reader.start()
            let devices = reader.connectedDevices()
            reader.stop()
            print(
                devices.isEmpty
                    ? "Target controller \(TargetController.identifier) not found."
                    : devices.map(\.displayName).joined(separator: "\n")
            )
            return
        }
        if arguments.contains("--self-check") {
            print("Embedded self-checks were retired; run `swift test` instead.")
            return
        }

        let application = NSApplication.shared
        let coordinator = ApplicationCoordinator()
        application.delegate = coordinator
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
