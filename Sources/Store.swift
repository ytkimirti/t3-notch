import Foundation

/// The fields of T3's `OrchestrationV2ThreadShell` the notch needs, and the status rules of T3's
/// default sidebar over them (client-runtime `shellRuntime`, web `resolveSidebarThreadStatus`).
struct AgentThread: Identifiable, Equatable {
    let id: String
    let projectId: String
    let title: String
    let status: String
    let runtimeStatus: String
    let blockedOnThreadWait: Bool
    let latestRunCompletedAt: Date?
    let lastVisitedAt: Date?
    let isSubagent: Bool
    let isShelved: Bool
    let snoozedUntil: Date?
    let needsAttention: Bool
    let backgroundWorkHolds: Bool

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let status = json["status"] as? String else { return nil }
        self.id = id
        projectId = json["projectId"] as? String ?? ""
        title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        self.status = status
        blockedOnThreadWait = json["blockedOnThreadWait"] as? Bool ?? false
        latestRunCompletedAt = parseDate(json["latestRunCompletedAt"])
        lastVisitedAt = parseDate(json["lastVisitedAt"])
        isSubagent = ((json["lineage"] as? [String: Any])?["relationshipToParent"] as? String) == "subagent"
        isShelved = present(json["archivedAt"]) || present(json["deletedAt"])
            || (json["settledOverride"] as? String) == "settled"
        snoozedUntil = parseDate(json["snoozedUntil"])
        // Approval, input and guest requests outrank done; auth refreshes don't (models.ts).
        let request = json["pendingRuntimeRequest"] as? [String: Any]
        needsAttention = (request != nil && request?["kind"] as? String != "auth_refresh")
            || (json["pendingGuestMessageCount"] as? Int ?? 0) > 0
        // orchestrationV2PendingBackgroundWork.backgroundWorkHoldsCompletion
        backgroundWorkHolds = (json["pendingBackgroundTasks"] as? [[String: Any]] ?? []).contains {
            $0["awaited"] as? Bool == true || ["subagent", "background_task"].contains($0["kind"] as? String ?? "")
        }
        let activity = (json["activityRunStatus"] as? String) ?? status
        runtimeStatus = backgroundWorkHolds && status != "failed" ? "idle" : activity
    }

    /// T3's "Working" and "Connecting" pills. Subagents count too: each one is an agent at work,
    /// while a parent blocked on them or parked on background work does not.
    var isRunning: Bool {
        switch runtimeStatus {
        case "preparing", "queued", "starting", "waiting": return true
        case "running": return !blockedOnThreadWait
        default: return false
        }
    }

    /// The sidebar's "waiting": blocked on child threads, or parked at idle on background work.
    private var isWaiting: Bool { (runtimeStatus == "running" && blockedOnThreadWait) || runtimeStatus == "idle" }

    var isFailed: Bool { status == "failed" }

    /// A sidebar row showing "done" (hasUnseenCompletion), or a failure you haven't opened since
    /// (hasUnseenFailure). The sidebar keeps showing failures after a visit; the notch doesn't.
    func isUnseenDone(now: Date) -> Bool {
        if isSubagent || isShelved || isRunning || isWaiting || needsAttention { return false }
        if let snoozedUntil, snoozedUntil > now { return false }
        guard let completed = latestRunCompletedAt else { return isFailed }
        guard let visited = lastVisitedAt else { return isFailed }
        return completed > visited
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

@MainActor
final class Store: ObservableObject {
    @Published private(set) var runningCount = 0
    @Published private(set) var done: [AgentThread] = []
    @Published private(set) var projects: [String: String] = [:]
    @Published var connected = false
    @Published var environmentId: String?
    private(set) var threads: [String: AgentThread] = [:] {
        didSet { recompute() }
    }

    func projectName(_ id: String) -> String { projects[id] ?? "" }

    private func recompute() {
        let running = threads.values.filter(\.isRunning).count
        let now = Date()
        let finished = threads.values.filter { $0.isUnseenDone(now: now) }.sorted {
            ($0.latestRunCompletedAt ?? .distantPast) > ($1.latestRunCompletedAt ?? .distantPast)
        }
        if running != runningCount { runningCount = running }
        if finished != done { done = finished }
    }

    /// The first snapshot on a connection replaces everything. Later snapshots are project
    /// enrichment refreshes that carry only changed projects and no threads.
    func apply(_ item: [String: Any], firstSnapshot: inout Bool) {
        switch item["kind"] as? String {
        case "snapshot":
            guard let snap = item["snapshot"] as? [String: Any] else { return }
            let threadList = snap["threads"] as? [[String: Any]] ?? []
            if firstSnapshot || !threadList.isEmpty {
                var next: [String: AgentThread] = [:]
                for t in threadList { if let t = AgentThread(t) { next[t.id] = t } }
                threads = next
                firstSnapshot = false
            }
            for p in snap["projects"] as? [[String: Any]] ?? [] { upsertProject(p) }
        case "thread.updated":
            guard let json = item["thread"] as? [String: Any], let id = json["id"] as? String else { return }
            threads[id] = (item["location"] as? String) == "active" ? AgentThread(json) : nil
        case "thread.removed":
            if let id = item["threadId"] as? String { threads[id] = nil }
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
