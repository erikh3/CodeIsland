import Foundation

/// What a follow-up reminder is about.
public enum FollowUpReminderKind: String, Sendable, CaseIterable {
    /// A permission request still waiting for allow / deny.
    case approval
    /// A question (AskUserQuestion, Notification question, Codex
    /// request_user_input) still waiting for an answer.
    case question
    /// A finished turn the user has not looked at yet.
    case completion

    /// Approvals and questions block the agent, so they are worth nagging
    /// about a few times; a finished turn blocks nothing and gets one nudge.
    public var maxAttempts: Int {
        switch self {
        case .approval, .question: return 3
        case .completion: return 1
        }
    }
}

/// One follow-up reminder, handed to whoever reacts to it (the island's sound
/// and card, and any push channel wired to `FollowUpReminderController`).
public struct FollowUpReminder: Equatable, Sendable {
    public enum Delivery: String, Equatable, Sendable {
        /// Delivered locally at its due time.
        case onTime
        /// Came due while local reminders were held back (screen locked,
        /// screen saver, displays asleep, quiet hours). Nothing played on the
        /// Mac; a `.catchUp` follows if the item is still waiting when the hold
        /// ends. Remote channels may still want this one — the user is away.
        case deferred
        /// The held-back reminder, delivered as soon as the hold ended.
        case catchUp
    }

    public let kind: FollowUpReminderKind
    public let sessionId: String
    /// 1-based. For `.deferred` it is the attempt that is owed.
    public let attempt: Int
    public let maxAttempts: Int
    /// When the item started waiting (request arrival / turn completion).
    public let waitingSince: Date
    public let delivery: Delivery

    public init(
        kind: FollowUpReminderKind,
        sessionId: String,
        attempt: Int,
        maxAttempts: Int,
        waitingSince: Date,
        delivery: Delivery
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.waitingSince = waitingSince
        self.delivery = delivery
    }

    /// No further reminder will follow for this item.
    public var isFinal: Bool { delivery != .deferred && attempt >= maxAttempts }
}

/// Pure timing state machine behind follow-up reminders. No timers, no clock:
/// every mutation takes `now`, and the owner arms a single wake-up for
/// `nextWakeDate` — so with the feature off (or nothing waiting) there is no
/// state and nothing scheduled.
///
/// Items come in two flavours:
/// - **Synced** (approvals, questions): the owner reports the full set of
///   sessions that are waiting via `sync`, and entries appear and disappear
///   with it. A silenced or exhausted entry stays until its item stops
///   waiting, so a later sync cannot restart the reminders for the very same
///   request.
/// - **Tracked** (completions): started by an event with `track`; a newer
///   event for the same session restarts it, and it is dropped once done.
///
/// Holding back (lock screen, quiet hours) does not pause the clock: an item
/// that comes due while held is marked owed, and the first tick after the hold
/// delivers it at once as a catch-up. Missed attempts collapse into that one
/// catch-up rather than being spent silently.
public struct FollowUpReminderScheduler: Sendable {
    public struct Key: Hashable, Sendable {
        public let kind: FollowUpReminderKind
        public let sessionId: String

        public init(_ kind: FollowUpReminderKind, _ sessionId: String) {
            self.kind = kind
            self.sessionId = sessionId
        }
    }

    struct Entry: Sendable {
        var waitingSince: Date
        /// Last delivery, or `waitingSince` before the first one. Due times
        /// are anchored here so changing the interval re-times everything.
        var anchor: Date
        var delivered: Int
        /// Came due while held back; waiting for the hold to end.
        var owed: Bool
        /// Out of attempts, or silenced by the owner. Kept (synced entries
        /// only) so the same waiting item is not re-tracked from scratch.
        var done: Bool
        /// Created by `sync` rather than `track`.
        var synced: Bool
    }

    /// Seconds between reminders; nil means the feature is off.
    public private(set) var interval: TimeInterval?
    private var entries: [Key: Entry] = [:]

    public init(interval: TimeInterval? = nil) {
        self.interval = Self.normalized(interval)
    }

    public var isEnabled: Bool { interval != nil }
    public var isEmpty: Bool { entries.isEmpty }
    public var trackedKeys: Set<Key> { Set(entries.keys) }
    public var hasOwed: Bool { entries.values.contains { $0.owed && !$0.done } }

    /// Items that can still produce a reminder.
    public var liveKeys: Set<Key> { Set(entries.filter { !$0.value.done }.keys) }

