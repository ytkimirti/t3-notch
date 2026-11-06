import Foundation

// Invariants of the T3 status port in Sources/Store.swift. Run with ./test.sh.

var failures = 0
func check(_ ok: Bool, _ name: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL \(name) (line \(line))") }
}

let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
func at(_ minutes: Int) -> String {
    ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(minutes) * 60))
}

func thread(_ fields: [String: Any] = [:]) -> AgentThread {
    var json: [String: Any] = [
        "id": "t", "projectId": "p", "title": "T", "status": "completed",
        "latestRunId": "run:1", "activeProviderThreadId": "pt:1",
        "latestRunCompletedAt": at(-5), "lastVisitedAt": at(-10),
        "lineage": ["relationshipToParent": NSNull()], "settledOverride": NSNull(),
        "archivedAt": NSNull(), "pendingRuntimeRequest": NSNull(), "pendingBackgroundTasks": [],
    ]
    for (k, v) in fields { json[k] = v }
    return AgentThread(json)!
}

// Done: completed after the last visit.
check(thread().isUnseenDone(now: now), "completed after visit is done")
check(!thread(["lastVisitedAt": at(-1)]).isUnseenDone(now: now), "visited after completion is not done")
check(!thread(["lastVisitedAt": NSNull()]).isUnseenDone(now: now), "never-opened completion is not done")
check(!thread(["lineage": ["relationshipToParent": "subagent"]]).isUnseenDone(now: now), "subagent is not done")
check(!thread(["settledOverride": "settled"]).isUnseenDone(now: now), "settled is not done")
check(thread(["settledOverride": "active"]).isUnseenDone(now: now), "unsettled is done")

// Failures.
check(thread(["status": "failed", "lastVisitedAt": NSNull()]).isUnseenDone(now: now), "never-opened failure is done")
check(!thread(["status": "failed", "lastVisitedAt": at(-1)]).isUnseenDone(now: now), "seen failure is not done")
check(thread(["status": "failed", "pendingBackgroundTasks": [["kind": "subagent", "awaited": false]]]).isUnseenDone(now: now),
      "failure ignores background hold")

// Running and waiting.
let approval = ["kind": "approval", "id": "r", "createdAt": at(-1)]
check(thread(["status": "running", "latestRunCompletedAt": NSNull()]).isRunning, "running")
check(thread(["status": "queued"]).isRunning, "queued is working")
check(thread(["status": "completed", "activityRunStatus": "running"]).isRunning, "activityRunStatus wins")
check(!thread(["status": "running", "blockedOnThreadWait": true]).isRunning, "blocked parent is waiting")
let parked = thread(["pendingBackgroundTasks": [["kind": "command", "awaited": true]]])
check(!parked.isRunning && !parked.isUnseenDone(now: now), "awaited background work parks at waiting")
check(thread(["pendingBackgroundTasks": [["kind": "command", "awaited": false]]]).isUnseenDone(now: now),
      "unawaited command does not hold")
check(thread(["lineage": ["relationshipToParent": "subagent"], "status": "running"]).isRunning, "running subagent counts")
check(thread(["status": "running", "blockedOnThreadWait": true]).isWaiting(now: now), "blocked parent counts as waiting")
check(parked.isWaiting(now: now), "parked thread counts as waiting")
check(!thread(["status": "running"]).isWaiting(now: now), "running is not waiting")
check(!thread(["status": "running", "blockedOnThreadWait": true, "lineage": ["relationshipToParent": "subagent"]]).isWaiting(now: now),
      "waiting subagent is not counted")
check(!thread().isWaiting(now: now), "done is not waiting")
check(!thread(["status": "running", "blockedOnThreadWait": true, "pendingRuntimeRequest": approval]).isWaiting(now: now),
      "approval outranks waiting")
