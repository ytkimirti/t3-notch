import Foundation

/// T3's default sidebar status (web `resolveSidebarThreadStatus`).
enum SidebarStatus { case attention, waiting, working, failed, ready }

/// The fields of T3's `OrchestrationV2ThreadShell` the notch needs, with T3's rules ported as
/// literally as possible: client-runtime `shellRuntime`, `toSidebarThreadSummary` and
/// `effectiveSnoozed`, web `resolveSidebarThreadStatus` and `hasUnseenCompletion/Failure`.
struct AgentThread: Identifiable, Equatable {
    let id: String
    let projectId: String
    let title: String
    let runtimeStatus: String?
    let blockedOnThreadWait: Bool
    let latestRunCompletedAt: Date?
    let lastVisitedAt: Date?
    let isSubagent: Bool
    let isShelved: Bool
    let snoozedAt: Date?
    let snoozedUntil: Date?
    let hasRuntimeRequest: Bool
    let isUsageLimited: Bool
    let parentThreadId: String?
    /// client-runtime `subagentRequest`: a live, T3-made subagent asking for approval or input.
    /// Rolls up to its ancestors (`pendingSubagentRequestsByThread`), which the Store sets below.
    let raisesSubagentRequest: Bool
    var hasSubagentRequest = false
    /// Which configured server the thread lives on (index into `Config.allServers`).
    var source = 0
    /// Unique across servers, unlike `id`.
    var key: String { "\(source)/\(id)" }
    private let ownAttention: Bool

    var needsAttention: Bool { ownAttention || hasSubagentRequest }

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let status = json["status"] as? String else { return nil }
        self.id = id
        projectId = json["projectId"] as? String ?? ""
        title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        blockedOnThreadWait = json["blockedOnThreadWait"] as? Bool ?? false
        isUsageLimited = (json["lastErrorClass"] as? String) == "usage_limit"
        latestRunCompletedAt = parseDate(json["latestRunCompletedAt"])
        lastVisitedAt = parseDate(json["lastVisitedAt"])
        let lineage = json["lineage"] as? [String: Any]
        isSubagent = (lineage?["relationshipToParent"] as? String) == "subagent"
        parentThreadId = lineage?["parentThreadId"] as? String
        isShelved = present(json["archivedAt"]) || (json["settledOverride"] as? String) == "settled"
        snoozedAt = parseDate(json["snoozedAt"])
        snoozedUntil = parseDate(json["snoozedUntil"])

        // shellRuntime: background work the agent waits on parks the thread at idle.
        let holds = (json["pendingBackgroundTasks"] as? [[String: Any]] ?? []).contains {
            $0["awaited"] as? Bool == true || ["subagent", "background_task"].contains($0["kind"] as? String ?? "")
        }
        let parkAtIdle = holds && status != "failed"
        if !present(json["latestRunId"]) && !present(json["activeProviderThreadId"]) && !parkAtIdle {
            runtimeStatus = nil
        } else {
            runtimeStatus = parkAtIdle ? "idle" : (json["activityRunStatus"] as? String) ?? status
        }

        // toSidebarThreadSummary: hasPendingApprovals, hasPendingUserInput, pendingGuestMessageCount.
        let request = json["pendingRuntimeRequest"] as? [String: Any]
        let kind = request?["kind"] as? String
        let runtimeIsWorking = ["preparing", "starting", "running"].contains(runtimeStatus ?? "")
        let approval = request != nil && kind != "user_input" && kind != "auth_refresh"
        let input = kind == "user_input" && (request?["blocking"] as? Bool != false || !runtimeIsWorking)
        hasRuntimeRequest = request != nil
        ownAttention = approval || input || (json["pendingGuestMessageCount"] as? Int ?? 0) > 0

