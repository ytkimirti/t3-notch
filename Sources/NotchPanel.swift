import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel above the menu bar (after CodeIsland's KeyablePanel).
private final class NotchPanel: NSPanel {
    // Never key: keystrokes stay with the user's app. Clicks still land via acceptsFirstMouse.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // AppKit clamps borderless windows below the menu bar on display changes; keep our frame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    private let store: Store
    private let state: NotchState
    private let panel: NSPanel
    private var monitors: [Any] = []
    private var exitTimer: Timer?
    private var leftAt: Date?
    private var enteredAt: Date?
    private var cancellables: Set<AnyCancellable> = []

    /// Wide enough for the widest wing (and the list, which spans it symmetrically) on either side.
    static func panelSize(notchWidth: CGFloat) -> CGSize {
        let wing = WingStyle.allCases.map { NotchState.wingWidth(content: WingLayout.widest($0)) }.max() ?? 0
        let half = max(NotchState.expandedWidth / 2, notchWidth / 2 + wing) + 16
        return CGSize(width: ceil(half * 2), height: 300)
    }

    init(store: Store, style: WingStyle) {
        self.store = store
        state = NotchState(geometry: Self.geometry(for: Self.targetScreen()))
        state.style = style
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: state.geometry.panelSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        let view = NotchView(store: store, state: state) { [weak self] thread in self?.open(thread) }
        let host = NotchHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: state.geometry.panelSize)
        panel.contentView = host
    }

    func show() {
        reposition()

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
        // Without a notch, whether a menu bar is reserved can change with the Space.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
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
        // No display (asleep), or no notch and no menu bar reserved (auto-hidden): a pill there
        // would sit over window content, so stay hidden.
        guard let screen, Self.hasNotch(screen) || Self.menuBarHeight(screen) > 0 else {
            state.expanded = false
            panel.orderOut(nil)
            return
        }
        // Over a full-screen app only the notch's dead strip is free; elsewhere it'd cover content.
        panel.collectionBehavior = Self.hasNotch(screen)
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            : [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let g = state.geometry
        let notchScreenMinX = Self.notchScreenMinX(screen)
        panel.setFrame(NSRect(x: notchScreenMinX - g.notchMinX, y: screen.frame.maxY - g.panelSize.height,
                              width: g.panelSize.width, height: g.panelSize.height), display: true)
        panel.orderFrontRegardless()
    }

    private func toScreen(_ r: CGRect) -> NSRect {
        let f = panel.frame
        return NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// The notch and wing, plus, when expanded, the list below the menu bar. The expanded shape's
    /// top strip beside the notch is left out so menu bar items there stay clickable.
    private func isHot(_ p: NSPoint) -> Bool {
        let running = store.runningCount, waiting = store.waitingCount, done = store.done.count
        var top = toScreen(state.collapsedRect(running: running, waiting: waiting, done: done))
        top.size.height += 4 // past the screen edge, so the topmost pixel row counts
        if top.contains(p) { return true }
        guard state.expanded else { return false }
        let g = state.geometry
        var below = state.shapeRect(running: running, waiting: waiting, done: done)
        below.origin.y = g.notchHeight
        below.size.height -= g.notchHeight
        return toScreen(below).contains(p)
    }

    private func updateHover() {
        let inside = panel.isVisible && isHot(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if inside {
            leftAt = nil
            // Dwell briefly so sweeping across the menu bar doesn't pop the list open.
            if !state.expanded {
                if let enteredAt, Date().timeIntervalSince(enteredAt) > 0.05 {
                    state.expanded = true
                } else if enteredAt == nil {
                    enteredAt = Date()
                }
            }
        } else if state.expanded {
            // Brief grace period so crossing a gap or overshooting an edge doesn't collapse it.
            if let leftAt, Date().timeIntervalSince(leftAt) > 0.12 {
                state.expanded = false
                self.leftAt = nil
            } else if leftAt == nil {
                leftAt = Date()
            }
        }
        if !inside { enteredAt = nil }
        // A panel that is never key gets no mouseMoved events of its own, so poll until we're out.
        if state.expanded || inside {
            if exitTimer == nil {
                exitTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
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
        if let env = store.environments[thread.source], let url = URL(string: "t3code://threads/\(env)/\(thread.id)") {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Screen geometry (CodeIsland's ScreenDetector)

    private static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    /// The built-in display with a notch if it's awake, else (lid closed) the primary display,
    /// where a zero-width "notch" at the top center stands in for it.
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: hasNotch) ?? NSScreen.screens.first
    }

    private static func notchSize(_ screen: NSScreen) -> CGSize {
        guard hasNotch(screen) else { return CGSize(width: 0, height: menuBarHeight(screen)) }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0, right = screen.auxiliaryTopRightArea?.width ?? 0
        return CGSize(width: screen.frame.width - left - right, height: screen.safeAreaInsets.top)
    }

    /// What the menu bar reserves at the top; zero when it auto-hides.
    private static func menuBarHeight(_ screen: NSScreen) -> CGFloat {
        screen.frame.maxY - screen.visibleFrame.maxY
    }

    private static func notchScreenMinX(_ screen: NSScreen) -> CGFloat {
        guard hasNotch(screen) else { return screen.frame.midX }
        return screen.frame.minX + (screen.auxiliaryTopLeftArea?.width ?? 0)
    }

    static func geometry(for screen: NSScreen?) -> NotchGeometry {
        let size = screen.map(notchSize) ?? CGSize(width: 185, height: 32)
        let panel = Self.panelSize(notchWidth: size.width)
        return NotchGeometry(panelSize: panel, notchMinX: (panel.width - size.width) / 2,
                             notchWidth: size.width, notchHeight: size.height,
                             hasNotch: screen.map(hasNotch) ?? true)
    }
}