// A subagent's live request rolls up to its parent, so the blocked parent needs you, not waits.
MainActor.assumeIsolated {
    let store = Store()
    var first = true
    let parent: [String: Any] = ["id": "p1", "status": "running", "latestRunId": "r", "blockedOnThreadWait": true]
    var child: [String: Any] = ["id": "c1", "status": "running", "latestRunId": "r", "activityRunStatus": "running",
                                "lineage": ["relationshipToParent": "subagent", "parentThreadId": "p1"],
                                "pendingRuntimeRequest": approval]
    store.apply(["kind": "snapshot", "snapshot": ["threads": [parent, child]]], firstSnapshot: &first)
    check(store.waitingCount == 0 && store.runningCount == 0, "subagent approval lifts parent out of waiting")
    child["creationSource"] = "provider"
    store.apply(["kind": "thread.updated", "location": "active", "thread": child], firstSnapshot: &first)
    check(store.waitingCount == 1, "provider-native subagent request does not roll up")
    child["creationSource"] = NSNull(); child["activityRunStatus"] = NSNull()
    store.apply(["kind": "thread.updated", "location": "active", "thread": child], firstSnapshot: &first)
    check(store.waitingCount == 1, "ended subagent run does not roll up")
}
check(!thread(["status": "running", "blockedOnThreadWait": true, "settledOverride": "settled"]).isWaiting(now: now),
      "settled is not waiting")
check(!thread(["status": "running", "blockedOnThreadWait": true, "snoozedUntil": at(30), "snoozedAt": at(-20)]).isWaiting(now: now),
      "snoozed is not waiting")

// Requests outrank working and done.
check(!thread(["status": "running", "pendingRuntimeRequest": approval]).isRunning, "approval is not running")
check(!thread(["pendingRuntimeRequest": approval]).isUnseenDone(now: now), "approval is not done")
check(thread(["pendingRuntimeRequest": ["kind": "auth_refresh"]]).isUnseenDone(now: now), "auth refresh still done")
check(thread(["status": "running", "pendingRuntimeRequest": ["kind": "user_input", "blocking": false]]).isRunning,
      "non-blocking question while working stays working")
check(!thread(["status": "running", "pendingRuntimeRequest": ["kind": "user_input"]]).isRunning,
      "blocking question is input")
check(!thread(["pendingGuestMessageCount": 2]).isUnseenDone(now: now), "guest request is not done")

// Snooze.
check(!thread(["snoozedUntil": at(30), "snoozedAt": at(-20)]).isUnseenDone(now: now), "snoozed is hidden")
check(thread(["snoozedUntil": at(-1), "snoozedAt": at(-20)]).isUnseenDone(now: now), "expired snooze is done")
check(thread(["status": "failed", "snoozedUntil": at(30), "snoozedAt": at(-20), "lastVisitedAt": NSNull()]).isUnseenDone(now: now),
      "failure after snoozing wakes it")
check(!thread(["status": "failed", "snoozedUntil": at(30), "snoozedAt": at(-1), "lastVisitedAt": NSNull()]).isUnseenDone(now: now),
      "failure before snoozing stays snoozed")

// Stream handling.
MainActor.assumeIsolated {
    let store = Store()
    var first = true
    let t: [String: Any] = ["id": "a", "projectId": "p", "title": "A", "status": "completed", "latestRunId": "r",
                            "latestRunCompletedAt": at(-5), "lastVisitedAt": at(-10)]
    store.apply(["kind": "snapshot", "snapshot": ["threads": [t], "projects": [["id": "p", "title": "proj"]]]], firstSnapshot: &first)
    check(store.done.count == 1 && store.projectName("p") == "proj", "snapshot loads")
    store.apply(["kind": "snapshot", "snapshot": ["threads": [], "projects": [["id": "p", "title": "renamed"]]]], firstSnapshot: &first)
    check(store.done.count == 1 && store.projectName("p") == "renamed", "enrichment snapshot keeps threads")
    var visited = t; visited["lastVisitedAt"] = at(0)
    store.apply(["kind": "thread.updated", "location": "active", "thread": visited], firstSnapshot: &first)
    check(store.done.isEmpty, "visit clears done")
    store.apply(["kind": "thread.updated", "location": "active", "thread": t], firstSnapshot: &first)
    store.apply(["kind": "thread.updated", "location": "archive", "thread": t], firstSnapshot: &first)
    check(store.done.isEmpty, "archived update removes")
    store.apply(["kind": "thread.updated", "location": "active", "thread": t], firstSnapshot: &first)
    store.apply(["kind": "thread.removed", "location": "active", "threadId": "a"], firstSnapshot: &first)
    check(store.done.isEmpty, "removal removes")
    var blocked = t; blocked["status"] = "running"; blocked["blockedOnThreadWait"] = true
    store.apply(["kind": "thread.updated", "location": "active", "thread": blocked], firstSnapshot: &first)
    check(store.waitingCount == 1 && store.runningCount == 0 && store.done.isEmpty, "store counts waiting")
}

