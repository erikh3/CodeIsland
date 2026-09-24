import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Claude Desktop Cowork cards: how watcher updates become `claude` sessions
/// hosted by Claude Desktop, and the ghost-card / duplicate-card guarantees.
@MainActor
final class AppStateCoworkWatchTests: XCTestCase {

    private let storeId = "local_f421aa51-3c78-4391-bc5e-3a05c2218bee"
    private let cliSessionId = "d0a5dc71-0311-45bb-87b4-0ff74229f6ca"
    private var key: String { AppState.coworkSessionKey(storeId) }

    override func setUp() {
        super.setUp()
        L10n.shared.language = "en"
    }

    override func tearDown() {
        L10n.shared.language = "system"
        super.tearDown()
    }

    private func metadata(
        storeId: String? = nil,
        isArchived: Bool = false,
        sessionType: String? = nil
    ) -> CoworkSessionMetadata {
        CoworkSessionMetadata(
            sessionId: storeId ?? self.storeId,
            cliSessionId: cliSessionId,
            title: "Available installation packages inquiry",
            cwd: "/sessions/bold-inspiring-tesla",
            userSelectedFolders: ["/Users/alice/code/app"],
            model: "claude-opus-4-5-20251101",
            createdAt: Date(timeIntervalSinceNow: -3600),
            lastActivityAt: Date(timeIntervalSinceNow: -60),
            isArchived: isArchived,
            sessionType: sessionType
        )
    }

    private func audit(_ lines: [String]) -> CoworkAuditState {
        var state = CoworkAuditState()
        state.apply(lines.map { CoworkAuditParser.event(fromLine: Data($0.utf8)) })
        return state
    }

    private func update(
        metadata: CoworkSessionMetadata? = nil,
        audit: CoworkAuditState = CoworkAuditState(),
        transcriptPath: String? = nil,
        lastActivity: Date? = nil,
        isLive: Bool = true,
        promptsStarted: Int = 0,
        turnsCompleted: Int = 0,
        permissionsRequested: Int = 0
    ) -> CoworkSessionWatcher.SessionUpdate {
        let metadata = metadata ?? self.metadata()
        return CoworkSessionWatcher.SessionUpdate(
            sessionId: metadata.sessionId,
            metadata: metadata,
            audit: audit,
            transcriptPath: transcriptPath,
            lastActivity: lastActivity,
            isLive: isLive,
            promptsStarted: promptsStarted,
            turnsCompleted: turnsCompleted,
            permissionsRequested: permissionsRequested
        )
    }

    // MARK: - Card identity

