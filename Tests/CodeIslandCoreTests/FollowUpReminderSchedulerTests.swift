import XCTest
@testable import CodeIslandCore

final class FollowUpReminderSchedulerTests: XCTestCase {
    typealias Key = FollowUpReminderScheduler.Key

    private let t0 = Date(timeIntervalSinceReferenceDate: 10_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Off

    func testOffKeepsNoStateAndSchedulesNothing() {
        var scheduler = FollowUpReminderScheduler(interval: nil)
        scheduler.sync(kind: .approval, waiting: ["a"], now: t0)
        scheduler.track(kind: .completion, sessionId: "b", now: t0)

        XCTAssertFalse(scheduler.isEnabled)
        XCTAssertTrue(scheduler.isEmpty)
        XCTAssertNil(scheduler.nextWakeDate())
        XCTAssertEqual(scheduler.collectDue(now: at(3_600), heldBack: false), [])
    }

    func testZeroIntervalMeansOff() {
        XCTAssertFalse(FollowUpReminderScheduler(interval: 0).isEnabled)
    }

    func testTurningOffDropsEverything() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, waiting: ["a"], now: t0)
        scheduler.setInterval(nil)
        XCTAssertTrue(scheduler.isEmpty)
        XCTAssertNil(scheduler.nextWakeDate())
    }

    // MARK: - Firing

    func testFiresExactlyAtTheInterval() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, waiting: ["a"], now: t0)
        XCTAssertEqual(scheduler.nextWakeDate(), at(60))

        XCTAssertEqual(scheduler.collectDue(now: at(59), heldBack: false), [])
        let fired = scheduler.collectDue(now: at(60), heldBack: false)
        XCTAssertEqual(fired, [FollowUpReminder(
            kind: .approval, sessionId: "a", attempt: 1, maxAttempts: 3, waitingSince: t0, delivery: .onTime
        )])
        XCTAssertEqual(scheduler.nextWakeDate(), at(120), "next one is an interval after the last delivery")
    }

    func testApprovalStopsAfterThreeReminders() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, waiting: ["a"], now: t0)

        var attempts: [Int] = []
        for minute in 1...6 {
            attempts += scheduler.collectDue(now: at(Double(minute) * 60), heldBack: false).map(\.attempt)
            // The request is still waiting the whole time.
            scheduler.sync(kind: .approval, waiting: ["a"], now: at(Double(minute) * 60))
        }
        XCTAssertEqual(attempts, [1, 2, 3])
        XCTAssertNil(scheduler.nextWakeDate())
        XCTAssertTrue(scheduler.trackedKeys.contains(Key(.approval, "a")),
                      "an exhausted entry is kept so a re-sync cannot restart it")
    }

    func testFinalAttemptIsMarked() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .question, waiting: ["q"], now: t0)
        let finals = (1...3).flatMap { scheduler.collectDue(now: at(Double($0) * 60), heldBack: false) }.map(\.isFinal)
        XCTAssertEqual(finals, [false, false, true])
    }

    func testCompletionRemindsOnceAndCanBeRestarted() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.track(kind: .completion, sessionId: "c", now: t0)

        let first = scheduler.collectDue(now: at(60), heldBack: false)
        XCTAssertEqual(first.map(\.attempt), [1])
        XCTAssertTrue(first[0].isFinal)
        XCTAssertEqual(scheduler.collectDue(now: at(600), heldBack: false), [])
        XCTAssertTrue(scheduler.isEmpty, "a done completion leaves nothing behind")

        // A new finished turn is new news.
        scheduler.track(kind: .completion, sessionId: "c", now: at(700))
        XCTAssertEqual(scheduler.collectDue(now: at(760), heldBack: false).map(\.attempt), [1])
    }

    func testRetrackingACompletionRestartsItsClock() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.track(kind: .completion, sessionId: "c", now: t0)
        scheduler.track(kind: .completion, sessionId: "c", now: at(50))
        XCTAssertEqual(scheduler.collectDue(now: at(60), heldBack: false), [])
        XCTAssertEqual(scheduler.collectDue(now: at(110), heldBack: false).count, 1)
    }

    // MARK: - Cancellation

    func testResolvedItemsDisappearOnSync() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, waiting: ["a", "b"], now: t0)
        scheduler.sync(kind: .approval, waiting: ["b"], now: at(10))
        XCTAssertEqual(scheduler.collectDue(now: at(60), heldBack: false).map(\.sessionId), ["b"])
    }

    func testSyncOnlyTouchesItsOwnKind() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, waiting: ["a"], now: t0)
        scheduler.track(kind: .completion, sessionId: "a", now: t0)
        scheduler.sync(kind: .question, waiting: [], now: at(1))
        XCTAssertEqual(scheduler.trackedKeys, [Key(.approval, "a"), Key(.completion, "a")])
    }

    func testSilencedRequestIsNotRestartedWhileStillWaiting() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, waiting: ["a"], now: t0)
        scheduler.silence(Key(.approval, "a"))
        scheduler.sync(kind: .approval, waiting: ["a"], now: at(30))

        XCTAssertEqual(scheduler.collectDue(now: at(600), heldBack: false), [])
        XCTAssertNil(scheduler.nextWakeDate())

        // Once it is resolved, a later request from the same session is fresh.
        scheduler.sync(kind: .approval, waiting: [], now: at(700))
        scheduler.sync(kind: .approval, waiting: ["a"], now: at(800))
        XCTAssertEqual(scheduler.collectDue(now: at(860), heldBack: false).map(\.attempt), [1])
    }

    func testSilenceAllForASession() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, waiting: ["a", "b"], now: t0)
        scheduler.track(kind: .completion, sessionId: "a", now: t0)
        scheduler.silenceAll(sessionId: "a")
        XCTAssertEqual(scheduler.collectDue(now: at(60), heldBack: false).map(\.sessionId), ["b"])
    }

    // MARK: - Held back (lock screen, quiet hours)

    func testHeldBackItemIsReportedOnceThenCaughtUpOnReturn() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, waiting: ["a"], now: t0)

        let whileLocked = scheduler.collectDue(now: at(60), heldBack: true)
        XCTAssertEqual(whileLocked.map(\.delivery), [.deferred])
        XCTAssertEqual(whileLocked.map(\.attempt), [1])
        XCTAssertTrue(scheduler.hasOwed)
        XCTAssertNil(scheduler.nextWakeDate(), "an owed item waits on the unlock, not the clock")
        XCTAssertEqual(scheduler.collectDue(now: at(130), heldBack: true), [], "reported once")

        // Unlock at 5 minutes: the clock kept running, so the catch-up is immediate.
        let back = scheduler.collectDue(now: at(300), heldBack: false)
        XCTAssertEqual(back.map(\.delivery), [.catchUp])
        XCTAssertEqual(back.map(\.attempt), [1], "missed intervals collapse into one catch-up")
        XCTAssertFalse(scheduler.hasOwed)
        XCTAssertEqual(scheduler.nextWakeDate(), at(360))
    }

    func testNothingOwedWhenResolvedDuringTheHold() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, waiting: ["a"], now: t0)
        _ = scheduler.collectDue(now: at(60), heldBack: true)
        scheduler.sync(kind: .approval, waiting: [], now: at(90))
        XCTAssertEqual(scheduler.collectDue(now: at(120), heldBack: false), [])
        XCTAssertTrue(scheduler.isEmpty)
    }

    func testHoldBeforeDueTimeChangesNothing() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, waiting: ["a"], now: t0)
        XCTAssertEqual(scheduler.collectDue(now: at(30), heldBack: true), [])
        XCTAssertFalse(scheduler.hasOwed)
        XCTAssertEqual(scheduler.collectDue(now: at(60), heldBack: false).map(\.delivery), [.onTime])
    }

    // MARK: - Interval changes and ordering

    func testChangingTheIntervalRetimesPendingItems() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, waiting: ["a"], now: t0)
        scheduler.setInterval(300)
        XCTAssertEqual(scheduler.nextWakeDate(), at(300))
        XCTAssertEqual(scheduler.collectDue(now: at(60), heldBack: false), [])
    }

    func testDueItemsComeMostUrgentFirst() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.track(kind: .completion, sessionId: "c", now: t0)
        scheduler.sync(kind: .question, waiting: ["q"], now: t0)
        scheduler.sync(kind: .approval, waiting: ["early"], now: at(1))
        scheduler.sync(kind: .approval, waiting: ["early", "late"], now: at(5))

        let fired = scheduler.collectDue(now: at(120), heldBack: false)
        XCTAssertEqual(fired.map(\.kind), [.approval, .approval, .question, .completion])
        XCTAssertEqual(fired.prefix(2).map(\.sessionId), ["early", "late"],
                       "oldest waiting approval first")
    }
}
