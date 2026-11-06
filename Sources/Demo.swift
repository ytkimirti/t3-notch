import AppKit
import Metal
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// `--demo <dir>`: renders the README animations from made-up agents, with no server, config, or
/// window. CARenderer steps the real wing layers through simulated time, so the frames match the
/// app. Writes `<dir>/<style>/frame-NNNN.png` at `fps`; the README shows how to make GIFs of them.
@MainActor
enum Demo {
    struct Beat {
        var running = 0, waiting = 0, done = 0
        var seconds: Double
        /// The cursor rests on the notch.
        var hover = false
        /// The list is open.
        var expanded = false
    }

    static let fps = 25.0
    static let scale: CGFloat = 2

    /// Agents start, one waits on its subagents, they finish, more than ten pile up, then a hover
    /// opens the list.
    static let story: [Beat] = [
        Beat(running: 1, seconds: 1.2),
        Beat(running: 3, seconds: 1.4),
        Beat(running: 4, waiting: 1, seconds: 1.4),
        Beat(running: 3, waiting: 1, done: 2, seconds: 1.6),
        Beat(running: 8, waiting: 2, done: 3, seconds: 2.2),
        Beat(running: 4, waiting: 1, done: 5, seconds: 1.4),
        Beat(running: 4, waiting: 1, done: 5, seconds: 0.5, hover: true),
        Beat(running: 4, waiting: 1, done: 5, seconds: 2.8, hover: true, expanded: true),
        Beat(running: 4, waiting: 1, done: 5, seconds: 0.8),
    ]