    /// Turning the feature off drops everything; changing the interval
    /// re-times pending entries from their last delivery.
    public mutating func setInterval(_ newValue: TimeInterval?) {
        interval = Self.normalized(newValue)
        if interval == nil { entries.removeAll() }
    }

    /// Reconcile one synced kind against the sessions currently waiting.
    public mutating func sync(kind: FollowUpReminderKind, waiting: Set<String>, now: Date) {
        guard isEnabled else { return }
        for key in entries.keys where key.kind == kind && !waiting.contains(key.sessionId) {
            entries.removeValue(forKey: key)
        }
        for sessionId in waiting {
            let key = Key(kind, sessionId)
            guard entries[key] == nil else { continue }
            entries[key] = Entry(waitingSince: now, anchor: now, delivered: 0, owed: false, done: false, synced: true)
        }
    }

    /// Start (or restart) an event-driven item.
    public mutating func track(kind: FollowUpReminderKind, sessionId: String, now: Date) {
        guard isEnabled else { return }
        entries[Key(kind, sessionId)] = Entry(
            waitingSince: now, anchor: now, delivered: 0, owed: false, done: false, synced: false
        )
    }

    /// Stop reminding about an item (seen, jumped to, handled elsewhere).
    public mutating func silence(_ key: Key) {
        guard let entry = entries[key] else { return }
        if entry.synced {
            entries[key]?.done = true
            entries[key]?.owed = false
        } else {
            entries.removeValue(forKey: key)
        }
    }

    public mutating func silenceAll(sessionId: String) {
        for key in entries.keys where key.sessionId == sessionId {
            silence(key)
        }
    }

    public mutating func silenceAll(kind: FollowUpReminderKind) {
        for key in entries.keys where key.kind == kind {
            silence(key)
        }
    }

    public mutating func reset() {
        entries.removeAll()
    }

    /// Earliest moment a live, not-yet-owed entry comes due. Owed entries are
    /// waiting on the hold to end, not on the clock.
    public func nextWakeDate() -> Date? {
        guard let interval else { return nil }
        return entries.values
            .filter { !$0.done && !$0.owed }
            .map { $0.anchor.addingTimeInterval(interval) }
            .min()
    }

    /// Advance to `now`. While `heldBack`, due items become owed (reported
    /// once as `.deferred`); otherwise due and owed items are delivered and
    /// counted. Results are ordered approvals → questions → completions, then
    /// oldest first, so the caller can pick "the most urgent" from the head.
    public mutating func collectDue(now: Date, heldBack: Bool) -> [FollowUpReminder] {
        guard let interval else { return [] }
        var out: [FollowUpReminder] = []
        for (key, entry) in entries where !entry.done {
            let isDue = now >= entry.anchor.addingTimeInterval(interval)
            guard entry.owed || isDue else { continue }
            let attempt = entry.delivered + 1
            let maxAttempts = key.kind.maxAttempts
            if heldBack {
                guard !entry.owed else { continue }  // already reported
                entries[key]?.owed = true
                out.append(FollowUpReminder(
                    kind: key.kind, sessionId: key.sessionId, attempt: attempt,
                    maxAttempts: maxAttempts, waitingSince: entry.waitingSince, delivery: .deferred
                ))
                continue
            }
            out.append(FollowUpReminder(
                kind: key.kind, sessionId: key.sessionId, attempt: attempt,
                maxAttempts: maxAttempts, waitingSince: entry.waitingSince,
                delivery: entry.owed ? .catchUp : .onTime
            ))
            if attempt >= maxAttempts {
                if entry.synced {
                    entries[key]?.done = true
                    entries[key]?.owed = false
                    entries[key]?.delivered = attempt
                } else {
                    entries.removeValue(forKey: key)
                }
            } else {
                entries[key]?.delivered = attempt
                entries[key]?.owed = false
                entries[key]?.anchor = now
            }
        }
        return out.sorted(by: Self.urgency)
    }

    private static func urgency(_ a: FollowUpReminder, _ b: FollowUpReminder) -> Bool {
        let order: [FollowUpReminderKind] = [.approval, .question, .completion]
        let ra = order.firstIndex(of: a.kind) ?? 0
        let rb = order.firstIndex(of: b.kind) ?? 0
        if ra != rb { return ra < rb }
        if a.waitingSince != b.waitingSince { return a.waitingSince < b.waitingSince }
        return a.sessionId < b.sessionId
    }

    private static func normalized(_ interval: TimeInterval?) -> TimeInterval? {
        guard let interval, interval > 0 else { return nil }
        return interval
    }
}