        // isChildRunLive: activityRunStatus when the server sends the key, else the run status.
        let childRunLive = json.keys.contains("activityRunStatus")
            ? present(json["activityRunStatus"])
            : ["preparing", "starting", "running", "waiting"].contains(status)
        raisesSubagentRequest = kind != nil && kind != "auth_refresh" && isSubagent
            && (json["creationSource"] as? String) != "provider" && childRunLive
    }

    var sidebarStatus: SidebarStatus {
        if needsAttention { return .attention }
        if runtimeStatus == "running" && blockedOnThreadWait { return .waiting }
        if ["preparing", "queued", "starting", "running", "waiting"].contains(runtimeStatus ?? "") { return .working }
        if runtimeStatus == "idle" { return .waiting }
        if runtimeStatus == "failed" { return .failed }
        return .ready
    }

    /// Subagents count too: each is an agent at work. A parent blocked on them is "waiting".
    var isRunning: Bool { sidebarStatus == .working }

    /// A sidebar row showing "Waiting": blocked on another thread, or parked on background work it
    /// awaits. Subagents have no row, and snoozing or settling their parent can't reach them; the
    /// parent of a waiting subagent is itself blocked, so it already shows.
    func isWaiting(now: Date) -> Bool {
        sidebarStatus == .waiting && !isSubagent && !isShelved && !isSnoozed(now: now)
    }

    var isFailed: Bool { sidebarStatus == .failed }

    /// effectiveSnoozed: hidden until snoozedUntil, unless it raised a hand meanwhile.
    func isSnoozed(now: Date) -> Bool {
        guard let snoozedUntil, snoozedUntil > now else { return false }
        if needsAttention || hasRuntimeRequest { return false }
        guard isFailed else { return true }
        guard let snoozedAt else { return false }
        guard let failedAt = latestRunCompletedAt else { return true }
        return failedAt <= snoozedAt
    }

    /// A sidebar row showing "done", or a failure you haven't opened since it failed. The sidebar
    /// keeps showing failures after a visit; the notch lists only what you haven't seen.
    func isUnseenDone(now: Date) -> Bool {
        if isSubagent || isShelved || isSnoozed(now: now) { return false }
        switch sidebarStatus {
        case .ready:
            guard let completed = latestRunCompletedAt, let visited = lastVisitedAt else { return false }
            return completed > visited
        case .failed:
            guard let completed = latestRunCompletedAt, let visited = lastVisitedAt else { return true }
            return completed > visited
        default:
            return false
        }
    }
}

private func present(_ value: Any?) -> Bool { value != nil && !(value is NSNull) }

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

private func parseDate(_ value: Any?) -> Date? {
    guard let s = value as? String else { return nil }
    return isoFractional.date(from: s) ?? isoPlain.date(from: s)
}