// Several servers: counted together, each keeps its own threads, a dropped one fades out.
MainActor.assumeIsolated {
    let store = Store()
    var firstA = true, firstB = true
    let run: [String: Any] = ["id": "same-id", "status": "running", "latestRunId": "r"]
    let fin: [String: Any] = ["id": "f", "projectId": "p", "title": "F", "status": "completed", "latestRunId": "r",
                              "latestRunCompletedAt": at(-5), "lastVisitedAt": at(-10)]
    store.apply(["kind": "snapshot", "snapshot": ["threads": [run]]], firstSnapshot: &firstA, source: 0)
    store.apply(["kind": "snapshot", "snapshot": ["threads": [run, fin]]], firstSnapshot: &firstB, source: 1)
    store.setConnected(0, true); store.setConnected(1, true)
    check(store.runningCount == 2 && store.done.count == 1, "servers add up, same id on each counts twice")
    check(store.done.first?.source == 1, "done thread knows its server")
    store.apply(["kind": "thread.removed", "threadId": "same-id"], firstSnapshot: &firstA, source: 0)
    check(store.runningCount == 1, "removal stays on its server")
    store.apply(["kind": "snapshot", "snapshot": ["threads": [run]]], firstSnapshot: &firstA, source: 0)
    store.setConnected(1, false)
    check(store.runningCount == 2 && store.connected, "a server that just dropped still counts")
    store.staleAfter = 0.05
    Thread.sleep(forTimeInterval: 0.1)
    store.setConnected(0, false) // server 1 is past its grace by now; server 0 just dropped
    check(store.runningCount == 1 && !store.connected, "with none connected, what last counted shows")
    store.setConnected(0, true)
    check(store.runningCount == 1 && store.done.isEmpty, "a server already stale stays out after an outage")
    store.environments = [0: "env", 1: "env"]
    store.setConnected(1, true)
    check(store.runningCount == 1, "one server configured twice counts once")
}
MainActor.assumeIsolated {
    // Both drop (sleep), one is back first (wake): the other gets a fresh grace.
    let store = Store()
    var a = true, b = true
    let run: [String: Any] = ["id": "r", "status": "running", "latestRunId": "r"]
    store.apply(["kind": "snapshot", "snapshot": ["threads": [run]]], firstSnapshot: &a, source: 0)
    store.apply(["kind": "snapshot", "snapshot": ["threads": [run]]], firstSnapshot: &b, source: 1)
    store.setConnected(0, true); store.setConnected(1, true)
    store.staleAfter = 0.05
    store.setConnected(0, false); store.setConnected(1, false)
    check(store.runningCount == 2, "outage shows the last known state")
    Thread.sleep(forTimeInterval: 0.1) // asleep longer than the grace
    store.setConnected(1, true)
    check(store.runningCount == 2, "the slower server keeps counting after a wake")
}

// Wing figures: every agent while ten fit, else ten split across the groups.
check(WingLayout.slots([3, 2, 4]) == [3, 2, 4], "ten or fewer all show")
check(WingLayout.slots([10, 0, 0]) == [10, 0, 0], "ten in one group all show")
check(WingLayout.slots([12, 0, 0]) == [10, 0, 0], "one group caps at ten")
check(WingLayout.slots([20, 1, 0]) == [9, 1, 0], "small group keeps its figure")
check(WingLayout.slots([8, 2, 3]) == [7, 1, 2], "overflow goes to the most left out")
check(WingLayout.slots([9999, 9999, 9999]) == [4, 3, 3], "ties favour earlier groups")
check(WingLayout.slots([0, 0, 0]) == [0, 0, 0], "nothing shows nothing")
let crowded = WingLayout(style: .critters, running: 12, waiting: 0, done: 1)
check(crowded.items.filter { if case .more = $0.item { return false }; return true }.count == 10, "layout draws ten figures")
check(crowded.items.contains { $0.item == .more(3, .running) }, "layout counts the rest")

print(failures == 0 ? "all tests passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
