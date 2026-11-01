import Foundation

struct Config: Decodable {
    let url: String      // e.g. http://dev.tail1c1140.ts.net:3773 (ATS allows plain HTTP to ts.net only)
    let token: String    // `t3 auth session issue --scope orchestration:read --token-only`
    let style: String?   // "critters" (default) or "equalizer"

    var wingStyle: WingStyle {
        guard let style else { return .critters }
        if let s = WingStyle(rawValue: style) { return s }
        log("unknown style \"\(style)\", using critters")
        return .critters
    }

    static let path = NSString(string: "~/.config/t3-notch/config.json").expandingTildeInPath

    static func load() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

/// Subscribes to T3's `orchestration.subscribeShell` over the Effect RPC WebSocket at `/ws`.
/// The server pushes one snapshot, then a `thread.updated` per change, so nothing polls.
@MainActor
final class T3Client {
    private let config: Config
    private let store: Store
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var backoff: TimeInterval = 1
    private var lastPong = Date()
    private var fetchingEnvironment = false

    init(config: Config, store: Store) {
        self.config = config
        self.store = store
    }

    func start() {
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        connect()
    }

    /// Drops the socket and dials again right away (wake from sleep).
    func reconnectNow() {
        backoff = 1
        connect()
    }

    private func connect() {
        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        store.connected = false

        guard var comps = URLComponents(string: config.url) else { return }
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.path = "/ws"
        comps.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: "2")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: req)
        task.maximumMessageSize = 64 << 20
        self.task = task
        task.resume()
        lastPong = Date()
        send(task, [
            "_tag": "Request", "id": "1", "tag": "orchestration.subscribeShell",
            "payload": ["omitIdleSubagents": true, "omitOlderSettled": true], "headers": [],
        ])
        Task { await receiveLoop(task, gen: gen) }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, gen: Int) async {
        var firstSnapshot = true
        while gen == generation {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch {
                if gen == generation { log("receive failed: \(error.localizedDescription)") }
                break
            }
            // A socket we already replaced can still deliver a message; drop it.
            guard gen == generation else { return }
            let data: Data
            switch message {
            case .string(let s): data = Data(s.utf8)
            case .data(let d): data = d
            @unknown default: continue
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }
            let messages = (parsed as? [[String: Any]]) ?? [parsed as? [String: Any] ?? [:]]
            for m in messages {
                switch m["_tag"] as? String {
                case "Chunk":
                    if !store.connected { store.connected = true }
                    backoff = 1
                    if store.environmentId == nil { Task { await fetchEnvironmentId() } }
                    for v in m["values"] as? [[String: Any]] ?? [] { store.apply(v, firstSnapshot: &firstSnapshot) }
                    send(task, ["_tag": "Ack", "requestId": m["requestId"] ?? "1"])
                case "Pong":
                    lastPong = Date()
                case "Ping":
                    send(task, ["_tag": "Pong"])
                case "Exit", "Defect", "ClientProtocolError":
                    log("stream ended: \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
                    task.cancel(with: .goingAway, reason: nil)
                default:
                    break
                }
            }
        }
        guard gen == generation else { return }
        store.connected = false
        let delay = backoff
        backoff = min(backoff * 2, 30)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        if gen == generation { connect() }
    }

    private func heartbeat() {
        if Date().timeIntervalSince(lastPong) > 50 {
            log("no pong for 50s, reconnecting")
            reconnectNow()
            return
        }
        if let task { send(task, ["_tag": "Ping"]) }
    }

    private func send(_ task: URLSessionWebSocketTask, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func fetchEnvironmentId() async {
        guard store.environmentId == nil, !fetchingEnvironment,
              let url = URL(string: config.url + "/.well-known/t3/environment") else { return }
        fetchingEnvironment = true
        defer { fetchingEnvironment = false }
        do {
            let (data, _) = try await session.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            store.environmentId = json?["environmentId"] as? String
        } catch {
            log("environment lookup failed: \(error.localizedDescription)")
        }
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[t3notch] \(message)\n".utf8))
}
