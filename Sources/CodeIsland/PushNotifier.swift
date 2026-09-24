import Foundation
import CoreGraphics
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "Push")

/// What `PushNotifier.notify` did with one moment.
enum PushDecision: Equatable {
    /// Push notifications are switched off.
    case disabled
    case skipped(PushSkipReason)
    /// Handed to these channels. Delivery itself is asynchronous; its outcome
    /// lands in `PushNotifier.lastDelivery`.
    case sent([PushChannelKind])
}

/// Last outcome per channel. Shown under the channel in Settings, so a push
/// that failed at 3 a.m. is visible without waiting for the next one.
struct PushDeliveryRecord: Equatable {
    let date: Date
    let kind: PushEventKind?  // nil = "Send test"
    let result: PushDeliveryResult
}

/// The approval or question a push is about, so the notifier can tell when
/// it has been answered.
struct PushPendingRequest {
    /// Identity within its session and kind: the tool call id when the
    /// agent sends one, else a fingerprint of what is asked.
    let key: String
    /// What is waiting under this identity right now, rebuilt from the
    /// queue (or the display-only wait); nil once it was answered or dropped.
    let current: @MainActor () -> PushContent?
}

/// Sends pushes to a phone or a team chat. Decides once per moment (gate →
/// channel selection → dedupe), then fans out to every channel that takes
/// the kind. Fire-and-forget like the webhook: a slow or failing push server
/// never touches the hook pipeline, it only updates `lastDelivery`.
///
/// Entry points:
/// - `notify(_:subject:…)` for any structured content;
/// - `AppState.pushFollowUpReminder(_:)`, subscribed to
///   `FollowUpReminderController` by `connectPushToFollowUps()`;
/// - `sendTest(_:)` for the settings page.
@MainActor
final class PushNotifier: ObservableObject {
    static let shared = PushNotifier()

    /// The only path to the network. Tests replace it with a recorder.
    var transport: PushTransport = URLSessionPushTransport.shared
    var presence: () -> PushPresenceSnapshot = { PushPresence.current() }
    var clock: () -> Date = Date.init
    var defaults: UserDefaults = .standard

    @Published private(set) var lastDelivery: [PushChannelKind: PushDeliveryRecord] = [:]
    /// The most recent `notify` verdict, for diagnostics and tests.
    private(set) var lastDecision: PushDecision?
    private var deduplicator = PushDeduplicator()

    /// Approvals / questions pushed and not yet seen answered. Each holds
    /// its dedupe slot until `requestsChanged` finds it gone, so a replay
    /// stays one push while the same request waits, and the next one after
    /// it is answered is news even seconds later.
    private var tracked: [String: TrackedRequest] = [:]
    private var pruneScheduled = false

    private struct TrackedRequest {
        let kind: PushEventKind
        let subject: PushSubject
        let request: PushPendingRequest
    }

    private init() {}

    /// The approval / question queues or a display-only wait changed. The
    /// check runs on the next main-actor turn, once the change has settled:
    /// a queue is emptied and refilled in one go when a request is replayed
    /// or promoted, and that must not read as "answered". One flag check
    /// when nothing is tracked.
    func requestsChanged() {
        guard !tracked.isEmpty, !pruneScheduled else { return }
        pruneScheduled = true
        Task { @MainActor [weak self] in self?.forgetAnsweredRequests() }
    }

    /// Drops every tracked request that is no longer waiting, freeing its
    /// dedupe slot.
    func forgetAnsweredRequests() {
        pruneScheduled = false
        for (id, entry) in tracked where entry.request.current() == nil {
            tracked[id] = nil
            deduplicator.forget(kind: entry.kind, sessionId: entry.subject.sessionId, requestKey: entry.request.key)
        }
    }

    private static func trackingId(_ kind: PushEventKind, _ sessionId: String, _ key: String) -> String {
        "\(kind.rawValue)|\(sessionId)|\(key)"
    }

    /// Whether a push of `kind` for this session went out at or after `date`
    /// (remembered for an hour).
    func hasPushed(_ kind: PushEventKind, sessionId: String, since date: Date) -> Bool {
        guard let sent = deduplicator.lastSent(kind: kind, sessionId: sessionId) else { return false }
        return sent >= date
    }