    static func run(to dir: String) {
        let store = demoStore()
        for style in WingStyle.allCases {
            let beats = style == .critters ? story : story.filter { !$0.hover }
            let out = "\(dir)/\(style.rawValue)"
            do { try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true) } catch {
                print("cannot create \(out): \(error)")
                exit(1)
            }
            // Clear frames from an earlier, longer run so they don't end up in the GIF.
            for name in (try? FileManager.default.contentsOfDirectory(atPath: out)) ?? [] where name.hasPrefix("frame-") {
                try? FileManager.default.removeItem(atPath: "\(out)/\(name)")
            }
            let frames = render(style: style, beats: beats, store: store, to: out)
            print("wrote \(frames) frames to \(out)")
        }
    }

    /// Five finished threads for the list: done, failed, done, usage-limited, done.
    private static func demoStore() -> Store {
        let now = Date()
        func ago(_ minutes: Double) -> String {
            ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutes * 60))
        }
        let rows: [(String, String, String, Double, String?)] = [
            ("Add retries with backoff to the uploader", "api", "completed", 1, nil),
            ("Fix the flaky checkout end-to-end test", "web", "failed", 4, nil),
            ("Write the migration for user settings", "api", "completed", 12, nil),
            ("Split the sidebar into smaller hooks", "web", "failed", 26, "usage_limit"),
            ("Bump dependencies and fix type errors", "cli", "completed", 70, nil),
        ]
        let threads: [[String: Any]] = rows.enumerated().map { i, row in
            var t: [String: Any] = [
                "id": "demo-\(i)", "projectId": row.1, "title": row.0, "status": row.2,
                "latestRunId": "run", "activeProviderThreadId": "provider",
                "latestRunCompletedAt": ago(row.3), "lastVisitedAt": ago(row.3 + 30),
            ]
            if let error = row.4 { t["lastErrorClass"] = error }
            return t
        }
        let projects = ["api", "web", "cli"].map { ["id": $0, "title": $0] }
        let store = Store()
        var first = true
        store.apply(["kind": "snapshot", "snapshot": ["threads": threads, "projects": projects]], firstSnapshot: &first)
        store.setConnected(0, true)
        return store
    }

    private static func render(style: WingStyle, beats: [Beat], store: Store, to dir: String) -> Int {
        let notch = CGSize(width: 185, height: 32)
        let widestWing = beats.map {
            NotchState.wingWidth(content: WingLayout(style: style, running: $0.running, waiting: $0.waiting, done: $0.done).width)
        }.max() ?? 0
        let notchMinX = (20 + widestWing).rounded()
        let hovers = beats.contains(where: \.hover)
        let size = CGSize(width: notchMinX + notch.width / 2 + 320, height: hovers ? 210 : notch.height + 14)
        let state = NotchState(geometry: NotchGeometry(panelSize: size, notchMinX: notchMinX,
                                                       notchWidth: notch.width, notchHeight: notch.height))
        state.style = style

        // Layers are y-up; the notch geometry is y-down from the top edge.
        func up(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }

        let scene = CALayer()
        scene.anchorPoint = .zero
        scene.bounds = CGRect(origin: .zero, size: size)
        scene.position = .zero
        scene.transform = CATransform3DMakeScale(scale, scale, 1)

        let wallpaper = CAGradientLayer()
        wallpaper.frame = scene.bounds
        wallpaper.colors = [NSColor(red: 0.98, green: 0.72, blue: 0.55, alpha: 1), NSColor(red: 0.62, green: 0.55, blue: 0.86, alpha: 1),
                            NSColor(red: 0.24, green: 0.36, blue: 0.68, alpha: 1)].map(\.cgColor)
        wallpaper.startPoint = CGPoint(x: 0, y: 0)
        wallpaper.endPoint = CGPoint(x: 1, y: 1)
        scene.addSublayer(wallpaper)

        let menuBar = CALayer()
        menuBar.frame = up(CGRect(x: 0, y: 0, width: size.width, height: notch.height))
        menuBar.backgroundColor = NSColor(white: 1, alpha: 0.62).cgColor
        scene.addSublayer(menuBar)
        addStatusItems(to: scene, right: size.width - 14, midY: size.height - notch.height / 2)

        let hardware = CAShapeLayer()
        let notchRect = up(CGRect(x: notchMinX, y: 0, width: notch.width, height: notch.height))
        // Round only the bottom corners: the top ones sit above the canvas.
        hardware.path = CGPath(roundedRect: CGRect(x: notchRect.minX, y: notchRect.minY, width: notch.width, height: notch.height + 10),
                               cornerWidth: 9, cornerHeight: 9, transform: nil)
        hardware.fillColor = .black

        let shape = CAShapeLayer()
        shape.fillColor = .black
        shape.contentsScale = scale
        scene.addSublayer(shape)

        let wing = CALayer()
        wing.anchorPoint = .zero
        scene.addSublayer(wing)

        // The list shows only inside the black shape, as it grows and shrinks.
        let clip = CALayer()
        clip.frame = scene.bounds
        let clipShape = CAShapeLayer()
        clip.mask = clipShape
        scene.addSublayer(clip)
        let list = CALayer()
        list.opacity = 0
        list.contentsScale = scale
        clip.addSublayer(list)
        // The real notch has no pixels, so nothing in the wing shows through it.
        scene.addSublayer(hardware)
        if let shown = beats.first(where: \.expanded) {
            state.expanded = true
            let open = state.shapeRect(running: shown.running, waiting: shown.waiting, done: shown.done)
            let content = DoneList(store: store, done: store.done, open: { _ in }, now: Date())
                .frame(width: open.width - 20)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = scale
            if let image = renderer.cgImage {
                let height = CGFloat(image.height) / scale
                list.contents = image
                list.frame = up(CGRect(x: 0, y: notch.height + 6, width: open.width - 20, height: height))
            }
            state.expanded = false
        }

        let cursor = CAShapeLayer()
        let arrow = CGMutablePath()
        arrow.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -17), CGPoint(x: 4, y: -13), CGPoint(x: 6.8, y: -19.2),
                                 CGPoint(x: 9.4, y: -18.1), CGPoint(x: 6.7, y: -12), CGPoint(x: 12, y: -12)])
        arrow.closeSubpath()
        cursor.path = arrow
        cursor.fillColor = .black
        cursor.strokeColor = .white
        cursor.lineWidth = 1.2
        cursor.lineJoin = .round
        cursor.contentsScale = scale
        cursor.isHidden = !hovers
        scene.addSublayer(cursor)
        let rest = CGPoint(x: size.width - 110, y: 46)
        let onNotch = CGPoint(x: notchMinX - 26, y: size.height - 14) // on the wing, beside the notch

        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        root.addSublayer(scene)

        let pixels = (w: Int(size.width * scale), h: Int(size.height * scale))
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            print("no Metal device")
            exit(1)
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixels.w, height: pixels.h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { exit(1) }
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
        renderer.layer = root
        renderer.bounds = root.frame

        // Eased toward their targets each frame, standing in for the app's SwiftUI springs.
        var left = notchMinX, right = notchMinX + notch.width, bottom = notch.height, wingWidth: CGFloat = 0
        var ear: CGFloat = 5, rightEar: CGFloat = 0, radius: CGFloat = 9, listOpacity: Float = 0
        var built: (Int, Int, Int)?
        var cursorAt = rest
        let dt = 1 / fps
        let ease = { (tau: Double) in CGFloat(1 - exp(-dt / tau)) }
        let start: CFTimeInterval = 10 // media time; the wing's animations begin at 1
        var frame = 0
        for beat in beats {
            state.expanded = beat.expanded
            let from = cursorAt, to = beat.hover ? onNotch : rest
            let steps = Int((beat.seconds * fps).rounded())
            for step in 0..<steps {
                let target = state.shapeRect(running: beat.running, waiting: beat.waiting, done: beat.done)
                let targetWing = state.wingWidth(running: beat.running, waiting: beat.waiting, done: beat.done)
                let k = ease(0.06)
                left += (target.minX - left) * k
                right += (target.maxX - right) * k
                bottom += (target.maxY - bottom) * k
                wingWidth += (targetWing - wingWidth) * k
                ear += ((beat.expanded ? 10 : 5) - ear) * k
                rightEar += ((beat.expanded ? 10 : 0) - rightEar) * k
                radius += ((beat.expanded ? 18 : 9) - radius) * k
                listOpacity += ((beat.expanded ? 1 : 0) - listOpacity) * Float(ease(0.06))
                let move = min(1, Double(step + 1) / (0.45 * fps))
                let s = CGFloat(move * move * (3 - 2 * move))
                cursorAt = CGPoint(x: from.x + (to.x - from.x) * s, y: from.y + (to.y - from.y) * s)

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let rect = CGRect(x: left, y: 0, width: right - left, height: bottom)
                var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
                let path = NotchShape(leftExtension: ear, rightExtension: rightEar, bottomRadius: radius)
                    .path(in: rect).cgPath
                shape.path = path.copy(using: &flip)
                clipShape.path = shape.path
                if built.map({ $0 != (beat.running, beat.waiting, beat.done) }) ?? true {
                    built = (beat.running, beat.waiting, beat.done)
                    let layout = WingLayout(style: style, running: beat.running, waiting: beat.waiting, done: beat.done)
                    wing.bounds = CGRect(x: 0, y: 0, width: layout.width, height: notch.height)
                    layout.build(into: wing, height: notch.height)
                }
                wing.position = CGPoint(x: notchMinX - wingWidth + NotchState.wingLead, y: size.height - notch.height)
                list.opacity = listOpacity
                list.frame.origin.x = left + 10
                cursor.position = cursorAt
                CATransaction.commit()
                CATransaction.flush()

                renderer.beginFrame(atTime: start + Double(frame) * dt, timeStamp: nil)
                renderer.addUpdate(renderer.bounds)
                renderer.render()
                renderer.endFrame()
                let done = queue.makeCommandBuffer()
                done?.commit()
                done?.waitUntilCompleted()
                let file = String(format: "%@/frame-%04d.png", dir, frame)
                guard write(texture, file) else {
                    print("cannot write \(file)")
                    exit(1)
                }
                frame += 1
            }
        }
        return frame
    }

    /// A clock, battery, and Wi-Fi at the right of the menu bar.
    private static func addStatusItems(to scene: CALayer, right: CGFloat, midY: CGFloat) {
        let clock = CATextLayer()
        clock.string = "Fri Nov 6  9:41"
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        clock.font = font
        clock.fontSize = 13
        clock.foregroundColor = NSColor(white: 0, alpha: 0.85).cgColor
        clock.contentsScale = scale
        let width = ceil(NSAttributedString(string: "Fri Nov 6  9:41", attributes: [.font: font]).size().width) + 2
        clock.frame = CGRect(x: right - width, y: midY - 8, width: width, height: 17)
        scene.addSublayer(clock)
        var x = right - width - 14
        for name in ["battery.75percent", "wifi"] {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { continue }
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: CGRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            let icon = CALayer()
            icon.contents = rep.cgImage
            icon.opacity = 0.85
            icon.frame = CGRect(x: x - image.size.width, y: midY - image.size.height / 2, width: image.size.width, height: image.size.height)
            scene.addSublayer(icon)
            x -= image.size.width + 16
        }
    }

    private static func write(_ texture: MTLTexture, _ path: String) -> Bool {
        let w = texture.width, h = texture.height, rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // CARenderer draws y-up, so the texture's first row is the image's bottom.
        bytes = (0..<h).reversed().flatMap { bytes[$0 * rowBytes..<($0 + 1) * rowBytes] }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
