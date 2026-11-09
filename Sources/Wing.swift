import AppKit
import QuartzCore
import SwiftUI

/// How the left wing shows agents: one shape per agent, blue while working, grey while waiting,
/// orange when woken from a snooze, green when done, dim green once you've read it.
enum WingStyle: String, CaseIterable {
    /// Pixel creatures: workers trot in place, waiting ones stand and glance around, finished ones
    /// doze until you open them.
    case critters
    /// Bars: workers bounce like audio levels, waiting ones idle at half height, finished ones
    /// rest as short green bars.
    case equalizer
}

private let blue = NSColor(red: 0.45, green: 0.75, blue: 1, alpha: 1)
private let green = NSColor(red: 0.35, green: 0.85, blue: 0.5, alpha: 1)
private let grey = NSColor(white: 0.62, alpha: 1)
private let orange = NSColor(red: 1, green: 0.62, blue: 0.25, alpha: 1)
private let dimGreen = NSColor(red: 0.35, green: 0.85, blue: 0.5, alpha: 0.4)

/// What sits where in the wing, in points from its left edge. Shared by the SwiftUI sizing and
/// the layer drawing so the black shape always fits its contents.
struct WingLayout: Equatable {
    /// The groups, left to right.
    enum Group { case running, waiting, woke, done, read }
    enum Item: Equatable {
        case runner, waiter, waker, sleeper, dozer, bar, idleBar, wokeBar, restingBar, readBar
        case more(Int, Group)
    }
    struct Placed: Equatable {
        let item: Item
        let x: CGFloat
        let width: CGFloat
    }

    let style: WingStyle
    let running: Int
    let waiting: Int
    let woke: Int
    let done: Int
    let read: Int
    let items: [Placed]
    let width: CGFloat

    static let px: CGFloat = 2 // one critter pixel
    static let critterSize = CGSize(width: 8 * px, height: 6 * px)
    static let barWidth: CGFloat = 3
    static let barMax: CGFloat = 16
    static let moreFont = NSFont.systemFont(ofSize: 10, weight: .bold)

    init(style: WingStyle, running: Int, waiting: Int, woke: Int = 0, done: Int, read: Int = 0,
         maxFigures: Int = Self.maxFigures) {
        self.style = style
        self.running = running
        self.waiting = waiting
        self.woke = woke
        self.done = done
        self.read = read
        let (shapeWidth, gap): (CGFloat, CGFloat) = switch style {
        case .critters: (Self.critterSize.width, 4)
        case .equalizer: (Self.barWidth, 3)
        }
        let caps = Self.slots([running, waiting, woke, done, read], max: maxFigures)
        var items: [Placed] = []
        var x: CGFloat = 0
        func add(_ item: Item, _ w: CGFloat, gap: CGFloat) {
            if !items.isEmpty { x += gap }
            items.append(Placed(item: item, x: x, width: w))
            x += w
        }
        let groups: [(Int, Int, Group)] = [(running, caps[0], .running), (waiting, caps[1], .waiting),
                                           (woke, caps[2], .woke), (done, caps[3], .done), (read, caps[4], .read)]
        for (count, cap, group) in groups where count > 0 {
            let shape: Item = switch (style, group) {
            case (.critters, .running): .runner
            case (.critters, .waiting): .waiter
            case (.critters, .woke): .waker
            case (.critters, .done): .sleeper
            case (.critters, .read): .dozer
            case (.equalizer, .running): .bar
            case (.equalizer, .waiting): .idleBar
            case (.equalizer, .woke): .wokeBar
            case (.equalizer, .done): .restingBar
            case (.equalizer, .read): .readBar
            }
            for i in 0..<min(count, cap) { add(shape, shapeWidth, gap: i == 0 ? 7 : gap) }
            if count > cap {
                let text = "+\(count - cap)"
                let w = ceil(NSAttributedString(string: text, attributes: [.font: Self.moreFont]).size().width)
                add(.more(count - cap, group), w, gap: 3)
            }
        }
        self.items = items
        width = x
    }

