import AppKit
import QuartzCore

/// Which threads each wing group holds, so a figure can follow its thread from group to group.
/// Woke, done, and read come in the list's order; running and waiting in any order.
struct WingKeys: Equatable {
    var running: [String] = []
    var waiting: [String] = []
    var woke: [String] = []
    var done: [String] = []
    var read: [String] = []

    subscript(group: WingLayout.Group) -> [String] {
        switch group {
        case .running: running
        case .waiting: waiting
        case .woke: woke
        case .done: done
        case .read: read
        }
    }
}

/// Keeps the wing's layers across updates and animates what changed:
///
/// - An agent that changes state crouches, jumps in a flip over to its new group, changing color
///   in the air and leaving a trail of sparks, then lands with a squash and a burst.
/// - A new agent pops in; one that's gone (settled, or a subagent that finished) puffs away.
/// - Figures that only make room slide over; one squeezed into a "+N" shrinks into it.
///
/// Positions count from the wing's right edge, which stays beside the notch while the wing grows
/// and shrinks on its left.
@MainActor
final class WingAnimator {
    private struct Figure {
        let group: WingLayout.Group
        let index: Int
        /// Holds the figure, anchored at its feet so it squashes against the ground.
        let box: CALayer
        /// The figure itself, which spins about its middle.
        let body: CALayer
        /// Until when it's still moving under its own steam (a jump or a glide).
        var busyUntil: CFTimeInterval = 0
        /// Until when it's still waiting to pop in, so not on screen yet.
        var hiddenUntil: CFTimeInterval = 0
        /// The burst waiting for it at the end of a jump, moved along if the jump is redirected.
        var landing: [CALayer] = []
    }

    private let stage = CALayer()
    private var figures: [String: Figure] = [:]
    /// Each group's threads last time, in wing order, including those in its "+N".
    private var members: [WingLayout.Group: [String]] = [:]
    /// Where each group's "+N" sat last time.
    private var mores: [WingLayout.Group: CGPoint] = [:]
    private var moreLayers: [WingLayout.Group: CALayer] = [:]
    /// Layers playing out an exit or a spark, removed once they're done.
    private var debris: [(layer: CALayer, until: CFTimeInterval)] = []
    private var style: WingStyle?
    private var height: CGFloat = 0
    /// Animating on screen, in `CACurrentMediaTime`; false for the demo's simulated clock.
    private let live: Bool
    private var sweepScheduled = false

    private static let groups: [WingLayout.Group] = [.running, .waiting, .woke, .done, .read]

    init(live: Bool = true) {
        self.live = live
        stage.anchorPoint = .zero
        stage.bounds = .zero
    }

    /// Keeps the stage on the host's right edge.
    func pin(toRightEdge width: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.position = CGPoint(x: width, y: 0)
        CATransaction.commit()
    }

    /// Shows `layout` in `root`, animating from what it showed before unless `animate` is false
    /// (while the first snapshots come in). `now` is the layer time.
    func update(root: CALayer, layout: WingLayout, keys: WingKeys, height: CGFloat, now: CFTimeInterval,
                animate: Bool = true) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if stage.superlayer !== root {
            root.sublayers?.forEach { $0.removeFromSuperlayer() }
            root.addSublayer(stage)
        }
        stage.position = CGPoint(x: root.bounds.width, y: 0)
        if style != layout.style || self.height != height {
            stage.sublayers?.forEach { $0.removeFromSuperlayer() }
            figures = [:]
            members = [:]
            mores = [:]
            moreLayers = [:]
            debris = []
        }
        style = layout.style
        self.height = height
        sweep(now: now)

        // Each group's threads in wing order. Running and waiting threads keep their places, and
        // newcomers join on the left, so nobody shuffles when one comes or goes.
        var next: [WingLayout.Group: [String]] = [:]
        var groupOf: [String: WingLayout.Group] = [:]
        for g in Self.groups {
            var list = keys[g]
            if g == .running || g == .waiting, let before = members[g] {
                let had = Set(before), has = Set(list)
                list = list.filter { !had.contains($0) } + before.filter { has.contains($0) }
            }
            next[g] = list
            for k in list { groupOf[k] = g }
        }
        var wasIn: [String: WingLayout.Group] = [:]
        for (g, list) in members { for k in list { wasIn[k] = g } }

