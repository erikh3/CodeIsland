import XCTest
@testable import CodeIsland
import CodeIslandCore

/// What the island shows after the queues are re-evaluated
/// (`showNextPending`): a completion card must not get stuck behind a
/// request that stays hidden.
@MainActor
final class PanelCardFlowTests: XCTestCase {
    private var appState: AppState!
    private var pending: [Task<Data, Never>] = []
    private var saved: [String: Any?] = [:]
    private let keys = [
        SettingsKey.autoExpandOnPermission, SettingsKey.autoExpandOnQuestion,
        SettingsKey.smartSuppress, SettingsKey.completionNotificationStyle,
        SettingsKey.followUpReminderMinutes,
    ]

    override func setUp() async throws {
        try await super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnQuestion)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set("expand", forKey: SettingsKey.completionNotificationStyle)
        UserDefaults.standard.set(0, forKey: SettingsKey.followUpReminderMinutes)
        pending = []
        appState = AppState()
        // The real card stays up 5 s; the flow is the same at 50 ms.
        appState.completionAutoCollapseDelay = 0.05
    }

    override func tearDown() async throws {
        let waiters = appState.permissionQueue.map(\.event) + appState.questionQueue.map(\.event)
        for event in waiters {
            appState.handlePeerDisconnect(sessionId: event.sessionId ?? "default", agentId: event.agentId)
        }
        for t in pending { _ = await t.value }
        appState = nil
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        try await super.tearDown()
    }

    // MARK: - Completion cards behind hidden requests

    /// "Auto-expand on question" off: the question waits behind its badge.
    /// A finished turn's card must still fold when its time is up.
    func testCompletionCardCollapsesWhileAHiddenQuestionWaits() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        try await ask("QX")
        XCTAssertEqual(appState.surface, .collapsed)
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "C1", "cwd": "/tmp"]))
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "C1"))

        await waitForSurface(.collapsed)
        XCTAssertEqual(appState.surface, .collapsed, "completion card should auto-collapse")
        XCTAssertEqual(appState.hiddenPendingQuestionSessionId, "QX", "the question keeps its badge")
    }

    /// Same with "auto-expand on approval" off (#292).
    func testCompletionCardCollapsesWhileAHiddenApprovalWaits() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnPermission)
        try await requestApproval("PX")
        XCTAssertEqual(appState.surface, .collapsed)
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "C2", "cwd": "/tmp"]))
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "C2"))

        await waitForSurface(.collapsed)
        XCTAssertEqual(appState.surface, .collapsed, "completion card should auto-collapse")
    }

    /// Finished turns queued behind the first card are shown in turn, not
    /// dropped because a hidden request is waiting.
    func testQueuedCompletionsAreShownBehindAHiddenRequest() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        try await ask("QY")
        appState.completionAutoCollapseDelay = 0.3
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "first", "cwd": "/tmp"]))
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "second", "cwd": "/tmp"]))
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "first"))

        await waitForSurface(.completionCard(sessionId: "second"))
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "second"))
        await waitForSurface(.collapsed)
        XCTAssertEqual(appState.surface, .collapsed)
    }

    /// A request arriving hidden while a completion card is up does not cut
    /// that card short by jumping to the next finished turn.
    func testHiddenRequestArrivingDoesNotCutACompletionCardShort() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnPermission)
        appState.completionAutoCollapseDelay = 30
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "shown", "cwd": "/tmp"]))
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "queued", "cwd": "/tmp"]))
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "shown"))

        try await requestApproval("hidden")
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "shown"))
    }

    /// The session of the completion card on screen goes away while the
    /// pointer is on the card: nothing is left on it, so it folds.
    func testRemovedSessionsCompletionCardFoldsEvenUnderThePointer() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        appState.completionAutoCollapseDelay = 30
        try await ask("QZ")
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "gone", "cwd": "/tmp"]))
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "gone"))
        appState.completionHasBeenEntered = true

        appState.removeSession("gone")
        XCTAssertEqual(appState.surface, .collapsed)
    }

    // MARK: - Helpers

    private func waitForSurface(_ expected: IslandSurface, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while appState.surface != expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func requestApproval(_ sid: String) async throws {
        let e = try event(["hook_event_name": "PermissionRequest", "session_id": sid, "tool_name": "Bash", "tool_input": ["command": "echo"]])
        pending.append(Task<Data, Never> { [appState] in
            await withCheckedContinuation { appState!.handlePermissionRequest(e, continuation: $0) }
        })
        await Task.yield()
    }

    private func ask(_ sid: String) async throws {
        let e = try event([
            "hook_event_name": "PermissionRequest", "session_id": sid, "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]],
        ])
        pending.append(Task<Data, Never> { [appState] in
            await withCheckedContinuation { appState!.handleAskUserQuestion(e, continuation: $0) }
        })
        await Task.yield()
    }

    private func event(_ p: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: p)))
    }
}
