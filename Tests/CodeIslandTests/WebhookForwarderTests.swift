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

    // MARK: - Stale / cross-talk edges

    func testStaleConfigAtSendTimeDropsDelivery() async throws {
        // Submit while config has a valid endpoint, then remove the endpoint before
        // the inactivity threshold is reached. waitAndSend re-checks shouldForward
        // at send time; with no endpoint the item must be silently dropped.
        var endpointEnabled = true
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = WebhookForwarder(
            appState: AppState(),
            presenceMonitor: monitor,
            configurationProvider: {
                WebhookForwarder.Configuration(
                    enabled: endpointEnabled,
                    endpoint: endpointEnabled ? URL(string: "https://example.invalid/hook") : nil,
                    eventFilter: [],
                    mainSessionsOnly: false,
                    onlyWhenInactive: true,
                    sendImmediatelyWhenLocked: false,
                    inactivitySeconds: 60
                )
            },
            sender: { request in sent.append(request) },
            pollNanoseconds: 1_000_000,
            actionabilityProvider: { _, _ in true }
        )
        let event = try makeEvent(name: "Stop", sessionId: "session")
        forwarder.submit(event, routeKind: .event)
        // Disable endpoint before the task gets a chance to fire.
        endpointEnabled = false
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(sent.count, 0)
    }

    func testCompletionAckDoesNotCrossSessionBoundary() async throws {
        // Two sessions each have a pending completion. Acknowledging sessionA must not
        // cancel sessionB's item — sessionB still delivers when user becomes inactive.
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(monitor: monitor, sent: sent)
        let eventA = try makeEvent(name: "Stop", sessionId: "sessionA")
        let eventB = try makeEvent(name: "Stop", sessionId: "sessionB")

        forwarder.submit(eventA, routeKind: .event)
        forwarder.submit(eventB, routeKind: .event)
        // Cancel sessionA's pending item via acknowledgement.
        forwarder.acknowledgeCompletion(sessionId: "sessionA")
        // sessionB must still be pending; inject activity so it never fires on its own.
        // Confirm by flushing via lock.
        monitor.setSessionLockedForTesting(true)
        try await waitUntil { sent.count == 1 }
        XCTAssertEqual(sent.count, 1)
    }

    func testRequestAckNilToolIdDoesNotCancelDifferentKind() async throws {
        // Two pending items: a permission and a completion, both with nil toolUseId, same session.
        // Acknowledging the permission (by kind) must leave the completion pending.
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(monitor: monitor, sent: sent, sendImmediatelyWhenLocked: true)
        let permEvent = try makeEvent(name: "PermissionRequest", sessionId: "session")
        let stopEvent = try makeEvent(name: "Stop", sessionId: "session")

        forwarder.submit(permEvent, routeKind: .permission)
        forwarder.submit(stopEvent, routeKind: .event)
        // Acknowledge the permission request — must only cancel the permission item.
        let ackEvent = try makeEvent(name: "PermissionRequest", sessionId: "session")
        forwarder.acknowledgeRequest(ackEvent, kind: .permission)
        // Completion item still pending; lock to flush it.
        monitor.setSessionLockedForTesting(true)
        try await waitUntil { sent.count == 1 }
        XCTAssertEqual(sent.count, 1)
    }

    func testStaleActionabilityPreventsSendWhenItemBecomesInactive() async throws {
        // Submit a completion item; actionability returns false on the first poll
        // (simulating the item having been resolved before the threshold). Must not send.
        var actionable = true
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
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
            sender: { request in sent.append(request) },
            pollNanoseconds: 1_000_000,
            actionabilityProvider: { _, _ in actionable }
        )
        let event = try makeEvent(name: "Stop", sessionId: "session")
        forwarder.submit(event, routeKind: .event)
        // Mark stale immediately.
        actionable = false
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(sent.count, 0)
    }

    func testAckForAgentBDoesNotCancelAgentANilToolId() async throws {
        // Regression: same session, same kind (.question), nil toolUseId, different agentId.
        // Two pending items: AgentA (seq 1), AgentB (seq 2).
        // Acknowledging AgentB must cancel only AgentB; AgentA must still fire and
        // the delivered payload must carry AgentA's agent_id, not AgentB's.
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(monitor: monitor, sent: sent, sendImmediatelyWhenLocked: true)

        let eventA = try makeEvent(name: "AskUserQuestion", sessionId: "main", agentId: "AgentA")
        let eventB = try makeEvent(name: "AskUserQuestion", sessionId: "main", agentId: "AgentB")
        forwarder.submit(eventA, routeKind: .question)
        forwarder.submit(eventB, routeKind: .question)

        // Acknowledge only AgentB's question.
        let ackB = try makeEvent(name: "AskUserQuestion", sessionId: "main", agentId: "AgentB")
        forwarder.acknowledgeRequest(ackB, kind: .question)

        // AgentA's item must survive — flush via lock.
        monitor.setSessionLockedForTesting(true)
        try await waitUntil { sent.count == 1 }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.rawFields("agent_id"), ["AgentA"],
            "Only AgentA's event should have been delivered; AgentB was acknowledged")
    }

    func testAckForAgentBExplicitToolIdDoesNotCancelAgentA() async throws {
        // Regression: same session, same kind (.question), same explicit toolUseId "t1",
        // different agentId. Two distinct subagents happen to emit the same tool call id.
        // Acknowledging AgentB must not cancel AgentA.
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(monitor: monitor, sent: sent, sendImmediatelyWhenLocked: true)

        let eventA = try makeEvent(name: "AskUserQuestion", sessionId: "main",
                                   toolUseId: "t1", agentId: "AgentA")
        let eventB = try makeEvent(name: "AskUserQuestion", sessionId: "main",
                                   toolUseId: "t1", agentId: "AgentB")
        forwarder.submit(eventA, routeKind: .question)
        forwarder.submit(eventB, routeKind: .question)

        // Acknowledge AgentB's item.
        let ackB = try makeEvent(name: "AskUserQuestion", sessionId: "main",
                                 toolUseId: "t1", agentId: "AgentB")
        forwarder.acknowledgeRequest(ackB, kind: .question)

        // AgentA must survive — flush via lock.
        monitor.setSessionLockedForTesting(true)
        try await waitUntil { sent.count == 1 }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.rawFields("agent_id"), ["AgentA"],
            "Only AgentA's event should have been delivered; AgentB was acknowledged")
    }

    func testRootAckDoesNotCancelChildAndChildAckDoesNotCancelRoot() async throws {
        // Regression: same canonical root session, nil toolUseId.
        // Root question (agentId==nil, seq 1) and child question (agentId=="Scout", seq 2).
        // Acknowledging root cancels only root — child must survive and deliver its payload.
        // Acknowledging child in a second forwarder cancels only child — root survives.
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = makeForwarder(monitor: monitor, sent: sent, sendImmediatelyWhenLocked: true)

        // Root: no agentId; Child: agentId="Scout".
        let rootEvent = try makeEvent(name: "AskUserQuestion", sessionId: "main")
        let childEvent = try makeEvent(name: "AskUserQuestion", sessionId: "main", agentId: "Scout")
        forwarder.submit(rootEvent, routeKind: .question)
        forwarder.submit(childEvent, routeKind: .question)

        // Acknowledge the root (nil agentId). Must not touch child's item.
        let ackRoot = try makeEvent(name: "AskUserQuestion", sessionId: "main")
        forwarder.acknowledgeRequest(ackRoot, kind: .question)

        // Child must survive — flush via lock.
        monitor.setSessionLockedForTesting(true)
        try await waitUntil { sent.count == 1 }
        XCTAssertEqual(sent.count, 1)
        // Delivered payload must be the child's — it carries agent_id "Scout".
        XCTAssertEqual(sent.rawFields("agent_id"), ["Scout"],
            "Root ack must not cancel child; child event should be the one delivered")

        // Second forwarder: same setup in reverse — acknowledging child must not cancel root.
        let monitor2 = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent2 = LockedRequests()
        let forwarder2 = makeForwarder(monitor: monitor2, sent: sent2, sendImmediatelyWhenLocked: true)
        forwarder2.submit(rootEvent, routeKind: .question)
        forwarder2.submit(childEvent, routeKind: .question)

        let ackChild = try makeEvent(name: "AskUserQuestion", sessionId: "main", agentId: "Scout")
        forwarder2.acknowledgeRequest(ackChild, kind: .question)

        monitor2.setSessionLockedForTesting(true)
        try await waitUntil { sent2.count == 1 }
        XCTAssertEqual(sent2.count, 1)
        // Delivered payload must be root's — it has nil agent_id in raw JSON.
        XCTAssertEqual(sent2.rawFields("agent_id"), [nil],
            "Child ack must not cancel root; root event (nil agent_id) should be delivered")
    }

    // MARK: - Regression: inactivity gate toggle

    func testToggleInactivityGateOffWhilePendingDeliversImmediately() async throws {
        // Regression: submit while onlyWhenInactive=true; toggle to false before idle
        // threshold; item must be delivered promptly without waiting for idle.
        var onlyWhenInactive = true
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = WebhookForwarder(
            appState: AppState(),
            presenceMonitor: monitor,
            configurationProvider: {
                WebhookForwarder.Configuration(
                    enabled: true,
                    endpoint: URL(string: "https://example.invalid/hook"),
                    eventFilter: [],
                    mainSessionsOnly: false,
                    onlyWhenInactive: onlyWhenInactive,
                    sendImmediatelyWhenLocked: false,
                    inactivitySeconds: 60
                )
            },
            sender: { request in sent.append(request) },
            pollNanoseconds: 1_000_000,
            actionabilityProvider: { _, _ in true }
        )
        let event = try makeEvent(name: "Stop", sessionId: "session")
        forwarder.submit(event, routeKind: .event)
        // Disable inactivity gate before idle threshold reached.
        onlyWhenInactive = false
        try await waitUntil { sent.count == 1 }
        XCTAssertEqual(sent.count, 1, "Toggling onlyWhenInactive off must cause pending item to deliver promptly")
    }

    // MARK: - Regression: disabled currentDeliveryState

    func testCurrentDeliveryStateDisabledWhenConfigDisabled() async throws {
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 10 }, observeSystem: false)
        let forwarder = WebhookForwarder(
            appState: AppState(),
            presenceMonitor: monitor,
            configurationProvider: {
                WebhookForwarder.Configuration(
                    enabled: false,
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
        XCTAssertEqual(state, .disabled,
            "currentDeliveryState must return .disabled when configuration.enabled is false")
    }

    // MARK: - Regression: stale completion after session removed

    func testCompletionDoesNotDeliverAfterSessionRemoved() async throws {
        // Regression: a pending completion must not fire after the session is removed
        // from AppState (e.g. SessionEnd). Uses real AppState path (no actionabilityProvider).
        let appState = AppState()
        let monitor = UserPresenceMonitor(idleSecondsProvider: { 0 }, observeSystem: false)
        let sent = LockedRequests()
        let forwarder = WebhookForwarder(
            appState: appState,
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
            sender: { request in sent.append(request) },
            pollNanoseconds: 1_000_000
            // No actionabilityProvider: uses real AppState path.
        )
        // Inject a session so actionability starts as true (session exists, not acked).
        var snapshot = SessionSnapshot(startTime: Date())
        snapshot.source = "test"
        appState.sessions["session"] = snapshot

        let event = try makeEvent(name: "Stop", sessionId: "session")
        forwarder.submit(event, routeKind: .event)
        // Remove session before idle threshold — simulates SessionEnd.
        appState.sessions.removeValue(forKey: "session")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(sent.count, 0, "Completion must not deliver after session is removed from AppState")
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
        toolUseId: String? = nil,
        agentId: String? = nil
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionId,
            "_source": "pi",
        ]
        if let toolUseId {
            payload["tool_use_id"] = toolUseId
        }
        if let agentId {
            payload["agent_id"] = agentId
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

    /// Decodes the `session_id` field from each sent request envelope body.
    var sessionIds: [String] {
        lock.withLock {
            requests.compactMap { req in
                guard let body = req.httpBody,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                else { return nil }
                return json["session_id"] as? String
            }
        }
    }

    /// Extracts `raw[field]` from each sent envelope body.
    func rawFields(_ field: String) -> [String?] {
        lock.withLock {
            requests.map { req in
                guard let body = req.httpBody,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let raw = json["raw"] as? [String: Any]
                else { return nil }
                return raw[field] as? String
            }
        }
    }
}