        // Where everything goes now, in stage points (left of the right edge, so negative).
        var placed: [(key: String, item: WingLayout.Item, x: CGFloat, width: CGFloat)] = []
        var newMores: [WingLayout.Group: CGPoint] = [:]
        moreLayers.values.forEach { $0.removeFromSuperlayer() }
        moreLayers = [:]
        var shownCount: [WingLayout.Group: Int] = [:]
        for p in layout.items {
            let x = p.x - layout.width
            let g = p.item.group
            if case .more(let n, _) = p.item {
                let label = WingLayout.moreLabel(n, group: g, x: x, width: p.width, height: height)
                stage.addSublayer(label)
                moreLayers[g] = label
                newMores[g] = CGPoint(x: x + p.width / 2, y: height / 2)
                continue
            }
            let i = shownCount[g, default: 0]
            shownCount[g] = i + 1
            guard let list = next[g], i < list.count else { continue } // a layout for other counts
            placed.append((list[i], p.item, x, p.width))
        }

        // Neighbors wait for the last jumper (they go 0.12s apart) to leave the ground before they
        // close up behind it.
        let jumpers = placed.filter { p in
            (figures[p.key].map { $0.group != p.item.group && $0.busyUntil <= now } ?? false)
                || (figures[p.key] == nil && wasIn[p.key].map { $0 != p.item.group } ?? false)
        }.count
        let makeRoom = jumpers == 0 ? 0 : 0.14 + 0.12 * Double(jumpers - 1)
        // Figures that stay in their group keep their layers (and their animations' phases).
        var kept: [String: Figure] = [:]
        var usedIndex: [WingLayout.Group: Set<Int>] = [:]
        for p in placed {
            guard var f = figures[p.key], f.group == p.item.group else { continue }
            figures[p.key] = nil
            let to = CGPoint(x: p.x + p.width / 2, y: f.box.position.y)
            if animate { slide(&f, to: to, delay: makeRoom, now: now) } else { f.box.position = to }
            kept[p.key] = f
            usedIndex[f.group, default: []].insert(f.index)
        }

        var flights = 0, pops = 0
        let popping = placed.filter { kept[$0.key] == nil && figures[$0.key] == nil && wasIn[$0.key] == nil }.count
        for p in placed where kept[p.key] == nil {
            let g = p.item.group
            var index = 0
            while usedIndex[g, default: []].contains(index) { index += 1 }
            usedIndex[g, default: []].insert(index)
            var f = makeFigure(p.item, x: p.x, width: p.width, index: index)
            stage.addSublayer(f.box)
            if !animate {
                figures[p.key]?.box.removeFromSuperlayer()
                figures[p.key] = nil
            } else if let old = figures.removeValue(forKey: p.key) {
                let here = Self.onScreen(old.box), angle = Self.rotation(old.body)
                old.box.removeFromSuperlayer()
                old.landing.forEach { $0.removeFromSuperlayer() }
                if old.hiddenUntil > now {
                    // It never showed: pop in where it belongs now.
                    pop(&f, delay: old.hiddenUntil - now, burst: false, now: now)
                } else {
                    // Changed state while on show: jump over, carrying on from mid-air if it was jumping.
                    let airborne = old.busyUntil > now
                    fly(&f, from: here, color: WingLayout.color(old.group), delay: airborne ? 0 : 0.12 * Double(flights),
                        angle: airborne ? angle : 0, airborne: airborne, now: now)
                    if !airborne { flights += 1 }
                }
            } else if let was = wasIn[p.key], let more = mores[was] {
                // Out of a "+N": from its own group's, or jumping over from another's.
                let from = CGPoint(x: more.x, y: f.box.position.y)
                if was == g {
                    pop(&f, delay: 0, burst: false, now: now, from: from)
                } else {
                    fly(&f, from: from, color: WingLayout.color(was), delay: 0.12 * Double(flights), now: now)
                    flights += 1
                }
            } else {
                // A new agent.
                // After the wing has grown room for it.
                pop(&f, delay: 0.18 + 0.04 * Double(pops), burst: popping <= 4, now: now)
                pops += 1
            }
            kept[p.key] = f
        }

        // What showed before and doesn't now: squeezed into a "+N", or gone.
        for (key, old) in figures {
            if !animate || old.hiddenUntil > now {
                old.box.removeFromSuperlayer()
                old.landing.forEach { $0.removeFromSuperlayer() }
            } else if let g = groupOf[key], let more = newMores[g] {
                sink(old, into: more, now: now)
                if let label = moreLayers[g] { bump(label, at: now + 0.3) }
            } else {
                puff(old, now: now)
            }
        }