    /// At most this many figures in a pill without a notch; the rest show as a "+N" per group.
    static let maxFigures = 10

    /// The layout with as many figures as fit in `maxWidth` points. Every group with agents keeps
    /// one figure, so a very narrow room can still overflow.
    static func fitting(style: WingStyle, running: Int, waiting: Int, woke: Int = 0, done: Int, read: Int = 0,
                        maxWidth: CGFloat) -> WingLayout {
        let total = running + waiting + woke + done + read
        let stride: CGFloat = style == .critters ? critterSize.width + 4 : barWidth + 3
        var n = min(total, Int(max(maxWidth, 0) / stride) + 1)
        while true {
            let layout = WingLayout(style: style, running: running, waiting: waiting, woke: woke, done: done, read: read,
                                    maxFigures: n)
            if layout.width <= maxWidth || n <= 0 { return layout }
            n -= 1
        }
    }

    /// How many figures each group gets: all of them while the total fits in `max`, else every
    /// non-empty group keeps one and the rest go, one at a time, to the group with the most left
    /// out (earlier groups win ties).
    static func slots(_ counts: [Int], max limit: Int = maxFigures) -> [Int] {
        var slots = counts.map { min(max($0, 0), 1) }
        var left = limit - slots.reduce(0, +)
        while left > 0 {
            var pick: Int?
            for i in counts.indices where counts[i] > slots[i] {
                if pick.map({ counts[i] - slots[i] > counts[$0] - slots[$0] }) ?? true { pick = i }
            }
            guard let i = pick else { break }
            slots[i] += 1
            left -= 1
        }
        return slots
    }

    /// The widest this style's pill content gets: every group shown plus a long "+N" on each.
    static func widest(_ style: WingStyle) -> CGFloat {
        WingLayout(style: style, running: 9999, waiting: 9999, woke: 9999, done: 9999, read: 9999).width
    }

    static func color(_ group: Group) -> NSColor {
        switch group {
        case .running: blue
        case .waiting: grey
        case .woke: orange
        case .done: green
        case .read: dimGreen
        }
    }

    /// Fills `root` (y-up, `height` tall) with the wing's layers and their animations.
    func build(into root: CALayer, height: CGFloat) {
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        var runnerIndex = 0, waiterIndex = 0, wakerIndex = 0, sleeperIndex = 0, dozerIndex = 0
        var barIndex = 0, idleIndex = 0, wokeBarIndex = 0
        for p in items {
            switch p.item {
            case .runner:
                root.addSublayer(Self.critter(x: p.x, height: height, group: .running, index: runnerIndex))
                runnerIndex += 1
            case .waiter:
                root.addSublayer(Self.critter(x: p.x, height: height, group: .waiting, index: waiterIndex))
                waiterIndex += 1
            case .waker:
                root.addSublayer(Self.critter(x: p.x, height: height, group: .woke, index: wakerIndex))
                wakerIndex += 1
            case .sleeper:
                root.addSublayer(Self.critter(x: p.x, height: height, group: .done, index: sleeperIndex))
                sleeperIndex += 1
            case .dozer:
                root.addSublayer(Self.critter(x: p.x, height: height, group: .read, index: dozerIndex))
                dozerIndex += 1
            case .bar:
                root.addSublayer(Self.bar(x: p.x, height: height, index: barIndex))
                barIndex += 1
            case .idleBar:
                root.addSublayer(Self.idleBar(x: p.x, height: height, color: grey, index: idleIndex))
                idleIndex += 1
            case .wokeBar:
                root.addSublayer(Self.idleBar(x: p.x, height: height, color: orange, index: wokeBarIndex))
                wokeBarIndex += 1
            case .restingBar, .readBar:
                let bar = CALayer()
                bar.frame = CGRect(x: p.x, y: (height - 4) / 2, width: Self.barWidth, height: 4)
                bar.backgroundColor = (p.item == .readBar ? dimGreen : green).cgColor
                bar.cornerRadius = 1.5
                root.addSublayer(bar)
            case .more(let n, let group):
                let text = CATextLayer()
                text.string = "+\(n)"
                text.font = Self.moreFont
                text.fontSize = Self.moreFont.pointSize
                text.foregroundColor = Self.color(group).cgColor
                text.contentsScale = 2
                text.frame = CGRect(x: p.x, y: (height - 13) / 2, width: p.width + 1, height: 13)
                root.addSublayer(text)
            }
        }
    }

