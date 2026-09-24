import Foundation
import CodeIslandCore

/// Push notifications, fed from the same places that drive the island:
/// the permission / question queues and the completion effect. Content is
/// built from what those queues hold, never re-guessed from raw hook JSON.
extension AppState {
    /// Who a session's pushes are about — the labels its card shows.
    func pushSubject(for sessionId: String) -> PushSubject {
        let session = sessions[sessionId]
        return PushSubject(
            sessionId: sessionId,
            agent: session?.sourceLabel ?? "Agent",
            project: session?.cwd == nil ? nil : session?.projectDisplayName,
            host: session?.remoteDisplayName
        )
    }

    /// A permission request was just queued. `smartSuppressed` is evaluated
    /// only when a push is actually on the table.
    func pushPermissionQueued(_ event: HookEvent, sessionId: String, smartSuppressed: @autoclosure () -> Bool) {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return }
        notifier.notify(
            Self.pushContent(forPermission: event, cwd: sessions[sessionId]?.cwd),
            subject: pushSubject(for: sessionId),
            smartSuppressed: smartSuppressed()
        )
    }

    /// A question (hook Notification, AskUserQuestion, Codex app-server) was just queued.
    func pushQuestionQueued(_ request: QuestionRequest, sessionId: String, smartSuppressed: @autoclosure () -> Bool) {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return }
        notifier.notify(
            Self.pushContent(forQuestion: request),
            subject: pushSubject(for: sessionId),
            smartSuppressed: smartSuppressed()
        )
    }

    /// Runs right after the reducer, before its side effects: a turn that
    /// ended on an API error pushes the error; any other turn end the
    /// reducer turned into a completion card pushes a completion.
    func pushAfterReduce(_ event: HookEvent, sessionId: String, effects: [SideEffect]) {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return }
        let session = sessions[sessionId]
        if let failure = PushEventClassifier.sessionError(eventName: event.eventName, raw: event.rawJSON) {
            notifier.notify(
                .error(type: failure.type, detail: failure.detail),
                subject: pushSubject(for: sessionId),
                smartSuppressed: !self.shouldAutoOpenPendingSurface(for: sessionId)
            )
            return
        }
        guard effects.contains(.enqueueCompletion(sessionId: sessionId)) else { return }
        notifier.notify(
            .completion(summary: Self.pushCompletionSummary(session)),
            subject: pushSubject(for: sessionId),
            smartSuppressed: !self.shouldAutoOpenPendingSurface(for: sessionId),
            isSubagent: PushEventClassifier.isSubagentCompletion(
                agentId: event.agentId,
                raw: event.rawJSON,
                sessionId: sessionId,
                session: session
            ),
            interrupted: session?.interrupted == true
        )
    }

    /// AiWork daemon turn boundary (its streams bypass the hook reducer).
    func pushAiWorkTurnEnded(_ eventName: String, sessionId: String) {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return }
        let session = sessions[sessionId]
        let content: PushContent
        switch eventName {
        case "stream.completed":
            content = .completion(summary: Self.pushCompletionSummary(session))
        case "stream.failed":
            content = .error(type: nil, detail: session?.lastAssistantMessage)
        default:
            return  // stream.aborted: the user stopped it
        }
        notifier.notify(
            content,
            subject: pushSubject(for: sessionId),
            smartSuppressed: !self.shouldAutoOpenPendingSurface(for: sessionId)
        )
    }

    /// Subscribes the push channels to follow-up reminders. Called once at launch.
    func connectPushToFollowUps() {
        followUps.addReminderHandler { [weak self] reminder in
            self?.pushFollowUpReminder(reminder)
        }
    }

    /// A follow-up reminder came due. It is rebuilt from the queue, so it
    /// carries the same command / question and options as the first push,
    /// plus how long it has been waiting.
    ///
    /// - `.deferred`: the Mac held its own reminder back (locked, screen
    ///   saver, display asleep, quiet hours) — the moment a phone matters most.
    /// - `.onTime`: the controller already skipped it when the session's
    ///   terminal was in front, so Smart Suppress has had its say.
    /// - `.catchUp`: the local replay after the hold ended; the person is
    ///   back and the deferred one already went out.
    @discardableResult
    func pushFollowUpReminder(_ reminder: FollowUpReminder) -> PushDecision {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return .disabled }
        if reminder.delivery == .catchUp { return .skipped(.userPresent) }
        let sessionId = reminder.sessionId
        let pending: PushContent
        switch reminder.kind {
        case .approval:
            guard let request = pendingPermission(forSession: sessionId) else { return .skipped(.nothingPending) }
            pending = Self.pushContent(forPermission: request.event, cwd: sessions[sessionId]?.cwd)
        case .question:
            guard let request = pendingQuestion(forSession: sessionId) else { return .skipped(.nothingPending) }
            pending = Self.pushContent(forQuestion: request)
        case .completion:
            // One nudge for a finished turn nobody looked at. If the turn's own
            // completion push reached the phone, the nudge would only repeat
            // it. (That push is decided just before the reminder's clock starts,
            // hence the slack.)
            if notifier.hasPushed(.completion, sessionId: sessionId, since: reminder.waitingSince.addingTimeInterval(-5)) {
                return .skipped(.duplicate)
            }
            pending = .completion(summary: Self.pushCompletionSummary(sessions[sessionId]))
        }
        return notifier.notify(
            .reminder(pending: pending, waitingSince: reminder.waitingSince),
            subject: pushSubject(for: sessionId)
        )
    }

    // MARK: Content

    nonisolated static func pushContent(forPermission event: HookEvent, cwd: String?) -> PushContent {
        .permission(
            tool: event.toolName,
            detail: PushDetailSummarizer.permissionDetail(
                toolInput: event.toolInput,
                fallback: event.toolDescription,
                cwd: cwd
            )
        )
    }

    /// Every question of a wizard (AskUserQuestion, Codex requestUserInput),
    /// not just the one on screen, so the user can think them all over.
    static func pushContent(forQuestion request: QuestionRequest) -> PushContent {
        let payloads = request.askUserQuestionState?.items.map(\.payload) ?? [request.question]
        return .question(
            items: payloads.map { PushQuestionItem(question: $0.question, options: $0.options ?? []) },
            isSecret: payloads.contains { $0.isSecret }
        )
    }

    /// The reply the completion card shows: this turn's last assistant
    /// message. `lastAssistantMessage` alone can still hold the previous
    /// turn's text when a Stop arrived without one, and the "Reply complete"
    /// placeholder says nothing a phone needs.
    static func pushCompletionSummary(_ session: SessionSnapshot?) -> String? {
        guard let session else { return nil }
        if let last = session.recentMessages.last {
            guard !last.isUser else { return nil }
            let placeholders = Set(L10n.strings.values.compactMap { $0["reply_complete_placeholder"] })
            return placeholders.contains(last.text) ? nil : last.text
        }
        return session.lastAssistantMessage
    }
}
