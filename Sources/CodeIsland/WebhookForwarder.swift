import Foundation
import CodeIslandCore

@MainActor
final class WebhookForwarder {
    enum AttentionKind: Equatable {
        case permission
        case question
        case completion
        case event
    }

    struct Configuration: Equatable {
        let enabled: Bool
        let endpoint: URL?
        let eventFilter: Set<String>
        let mainSessionsOnly: Bool
        let onlyWhenInactive: Bool
        let sendImmediatelyWhenLocked: Bool
        let inactivitySeconds: TimeInterval
    }
    typealias ActionabilityProvider = (HookEvent, AttentionKind) -> Bool

    typealias ConfigurationProvider = () -> Configuration
    typealias Sender = @Sendable (URLRequest) -> Void

    private struct PendingItem {
        let event: HookEvent
        let kind: AttentionKind
        let sequence: UInt64
        let task: Task<Void, Never>
    }

    private weak var appState: AppState?
    private let presenceMonitor: UserPresenceMonitor
    private let configurationProvider: ConfigurationProvider
    private let sender: Sender
    private let pollNanoseconds: UInt64
    private var pending: [UInt64: PendingItem] = [:]
    private var nextSequence: UInt64 = 0
    private let actionabilityProvider: ActionabilityProvider?
    private var acknowledgedCompletionSequence: [String: UInt64] = [:]

    init(
        appState: AppState,
        presenceMonitor: UserPresenceMonitor? = nil,
        configurationProvider: @escaping ConfigurationProvider = WebhookForwarder.userDefaultsConfiguration,
        sender: @escaping Sender = { request in WebhookForwarder.urlSessionSender(request) },
        pollNanoseconds: UInt64 = 1_000_000_000,
        actionabilityProvider: ActionabilityProvider? = nil
    ) {
        self.appState = appState
        self.presenceMonitor = presenceMonitor ?? UserPresenceMonitor()
        self.configurationProvider = configurationProvider
        self.sender = sender
        self.pollNanoseconds = pollNanoseconds
        self.actionabilityProvider = actionabilityProvider
        self.presenceMonitor.onSessionLocked = { [weak self] in
            self?.flushForLockedSession()
        }
    }

    func submit(_ event: HookEvent, routeKind: HookServer.RouteKind) {
        let configuration = configurationProvider()
        guard Self.shouldForward(event, configuration: configuration) else { return }

        let kind = Self.attentionKind(event: event, routeKind: routeKind)
        if !configuration.onlyWhenInactive
            || (presenceMonitor.isSessionLocked && configuration.sendImmediatelyWhenLocked) {
            send(event, configuration: configuration)
            return
        }

        nextSequence &+= 1
        let sequence = nextSequence
        let task = Task { [weak self] in
            guard let self else { return }
            await self.waitAndSend(sequence: sequence)
        }
        pending[sequence] = PendingItem(event: event, kind: kind, sequence: sequence, task: task)
    }

    func acknowledgeRequest(_ event: HookEvent, kind: AttentionKind) {
        let sessionId = event.sessionId ?? "default"
        let match = pending.values
            .filter {
                $0.kind == kind
                    && ($0.event.sessionId ?? "default") == sessionId
                    && Self.requestIdsMatch($0.event.toolUseId, event.toolUseId)
            }
            .min { $0.sequence < $1.sequence }
        guard let match else { return }
        match.task.cancel()
        pending.removeValue(forKey: match.sequence)
    }

    func acknowledgeCompletion(sessionId: String) {
        let newest = pending.values
            .filter { $0.kind == .completion && ($0.event.sessionId ?? "default") == sessionId }
            .map(\.sequence)
            .max() ?? 0
        acknowledgedCompletionSequence[sessionId] = max(
            acknowledgedCompletionSequence[sessionId] ?? 0,
            newest
        )
        cancelPending { item in
            item.kind == .completion
                && (item.event.sessionId ?? "default") == sessionId
                && item.sequence <= newest
        }
    }

    func acknowledgeSessionActivity(sessionId: String) {
        acknowledgeCompletion(sessionId: sessionId)
    }

    func cancelAll() {
        for item in pending.values {
            item.task.cancel()
        }
        pending.removeAll()
    }

    private func waitAndSend(sequence: UInt64) async {
        defer { pending.removeValue(forKey: sequence) }

        while !Task.isCancelled {
            guard let item = pending[sequence], isStillActionable(item) else { return }
            let configuration = configurationProvider()
            guard Self.shouldForward(item.event, configuration: configuration) else { return }

            if presenceMonitor.isSessionLocked, configuration.sendImmediatelyWhenLocked {
                send(item.event, configuration: configuration)
                return
            }

            let idleSeconds = await presenceMonitor.idleSeconds()
            guard !Task.isCancelled, let current = pending[sequence], isStillActionable(current) else { return }
            if idleSeconds >= configuration.inactivitySeconds {
                send(current.event, configuration: configuration)
                return
            }

            let remaining = max(0.05, configuration.inactivitySeconds - idleSeconds)
            let sleepNanoseconds = min(pollNanoseconds, UInt64(remaining * 1_000_000_000))
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }
    }

