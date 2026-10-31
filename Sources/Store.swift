import Foundation

struct AgentThread: Identifiable, Equatable {
    let id: String
    let projectId: String
    let title: String
    let status: String
    let blockedOnThreadWait: Bool
    let latestRunCompletedAt: Date?
    let lastVisitedAt: Date?
    let hidden: Bool

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let status = json["status"] as? String else { return nil }
        self.id = id
        projectId = json["projectId"] as? String ?? ""
        title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        self.status = status
        blockedOnThreadWait = json["blockedOnThreadWait"] as? Bool ?? false
        latestRunCompletedAt = parseDate(json["latestRunCompletedAt"])
        lastVisitedAt = parseDate(json["lastVisitedAt"])
        hidden = !(json["archivedAt"] is NSNull || json["archivedAt"] == nil)
            || !(json["deletedAt"] is NSNull || json["deletedAt"] == nil)
    }

    // Mirrors the "Working" and "Connecting" pills in T3's sidebar (Sidebar.logic.ts).
    var isRunning: Bool {
        switch status {
        case "preparing", "queued", "starting", "waiting": return true
        case "running": return !blockedOnThreadWait
        default: return false
        }
    }

    var isFailed: Bool { status == "failed" }

    // Mirrors hasUnseenCompletion / hasUnseenFailure: finished after the last visit.
    // Completions in never-opened threads (agent-spawned children) don't count; failures do.
    var isUnseenDone: Bool {
        if hidden || isRunning { return false }
        guard let completed = latestRunCompletedAt else { return isFailed }
        guard let visited = lastVisitedAt else { return isFailed }
        return completed > visited
    }
}

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
    @Published private(set) var threads: [String: AgentThread] = [:]
    @Published private(set) var projects: [String: String] = [:]
    @Published var connected = false
    @Published var environmentId: String?

    var runningCount: Int { threads.values.filter(\.isRunning).count }

    var done: [AgentThread] {
        threads.values.filter(\.isUnseenDone).sorted {
            ($0.latestRunCompletedAt ?? .distantPast) > ($1.latestRunCompletedAt ?? .distantPast)
        }
    }

    func projectName(_ id: String) -> String { projects[id] ?? "" }

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
            guard (item["location"] as? String) == "active",
                  let json = item["thread"] as? [String: Any], let t = AgentThread(json) else {
                if let id = (item["thread"] as? [String: Any])?["id"] as? String { threads[id] = nil }
                return
            }
            threads[t.id] = t
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
        guard let id = p["id"] as? String else { return }
        let root = (p["workspaceRoot"] as? String).map { ($0 as NSString).lastPathComponent }
        projects[id] = (p["title"] as? String) ?? root ?? ""
    }
}
