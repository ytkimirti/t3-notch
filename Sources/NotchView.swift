import AppKit
import SwiftUI

/// Where the hardware notch sits inside the panel, in panel-local points (origin top-left).
struct NotchGeometry: Equatable {
    var panelSize: CGSize
    var notchMinX: CGFloat
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    /// False on a display without a notch (lid closed): `notchWidth` is zero and the wing is a
    /// pill centered in the menu bar.
    var hasNotch = true
    /// How wide the wing's figures may get: the menu bar left of the notch, or without one, from
    /// the screen's left edge to the pill's furthest right edge. Nil keeps a ten-figure cap.
    var wingRoom: CGFloat?

    var notchMidX: CGFloat { notchMinX + notchWidth / 2 }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var geometry: NotchGeometry
    @Published var expanded = false
    var style: WingStyle = .critters // read from config once at launch

    static let rowHeight: CGFloat = 26
    static let maxRows = 12
    static let moreHeight: CGFloat = 20
    static let footerHeight: CGFloat = 24
    static let expandedWidth: CGFloat = 380

    init(geometry: NotchGeometry) { self.geometry = geometry }

    private var layoutCache: WingLayout?

    private var layoutCacheRoom: CGFloat?

    /// Cached: hover hit-testing asks on every mouse move, and "+N" layout measures text.
    func wingLayout(running: Int, waiting: Int, woke: Int = 0, done: Int, read: Int = 0) -> WingLayout {
        let room = geometry.wingRoom
        if let c = layoutCache, layoutCacheRoom == room, c.style == style, c.running == running,
           c.waiting == waiting, c.woke == woke, c.done == done, c.read == read { return c }
        let layout = room.map {
            WingLayout.fitting(style: style, running: running, waiting: waiting, woke: woke, done: done, read: read,
                               maxWidth: $0)
        } ?? WingLayout(style: style, running: running, waiting: waiting, woke: woke, done: done, read: read)
        layoutCache = layout
        layoutCacheRoom = room
        return layout
    }

    /// How far left of the notch the list may reach; a longer wing runs on past it.
    static let listReach: CGFloat = 300

    /// Width of the black wing; zero when there is nothing to show.
    func wingWidth(running: Int, waiting: Int, woke: Int = 0, done: Int, read: Int = 0) -> CGFloat {
        Self.wingWidth(content: wingLayout(running: running, waiting: waiting, woke: woke, done: done, read: read).width)
    }

    /// Space before the wing's first figure and after its last (where the notch begins, if any).
    static let wingLead: CGFloat = 12
    static let wingTrail: CGFloat = 10

    static func wingWidth(content: CGFloat) -> CGFloat {
        content == 0 ? 0 : wingLead + content + wingTrail
    }

    /// How far right of center the pill may reach without a notch, so status items stay visible.
    static let pillReach: CGFloat = expandedWidth / 2

    /// The wing's left edge: grown out of the notch's left edge, or without a notch, centered
    /// until it reaches `pillReach`, then growing left only.
    func wingMinX(_ wing: CGFloat) -> CGFloat {
        let g = geometry
        if g.hasNotch { return g.notchMinX - wing }
        return min(g.notchMidX - wing / 2, g.notchMidX + Self.pillReach - wing).rounded()
    }

    /// The notch plus its wing, in panel-local coordinates.
    func collapsedRect(running: Int, waiting: Int, woke: Int = 0, done: Int, read: Int = 0) -> CGRect {
        let g = geometry
        let wing = wingWidth(running: running, waiting: waiting, woke: woke, done: done, read: read)
        return CGRect(x: wingMinX(wing), y: 0, width: g.notchWidth + wing, height: g.notchHeight)
    }

    /// The black shape's frame in panel-local coordinates.
    /// The list holds the woken, done, and read threads.
    func shapeRect(running: Int, waiting: Int, woke: Int = 0, done: Int, read: Int = 0) -> CGRect {
        let g = geometry
        let wing = wingWidth(running: running, waiting: waiting, woke: woke, done: done, read: read)
        if !expanded { return collapsedRect(running: running, waiting: waiting, woke: woke, done: done, read: read) }
        let listed = woke + done + read
        // Reaches left over a short wing but no further right than usual, so status items stay visible.
        let half = Self.expandedWidth / 2
        let minX = min(g.notchMidX - half, max(wingMinX(wing), g.notchMinX - Self.listReach))
        let rows = max(1, min(listed, Self.maxRows))
        let more = listed > Self.maxRows ? Self.moreHeight : 0
        let height = g.notchHeight + 6 + CGFloat(rows) * Self.rowHeight + more + Self.footerHeight + 4
        return CGRect(x: minX, y: 0, width: g.notchMidX + half - minX, height: height)
    }
}

