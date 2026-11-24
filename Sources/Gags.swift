import AppKit
import QuartzCore

/// Easter eggs: once in a long while a critter does a little bit for a few seconds, then carries
/// on. Each figure has one gag, picked by its group and its place in the group, and plays it at
/// the end of every cycle of `gap` plus its length; staggered phases keep a crowded wing from
/// playing them all at once.
///
/// - Running: puts on shades, or headphones with notes floating off.
/// - Waiting: smokes a cigar and blows a smoke ring, or reads the paper and peeks over it.
/// - Woke: sips a coffee.
/// - Done: blows a bubble that pops and startles it.
/// - Read: dreams of a heart.
///
/// Like the rest of the wing, it's all Core Animation loops: no timers, no per-frame work.
extension WingLayout {
    enum Gag: CaseIterable {
        case shades, headphones, cigar, paper, coffee, bubble, dream

        /// How long the gag plays, and the seconds between two plays of it.
        var timing: (length: CFTimeInterval, gap: CFTimeInterval) {
            switch self {
            case .shades: (6, 55)
            case .headphones: (7, 60)
            case .cigar: (9, 45)
            case .paper: (8, 65)
            case .coffee: (6, 45)
            case .bubble: (5, 40)
            case .dream: (4, 70)
            }
        }
    }

    /// Overrides every gag's gap, so the demo can show them all in a few seconds.
    static var gagGap: CFTimeInterval?

    static func gag(for group: Group, index: Int) -> Gag {
        let even = index.isMultiple(of: 2)
        return switch group {
        case .running: even ? .shades : .headphones
        case .waiting: even ? .cigar : .paper
        case .woke: .coffee
        case .done: .bubble
        case .read: .dream
        }
    }

    /// When a gag plays within its cycle: its last `length` seconds.
    struct GagClock {
        let length: CFTimeInterval
        let period: CFTimeInterval
        let offset: CFTimeInterval

        init(_ gag: Gag, index: Int) {
            length = gag.timing.length
            period = length + (WingLayout.gagGap ?? gag.timing.gap)
            // Each gag starts its group's figures at their own spot in the cycle, and each kind of
            // gag sits elsewhere in it, so two gags rarely line up.
            let salt = Double(Gag.allCases.firstIndex(of: gag) ?? 0) * 0.13 * period
            offset = WingLayout.phase(index, period) + salt
        }

        /// The key time `s` seconds into the gag.
        func t(_ s: Double) -> NSNumber { NSNumber(value: (period - length + min(max(s, 0), length)) / period) }

        /// A stepped track: each (seconds into the gag, value) holds until the next, and `rest`
        /// holds outside the gag.
        func track(_ keyPath: String, _ frames: [(Double, Double)], rest: Double = 0) -> CAKeyframeAnimation {
            var values = [rest], times: [NSNumber] = [0]
            for (s, v) in frames {
                times.append(t(s))
                values.append(v)
            }
            values.append(rest)
            times.append(t(length))
            times.append(1)
            return WingLayout.keys(keyPath, values, times)
        }

        /// Shown from `from` to `to` seconds into the gag.
        func shown(_ from: Double, _ to: Double) -> CAKeyframeAnimation { track("opacity", [(from, 1), (to, 0)]) }

        /// Plays `tracks` on `layer` once per cycle.
        func play(_ layer: CALayer, _ tracks: [CAKeyframeAnimation]) {
            layer.add(WingLayout.loop(tracks, duration: period, offset: offset), forKey: "gag")
        }

        /// Something rising a point per `step` from each of `starts`, drifting sideways by
        /// `sway` and fading out over `steps` steps.
        func rise(_ layer: CALayer, starts: [Double], steps: Int, step: Double, sway: [Double] = [0],
                  scale: [Double]? = nil, from opacity: Double = 1) {
            var x: [(Double, Double)] = [], y: [(Double, Double)] = [], o: [(Double, Double)] = []
            var s: [(Double, Double)] = []
            for start in starts {
                for i in 0..<steps {
                    let at = start + Double(i) * step
                    x.append((at, sway[i % sway.count]))
                    y.append((at, Double(i)))
                    o.append((at, opacity * (1 - Double(i) / Double(steps))))
                    if let scale { s.append((at, scale[min(i, scale.count - 1)])) }
                }
                let end = start + Double(steps) * step
                x.append((end, 0)); y.append((end, 0)); o.append((end, 0))
                if scale != nil { s.append((end, 1)) }
            }
            var tracks = [track("transform.translation.x", x), track("transform.translation.y", y), track("opacity", o)]
            if scale != nil { tracks.append(track("transform.scale", s, rest: 1)) }
            play(layer, tracks)
        }
    }

