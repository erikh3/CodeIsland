import Foundation
import Network
import OSLog
import CodeIslandCore

private let log = Logger(subsystem: "CodeIsland", category: "HerdrSubscription")

/// Subscribes to Herdr's `pane.agent_status_changed` event stream for a single pane.
///
/// Manages two connections internally:
/// - A persistent subscription stream for push events.
/// - A short-lived connection for the initial `agent.get` state sync on each (re)connect.
///
/// All work runs on `@MainActor` matching `NWConnection`'s `.main` queue dispatch.
/// Reconnects automatically with exponential backoff. Call ``cancel()`` to tear down permanently.
@MainActor
final class HerdrSubscription {
    // MARK: - Types

    struct StatusChange {
        let status: AgentStatus?
        /// Human-readable label from state_labels or agent terminal title. nil if unavailable.
        let label: String?
    }

    // MARK: - Init

    private let socketPath: String
    private let paneId: String
    private let onStatusChange: (StatusChange) -> Void

    private var subConnection: NWConnection?
    private var cancelled = false
    private var backoffSeconds: Double = 1

    /// - Parameters:
    ///   - socketPath: Value of `HERDR_SOCKET_PATH` from the `SessionStart` event.
    ///   - paneId: Value of `_herdr_pane_id` from the `SessionStart` event.
    ///   - onStatusChange: Called on `@MainActor` for each status transition.
    ///                     `status == nil` means Herdr reported `unknown` -- caller should no-op.
    init(
        socketPath: String,
        paneId: String,
        onStatusChange: @escaping (StatusChange) -> Void
    ) {
        self.socketPath = socketPath
        self.paneId = paneId
        self.onStatusChange = onStatusChange
        connect()
    }

    /// Permanently tears down the subscription. Safe to call multiple times.
    func cancel() {
        cancelled = true
        subConnection?.cancel()
        subConnection = nil
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard !cancelled else { return }

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        let endpoint = NWEndpoint.unix(path: socketPath)

        let sub = NWConnection(to: endpoint, using: params)
        subConnection = sub

        sub.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                switch state {
                case .ready:
                    self.onSubReady(sub)
                case .failed(let error):
                    log.warning("Herdr sub connection failed: \(error.localizedDescription)")
                    self.scheduleReconnect()
                case .cancelled:
                    self.scheduleReconnect()
                default:
                    break
                }
            }
        }
        sub.start(queue: .main)
    }

    private func onSubReady(_ connection: NWConnection) {
        backoffSeconds = 1

        // Send subscribe request.
        send(data: jsonLine([
            "id": "ci-sub",
            "method": "events.subscribe",
            "params": [
                "subscriptions": [
                    ["type": "pane.agent_status_changed", "pane_id": paneId]
                ]
            ]
        ]), on: connection)

        // Fetch initial state on a separate short-lived connection (socket does not multiplex).
        fetchInitialState()

        // Start reading push events.
        receiveFrames(connection: connection, buffer: Data(), awaitingAck: true)
    }

    private func scheduleReconnect() {
        guard !cancelled else { return }
        let delay = backoffSeconds
        backoffSeconds = min(backoffSeconds * 2, 30)
        log.info("Herdr sub reconnecting in \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.cancelled else { return }
            self.connect()
        }
    }

    // MARK: - Persistent stream reading

    private func receiveFrames(connection: NWConnection, buffer: Data, awaitingAck: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }

                if let error, content == nil {
                    log.warning("Herdr sub receive error: \(error.localizedDescription)")
                    return
                }

                var buf = buffer
                if let content { buf.append(content) }

                var remaining = buf
                while let newlineRange = remaining.firstRange(of: Data([0x0A])) {
                    let lineData = remaining[remaining.startIndex..<newlineRange.lowerBound]
                    remaining = remaining[newlineRange.upperBound...]

                    guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                    if awaitingAck {
                        let resultType = (json["result"] as? [String: Any])?["type"] as? String
                        if resultType == "subscription_started" {
                            self.receiveFrames(connection: connection, buffer: Data(remaining), awaitingAck: false)
                            return
                        } else {
                            log.error("Herdr sub unexpected ack: \(json)")
                            self.cancel()
                            return
                        }
                    } else {
                        self.handlePushEvent(json)
                    }
                }

                if isComplete { return }
                self.receiveFrames(connection: connection, buffer: Data(remaining), awaitingAck: awaitingAck)
            }
        }
    }

    private func handlePushEvent(_ json: [String: Any]) {
        guard (json["event"] as? String) == "pane.agent_status_changed",
              let data = json["data"] as? [String: Any],
              let agentStatus = data["agent_status"] as? String
        else { return }

        let stateLabels = data["state_labels"] as? [String: String]
        let change = buildChange(agentStatus: agentStatus, stateLabels: stateLabels, title: nil)
        onStatusChange(change)
    }

    // MARK: - Initial state fetch (separate connection)

    private func fetchInitialState() {
        guard !cancelled else { return }

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        let endpoint = NWEndpoint.unix(path: socketPath)
        let conn = NWConnection(to: endpoint, using: params)

        conn.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                self.send(data: self.jsonLine([
                    "id": "ci-init",
                    "method": "agent.get",
                    "params": ["target": self.paneId]
                ]), on: conn)
                self.receiveInitResponse(connection: conn, buffer: Data())
            }
        }
        conn.start(queue: .main)
    }

    private func receiveInitResponse(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self else { return }

                var buf = buffer
                if let content { buf.append(content) }

                if let newlineRange = buf.firstRange(of: Data([0x0A])) {
                    let lineData = buf[buf.startIndex..<newlineRange.lowerBound]
                    if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                       let agent = (json["result"] as? [String: Any])?["agent"] as? [String: Any],
                       let agentStatus = agent["agent_status"] as? String {
                        let stateLabels = agent["state_labels"] as? [String: String]
                        let title = agent["terminal_title_stripped"] as? String
                        let change = self.buildChange(agentStatus: agentStatus, stateLabels: stateLabels, title: title)
                        self.onStatusChange(change)
                    }
                    connection.cancel()
                    return
                }

                if isComplete {
                    connection.cancel()
                    return
                }
                self.receiveInitResponse(connection: connection, buffer: buf)
            }
        }
    }

    // MARK: - Helpers

    private func buildChange(agentStatus: String, stateLabels: [String: String]?, title: String?) -> StatusChange {
        let status: AgentStatus? = switch agentStatus {
        case "blocked": .waitingApproval
        case "working": .running
        case "idle", "done": .idle
        default: nil
        }

        var label: String? = nil
        if let labels = stateLabels, !labels.isEmpty {
            label = labels.values.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        if (label == nil || label!.isEmpty), let title {
            // Strip leading process indicator (e.g. "π ⠹ " or "π ! ") from terminal title.
            let stripped = title
                .replacingOccurrences(of: #"^π\s+\S+\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            label = stripped.isEmpty ? nil : stripped
        }

        return StatusChange(status: status, label: label)
    }

    private func jsonLine(_ object: Any) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    private func send(data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                log.warning("Herdr send error: \(error.localizedDescription)")
            }
        })
    }
}
