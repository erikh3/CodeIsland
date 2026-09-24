import Foundation
import AppKit
import CodeIslandCore

/// Claude Desktop Cowork tasks and local Chat sessions on the island.
///
/// Cowork runs Claude Code inside a sandbox VM, so it fires no hooks
/// (anthropics/claude-code#40495). `CoworkSessionWatcher` reads Claude
/// Desktop's own session store instead; this file maps its updates onto
/// ordinary `claude` session cards hosted by Claude Desktop. Approvals cannot
/// be answered from here — a waiting card only says so, and a click opens the
/// conversation in Claude Desktop.
extension AppState {
    /// Keeps store ids (`local_<uuid>`) disjoint from hook session ids.
    nonisolated static let coworkSessionPrefix = "cowork:"
    nonisolated static let claudeDesktopBundleId = "com.anthropic.claudefordesktop"

    nonisolated static func coworkSessionKey(_ storeSessionId: String) -> String {
        coworkSessionPrefix + storeSessionId
    }

    nonisolated static func coworkStoreSessionId(fromKey key: String) -> String? {
        guard key.hasPrefix(coworkSessionPrefix) else { return nil }
        return String(key.dropFirst(coworkSessionPrefix.count))
    }

    /// A Cowork card waiting on a permission card in Claude Desktop. The idle
    /// cleanup's "no events for 5 minutes, the connection must have dropped"
    /// rule must not flip it: the store stays silent for exactly as long as the
    /// card is left open, and archiving, deleting or quitting Claude Desktop
    /// each clear the card through their own path.
    nonisolated static func isCoworkWaitingOnDesktop(key: String, status: AgentStatus) -> Bool {
        key.hasPrefix(coworkSessionPrefix) && (status == .waitingApproval || status == .waitingQuestion)
    }

