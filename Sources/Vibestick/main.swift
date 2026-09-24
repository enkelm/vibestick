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
    private static let naturalScrollingKey = "com.apple.swipescrolldirection"

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

    func perform(_ mapping: StickMapping, target: FocusedApp) {
        switch mapping {
        case .none:
            return
        case let .key(chord):
            postKey(chord, target: target, announce: false)
        case let .scroll(direction):
            postScroll(direction)
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

    private func postScroll(_ direction: ScrollDirection) {
        state.setAccessibility()
        guard state.accessibilityGranted else {
            state.announce("Accessibility is required; no scroll sent")
            return
        }
        let naturalScrolling = (
            UserDefaults.standard.object(forKey: Self.naturalScrollingKey) as? NSNumber
        )?.boolValue ?? true
        let delta = direction.delta(naturalScrolling: naturalScrolling)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .line,
                wheelCount: 2,
                wheel1: delta.vertical,
                wheel2: delta.horizontal,
                wheel3: 0
              )
        else {
            state.announce("Could not create scroll event")
            return
        }
        event.post(tap: .cghidEventTap)
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
enum BindingEditTarget: Identifiable {
    case button(PadButton)
    case system(SystemBinding)
    case stick(StickInput)

    var id: String {
        switch self {
        case let .button(button):
            return "button:\(button.rawValue)"
        case let .system(binding):
            return "system:\(binding.rawValue)"
        case let .stick(input):
            return "stick:\(input.rawValue)"
        }
    }
}

@MainActor
final class OverlayUIState: ObservableObject {
    @Published var editTarget: BindingEditTarget?
    @Published private(set) var isEditing = false

    private let onEditingChanged: (Bool) -> Void

    init(onEditingChanged: @escaping (Bool) -> Void) {
        self.onEditingChanged = onEditingChanged
    }

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        onEditingChanged(true)
    }

    func edit(_ target: BindingEditTarget) {
        beginEditing()
        editTarget = target
    }

    func dismissEditor() {
        editTarget = nil
    }

    func endEditing() {
        editTarget = nil
        guard isEditing else { return }
        isEditing = false
        onEditingChanged(false)
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
    private let trainer: BindingsOverlayTrainer
    private let uiState: OverlayUIState
    private var panel: OverlayPanel?

    init(
        state: ProfileStore,
        trainer: BindingsOverlayTrainer,
        onEditingChanged: @escaping (Bool) -> Void
    ) {
        self.state = state
        self.trainer = trainer
        uiState = OverlayUIState { editing in
            if editing {
                state.beginEditingFocusedApp()
            } else {
                state.endEditing()
                trainer.follow(state.focusedApp)
            }
            onEditingChanged(editing)
        }
    }

    var isVisible: Bool { panel?.isVisible == true }
    var isCapturing: Bool { uiState.editTarget != nil }
    var isEditing: Bool { uiState.isEditing }

    func toggle() {
        if isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        trainer.follow(state.focusedApp)
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
        uiState.endEditing()
        trainer.setPointerInteraction(active: false)
        panel?.orderOut(nil)
    }

    func follow(_ app: FocusedApp) {
        guard !isEditing else { return }
        trainer.follow(app)
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 650),
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
                trainer: trainer,
                uiState: uiState,
                close: { [weak self] in self?.close() }
            )
        )
        return panel
    }
}

// MARK: - Overlay UI