    // MARK: Settings

    var isEnabled: Bool { defaults.bool(forKey: SettingsKey.pushEnabled) }

    /// `bool(forKey:)` reads an unregistered key as false; this one defaults on.
    var onlyWhenAway: Bool {
        defaults.object(forKey: SettingsKey.pushOnlyWhenAway) == nil
            ? SettingsDefaults.pushOnlyWhenAway
            : defaults.bool(forKey: SettingsKey.pushOnlyWhenAway)
    }

    var idleThreshold: TimeInterval {
        let minutes = defaults.object(forKey: SettingsKey.pushAwayIdleMinutes) == nil
            ? SettingsDefaults.pushAwayIdleMinutes
            : defaults.integer(forKey: SettingsKey.pushAwayIdleMinutes)
        return TimeInterval(max(minutes, 1) * 60)
    }

    var summaryLimit: Int {
        let stored = defaults.integer(forKey: SettingsKey.pushSummaryLength)
        return stored > 0 ? stored : SettingsDefaults.pushSummaryLength
    }

    var channels: [PushChannelConfig] {
        PushChannelConfig.decodeList(defaults.string(forKey: SettingsKey.pushChannels) ?? SettingsDefaults.pushChannels)
    }

    // MARK: Sending

    /// Decide and, if it passes, send. Cheap when disabled: one defaults read.
    ///
    /// - `smartSuppressed`: the island itself declined to pop this up
    ///   because the agent's terminal is in front (Smart Suppress).
    /// - `isSubagent` / `interrupted`: only meaningful for completions.
    /// - `request`: the approval / question this push is about, for
    ///   `.permission` / `.question` content; nil otherwise.
    @discardableResult
    func notify(
        _ content: PushContent,
        subject: PushSubject,
        smartSuppressed: @autoclosure () -> Bool = false,
        isSubagent: Bool = false,
        interrupted: Bool = false,
        request: PushPendingRequest? = nil
    ) -> PushDecision {
        let decision = decide(
            content,
            subject: subject,
            smartSuppressed: smartSuppressed(),
            isSubagent: isSubagent,
            interrupted: interrupted,
            request: request
        )
        lastDecision = decision
        return decision
    }

    private func decide(
        _ content: PushContent,
        subject: PushSubject,
        smartSuppressed: @autoclosure () -> Bool,
        isSubagent: Bool,
        interrupted: Bool,
        request: PushPendingRequest?
    ) -> PushDecision {
        guard isEnabled else { return .disabled }
        let kind = content.kind
        let targets = channels.filter { $0.accepts(kind) }
        guard !targets.isEmpty else { return skip(.noChannel, kind, subject) }

        let gate = PushGateInput(
            kind: kind,
            onlyWhenAway: onlyWhenAway,
            idleThreshold: idleThreshold,
            presence: presence(),
            smartSuppressed: smartSuppressed(),
            isSubagent: isSubagent,
            interrupted: interrupted
        )
        if let reason = PushGate.evaluate(gate) { return skip(reason, kind, subject) }

        let now = clock()
        let request = kind == .permission || kind == .question ? request : nil
        if let reason = deduplicator.admit(kind: kind, sessionId: subject.sessionId, requestKey: request?.key, now: now) {
            return skip(reason, kind, subject)
        }
        if let request {
            tracked[Self.trackingId(kind, subject.sessionId, request.key)] = TrackedRequest(
                kind: kind,
                subject: subject,
                request: request
            )
        }

        // Rendered once per detail level; team chats default to headlines only.
        var rendered: [Bool: PushMessage] = [:]
        for channel in targets {
            let message = rendered[channel.includeDetails] ?? PushMessageFormatter.render(
                content,
                subject: subject,
                strings: Self.strings(),
                summaryLimit: summaryLimit,
                includeDetails: channel.includeDetails,
                now: now
            )
            rendered[channel.includeDetails] = message
            deliver(message, to: channel, kind: kind, now: now)
        }
        log.info("push \(kind.rawValue, privacy: .public) session=\(subject.sessionId, privacy: .public) → \(targets.map(\.kind.rawValue).joined(separator: ","), privacy: .public)")
        return .sent(targets.map(\.kind))
    }

