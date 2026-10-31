import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel above the menu bar (CodeIsland's KeyablePanel).
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // AppKit clamps borderless windows below the menu bar on display changes; keep our frame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // A non-activating panel isn't key, so the first click would only focus it; make it key first.
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}

@MainActor
final class NotchController {
    private let store: Store
    private let state: NotchState
    private let panel: NSPanel
    private var monitors: [Any] = []
    private var exitTimer: Timer?
    private var leftAt: Date?
    private var cancellables: Set<AnyCancellable> = []

    static let panelSize = CGSize(width: 440, height: 300)

    init(store: Store) {
        self.store = store
        state = NotchState(geometry: Self.geometry(for: Self.targetScreen()))
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        let view = NotchView(store: store, state: state) { [weak self] thread in self?.open(thread) }
        let host = NotchHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.updateHover() }
            return event
        } as Any)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        // The hot zone changes size when counts change; re-check while the mouse sits still.
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateHover() }
        }.store(in: &cancellables)
    }

    private func reposition() {
        let screen = Self.targetScreen()
        state.geometry = Self.geometry(for: screen)
        guard let screen else { return }
        let g = state.geometry
        let notchScreenMinX = Self.notchScreenMinX(screen)
        panel.setFrame(NSRect(x: notchScreenMinX - g.notchMinX, y: screen.frame.maxY - Self.panelSize.height,
                              width: Self.panelSize.width, height: Self.panelSize.height), display: true)
    }

    private func hotRect() -> NSRect {
        let r = state.shapeRect(running: store.runningCount, done: store.done.count)
        let f = panel.frame
        // Grow upward past the screen edge so the topmost pixel row counts as inside.
        return NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height + 4)
    }

    private func updateHover() {
        let inside = hotRect().contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        if inside {
            leftAt = nil
            if !state.expanded { state.expanded = true }
        } else if state.expanded {
            // Brief grace period so crossing a gap or overshooting an edge doesn't collapse it.
            if let leftAt, Date().timeIntervalSince(leftAt) > 0.18 {
                state.expanded = false
                self.leftAt = nil
            } else if leftAt == nil {
                leftAt = Date()
            }
        }
        // Local mouseMoved events stop once the panel isn't key, so poll until we're out.
        if state.expanded || inside {
            if exitTimer == nil {
                exitTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateHover() }
                }
            }
        } else {
            exitTimer?.invalidate()
            exitTimer = nil
        }
    }

    private func open(_ thread: AgentThread) {
        state.expanded = false
        panel.ignoresMouseEvents = true
        if let env = store.environmentId, let url = URL(string: "t3code://threads/\(env)/\(thread.id)") {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Screen geometry (CodeIsland's ScreenDetector)

    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func notchSize(_ screen: NSScreen) -> CGSize {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        // No notch: a pseudo-notch at the top centre, as tall as the menu bar.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return CGSize(width: 180, height: menuBar > 0 ? menuBar : 24)
    }

    private static func notchScreenMinX(_ screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea != nil {
            return screen.frame.minX + left.width
        }
        return screen.frame.midX - notchSize(screen).width / 2
    }

    static func geometry(for screen: NSScreen?) -> NotchGeometry {
        let size = screen.map(notchSize) ?? CGSize(width: 185, height: 32)
        return NotchGeometry(panelSize: panelSize, notchMinX: (panelSize.width - size.width) / 2,
                             notchWidth: size.width, notchHeight: size.height)
    }
}
