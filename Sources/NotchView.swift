import AppKit
import SwiftUI

/// Where the hardware notch sits inside the panel, in panel-local points (origin top-left).
struct NotchGeometry: Equatable {
    var panelSize: CGSize
    var notchMinX: CGFloat
    var notchWidth: CGFloat
    var notchHeight: CGFloat

    var notchMidX: CGFloat { notchMinX + notchWidth / 2 }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var geometry: NotchGeometry
    @Published var expanded = false

    static let rowHeight: CGFloat = 26
    static let maxRows = 8
    static let moreHeight: CGFloat = 20
    static let expandedWidth: CGFloat = 380

    init(geometry: NotchGeometry) { self.geometry = geometry }

    /// Width of the black wing grown out of the notch's left edge; zero when there is nothing to show.
    func wingWidth(running: Int, done: Int) -> CGFloat {
        let items = [running, done].filter { $0 > 0 }
        if items.isEmpty { return 0 }
        let content = items.reduce(0) { $0 + 13 + 7 * CGFloat(String($1).count) }
        return 12 + content + CGFloat(items.count - 1) * 8 + 8
    }

    /// The notch plus its wing, in panel-local coordinates.
    func collapsedRect(running: Int, done: Int) -> CGRect {
        let g = geometry
        let wing = wingWidth(running: running, done: done)
        return CGRect(x: g.notchMinX - wing, y: 0, width: g.notchWidth + wing, height: g.notchHeight)
    }

    /// The black shape's frame in panel-local coordinates.
    func shapeRect(running: Int, done: Int) -> CGRect {
        let g = geometry
        let wing = wingWidth(running: running, done: done)
        if !expanded { return collapsedRect(running: running, done: done) }
        let half = max(Self.expandedWidth / 2, g.notchMidX - (g.notchMinX - wing))
        let rows = max(1, min(done, Self.maxRows))
        let more = done > Self.maxRows ? Self.moreHeight : 0
        let height = g.notchHeight + 6 + CGFloat(rows) * Self.rowHeight + more + 8
        return CGRect(x: g.notchMidX - half, y: 0, width: half * 2, height: height)
    }
}

/// CodeIsland's NotchPanelShape (wxtsky/CodeIsland, NotchPanelView.swift), with separate left and
/// right "ears" so the collapsed wing flares only on its outer side and sits flush with the notch.
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

    var body: some View {
        let running = store.runningCount
        let done = store.done
        let g = state.geometry
        let rect = state.shapeRect(running: running, done: done.count)
        let wing = state.wingWidth(running: running, done: done.count)
        let visible = state.expanded || wing > 0

        ZStack(alignment: .topLeading) {
            NotchShape(leftExtension: state.expanded ? 10 : 5,
                       rightExtension: state.expanded ? 10 : 0,
                       bottomRadius: state.expanded ? 18 : 9)
                .fill(Color.black)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX)
                .opacity(visible ? 1 : 0)

            Counts(running: running, done: done.count, connected: store.connected)
                .frame(width: max(wing - 8, 0), height: g.notchHeight, alignment: .leading)
                .padding(.leading, 12)
                .offset(x: g.notchMinX - wing)
                .opacity(wing > 0 ? 1 : 0)

            if state.expanded {
                DoneList(store: store, done: done, open: open, now: Date())
                    .frame(width: rect.width - 20)
                    .offset(x: rect.minX + 10, y: g.notchHeight + 6)
                    .transition(.opacity)
            }
        }
        .frame(width: g.panelSize.width, height: g.panelSize.height, alignment: .topLeading)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: wing)
        .environment(\.colorScheme, .dark)
    }
}

private struct Counts: View {
    let running: Int
    let done: Int
    let connected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if running > 0 {
                HStack(spacing: 4) {
                    Spinner().frame(width: 9, height: 9)
                    Text("\(running)").foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1))
                }
            }
            if done > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy))
                    Text("\(done)")
                }
                .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.5))
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        .opacity(connected ? 1 : 0.35)
    }
}

/// Drawn still: a forever-spinning arc would redraw the panel every frame while anything runs.
private struct Spinner: View {
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color(red: 0.45, green: 0.75, blue: 1), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .rotationEffect(.degrees(-30))
    }
}

private struct DoneList: View {
    @ObservedObject var store: Store
    let done: [AgentThread]
    let open: (AgentThread) -> Void
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            if done.isEmpty {
                Text(store.connected ? "Nothing finished" : "Not connected to T3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: NotchState.rowHeight)
            } else {
                ForEach(done.prefix(NotchState.maxRows)) { t in
                    Row(thread: t, project: store.projectName(t.projectId), now: now) { open(t) }
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

private struct Row: View {
    let thread: AgentThread
    let project: String
    let now: Date
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(thread.isFailed ? Color(red: 1, green: 0.4, blue: 0.4) : Color(red: 0.35, green: 0.85, blue: 0.5))
                    .frame(width: 6, height: 6)
                Text(thread.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(project)
                    .lineLimit(1)
                    .frame(maxWidth: 96, alignment: .trailing)
                Text(age(thread.latestRunCompletedAt))
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

    private func age(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
