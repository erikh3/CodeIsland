import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Model / reasoning-effort label wiring in AppState: live tail deltas,
/// subagents' own models read from their transcripts, Codex rollouts.
@MainActor
final class AppStateModelLabelTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-AppStateModelLabelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func recapLine(_ text: String, timestamp: String = "2026-09-12T03:35:41.545Z") -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"system","subtype":"away_summary","content":"\#(text) (disable recaps in /config)","timestamp":"\#(timestamp)","uuid":"u","isMeta":false,"sessionId":"s"}"#
    }

    private func userLine(_ text: String) -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u"}"#
    }

    private func assistantLine(model: String, effort: String, sidechain: Bool = false) -> String {
        #"{"parentUuid":"p","isSidechain":\#(sidechain),"message":{"model":"\#(model)","role":"assistant","content":[{"type":"text","text":"ok"}]},"type":"assistant","effort":"\#(effort)","uuid":"u"}"#
    }

    private func writeTranscript(_ lines: [String], name: String = "session.jsonl") throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testModelDeltaUpdatesTheLabel() {
        let appState = AppState()
        var session = SessionSnapshot()
        session.model = "claude-opus-5-5[1m]"
        appState.sessions["s1"] = session

        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: "s1",
            lastUserPrompt: nil,
            lastAssistantMessage: "hi",
            modelObservation: ModelObservation(model: "claude-opus-5-5", effort: "xhigh")
        ))

        XCTAssertEqual(appState.sessions["s1"]?.modelLabel, "Opus 5.5 1M · xhigh")
    }

    func testResumeWithADifferentModelKeepsTheModelTheHookReported() throws {
        // `claude --resume <id> --model sonnet` over a transcript that ran on Opus.
        let path = try writeTranscript([
            userLine("earlier work"),
            #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"ok"}]},"type":"assistant","effort":"xhigh","timestamp":"2026-09-01T10:00:00.000Z","uuid":"u"}"#,
        ], name: "resume.jsonl")
        let appState = AppState()
        defer { appState.detachTranscriptTailer(sessionId: "resumed") }
        func hook(_ payload: [String: Any]) throws -> HookEvent {
            var payload = payload
            payload["session_id"] = "resumed"
            payload["transcript_path"] = path
            payload["cwd"] = tempDir.path
            return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
        }

        appState.handleEvent(try hook(["hook_event_name": "SessionStart", "source": "resume", "model": "claude-sonnet-5"]))
        appState.handleEvent(try hook(["hook_event_name": "UserPromptSubmit", "prompt": "carry on"]))

        XCTAssertEqual(appState.attachedTranscriptPaths["resumed"], path, "the attach backfill ran")
        XCTAssertEqual(appState.sessions["resumed"]?.model, "claude-sonnet-5")
        XCTAssertNil(appState.sessions["resumed"]?.reasoningEffort, "Opus's effort is not Sonnet's")
    }

    // MARK: - Subagents' own models

    func testClaudeSubagentModelComesFromItsOwnTranscriptNotTheParent() throws {
        let parentPath = try writeTranscript(
            [assistantLine(model: "claude-opus-5-5", effort: "xhigh")],
            name: "proj/sess.jsonl"
        )
        _ = try writeTranscript(
            [
                #"{"isSidechain":true,"type":"user","message":{"role":"user","content":"look"}}"#,
                assistantLine(model: "claude-haiku-4-5-20251001", effort: "low", sidechain: true),
            ],
            name: "proj/sess/subagents/agent-a1.jsonl"
        )
        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "claude"
        parent.transcriptPath = parentPath
        parent.model = "claude-opus-5-5"
        parent.subagents["a1"] = SubagentState(agentId: "a1", agentType: "Explore")
        appState.sessions["sess"] = parent

        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PreToolUse", "session_id": "sess", "agent_id": "a1",
        ])))
        appState.maybeBackfillSubagentModel(sessionId: "sess", agentId: "a1", event: event)

        let sub = appState.sessions["sess"]?.subagents["a1"]
        XCTAssertEqual(sub?.model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(sub?.reasoningEffort, "low")
        XCTAssertEqual(sub?.modelLabel, "Haiku 4.5 · low")
        XCTAssertEqual(appState.sessions["sess"]?.model, "claude-opus-5-5")

        // Codex-style recreation of the SubagentState reuses the cached read.
        appState.sessions["sess"]?.subagents["a1"] = SubagentState(agentId: "a1", agentType: "Explore")
        appState.maybeBackfillSubagentModel(sessionId: "sess", agentId: "a1", event: event)
        XCTAssertEqual(appState.sessions["sess"]?.subagents["a1"]?.model, "claude-haiku-4-5-20251001")
    }

    func testClaudeSubagentTranscriptInAGroupDirectoryIsFound() throws {
        let parentPath = try writeTranscript([userLine("x")], name: "proj/sess.jsonl")
        _ = try writeTranscript(
            [assistantLine(model: "claude-sonnet-5", effort: "medium", sidechain: true)],
            name: "proj/sess/subagents/run-1/agent-a2.jsonl"
        )
        XCTAssertEqual(
            AppState.readClaudeSubagentModel(parentTranscriptPath: parentPath, agentId: "a2"),
            ModelObservation(model: "claude-sonnet-5", effort: "medium")
        )
        XCTAssertNil(AppState.readClaudeSubagentModel(parentTranscriptPath: parentPath, agentId: "missing"))
    }

    func testMissingSubagentTranscriptRetriesAfterACooldown() throws {
        let parentPath = try writeTranscript([userLine("x")], name: "proj/sess.jsonl")
        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "claude"
        parent.transcriptPath = parentPath
        parent.subagents["a3"] = SubagentState(agentId: "a3", agentType: "Plan")
        appState.sessions["sess"] = parent
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "SubagentStart", "session_id": "sess", "agent_id": "a3",
        ])))

        appState.maybeBackfillSubagentModel(sessionId: "sess", agentId: "a3", event: event)

        XCTAssertNil(appState.sessions["sess"]?.subagents["a3"]?.model)
        let retryAt = try XCTUnwrap(appState.subagentModelReadRetryAt["sess"]?["a3"])
        XCTAssertGreaterThan(retryAt, Date())
    }

    // MARK: - Codex rollout model

    func testCodexBackfillPrefersTurnContextModelOverProvider() throws {
        let path = try writeTranscript([
            #"{"timestamp":"t","type":"session_meta","payload":{"id":"x","cwd":"/r","model_provider":"openai"}}"#,
            #"{"timestamp":"t","type":"turn_context","payload":{"cwd":"/r","model":"gpt-5.6-sol","effort":"max"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"user_message","message":"go"}}"#,
        ], name: "rollout.jsonl")

        XCTAssertEqual(AppState.readRecentFromCodexTranscript(path: path).0, "gpt-5.6-sol")
    }
}
