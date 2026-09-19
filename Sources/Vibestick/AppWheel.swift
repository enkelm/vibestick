import AppKit
import SwiftUI
import VibestickCore

struct AppWheelItem: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage
    let application: NSRunningApplication
}

@MainActor
final class AppWheelModel: ObservableObject {
    @Published private(set) var apps: [AppWheelItem] = []
    @Published private(set) var interaction = AppWheelInteraction()

    var selectedIndex: Int? {
        interaction.selectedIndex
    }

    var selectedApp: AppWheelItem? {
        guard let selectedIndex,
              apps.indices.contains(selectedIndex)
        else { return nil }
        return apps[selectedIndex]
    }

    func replaceApps(_ apps: [AppWheelItem]) {
        self.apps = apps
        interaction.begin(itemCount: apps.count)
    }

    func updateSelection(x: Double, y: Double) {
        interaction.updateSelection(x: x, y: y)
    }

    func handle(button: PadButton, pressed: Bool) -> AppWheelResponse {
        interaction.handle(button: button, pressed: pressed)
    }
}

final class AppWheelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppWheelController {
    private static let panelSize = NSSize(width: 560, height: 560)

    private let state: ProfileStore
    private let appActivated: () -> Void
    private let recencyRank: (String) -> UInt64?
    private let model = AppWheelModel()
    private var panel: AppWheelPanel?

    init(
        state: ProfileStore,
        appActivated: @escaping () -> Void,
        recencyRank: @escaping (String) -> UInt64?
    ) {
        self.state = state
        self.appActivated = appActivated
        self.recencyRank = recencyRank
    }

    var isVisible: Bool { panel?.isVisible == true }

    @discardableResult
    func open() -> Bool {
        let apps = runningApps()
        guard !apps.isEmpty else {
            state.announce("No open apps are available for the app wheel")
            return false
        }

        model.replaceApps(apps)
        if panel == nil { panel = makePanel() }
        guard let panel else { return false }
        position(panel)
        panel.orderFrontRegardless()
        state.announce("App wheel open · point with the left stick, A to open, B to close")
        return true
    }

    func updateSelection(x: Double, y: Double) {
        guard isVisible else { return }
        model.updateSelection(x: x, y: y)
    }

    func handle(button: PadButton, pressed: Bool) {
        guard isVisible else { return }
        switch model.handle(button: button, pressed: pressed) {
        case .none:
            if button == .a, pressed, model.selectedApp == nil {
                state.announce("Point the left stick at an app before pressing A")
            }
        case .activate:
            activateSelection()
        case .cancel:
            cancel()
        }
    }

    func cancel() {
        guard isVisible else { return }
        close()
        state.announce("Closed the app wheel")
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func activateSelection() {
        guard let item = model.selectedApp else { return }
        close()
        if item.application.activate(options: [.activateAllWindows]) {
            state.announce("Opened \(item.name)")
            appActivated()
        } else {
            state.announce("macOS could not open \(item.name)")
        }
    }

    private func makePanel() -> AppWheelPanel {
        let panel = AppWheelPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: AppWheelView(model: model))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.center()
            return
        }
        let frame = screen.frame
        let origin = NSPoint(
            x: frame.midX - Self.panelSize.width / 2,
            y: frame.midY - Self.panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func runningApps() -> [AppWheelItem] {
        let workspace = NSWorkspace.shared
        let frontmostPID = workspace.frontmostApplication?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let applications = workspace.runningApplications
        let snapshots = applications.map { application in
            let applicationID = appWheelIdentifier(for: application)
            return AppWheelApplication(
                id: String(application.processIdentifier),
                name: application.localizedName ?? applicationID,
                applicationID: applicationID,
                recencyRank: recencyRank(applicationID),
                isRegular: application.activationPolicy == .regular,
                isTerminated: application.isTerminated,
                isCurrent: application.processIdentifier == frontmostPID,
                isVibestick: application.processIdentifier == ownPID
            )
        }
        let applicationsByID = Dictionary(
            uniqueKeysWithValues: applications.map {
                (String($0.processIdentifier), $0)
            }
        )

        return AppWheelCandidates.make(from: snapshots).compactMap { candidate in
            guard let application = applicationsByID[candidate.id] else {
                return nil
            }
            let icon = application.icon
                ?? NSImage(
                    systemSymbolName: "app",
                    accessibilityDescription: candidate.name
                )
                ?? NSImage()
            return AppWheelItem(
                id: application.processIdentifier,
                name: candidate.name,
                icon: icon,
                application: application
            )
        }
    }
}

func appWheelIdentifier(for application: NSRunningApplication) -> String {
    AppWheelApplicationIdentity.make(
        bundleIdentifier: application.bundleIdentifier,
        bundleURL: application.bundleURL,
        executableURL: application.executableURL,
        localizedName: application.localizedName,
        processIdentifier: application.processIdentifier
    )
}

// MARK: - App wheel UI

struct AppWheelView: View {
    @ObservedObject var model: AppWheelModel

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 500, height: 500)
                .shadow(color: .black.opacity(0.5), radius: 28, x: 0, y: 15)

            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                .frame(width: 420, height: 420)

            ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                appIcon(app, at: index)
            }

            centerContent
        }
        .frame(width: 560, height: 560)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App switcher")
    }

    @ViewBuilder
    private var centerContent: some View {
        VStack(spacing: 10) {
            if let app = model.selectedApp {
                Text(app.name)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: 180)

                Text("READY TO OPEN")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.62))
            } else {
                Image(systemName: "circle.dotted.circle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.75))

                Text("Point with left stick")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }

            HStack(spacing: 16) {
                ControllerHintBadge(letter: "A", label: "Open", color: .green)
                ControllerHintBadge(letter: "B", label: "Close", color: .red)
            }
            .padding(.top, 4)
        }
        .frame(width: 200, height: 150)
        .animation(.easeOut(duration: 0.14), value: model.selectedIndex)
    }

    private func appIcon(_ app: AppWheelItem, at index: Int) -> some View {
        let count = max(model.apps.count, 1)
        let angle = -Double.pi / 2 + (Double(index) / Double(count)) * Double.pi * 2
        let selected = model.selectedIndex == index
        let iconSize = baseIconSize(for: count)

        return ZStack {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.28))
                )
        }
        .scaleEffect(selected ? 1.18 : 1)
        .brightness(selected ? 0.08 : 0)
        .shadow(
            color: selected ? Color.accentColor.opacity(0.45) : .black.opacity(0.24),
            radius: selected ? 14 : 7,
            x: 0,
            y: selected ? 8 : 4
        )
        .offset(
            x: cos(angle) * (selected ? 218 : 210),
            y: sin(angle) * (selected ? 218 : 210)
        )
        .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.72), value: model.selectedIndex)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func baseIconSize(for count: Int) -> CGFloat {
        min(52, max(28, 1_180 / CGFloat(count) - 8))
    }
}

struct ControllerHintBadge: View {
    let letter: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(letter)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(color.opacity(0.78)))

            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.78))
        }
    }
}
