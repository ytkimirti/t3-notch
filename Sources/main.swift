import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var client: T3Client?
    var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config: Config
        do { config = try Config.load() } catch {
            // Exit 0 so launchd (KeepAlive: SuccessfulExit false) doesn't restart it every 10s.
            log("cannot read \(Config.path): \(error)")
            exit(0)
        }
        let client = T3Client(config: config, store: store)
        self.client = client
        client.start()

        if let dir = renderDir {
            Task { await renderAndExit(to: dir) }
            return
        }
        let controller = NotchController(store: store, style: config.wingStyle)
        self.controller = controller
        controller.show()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.client?.reconnectNow() }
        }
    }

    /// `--render <dir>`: connect, wait for the first snapshot, write collapsed/expanded PNGs over a
    /// fake menu bar and notch, print what it would show, and exit. Opens no window.
    private func renderAndExit(to dir: String) async {
        for _ in 0..<100 where !(store.connected && store.environmentId != nil) {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        print("connected=\(store.connected) environment=\(store.environmentId ?? "-") threads=\(store.threads.count)")
        print("running=\(store.runningCount) done=\(store.done.count)")
        for t in store.done { print("  \(t.isFailed ? "x" : "v") \(t.title) [\(store.projectName(t.projectId))]") }

        let state = NotchState(geometry: NotchController.geometry(for: NotchController.targetScreen()))
        print("screen=\(NotchController.targetScreen()?.localizedName ?? "none") geometry=\(state.geometry)")
        for expanded in [false, true] {
            state.expanded = expanded
            let g = state.geometry
            let view = ZStack(alignment: .topLeading) {
                Color(white: 0.82)
                Color(white: 0.93).frame(height: g.notchHeight)
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                    .fill(Color.black)
                    .frame(width: g.notchWidth, height: g.notchHeight)
                    .offset(x: g.notchMinX)
                NotchView(store: store, state: state, open: { _ in })
            }
            .frame(width: g.panelSize.width, height: g.panelSize.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let cg = renderer.cgImage, let ctx = bitmap(cg.width, cg.height) else {
                print("render failed")
                exit(1)
            }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let wing = state.wingWidth(running: store.runningCount, done: store.done.count)
            if wing > 0 {
                ctx.scaleBy(x: 2, y: 2)
                ctx.translateBy(x: g.notchMinX - wing + 12, y: g.panelSize.height - g.notchHeight)
                wingLayer(state.wingLayout(running: store.runningCount, done: store.done.count), g.notchHeight).render(in: ctx)
            }
            write(ctx, "\(dir)/\(expanded ? "expanded" : "collapsed").png")
        }

        // Every style at a few counts, including overflow, on a plain black strip.
        let h = state.geometry.notchHeight
        for style in WingStyle.allCases {
            for (r, d) in [(3, 2), (1, 0), (0, 1), (12, 9)] {
                let layout = WingLayout(style: style, running: r, done: d)
                let w = layout.width + 24
                guard let ctx = bitmap(Int(w * 2), Int(h * 2)) else { exit(1) }
                ctx.scaleBy(x: 2, y: 2)
                ctx.setFillColor(.black)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.translateBy(x: 12, y: 0)
                wingLayer(layout, h).render(in: ctx)
                write(ctx, "\(dir)/wing-\(style.rawValue)-\(r)-\(d).png")
            }
        }
        exit(0)
    }
}

private func bitmap(_ w: Int, _ h: Int) -> CGContext? {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

private func wingLayer(_ layout: WingLayout, _ height: CGFloat) -> CALayer {
    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: layout.width, height: height)
    layout.build(into: root, height: height)
    return root
}

private func write(_ ctx: CGContext, _ path: String) {
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let renderDir: String? = {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return nil }
    return args[i + 1]
}()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
