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
            log("cannot read \(Config.path): \(error)")
            exit(1)
        }
        let client = T3Client(config: config, store: store)
        self.client = client
        client.start()

        if let dir = renderDir {
            Task { await renderAndExit(to: dir) }
            return
        }
        let controller = NotchController(store: store)
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
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                print("render failed")
                exit(1)
            }
            let path = "\(dir)/\(expanded ? "expanded" : "collapsed").png"
            try? png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
        exit(0)
    }
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
