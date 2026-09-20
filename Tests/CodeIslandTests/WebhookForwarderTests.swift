import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class WebhookForwarderTests: XCTestCase {
    func testInactivityDurationClampsManualInput() {
        XCTAssertEqual(WebhookInactivityDuration.clamp(-1), 5)
        XCTAssertEqual(WebhookInactivityDuration.clamp(47), 47)
        XCTAssertEqual(WebhookInactivityDuration.clamp(7_200), 3_600)
    }


    func testInactivityDurationUsesSparseNonlinearSliderStops() {
        XCTAssertEqual(WebhookInactivityDuration.sliderStops, [30, 45, 60, 90, 120, 180, 300, 600])
        XCTAssertEqual(WebhookInactivityDuration.sliderOverflow(for: 20), .below)
        XCTAssertEqual(WebhookInactivityDuration.sliderOverflow(for: 30), .within)
        XCTAssertEqual(WebhookInactivityDuration.sliderOverflow(for: 600), .within)
        XCTAssertEqual(WebhookInactivityDuration.sliderOverflow(for: 1_200), .above)
        XCTAssertEqual(WebhookInactivityDuration.sliderPosition(for: 75), 2)
        XCTAssertEqual(WebhookInactivityDuration.seconds(forSliderPosition: 4), 120)
        XCTAssertEqual(WebhookInactivityDuration.seconds(forSliderPosition: 7), 600)
    }
    func testInactivityDurationParsesHumanExpressions() {
        XCTAssertEqual(WebhookInactivityDuration.parse("130"), 130)
        XCTAssertEqual(WebhookInactivityDuration.parse("60s"), 60)
        XCTAssertEqual(WebhookInactivityDuration.parse("3m"), 180)
        XCTAssertEqual(WebhookInactivityDuration.parse("1m30s"), 90)
        XCTAssertEqual(WebhookInactivityDuration.parse("2 minutes and 10 seconds"), 130)
        XCTAssertEqual(WebhookInactivityDuration.parse("1 min 5 sec"), 65)
        XCTAssertEqual(WebhookInactivityDuration.parse("20m"), 1_200)
        XCTAssertEqual(WebhookInactivityDuration.parse("20 minutes"), 1_200)
        XCTAssertNil(WebhookInactivityDuration.parse("soon"))
        XCTAssertNil(WebhookInactivityDuration.parse("1m later"))
    }

    func testInactivityDurationFormatsCanonicalText() {
        XCTAssertEqual(WebhookInactivityDuration.format(30), "30s")
        XCTAssertEqual(WebhookInactivityDuration.format(60), "1m")
        XCTAssertEqual(WebhookInactivityDuration.format(90), "1m 30s")
        XCTAssertEqual(WebhookInactivityDuration.format(130), "2m 10s")
        XCTAssertEqual(WebhookInactivityDuration.format(180), "3m")
        XCTAssertEqual(WebhookInactivityDuration.format(1_200), "20m")
    }

    func testInactiveUserReceivesDelayedCompletion() async throws {
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 61 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(monitor: monitor, sent: sent)
        let event = try makeEvent(name: "Stop", sessionId: "session")

        forwarder.submit(event, routeKind: .event)
        try await waitUntil { sent.count == 1 }

        XCTAssertEqual(sent.count, 1)
    }
    func testAlwaysModeSendsImmediatelyWhileUserIsActive() throws {
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(monitor: monitor, sent: sent, onlyWhenInactive: false)
        let event = try makeEvent(name: "Stop", sessionId: "session")

        forwarder.submit(event, routeKind: .event)

        XCTAssertEqual(sent.count, 1)
    }

    func testDisabledConfigurationDoesNotSend() throws {
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 61 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(monitor: monitor, sent: sent, enabled: false)
        let event = try makeEvent(name: "Stop", sessionId: "session")

        forwarder.submit(event, routeKind: .event)

        XCTAssertEqual(sent.count, 0)
    }


    func testActiveUserKeepsCompletionPendingUntilAcknowledged() async throws {
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(monitor: monitor, sent: sent)
        let event = try makeEvent(name: "Stop", sessionId: "session")

        forwarder.submit(event, routeKind: .event)
        try await Task.sleep(nanoseconds: 30_000_000)
        forwarder.acknowledgeCompletion(sessionId: "session")
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(sent.count, 0)
    }

    func testLockFlushesPendingCompletionImmediately() async throws {
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(monitor: monitor, sent: sent)
        let event = try makeEvent(name: "Stop", sessionId: "session")

        forwarder.submit(event, routeKind: .event)
        monitor.setSessionLockedForTesting(true)
        try await waitUntil { sent.count == 1 }

        XCTAssertEqual(sent.count, 1)
    }

    func testLockDoesNotFlushWhenLockedDeliveryIsDisabled() async throws {
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(
            monitor: monitor,
            sent: sent,
            sendImmediatelyWhenLocked: false
        )
        let event = try makeEvent(name: "Stop", sessionId: "session")

        forwarder.submit(event, routeKind: .event)
        monitor.setSessionLockedForTesting(true)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(sent.count, 0)
    }

    func testResolvedPermissionDoesNotSend() async throws {
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 61 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(monitor: monitor, sent: sent, actionability: { _, kind in
            kind != .permission
        })
        let event = try makeEvent(name: "PermissionRequest", sessionId: "session", toolUseId: "tool-1")

        forwarder.submit(event, routeKind: .permission)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(sent.count, 0)
    }

    func testPendingPermissionSendsWhenInactive() async throws {
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 61 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(monitor: monitor, sent: sent)
        let event = try makeEvent(name: "PermissionRequest", sessionId: "session", toolUseId: "tool-1")

        forwarder.submit(event, routeKind: .permission)
        try await waitUntil { sent.count == 1 }

        XCTAssertEqual(sent.count, 1)
    }

    // MARK: - WebhookDeliveryState resolver

    func testResolverAlwaysModeReturnsActive() {
        let state = WebhookForwarder.resolveDeliveryState(
            onlyWhenInactive: false,
            inactivitySeconds: 60,
            idleSeconds: 0
        )
        XCTAssertEqual(state, .active)
    }

    func testResolverLockedImmediateDeliveryReturnsActive() {
        let state = WebhookForwarder.resolveDeliveryState(
            onlyWhenInactive: true,
            sendImmediatelyWhenLocked: true,
            isSessionLocked: true,
            inactivitySeconds: 60,
            idleSeconds: 0
        )
        XCTAssertEqual(state, .active)
    }

    func testResolverIdleAtThresholdReturnsActive() {
        let state = WebhookForwarder.resolveDeliveryState(
            onlyWhenInactive: true,
            inactivitySeconds: 60,
            idleSeconds: 60
        )
        XCTAssertEqual(state, .active)
    }

    func testResolverIdleAboveThresholdReturnsActive() {
        let state = WebhookForwarder.resolveDeliveryState(
            onlyWhenInactive: true,
            inactivitySeconds: 60,
            idleSeconds: 90
        )
        XCTAssertEqual(state, .active)
    }

    func testResolverWaitingProgressAndRemainingSeconds() {
        let state = WebhookForwarder.resolveDeliveryState(
            onlyWhenInactive: true,
            inactivitySeconds: 60,
            idleSeconds: 45
        )
        XCTAssertEqual(state, .waitingForInactivity(progress: 0.75, remainingSeconds: 15))
    }

    func testResolverRemainingSecondsIsCeiled() {
        // idle=44.5, remaining=15.5 → ceil → 16
        let state = WebhookForwarder.resolveDeliveryState(
            onlyWhenInactive: true,
            inactivitySeconds: 60,
            idleSeconds: 44.5
        )
        if case let .waitingForInactivity(_, remaining) = state {
            XCTAssertEqual(remaining, 16)
        } else {
            XCTFail("Expected waitingForInactivity, got \(state)")
        }
    }

    func testResolverProgressClampedToOne() {
        // Passing idleSeconds slightly above threshold still returns .active; progress never exceeds 1.
        // Verify by passing exactly threshold - epsilon still gives progress < 1.
        let state = WebhookForwarder.resolveDeliveryState(
            onlyWhenInactive: true,
            inactivitySeconds: 60,
            idleSeconds: 59.9
        )
        if case let .waitingForInactivity(progress, _) = state {
            XCTAssertLessThanOrEqual(progress, 1.0)
            XCTAssertGreaterThanOrEqual(progress, 0.0)
        } else {
            XCTFail("Expected waitingForInactivity, got \(state)")
        }
    }

    func testResolverZeroThresholdReturnsActive() {
        // Zero inactivitySeconds is degenerate — guard produces .active, never divide-by-zero.
        let state = WebhookForwarder.resolveDeliveryState(
            onlyWhenInactive: true,
            inactivitySeconds: 0,
            idleSeconds: 0
        )
        XCTAssertEqual(state, .active)
    }

    func testCurrentDeliveryStateAlwaysModeReturnsActiveWithoutQueryingIdle() async throws {
        var idleCalled = false
        let monitor = UserPresenceMonitor(idleSecondsProvider: { idleCalled = true; return 0 }, observeSystem: false)
        let forwarder = WebhookForwarder(
            appState: AppState(),
            presenceMonitor: monitor,
            configurationProvider: {
                WebhookForwarder.Configuration(
                    enabled: true,
                    endpoint: URL(string: "https://example.invalid/hook"),
                    eventFilter: [],
                    mainSessionsOnly: false,
                    onlyWhenInactive: false,
                    sendImmediatelyWhenLocked: false,
                    inactivitySeconds: 60
                )
            },
            sender: { _ in }
        )
        let state = await forwarder.currentDeliveryState()
        XCTAssertEqual(state, .active)
        XCTAssertFalse(idleCalled, "Should not query idle time when onlyWhenInactive is false")
    }

    func testCurrentDeliveryStateWaitingWhenUserIsActive() async throws {
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 10 }, observeSystem: false)
        let forwarder = WebhookForwarder(
            appState: AppState(),
            presenceMonitor: monitor,
            configurationProvider: {
                WebhookForwarder.Configuration(
                    enabled: true,
                    endpoint: URL(string: "https://example.invalid/hook"),
                    eventFilter: [],
                    mainSessionsOnly: false,
                    onlyWhenInactive: true,
                    sendImmediatelyWhenLocked: false,
                    inactivitySeconds: 60
                )
            },
            sender: { _ in }
        )
        let state = await forwarder.currentDeliveryState()
        XCTAssertEqual(state, .waitingForInactivity(
            progress: 10.0 / 60.0,
            remainingSeconds: 50
        ))
    }

    func testCurrentDeliveryStateActiveWhenUserExceedsThreshold() async throws {
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 61 }, observeSystem: false)
        let forwarder = WebhookForwarder(
            appState: AppState(),
            presenceMonitor: monitor,
            configurationProvider: {
                WebhookForwarder.Configuration(
                    enabled: true,
                    endpoint: URL(string: "https://example.invalid/hook"),
                    eventFilter: [],
                    mainSessionsOnly: false,
                    onlyWhenInactive: true,
                    sendImmediatelyWhenLocked: false,
                    inactivitySeconds: 60
                )
            },
            sender: { _ in }
        )
        let state = await forwarder.currentDeliveryState()
        XCTAssertEqual(state, .active)
    }

    private func makeForwarder(
        monitor: UserPresenceMonitor,
        sent: LockedRequests,
        enabled: Bool = true,
        onlyWhenInactive: Bool = true,
        sendImmediatelyWhenLocked: Bool = true,
        actionability: @escaping WebhookForwarder.ActionabilityProvider = { _, _ in true }
    ) -> WebhookForwarder {
        WebhookForwarder(
            appState: AppState(),
            presenceMonitor: monitor,
            configurationProvider: {
                WebhookForwarder.Configuration(
                    enabled: enabled,
                    endpoint: URL(string: "https://example.invalid/hook"),
                    eventFilter: [],
                    mainSessionsOnly: false,
                    onlyWhenInactive: onlyWhenInactive,
                    sendImmediatelyWhenLocked: sendImmediatelyWhenLocked,
                    inactivitySeconds: 60
                )
            },
            sender: { request in sent.append(request) },
            pollNanoseconds: 1_000_000,
            actionabilityProvider: actionability
        )
    }

    private func makeEvent(
        name: String,
        sessionId: String,
        toolUseId: String? = nil
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionId,
            "_source": "pi",
        ]
        if let toolUseId {
            payload["tool_use_id"] = toolUseId
        }
        return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        let started = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - started > .nanoseconds(Int64(timeoutNanoseconds)) {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private final class LockedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var count: Int {
        lock.withLock { requests.count }
    }

    func append(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }
}