        figures = kept
        members = next
        mores = newMores
        scheduleSweep(now: now)
    }

    /// Where each shown figure stands, by key, in points left of the right edge. For tests.
    var positions: [String: CGFloat] { figures.mapValues(\.box.position.x) }
    /// How many layers the wing holds, exits and sparks included. For tests.
    var layerCount: Int { stage.sublayers?.count ?? 0 }

    /// Drops exits and sparks that have played out.
    func sweep(now: CFTimeInterval) {
        debris.removeAll { d in
            if d.until > now { return false }
            d.layer.removeFromSuperlayer()
            return true
        }
    }

    /// Clears what's left of the exits once they're over, rather than at the next update, which
    /// may be hours away (a puffed figure keeps its loops running while invisible).
    private func scheduleSweep(now: CFTimeInterval) {
        guard live, !sweepScheduled, let last = debris.map(\.until).max() else { return }
        sweepScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(last - now, 0) + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sweepScheduled = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.sweep(now: CACurrentMediaTime())
                CATransaction.commit()
                self.scheduleSweep(now: CACurrentMediaTime())
            }
        }
    }

    /// How far a figure has turned right now, mid-flip or not.
    private static func rotation(_ layer: CALayer) -> Double {
        (layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? 0
    }

    /// Where a figure shows right now, mid-move or not.
    private static func onScreen(_ layer: CALayer) -> CGPoint {
        layer.presentation()?.position ?? layer.position
    }

    // MARK: Moves

    private func makeFigure(_ item: WingLayout.Item, x: CGFloat, width: CGFloat, index: Int) -> Figure {
        let body = WingLayout.figure(item, x: 0, height: height, index: index)
        let foot = body.frame.minY
        let box = CALayer()
        box.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        box.anchorPoint = CGPoint(x: 0.5, y: height > 0 ? foot / height : 0)
        box.position = CGPoint(x: x + width / 2, y: foot)
        box.addSublayer(body)
        return Figure(group: item.group, index: index, box: box, body: body)
    }

    /// Makes room: a soft spring sideways. A figure still on the move carries its jump on from
    /// where it is to the new spot instead.
    private func slide(_ f: inout Figure, to: CGPoint, delay: CFTimeInterval, now: CFTimeInterval) {
        let from = f.box.position
        guard from != to else { return }
        if f.busyUntil > now {
            let here = Self.onScreen(f.box), angle = Self.rotation(f.body)
            f.landing.forEach { $0.removeFromSuperlayer() }
            f.box.position = to
            fly(&f, from: here, color: WingLayout.color(f.group), delay: 0, angle: angle, airborne: true, now: now)
            return
        }
        f.box.position = to
        let spring = CASpringAnimation(keyPath: "position.x")
        spring.isAdditive = true
        spring.fromValue = from.x - to.x
        spring.toValue = 0
        spring.mass = 1
        spring.stiffness = 210
        spring.damping = 20
        spring.duration = spring.settlingDuration
        spring.beginTime = now + delay
        spring.fillMode = .backwards
        f.box.add(spring, forKey: nil)
    }

    /// The state change: crouch, a flipping jump from `from` that turns from `color` into the new
    /// group's color and trails sparks, then a squashed landing that throws off a burst.
    /// From mid-air (`airborne`), it skips the crouch and carries on from `angle`.
    private func fly(_ f: inout Figure, from: CGPoint, color old: NSColor, delay: CFTimeInterval, angle: Double = 0,
                     airborne: Bool = false, now: CFTimeInterval) {
        let to = f.box.position
        let new = WingLayout.color(f.group)
        let dx = to.x - from.x
        let crouch = airborne ? 0.01 : 0.1, air = 0.42 + min(abs(dx) / 600, 0.18), land = 0.2
        let total = crouch + air + land
        let begin = now + delay
        // As high as the menu bar leaves room for above the figure.
        let top = f.body.frame.maxY
        let lift = max(3, min(9, height - top + 1))
        // At least half a turn on, ending upright.
        let turn = 2 * Double.pi
        let end = dx > 0.5 ? turn * ((angle - Double.pi) / turn).rounded(.down) : turn * ((angle + Double.pi) / turn).rounded(.up)

        func at(_ u: Double) -> CGPoint {
            let s = u * u * (3 - 2 * u)
            return CGPoint(x: from.x + dx * s, y: from.y + (to.y - from.y) * s + 4 * lift * u * (1 - u))
        }
        let steps = 24
        var times: [NSNumber] = [0], points: [NSValue] = [NSValue(point: from)], angles: [Double] = [angle]
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            times.append(NSNumber(value: (crouch + air * u) / total))
            points.append(NSValue(point: at(u)))
            angles.append(angle + (end - angle) * u * u * (3 - 2 * u))
        }
        times.append(1)
        points.append(NSValue(point: to))
        angles.append(end)

        let path = CAKeyframeAnimation(keyPath: "position")
        path.values = points
        path.keyTimes = times
        // Crouch, stretch on takeoff, round in the air, squash on landing, settle.
        let touch = crouch + air
        let marks: [Double] = [0, crouch, crouch + 0.07, crouch + air * 0.5, touch, touch + 0.06, touch + 0.13, total]
        let squashTimes = marks.map { NSNumber(value: $0 / total) }
        let sx = CAKeyframeAnimation(keyPath: "transform.scale.x")
        sx.values = [1, airborne ? 1 : 1.25, airborne ? 1 : 0.85, 1, 1, 1.35, 0.92, 1]
        sx.keyTimes = squashTimes
        let sy = CAKeyframeAnimation(keyPath: "transform.scale.y")
        sy.values = [1, airborne ? 1 : 0.7, airborne ? 1 : 1.25, 1, 1, 0.6, 1.08, 1]
        sy.keyTimes = squashTimes
        let jump = CAAnimationGroup()
        jump.animations = [path, sx, sy]
        jump.duration = total
        jump.beginTime = begin
        jump.fillMode = .backwards
        f.box.add(jump, forKey: "flight")

        let flip = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        flip.values = angles
        flip.keyTimes = times
        flip.duration = total
        flip.beginTime = begin
        flip.fillMode = .backwards
        f.body.add(flip, forKey: "spin")

        recolor(f.body, from: old, to: new, begin: begin + crouch * 0.5, duration: air, hideFrom: begin, hideUntil: begin + total + 0.3)
        f.busyUntil = begin + total

        // Sparks fall behind along the arc, fading from the old color into the new.
        let mid = (f.body.frame.height / 2).rounded()
        for i in 1...6 {
            let u = Double(i) / 7
            let p = at(u)
            spark(at: CGPoint(x: p.x, y: p.y + mid), to: CGPoint(x: p.x, y: p.y + mid - 2),
                  color: old.blended(withFraction: u, of: new) ?? new, size: 2,
                  begin: begin + crouch + air * u, duration: 0.32)
        }
        f.landing = burst(at: CGPoint(x: to.x, y: to.y + 2), color: new, count: 8, reach: 10, begin: begin + crouch + air)
    }

    /// A new agent grows out of the ground with a wobble.
    private func pop(_ f: inout Figure, delay: CFTimeInterval, burst withBurst: Bool, now: CFTimeInterval, from: CGPoint? = nil) {
        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = 0
        grow.toValue = 1
        grow.mass = 0.6
        grow.stiffness = 260
        grow.damping = 13
        grow.duration = grow.settlingDuration
        grow.beginTime = now + delay
        grow.fillMode = .backwards
        f.box.add(grow, forKey: "pop")
        f.hiddenUntil = now + delay
        if let from {
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: from)
            move.toValue = NSValue(point: f.box.position)
            move.duration = 0.3
            move.beginTime = now + delay
            move.fillMode = .backwards
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            f.box.add(move, forKey: "flight")
            f.busyUntil = now + delay + 0.3
        }
        if withBurst {
            let c = f.box.position
            burst(at: CGPoint(x: c.x, y: c.y + 4), color: WingLayout.color(f.group), count: 5, reach: 7, begin: now + delay)
        }
    }

    /// An agent that's gone swells a touch and vanishes in a puff.
    private func puff(_ f: Figure, now: CFTimeInterval) {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1, 1.25, 0]
        scale.keyTimes = [0, 0.3, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.3, 1]
        let exit = CAAnimationGroup()
        exit.animations = [scale, fade]
        exit.duration = 0.3
        exit.beginTime = now
        exit.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let c = Self.onScreen(f.box)
        f.box.removeAllAnimations()
        f.box.position = c
        f.box.opacity = 0
        f.box.add(exit, forKey: "exit")
        debris.append((f.box, now + 0.4))
        f.landing.forEach { $0.removeFromSuperlayer() }
        // Over before the wing closes in (`NotchState.shrinkDelay`).
        burst(at: CGPoint(x: c.x, y: c.y + 5), color: NSColor(white: 0.75, alpha: 1), count: 6, reach: 8, begin: now + 0.06,
              duration: 0.3)
    }

    /// A figure pushed out of view shrinks into its group's "+N".
    private func sink(_ f: Figure, into more: CGPoint, now: CFTimeInterval) {
        let here = Self.onScreen(f.box)
        f.box.removeAllAnimations()
        f.landing.forEach { $0.removeFromSuperlayer() }
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: here)
        move.toValue = NSValue(point: CGPoint(x: more.x, y: f.box.position.y))
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let exit = CAAnimationGroup()
        exit.animations = [move, scale, fade]
        exit.duration = 0.32
        exit.beginTime = now
        exit.timingFunction = CAMediaTimingFunction(name: .easeIn)
        f.box.opacity = 0
        f.box.add(exit, forKey: "exit")
        debris.append((f.box, now + 0.4))
    }

    /// The "+N" swells as something drops in.
    private func bump(_ label: CALayer, at begin: CFTimeInterval) {
        let swell = CAKeyframeAnimation(keyPath: "transform.scale")
        swell.values = [1, 1.4, 0.95, 1]
        swell.keyTimes = [0, 0.35, 0.7, 1]
        swell.duration = 0.3
        swell.beginTime = begin
        label.add(swell, forKey: "bump")
    }

    // MARK: Pieces

    /// Fades every part of `layer` painted in `to` in from `from`, and hides its floating "z"s
    /// until it has landed.
    private func recolor(_ layer: CALayer, from: NSColor, to: NSColor, begin: CFTimeInterval, duration: CFTimeInterval,
                         hideFrom: CFTimeInterval, hideUntil: CFTimeInterval) {
        let target = to.cgColor
        // Redirected mid-jump: any color change already under way carries on.
        let recoloring = from != to
        func walk(_ l: CALayer) {
            if !recoloring {
            } else if let shape = l as? CAShapeLayer, shape.fillColor == target {
                l.add(fade("fillColor", from, to, begin, duration), forKey: "recolor")
            } else if l.backgroundColor == target {
                l.add(fade("backgroundColor", from, to, begin, duration), forKey: "recolor")
            }
            if l is CATextLayer {
                let hide = CABasicAnimation(keyPath: "opacity")
                hide.fromValue = 0
                hide.toValue = 0
                hide.duration = hideUntil - hideFrom
                hide.beginTime = hideFrom
                hide.fillMode = .backwards
                l.add(hide, forKey: "hide")
            }
            l.sublayers?.forEach(walk)
        }
        walk(layer)
    }

    private func fade(_ keyPath: String, _ from: NSColor, _ to: NSColor, _ begin: CFTimeInterval,
                      _ duration: CFTimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from.cgColor
        a.toValue = to.cgColor
        a.beginTime = begin
        a.duration = duration
        a.fillMode = .backwards
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }

    /// `count` pixels flying out of `center` and fading, mostly upward.
    @discardableResult
    private func burst(at center: CGPoint, color: NSColor, count: Int, reach: CGFloat, begin: CFTimeInterval,
                       duration: CFTimeInterval = 0.42) -> [CALayer] {
        (0..<count).map { i in
            // Fanned over the upper half and a little below the sides.
            let angle = CGFloat(-0.35 + (Double.pi + 0.7) * Double(i) / Double(max(count - 1, 1)))
            let r: CGFloat = reach * (i.isMultiple(of: 2) ? 1 : 0.7)
            let end = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
            return spark(at: center, to: end, color: i.isMultiple(of: 3) ? .white : color, size: i.isMultiple(of: 2) ? 2 : 1.5,
                         begin: begin, duration: duration)
        }
    }

    /// A square of `size` points that drifts from `start` to `end` and fades out.
    @discardableResult
    private func spark(at start: CGPoint, to end: CGPoint, color: NSColor, size: CGFloat, begin: CFTimeInterval,
                       duration: CFTimeInterval) -> CALayer {
        let s = CALayer()
        s.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        s.position = end
        s.backgroundColor = color.cgColor
        s.opacity = 0
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: start)
        move.toValue = NSValue(point: end)
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95
        fade.toValue = 0
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let g = CAAnimationGroup()
        g.animations = [move, fade]
        g.duration = duration
        g.beginTime = begin
        s.add(g, forKey: "spark")
        stage.insertSublayer(s, at: 0)
        debris.append((s, begin + duration + 0.1))
        return s
    }
}