    /// "Send test": bypasses every gate and the dedupe, and reports exactly
    /// what the server said.
    func sendTest(_ channel: PushChannelConfig) async -> PushDeliveryResult {
        let message = PushMessage.test(strings: Self.strings())
        let result: PushDeliveryResult
        do {
            let request = try PushRequestBuilder.request(for: message, channel: channel, now: clock())
            let response = await transport.send(request)
            result = .from(response, kind: channel.kind, requestURL: request.url)
        } catch {
            result = Self.configFailure(error)
        }
        lastDelivery[channel.kind] = PushDeliveryRecord(date: clock(), kind: nil, result: result)
        return result
    }

    private func deliver(_ message: PushMessage, to channel: PushChannelConfig, kind: PushEventKind, now: Date) {
        let request: PushHTTPRequest
        do {
            request = try PushRequestBuilder.request(for: message, channel: channel, now: now)
        } catch {
            lastDelivery[channel.kind] = PushDeliveryRecord(date: now, kind: kind, result: Self.configFailure(error))
            return
        }
        let transport = self.transport
        Task { [weak self] in
            let response = await transport.send(request)
            let result = PushDeliveryResult.from(response, kind: channel.kind, requestURL: request.url)
            if !result.ok {
                log.error("push to \(channel.kind.rawValue, privacy: .public) failed: \(result.loggableSummary(for: channel), privacy: .public)")
            }
            self?.lastDelivery[channel.kind] = PushDeliveryRecord(date: self?.clock() ?? Date(), kind: kind, result: result)
        }
    }

    private func skip(_ reason: PushSkipReason, _ kind: PushEventKind, _ subject: PushSubject) -> PushDecision {
        log.debug("push \(kind.rawValue, privacy: .public) session=\(subject.sessionId, privacy: .public) skipped: \(reason.rawValue, privacy: .public)")
        return .skipped(reason)
    }

    private static func configFailure(_ error: Error) -> PushDeliveryResult {
        let problem = (error as? PushConfigProblem) ?? .invalidURL
        return PushDeliveryResult(ok: false, statusCode: nil, message: L10n.shared["push_problem_\(problem.rawValue)"])
    }

    static func strings(_ l10n: L10n = .shared) -> PushStrings {
        PushStrings(
            permission: l10n["push_msg_permission"],
            question: l10n["push_msg_question"],
            completion: l10n["push_msg_completion"],
            error: l10n["push_msg_error"],
            reminder: l10n["push_msg_reminder"],
            waitingMinutes: l10n["push_msg_waiting_minutes"],
            secretQuestion: l10n["push_msg_secret_question"],
            moreOptions: l10n["push_msg_more_options"],
            testHeadline: l10n["push_msg_test_headline"],
            testBody: l10n["push_msg_test_body"],
            answerIn: l10n["push_msg_answer_in"],
            answerOnMac: l10n["push_msg_answer_on_mac"]
        )
    }

    /// Clears dedupe state and delivery records between tests.
    func resetForTesting() {
        deduplicator = PushDeduplicator()
        lastDelivery = [:]
        lastDecision = nil
        tracked = [:]
        pruneScheduled = false
    }
}

// MARK: - Presence

/// "Is anyone at this Mac", for the push gate. Lock, screen saver and display
/// sleep are the signals `SceneMuteMonitor` already tracks for event sounds;
/// idle time and fast user switching are read on demand. Nothing here needs a
/// permission or an observer of its own.
enum PushPresence {
    @MainActor
    static func current() -> PushPresenceSnapshot {
        let scene = SceneMuteMonitor.shared.state
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        // Another user owns the console: this one is not at the screen.
        let onConsole = session?["kCGSSessionOnConsoleKey"] as? Bool ?? true
        // ~0 is kCGAnyInputEventType: keyboard, mouse, trackpad, tablet.
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return PushPresenceSnapshot(
            screenLocked: scene.screenLocked,
            screenSaverRunning: scene.screensaverRunning,
            displaysAsleep: scene.displaysAsleep,
            sessionOnConsole: onConsole,
            idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        )
    }
}
