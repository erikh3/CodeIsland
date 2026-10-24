import XCTest
@testable import CodeIsland
import CodeIslandCore

final class WebhookMainSessionFilterTests: XCTestCase {
    func testMainSessionEventIsForwardable() throws {
        let event = try makeEvent([
            "hook_event_name": "Stop",
            "session_id": "main-session",
            "_source": "pi",
        ])

        XCTAssertFalse(HookServer.isSubsessionEvent(event))
    }
    func testScopeAllowsMainEventsWhenEnabled() throws {
        let event = try makeEvent([
            "hook_event_name": "Stop",
            "session_id": "main-session",
            "_source": "pi",
        ])

        XCTAssertTrue(HookServer.webhookScopeAllows(event, mainSessionsOnly: true))
    }


    func testOmpSubagentEventIsExcludedBeforeRouting() throws {
        let event = try makeEvent([
            "hook_event_name": "Stop",
            "session_id": "child-session",
            "_source": "pi",
            "_omp_subagent": true,
            "_omp_parent_session_id": "main-session",
            "_omp_agent_id": "ResearchScout",
            "_omp_agent_type": "scout",
        ])

        XCTAssertTrue(HookServer.isSubsessionEvent(event))
    }
    func testScopeRejectsSubagentEventsWhenEnabled() throws {
        let event = try makeEvent([
            "hook_event_name": "Stop",
            "session_id": "child-session",
            "_source": "pi",
            "_omp_subagent": true,
        ])

        XCTAssertFalse(HookServer.webhookScopeAllows(event, mainSessionsOnly: true))
        XCTAssertTrue(HookServer.webhookScopeAllows(event, mainSessionsOnly: false))
    }


    func testMergedSubagentEventIsExcludedByAgentId() throws {
        let event = try makeEvent([
            "hook_event_name": "Stop",
            "session_id": "main-session",
            "_source": "pi",
            "agent_id": "ResearchScout",
        ])

        XCTAssertTrue(HookServer.isSubsessionEvent(event))
    }

    func testCursorChildSessionIsExcludedFromTranscriptPath() throws {
        let childId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let event = try makeEvent([
            "hook_event_name": "Stop",
            "session_id": childId,
            "_source": "cursor",
            "transcript_path": "/tmp/.cursor/projects/x/agent-transcripts/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl",
        ])

        XCTAssertTrue(HookServer.isSubsessionEvent(event))
    }

    func testPluginChildEventIsExcluded() throws {
        let event = try makeEvent([
            "hook_event_name": "Stop",
            "session_id": "plugin-session",
            "_source": "opencode",
            "_via_plugin": true,
        ])

        XCTAssertTrue(HookServer.isSubsessionEvent(event))
    }

    func testSubagentLifecycleEventIsExcluded() throws {
        let event = try makeEvent([
            "hook_event_name": "SubagentStop",
            "session_id": "main-session",
            "_source": "claude",
        ])

        XCTAssertTrue(HookServer.isSubsessionEvent(event))
    }

    private func makeEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
