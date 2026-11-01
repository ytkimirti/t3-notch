import AppKit
import QuartzCore
import SwiftUI

/// How the left wing shows agents: one shape per agent, blue while working, green when done.
enum WingStyle: String, CaseIterable {
    /// Pixel creatures: workers trot in place, finished ones doze until you open them.
    case critters
    /// Bars: workers bounce like audio levels, finished ones rest as short green bars.
    case equalizer
}

private let blue = NSColor(red: 0.45, green: 0.75, blue: 1, alpha: 1)
private let green = NSColor(red: 0.35, green: 0.85, blue: 0.5, alpha: 1)

/// What sits where in the wing, in points from its left edge. Shared by the SwiftUI sizing and
/// the layer drawing so the black shape always fits its contents.
struct WingLayout: Equatable {
    enum Item: Equatable {
        case runner, sleeper, bar, restingBar
        case more(Int, done: Bool)
    }
    struct Placed: Equatable {
        let item: Item
        let x: CGFloat
        let width: CGFloat
    }

    let style: WingStyle
    let items: [Placed]
    let width: CGFloat

    static let px: CGFloat = 2 // one critter pixel
    static let critterSize = CGSize(width: 8 * px, height: 6 * px)
    static let barWidth: CGFloat = 3
    static let barMax: CGFloat = 16
    static let moreFont = NSFont.systemFont(ofSize: 10, weight: .bold)

    init(style: WingStyle, running: Int, done: Int) {
        self.style = style
        let (shapeWidth, gap, maxRunning, maxDone): (CGFloat, CGFloat, Int, Int) = switch style {
        case .critters: (Self.critterSize.width, 4, 4, 3)
        case .equalizer: (Self.barWidth, 3, 8, 6)
        }
        var items: [Placed] = []
        var x: CGFloat = 0
        func add(_ item: Item, _ w: CGFloat, gap: CGFloat) {
            if !items.isEmpty { x += gap }
            items.append(Placed(item: item, x: x, width: w))
            x += w
        }
        for (count, cap, isDone) in [(running, maxRunning, false), (done, maxDone, true)] where count > 0 {
            let shape: Item = switch (style, isDone) {
            case (.critters, false): .runner
            case (.critters, true): .sleeper
            case (.equalizer, false): .bar
            case (.equalizer, true): .restingBar
            }
            for i in 0..<min(count, cap) { add(shape, shapeWidth, gap: i == 0 ? 7 : gap) }
            if count > cap {
                let text = "+\(count - cap)"
                let w = ceil(NSAttributedString(string: text, attributes: [.font: Self.moreFont]).size().width)
                add(.more(count - cap, done: isDone), w, gap: 3)
            }
        }
        self.items = items
        width = x
    }

    /// Fills `root` (y-up, `height` tall) with the wing's layers and their animations.
    func build(into root: CALayer, height: CGFloat) {
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        var runnerIndex = 0, sleeperIndex = 0, barIndex = 0
        for p in items {
            switch p.item {
            case .runner:
                root.addSublayer(Self.critter(x: p.x, height: height, asleep: false, index: runnerIndex))
                runnerIndex += 1
            case .sleeper:
                root.addSublayer(Self.critter(x: p.x, height: height, asleep: true, index: sleeperIndex))
                sleeperIndex += 1
            case .bar:
                root.addSublayer(Self.bar(x: p.x, height: height, index: barIndex))
                barIndex += 1
            case .restingBar:
                let bar = CALayer()
                bar.frame = CGRect(x: p.x, y: (height - 4) / 2, width: Self.barWidth, height: 4)
                bar.backgroundColor = green.cgColor
                bar.cornerRadius = 1.5
                root.addSublayer(bar)
            case .more(let n, let done):
                let text = CATextLayer()
                text.string = "+\(n)"
                text.font = Self.moreFont
                text.fontSize = Self.moreFont.pointSize
                text.foregroundColor = (done ? green : blue).cgColor
                text.contentsScale = 2
                text.frame = CGRect(x: p.x, y: (height - 13) / 2, width: p.width + 1, height: 13)
                root.addSublayer(text)
            }
        }
    }

    // MARK: Critters

    private static let body = ["..XXXX..", ".XXXXXX.", ".XoXXoX.", "XXXXXXXX", ".XXXXXX."]

    /// An 8x6 pixel creature. Rows are listed top-down; layers are y-up.
    private static func critter(x: CGFloat, height: CGFloat, asleep: Bool, index: Int) -> CALayer {
        let size = critterSize
        let root = CALayer()
        root.frame = CGRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
        let color = asleep ? green : blue
        func pixel(_ col: Int, _ row: Int, _ path: CGMutablePath, dy: CGFloat = 0, h: CGFloat = px) {
            path.addRect(CGRect(x: CGFloat(col) * px, y: CGFloat(5 - row) * px + dy, width: px, height: h))
        }
        let skin = CGMutablePath(), eyes = CGMutablePath()
        for (row, line) in body.enumerated() {
            for (col, c) in line.enumerated() where c != "." {
                if c == "o" && !asleep { pixel(col, row, eyes) } else { pixel(col, row, skin) }
                // Closed eyes: a thin dark lid across the lower half of the eye pixel.
                if c == "o" && asleep { pixel(col, row, eyes, h: px / 2) }
            }
        }
        root.addSublayer(shape(skin, color))
        root.addSublayer(shape(eyes, .black))

        let legsA = CGMutablePath(), legsB = CGMutablePath()
        pixel(1, 5, legsA); pixel(6, 5, legsA)
        pixel(2, 5, legsB); pixel(5, 5, legsB)
        let a = shape(legsA, color), b = shape(legsB, color)
        if !asleep { b.opacity = 0 } // the walk animation swaps the pairs
        root.addSublayer(b)

        if asleep {
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
            z.add(loop([drift, fade], duration: 2.2, offset: Double(index) * 0.8), forKey: "z")
            root.addSublayer(z)
        } else {
            root.addSublayer(a)
            // Two-frame walk: swap leg pairs and bob up a point on each step.
            let step = 0.36, offset = Double(index) * 0.12
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

    private static let tempos: [CFTimeInterval] = [0.45, 0.3, 0.58, 0.38, 0.5, 0.34, 0.62, 0.42]

    private static func bar(x: CGFloat, height: CGFloat, index: Int) -> CALayer {
        let bar = CALayer()
        bar.frame = CGRect(x: x, y: (height - barMax) / 2, width: barWidth, height: barMax)
        bar.backgroundColor = blue.cgColor
        bar.cornerRadius = 1.5
        let bounce = CABasicAnimation(keyPath: "bounds.size.height")
        bounce.fromValue = 4
        bounce.toValue = barMax
        let tempo = tempos[index % tempos.count]
        let anim = loop([bounce], duration: tempo, offset: Double(index) * 0.17)
        anim.autoreverses = true
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.add(anim, forKey: "bounce")
        return bar
    }

    /// Groups animations into one forever-repeating cycle, phase-shifted by `offset` seconds.
    private static func loop(_ animations: [CAAnimation], duration: CFTimeInterval, offset: CFTimeInterval) -> CAAnimationGroup {
        let g = CAAnimationGroup()
        animations.forEach { $0.duration = duration }
        g.animations = animations
        g.duration = duration
        g.repeatCount = .infinity
        g.timeOffset = offset
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