    func testLivePromptOpensAClaudeDesktopHostedClaudeCard() throws {
        let appState = AppState()
        appState.applyCoworkUpdate(update(
            audit: audit([CoworkAuditFixture.userPrompt]),
            promptsStarted: 1
        ))

        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.source, "claude", "same engine, same mascot — no new source")
        XCTAssertEqual(card.termBundleId, "com.anthropic.claudefordesktop")
        XCTAssertTrue(card.isNativeAppMode)
        XCTAssertEqual(card.terminalName, "Claude")
        XCTAssertEqual(card.status, .processing)
        XCTAssertEqual(card.sessionTitle, "Available installation packages inquiry")
        XCTAssertEqual(card.cwd, "/Users/alice/code/app")
        XCTAssertEqual(card.model, "claude-opus-4-5-20251101")
        XCTAssertEqual(card.providerSessionId, cliSessionId)
        // No transcript yet: the audit prompt stands in for the chat line.
        XCTAssertEqual(card.lastUserPrompt, "list the installers")
        XCTAssertEqual(card.recentMessages.map(\.text), ["list the installers"])
    }

    func testKeysStayInTheirOwnNamespace() {
        XCTAssertEqual(AppState.coworkSessionKey(storeId), "cowork:\(storeId)")
        XCTAssertEqual(AppState.coworkStoreSessionId(fromKey: key), storeId)
        XCTAssertNil(AppState.coworkStoreSessionId(fromKey: cliSessionId))
        // Only the negative path: a positive call would open Claude Desktop.
        XCTAssertFalse(AppState.openCoworkSession(sessionKey: cliSessionId))
    }

    func testRunningToolIsShownWithSandboxPathsStripped() throws {
        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([
            CoworkAuditFixture.userPrompt,
            CoworkAuditFixture.assistantToolUse,
        ])))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .running)
        XCTAssertEqual(card.currentTool, "Bash")
        XCTAssertEqual(card.toolDescription, #"find alice -name "*.dmg""#)
    }

    // MARK: - Waiting (display-only)

    func testPermissionCardShowsAsDisplayOnlyWait() throws {
        let appState = AppState()
        let request = CoworkAuditFixture.permissionRequest(id: "r", tool: "Bash", input: #"{"command":"rm x"}"#)
        appState.applyCoworkUpdate(update(
            audit: audit([CoworkAuditFixture.userPrompt, request]),
            permissionsRequested: 1
        ))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .waitingApproval)
        XCTAssertEqual(card.currentTool, "Bash")
        XCTAssertEqual(card.toolDescription, "Approve Bash in Claude Desktop · rm x")
        XCTAssertTrue(appState.permissionQueue.isEmpty, "nothing to answer from the island")
    }

    func testQuestionShowsTheQuestionText() throws {
        let appState = AppState()
        let question = CoworkAuditFixture.permissionRequest(
            id: "q", tool: "AskUserQuestion", input: #"{"questions":[{"question":"Which folder?"}]}"#
        )
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt, question])))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .waitingQuestion)
        XCTAssertEqual(card.toolDescription, "Answer in Claude Desktop: Which folder?")
        XCTAssertTrue(appState.questionQueue.isEmpty)
    }

    // MARK: - Completion

    func testCompletedTurnGoesIdleAndKeepsTheReply() throws {
        let appState = AppState()
        appState.applyCoworkUpdate(update(
            audit: audit([
                CoworkAuditFixture.userPrompt,
                CoworkAuditFixture.assistantReply,
                CoworkAuditFixture.resultSuccess,
            ]),
            promptsStarted: 1,
            turnsCompleted: 1
        ))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .idle)
        XCTAssertNil(card.currentTool)
        XCTAssertEqual(card.lastAssistantMessage, "Found a.dmg")
        XCTAssertEqual(card.recentMessages.map(\.isUser), [true, false])
    }

    func testAttachedTranscriptOwnsTheChatLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowork-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("\(cliSessionId).jsonl").path
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"list the installers"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"From the transcript"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.applyCoworkUpdate(update(
            audit: audit([CoworkAuditFixture.userPrompt, CoworkAuditFixture.resultSuccess]),
            transcriptPath: transcript,
            turnsCompleted: 1
        ))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.transcriptPath, transcript)
        XCTAssertEqual(card.recentMessages.map(\.text), ["list the installers", "From the transcript"])
        XCTAssertEqual(appState.attachedTranscriptPaths[key], transcript)
        appState.removeSession(key)
    }

    // MARK: - Ghost cards

    func testHistoryNeverOpensACard() {
        let appState = AppState()
        // A title generated (or the file re-saved) for a session whose card the
        // idle sweep already collected.
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.resultSuccess]), isLive: false))
        XCTAssertNil(appState.sessions[key])
    }

    func testMetadataRefreshStillUpdatesAnExistingCard() {
        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt])))
        var renamed = metadata()
        renamed.title = "Renamed task"
        appState.applyCoworkUpdate(update(metadata: renamed, audit: audit([CoworkAuditFixture.userPrompt]), isLive: false))
        XCTAssertEqual(appState.sessions[key]?.sessionTitle, "Renamed task")
    }

    func testArchivingRemovesTheCard() {
        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt])))
        XCTAssertNotNil(appState.sessions[key])
        appState.applyCoworkUpdate(update(metadata: metadata(isArchived: true), isLive: false))
        XCTAssertNil(appState.sessions[key])
    }

    func testHiddenSessionTypesNeverGetACard() {
        let appState = AppState()
        for type in ["agent", "dispatch_child", "radar"] {
            appState.applyCoworkUpdate(update(
                metadata: metadata(sessionType: type),
                audit: audit([CoworkAuditFixture.userPrompt])
            ))
            XCTAssertNil(appState.sessions[key], type)
        }
        appState.applyCoworkUpdate(update(
            metadata: metadata(sessionType: "chat"),
            audit: audit([CoworkAuditFixture.userPrompt])
        ))
        XCTAssertNotNil(appState.sessions[key], "local Chat sessions are shown like Cowork tasks")
    }

    func testLaunchSnapshotReplacesRestoredCards() throws {
        let appState = AppState()
        // What SessionPersistence restored from the previous run.
        let ghostKey = AppState.coworkSessionKey("local_0ld5e551-0000-0000-0000-000000000000")
        var ghost = SessionSnapshot()
        ghost.source = "claude"
        ghost.lastUserPrompt = "something from yesterday"
        appState.sessions[ghostKey] = ghost
        appState.sessions["unrelated-hook-session"] = SessionSnapshot()

        let lastActivity = Date(timeIntervalSinceNow: -120)
        appState.applyCoworkLaunchSnapshot([
            update(
                audit: audit([CoworkAuditFixture.userPrompt, CoworkAuditFixture.resultSuccess]),
                lastActivity: lastActivity,
                isLive: false
            ),
        ], claudeDesktopRunning: true)

        XCTAssertNil(appState.sessions[ghostKey], "the store no longer vouches for it")
        XCTAssertNotNil(appState.sessions["unrelated-hook-session"])
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .idle)
        XCTAssertEqual(card.lastActivity, lastActivity, "keeps its real age for the idle sweep")
    }

    func testTurnOrphanedByAClaudeDesktopRestartIsRebuiltIdle() throws {
        let appState = AppState()
        let request = CoworkAuditFixture.permissionRequest(id: "r", tool: "Bash", input: #"{"command":"rm x"}"#)
        let openCard = audit([CoworkAuditFixture.userPrompt, request])
        let launchedAt = Date(timeIntervalSinceNow: -30)

        // Last written before the running instance started: the card died with it.
        appState.applyCoworkLaunchSnapshot(
            [update(audit: openCard, lastActivity: launchedAt.addingTimeInterval(-60), isLive: false)],
            claudeDesktopRunning: true,
            claudeDesktopLaunchedAt: launchedAt
        )
        XCTAssertEqual(try XCTUnwrap(appState.sessions[key]).status, .idle)

        // Written by the running instance: genuinely still waiting.
        appState.sessions.removeAll()
        appState.applyCoworkLaunchSnapshot(
            [update(audit: openCard, lastActivity: Date(), isLive: false)],
            claudeDesktopRunning: true,
            claudeDesktopLaunchedAt: launchedAt
        )
        XCTAssertEqual(try XCTUnwrap(appState.sessions[key]).status, .waitingApproval)
    }

    func testOnlyACoworkPermissionWaitOutlivesTheSilenceTimeout() {
        XCTAssertTrue(AppState.isCoworkWaitingOnDesktop(key: key, status: .waitingApproval))
        XCTAssertTrue(AppState.isCoworkWaitingOnDesktop(key: key, status: .waitingQuestion))
        // A silent "thinking" card may be an interrupted turn: let it settle.
        XCTAssertFalse(AppState.isCoworkWaitingOnDesktop(key: key, status: .processing))
        XCTAssertFalse(AppState.isCoworkWaitingOnDesktop(key: key, status: .running))
        XCTAssertFalse(AppState.isCoworkWaitingOnDesktop(key: cliSessionId, status: .waitingApproval))
    }

    func testLaunchSnapshotShowsNothingWhileClaudeDesktopIsClosed() {
        let appState = AppState()
        appState.sessions[key] = SessionSnapshot()
        appState.applyCoworkLaunchSnapshot([
            update(audit: audit([CoworkAuditFixture.userPrompt]), lastActivity: Date(), isLive: false),
        ], claudeDesktopRunning: false)
        XCTAssertTrue(appState.sessions.isEmpty)
    }

    // MARK: - Duplicates

    func testHookDrivenCardWins() {
        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt])))
        XCTAssertNotNil(appState.sessions[key])

        // Hooks start arriving for the same conversation (keyed by CLI session id).
        appState.sessions[cliSessionId] = SessionSnapshot()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt, CoworkAuditFixture.assistantReply])))
        XCTAssertNil(appState.sessions[key])
        XCTAssertNotNil(appState.sessions[cliSessionId])
    }

    func testStoppingRemovesEveryCoworkCard() {
        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt])))
        appState.sessions["hook"] = SessionSnapshot()
        appState.removeCoworkSessions()
        XCTAssertNil(appState.sessions[key])
        XCTAssertNotNil(appState.sessions["hook"])
    }
}

