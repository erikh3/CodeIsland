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
