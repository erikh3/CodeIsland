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
}
