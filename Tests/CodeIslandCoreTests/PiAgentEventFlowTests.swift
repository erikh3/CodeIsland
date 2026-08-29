import XCTest
@testable import CodeIslandCore

final class PiAgentEventFlowTests: XCTestCase {
    private func hookEvent(_ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data), file: file, line: line)
    }

    private func apply(_ payload: [String: Any], to sessions: inout [String: SessionSnapshot]) throws -> [SideEffect] {
        reduceEvent(sessions: &sessions, event: try hookEvent(payload), maxHistory: 20)
    }

    func testPiSessionStartPreservesDirectPluginEnvForHarnessJumping() throws {
        let sessionId = "pi-e2e-env"
        var sessions: [String: SessionSnapshot] = [:]

        let effects = try apply([
            "hook_event_name": "SessionStart",
            "session_id": sessionId,
            "_source": "pi",
            "_ppid": 12345,
            "cwd": "/Users/dev/workspace",
            "session_title": "Pi env test",
            "_env": [
                "TERM_PROGRAM": "Ghostty",
                "__CFBundleIdentifier": "com.mitchellh.ghostty",
                "ITERM_SESSION_ID": "w0t0p0:GUID-123",
                "TMUX": "/tmp/tmux-501/default,111,0",
                "TMUX_PANE": "%42",
                "KITTY_WINDOW_ID": "kitty-7",
                "CMUX_SURFACE_ID": "surface-123",
                "CMUX_WORKSPACE_ID": "workspace-456",
                "ZELLIJ_PANE_ID": "17",
                "ZELLIJ_SESSION_NAME": "zed",
                "WEZTERM_PANE": "99",
            ],
        ], to: &sessions)

        let session = try XCTUnwrap(sessions[sessionId])
        XCTAssertEqual(session.source, "pi")
        XCTAssertEqual(session.cwd, "/Users/dev/workspace")
        XCTAssertEqual(session.sessionTitle, "Pi env test")
        XCTAssertEqual(session.cliPid, 12345)
        XCTAssertEqual(session.termApp, "Ghostty")
        XCTAssertEqual(session.termBundleId, "com.mitchellh.ghostty")
        XCTAssertEqual(session.itermSessionId, "GUID-123")
        XCTAssertEqual(session.tmuxEnv, "/tmp/tmux-501/default,111,0")
        XCTAssertEqual(session.tmuxPane, "%42")
        XCTAssertEqual(session.kittyWindowId, "kitty-7")
        XCTAssertEqual(session.cmuxSurfaceId, "surface-123")
        XCTAssertEqual(session.cmuxWorkspaceId, "workspace-456")
        XCTAssertEqual(session.zellijPaneId, "17")
        XCTAssertEqual(session.zellijSessionName, "zed")
        XCTAssertEqual(session.weztermPaneId, "99")
        XCTAssertTrue(effects.contains(.stopMonitor(sessionId: sessionId)))
        XCTAssertTrue(effects.contains(.tryMonitorSession(sessionId: sessionId)))
    }
    func testPiAndOmpAliasesNormalizeToPi() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("pi"), "pi")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("omp"), "pi")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("Oh My Pi"), "pi")

        var session = SessionSnapshot()
        session.source = "pi"
        XCTAssertEqual(session.sourceLabel, "Pi")
    }

    func testPiAgentLifecyclePayloadsReduceToVisibleSessionState() throws {
        let sessionId = "pi-e2e-flow"
        var sessions: [String: SessionSnapshot] = [:]
        let base: [String: Any] = [
            "session_id": sessionId,
            "_source": "pi",
            "_ppid": 22222,
            "cwd": "/Users/dev/project",
            "_env": ["TERM_PROGRAM": "Apple_Terminal"],
        ]

        _ = try apply(base.merging(["hook_event_name": "SessionStart"]) { _, new in new }, to: &sessions)
        _ = try apply(base.merging([
            "hook_event_name": "UserPromptSubmit",
            "prompt": "Fix the Pi harness status panel",
        ]) { _, new in new }, to: &sessions)
        _ = try apply(base.merging([
            "hook_event_name": "PreToolUse",
            "tool_name": "Read",
            "tool_input": ["file_path": "/Users/dev/project/AGENTS.md"],
        ]) { _, new in new }, to: &sessions)
        _ = try apply(base.merging(["hook_event_name": "PostToolUse"]) { _, new in new }, to: &sessions)
        let stopEffects = try apply(base.merging([
            "hook_event_name": "Stop",
            "last_assistant_message": "Pi harness status is wired.",
        ]) { _, new in new }, to: &sessions)

        let session = try XCTUnwrap(sessions[sessionId])
        XCTAssertEqual(session.source, "pi")
        XCTAssertEqual(session.lastUserPrompt, "Fix the Pi harness status panel")
        XCTAssertEqual(session.lastAssistantMessage, "Pi harness status is wired.")
        XCTAssertNil(session.currentTool)
        XCTAssertEqual(session.toolHistory.count, 1)
        XCTAssertEqual(session.toolHistory.first?.tool, "Read")
        XCTAssertEqual(session.toolHistory.first?.description, "AGENTS.md")
        XCTAssertEqual(session.recentMessages.map(\.text), [
            "Fix the Pi harness status panel",
            "Pi harness status is wired.",
        ])
        XCTAssertTrue(stopEffects.contains(.enqueueCompletion(sessionId: sessionId)))
    }

    func testPiToolCallIntentSurfacesAsToolDescription() throws {
        // The omp bridge emits PreToolUse from `tool_execution_start`, which
        // carries the tool's `intent` (the model's per-call `i` summary) as a
        // top-level field. The reducer must expose that intent as the session's
        // live tool description — the status text omp shows — and it changes on
        // every tool call.
        let sessionId = "pi-intent"
        var sessions: [String: SessionSnapshot] = [:]
        let base: [String: Any] = [
            "session_id": sessionId,
            "_source": "pi",
            "cwd": "/Users/dev/project",
        ]

        _ = try apply(base.merging(["hook_event_name": "SessionStart"]) { _, new in new }, to: &sessions)
        // `read .` carries no file_path/AbsolutePath field the generic derivation
        // could latch onto, so the top-level intent is the only description signal.
        _ = try apply(base.merging([
            "hook_event_name": "PreToolUse",
            "tool_name": "Read",
            "tool_input": ["path": "."],
            "intent": "List directory contents",
        ]) { _, new in new }, to: &sessions)

        let afterRead = try XCTUnwrap(sessions[sessionId])
        XCTAssertEqual(afterRead.currentTool, "Read")
        XCTAssertEqual(afterRead.toolDescription, "List directory contents")

        // PostToolUse clears the live tool chrome, but `lastToolIntent` must
        // survive the think gap so the card keeps showing the intent instead of
        // blanking back to bare "thinking".
        _ = try apply(base.merging(["hook_event_name": "PostToolUse"]) { _, new in new }, to: &sessions)
        let afterPost = try XCTUnwrap(sessions[sessionId])
        XCTAssertNil(afterPost.currentTool)
        XCTAssertNil(afterPost.toolDescription)
        XCTAssertEqual(afterPost.lastToolIntent, "List directory contents")

        // The next tool call swaps in its own intent — the intent tracks the most
        // recent call, not a frozen earlier value. This one carries the intent as
        // an `i` argument inside `tool_input`, the other shape the reducer accepts.
        _ = try apply(base.merging([
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": ["command": "find . -name '*.swift' | wc -l", "i": "Count Swift files"],
        ]) { _, new in new }, to: &sessions)

        let afterBash = try XCTUnwrap(sessions[sessionId])
        XCTAssertEqual(afterBash.currentTool, "Bash")
        XCTAssertEqual(afterBash.toolDescription, "Count Swift files")
        XCTAssertEqual(afterBash.lastToolIntent, "Count Swift files")

        // A turn end (Stop) does NOT clear the persisted intent: omp keeps the
        // last tool's intent visible through the next turn's opening generation
        // gap, so the card never blanks to "thinking" before the first tool.
        _ = try apply(base.merging([
            "hook_event_name": "Stop",
            "last_assistant_message": "5 Swift files.",
        ]) { _, new in new }, to: &sessions)
        XCTAssertEqual(sessions[sessionId]?.lastToolIntent, "Count Swift files")
        XCTAssertEqual(sessions[sessionId]?.status, .idle)

        // A new prompt also keeps the prior intent until the next tool overwrites
        // it — the generation gap shows the last known intent, matching omp.
        _ = try apply(base.merging([
            "hook_event_name": "UserPromptSubmit",
            "prompt": "now count the TypeScript files",
        ]) { _, new in new }, to: &sessions)
        XCTAssertEqual(sessions[sessionId]?.lastToolIntent, "Count Swift files")
        XCTAssertEqual(sessions[sessionId]?.status, .processing)
    // MARK: - OMP subagent Stop reducer tests

    func testOmpSeparateChildStopIdlesAndRetainsReply() throws {
        let childId = "pi-child-1"
        var sessions: [String: SessionSnapshot] = [:]
        let base: [String: Any] = [
            "session_id": childId,
            "_source": "pi",
            "_omp_subagent": true,
            "_omp_parent_session_id": "pi-root-1",
            "_omp_agent_id": "ResearchScout",
            "_omp_agent_type": "scout",
        ]

        _ = try apply(base.merging(["hook_event_name": "SessionStart"]) { $1 }, to: &sessions)
        _ = try apply(base.merging([
            "hook_event_name": "UserPromptSubmit",
            "prompt": "Research the topic",
        ]) { $1 }, to: &sessions)

        let stopEffects = try apply(base.merging([
            "hook_event_name": "Stop",
            "last_assistant_message": "Research complete.",
        ]) { $1 }, to: &sessions)

        let session = try XCTUnwrap(sessions[childId])
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.lastAssistantMessage, "Research complete.")
        XCTAssertFalse(stopEffects.contains(.enqueueCompletion(sessionId: childId)))
        XCTAssertFalse(stopEffects.contains(.playSound("Stop")))
    }


    func testNormalRootPiStopEmitsBothCompletionAndSound() throws {
        let sessionId = "pi-root-normal"
        var sessions: [String: SessionSnapshot] = [:]

        _ = try apply([
            "hook_event_name": "SessionStart",
            "session_id": sessionId,
            "_source": "pi",
        ], to: &sessions)

        let stopEffects = try apply([
            "hook_event_name": "Stop",
            "session_id": sessionId,
            "_source": "pi",
            "last_assistant_message": "All done.",
        ], to: &sessions)

        XCTAssertTrue(stopEffects.contains(.enqueueCompletion(sessionId: sessionId)))
        XCTAssertTrue(stopEffects.contains(.playSound("Stop")))
    }

    func testMergedChildStopWithSiblingLeavesParentActive() throws {
        let parentId = "pi-root-merge"
        var sessions: [String: SessionSnapshot] = [:]

        _ = try apply([
            "hook_event_name": "SessionStart",
            "session_id": parentId,
            "_source": "pi",
        ], to: &sessions)

        // Two merged children start
        _ = try apply([
            "hook_event_name": "SubagentStart",
            "session_id": parentId,
            "_source": "pi",
            "agent_id": "Scout",
            "agent_type": "scout",
        ], to: &sessions)
        _ = try apply([
            "hook_event_name": "SubagentStart",
            "session_id": parentId,
            "_source": "pi",
            "agent_id": "Reviewer",
            "agent_type": "reviewer",
        ], to: &sessions)

        // First child stops
        let firstStopEffects = try apply([
            "hook_event_name": "Stop",
            "session_id": parentId,
            "_source": "pi",
            "agent_id": "Scout",
        ], to: &sessions)

        let session = try XCTUnwrap(sessions[parentId])
        // Sibling still active
        XCTAssertNotNil(session.subagents["Reviewer"])
        XCTAssertNil(session.subagents["Scout"])
        // Parent still active (not idle)
        XCTAssertNotEqual(session.status, .idle)
        XCTAssertFalse(firstStopEffects.contains(.enqueueCompletion(sessionId: parentId)))
    }

    func testMergedFinalChildStopReturnsParentToProcessingNoCompletion() throws {
        let parentId = "pi-root-final-child"
        var sessions: [String: SessionSnapshot] = [:]

        _ = try apply([
            "hook_event_name": "SessionStart",
            "session_id": parentId,
            "_source": "pi",
        ], to: &sessions)

        _ = try apply([
            "hook_event_name": "SubagentStart",
            "session_id": parentId,
            "_source": "pi",
            "agent_id": "OnlyChild",
            "agent_type": "task",
        ], to: &sessions)

        let finalStopEffects = try apply([
            "hook_event_name": "Stop",
            "session_id": parentId,
            "_source": "pi",
            "agent_id": "OnlyChild",
        ], to: &sessions)

        let session = try XCTUnwrap(sessions[parentId])
        XCTAssertTrue(session.subagents.isEmpty)
        XCTAssertEqual(session.status, .processing)
        XCTAssertFalse(finalStopEffects.contains(.enqueueCompletion(sessionId: parentId)))
    }

    func testNonOmpProviderStopRemainsUnchanged() throws {
        let sessionId = "claude-normal"
        var sessions: [String: SessionSnapshot] = [:]

        _ = try apply([
            "hook_event_name": "SessionStart",
            "session_id": sessionId,
            "_source": "claude",
        ], to: &sessions)

        let stopEffects = try apply([
            "hook_event_name": "Stop",
            "session_id": sessionId,
            "_source": "claude",
            "last_assistant_message": "Task finished.",
        ], to: &sessions)

        XCTAssertTrue(stopEffects.contains(.enqueueCompletion(sessionId: sessionId)))
        XCTAssertTrue(stopEffects.contains(.playSound("Stop")))
        let session = try XCTUnwrap(sessions[sessionId])
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.lastAssistantMessage, "Task finished.")
    }

    func testMergedChildPreCompactDoesNotMutateParent() throws {
        let parentId = "pi-root-precompact"
        var sessions: [String: SessionSnapshot] = [:]

        _ = try apply([
            "hook_event_name": "SessionStart",
            "session_id": parentId,
            "_source": "pi",
        ], to: &sessions)
        _ = try apply([
            "hook_event_name": "SubagentStart",
            "session_id": parentId,
            "_source": "pi",
            "agent_id": "Compactor",
            "agent_type": "task",
        ], to: &sessions)

        let parentStatus = try XCTUnwrap(sessions[parentId]).status
        let parentDesc = sessions[parentId]?.toolDescription

        let effects = try apply([
            "hook_event_name": "PreCompact",
            "session_id": parentId,
            "_source": "pi",
            "agent_id": "Compactor",
        ], to: &sessions)

        let session = try XCTUnwrap(sessions[parentId])
        XCTAssertEqual(session.status, parentStatus, "parent status must not change on merged child PreCompact")
        XCTAssertEqual(session.toolDescription, parentDesc, "parent toolDescription must not change on merged child PreCompact")
        XCTAssertFalse(effects.contains(.playSound("PreCompact")), "merged child PreCompact must not emit sound")
    }

    func testMergedChildPostCompactDoesNotMutateParent() throws {
        let parentId = "pi-root-postcompact"
        var sessions: [String: SessionSnapshot] = [:]

        _ = try apply([
            "hook_event_name": "SessionStart",
            "session_id": parentId,
            "_source": "pi",
        ], to: &sessions)
        _ = try apply([
            "hook_event_name": "SubagentStart",
            "session_id": parentId,
            "_source": "pi",
            "agent_id": "Compactor",
            "agent_type": "task",
        ], to: &sessions)

        let parentStatus = try XCTUnwrap(sessions[parentId]).status
        let parentDesc = sessions[parentId]?.toolDescription

        let effects = try apply([
            "hook_event_name": "PostCompact",
            "session_id": parentId,
            "_source": "pi",
            "agent_id": "Compactor",
        ], to: &sessions)

        let session = try XCTUnwrap(sessions[parentId])
        XCTAssertEqual(session.status, parentStatus, "parent status must not change on merged child PostCompact")
        XCTAssertEqual(session.toolDescription, parentDesc, "parent toolDescription must not change on merged child PostCompact")
        XCTAssertFalse(effects.contains(.playSound("PostCompact")), "merged child PostCompact must not emit sound")
    }
}