    /// Adds `gag`'s props to a critter. Props sit in `root` (y-up, in points), unless they should
    /// breathe with the `body` or glance with the `eyes`.
    static func addGag(_ gag: Gag, root: CALayer, body: CALayer, eyes: CALayer, color: NSColor, index: Int,
                       headroom: CGFloat) {
        let clock = GagClock(gag, index: index)
        // Room to float things up into above the critter's 12 points.
        let sky = Int(max(3, min(8, headroom - 2)))
        switch gag {
        case .shades:
            // Deal with it: they drop onto its eyes, a glint runs across, and they lift off.
            // Dark slate rather than black, so they read as glasses and not as holes in the wing.
            let lens = NSColor(red: 0.16, green: 0.17, blue: 0.24, alpha: 1)
            let shades = prop([R(3, 7, 10, 1), R(3, 5, 4, 2), R(9, 5, 4, 2)], lens, in: body)
            let shine = prop([R(4, 6, 1, 1), R(10, 6, 1, 1)], NSColor(white: 0.55, alpha: 1), in: shades)
            shine.opacity = 1
            let glint = prop([R(4, 6, 2, 1), R(10, 6, 2, 1), R(5, 7, 1, 1), R(11, 7, 1, 1)], .white, in: shades)
            let drop = [(0.0, 8.0), (0.1, 6), (0.2, 4), (0.3, 2), (0.4, 0), (5.3, 2), (5.4, 5), (5.5, 9)]
            clock.play(shades, [clock.track("transform.translation.y", drop), clock.shown(0, 5.6)])
            clock.play(glint, [clock.track("opacity", [(1.2, 1), (1.32, 0), (3.6, 1), (3.72, 0)])])
        case .headphones:
            // Vibing: headphones go on and notes float off a cup.
            let red = NSColor(red: 0.95, green: 0.3, blue: 0.35, alpha: 1)
            let band = prop([R(3, 12, 10, 1), R(2, 10, 1, 2), R(13, 10, 1, 2)], NSColor(white: 0.35, alpha: 1), in: root)
            let cups = prop([R(1, 6, 2, 4), R(13, 6, 2, 4)], red, in: root)
            clock.play(band, [clock.shown(0, 6.8)])
            clock.play(cups, [clock.shown(0, 6.8)])
            let gold = NSColor(red: 1, green: 0.85, blue: 0.35, alpha: 1)
            for (n, starts) in [[0.8, 3.0, 5.0], [1.9, 4.0]].enumerated() {
                let note = prop(n == 0 ? [R(15, 9, 2, 2), R(16, 11, 1, 3), R(17, 13, 1, 1)]
                                       : [R(15, 9, 2, 2), R(16, 11, 1, 3), R(17, 13, 2, 1), R(19, 9, 2, 2), R(20, 11, 1, 2)],
                                gold, in: root)
                clock.rise(note, starts: starts, steps: min(sky, 5), step: 0.3, sway: [0, 1, 1, 2, 2])
            }
        case .cigar:
            // A cigar at the corner of its mouth, eyes half shut. It draws on it (the ember glows),
            // a wisp curls up, and it blows a smoke ring.
            let ember = NSColor(red: 1, green: 0.32, blue: 0.08, alpha: 1)
            let smoke = NSColor(white: 0.82, alpha: 1)
            let lids = prop([R(4, 7, 2, 1), R(10, 7, 2, 1)], color, in: eyes)
            let cigar = prop([R(12, 4, 6, 2)], NSColor(red: 0.45, green: 0.26, blue: 0.13, alpha: 1), in: root)
            let band = prop([R(14, 4, 1, 2)], NSColor(red: 0.95, green: 0.75, blue: 0.25, alpha: 1), in: cigar)
            let tip = prop([R(18, 4, 1, 2)], ember, in: root)
            clock.play(lids, [clock.shown(0.3, 8.7)])
            clock.play(cigar, [clock.shown(0, 8.8)])
            band.opacity = 1
            clock.play(tip, [clock.track("opacity", [(0, 0.45), (1.0, 1), (1.8, 0.45), (4.4, 1), (5.2, 0.45), (8.8, 0)])])
            for (n, starts) in [[0.4, 2.2, 6.0], [1.3, 3.1, 7.0]].enumerated() {
                let wisp = prop([R(18, 6, 1, 1)], smoke, in: root)
                clock.rise(wisp, starts: starts, steps: sky, step: 0.22, sway: n == 0 ? [0, 0, 1, 1, 0, 0, -1, -1] : [0, 1, 1, 0, 0, 1],
                           from: 0.8)
            }
            // The ring rises from above its head, growing as it fades.
            let ring = CAShapeLayer()
            let r = CGMutablePath()
            [R(1, 0, 2, 1), R(1, 3, 2, 1), R(0, 1, 1, 2), R(3, 1, 1, 2)].forEach { r.addRect($0) }
            ring.path = r
            ring.fillColor = smoke.cgColor
            ring.contentsScale = 2
            ring.frame = CGRect(x: 6, y: 11, width: 4, height: 4)
            ring.opacity = 0
            root.addSublayer(ring)
            clock.rise(ring, starts: [5.6], steps: min(sky, 6), step: 0.3, sway: [0, 0, 1, 1, 1, 2],
                       scale: [1, 1, 1.25, 1.25, 1.5, 1.5], from: 0.9)
        case .paper:
            // Reads the paper while it waits, peeks over it, and turns the page.
            let paper = prop([R(0, 2, 16, 7)], NSColor(white: 0.92, alpha: 1), in: root)
            let text = prop([R(2, 7, 12, 1), R(2, 5, 5, 1), R(9, 5, 5, 1), R(2, 3, 5, 1), R(9, 3, 4, 1)],
                            NSColor(white: 0.5, alpha: 1), in: paper)
            let fold = prop([R(8, 2, 0.5, 7)], NSColor(white: 0.7, alpha: 1), in: paper)
            fold.opacity = 1
            clock.play(paper, [clock.shown(0, 7.8),
                               clock.track("transform.translation.y", [(0, -2), (0.15, 0), (3.0, -3), (4.6, 0), (7.6, -2)])])
            clock.play(text, [clock.track("opacity", [(0, 1), (5.8, 0), (6.0, 1)])])
        case .coffee:
            // Holds a mug that steams, and takes a sip.
            let mug = prop([R(11, 1, 4, 4), R(15, 2, 1, 1), R(15, 4, 1, 1), R(16, 2, 1, 3)],
                           NSColor(white: 0.95, alpha: 1), in: root)
            let stripe = prop([R(11, 3, 4, 1)], NSColor(red: 0.85, green: 0.3, blue: 0.3, alpha: 1), in: mug)
            stripe.opacity = 1
            clock.play(mug, [clock.shown(0, 5.8),
                             clock.track("transform.translation.y", [(0, 0), (2.6, 2), (3.4, 0)]),
                             clock.track("transform.translation.x", [(0, 0), (2.6, -1), (3.4, 0)])])
            for (n, starts) in [[0.3, 1.7, 3.8], [0.9, 4.4]].enumerated() {
                let steam = prop([R(n == 0 ? 12 : 14, 6, 1, 1)], NSColor(white: 0.8, alpha: 1), in: root)
                clock.rise(steam, starts: starts, steps: min(sky, 5), step: 0.25, sway: [0, 1, 0, -1, 0], from: 0.7)
            }
        case .bubble:
            // A bubble swells from its nose with its breaths, then pops, and it wakes for a moment.
            let bubble = CAShapeLayer()
            bubble.path = CGPath(ellipseIn: CGRect(x: 0.5, y: 0.5, width: 5, height: 5), transform: nil)
            bubble.fillColor = NSColor(white: 1, alpha: 0.18).cgColor
            bubble.strokeColor = NSColor(red: 0.75, green: 1, blue: 0.85, alpha: 0.85).cgColor
            bubble.lineWidth = 1
            bubble.contentsScale = 2
            bubble.frame = CGRect(x: 14, y: 2, width: 6, height: 6)
            bubble.opacity = 0
            body.addSublayer(bubble)
            let sizes = [0.35, 0.5, 0.65, 0.5, 0.7, 0.85, 0.7, 0.9, 1.05, 1.2]
            clock.play(bubble, [clock.shown(0, 3.6),
                                clock.track("transform.scale", sizes.enumerated().map { (Double($0) * 0.35, $1) }, rest: 1)])
            let shine = NSColor(red: 0.75, green: 1, blue: 0.85, alpha: 1)
            for (dx, dy) in [(-1.0, 1.0), (1, 1), (1, -1), (-1, -1)] {
                let drop = prop([R(16.5, 4.5, 1, 1)], shine, in: root)
                clock.play(drop, [clock.shown(3.6, 4.0),
                                  clock.track("transform.translation.x", [(3.6, dx * 2), (3.8, dx * 4)]),
                                  clock.track("transform.translation.y", [(3.6, dy * 2), (3.8, dy * 4)])])
            }
            let startled = prop([R(4, 6, 2, 2), R(10, 6, 2, 2)], .black, in: eyes)
            clock.play(startled, [clock.shown(3.6, 4.4)])
        case .dream:
            // Dreams of something nice.
            let heart = prop([R(8, 13, 1, 1), R(10, 13, 1, 1), R(7, 12, 5, 1), R(8, 11, 3, 1), R(9, 10, 1, 1)],
                             NSColor(red: 0.55, green: 0.22, blue: 0.32, alpha: 1), in: root)
            clock.rise(heart, starts: [0.2], steps: min(sky, 6), step: 0.55, sway: [0, 0, 1, 1, 0, 0])
        }
    }

    private static func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// A hidden prop of `rects` in `parent`, sharing its frame.
    private static func prop(_ rects: [CGRect], _ color: NSColor, in parent: CALayer) -> CAShapeLayer {
        let path = CGMutablePath()
        rects.forEach { path.addRect($0) }
        let s = CAShapeLayer()
        s.path = path
        s.fillColor = color.cgColor
        s.contentsScale = 2
        s.frame = CGRect(origin: .zero, size: parent.bounds.size)
        s.opacity = 0
        parent.addSublayer(s)
        return s
    }
}
