import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var clients: [T3Client] = []
    var controller: NotchController?
    var style = WingStyle.critters

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = argument("--demo") {
            Demo.run(to: dir)
            exit(0)
        }
        let config: Config
        do { config = try Config.load() } catch {
            // Exit 0 so launchd (KeepAlive: SuccessfulExit false) doesn't restart it every 10s.
            log("cannot read \(Config.path): \(error)")
            exit(0)
        }
        style = config.wingStyle
        clients = config.allServers.enumerated().map { T3Client(server: $1, source: $0, store: store) }
        clients.forEach { $0.start() }

        if let dir = renderDir {
            Task { await renderAndExit(to: dir) }
            return
        }
        let controller = NotchController(store: store, style: style)
        self.controller = controller
        controller.show()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clients.forEach { $0.reconnectNow() } }
        }
    }

    /// `--render <dir>`: connect, wait for the first snapshot, write collapsed/expanded PNGs over a
    /// fake menu bar and notch plus wing strips for every style, print what it would show, and exit.
    /// Opens no window.
    private func renderAndExit(to dir: String) async {
        let servers = clients.indices
        for _ in 0..<100 where !servers.allSatisfy({ store.connectedSources.contains($0) && store.environments[$0] != nil }) {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        for s in servers {
            print("server \(s): connected=\(store.connectedSources.contains(s)) environment=\(store.environments[s] ?? "-")")
        }
        print("threads=\(store.threadCount)")
        print("running=\(store.runningCount) waiting=\(store.waitingCount) woke=\(store.woke.count) done=\(store.done.count) read=\(store.read.count)")
        for t in store.finished {
            let mark = store.woke.contains(t) ? "!" : store.read.contains(t) ? "." : t.isFailed ? "x" : "v"
            print("  \(mark) \(t.title) [\(store.projectName(t.projectId))]")
        }

        let state = NotchState(geometry: NotchController.geometry(for: NotchController.targetScreen()))
        state.style = style
        print("screen=\(NotchController.targetScreen()?.localizedName ?? "none") geometry=\(state.geometry)")
        for expanded in [false, true] {
            state.expanded = expanded
            let g = state.geometry
            let view = ZStack(alignment: .topLeading) {
                Color(white: 0.82)
                Color(white: 0.93).frame(height: g.notchHeight)
                if g.hasNotch {
                    UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                        .fill(Color.black)
                        .frame(width: g.notchWidth, height: g.notchHeight)
                        .offset(x: g.notchMinX)
                }
                NotchView(store: store, state: state, open: { _ in }, hide: {})
            }
            .frame(width: g.panelSize.width, height: g.panelSize.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let cg = renderer.cgImage, let ctx = bitmap(cg.width, cg.height) else {
                print("render failed")
                exit(1)
            }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let wing = state.wingWidth(running: store.runningCount, waiting: store.waitingCount, woke: store.woke.count,
                                       done: store.done.count, read: store.read.count)
            if wing > 0 {
                ctx.scaleBy(x: 2, y: 2)
                ctx.translateBy(x: state.wingMinX(wing) + NotchState.wingLead, y: g.panelSize.height - g.notchHeight)
                wingLayer(state.wingLayout(running: store.runningCount, waiting: store.waitingCount, woke: store.woke.count,
                                           done: store.done.count, read: store.read.count), g.notchHeight).render(in: ctx)
            }
            write(ctx, "\(dir)/\(expanded ? "expanded" : "collapsed").png")
        }

        // Every style at a few counts, including overflow, on a plain black strip.
        let h = state.geometry.notchHeight
        for style in WingStyle.allCases {
            for (r, w, k, d, e) in [(3, 1, 0, 2, 0), (1, 0, 0, 0, 0), (0, 1, 0, 0, 0), (0, 0, 0, 1, 0), (12, 7, 0, 9, 0),
                                    (2, 1, 2, 2, 3)] {
                let layout = WingLayout(style: style, running: r, waiting: w, woke: k, done: d, read: e)
                let width = layout.width + 24
                guard let ctx = bitmap(Int(width * 2), Int(h * 2)) else { exit(1) }
                ctx.scaleBy(x: 2, y: 2)
                ctx.setFillColor(.black)
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: h))
                ctx.translateBy(x: 12, y: 0)
                wingLayer(layout, h).render(in: ctx)
                write(ctx, "\(dir)/wing-\(style.rawValue)-\(r)-\(w)-\(k)-\(d)-\(e).png")
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

func argument(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let renderDir = argument("--render")

for flag in ["--render", "--demo"] where CommandLine.arguments.contains(flag) && argument(flag) == nil {
    print("usage: t3notch [--render <dir> | --demo <dir>]")
    exit(2)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