    // MARK: Critters

    private static let body = ["..XXXX..", ".XXXXXX.", ".XoXXoX.", "XXXXXXXX", ".XXXXXX."]

    /// An 8x6 pixel creature. Rows are listed top-down; layers are y-up.
    private static func critter(x: CGFloat, height: CGFloat, group: Group, index: Int) -> CALayer {
        let size = critterSize
        let root = CALayer()
        root.frame = CGRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
        let color = Self.color(group)
        // Woken ones stand and glance around like waiting ones; read ones doze without the z.
        let asleep = group == .done || group == .read
        let looks = group == .waiting || group == .woke
        func pixel(_ col: Int, _ row: Int, _ path: CGMutablePath, dy: CGFloat = 0, h: CGFloat = px) {
            path.addRect(CGRect(x: CGFloat(col) * px, y: CGFloat(5 - row) * px + dy, width: px, height: h))
        }
        // A runner's eyes are holes in its skin. A waiter's sit on solid skin so they can shift.
        let skin = CGMutablePath(), eyes = CGMutablePath()
        for (row, line) in body.enumerated() {
            for (col, c) in line.enumerated() where c != "." {
                if c == "o" && group == .running { pixel(col, row, eyes) } else { pixel(col, row, skin) }
                if c == "o" && looks { pixel(col, row, eyes) }
                // Closed eyes: a thin dark lid across the lower half of the eye pixel.
                if c == "o" && asleep { pixel(col, row, eyes, h: px / 2) }
            }
        }
        root.addSublayer(shape(skin, color))
        let eyeLayer = shape(eyes, .black)
        root.addSublayer(eyeLayer)

        let legsA = CGMutablePath(), legsB = CGMutablePath()
        pixel(1, 5, legsA); pixel(6, 5, legsA)
        pixel(2, 5, legsB); pixel(5, 5, legsB)
        let b = shape(legsB, color)
        root.addSublayer(b)

        if looks {
            // Stands still and glances left, then right, now and then.
            let glance = flip("transform.translation.x", [0, 0, 0, -1, -1, 0, 0, 0, 1, 1])
            eyeLayer.add(loop([glance], duration: 4, offset: phase(index, 4)), forKey: "glance")
        } else if group == .read {
            // No z: just lying there.
        } else if asleep {
            let z = CATextLayer()
            z.string = "z"
            z.font = NSFont.monospacedSystemFont(ofSize: 7, weight: .bold)
            z.fontSize = 7
            z.foregroundColor = green.cgColor
            z.contentsScale = 2
            z.frame = CGRect(x: size.width - 3, y: size.height - 4, width: 6, height: 9)
            z.opacity = 0
            let drift = CABasicAnimation(keyPath: "transform.translation")
            drift.fromValue = NSValue(size: .zero)
            drift.toValue = NSValue(size: CGSize(width: 4, height: 7))
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 0]
            fade.keyTimes = [0, 0.3, 1]
            z.add(loop([drift, fade], duration: 2.2, offset: phase(index, 2.2)), forKey: "z")
            root.addSublayer(z)
        } else {
            let a = shape(legsA, color)
            b.opacity = 0 // the walk animation swaps the pairs
            root.addSublayer(a)
            // Two-frame walk: swap leg pairs and bob up a point on each step. A step flips twice,
            // so spread the phases over half of it, or pairs would flip together, mirrored.
            let step = 0.36, offset = phase(index, step / 2)
            a.add(loop([flip("opacity", [1, 0])], duration: step, offset: offset), forKey: "walk")
            b.add(loop([flip("opacity", [0, 1])], duration: step, offset: offset), forKey: "walk")
            root.add(loop([flip("transform.translation.y", [0, 1])], duration: step, offset: offset), forKey: "hop")
        }
        return root
    }

    private static func shape(_ path: CGPath, _ color: NSColor) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.path = path
        s.fillColor = color.cgColor
        s.contentsScale = 2
        s.frame = CGRect(origin: .zero, size: critterSize)
        return s
    }

    /// Jumps between values in equal steps, no tweening (pixel-art frames).
    private static func flip(_ keyPath: String, _ values: [Double]) -> CAKeyframeAnimation {
        let k = CAKeyframeAnimation(keyPath: keyPath)
        k.values = values
        k.calculationMode = .discrete
        return k
    }

    // MARK: Equalizer

    /// A half-height bar that slowly dims and brightens.
    private static func idleBar(x: CGFloat, height: CGFloat, color: NSColor, index: Int) -> CALayer {
        let bar = CALayer()
        bar.frame = CGRect(x: x, y: (height - 8) / 2, width: barWidth, height: 8)
        bar.backgroundColor = color.cgColor
        bar.cornerRadius = 1.5
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.45
        let anim = loop([breathe], duration: 1.4, offset: phase(index, 2.8))
        anim.autoreverses = true
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.add(anim, forKey: "breathe")
        return bar
    }

    private static let tempos: [CFTimeInterval] = [0.45, 0.3, 0.58, 0.38, 0.5, 0.34, 0.62, 0.42, 0.54, 0.32]

    private static func bar(x: CGFloat, height: CGFloat, index: Int) -> CALayer {
        let bar = CALayer()
        bar.frame = CGRect(x: x, y: (height - barMax) / 2, width: barWidth, height: barMax)
        bar.backgroundColor = blue.cgColor
        bar.cornerRadius = 1.5
        let bounce = CABasicAnimation(keyPath: "bounds.size.height")
        bounce.fromValue = 4
        bounce.toValue = barMax
        let tempo = tempos[index % tempos.count]
        let anim = loop([bounce], duration: tempo, offset: phase(index, 2 * tempo))
        anim.autoreverses = true
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.add(anim, forKey: "bounce")
        return bar
    }

    /// Where figure `index` starts in a cycle of `period` seconds: each of ten neighbouring figures
    /// in a group gets its own tenth of the cycle, and the first few sit far apart. Each further
    /// run of ten shifts by a hundredth, so a long wing doesn't repeat every ten figures.
    private static func phase(_ index: Int, _ period: CFTimeInterval) -> CFTimeInterval {
        let tenths = [0, 5, 2, 7, 4, 9, 1, 6, 3, 8]
        let run = Double(tenths[(index / 10) % tenths.count]) / 10
        return (Double(tenths[index % tenths.count]) + run) / 10 * period
    }

    /// Groups animations into one forever-repeating cycle, phase-shifted by `offset` seconds.
    private static func loop(_ animations: [CAAnimation], duration: CFTimeInterval, offset: CFTimeInterval) -> CAAnimationGroup {
        let g = CAAnimationGroup()
        animations.forEach { $0.duration = duration }
        g.animations = animations
        g.duration = duration
        g.repeatCount = .infinity
        g.timeOffset = offset
        // A fixed start in media time, so rebuilding the layers when a count changes keeps each
        // figure's phase instead of restarting them all in step.
        g.beginTime = 1
        g.isRemovedOnCompletion = false
        return g
    }
}

/// Hosts the wing layers. Core Animation runs them in the window server, so the app does no
/// per-frame work (a SwiftUI animation here redrew at 120 Hz, about 9% CPU).
struct WingView: NSViewRepresentable {
    let layout: WingLayout
    let height: CGFloat

    final class Host: NSView {
        var built: (WingLayout, CGFloat)?
    }

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: Host, context: Context) {
        if let built = view.built, built.0 == layout, built.1 == height { return }
        view.built = (layout, height)
        guard let root = view.layer else { return }
        layout.build(into: root, height: height)
    }
}