struct BindingChip: View {
    let button: PadButton
    let action: BindingAction
    let source: BindingSource
    let pressed: Bool
    let editable: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 1) {
                Text(button.shortTitle)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(pressed ? .white : .primary)
                Text(action.displayName)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(actionColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(source.editorLabel)
                    .font(.system(size: 7, weight: .semibold, design: .rounded))
                    .foregroundStyle(sourceColor)
                    .lineLimit(1)
            }
            .frame(width: 78, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(pressed ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(sourceColor.opacity(0.75), lineWidth: source == .operatorOverride ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!editable)
        .opacity(editable ? 1 : 0.88)
        .help("Remap \(button.title)")
    }

    private var sourceColor: Color {
        switch source {
        case .operatorOverride: return .mint
        case .preset: return .orange
        case .globalFallback: return .purple
        case .builtInDefault: return .blue
        case .unbound: return .secondary
        }
    }

    private var actionColor: Color {
        switch action {
        case .none: return .secondary
        case .overlay, .switchApp: return .orange
        case .key, .sequence: return sourceColor
        }
    }
}

struct BindingEditorRow: View {
    let title: String
    let action: String
    let source: BindingSource
    let editable: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(width: 112, alignment: .leading)
                Text(action)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(source.editorLabel)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(source == .operatorOverride ? Color.mint : Color.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .disabled(!editable)
        .opacity(editable ? 1 : 0.88)
    }
}

struct SystemGestureChip: View {
    let binding: SystemBinding
    let action: BindingAction
    let active: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(binding.title.uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(active ? .white : .secondary)
            Text(action.displayName)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(active ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
        )
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

private extension BindingSource {
    var editorLabel: String {
        switch self {
        case .operatorOverride: return "Operator override"
        case .preset: return "Preset"
        case .globalFallback: return "Global fallback"
        case .builtInDefault: return "Built-in default"
        case .unbound: return "Unbound"
        }
    }
}

private extension BindingEditorSection {
    var editorTitle: String {
        switch self {
        case .systemBindings: return "System"
        case .globalFallbacks: return "Global"
        case .appProfile: return "Focused app"
        case .herdrLayer: return "Herdr layer"
        case .stickMappings: return "Sticks"
        }
    }
}

private extension SystemBinding {
    var editorTitle: String {
        switch self {
        case .shortL3: return "Short L3"
        case .longL3: return "Long L3"
        case .share: return "Share"
        }
    }
}

private extension StickInput {
    var editorTitle: String {
        switch self {
        case .leftUp: return "Left stick up"
        case .leftDown: return "Left stick down"
        case .leftLeft: return "Left stick left"
        case .leftRight: return "Left stick right"
        case .rightUp: return "Right stick up"
        case .rightDown: return "Right stick down"
        case .rightLeft: return "Right stick left"
        case .rightRight: return "Right stick right"
        }
    }
}

private extension StickMapping {
    var displayName: String {
        switch self {
        case .none: return "Unbound"
        case let .key(chord): return chord.displayName
        case let .scroll(direction): return "Scroll \(direction.rawValue)"
        }
    }
}

struct OverlayView: View {
    @ObservedObject var state: ProfileStore
    @ObservedObject var trainer: BindingsOverlayTrainer
    @ObservedObject var uiState: OverlayUIState
    let close: () -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 7),
        count: 5
    )

    var body: some View {
        VStack(spacing: 0) {
            header
            scopeBar
            systemGestureBar
            scopeContent
            footer
        }
        .padding(18)
        .frame(width: 620, height: 650)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    uiState.isEditing || trainer.presentation == .interactive
                        ? AnyShapeStyle(.thinMaterial)
                        : AnyShapeStyle(.ultraThinMaterial)
                )
                .opacity(
                    trainer.presentation == .interactive ||
                        uiState.isEditing
                        ? 0.96
                        : 0.62
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
        .preferredColorScheme(.dark)
        .onHover { active in
            withAnimation(.easeInOut(duration: 0.16)) {
                trainer.setPointerInteraction(active: active)
            }
        }
        .sheet(item: $uiState.editTarget) { target in
            editor(for: target)
        }
        .onExitCommand(perform: close)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vibestick")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text(uiState.isEditing ? "bindings editor" : "live bindings trainer")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(uiState.isEditing ? Color.mint : Color.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(state.devices.first?.name ?? "No controller")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(state.accessibilityGranted ? "Keyboard output ready" : "Keyboard output needs Access")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(state.accessibilityGranted ? .mint : .orange)
            }
            if uiState.isEditing {
                Button("Done") { uiState.endEditing() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Finish editing and resume mapped controller output")
            } else {
                Button("Edit") { uiState.beginEditing() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Pin this app context and suspend mapped controller output")
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
        .padding(.bottom, 12)
    }

    private var scopeBar: some View {
        VStack(spacing: 8) {
            Picker("Editor section", selection: $state.editingSection) {
                ForEach(state.availableEditingSections) { section in
                    Text(section.editorTitle).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: state.editingSection) { _, section in
                state.announce("Viewing \(section.editorTitle.lowercased()) bindings")
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(uiState.isEditing ? Color.mint : Color.orange)
                    .frame(width: 7, height: 7)
                Text(contextDescription)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if uiState.isEditing, state.editingSection == .appProfile {
                    Button("Reset app profile") { state.resetEditingApp() }
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var systemGestureBar: some View {
        HStack(spacing: 6) {
            SystemGestureChip(
                binding: .share,
                action: state.systemBinding(for: .share),
                active: trainer.pressed.contains(.share)
            )
            SystemGestureChip(
                binding: .shortL3,
                action: state.systemBinding(for: .shortL3),
                active: trainer.pressed.contains(.l3)
            )
            SystemGestureChip(
                binding: .longL3,
                action: state.systemBinding(for: .longL3),
                active: trainer.pressed.contains(.l3)
            )
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var scopeContent: some View {
        switch state.editingSection {
        case .systemBindings:
            systemBindings
        case .globalFallbacks, .appProfile, .herdrLayer:
            buttonBindings
        case .stickMappings:
            stickBindings
        }
    }

    private var systemBindings: some View {
        HStack(spacing: 20) {
            liveController
            VStack(spacing: 7) {
                ForEach(SystemBinding.allCases, id: \.self) { binding in
                    let override = state.isSystemBindingOverride(binding)
                    BindingEditorRow(
                        title: binding.editorTitle,
                        action: state.systemBinding(for: binding).displayName,
                        source: override ? .operatorOverride : .builtInDefault,
                        editable: uiState.isEditing,
                        onTap: { uiState.edit(.system(binding)) }
                    )
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var buttonBindings: some View {
        VStack(spacing: 4) {
            liveController
            ScrollView {
                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(editableButtons) { button in
                        chip(button)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            Text(
                uiState.isEditing
                    ? "Select a binding to capture, clear, or reset it"
                    : "Mappings pass through while you preview live input"
            )
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .frame(maxHeight: .infinity)
    }

    private var stickBindings: some View {
        HStack(spacing: 20) {
            liveController
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(StickInput.allCases, id: \.self) { input in
                        let override = state.isStickMappingOverride(input)
                        BindingEditorRow(
                            title: input.editorTitle,
                            action: state.stickMapping(for: input).displayName,
                            source: override ? .operatorOverride : .builtInDefault,
                            editable: uiState.isEditing,
                            onTap: { uiState.edit(.stick(input)) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var liveController: some View {
        ControllerDiagram(
            pressed: trainer.pressed,
            axes: trainer.axes,
            triggers: trainer.triggers
        )
    }

    private var editableButtons: [PadButton] {
        PadButton.allCases.filter { button in
            if button == .l3 || button == .share { return false }
            if state.editingSection == .herdrLayer, button == .back { return false }
            if state.editingSection == .appProfile,
               state.editingApp.isHerdr,
               button == .back {
                return false
            }
            return true
        }
    }

    private var contextDescription: String {
        if uiState.isEditing {
            return "Pinned to \(state.describe(state.editingApp)) · mapped output suspended"
        }
        return "Following \(state.describe(trainer.appContext)) · mapped output passes through"
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
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let configurationNotice = state.configurationNotice {
                Text(configurationNotice)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text("Trainer is live · mapped controls pass through · menu bar is always available")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
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
            source: state.bindingSource(for: button),
            pressed: trainer.pressed.contains(button),
            editable: uiState.isEditing,
            onTap: { uiState.edit(.button(button)) }
        )
    }

    @ViewBuilder
    private func editor(for target: BindingEditTarget) -> some View {
        switch target {
        case let .button(button):
            BindingActionEditorSheet(
                title: button.title,
                current: state.binding(for: button),
                source: state.bindingSource(for: button),
                onSet: { action in
                    state.setBinding(action, for: button)
                    uiState.dismissEditor()
                },
                onReset: {
                    state.resetBinding(button)
                    uiState.dismissEditor()
                },
                close: { uiState.dismissEditor() }
            )
        case let .system(binding):
            BindingActionEditorSheet(
                title: binding.editorTitle,
                current: state.systemBinding(for: binding),
                source: state.isSystemBindingOverride(binding)
                    ? .operatorOverride
                    : .builtInDefault,
                onSet: { action in
                    state.setSystemBinding(action, for: binding)
                    uiState.dismissEditor()
                },
                onReset: {
                    state.resetSystemBinding(binding)
                    uiState.dismissEditor()
                },
                close: { uiState.dismissEditor() }
            )
        case let .stick(input):
            StickMappingEditorSheet(
                input: input,
                current: state.stickMapping(for: input),
                source: state.isStickMappingOverride(input)
                    ? .operatorOverride
                    : .builtInDefault,
                onSet: { mapping in
                    state.setStickMapping(mapping, for: input)
                    uiState.dismissEditor()
                },
                onReset: {
                    state.resetStickMapping(input)
                    uiState.dismissEditor()
                },
                close: { uiState.dismissEditor() }
            )
        }
    }
}

struct BindingActionEditorSheet: View {
    let title: String
    let current: BindingAction
    let source: BindingSource
    let onSet: (BindingAction) -> Void
    let onReset: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 15) {
            EditorSheetHeader(
                title: title,
                current: current.displayName,
                source: source
            )
            KeyCaptureView(onCapture: { onSet(.key($0)) })
                .frame(height: 64)
                .overlay(
                    Text("Press any key or modifier chord")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                )
            HStack(spacing: 8) {
                Button("Toggle overlay") { onSet(.overlay) }
                Button("Open app wheel") { onSet(.switchApp) }
            }
            .buttonStyle(.bordered)
            EditorSheetFooter(
                onClear: { onSet(.none) },
                onReset: onReset,
                close: close
            )
        }
        .padding(22)
        .frame(width: 380, height: 270)
        .preferredColorScheme(.dark)
    }
}

struct StickMappingEditorSheet: View {
    let input: StickInput
    let current: StickMapping
    let source: BindingSource
    let onSet: (StickMapping) -> Void
    let onReset: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 15) {
            EditorSheetHeader(
                title: input.editorTitle,
                current: current.displayName,
                source: source
            )
            KeyCaptureView(onCapture: { onSet(.key($0)) })
                .frame(height: 58)
                .overlay(
                    Text("Press a key or choose scrolling")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                )
            HStack(spacing: 7) {
                ForEach(
                    [
                        ScrollDirection.up,
                        .down,
                        .left,
                        .right,
                    ],
                    id: \.self
                ) { direction in
                    Button(direction.rawValue.capitalized) {
                        onSet(.scroll(direction))
                    }
                }
            }
            .buttonStyle(.bordered)
            EditorSheetFooter(
                onClear: { onSet(.none) },
                onReset: onReset,
                close: close
            )
        }
        .padding(22)
        .frame(width: 390, height: 255)
        .preferredColorScheme(.dark)
    }
}

private struct EditorSheetHeader: View {
    let title: String
    let current: String
    let source: BindingSource

    var body: some View {
        VStack(spacing: 4) {
            Text("Edit \(title)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text("\(current) · \(source.editorLabel)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

private struct EditorSheetFooter: View {
    let onClear: () -> Void
    let onReset: () -> Void
    let close: () -> Void

    var body: some View {
        HStack {
            Button("Clear", action: onClear)
                .buttonStyle(.borderless)
            Button("Reset", action: onReset)
                .buttonStyle(.borderless)
            Spacer()
            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)
        }
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
private final class GhosttyFocusObserver {
    private let onFocusedSurfaceChanged: () -> Void
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?
    private var focusedWindowElement: AXUIElement?
    private var processID: pid_t?

    init(onFocusedSurfaceChanged: @escaping () -> Void) {
        self.onFocusedSurfaceChanged = onFocusedSurfaceChanged
    }

    func follow(_ application: NSRunningApplication?) {
        guard let application,
              let bundleID = application.bundleIdentifier,
              GhosttyPreset.matches(bundleID)
        else {
            stop()
            return
        }
        guard processID != application.processIdentifier || observer == nil else {
            return
        }

        stop()
        var newObserver: AXObserver?
        let result = AXObserverCreate(
            application.processIdentifier,
            { _, _, notification, context in
                guard let context else { return }
                let focusObserver = Unmanaged<GhosttyFocusObserver>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                Task { @MainActor in
                    focusObserver.handle(notification)
                }
            },
            &newObserver
        )
        guard result == .success, let newObserver else { return }

        let applicationElement = AXUIElementCreateApplication(
            application.processIdentifier
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(
            newObserver,
            applicationElement,
            kAXFocusedWindowChangedNotification as CFString,
            context
        ) == .success
        else { return }

        observer = newObserver
        self.applicationElement = applicationElement
        processID = application.processIdentifier
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(newObserver),
            .commonModes
        )
        observeFocusedWindow()
    }

    func stop() {
        if let observer {
            if let focusedWindowElement {
                AXObserverRemoveNotification(
                    observer,
                    focusedWindowElement,
                    kAXTitleChangedNotification as CFString
                )
            }
            if let applicationElement {
                AXObserverRemoveNotification(
                    observer,
                    applicationElement,
                    kAXFocusedWindowChangedNotification as CFString
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        focusedWindowElement = nil
        applicationElement = nil
        observer = nil
        processID = nil
    }

    private func handle(_ notification: CFString) {
        if notification == kAXFocusedWindowChangedNotification as CFString {
            observeFocusedWindow()
        }
        onFocusedSurfaceChanged()
    }

    private func observeFocusedWindow() {
        guard let observer, let applicationElement else { return }
        if let focusedWindowElement {
            AXObserverRemoveNotification(
                observer,
                focusedWindowElement,
                kAXTitleChangedNotification as CFString
            )
        }
        focusedWindowElement = nil

        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        ) == .success,
              let focusedWindow
        else { return }
        let windowElement = focusedWindow as! AXUIElement
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(
            observer,
            windowElement,
            kAXTitleChangedNotification as CFString,
            context
        ) == .success
        else { return }
        focusedWindowElement = windowElement
    }
}

@MainActor
final class ApplicationCoordinator: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = ProfileStore()
    let trainer = BindingsOverlayTrainer()
    private lazy var ghosttyFocusObserver = GhosttyFocusObserver {
        [weak self] in self?.refreshFocus()
    }
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
    private var stickRepeatTimer: Timer?
    private var appWheelSessionActive = false
    private var appWheelRecency = AppWheelRecency()
    private var commandRouter = CommandRouter()
    private var stickRepeater: StickRepeater!
    private var outputLifecycle = OutputLifecycle()
    private var diagnostics: [ControllerDiagnosticRecord] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Vibestick started")
        actions = MacActions(
            state: state,
            appActivated: { [weak self] in self?.scheduleFocusRefresh() }
        )
        stickRepeater = StickRepeater(tuning: state.configuration.stickTuning)
        overlay = OverlayController(
            state: state,
            trainer: trainer,
            onEditingChanged: { [weak self] editing in
                self?.applyLifecycle(.setBindingsEditing(editing))
            }
        )
        appWheel = AppWheelController(
            state: state,
            appActivated: { [weak self] in self?.scheduleFocusRefresh() },
            recencyRank: { [weak self] applicationID in
                self?.appWheelRecency.rank(for: applicationID)
            }
        )
        recordUse(of: NSWorkspace.shared.frontmostApplication)
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
        ) { [weak self] notification in
            Task { @MainActor in
                let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication
                self?.recordUse(of: application)
                self?.refreshFocus()
            }
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
        ghosttyFocusObserver.stop()
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
        overlay.open()
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
        \(state.herdrDetectionDiagnostic())
        App wheel: always active · hold L3
        Owner: standalone Vibestick\(configuration)

        Recent controller events:
        \(trace.isEmpty ? "No events recorded." : trace)

        Stop Herdr's gamepad plugin before enabling this listener.
        """
        alert.runModal()
    }

    @objc private func resetFocusedProfile() {
        state.resetFocusedApp()
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
        trainer.observe(input)
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
            mappedOutputAvailable: outputLifecycle.mappedOutputAvailable
        )
    }

    private func handle(_ route: InputRoute) {
        guard outputLifecycle.allows(route) else { return }
        if route.cancelsRepeatingStickInput {
            cancelStickRepeat()
        }

        switch route {
        case .capture:
            return
        case let .herdrLayer(input, action):
            guard let action else { return }
            perform(action, from: input)
        case let .appWheel(input):
            handleAppWheelInput(input)
        case let .systemGesture(input, _, action):
            guard let action else { return }
            perform(action, from: input)
        case let .appBinding(input, action):
            if case let .axis(axis, value) = input {
                handleStick(axis: axis, value: value)
                return
            }
            guard let action else { return }
            perform(action, from: input)
        }
    }

    private func handleStick(axis: StickAxis, value: Double) {
        let inputs = stickRepeater.update(
            axis: axis,
            value: value,
            at: ProcessInfo.processInfo.systemUptime
        )
        emitStickInputs(inputs)
        scheduleStickRepeat()
    }

    private func emitStickInputs(_ inputs: [StickInput]) {
        guard outputLifecycle.mappedOutputAvailable else { return }
        for input in inputs {
            actions.perform(
                state.stickMapping(for: input, app: state.focusedApp),
                target: state.focusedApp
            )
        }
    }

    private func scheduleStickRepeat() {
        stickRepeatTimer?.invalidate()
        stickRepeatTimer = nil
        guard let fireTime = stickRepeater.nextFireTime else { return }

        let interval = max(
            0.001,
            fireTime - ProcessInfo.processInfo.systemUptime
        )
        stickRepeatTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stickRepeatTimer = nil
                guard self.outputLifecycle.mappedOutputAvailable,
                      !self.routingContext.captureActive,
                      !self.routingContext.appWheelActive
                else {
                    self.cancelStickRepeat()
                    return
                }
                self.emitStickInputs(
                    self.stickRepeater.advance(
                        to: ProcessInfo.processInfo.systemUptime
                    )
                )
                self.scheduleStickRepeat()
            }
        }
    }

    private func cancelStickRepeat() {
        stickRepeatTimer?.invalidate()
        stickRepeatTimer = nil
        stickRepeater?.cancel()
    }

    private func handleAppWheelInput(_ input: ControllerInput) {
        switch input {
        case let .button(button, pressed):
            appWheel.handle(button: button, pressed: pressed)
        case let .axis(axis, _):
            guard axis == .leftX || axis == .leftY else { return }
            appWheel.updateSelection(
                x: trainer.axes[.leftX] ?? 0,
                y: trainer.axes[.leftY] ?? 0
            )
        case .trigger:
            return
        }
    }

    private func recordUse(of application: NSRunningApplication?) {
        guard let application else { return }
        appWheelRecency.recordUse(of: appWheelIdentifier(for: application))
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
        ghosttyFocusObserver.follow(
            NSWorkspace.shared.frontmostApplication
        )
        state.refreshFocus()
        overlay?.follow(state.focusedApp)
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
            trainer.clearController()
        }
        refreshMenuStatus()
    }

    private func applyCleanup(_ cleanup: OutputCleanup) {
        if cleanup.contains(.cancelPendingRoutes) {
            appWheelHoldTimer?.invalidate()
            appWheelHoldTimer = nil
            cancelStickRepeat()
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
        outputStatusMenuItem?.title = if outputLifecycle.isPaused {
            "Output: emergency pause"
        } else if outputLifecycle.isBindingsEditing {
            "Output: suspended while editing"
        } else {
            "Output: active"
        }
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
