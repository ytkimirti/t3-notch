import AppKit
import QuartzCore

/// Easter eggs: about half the agents are characters, each with a trait it keeps on for as long as
/// it stays in its group: shades, a cigar, a crown, a bird on its head. The thread's id picks the
/// trait, so an agent keeps its own: the same one each time it comes back to a group, another one
/// in each group it moves to. Most traits also do a little bit now and then (the cigar glows and
/// smokes, the bird hops and chirps).
///
/// - Working: shades, headphones, propeller beanie, ninja headband, crown, party hat, top hat,
///   bird, mustache.
/// - Waiting: cigar, newspaper, phone, bubble gum, umbrella in the rain, top hat, crown, mustache,
///   bird, shades.
/// - Woke: coffee, bubble gum, bird, crown, party hat, shades, mustache, headphones.
/// - Done (asleep): snot bubble, nightcap, halo, dreams, bird.
/// - Read (dozing, dimmed): dreams, nightcap, halo.
///
/// Like the rest of the wing, it's all Core Animation loops: no timers, no per-frame work.
extension WingLayout {
    enum Gag: String, CaseIterable {
        case shades, headphones, propeller, headband, crown, party, tophat, bird, mustache
        case cigar, paper, phone, gum, umbrella, coffee, bubble, nightcap, halo, dream
    }

    /// The traits a figure of `group` can have.
    static func gags(for group: Group) -> [Gag] {
        switch group {
        case .running: [.shades, .headphones, .propeller, .headband, .crown, .party, .tophat, .bird, .mustache]
        case .waiting: [.cigar, .paper, .phone, .gum, .umbrella, .tophat, .crown, .mustache, .bird, .shades]
        case .woke: [.coffee, .gum, .bird, .crown, .party, .shades, .mustache, .headphones]
        case .done: [.bubble, .nightcap, .halo, .dream, .bird]
        case .read: [.dream, .nightcap, .halo]
        }
    }

    /// Percent of agents that are characters.
    static let traitShare: UInt64 = 50

    /// Traits by thread, for the demo.
    static var forcedTraits: [String: Gag] = [:]

    /// The trait of `key`'s agent while in `group`, if it's a character.
    static func trait(for group: Group, key: String) -> Gag? {
        let list = gags(for: group)
        if let forced = forcedTraits[key] { return list.contains(forced) ? forced : nil }
        let seed = hash(key)
        guard seed % 100 < traitShare else { return nil }
        let salt: UInt64 = switch group {
        case .running: 1
        case .waiting: 2
        case .woke: 3
        case .done: 4
        case .read: 5
        }
        let pick = mix(seed &+ salt &* 0x9E37_79B9)
        return list[Int(pick % UInt64(list.count))]
    }