/// Threads from every configured T3 server, counted together.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var runningCount = 0
    @Published private(set) var waitingCount = 0
    @Published private(set) var done: [AgentThread] = []
    @Published private(set) var projects: [String: String] = [:]
    /// Servers with a live subscription.
    @Published private(set) var connectedSources: Set<Int> = []
    /// Each server's T3 environment, for `t3code://` links.
    @Published var environments: [Int: String] = [:] {
        didSet { recompute() }
    }
    /// Threads by server, then by id.
    private(set) var sources: [Int: [String: AgentThread]] = [:] {
        didSet { recompute() }
    }
    /// When each server dropped. A dropped server's threads keep counting this long, so a
    /// reconnect doesn't flicker the wing; after that its agents are no longer known to be running.
    private var disconnectedAt: [Int: Date] = [:]
    var staleAfter: TimeInterval = 30
    /// What counted when the last server dropped: shown, dimmed, until one is back. Nil until a
    /// server first drops, so everything counts before any connection.
    private var lastKnown: Set<Int>?

    var connected: Bool { !connectedSources.isEmpty }
    var threadCount: Int { sources.values.reduce(0) { $0 + $1.count } }

    func setConnected(_ source: Int, _ isConnected: Bool) {
        guard connectedSources.contains(source) != isConnected else { return }
        let now = Date(), wasConnected = connected
        if isConnected {
            connectedSources.insert(source)
            disconnectedAt[source] = nil
            // Back from an outage (say, a wake): the others still down get a fresh grace, as
            // their clocks ran while nothing could reconnect.
            if !wasConnected { for s in lastKnown ?? [] where !connectedSources.contains(s) { disconnectedAt[s] = now } }
        } else {
            connectedSources.remove(source)
            disconnectedAt[source] = now
            if !connected { lastKnown = Set(countedSources(now: now, fallback: false)) }
        }
        recompute()
    }

    /// Servers whose threads count: connected ones and ones that dropped under `staleAfter` ago,
    /// once per environment, preferring a connected copy (the same server configured twice counts
    /// once). With none connected,
    /// `lastKnown`, so the dimmed wing still shows the last known state.
    private func countedSources(now: Date, fallback: Bool = true) -> [Int] {
        var seen = Set<String>()
        let order = sources.keys.sorted { (connectedSources.contains($0) ? 0 : 1, $0) < (connectedSources.contains($1) ? 0 : 1, $1) }
        return order.filter { s in
            let live = fallback && !connected ? lastKnown?.contains(s) ?? true
                : connectedSources.contains(s) || disconnectedAt[s].map { now.timeIntervalSince($0) < staleAfter } ?? false
            guard live else { return false }
            guard let env = environments[s] else { return true }
            return seen.insert(env).inserted
        }
    }

    /// One server's threads with subagent requests rolled up to every ancestor, as T3's sidebar does.
    private func withSubagentRequests(_ threads: [String: AgentThread]) -> [AgentThread] {
        var raised = Set<String>()
        for child in threads.values where child.raisesSubagentRequest {
            var seen: Set<String> = [child.id]
            var current: AgentThread? = child
            while let c = current, c.isSubagent, let parent = c.parentThreadId, !seen.contains(parent) {
                seen.insert(parent)
                raised.insert(parent)
                current = threads[parent]
            }
        }
        if raised.isEmpty { return Array(threads.values) }
        return threads.values.map { t in
            var t = t
            t.hasSubagentRequest = raised.contains(t.id)
            return t
        }
    }
    private var snoozeTimer: Timer?

    func projectName(_ id: String) -> String { projects[id] ?? "" }

    private func recompute() {
        let now = Date()
        let counted = countedSources(now: now)
        let all = counted.flatMap { withSubagentRequests(sources[$0] ?? [:]) }
        let running = all.filter(\.isRunning).count
        let waiting = all.filter { $0.isWaiting(now: now) }.count
        let finished = all.filter { $0.isUnseenDone(now: now) }.sorted {
            ($0.latestRunCompletedAt ?? .distantPast) > ($1.latestRunCompletedAt ?? .distantPast)
        }
        if running != runningCount { runningCount = running }
        if waiting != waitingCount { waitingCount = waiting }
        if finished != done { done = finished }

        // The server sends nothing when a snooze runs out, and nothing at all once it dropped;
        // recompute then ourselves.
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        let snoozeEnds = counted.flatMap { (sources[$0] ?? [:]).values.compactMap(\.snoozedUntil) }
        let staleAt = connected ? disconnectedAt.values.map { $0.addingTimeInterval(staleAfter) } : []
        if let wake = (snoozeEnds + staleAt).filter({ $0 > now }).min() {
            snoozeTimer = Timer.scheduledTimer(withTimeInterval: wake.timeIntervalSince(now) + 1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.recompute() }
            }
        }
    }

    /// The first snapshot on a connection replaces everything. Later snapshots are project
    /// enrichment refreshes that carry only changed projects and no threads.
    func apply(_ item: [String: Any], firstSnapshot: inout Bool, source: Int = 0) {
        func parse(_ json: [String: Any]) -> AgentThread? {
            guard var t = AgentThread(json) else { return nil }
            t.source = source
            return t
        }
        switch item["kind"] as? String {
        case "snapshot":
            guard let snap = item["snapshot"] as? [String: Any] else { return }
            let threadList = snap["threads"] as? [[String: Any]] ?? []
            if firstSnapshot || !threadList.isEmpty {
                var next: [String: AgentThread] = [:]
                for t in threadList { if let t = parse(t) { next[t.id] = t } }
                sources[source] = next
                firstSnapshot = false
            }
            for p in snap["projects"] as? [[String: Any]] ?? [] { upsertProject(p) }
        case "thread.updated":
            guard let json = item["thread"] as? [String: Any], let id = json["id"] as? String else { return }
            sources[source, default: [:]][id] = (item["location"] as? String) == "active" ? parse(json) : nil
        case "thread.removed":
            if let id = item["threadId"] as? String { sources[source]?[id] = nil }
        case "project.updated":
            if let p = item["project"] as? [String: Any] { upsertProject(p) }
        case "project.removed":
            if let id = item["projectId"] as? String { projects[id] = nil }
        default:
            break
        }
    }

    private func upsertProject(_ p: [String: Any]) {
        guard let id = p["id"] as? String, let title = p["title"] as? String else { return }
        if projects[id] != title { projects[id] = title }
    }
}