/// `audit.jsonl` lines in the real record shapes (the core suite's
/// CoworkAuditLogTests pins the parser against the same shapes).
enum CoworkAuditFixture {
    private static let ts = #""_audit_timestamp":"2026-01-13T10:39:52.333Z""#

    static let userPrompt = #"{"type":"user","uuid":"u1","session_id":"f421","parent_tool_use_id":null,"message":{"role":"user","content":"list the installers"},"# + ts + "}"
    static let assistantToolUse = #"{"type":"assistant","message":{"model":"claude-opus-4-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"find /sessions/bold-inspiring-tesla/mnt/alice -name \"*.dmg\""}}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"d0a5","uuid":"a2","# + ts + "}"
    static let assistantReply = #"{"type":"assistant","message":{"model":"claude-opus-4-5","id":"msg_2","type":"message","role":"assistant","content":[{"type":"text","text":"Found a.dmg"}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"d0a5","uuid":"a3","# + ts + "}"
    static let resultSuccess = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":50948,"num_turns":2,"result":"Found a.dmg","session_id":"d0a5","total_cost_usd":0.24,"permission_denials":[],"uuid":"r1","# + ts + "}"

    static func permissionRequest(id: String, tool: String, input: String) -> String {
        #"{"type":"system","subtype":"permission_request","uuid":""# + id + #"","session_id":"d0a5","tool_name":""# + tool + #"","tool_input":"# + input + "," + ts + "}"
    }
}