    private func flushForLockedSession() {
        let currentConfiguration = configurationProvider()
        guard currentConfiguration.sendImmediatelyWhenLocked else { return }
        let items = pending.values.sorted { $0.sequence < $1.sequence }
        for item in items where isStillActionable(item) {
            let configuration = configurationProvider()
            if Self.shouldForward(item.event, configuration: configuration) {
                send(item.event, configuration: configuration)
            }
            item.task.cancel()
            pending.removeValue(forKey: item.sequence)
        }
    }

    private func isStillActionable(_ item: PendingItem) -> Bool {
        if let actionabilityProvider {
            return actionabilityProvider(item.event, item.kind)
        }
        guard let appState else { return false }
        let sessionId = item.event.sessionId ?? "default"
        switch item.kind {
        case .permission:
            return appState.permissionQueue.contains {
                ($0.event.sessionId ?? "default") == sessionId
                    && Self.requestIdsMatch($0.toolUseId, item.event.toolUseId)
            }
        case .question:
            return appState.questionQueue.contains {
                ($0.event.sessionId ?? "default") == sessionId
                    && Self.requestIdsMatch($0.event.toolUseId, item.event.toolUseId)
            }
        case .completion:
            return item.sequence > (acknowledgedCompletionSequence[sessionId] ?? 0)
        case .event:
            return true
        }
    }

    private func cancelPending(where predicate: (PendingItem) -> Bool) {
        let sequences = pending.values.filter(predicate).map(\.sequence)
        for sequence in sequences {
            pending[sequence]?.task.cancel()
            pending.removeValue(forKey: sequence)
        }
    }

    private func send(_ event: HookEvent, configuration: Configuration) {
        guard let endpoint = configuration.endpoint,
              let request = Self.makeRequest(event: event, endpoint: endpoint) else { return }
        sender(request)
    }

    nonisolated static func attentionKind(
        event: HookEvent,
        routeKind: HookServer.RouteKind
    ) -> AttentionKind {
        if routeKind == .question || event.toolName == "AskUserQuestion" {
            return .question
        }
        if routeKind == .permission {
            return .permission
        }
        switch EventNormalizer.normalize(event.eventName) {
        case "Stop", "AfterAgentResponse", "TaskRoundComplete":
            return .completion
        default:
            return .event
        }
    }

    nonisolated static func shouldForward(
        _ event: HookEvent,
        configuration: Configuration
    ) -> Bool {
        guard configuration.enabled, configuration.endpoint != nil else { return false }
        guard HookServer.webhookScopeAllows(
            event,
            mainSessionsOnly: configuration.mainSessionsOnly
        ) else { return false }
        guard !configuration.eventFilter.isEmpty else { return true }
        let normalized = EventNormalizer.normalize(event.eventName)
        return configuration.eventFilter.contains(normalized)
            || configuration.eventFilter.contains(event.eventName)
    }

    nonisolated static func makeRequest(event: HookEvent, endpoint: URL) -> URLRequest? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let envelope: [String: Any] = [
            "event": EventNormalizer.normalize(event.eventName),
            "raw_event": event.eventName,
            "session_id": event.sessionId ?? "",
            "source": event.rawJSON["_source"] as? String ?? "",
            "cwd": event.rawJSON["cwd"] as? String ?? "",
            "tool_name": event.toolName ?? "",
            "timestamp": formatter.string(from: Date()),
            "raw": event.rawJSON,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodeIsland-Webhook/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return request
    }

    nonisolated static func userDefaultsConfiguration() -> Configuration {
        let defaults = UserDefaults.standard
        let urlString = (defaults.string(forKey: SettingsKey.webhookURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = defaults.string(forKey: SettingsKey.webhookEventFilter) ?? ""
        let eventFilter = Set(filter.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
        return Configuration(
            enabled: defaults.bool(forKey: SettingsKey.webhookEnabled),
            endpoint: URL(string: urlString),
            eventFilter: eventFilter,
            mainSessionsOnly: defaults.bool(forKey: SettingsKey.webhookMainSessionsOnly),
            onlyWhenInactive: defaults.bool(forKey: SettingsKey.webhookOnlyWhenInactive),
            sendImmediatelyWhenLocked: defaults.bool(forKey: SettingsKey.webhookSendImmediatelyWhenLocked),
            inactivitySeconds: TimeInterval(WebhookInactivityDuration.clamp(
                defaults.integer(forKey: SettingsKey.webhookInactivitySeconds)
            ))
        )
    }

    nonisolated static func urlSessionSender(_ request: URLRequest) {
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    nonisolated private static func requestIdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return lhs == rhs
        case (nil, nil): return true
        default: return false
        }
    }

    deinit {
        for item in pending.values {
            item.task.cancel()
        }
    }
}
