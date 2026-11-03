import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateOmpSessionHandoffTests: XCTestCase {
    func testSessionStartReplacesOlderOmpRootOnSameHerdrPane() throws {
        let appState = AppState()

        appState.handleEvent(try makeSessionStart(
            sessionId: "pi-temporary",
            paneId: "w1:p1",
            socketPath: "/tmp/herdr.sock"
        ))
        appState.handleEvent(try makeSessionStart(
            sessionId: "pi-unrelated",
            paneId: "w1:p2",
            socketPath: "/tmp/herdr.sock"
        ))
        appState.handleEvent(try makeSessionStart(
            sessionId: "pi-persisted",
            paneId: "w1:p1",
            socketPath: "/tmp/herdr.sock"
        ))

        XCTAssertNil(appState.sessions["pi-temporary"])
        XCTAssertNotNil(appState.sessions["pi-persisted"])
        XCTAssertNotNil(appState.sessions["pi-unrelated"])
    }

    private func makeSessionStart(
        sessionId: String,
        paneId: String,
        socketPath: String
    ) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": sessionId,
            "_source": "pi",
            "_herdr_pane_id": paneId,
            "_herdr_socket_path": socketPath,
            "cwd": "/tmp/project",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }

    // MARK: - Herdr blocked state survives unrelated events

    func testHerdrBlockedStatusSurvivesUserPromptSubmit() throws {
        let appState = AppState()
        let sessionId = "pi-blocked-session"
        var snap = SessionSnapshot(startTime: Date())
        snap.source = "pi"
        snap.status = .waitingApproval
        snap.herdrBlocked = true
        snap.toolDescription = "Waiting for approval"
        appState.sessions[sessionId] = snap

        // UserPromptSubmit would normally set status = .processing and clear toolDescription
        let event = try makeEvent(
            eventName: "UserPromptSubmit",
            sessionId: sessionId,
            extra: ["prompt": "do the thing"]
        )
        appState.handleEvent(event)

        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingApproval,
            "Herdr-blocked status must survive UserPromptSubmit")
        XCTAssertEqual(appState.sessions[sessionId]?.toolDescription, "Waiting for approval",
            "Herdr blocked label must be preserved through UserPromptSubmit")
    }

    func testHerdrBlockedStatusSurvivesStop() throws {
        let appState = AppState()
        let sessionId = "pi-blocked-stop"
        var snap = SessionSnapshot(startTime: Date())
        snap.source = "pi"
        snap.status = .waitingApproval
        snap.herdrBlocked = true
        snap.toolDescription = "Blocked reason"
        appState.sessions[sessionId] = snap

        let event = try makeEvent(eventName: "Stop", sessionId: sessionId)
        appState.handleEvent(event)

        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingApproval,
            "Herdr-blocked status must survive Stop")
        XCTAssertEqual(appState.sessions[sessionId]?.toolDescription, "Blocked reason",
            "Herdr blocked label must be preserved through Stop")
    }

    func testHerdrBlockedSessionDoesNotEnqueueCompletion() throws {
        let appState = AppState()
        let sessionId = "pi-blocked-completion"
        var snap = SessionSnapshot(startTime: Date())
        snap.source = "pi"
        snap.status = .waitingApproval
        snap.herdrBlocked = true
        snap.toolDescription = "Blocked"
        appState.sessions[sessionId] = snap

        let event = try makeEvent(eventName: "Stop", sessionId: sessionId)
        appState.handleEvent(event)

        // No completion card should have been enqueued or shown
        XCTAssertNil(appState.justCompletedSessionId,
            "Stop under Herdr block must not produce a completion card")
    }

    func testUnrelatedSessionUnaffectedByHerdrBlock() throws {
        let appState = AppState()
        let blockedId = "pi-blocked"
        let unrelatedId = "pi-unrelated"

        var blocked = SessionSnapshot(startTime: Date())
        blocked.source = "pi"
        blocked.status = .waitingApproval
        blocked.herdrBlocked = true
        blocked.toolDescription = "Blocked"
        appState.sessions[blockedId] = blocked

        var unrelated = SessionSnapshot(startTime: Date())
        unrelated.source = "pi"
        unrelated.status = .running
        appState.sessions[unrelatedId] = unrelated

        let event = try makeEvent(eventName: "Stop", sessionId: unrelatedId)
        appState.handleEvent(event)

        // Blocked session untouched
        XCTAssertEqual(appState.sessions[blockedId]?.status, .waitingApproval)
        XCTAssertEqual(appState.sessions[blockedId]?.herdrBlocked, true)
        // Unrelated session transitioned normally to idle
        XCTAssertEqual(appState.sessions[unrelatedId]?.status, .idle)
    }


    // MARK: - Non-blocked sessions must transition normally

    func testNonBlockedStopTransitionsToIdle() throws {
        let appState = AppState()
        let sessionId = "pi-nonblocked-stop"
        var snap = SessionSnapshot(startTime: Date())
        snap.source = "pi"
        snap.status = .running
        snap.herdrBlocked = false
        appState.sessions[sessionId] = snap

        let event = try makeEvent(eventName: "Stop", sessionId: sessionId)
        appState.handleEvent(event)

        XCTAssertEqual(appState.sessions[sessionId]?.status, .idle,
            "Non-blocked Stop must transition to idle, not remain at waitingApproval")
    }

    func testNonBlockedUserPromptSubmitTransitionsToProcessing() throws {
        let appState = AppState()
        let sessionId = "pi-nonblocked-ups"
        var snap = SessionSnapshot(startTime: Date())
        snap.source = "pi"
        snap.status = .idle
        snap.herdrBlocked = false
        appState.sessions[sessionId] = snap

        let event = try makeEvent(
            eventName: "UserPromptSubmit",
            sessionId: sessionId,
            extra: ["prompt": "hello"]
        )
        appState.handleEvent(event)

        XCTAssertEqual(appState.sessions[sessionId]?.status, .processing,
            "Non-blocked UserPromptSubmit must transition to processing, not be stuck at waitingApproval")
    }

    // MARK: - Herdr blocked with nil label still guards status

    func testHerdrBlockedWithNilLabelStillSurvivesStop() throws {
        let appState = AppState()
        let sessionId = "pi-blocked-nil-label"
        var snap = SessionSnapshot(startTime: Date())
        snap.source = "pi"
        snap.status = .waitingApproval
        snap.herdrBlocked = true
        snap.toolDescription = nil   // no label text set
        appState.sessions[sessionId] = snap

        let event = try makeEvent(eventName: "Stop", sessionId: sessionId)
        appState.handleEvent(event)

        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingApproval,
            "Herdr-blocked session with nil label must stay at waitingApproval after Stop")
    }

    // MARK: - Helpers

    private func makeEvent(
        eventName: String,
        sessionId: String,
        extra: [String: Any] = [:]
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": eventName,
            "session_id": sessionId,
            "_source": "pi",
            "cwd": "/tmp/project",
        ]
        for (k, v) in extra { payload[k] = v }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