    /// FNV-1a: stable across launches, unlike `hashValue`.
    static func hash(_ key: String) -> UInt64 {
        key.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    /// splitmix64's finalizer, to spread a seed's bits.
    private static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// One cycle of a trait's little bit, repeating forever.
    struct GagClock {
        let period: CFTimeInterval
        let offset: CFTimeInterval

        /// Figures with the same trait start at their own points in the cycle.
        init(period: CFTimeInterval, index: Int, key: String) {
            self.period = period
            offset = WingLayout.phase(index, period) + Double(WingLayout.hash(key) % 1000) / 1000 * period
        }

        func t(_ s: Double) -> NSNumber { NSNumber(value: min(max(s / period, 0), 1)) }

        /// A stepped track: `rest` until the first frame, then each (seconds, value) holds until the
        /// next, the last until the cycle ends.
        func track(_ keyPath: String, _ frames: [(Double, Double)], rest: Double = 0) -> CAKeyframeAnimation {
            WingLayout.keys(keyPath, [rest] + frames.map(\.1), [0] + frames.map { t($0.0) } + [1])
        }

        /// Shown from `from` to `to` seconds into the cycle.
        func shown(_ from: Double, _ to: Double) -> CAKeyframeAnimation { track("opacity", [(from, 1), (to, 0)]) }

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

    /// Dresses a critter in `gag`. Props sit in `root` (y-up, in points; the critter is 16 by 12),
    /// unless they should breathe with the `body` or glance with the `eyes`.
    static func addGag(_ gag: Gag, root: CALayer, body: CALayer, eyes: CALayer, group: Group, index: Int, key: String,
                       headroom: CGFloat) {
        // Read critters are dimmed, and so is what they wear.
        let dim = group == .read
        func c(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
            let k = dim ? 0.45 : 1
            return NSColor(red: r * k, green: g * k, blue: b * k, alpha: 1)
        }
        func w(_ v: Double) -> NSColor { c(v, v, v) }
        func clock(_ period: CFTimeInterval) -> GagClock { GagClock(period: period, index: index, key: key) }
        // Room to float things up into above the head.
        let sky = Int(max(3, min(8, headroom - 2)))
        let gold = c(1, 0.82, 0.25)

        switch gag {
        case .shades:
            // Slate rather than black, so they read as glasses and not as holes in the wing. A glint
            // runs across now and then, and they slip down for a look over them.
            let k = clock(7)
            let shades = prop([R(3, 7, 10, 1), R(3, 5, 4, 2), R(9, 5, 4, 2)], c(0.16, 0.17, 0.24), in: body)
            prop([R(4, 6, 1, 1), R(10, 6, 1, 1)], w(0.55), in: shades)
            let glint = prop([R(4, 6, 2, 1), R(10, 6, 2, 1), R(5, 7, 1, 1), R(11, 7, 1, 1)], w(1), in: shades, hidden: true)
            k.play(glint, [k.track("opacity", [(1.2, 1), (1.32, 0), (3.6, 1), (3.72, 0)])])
            k.play(shades, [k.track("transform.translation.y", [(5.0, -1), (5.9, 0)])])
        case .headphones:
            let k = clock(4)
            prop([R(3, 12, 10, 1), R(2, 10, 1, 2), R(13, 10, 1, 2)], w(0.35), in: root)
            prop([R(1, 6, 2, 4), R(13, 6, 2, 4)], c(0.95, 0.3, 0.35), in: root)
            for (n, start) in [0.3, 2.3].enumerated() {
                let note = prop(n == 0 ? [R(15, 9, 2, 2), R(16, 11, 1, 3), R(17, 13, 1, 1)]
                                       : [R(15, 9, 2, 2), R(16, 11, 1, 3), R(17, 13, 2, 1), R(19, 9, 2, 2), R(20, 11, 1, 2)],
                                c(1, 0.85, 0.35), in: root, hidden: true)
                k.rise(note, starts: [start], steps: min(sky, 5), step: 0.3, sway: [0, 1, 1, 2, 2])
            }
        case .propeller:
            // A beanie whose propeller never stops.
            let k = GagClock(period: 0.24, index: 0, key: "")
            prop([R(5, 12, 3, 1), R(6, 13, 2, 1)], c(0.95, 0.3, 0.35), in: body)
            prop([R(8, 12, 3, 1), R(8, 13, 2, 1)], c(0.35, 0.55, 1), in: body)
            prop([R(7, 14, 2, 1)], w(0.6), in: body)
            let blade = prop([R(4, 15, 8, 1)], c(1, 0.85, 0.3), in: body)
            k.play(blade, [k.track("transform.scale.x", [(0.06, 0.5), (0.12, 0.125), (0.18, 0.5)], rest: 1)])
        case .headband:
            // A ninja's headband, its tails flapping.
            let k = clock(0.4)
            let red = c(0.9, 0.15, 0.2)
            prop([R(2, 9, 12, 1)], red, in: root)
            let up = prop([R(0, 9, 2, 1), R(-2, 10, 2, 1)], red, in: root, hidden: true)
            let down = prop([R(0, 9, 2, 1), R(-2, 8, 2, 1)], red, in: root, hidden: true)
            k.play(up, [k.shown(0, 0.2)])
            k.play(down, [k.track("opacity", [(0.2, 1)])])
        case .crown:
            let k = clock(4)
            prop([R(4, 12, 8, 2), R(4, 14, 1, 2), R(7, 14, 2, 2), R(11, 14, 1, 2)], gold, in: body)
            prop([R(7, 12, 2, 1)], c(0.9, 0.2, 0.3), in: body)
            for (x, y, at) in [(14.0, 15.0, 0.8), (2.0, 13.0, 2.6)] {
                let sparkle = prop([R(x, y, 1, 1), R(x - 1, y, 1, 1), R(x + 1, y, 1, 1), R(x, y - 1, 1, 1), R(x, y + 1, 1, 1)],
                                   w(1), in: root, hidden: true)
                k.play(sparkle, [k.shown(at, at + 0.2)])
            }
        case .party:
            // A party hat that throws confetti now and then.
            let k = clock(5)
            prop([R(6, 12, 5, 2), R(7, 14, 3, 2), R(8, 16, 1, 2)], c(0.95, 0.35, 0.75), in: body)
            prop([R(6, 13, 5, 1), R(7, 15, 3, 1)], c(1, 0.85, 0.3), in: body)
            prop([R(8, 18, 1, 1)], w(1), in: body)
            let colors = [c(1, 0.85, 0.3), c(0.4, 0.9, 1), c(1, 0.45, 0.7), c(0.5, 1, 0.5), w(1), c(1, 0.6, 0.2)]
            let arc: [Double] = [1, 2, 3, 3, 2, 1, 0, -1]
            for (i, color) in colors.enumerated() {
                let bit = prop([R(8, 18, 1, 1)], color, in: root, hidden: true)
                let dx = Double(i) - 2.5
                let start = 2.0 + Double(i % 2) * 0.05
                let steps = arc.indices.map { start + Double($0) * 0.12 }
                k.play(bit, [k.shown(start, start + Double(arc.count) * 0.12),
                             k.track("transform.translation.x", steps.enumerated().map { ($1, (dx * Double($0 + 1) / 2).rounded()) }),
                             k.track("transform.translation.y", zip(steps, arc).map { ($0, $1) })])
            }
        case .tophat:
            // A top hat it tips now and then.
            let k = clock(6)
            let hat = prop([R(3, 12, 10, 1), R(5, 13, 6, 5)], c(0.3, 0.3, 0.38), in: body)
            prop([R(5, 13, 6, 1)], c(0.85, 0.2, 0.3), in: hat)
            prop([R(5, 17, 6, 1)], c(0.45, 0.45, 0.55), in: hat)
            k.play(hat, [k.track("transform.translation.y", [(3.0, 1), (3.15, 3), (3.7, 1), (3.85, 0)])])
        case .bird:
            // A little bird on its head that hops, looks around, and sings.
            let k = clock(7)
            let bird = CALayer()
            bird.frame = CGRect(x: 4.5, y: 12, width: 7, height: 4)
            body.addSublayer(bird)
            prop([R(4, 2, 2, 2), R(0, 1, 6, 1), R(0, 2, 1, 1), R(1, 0, 4, 1)], c(1, 0.85, 0.3), in: bird)
            prop([R(5, 3, 1, 1)], w(0.05), in: bird)
            prop([R(6, 2, 1, 1)], c(1, 0.5, 0.15), in: bird)
            k.play(bird, [k.track("transform.translation.y", [(1.5, 1), (1.7, 0), (1.9, 1), (2.1, 0)]),
                          k.track("transform.scale.x", [(3.0, -1), (5.0, 1)], rest: 1)])
            let note = prop([R(12, 16, 1, 1), R(13, 17, 1, 2)], c(1, 0.85, 0.35), in: root, hidden: true)
            k.rise(note, starts: [5.6], steps: max(1, min(sky - 3, 4)), step: 0.3, sway: [0, 1, 1, 2])
        case .mustache:
            // A fine mustache that twitches now and then.
            let k = clock(5)
            let stache = prop([R(4, 5, 8, 1), R(3, 4, 3, 1), R(10, 4, 3, 1), R(2, 5, 1, 1), R(13, 5, 1, 1)],
                              c(0.35, 0.2, 0.1), in: root)
            k.play(stache, [k.track("transform.translation.y", [(2.0, 1), (2.15, 0), (2.3, 1), (2.45, 0)])])
        case .cigar:
            // A cigar at the corner of its mouth, eyes half shut. It draws on it (the ember glows),
            // smoke curls up, and it blows a smoke ring.
            let k = clock(9)
            let smoke = w(0.82)
            prop([R(4, 7, 2, 1), R(10, 7, 2, 1)], Self.color(group), in: eyes)
            let cigar = prop([R(12, 4, 6, 2)], c(0.45, 0.26, 0.13), in: root)
            prop([R(14, 4, 1, 2)], c(0.95, 0.75, 0.25), in: cigar)
            let tip = prop([R(18, 4, 1, 2)], c(1, 0.32, 0.08), in: root)
            k.play(tip, [k.track("opacity", [(1.0, 1), (1.8, 0.45), (4.4, 1), (5.2, 0.45)], rest: 0.45)])
            for (n, starts) in [[0.4, 2.2, 6.0], [1.3, 3.1, 7.0]].enumerated() {
                let wisp = prop([R(18, 6, 1, 1)], smoke, in: root, hidden: true)
                k.rise(wisp, starts: starts, steps: sky, step: 0.22, sway: n == 0 ? [0, 0, 1, 1, 0, 0, -1, -1] : [0, 1, 1, 0, 0, 1],
                       from: 0.8)
            }
            // The ring rises from above its head, growing as it fades.
            let ring = CALayer()
            ring.frame = CGRect(x: 6, y: 11, width: 4, height: 4)
            root.addSublayer(ring)
            prop([R(1, 0, 2, 1), R(1, 3, 2, 1), R(0, 1, 1, 2), R(3, 1, 1, 2)], smoke, in: ring)
            ring.opacity = 0
            k.rise(ring, starts: [5.6], steps: min(sky, 6), step: 0.3, sway: [0, 0, 1, 1, 1, 2],
                   scale: [1, 1, 1.25, 1.25, 1.5, 1.5], from: 0.9)
        case .paper:
            // Reads the paper, peeks over it, and turns the page.
            let k = clock(8)
            let paper = prop([R(0, 2, 16, 7)], w(0.92), in: root)
            let text = prop([R(2, 7, 12, 1), R(2, 5, 5, 1), R(9, 5, 5, 1), R(2, 3, 5, 1), R(9, 3, 4, 1)], w(0.5), in: paper)
            prop([R(8, 2, 0.5, 7)], w(0.7), in: paper)
            k.play(paper, [k.track("transform.translation.y", [(3.0, -3), (4.6, 0)])])
            k.play(text, [k.track("opacity", [(5.8, 0), (6.0, 1)], rest: 1)])
        case .phone:
            // Scrolls its phone, and likes something now and then.
            let k = clock(4)
            let phone = prop([R(10, 1, 4, 6)], c(0.18, 0.18, 0.22), in: root)
            prop([R(11, 2, 2, 4)], c(0.55, 0.8, 1), in: phone)
            let line = prop([R(11, 2, 2, 1)], c(0.3, 0.5, 0.75), in: phone)
            let scroll = (0..<8).map { (Double($0) * 0.25, Double($0 % 4)) }
            k.play(line, [k.track("transform.translation.y", scroll + [(2.0, 0)])])
            let heart = prop([R(11, 8, 1, 1), R(13, 8, 1, 1), R(11, 7, 3, 1), R(12, 6, 1, 1)], c(1, 0.4, 0.55), in: root,
                             hidden: true)
            k.rise(heart, starts: [2.4], steps: min(sky, 5), step: 0.25)
        case .gum:
            // Blows a bubble of gum until it pops all over its face.
            let k = clock(6)
            let pink = c(1, 0.45, 0.7)
            let bubble = CAShapeLayer()
            bubble.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 8, height: 8), transform: nil)
            bubble.fillColor = pink.cgColor
            bubble.contentsScale = 2
            bubble.frame = CGRect(x: 4, y: 1, width: 8, height: 8)
            bubble.opacity = 0
            root.addSublayer(bubble)
            prop([R(5, 5, 1, 1)], w(1), in: bubble)
            let sizes = [0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1]
            k.play(bubble, [k.shown(0, 3.4), k.track("transform.scale", sizes.enumerated().map { (Double($0) * 0.5, $1) }, rest: 1)])
            let bits = prop([R(4, 5, 1, 1), R(11, 6, 1, 1), R(7, 3, 2, 1), R(12, 3, 1, 1)], pink, in: root, hidden: true)
            k.play(bits, [k.shown(3.4, 4.8)])
        case .umbrella:
            // Waits under an umbrella in its own little rain.
            let k = clock(2)
            prop([R(8, 12, 1, 2)], w(0.6), in: root)
            prop([R(2, 14, 12, 1), R(4, 15, 8, 1), R(6, 16, 4, 1), R(8, 17, 1, 1)], c(0.9, 0.3, 0.4), in: root)
            // Drops fall from as high as the menu bar allows onto the canopy, and splash.
            let top = 12 + Double(sky) + 1
            for (i, (x, land)) in [(3.0, 15.0), (6, 17), (10, 16), (13, 15)].enumerated() {
                let fall = max(1, Int(top - land))
                let drop = prop([R(x, land + Double(fall), 1, 1)], c(0.55, 0.75, 1), in: root, hidden: true)
                let start = Double(i) * 0.5
                let steps = (0..<fall).map { (start + Double($0) * 0.1, -Double($0)) }
                let end = start + Double(fall) * 0.1
                k.play(drop, [k.shown(start, end), k.track("transform.translation.y", steps + [(end, 0)])])
                let splash = prop([R(x - 1, land, 1, 1), R(x + 1, land, 1, 1)], c(0.55, 0.75, 1), in: root, hidden: true)
                k.play(splash, [k.shown(end, end + 0.12)])
            }
        case .coffee:
            // Holds a steaming mug and takes a sip.
            let k = clock(6)
            let mug = prop([R(11, 1, 4, 4), R(15, 2, 1, 1), R(15, 4, 1, 1), R(16, 2, 1, 3)], w(0.95), in: root)
            prop([R(11, 3, 4, 1)], c(0.85, 0.3, 0.3), in: mug)
            k.play(mug, [k.track("transform.translation.y", [(2.6, 2), (3.4, 0)]),
                         k.track("transform.translation.x", [(2.6, -1), (3.4, 0)])])
            for (n, starts) in [[0.3, 1.7, 3.8], [0.9, 4.4]].enumerated() {
                let steam = prop([R(n == 0 ? 12 : 14, 6, 1, 1)], w(0.8), in: root, hidden: true)
                k.rise(steam, starts: starts, steps: min(sky, 5), step: 0.25, sway: [0, 1, 0, -1, 0], from: 0.7)
            }
        case .bubble:
            // A bubble swells from its nose with its breaths, then pops, and it wakes for a moment.
            let k = clock(6)
            let bubble = CAShapeLayer()
            bubble.path = CGPath(ellipseIn: CGRect(x: 0.5, y: 0.5, width: 5, height: 5), transform: nil)
            bubble.fillColor = NSColor(white: 1, alpha: 0.18).cgColor
            bubble.strokeColor = c(0.75, 1, 0.85).withAlphaComponent(0.85).cgColor
            bubble.lineWidth = 1
            bubble.contentsScale = 2
            bubble.frame = CGRect(x: 14, y: 2, width: 6, height: 6)
            bubble.opacity = 0
            body.addSublayer(bubble)
            let sizes = [0.35, 0.5, 0.65, 0.5, 0.7, 0.85, 0.7, 0.9, 1.05, 1.2]
            k.play(bubble, [k.shown(0, 3.6), k.track("transform.scale", sizes.enumerated().map { (Double($0) * 0.35, $1) }, rest: 1)])
            for (dx, dy) in [(-1.0, 1.0), (1, 1), (1, -1), (-1, -1)] {
                let drop = prop([R(16.5, 4.5, 1, 1)], c(0.75, 1, 0.85), in: root, hidden: true)
                k.play(drop, [k.shown(3.6, 4.0),
                              k.track("transform.translation.x", [(3.6, dx * 2), (3.8, dx * 4)]),
                              k.track("transform.translation.y", [(3.6, dy * 2), (3.8, dy * 4)])])
            }
            let startled = prop([R(4, 6, 2, 2), R(10, 6, 2, 2)], .black, in: eyes, hidden: true)
            k.play(startled, [k.shown(3.6, 4.2)])
        case .nightcap:
            // A nightcap whose pompom sways as it sleeps.
            let k = clock(4)
            prop([R(4, 12, 8, 1)], w(0.95), in: body)
            prop([R(5, 13, 7, 1), R(7, 14, 7, 1), R(10, 15, 5, 1), R(14, 13, 1, 2)], c(0.35, 0.45, 0.95), in: body)
            let pompom = prop([R(14, 11, 2, 2)], w(0.95), in: body)
            k.play(pompom, [k.track("transform.translation.x", [(2.0, 1)])])
        case .halo:
            // A halo, bobbing above its head.
            let k = clock(2)
            let halo = prop([R(5, 15, 6, 1), R(4, 14, 1, 1), R(11, 14, 1, 1), R(5, 13, 6, 1)], gold, in: root)
            k.play(halo, [k.track("transform.translation.y", [(1.0, 1)])])
        case .dream:
            // Dreams of something nice.
            let k = clock(5)
            let heart = prop([R(8, 13, 1, 1), R(10, 13, 1, 1), R(7, 12, 5, 1), R(8, 11, 3, 1), R(9, 10, 1, 1)],
                             c(1, 0.4, 0.55), in: root, hidden: true)
            k.rise(heart, starts: [0.2], steps: min(sky, 6), step: 0.55, sway: [0, 0, 1, 1, 0, 0])
        }
    }

    private static func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// A prop of `rects` in `parent`, sharing its frame; `hidden` ones wait for their track to show them.
    @discardableResult
    private static func prop(_ rects: [CGRect], _ color: NSColor, in parent: CALayer, hidden: Bool = false) -> CAShapeLayer {
        let path = CGMutablePath()
        rects.forEach { path.addRect($0) }
        let s = CAShapeLayer()
        s.path = path
        s.fillColor = color.cgColor
        s.contentsScale = 2
        s.frame = CGRect(origin: .zero, size: parent.bounds.size)
        s.opacity = hidden ? 0 : 1
        parent.addSublayer(s)
        return s
    }
}