/// CodeIsland's NotchPanelShape (wxtsky/CodeIsland, NotchPanelView.swift), with separate left and
/// right "ears" so the collapsed wing flares only on its outer side and sits flush with the notch
/// (without a notch, the pill flares on both).
struct NotchShape: Shape {
    var leftExtension: CGFloat
    var rightExtension: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(leftExtension, rightExtension), bottomRadius) }
        set {
            leftExtension = newValue.first.first
            rightExtension = newValue.first.second
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let l = leftExtension, r = rightExtension
        let br = min(bottomRadius, rect.width / 4, rect.height / 2)
        let k: CGFloat = 0.62
        var p = Path()
        p.move(to: CGPoint(x: rect.minX - l, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX + r, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                   control1: CGPoint(x: rect.maxX + r * 0.35, y: rect.minY),
                   control2: CGPoint(x: rect.maxX, y: rect.minY + r * 0.35))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addCurve(to: CGPoint(x: rect.maxX - br, y: rect.maxY),
                   control1: CGPoint(x: rect.maxX, y: rect.maxY - br * (1 - k)),
                   control2: CGPoint(x: rect.maxX - br * (1 - k), y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + br, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - br),
                   control1: CGPoint(x: rect.minX + br * (1 - k), y: rect.maxY),
                   control2: CGPoint(x: rect.minX, y: rect.maxY - br * (1 - k)))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + l))
        p.addCurve(to: CGPoint(x: rect.minX - l, y: rect.minY),
                   control1: CGPoint(x: rect.minX, y: rect.minY + l * 0.35),
                   control2: CGPoint(x: rect.minX - l * 0.35, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var store: Store
    @ObservedObject var state: NotchState
    var open: (AgentThread) -> Void
    var hide: () -> Void

    var body: some View {
        let running = store.runningCount
        let waiting = store.waitingCount
        let woke = store.woke.count, done = store.done.count, read = store.read.count
        let g = state.geometry
        let rect = state.shapeRect(running: running, waiting: waiting, woke: woke, done: done, read: read)
        let wing = state.wingWidth(running: running, waiting: waiting, woke: woke, done: done, read: read)
        let visible = state.expanded || wing > 0

        let strip = state.collapsedRect(running: running, waiting: waiting, woke: woke, done: done, read: read)

        ZStack(alignment: .topLeading) {
            // The wing itself, for when it runs past the list's left edge.
            NotchShape(leftExtension: 5, rightExtension: g.hasNotch ? 0 : 5, bottomRadius: 9)
                .fill(Color.black)
                .frame(width: strip.width, height: strip.height)
                .offset(x: strip.minX)
                .opacity(wing > 0 ? 1 : 0)

            NotchShape(leftExtension: state.expanded ? 10 : 5,
                       rightExtension: state.expanded ? 10 : (g.hasNotch ? 0 : 5),
                       bottomRadius: state.expanded ? 18 : 9)
                .fill(Color.black)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX)
                .opacity(visible ? 1 : 0)

            Group {
                // ImageRenderer can't draw AppKit views; `--render` composites the layers itself.
                if renderDir == nil {
                    WingView(layout: state.wingLayout(running: running, waiting: waiting, woke: woke, done: done, read: read),
                             height: g.notchHeight)
                } else {
                    Color.clear
                }
            }
            .frame(width: max(wing - NotchState.wingLead - NotchState.wingTrail, 0), height: g.notchHeight)
            .offset(x: state.wingMinX(wing) + NotchState.wingLead)
            .opacity(wing > 0 ? (store.connected ? 1 : 0.35) : 0)

            if state.expanded {
                DoneList(store: store, done: store.finished, open: open, hide: hide, now: Date())
                    .frame(width: rect.width - 20)
                    .offset(x: rect.minX + 10, y: g.notchHeight + 6)
                    .transition(.opacity)
            }
        }
        .frame(width: g.panelSize.width, height: g.panelSize.height, alignment: .topLeading)
        .animation(.spring(response: 0.18, dampingFraction: 0.86), value: state.expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: wing)
        .environment(\.colorScheme, .dark)
    }
}

struct DoneList: View {
    @ObservedObject var store: Store
    let done: [AgentThread]
    let open: (AgentThread) -> Void
    let hide: () -> Void
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            list
            HideButton(action: hide)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: NotchState.footerHeight)
        }
    }

    @ViewBuilder private var list: some View {
        VStack(spacing: 0) {
            if done.isEmpty {
                Text(store.connected ? "Nothing finished" : "Not connected to T3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: NotchState.rowHeight)
            } else {
                ForEach(done.prefix(NotchState.maxRows), id: \.key) { t in
                    Row(thread: t, kind: store.woke.contains(t) ? .woke : store.read.contains(t) ? .read : .done,
                        project: store.projectName(t.projectId), now: now) { open(t) }
                }
                if done.count > NotchState.maxRows {
                    Text("+\(done.count - NotchState.maxRows) more")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, minHeight: NotchState.moreHeight)
                }
            }
        }
    }
}

/// Takes the notch off the menu bar for a minute, so the menu items under the wing can be used.
private struct HideButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "eye.slash")
                Text("Hide for a minute")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(hover ? 0.85 : 0.38))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(hover ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct Row: View {
    enum Kind { case woke, done, read }
    let thread: AgentThread
    let kind: Kind
    let project: String
    let now: Date
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(thread.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(kind == .read ? 0.6 : 0.92))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(project)
                    .lineLimit(1)
                    .frame(maxWidth: 96, alignment: .trailing)
                Text(age(kind == .woke ? thread.wokeAt(now: now) : thread.latestRunCompletedAt))
                    .monospacedDigit()
                    .frame(width: 26, alignment: .trailing)
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.42))
            .padding(.horizontal, 8)
            .frame(height: NotchState.rowHeight)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hover ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    // T3's sidebar: red for failed, amber for "Limited" (failed on a usage limit), green for done.
    // Woken ones are orange, like their figures; read ones fade.
    private var dotColor: Color {
        let color = if kind == .woke {
            Color(red: 1, green: 0.62, blue: 0.25)
        } else if !thread.isFailed {
            Color(red: 0.35, green: 0.85, blue: 0.5)
        } else {
            thread.isUsageLimited ? Color(red: 1, green: 0.75, blue: 0.3) : Color(red: 1, green: 0.4, blue: 0.4)
        }
        return kind == .read ? color.opacity(0.4) : color
    }

    private func age(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