    static func isCoworkTrackingEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: SettingsKey.trackClaudeDesktopCowork) != nil else {
            return SettingsDefaults.trackClaudeDesktopCowork
        }
        return defaults.bool(forKey: SettingsKey.trackClaudeDesktopCowork)
    }

    // MARK: - Lifecycle

    /// Idempotent. With the setting off this also clears any Cowork card left
    /// over from the previous run.
    func startCoworkWatcher(rootPath: String = CoworkPaths.defaultRoot()) {
        guard Self.isCoworkTrackingEnabled() else {
            stopCoworkWatcher()
            return
        }
        guard coworkWatcher == nil else { return }
        let watcher = CoworkSessionWatcher(rootPath: rootPath) { [weak self] output in
            Task { @MainActor in self?.handleCoworkOutput(output) }
        }
        coworkWatcher = watcher
        watcher.start()
    }

    func stopCoworkWatcher() {
        coworkWatcher?.stop()
        coworkWatcher = nil
        removeCoworkSessions()
    }

    func removeCoworkSessions() {
        for key in sessions.keys where key.hasPrefix(Self.coworkSessionPrefix) {
            removeSession(key)
        }
    }

    func handleCoworkOutput(_ output: CoworkSessionWatcher.Output) {
        // A delivery queued before the watcher was stopped must not bring
        // cards back.
        guard coworkWatcher != nil else { return }
        switch output {
        case .launchSnapshot(let updates):
            let claudeDesktop = NSRunningApplication
                .runningApplications(withBundleIdentifier: Self.claudeDesktopBundleId)
                .first
            applyCoworkLaunchSnapshot(
                updates,
                claudeDesktopRunning: claudeDesktop != nil,
                claudeDesktopLaunchedAt: claudeDesktop?.launchDate
            )
        case .updates(let updates):
            for update in updates {
                applyCoworkUpdate(update)
            }
            refreshDerivedState()
        case .removed(let storeIds):
            for storeId in storeIds where sessions[Self.coworkSessionKey(storeId)] != nil {
                removeSession(Self.coworkSessionKey(storeId))
            }
        }
    }

    // MARK: - Applying updates

    /// Reconcile with the store right after launch. Cards restored from the
    /// previous run's `sessions.json` are only a snapshot of what was on screen
    /// then; the store decides now. Anything it does not vouch for — archived,
    /// deleted, gone quiet, or Claude Desktop not even running — goes, so a
    /// restart never resurrects a finished Cowork task as a ghost card.
    ///
    /// A turn (or permission card) the log leaves open but that was last
    /// written before the running Claude Desktop started died with the previous
    /// instance — Claude Desktop logs nothing when it restarts over one — so it
    /// is rebuilt idle rather than as a card that "thinks" forever.
    func applyCoworkLaunchSnapshot(
        _ updates: [CoworkSessionWatcher.SessionUpdate],
        claudeDesktopRunning: Bool,
        claudeDesktopLaunchedAt: Date? = nil
    ) {
        let vouched = claudeDesktopRunning
            ? Set(updates.map { Self.coworkSessionKey($0.sessionId) })
            : []
        for key in sessions.keys where key.hasPrefix(Self.coworkSessionPrefix) && !vouched.contains(key) {
            removeSession(key)
        }
        guard claudeDesktopRunning else { return }
        for update in updates {
            applyCoworkUpdate(update, isLaunch: true)
            let key = Self.coworkSessionKey(update.sessionId)
            if let launchedAt = claudeDesktopLaunchedAt,
               let lastActivity = update.lastActivity,
               lastActivity < launchedAt,
               var snapshot = sessions[key],
               snapshot.status != .idle {
                let waitBefore = displayOnlyWaitKind(forSession: key)
                snapshot.status = .idle
                snapshot.currentTool = nil
                snapshot.toolDescription = nil
                sessions[key] = snapshot
                noteDisplayOnlyWait(sessionId: key, was: waitBefore)
            }
        }
        refreshDerivedState()
    }

    /// Apply one watcher update. Only a launch rebuild or live audit activity
    /// may open a card: a metadata-only change (a generated title, a re-save)
    /// for a session the idle sweep already collected is history, not activity.
    func applyCoworkUpdate(_ update: CoworkSessionWatcher.SessionUpdate, isLaunch: Bool = false) {
        let key = Self.coworkSessionKey(update.sessionId)
        let metadata = update.metadata
        guard CoworkSessionPolicy.isTrackable(metadata),
              !CoworkSessionPolicy.isShadowedByHookSession(
                cliSessionId: metadata.cliSessionId,
                existingSessionKeys: Set(sessions.keys)
              ) else {
            if sessions[key] != nil { removeSession(key) }
            return
        }
        let isNew = sessions[key] == nil
        guard !isNew || isLaunch || update.isLive else { return }
        let waitBefore = displayOnlyWaitKind(forSession: key)

        var snapshot = sessions[key] ?? SessionSnapshot(startTime: metadata.createdAt ?? Date())
        Self.applyCoworkMetadata(&snapshot, metadata: metadata, transcriptPath: update.transcriptPath)
        Self.applyCoworkAuditState(&snapshot, state: update.audit)
        if update.isLive {
            snapshot.lastActivity = Date()
        } else if isNew, let lastActivity = update.lastActivity {
            // Rebuilt from history: keep the real age so the idle sweep
            // retires it on the same clock as every other card.
            snapshot.lastActivity = lastActivity
        }
        sessions[key] = snapshot
        attachTranscriptTailerIfNeeded(sessionId: key)
        // A permission card or question in Claude Desktop: reminders, and a
        // push when a live one first appears.
        noteDisplayOnlyWait(
            sessionId: key,
            was: waitBefore,
            asking: DisplayOnlyWait.content(forCowork: update.audit),
            announce: update.isLive && !isLaunch
        )

        guard update.isLive else { return }
        if snapshot.status != .idle,
           activeSessionId == nil || sessions[activeSessionId ?? ""]?.status == .idle {
            activeSessionId = key
        }
        // One cue per turn boundary, reusing the hook event names so the
        // existing per-event sound toggles apply unchanged.
        if update.turnsCompleted > 0, snapshot.status == .idle {
            SoundManager.shared.handleEvent(
                update.audit.lastTurnFailed ? EventSoundRouting.turnFailed : "Stop",
                sessionId: key
            )
            enqueueCompletion(key)
            pushTurnEnded(sessionId: key, failed: update.audit.lastTurnFailed)
        } else if update.permissionsRequested > 0,
                  snapshot.status == .waitingApproval || snapshot.status == .waitingQuestion {
            // Display-only wait, like Cursor's in-IDE question (#265): the sound
            // and the waiting status say Cowork is blocked; nothing is queued,
            // since the answer can only be given in Claude Desktop.
            SoundManager.shared.handleEvent("PermissionRequest")
        } else if update.promptsStarted > 0 {
            let isFreshSession = isNew && metadata.createdAt.map { Date().timeIntervalSince($0) < 120 } == true
            SoundManager.shared.handleEvent(isFreshSession ? "SessionStart" : "UserPromptSubmit")
        }
    }

    /// Identity and context from `local_<id>.json`. Pure — shared by live
    /// updates, the launch rebuild and tests.
    nonisolated static func applyCoworkMetadata(
        _ snapshot: inout SessionSnapshot,
        metadata: CoworkSessionMetadata,
        transcriptPath: String?
    ) {
        // The engine is Claude Code: keep the claude mascot and every
        // transcript-driven feature. The host bundle marks it as a Claude
        // Desktop session (badge, native-app handling, click-to-jump).
        snapshot.source = "claude"
        snapshot.termBundleId = claudeDesktopBundleId
        snapshot.termApp = "Claude"
        if let cliSessionId = metadata.cliSessionId {
            snapshot.providerSessionId = cliSessionId
        }
        if let title = metadata.displayTitle {
            snapshot.sessionTitle = title
        }
        if let cwd = metadata.hostCwd {
            snapshot.cwd = cwd
        }
        if let model = metadata.model {
            snapshot.model = model
        }
        if let transcriptPath {
            snapshot.transcriptPath = transcriptPath
        }
    }

    /// Status from the audit-log reducer. Pure.
    nonisolated static func applyCoworkAuditState(_ snapshot: inout SessionSnapshot, state: CoworkAuditState) {
        switch state.phase {
        case .idle:
            snapshot.status = .idle
            snapshot.currentTool = nil
            snapshot.toolDescription = nil
        case .processing:
            // `.running` is what hook sources report while a tool executes; the
            // bare "thinking" indicator stays for model output.
            snapshot.status = state.currentTool == nil ? .processing : .running
            snapshot.interrupted = false
            snapshot.currentTool = state.currentTool?.name
            snapshot.toolDescription = state.currentTool?.detail
        case .waitingApproval:
            let tool = state.activePermission?.toolName ?? "tool"
            let ask = String(format: L10n.shared["cowork_waiting_approval"], tool)
            snapshot.status = .waitingApproval
            snapshot.currentTool = tool
            snapshot.toolDescription = state.activePermission?.detail.map { "\(ask) · \($0)" } ?? ask
        case .waitingQuestion:
            snapshot.status = .waitingQuestion
            snapshot.currentTool = "AskUserQuestion"
            if let question = state.activePermission?.detail {
                snapshot.toolDescription = String(format: L10n.shared["cowork_waiting_question"], question)
            } else {
                snapshot.toolDescription = L10n.shared["cowork_waiting_question_generic"]
            }
        }

        // Without a transcript yet (the CLI writes it a beat after the audit
        // log) fall back to what the audit carries; once the tailer is attached
        // it owns the chat lines, so both sources never double-post.
        guard snapshot.transcriptPath == nil else { return }
        if let prompt = state.lastPrompt, snapshot.lastUserPrompt != prompt {
            snapshot.lastUserPrompt = prompt
            snapshot.addRecentMessage(ChatMessage(isUser: true, text: prompt))
        }
        if state.phase == .idle, state.completedTurnCount > 0 {
            let reply = state.lastResultText
                ?? L10n.shared[state.lastTurnFailed ? "reply_failed_placeholder" : "reply_complete_placeholder"]
            if snapshot.lastAssistantMessage != reply {
                snapshot.lastAssistantMessage = reply
                snapshot.addRecentMessage(ChatMessage(isUser: false, text: reply))
            }
        }
    }

    // MARK: - Click-to-jump

    /// Open a Cowork card's conversation in Claude Desktop. Returns false when
    /// `sessionKey` is not a Cowork card, so the caller falls back to its
    /// generic activation.
    ///
    /// The deep link is not a guess: Claude Desktop's URL handler routes
    /// `claude://claude.ai/cowork/<id>` to its in-app `/cowork/<id>` screen,
    /// the same route its own "needs input" and "task finished" notifications
    /// navigate to (verified in the shipped app bundle, v2.2553).
    @discardableResult
    nonisolated static func openCoworkSession(sessionKey: String) -> Bool {
        guard let storeId = coworkStoreSessionId(fromKey: sessionKey) else { return false }
        let workspace = NSWorkspace.shared
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeDesktopBundleId).first,
           app.isHidden {
            app.unhide()
        }
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: claudeDesktopBundleId) else {
            return true
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Reopen first, like a Dock click: it brings back a closed or hidden
        // main window (and switches Space). The link event queues behind it and
        // then navigates that window to the conversation.
        workspace.openApplication(at: appURL, configuration: configuration)
        if let url = CoworkSessionPolicy.deepLinkURL(sessionId: storeId) {
            workspace.open([url], withApplicationAt: appURL, configuration: configuration)
        }
        return true
    }
}
