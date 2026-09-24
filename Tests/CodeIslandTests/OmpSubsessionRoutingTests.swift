import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Coverage for OMP task-child routing in HookServer.
/// Tests verify separate / merge / hide, AppState key resolution, child-first
/// metadata, two-root disambiguation, concurrent children, malformed metadata,
/// already-merged payloads, and nested dotted child IDs.
@MainActor
final class OmpSubsessionRoutingTests: XCTestCase {

    // MARK: - Session IDs

    private let rootId     = "pi-aaaaaaaa-0000-0000-0000-000000000001"
    private let childId    = "pi-bbbbbbbb-0000-0000-0000-000000000002"
    private let child2Id   = "pi-cccccccc-0000-0000-0000-000000000003"
    private let root2Id    = "pi-dddddddd-0000-0000-0000-000000000004"
    private let providerParentId = "raw-provider-uuid-parent"

    // MARK: - Helpers

    private func withPluginSessionMode(_ mode: String, _ body: () throws -> Void) rethrows {
        let previous = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
        UserDefaults.standard.set(mode, forKey: SettingsKey.pluginSessionMode)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: SettingsKey.pluginSessionMode)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.pluginSessionMode)
            }
        }
        try body()
    }

    private func route(
        appState: AppState,
        payload: [String: Any],
        parentPidLookup: @escaping (pid_t) -> pid_t? = { _ in nil }
    ) throws -> (processedData: Data, responseData: Data?, raw: [String: Any]) {
        let server = HookServer(appState: appState, parentPidLookup: parentPidLookup)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let routed = server.routeSubsessionPayloadIfNeededForTesting(data: data)
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: routed.processedData) as? [String: Any]
        )
        return (routed.processedData, routed.responseData, raw)
    }

    private func ompChildPayload(
        sessionId: String,
        parentSessionId: String,
        agentId: String = "ResearchScout",
        agentType: String = "scout",
        eventName: String = "PostToolUse",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "_omp_subagent": true,
            "_omp_parent_session_id": parentSessionId,
            "_omp_agent_id": agentId,
            "_omp_agent_type": agentType,
            "session_id": sessionId,
            "session_title": "Subagent · \(agentId)",
            "_source": "pi",
            "hook_event_name": eventName,
        ]
        for (k, v) in extra { payload[k] = v }
        return payload
    }

    private func makeRunningSession(source: String = "pi") -> SessionSnapshot {
        var snap = SessionSnapshot(startTime: Date())
        snap.source = source
        snap.status = .running
        return snap
    }

    // MARK: - Byte probe

    func testMayBeOmpSubagentReturnsTrueWhenMarkerPresent() throws {
        let data = try JSONSerialization.data(withJSONObject: ["_omp_subagent": true])
        XCTAssertTrue(HookServer.mayBeOmpSubagent(data: data))
    }

    func testMayBeOmpSubagentReturnsFalseWhenMarkerAbsent() throws {
        let data = try JSONSerialization.data(withJSONObject: ["session_id": "abc"])
        XCTAssertFalse(HookServer.mayBeOmpSubagent(data: data))
    }

    // MARK: - Separate mode

    func testSeparateModePassesThroughChildUnchanged() throws {
        try withPluginSessionMode("separate") {
            let appState = AppState()
            appState.sessions[rootId] = makeRunningSession()

            let routed = try route(appState: appState, payload: ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId
            ))
            XCTAssertNil(routed.responseData)
            // session_id stays as-is — child keeps its own card
            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
            XCTAssertNil(routed.raw["agent_id"])
            XCTAssertNil(routed.raw["_omp_child_session_id"])
        }
    }

    // MARK: - Merge mode

    func testMergeModeRewritesChildOntoParent() throws {
        try withPluginSessionMode("merge") {
            let appState = AppState()
            appState.sessions[rootId] = makeRunningSession()

            let routed = try route(appState: appState, payload: ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId,
                agentId: "ResearchScout",
                agentType: "scout"
            ))
            XCTAssertNil(routed.responseData)
            XCTAssertEqual(routed.raw["session_id"] as? String, rootId)
            XCTAssertEqual(routed.raw["agent_id"] as? String, "ResearchScout")
            XCTAssertEqual(routed.raw["agent_type"] as? String, "scout")
            XCTAssertEqual(routed.raw["_omp_child_session_id"] as? String, childId)
            // Routing-only fields removed
            XCTAssertNil(routed.raw["_omp_parent_session_id"])
            XCTAssertNil(routed.raw["_omp_agent_id"])
            XCTAssertNil(routed.raw["_omp_agent_type"])
            // _omp_subagent flag retained for downstream reducer
            XCTAssertEqual(routed.raw["_omp_subagent"] as? Bool, true)
        }
    }

    func testMergeModeMaintainsChildFirstMetadataForParentInit() throws {
        try withPluginSessionMode("merge") {
            // Child arrives before the parent card exists.
            // Metadata like _source, cwd must survive so fillMissingParentMetadata works.
            let appState = AppState()

            let routed = try route(appState: appState, payload: ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId,
                extra: [
                    "cwd": "/home/user/project",
                    "_source": "pi",
                ]
            ))
            XCTAssertNil(routed.responseData)
            // session_id rewritten to parent even though parent card doesn't exist yet
            XCTAssertEqual(routed.raw["session_id"] as? String, rootId)
            // Metadata fields preserved
            XCTAssertEqual(routed.raw["cwd"] as? String, "/home/user/project")
            XCTAssertEqual(routed.raw["_source"] as? String, "pi")
        }
    }

    // MARK: - Hide mode

    func testHideModeNonPermissionEventRespondsEmpty() throws {
        try withPluginSessionMode("hide") {
            let appState = AppState()
            appState.sessions[rootId] = makeRunningSession()

            let server = HookServer(appState: appState)
            let payload = ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId,
                eventName: "PostToolUse"
            )
            let data = try JSONSerialization.data(withJSONObject: payload)
            let routed = server.routeSubsessionPayloadIfNeededForTesting(data: data)
            XCTAssertNotNil(routed.responseData)
            // Non-permission events get empty JSON object response
            if let response = routed.responseData,
               let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any] {
                XCTAssertTrue(obj.isEmpty)
            }
            // processedData unchanged
            XCTAssertEqual(routed.processedData, data)
        }
    }

    func testHideModePermissionEventRespondsAllow() throws {
        try withPluginSessionMode("hide") {
            let appState = AppState()
            appState.sessions[rootId] = makeRunningSession()

            let server = HookServer(appState: appState)
            let payload = ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId,
                eventName: "PermissionRequest",
                extra: ["hook_event_name": "PermissionRequest"]
            )
            let data = try JSONSerialization.data(withJSONObject: payload)
            let routed = server.routeSubsessionPayloadIfNeededForTesting(data: data)
            XCTAssertNotNil(routed.responseData)
            if let response = routed.responseData,
               let text = String(data: response, encoding: .utf8) {
                XCTAssertTrue(text.contains("allow"), "Expected allow response, got: \(text)")
            }
        }
    }

    // MARK: - Resolved AppState parent key

    func testMergeModeResolvesProviderParentToAppStateKey() throws {
        try withPluginSessionMode("merge") {
            // Parent exists under a different AppState key but with matching providerSessionId.
            let appState = AppState()
            var parentSnap = makeRunningSession()
            parentSnap.providerSessionId = providerParentId
            let appStateKey = "pi-resolved-key-for-provider"
            appState.sessions[appStateKey] = parentSnap

            let routed = try route(appState: appState, payload: ompChildPayload(
                sessionId: childId,
                parentSessionId: providerParentId  // raw provider ID, not AppState key
            ))
            XCTAssertNil(routed.responseData)
            // session_id must be the resolved AppState key, not the raw provider ID
            XCTAssertEqual(routed.raw["session_id"] as? String, appStateKey)
            XCTAssertEqual(routed.raw["_omp_child_session_id"] as? String, childId)
        }
    }

    func testMergeModeUsesProviderIdWhenNoCardExists() throws {
        try withPluginSessionMode("merge") {
            // No AppState card for the parent yet — fall back to raw parent session ID.
            let appState = AppState()

            let routed = try route(appState: appState, payload: ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId
            ))
            XCTAssertNil(routed.responseData)
            XCTAssertEqual(routed.raw["session_id"] as? String, rootId)
        }
    }

    // MARK: - Two roots sharing CWD and PID

    func testTwoRootsWithSameCwdAndPidRemainSeparate() throws {
        // OMP routing uses explicit _omp_parent_session_id; CWD/PID are irrelevant.
        // Each child is attached to its explicit parent, not an ambiguous guess.
        try withPluginSessionMode("merge") {
            let appState = AppState()
            var root1 = makeRunningSession()
            root1.cliPid = 42_001
            appState.sessions[rootId] = root1

            var root2 = makeRunningSession()
            root2.cliPid = 42_001
            appState.sessions[root2Id] = root2

            // Child explicitly names rootId as its parent
            let routed = try route(appState: appState, payload: ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId
            ))
            XCTAssertEqual(routed.raw["session_id"] as? String, rootId,
                "Child with explicit parent ID must not be guessed onto root2")
        }
    }

    // MARK: - Two concurrent children, one explicit root

    func testTwoConcurrentChildrenMergeOntoSameRoot() throws {
        try withPluginSessionMode("merge") {
            let appState = AppState()
            appState.sessions[rootId] = makeRunningSession()

            let routed1 = try route(appState: appState, payload: ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId,
                agentId: "ResearchScout",
                agentType: "scout"
            ))
            let routed2 = try route(appState: appState, payload: ompChildPayload(
                sessionId: child2Id,
                parentSessionId: rootId,
                agentId: "CodeReviewer",
                agentType: "reviewer"
            ))

            XCTAssertEqual(routed1.raw["session_id"] as? String, rootId)
            XCTAssertEqual(routed1.raw["agent_id"] as? String, "ResearchScout")
            XCTAssertEqual(routed1.raw["_omp_child_session_id"] as? String, childId)

            XCTAssertEqual(routed2.raw["session_id"] as? String, rootId)
            XCTAssertEqual(routed2.raw["agent_id"] as? String, "CodeReviewer")
            XCTAssertEqual(routed2.raw["_omp_child_session_id"] as? String, child2Id)
        }
    }

    // MARK: - Malformed metadata unchanged

    func testMalformedOmpPayloadPassesThrough() throws {
        struct Case {
            let label: String
            let payload: [String: Any]
            let expectedSessionId: String
        }
        let cases: [Case] = [
            Case(
                label: "missing _omp_parent_session_id",
                payload: [
                    "_omp_subagent": true,
                    "_omp_agent_id": "ResearchScout",
                    "_omp_agent_type": "scout",
                    "session_id": childId,
                    "_source": "pi",
                    "hook_event_name": "PostToolUse",
                ],
                expectedSessionId: childId
            ),
            Case(
                label: "missing _omp_agent_id",
                payload: [
                    "_omp_subagent": true,
                    "_omp_parent_session_id": rootId,
                    "_omp_agent_type": "scout",
                    "session_id": childId,
                    "_source": "pi",
                    "hook_event_name": "PostToolUse",
                ],
                expectedSessionId: childId
            ),
            Case(
                label: "child and parent session_id identical",
                payload: [
                    "_omp_subagent": true,
                    "_omp_parent_session_id": rootId,
                    "_omp_agent_id": "ResearchScout",
                    "_omp_agent_type": "scout",
                    "session_id": rootId,
                    "_source": "pi",
                    "hook_event_name": "PostToolUse",
                ],
                expectedSessionId: rootId
            ),
            Case(
                label: "_omp_subagent is string not bool",
                payload: [
                    "_omp_subagent": "true",
                    "_omp_parent_session_id": rootId,
                    "_omp_agent_id": "ResearchScout",
                    "_omp_agent_type": "scout",
                    "session_id": childId,
                    "_source": "pi",
                    "hook_event_name": "PostToolUse",
                ],
                expectedSessionId: childId
            ),
        ]
        try withPluginSessionMode("merge") {
            for c in cases {
                let appState = AppState()
                let routed = try route(appState: appState, payload: c.payload)
                XCTAssertEqual(routed.raw["session_id"] as? String, c.expectedSessionId,
                    "session_id wrong for case: \(c.label)")
                XCTAssertNil(routed.raw["agent_id"],
                    "agent_id should be nil for case: \(c.label)")
            }
        }
    }

    // MARK: - Supervised OMP process routing

    func testNestedOmpProcessMergesIntoAncestorSession() throws {
        try withPluginSessionMode("merge") {
            let appState = AppState()
            var parent = makeRunningSession()
            parent.cliPid = 4_100
            appState.sessions[rootId] = parent

            let parents: [pid_t: pid_t] = [4_300: 4_200, 4_200: 4_100, 4_100: 1]
            let routed = try route(
                appState: appState,
                payload: [
                    "session_id": childId,
                    "_source": "pi",
                    "_ppid": 4_300,
                    "hook_event_name": "SessionStart",
                    "cwd": "/project",
                ],
                parentPidLookup: { parents[$0] }
            )

            XCTAssertEqual(routed.raw["session_id"] as? String, rootId)
            XCTAssertEqual(routed.raw["agent_id"] as? String, childId)
            XCTAssertEqual(routed.raw["agent_type"] as? String, "omp")
            XCTAssertEqual(routed.raw["_omp_child_session_id"] as? String, childId)
            XCTAssertEqual(routed.raw["_omp_subagent"] as? Bool, true)
        }
    }

    func testNestedOmpProcessInSeparateModeDoesNotReplaceParentCard() throws {
        try withPluginSessionMode("separate") {
            let appState = AppState()
            var parent = makeRunningSession()
            parent.cliPid = 4_100
            appState.sessions[rootId] = parent

            let parents: [pid_t: pid_t] = [4_300: 4_200, 4_200: 4_100, 4_100: 1]
            let routed = try route(
                appState: appState,
                payload: [
                    "session_id": childId,
                    "_source": "pi",
                    "_ppid": 4_300,
                    "hook_event_name": "SessionStart",
                    "cwd": "/project",
                ],
                parentPidLookup: { parents[$0] }
            )

            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
            XCTAssertEqual(routed.raw["_omp_parent_session_id"] as? String, rootId)
            XCTAssertEqual(routed.raw["_omp_subagent"] as? Bool, true)

            let event = try XCTUnwrap(HookEvent(from: routed.processedData))
            appState.handleEvent(event)
            XCTAssertNotNil(appState.sessions[rootId])
            XCTAssertNotNil(appState.sessions[childId])
        }
    }

    func testRestoreCleanupRemovesNestedOmpProcessInMergeMode() {
        withPluginSessionMode("merge") {
            let appState = AppState()
            var parent = makeRunningSession()
            parent.status = .idle
            parent.cliPid = 4_100
            appState.sessions[rootId] = parent

            var child = makeRunningSession()
            child.status = .idle
            child.cliPid = 4_300
            appState.sessions[childId] = child

            let parents: [pid_t: pid_t] = [4_300: 4_200, 4_200: 4_100, 4_100: 1]
            appState.removeRestoredNestedOmpSessions(parentPidLookup: { parents[$0] })

            XCTAssertNotNil(appState.sessions[rootId])
            XCTAssertNil(appState.sessions[childId])
        }
    }

    func testRestoreCleanupPreservesNestedOmpProcessInSeparateMode() {
        withPluginSessionMode("separate") {
            let appState = AppState()
            var parent = makeRunningSession()
            parent.status = .idle
            parent.cliPid = 4_100
            appState.sessions[rootId] = parent

            var child = makeRunningSession()
            child.status = .idle
            child.cliPid = 4_300
            appState.sessions[childId] = child

            let parents: [pid_t: pid_t] = [4_300: 4_200, 4_200: 4_100, 4_100: 1]
            appState.removeRestoredNestedOmpSessions(parentPidLookup: { parents[$0] })

            XCTAssertNotNil(appState.sessions[rootId])
            XCTAssertNotNil(appState.sessions[childId])
        }
    }

    func testIndependentOmpProcessIsNotRoutedBySharedPaneAlone() throws {
        try withPluginSessionMode("merge") {
            let appState = AppState()
            var parent = makeRunningSession()
            parent.cliPid = 4_100
            appState.sessions[rootId] = parent

            let routed = try route(
                appState: appState,
                payload: [
                    "session_id": childId,
                    "_source": "pi",
                    "_ppid": 5_000,
                    "hook_event_name": "SessionStart",
                    "cwd": "/project",
                ],
                parentPidLookup: { _ in 1 }
            )

            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
            XCTAssertNil(routed.raw["_omp_subagent"])
        }
    }

    // MARK: - Already merged unchanged

    func testAlreadyMergedPayloadIsUnchanged() throws {
        try withPluginSessionMode("merge") {
            let appState = AppState()

            // Already-routed: has _omp_subagent + agent_id + _omp_child_session_id,
            // but _omp_parent_session_id is absent.
            let alreadyMerged: [String: Any] = [
                "_omp_subagent": true,
                "agent_id": "ResearchScout",
                "_omp_child_session_id": childId,
                "session_id": rootId,
                "_source": "pi",
                "hook_event_name": "PostToolUse",
            ]
            let routed = try route(appState: appState, payload: alreadyMerged)
            XCTAssertNil(routed.responseData)
            XCTAssertEqual(routed.raw["session_id"] as? String, rootId)
            XCTAssertEqual(routed.raw["agent_id"] as? String, "ResearchScout")
            XCTAssertEqual(routed.raw["_omp_child_session_id"] as? String, childId)
            // No double-routing
            XCTAssertNil(routed.raw["_omp_parent_session_id"])
        }
    }

    // MARK: - Nested dotted child ID

    func testNestedDottedChildIdIsPreservedInMerge() throws {
        try withPluginSessionMode("merge") {
            let appState = AppState()
            appState.sessions[rootId] = makeRunningSession()

            let nestedAgentId = "ParentScout.ChildReviewer"
            let routed = try route(appState: appState, payload: ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId,
                agentId: nestedAgentId,
                agentType: "reviewer"
            ))
            XCTAssertNil(routed.responseData)
            XCTAssertEqual(routed.raw["session_id"] as? String, rootId)
            // Dotted nested ID preserved exactly as-is
            XCTAssertEqual(routed.raw["agent_id"] as? String, nestedAgentId)
            XCTAssertEqual(routed.raw["_omp_child_session_id"] as? String, childId)
        }
    }

    // MARK: - OMP routing precedes Cursor/Codex/plugin routing

    func testOmpRoutingPrecedesCursorRouting() throws {
        // A payload that looks like it could be Cursor (has agent-transcripts)
        // but also carries OMP metadata must be handled by OMP routing only.
        try withPluginSessionMode("merge") {
            let appState = AppState()
            appState.sessions[rootId] = makeRunningSession()

            var payload = ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId,
                agentId: "ResearchScout",
                agentType: "scout"
            )
            // Add a Cursor-style transcript path to the payload
            payload["transcript_path"] = "/Users/u/.cursor/projects/x/agent-transcripts/parent/child.jsonl"
            payload["_source"] = "pi"

            let routed = try route(appState: appState, payload: payload)
            // OMP routing must have fired: session_id is rootId, agent_id is set
            XCTAssertEqual(routed.raw["session_id"] as? String, rootId)
            XCTAssertEqual(routed.raw["agent_id"] as? String, "ResearchScout")
            // No Cursor-specific fields added
            XCTAssertNil(routed.raw["_cursor_subagent"])
        }
    }
}
