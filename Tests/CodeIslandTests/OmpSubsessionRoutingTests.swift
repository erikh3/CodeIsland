import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Coverage for OMP task-child routing in HookServer.
/// OMP children use the canonical `_parent_session_id` contract and are routed by
/// SubsessionRouter/DeclaredSubsession alongside every other child kind.
/// Tests verify separate / merge / hide, AppState key resolution, child-first
/// metadata, two-root disambiguation, concurrent children, malformed metadata,
/// and nested dotted child IDs.
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

    /// Builds a canonical OMP child payload matching the TS extension output:
    /// `_parent_session_id` + `agent_type` only; `agent_id` is derived from
    /// the child's card id by SubsessionRouter once it folds the payload.
    private func ompChildPayload(
        sessionId: String,
        parentSessionId: String,
        agentType: String = "scout",
        eventName: String = "PostToolUse",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            DeclaredSubsession.parentKey: parentSessionId,
            "agent_type": agentType,
            "session_id": sessionId,
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

    // MARK: - Separate mode

    func testSeparateModeLinksChildToParent() throws {
        try withPluginSessionMode("separate") {
            let appState = AppState()
            appState.sessions[rootId] = makeRunningSession()

            let routed = try route(appState: appState, payload: ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId
            ))
            XCTAssertNil(routed.responseData)
            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
            let event = try XCTUnwrap(HookEvent(from: routed.processedData))
            appState.handleEvent(event)
            XCTAssertEqual(appState.sessions[childId]?.parentSessionId, rootId)
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
                agentType: "scout"
            ))
            XCTAssertNil(routed.responseData)
            XCTAssertEqual(routed.raw["session_id"] as? String, rootId)
            // agent_id is the child's canonical card id (derived by SubsessionRouter.fold
            // from DeclaredSubsession.link.agentId when no agent_id is in the payload).
            XCTAssertEqual(routed.raw["agent_id"] as? String, childId)
            XCTAssertEqual(routed.raw["agent_type"] as? String, "scout")
            // Routing field removed; folded kind stamped
            XCTAssertNil(routed.raw[DeclaredSubsession.parentKey])
            XCTAssertEqual(routed.raw[SubsessionRouter.foldedKey] as? String, "declared")
            let event = try XCTUnwrap(HookEvent(from: routed.processedData))
            appState.handleEvent(event)
            XCTAssertNil(appState.sessions[rootId]?.parentSessionId)
        }
    }

    func testChildBeforeParentKeepsItsMetadata() throws {
        try withPluginSessionMode("merge") {
            // Child arrives before the parent card exists.
            // The child's source and working directory must remain intact.
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
            // An unknown parent is not invented; the child keeps its own card.
            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
            // Metadata fields preserved
            XCTAssertEqual(routed.raw["cwd"] as? String, "/home/user/project")
            XCTAssertEqual(routed.raw["_source"] as? String, "pi")
        }
    }

    // MARK: - Hide mode

    func testHideModeNonBlockingEventRespondsEmpty() throws {
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
            if let response = routed.responseData,
               let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any] {
                XCTAssertTrue(obj.isEmpty)
            }
        }
    }

    func testHideModePermissionEventGetsOwnCard() throws {
        // Hide never answers a blocking request on the user's behalf (#165):
        // a PermissionRequest in hide mode surfaces on the child's own card.
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
            // Blocking request in hide mode: no hidden response, child gets own card.
            XCTAssertNil(routed.responseData)
            let raw = try XCTUnwrap(
                JSONSerialization.jsonObject(with: routed.processedData) as? [String: Any]
            )
            XCTAssertEqual(raw["session_id"] as? String, childId)
            let event = try XCTUnwrap(HookEvent(json: raw))
            appState.handleEvent(event)
            XCTAssertEqual(appState.sessions[childId]?.parentSessionId, rootId)
        }
    }

    // MARK: - Resolved AppState parent key

    func testMergeModeUsesCanonicalParentCardKey() throws {
        try withPluginSessionMode("merge") {
            // Parent exists under a different AppState key but with matching providerSessionId.
            let appState = AppState()
            var parentSnap = makeRunningSession()
            parentSnap.providerSessionId = providerParentId
            let appStateKey = "pi-resolved-key-for-provider"
            appState.sessions[appStateKey] = parentSnap

            let routed = try route(appState: appState, payload: ompChildPayload(
                sessionId: childId,
                parentSessionId: appStateKey
            ))
            XCTAssertNil(routed.responseData)
            // The canonical parent pointer addresses the card directly.
            XCTAssertEqual(routed.raw["session_id"] as? String, appStateKey)
        }
    }

    func testMergeModeDoesNotInventUnknownParent() throws {
        try withPluginSessionMode("merge") {
            // An unknown parent does not create a phantom parent card.
            let appState = AppState()

            let routed = try route(appState: appState, payload: ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId
            ))
            XCTAssertNil(routed.responseData)
            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
        }
    }

    // MARK: - Two roots sharing CWD and PID

    func testTwoRootsWithSameCwdAndPidRemainSeparate() throws {
        // OMP routing uses explicit _parent_session_id; CWD/PID are irrelevant.
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
                agentType: "scout"
            ))
            let routed2 = try route(appState: appState, payload: ompChildPayload(
                sessionId: child2Id,
                parentSessionId: rootId,
                agentType: "reviewer"
            ))

            XCTAssertEqual(routed1.raw["session_id"] as? String, rootId)
            // Each child's card id is its agent_id row in the parent.
            XCTAssertEqual(routed1.raw["agent_id"] as? String, childId)

            XCTAssertEqual(routed2.raw["session_id"] as? String, rootId)
            XCTAssertEqual(routed2.raw["agent_id"] as? String, child2Id)
        }
    }

    // MARK: - Malformed metadata passes through unchanged

    func testMissingParentSessionIdPassesThrough() throws {
        // No _parent_session_id: not a declared child; passes through unchanged.
        try withPluginSessionMode("merge") {
            let appState = AppState()
            let payload: [String: Any] = [
                "agent_id": "ResearchScout",
                "agent_type": "scout",
                "session_id": childId,
                "_source": "pi",
                "hook_event_name": "PostToolUse",
            ]
            let routed = try route(appState: appState, payload: payload)
            // No _parent_session_id: SubsessionRouter won't fold this.
            // agent_id present so isSubsessionEvent=true, but no routing.
            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
        }
    }

    func testChildAndParentSameIdPassesThrough() throws {
        try withPluginSessionMode("merge") {
            let appState = AppState()
            // DeclaredSubsession rejects self-parent.
            let payload = ompChildPayload(
                sessionId: rootId,
                parentSessionId: rootId
            )
            let routed = try route(appState: appState, payload: payload)
            XCTAssertEqual(routed.raw["session_id"] as? String, rootId)
            XCTAssertNil(routed.raw[SubsessionRouter.foldedKey])
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
            XCTAssertEqual(routed.raw[SubsessionRouter.foldedKey] as? String, "declared")
        }
    }

    func testNestedOmpProcessInSeparateModeLinksToParent() throws {
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

            // The reducer links the separate child through its declared parent.
            XCTAssertEqual(routed.raw["session_id"] as? String, childId)

            let event = try XCTUnwrap(HookEvent(from: routed.processedData))
            appState.handleEvent(event)
            XCTAssertNotNil(appState.sessions[rootId])
            XCTAssertEqual(appState.sessions[childId]?.parentSessionId, rootId)
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
            XCTAssertNil(routed.raw[DeclaredSubsession.parentKey])
            XCTAssertNil(routed.raw[SubsessionRouter.linkedParentKey])
        }
    }

    // MARK: - Nested dotted child ID

    func testNestedChildMergeUsesCardIdAsAgentRow() throws {
        // Without an agent_id in the payload, SubsessionRouter.fold uses the
        // child's card id (DeclaredSubsession.link.agentId = childCardId) as
        // the subagent row identifier.
        try withPluginSessionMode("merge") {
            let appState = AppState()
            appState.sessions[rootId] = makeRunningSession()

            let routed = try route(appState: appState, payload: ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId,
                agentType: "reviewer"
            ))
            XCTAssertNil(routed.responseData)
            XCTAssertEqual(routed.raw["session_id"] as? String, rootId)
            // agent_id is the canonical child card id.
            XCTAssertEqual(routed.raw["agent_id"] as? String, childId)
            XCTAssertEqual(routed.raw["agent_type"] as? String, "reviewer")
        }
    }

    // MARK: - OMP routing goes through SubsessionRouter alongside Cursor/Codex

    func testOmpChildWithCursorTranscriptPathUsesParentKey() throws {
        // A payload that carries both a Cursor transcript path and _parent_session_id
        // is routed by DeclaredSubsession (explicit), not by Cursor heuristics.
        try withPluginSessionMode("merge") {
            let appState = AppState()
            appState.sessions[rootId] = makeRunningSession()

            var payload = ompChildPayload(
                sessionId: childId,
                parentSessionId: rootId,
                agentType: "scout"
            )
            payload["transcript_path"] = "/Users/u/.cursor/projects/x/agent-transcripts/parent/child.jsonl"
            payload["_source"] = "pi"

            let routed = try route(appState: appState, payload: payload)
            // DeclaredSubsession wins: session_id is rootId, agent_id is preserved.
            XCTAssertEqual(routed.raw["session_id"] as? String, rootId)
            XCTAssertEqual(routed.raw["agent_id"] as? String, childId)
            XCTAssertNil(routed.raw["_cursor_subagent"])
        }
    }
}
