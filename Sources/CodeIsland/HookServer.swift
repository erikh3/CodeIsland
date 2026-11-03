import Foundation
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "HookServer")

@MainActor
class HookServer {
    enum RouteKind: Equatable {
        case permission
        case question
        case event
    }

    private let appState: AppState
    /// Where hooks connect (``SocketPath``).
    nonisolated static var socketPath: String { SocketPath.path }
    /// Where this server listens: ``socketPath``, a remote host's own socket
    /// (``RemoteHookSockets``), or a test's.
    let socketPath: String
    /// Which machine the requests on this socket come from: this Mac, or the
    /// remote host the socket was bound for (``HookOrigin``). Read on the
    /// connection queue; the host's name may change while it is connected.
    private let originBox: OriginBox
    /// The cwd allow-list (#240) of a remote host, by id.
    private let hostCwdFilter: @MainActor (String) -> String?
    /// The tools a test approves without a card; nil reads the user's settings.
    private let pinnedAutoApproveTools: Set<String>?
    /// How often a held request's hook is checked for being gone: a backstop
    /// to its watch, which sees that at once (``monitorPeerDisconnect``).
    private let heldRequestCheckInterval: TimeInterval
    /// How much of the island this socket's hooks may take: as much as they
    /// like on this Mac's, a bounded share on a remote host's.
    let limits: HookSocketLimits
    private var listener: HookSocketListener?
    /// Hook connections are accepted and read here, off the main thread; only
    /// a complete request is handed to the main actor (``HookSocketListener``).
    private let connectionQueue = DispatchQueue(label: "com.codeisland.hook-server", qos: .userInitiated)
    /// OMP nested-process ancestry lookup; injected for testability.
    private let parentPidLookup: (pid_t) -> pid_t?

    /// `origin` is the machine whose hooks reach `socketPath`: this Mac's
    /// main socket, or a remote host's own (``RemoteHookSockets``).
    /// `hostCwdFilter` gives a remote host's cwd allow-list; by default the
    /// one in Settings.
    ///
    /// `limits` are those of `origin`'s socket unless given
    /// (``HookSocketLimits/for(_:)``).
    ///
    /// `socketPath`, `autoApproveTools`, `heldRequestCheckInterval`,
    /// `limits` and `parentPidLookup` are for tests: a socket of their own,
    /// the tools approved without a card, not read from the settings, a
    /// shorter backstop and smaller limits, and a controlled process-tree.
    init(
        appState: AppState,
        socketPath: String = HookServer.socketPath,
        origin: HookOrigin = .local,
        hostCwdFilter: @escaping @MainActor (String) -> String? = { id in
            RemoteManager.shared.hosts.first(where: { $0.id == id })?.cwdFilter
        },
        autoApproveTools: Set<String>? = nil,
        heldRequestCheckInterval: TimeInterval = 300,
        limits: HookSocketLimits? = nil,
        parentPidLookup: @escaping (pid_t) -> pid_t? = ProcessTable.parentPid(of:)
    ) {
        self.appState = appState
        self.socketPath = socketPath
        self.originBox = OriginBox(origin)
        self.hostCwdFilter = hostCwdFilter
        self.pinnedAutoApproveTools = autoApproveTools
        self.heldRequestCheckInterval = heldRequestCheckInterval
        self.limits = limits ?? .for(origin)
        self.parentPidLookup = parentPidLookup
        appState.webhookForwarder = appState.webhookForwarder ?? WebhookForwarder(appState: appState)
    }

    /// Which machine this socket's requests come from.
    var origin: HookOrigin { originBox.value }

    /// The remote host this socket is for was renamed: its requests carry
    /// the new name from now on. Nothing changes on this Mac's socket.
    func renameHost(to name: String) {
        guard case .remoteHost(let id, _) = originBox.value else { return }
        originBox.set(.remoteHost(id: id, name: name))
    }

    /// Starts listening. False, logged, when the socket cannot be created.
    @discardableResult
    func start() -> Bool {
        let limits = limits
        let originBox = originBox
        let path = socketPath
        // Shared by this socket's connections, on its queue.
        let budget = limits.maxBufferedBytes.map(HookReadBudget.init(limit:))
        let listener = HookSocketListener(
            path: socketPath,
            queue: connectionQueue,
            maxConnections: limits.maxConnections
        ) { [weak self] connection in
            connection.readRequest(
                limit: limits.maxRequestBytes,
                idleTimeout: limits.readIdleTimeout,
                deadline: limits.readDeadline,
                budget: budget
            ) { request in
                switch request {
                case .failed, .stalled:
                    connection.cancel()
                case .overBudget:
                    log.warning("HookServer: \(path, privacy: .public) already holds \(limits.maxBufferedBytes ?? 0) bytes of unfinished requests; dropping a connection")
                    connection.cancel()
                case .tooLarge:
                    log.warning("Payload too large (over \(limits.maxRequestBytes) bytes), dropping connection")
                    // Nobody read it, so nobody decides: a large file an
                    // agent writes is not refused, its agent asks in its own
                    // way (it used to be told "deny" on this Mac's socket).
                    connection.respond(Data())
                case .received(let data):
                    // The socket names the host, and an edge's facts are
                    // parsed and interpreted, here too, off the main thread.
                    let intake = Self.intake(data, origin: originBox.value)
                    if case .answerNothing = intake {
                        connection.respond(Data())
                        return
                    }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.processRequest(intake, connection: connection)
                        }
                    }
                }
            }
        }
        guard listener.start() else { return false }
        self.listener = listener
        log.info("HookServer listening on \(self.socketPath)")
        return true
    }

    func stop() {
        let listener = listener
        listener?.stop()
        self.listener = nil
        guard case .local = origin else {
            // A host's socket goes at once, and only the file this server
            // made: the host's forward is gone, and the host may connect
            // again and bind this path a moment later — a late removal
            // would take that socket away.
            listener?.removeSocketFile()
            return
        }
        // Delay socket removal so in-flight hooks can finish sending their payload
        // before the file disappears — prevents intermittent errors on session end (#45).
        let path = socketPath
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            unlink(path)
        }
    }


    /// Internal tools that are safe to auto-approve without user confirmation.
    /// Read from user settings; defaults to all known internal tools.
    private var autoApproveTools: Set<String> {
        pinnedAutoApproveTools ?? SettingsManager.shared.autoApproveTools
    }

    /// Whether this event's agent is on the user's always-proceed list (#283).
    /// Matched on both the raw `_source` and its normalized form so "agy",
    /// "google-antigravity" and "antigravity-cli" all resolve to one entry.
    static func isAutoApprovedSource(_ event: HookEvent) -> Bool {
        isAutoApprovedSource(event, approved: SettingsManager.shared.autoApproveSources)
    }

    nonisolated static func isAutoApprovedSource(
        _ event: HookEvent,
        approved: Set<String>
    ) -> Bool {
        guard !approved.isEmpty,
              let raw = event.rawJSON["_source"] as? String else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if approved.contains(trimmed) { return true }
        guard let normalized = SessionSnapshot.normalizedSupportedSource(trimmed) else { return false }
        return approved.contains(normalized)
    }

    /// User-configured cwd substring blocklist for plugin/background hooks (e.g. claude-mem).
    /// Empty default = no filtering. Trimmed, blank entries skipped.
    private static func eventMatchesExcludedCwd(_ cwd: String) -> Bool {
        cwdMatchesAnyPattern(cwd, patternsCSV: SettingsManager.shared.excludedHookCwdSubstrings)
    }

    /// Pure substring blocklist match — returns true if `cwd` contains any
    /// non-empty trimmed entry of `patternsCSV`. Extracted for testability;
    /// `nonisolated` because it touches no actor state.
    nonisolated static func cwdMatchesAnyPattern(_ cwd: String, patternsCSV: String) -> Bool {
        guard !patternsCSV.isEmpty else { return false }
        for entry in patternsCSV.split(separator: ",", omittingEmptySubsequences: false) {
            let pattern = entry.trimmingCharacters(in: .whitespaces)
            if !pattern.isEmpty, cwd.contains(pattern) { return true }
        }
        return false
    }

    /// Per-host cwd ALLOW-list for remote sessions (#240) — on shared remote
    /// accounts, users can scope the panel to their own project directories.
    /// Empty filter = allow everything (previous behavior). With a filter set,
    /// events must carry a cwd containing one of the entries; events without a
    /// cwd are dropped too — on a shared account they can't be attributed.
    nonisolated static func remoteEventPassesCwdFilter(
        cwd: String?,
        workspaceRoots: [String]? = nil,
        filterCSV: String
    ) -> Bool {
        let hasPattern = filterCSV
            .split(separator: ",", omittingEmptySubsequences: false)
            .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard hasPattern else { return true }
        if let cwd, !cwd.isEmpty, cwdMatchesAnyPattern(cwd, patternsCSV: filterCSV) {
            return true
        }
        if let roots = workspaceRoots {
            for root in roots where !root.isEmpty {
                if cwdMatchesAnyPattern(root, patternsCSV: filterCSV) {
                    return true
                }
            }
        }
        // No cwd or workspace root matched — on a shared account they can't be attributed.
        return false
    }

    /// Remote cwd allow-lists drop hooks from other users' directories on shared
    /// SSH accounts (#240). Lifecycle and blocking hooks for sessions we already
    /// track must still flow through — otherwise SessionEnd/Stop never tears
    /// sessions down and PermissionRequest/Notification stall the remote agent.
    nonisolated static func remoteEventBypassesCwdFilter(
        eventName: String,
        sessionId: String?,
        trackedSessionIds: Set<String>
    ) -> Bool {
        guard let sessionId, trackedSessionIds.contains(sessionId) else { return false }
        switch EventNormalizer.normalize(eventName) {
        case "SessionEnd", "Stop", "SubagentStop", "PermissionRequest", "Notification", "AfterAgentResponse":
            return true
        default:
            return false
        }
    }

    /// The cwd filter of the remote host whose socket this is: the socket
    /// names the host, not the payload. Nil on this Mac's socket, or once
    /// the host is no longer configured.
    private var remoteCwdFilter: String? {
        guard case .remoteHost(let hostId, _) = origin else { return nil }
        return hostCwdFilter(hostId)
    }

    nonisolated internal static func isSubsessionEvent(_ event: HookEvent) -> Bool {
        let raw = event.rawJSON
        if event.agentId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if (raw["_omp_subagent"] as? Bool) == true
            || (raw["_cursor_subagent"] as? Bool) == true
            || (raw["_codex_subagent"] as? Bool) == true
            || (raw["_via_plugin"] as? Bool) == true {
            return true
        }
        switch EventNormalizer.normalize(event.eventName) {
        case "SubagentStart", "SubagentStop":
            return true
        default:
            break
        }
        let declared = (raw["_source"] as? String) ?? (raw["source"] as? String)
        let path = SubsessionRouter.transcriptPath(in: raw)
        if CursorSubsessionRouter.shouldTreatAsCursorFamily(declaredSource: declared, transcriptPath: path),
           let childSessionId = SubsessionRouter.sessionId(in: raw),
           CursorSessionFolding.foldTarget(childSessionId: childSessionId, transcriptPath: path) != nil {
            return true
        }
        return Self.codexSubagentMetadata(from: raw) != nil
    }

    nonisolated internal static func webhookScopeAllows(
        _ event: HookEvent,
        mainSessionsOnly: Bool
    ) -> Bool {
        !mainSessionsOnly || !isSubsessionEvent(event)
    }

    nonisolated static func routeKind(for event: HookEvent) -> RouteKind {
        let normalizedEventName = EventNormalizer.normalize(event.eventName)
        // Google Antigravity's PreToolUse stays a plain activity event. Its hook
        // cannot approve a call (an `allow` is ignored and Antigravity prompts
        // anyway), so an island card in front of it only doubled every approval
        // and left a card behind when the user answered in Antigravity. The
        // bridge has already told Antigravity to decide for itself (#339).
        if normalizedEventName == "PermissionRequest" {
            return .permission
        }
        if normalizedEventName == "Notification", QuestionPayload.from(event: event) != nil {
            return .question
        }
        return .event
    }

    nonisolated static func shouldDeferPermissionRequestToProvider(_ event: HookEvent) -> Bool {
        guard EventNormalizer.normalize(event.eventName) == "PermissionRequest",
              event.toolName != "AskUserQuestion" else {
            return false
        }
        return CodexPermissionRules.shouldDeferToCodexAutoReview(for: event)
    }

    private static let pluginMarkerBytes = Data("_via_plugin".utf8)
    private static let declaredParentMarkerBytes = Data(DeclaredSubsession.parentKey.utf8)
    private static let sourceMarkerBytes = Data(#""_source""#.utf8)
    private static let codexMarkerBytes = Data("codex".utf8)
    private static let cursorTranscriptMarkerBytes = Data("agent-transcripts".utf8)
    private static let cursorSourceExactBytes = Data(#""_source":"cursor""#.utf8)
    private static let cursorCliSourceExactBytes = Data(#""_source":"cursor-cli""#.utf8)
    private static let ppidKeyBytes = Data(#""_ppid""#.utf8)
    private static let ompSubagentMarkerBytes = Data(#""_omp_subagent""#.utf8)
    private static let ompSourceExactBytes = Data(#""_source":"pi""#.utf8)
    /// JSON `\uXXXX` escape — only then do we fall back to a full parse.
    private static let jsonUnicodeEscapeBytes = Data(#"\u"#.utf8)
    private static let cursorSourceFlexibleRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #""_source"\s*:\s*"(cursor-cli|cursor)""#,
            options: []
        )
    }()

    /// Whether Cursor Task routing may need a JSON parse (transcript fold path).
    ///
    /// Requires `agent-transcripts` plus either a Cursor `_source` or a path under
    /// `/.cursor/` (misbranded Claude-default Task hooks still fold).
    internal static func mayNeedCursorSubsessionRouting(data: Data) -> Bool {
        guard data.range(of: cursorTranscriptMarkerBytes) != nil else { return false }
        if mayBeCursorHookSource(data: data) { return true }
        return data.range(of: Data("/.cursor/".utf8)) != nil
    }

    /// `_source` is `cursor` / `cursor-cli` (compact, spaced, or `\u`-escaped).
    /// Used for merge/hide `_ppid` fallback when `agent-transcripts` is absent.
    internal static func mayBeCursorHookSource(data: Data) -> Bool {
        // Compact forms first — bridge JSONSerialization emits no spaces after `:`.
        if data.range(of: cursorCliSourceExactBytes) != nil
            || data.range(of: cursorSourceExactBytes) != nil {
            return true
        }
        guard data.range(of: sourceMarkerBytes) != nil else { return false }
        if let text = String(data: data, encoding: .utf8) {
            let range = NSRange(text.startIndex..., in: text)
            if cursorSourceFlexibleRegex.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        guard data.range(of: jsonUnicodeEscapeBytes) != nil,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = obj["_source"] as? String else {
            return false
        }
        return CursorSubsessionRouter.isCursorFamilySource(source)
    }

    /// Whether a hook may be a child session's, worth a JSON parse for Agent
    /// Sub-Sessions. Cheap byte probes first; avoid JSONSerialization on every
    /// PostToolUse.
    internal static func mayNeedSubsessionRouting(data: Data, mode: SubsessionMode) -> Bool {
        // A child that names its parent (#378), a plugin proxy (#123) or a
        // Codex thread: in every mode. Show separately keeps such a child on a
        // quiet card of its own, and a child folded before Agent Sub-Sessions
        // changed must still end where it started.
        if data.range(of: declaredParentMarkerBytes) != nil
            || data.range(of: pluginMarkerBytes) != nil
            || (data.range(of: sourceMarkerBytes) != nil && data.range(of: codexMarkerBytes) != nil) {
            return true
        }
        // A Cursor Task whose transcript path names its chat, in every mode.
        if mayNeedCursorSubsessionRouting(data: data) { return true }
        // One without: Merge and Hide fall back to its IDE process (`_ppid`).
        // Show separately does not act on that guess, so it needs no parse.
        return mode != .separate
            && mayBeCursorHookSource(data: data)
            && data.range(of: ppidKeyBytes) != nil
    }

    /// Serialize `rewritten` to JSON; return `fallback` on failure.
    private static func serializeOrFallback(_ rewritten: [String: Any], fallback: Data) -> Data {
        (try? JSONSerialization.data(withJSONObject: rewritten)) ?? fallback
    }

    // MARK: - Payload helpers

    nonisolated private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func rawSessionId(from raw: [String: Any]) -> String? {
        SubsessionRouter.sessionId(in: raw)
    }

    private static func pluginPpid(from raw: [String: Any]) -> Int? {
        SubsessionRouter.positivePpid(in: raw)
    }

    /// Hidden requests return no decision so their agent remains responsible for asking.
    private static func hiddenPluginResponse(for raw: [String: Any]) -> Data {
        Data("{}".utf8)
    }

    nonisolated private static func codexSubagentMetadata(from raw: [String: Any]) -> CodexSubagentMetadata? {
        guard let path = nonEmptyString(raw["transcript_path"]) else { return nil }
        return CodexDiscovery.codexSubagentMetadata(inTranscriptPath: path)
    }


    // MARK: - OMP subagent routing

    /// Decision produced by ``decideOmpSubagent(raw:)``.
    enum OmpSubagentDecision {
        /// Payload is a valid OMP child; apply the chosen mode.
        case route(childSessionId: String, parentSessionId: String, agentId: String, agentType: String)
        /// Already routed — `_omp_subagent` + `agent_id` + `_omp_child_session_id`
        /// but no `_omp_parent_session_id`. Leave unchanged.
        case alreadyMerged
        /// Not an OMP child event, or invalid/partial metadata. Pass through.
        case passThrough
    }

    /// Cheap structural check: true when raw bytes contain `"_omp_subagent"`.
    internal static func mayBeOmpSubagent(data: Data) -> Bool {
        data.range(of: ompSubagentMarkerBytes) != nil
    }

    /// Parse and validate OMP routing metadata from an already-deserialized payload.
    ///
    /// Returns `.route` when all required fields are present and valid.
    /// Returns `.alreadyMerged` for a payload that has already been routed.
    /// Returns `.passThrough` for anything else (including malformed/partial metadata).
    internal static func decideOmpSubagent(raw: [String: Any]) -> OmpSubagentDecision {
        // Must have _omp_subagent: true
        guard (raw["_omp_subagent"] as? Bool) == true else { return .passThrough }

        // Already-merged: has agent_id and _omp_child_session_id but no parent pointer.
        if Self.nonEmptyString(raw["agent_id"]) != nil,
           Self.nonEmptyString(raw["_omp_child_session_id"]) != nil,
           raw["_omp_parent_session_id"] == nil {
            return .alreadyMerged
        }

        // All routing fields must be present and non-empty.
        guard let childSessionId = Self.rawSessionId(from: raw),
              let parentSessionId = Self.nonEmptyString(raw["_omp_parent_session_id"]),
              let agentId = Self.nonEmptyString(raw["_omp_agent_id"]),
              let agentType = Self.nonEmptyString(raw["_omp_agent_type"]) else {
            return .passThrough
        }
        // Child and parent must be distinct.
        guard childSessionId != parentSessionId else { return .passThrough }

        return .route(
            childSessionId: childSessionId,
            parentSessionId: parentSessionId,
            agentId: agentId,
            agentType: agentType
        )
    }

    /// Apply OMP-specific routing when ``decideOmpSubagent(raw:)`` returns `.route`.
    ///
    /// - `separate`: return `(data, nil)` — child session ID and title are unchanged.
    /// - `merge`:    rewrite `session_id` to the resolved root key, set `agent_id`,
    ///               `agent_type`, and `_omp_child_session_id`; remove the three
    ///               routing-only fields `_omp_parent_session_id`, `_omp_agent_id`,
    ///               and `_omp_agent_type`. Falls back to original `data` on
    ///               serialization failure.
    /// - `hide`:     return `(data, hiddenPluginResponse)`.
    private func applyOmpRouting(
        data: Data,
        raw: [String: Any],
        childSessionId: String,
        parentSessionId: String,
        agentId: String,
        agentType: String,
        mode: SubsessionMode
    ) -> RoutedHook {
        switch mode {
        case .hide:
            return RoutedHook(data: data, json: raw, response: Self.hiddenPluginResponse(for: raw))
        case .merge:
            let resolvedParent = appState.findSessionId(providerSessionId: parentSessionId)
                ?? parentSessionId
            var rewritten = raw
            rewritten["session_id"] = resolvedParent
            rewritten["agent_id"] = agentId
            rewritten["agent_type"] = agentType
            rewritten["_omp_child_session_id"] = childSessionId
            rewritten.removeValue(forKey: "_omp_parent_session_id")
            rewritten.removeValue(forKey: DeclaredSubsession.parentKey)
            rewritten.removeValue(forKey: "_omp_agent_id")
            rewritten.removeValue(forKey: "_omp_agent_type")
            return RoutedHook(data: data, json: rewritten, rewritten: true)
        default:
            // .separate or unknown — leave session ID and title as-is.
            return RoutedHook(data: data, json: raw, rewritten: true)
        }
    }

    /// OMP supervised processes inherit their launching session's process
    /// ancestry but run a fresh OMP session. Treat a nested OMP process like a
    /// child session so Agent Sub-Sessions settings still apply.
    private func routeNestedOmpProcessIfNeeded(
        data: Data,
        raw: [String: Any],
        mode: SubsessionMode
    ) -> RoutedHook? {
        guard case .local = origin,
              (raw["_omp_subagent"] as? Bool) != true,
              SessionSnapshot.normalizedSupportedSource(raw["_source"] as? String) == "pi",
              let childSessionId = Self.rawSessionId(from: raw),
              let rawProcessId = Self.pluginPpid(from: raw),
              let processId = pid_t(exactly: rawProcessId) else {
            return nil
        }

        guard let parentSessionId = appState.findAncestorSessionId(
            forSource: "pi",
            processId: processId,
            excluding: childSessionId,
            requireActive: true,
            parentPidLookup: parentPidLookup
        ) else {
            return nil
        }

        if mode == .merge || mode == .hide {
            appState.removeSession(childSessionId)
        }

        var child = raw
        child["_omp_subagent"] = true
        child["_omp_parent_session_id"] = parentSessionId
        child["_omp_agent_id"] = childSessionId
        child["_omp_agent_type"] = "omp"

        return applyOmpRouting(
            data: data,
            raw: child,
            childSessionId: childSessionId,
            parentSessionId: parentSessionId,
            agentId: childSessionId,
            agentType: "omp",
            mode: mode
        )
    }

    /// A hook after Agent Sub-Sessions: `json` is its parsed payload when
    /// routing had to parse it (HookEvent is built from that, not reparsed).
    private struct RoutedHook {
        var data: Data
        var json: [String: Any]?
        var rewritten = false
        var response: Data?
    }

    /// Test seam for Agent Sub-Sessions pre-routing (Cursor / Codex / plugin / OMP).
    internal func routeSubsessionPayloadIfNeededForTesting(
        data: Data
    ) -> (processedData: Data, responseData: Data?) {
        let routed = routeSubsessionPayloadIfNeeded(data: data)
        guard routed.rewritten,
              let json = routed.json,
              let rewritten = try? JSONSerialization.data(withJSONObject: json) else {
            return (routed.data, routed.response)
        }
        return (rewritten, routed.response)
    }

    /// Agent Sub-Sessions (#123, #151, #262, #378): find whose child the hook
    /// is (``SubsessionRouter/link(in:context:now:)``) and place it — on the
    /// child's own card, linked to its parent; folded into the parent's card;
    /// or hidden. OMP subagent routing (``decideOmpSubagent(raw:)``) runs
    /// first and short-circuits before ``SubsessionRouter`` sees the payload.
    private func routeSubsessionPayloadIfNeeded(data: Data) -> RoutedHook {
        let mode = AppState.currentPluginSessionMode()
        let mayBeOmp = Self.mayBeOmpSubagent(data: data)
            || (data.range(of: Self.ompSourceExactBytes) != nil
                && data.range(of: Self.ppidKeyBytes) != nil)
        guard Self.mayNeedSubsessionRouting(data: data, mode: mode) || mayBeOmp,
              var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RoutedHook(data: data)
        }

        // OMP explicit subagent routing takes priority over SubsessionRouter.
        switch Self.decideOmpSubagent(raw: raw) {
        case .route(let childSessionId, let parentSessionId, let agentId, let agentType):
            return applyOmpRouting(
                data: data,
                raw: raw,
                childSessionId: childSessionId,
                parentSessionId: parentSessionId,
                agentId: agentId,
                agentType: agentType,
                mode: mode
            )
        case .alreadyMerged:
            return RoutedHook(data: data, json: raw)
        case .passThrough:
            break
        }

        // OMP nested-process routing: a fresh OMP session whose process ancestry
        // includes an active parent OMP session is treated as a child.
        if data.range(of: Self.ompSourceExactBytes) != nil,
           let routed = routeNestedOmpProcessIfNeeded(data: data, raw: raw, mode: mode) {
            return routed
        }

        guard Self.mayNeedSubsessionRouting(data: data, mode: mode) else {
            return RoutedHook(data: data, json: raw)
        }

        let context = appState.subsessionContext
        guard let link = SubsessionRouter.link(in: raw, context: context) else {
            return RoutedHook(data: data, json: raw)
        }
        let original = raw
        let outcome = SubsessionRouter.route(
            &raw,
            link: link,
            mode: mode,
            cards: context.cards,
            isBlockingRequest: {
                HookEvent(json: original).map { Self.routeKind(for: $0) != .event } ?? false
            }
        )
        switch outcome {
        case .unchanged:
            return RoutedHook(data: data, json: raw)
        case .rewritten:
            return RoutedHook(data: data, json: raw, rewritten: true)
        case .hidden:
            return RoutedHook(data: data, json: raw, response: Data("{}".utf8))
        }
    }

    /// The interpretation of each pending edge delivery that sent facts
    /// (`_edge`), by connection: its answer goes back as its agent reads it.
    private var edgeIntakes: [ObjectIdentifier: HookIntake] = [:]

    /// A delivery before it is routed (``intake(_:origin:)``).
    enum Intake {
        /// Route `payload`. `edge` is HookIntake's reading of an edge that
        /// sent facts, nil for a payload its edge interpreted itself.
        case route(_ payload: Data, edge: HookIntake?)
        /// Answer nothing, and stop.
        case answerNothing
    }

    /// A request that arrived on `origin`'s socket, before it is routed.
    ///
    /// The socket names the host first (``HookOrigin/admit(_:)``): on a
    /// remote host's socket the payload is stamped with that host, whatever
    /// it claimed; on this Mac's, a payload that claims a remote host is
    /// answered with nothing. So HookIntake and everything after it see the
    /// host the socket names, and no other.
    ///
    /// An edge that cannot interpret its hook sends what it observed in
    /// `_edge` instead (``HookEdgeFacts``); HookIntake reads it here, as
    /// codeisland-bridge does on its own side. A payload without facts is its
    /// edge's own interpretation and passes as it is. Runs on the connection
    /// queue, off the main thread.
    nonisolated static func intake(_ received: Data, origin: HookOrigin) -> Intake {
        let data: Data
        let parsed: [String: Any]?
        switch origin.admit(received) {
        case .admitted(let admitted, let payload):
            data = admitted
            parsed = payload
        case .refusedRemoteClaim:
            // Only a process on this Mac reaches this socket, and none of
            // its hooks names a remote host: this one passes itself off as
            // one, which would take it past every check that keeps a remote
            // session from acting on this Mac.
            log.warning("HookServer: refused a request on this Mac's socket that claims to come from a remote host")
            return .answerNothing
        case .refusedUnreadable:
            log.warning("HookServer: refused a request on a remote host's socket that is not a JSON object")
            return .answerNothing
        case .refusedBlankHost:
            log.error("HookServer: refused a request on the socket of a remote host without an id")
            return .answerNothing
        }
        let payload = parsed ?? (HookEdgeFacts.mayCarryFacts(data)
            ? try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            : nil)
        guard let payload, let delivery = HookEdgeFacts.delivery(in: payload) else {
            return .route(data, edge: nil)
        }
        // Slashes unescaped, as the remote hook used to send them: the byte
        // probes below (`/.cursor/`) read paths as they are written.
        guard case .interpreted(let intake) = delivery,
              let interpreted = try? JSONSerialization.data(
                  withJSONObject: intake.payload,
                  options: [.withoutEscapingSlashes]
              ) else {
            return .answerNothing
        }
        // A hook nobody waits on is never held: one HookIntake does not hold
        // (a hook Cursor runs, #377) or one its edge does not wait on is
        // answered at once with nothing, as the bridge prints nothing for it,
        // and gets no card — its agent takes no answer from the island.
        if !intake.waitsForAnswer,
           let event = HookEvent(json: intake.payload),
           routeKind(for: event) != .event {
            return .answerNothing
        }
        return .route(interpreted, edge: intake)
    }

    private func processRequest(_ intake: Intake, connection: HookConnection) {
        let connectionId = ObjectIdentifier(connection)
        edgeIntakes[connectionId] = nil
        let data: Data
        switch intake {
        case .answerNothing:
            sendResponse(connection: connection, data: Data())
            return
        case .route(let payload, let edge):
            edgeIntakes[connectionId] = edge
            data = payload
        }

        // Sub-session pre-filter: a child session's hook (a Codex thread, a
        // Cursor Task, a declared child, a plugin proxy) follows Agent
        // Sub-Sessions — its own linked card, its parent's card, or hidden.
        let routed = routeSubsessionPayloadIfNeeded(data: data)
        if let responseData = routed.response {
            sendResponse(connection: connection, data: responseData)
            return
        }

        guard let event = routed.json.flatMap(HookEvent.init(json:)) ?? HookEvent(from: routed.data) else {
            sendResponse(connection: connection, data: Data("{\"error\":\"parse_failed\"}".utf8))
            return
        }

        // Diagnostics ring buffer (#103): record the post-merge view of the
        // event so the export reflects what was actually dispatched. Also
        // capture the field names the hook arrived with and a prompt preview
        // so future "prompt not showing" reports can be diagnosed without
        // round-tripping for more data.
        let payloadKeys = event.rawJSON.keys
            .filter { !$0.hasPrefix("_") }  // drop bridge-injected metadata fields
            .sorted()
        let promptPreview: String? = {
            let candidates = ["prompt", "user_prompt", "userPrompt", "message", "input", "content", "text"]
            for key in candidates {
                if let s = event.rawJSON[key] as? String {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return String(trimmed.prefix(80))
                    }
                }
            }
            return nil
        }()
        appState.recordHookEvent(
            source: event.rawJSON["_source"] as? String,
            sessionId: event.sessionId,
            eventName: event.eventName,
            toolName: event.toolName,
            viaPlugin: (event.rawJSON["_via_plugin"] as? Bool) == true,
            payloadKeys: payloadKeys,
            promptPreview: promptPreview
        )

        if let rawSource = event.rawJSON["_source"] as? String,
           SessionSnapshot.normalizedSupportedSource(rawSource) == nil {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        // User-configured cwd exclusion: drop hooks fired by background plugins
        // (e.g. claude-mem, agent loops) whose cwd matches any user-provided
        // substring. Default empty list = no filtering, matches existing behavior. (#125)
        if let cwd = event.rawJSON["cwd"] as? String,
           !cwd.isEmpty,
           Self.eventMatchesExcludedCwd(cwd) {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        // Per-host cwd allow-list for remote sessions (#240): on a shared remote
        // account every user's hooks reach every connected client — scope this
        // panel to the configured working directories and drop the rest.
        if let filterCSV = remoteCwdFilter,
           !Self.remoteEventPassesCwdFilter(
               cwd: event.rawJSON["cwd"] as? String,
               workspaceRoots: event.rawJSON["workspace_roots"] as? [String],
               filterCSV: filterCSV
           ),
           !Self.remoteEventBypassesCwdFilter(
               eventName: event.eventName,
               sessionId: event.sessionId,
               trackedSessionIds: Set(appState.sessions.keys)
           ) {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        // User-configured webhook forwarding via injected WebhookForwarder.
        // Runs before the route handlers; delayed delivery waits for user inactivity
        // and is cancelled via acknowledgeRequest once the user responds. (#115)
        appState.webhookForwarder?.submit(event, routeKind: Self.routeKind(for: event))

        switch Self.routeKind(for: event) {
        case .permission:
            // Auto-approve safe internal tools without showing UI
            if let toolName = event.toolName, autoApproveTools.contains(toolName) {
                let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
                sendResponse(connection: connection, data: Data(response.utf8))
                return
            }

            // Agents the user has already put in an always-proceed mode
            // (Antigravity Turbo, Cursor YOLO, …). Re-asking on the island is the
            // exact interruption that mode exists to remove (#283). Questions are
            // not permissions, so AskUserQuestion is deliberately excluded below.
            if event.toolName != "AskUserQuestion",
               Self.isAutoApprovedSource(event) {
                let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
                sendResponse(connection: connection, data: Data(response.utf8))
                return
            }

            // AskUserQuestion is a question, not a permission — route to QuestionBar
            if event.toolName == "AskUserQuestion" {
                guard let hook = hold(connection) else { return }
                Task {
                    let responseBody = await withCheckedContinuation { continuation in
                        appState.handleAskUserQuestion(event, continuation: continuation, hookConnectionId: hook)
                    }
                    self.sendResponse(connection: connection, data: responseBody)
                }
                return
            }

            if Self.shouldDeferPermissionRequestToProvider(event) {
                sendResponse(connection: connection, data: Data("{}".utf8))
                return
            }

            guard let hook = hold(connection) else { return }
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handlePermissionRequest(event, continuation: continuation, hookConnectionId: hook)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }

        case .question:
            guard let hook = hold(connection) else { return }
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handleQuestion(event, continuation: continuation, hookConnectionId: hook)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }

        case .event:
            appState.handleEvent(event)
            sendResponse(connection: connection, data: Data("{}".utf8))
        }
    }

    /// Per-connection state used by the disconnect monitor.
    /// `responded` flips to true once we've sent the response, so our own
    /// closing of the connection after `sendResponse` does not masquerade as a
    /// peer disconnect. `id` names the connection to AppState: the request it
    /// holds goes with it (``AppState/handleHookGone(connectionId:)``).
    private final class ConnectionContext {
        let id = UUID()
        var responded: Bool = false
    }

    private var connectionContexts: [ObjectIdentifier: ConnectionContext] = [:]

    /// Requests held for an answer now.
    private var heldRequests: Int {
        connectionContexts.values.reduce(0) { $0 + ($1.responded ? 0 : 1) }
    }

    /// Holds `connection` until its request is answered
    /// (``monitorPeerDisconnect(connection:)``) and returns its id — or,
    /// when the socket already holds as many requests as it may
    /// (``HookSocketLimits/maxHeldRequests``), answers it at once with
    /// nothing and returns nil: no card, and its agent asks in its own way.
    private func hold(_ connection: HookConnection) -> UUID? {
        if let cap = limits.maxHeldRequests, heldRequests >= cap {
            log.warning("HookServer: \(self.socketPath, privacy: .public) already holds \(cap) requests; answering one more with nothing")
            sendResponse(connection: connection, data: Data())
            return nil
        }
        return monitorPeerDisconnect(connection: connection)
    }

    /// Watch for bridge process disconnect — indicates the bridge process actually died
    /// (e.g. user Ctrl-C'd Claude Code), NOT a normal half-close.
    ///
    /// The bridge always does `shutdown(SHUT_WR)` after sending the request (see
    /// CodeIslandBridge/main.swift), which produces an immediate EOF on the read side:
    /// taken for a disconnect, every PermissionRequest was auto-drained as `deny`
    /// before its card was even visible. ``HookConnection/closeWhenPeerLeaves()``
    /// closes the connection only on real teardown, and a connection that closes
    /// without an answer — its hook gone, seen by that watch or by the safety
    /// net below — drops its card, and no other: each held request has a hook
    /// of its own.
    ///
    /// Returns the connection's id, for its request (`hookConnectionId`).
    private func monitorPeerDisconnect(connection: HookConnection) -> UUID {
        let context = ConnectionContext()
        let connId = ObjectIdentifier(connection)
        connectionContexts[connId] = context

        // Holding `connection` until this runs keeps its identifier from being reused.
        connection.onClose { [weak self, connection] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !context.responded {
                        self.appState.handleHookGone(connectionId: context.id)
                    }
                    if self.connectionContexts[ObjectIdentifier(connection)] === context {
                        self.connectionContexts.removeValue(forKey: connId)
                    }
                }
            }
        }
        connection.closeWhenPeerLeaves()

        // Safety net, should the watch ever miss its hook leaving: now and
        // then, a held request whose hook is gone is closed, and its card
        // dropped. A hook still there is never cut off: it waits as long as
        // its agent lets it (the bridge up to 86400 s), for someone who
        // stepped away (#306), and its request stays answerable.
        let interval = UInt64(heldRequestCheckInterval * 1_000_000_000)
        Task { @MainActor [weak self, weak connection] in
            while (try? await Task.sleep(nanoseconds: interval)) != nil {
                guard let self, let connection,
                      self.connectionContexts[connId] === context,
                      !context.responded else { return }
                connection.closeIfPeerGone()
            }
        }
        return context.id
    }

    private func sendResponse(connection: HookConnection, data: Data) {
        // Mark as responded BEFORE the connection closes so the disconnect monitor
        // ignores our own teardown.
        if let context = connectionContexts[ObjectIdentifier(connection)] {
            context.responded = true
        }
        // An edge that sent facts gets what the bridge would have printed.
        var data = data
        if let intake = edgeIntakes.removeValue(forKey: ObjectIdentifier(connection)) {
            data = intake.stdout(forAnswer: data) ?? Data()
        }
        connection.respond(data)
    }
}

/// The origin a server's connection queue reads, while the main actor may
/// rename its host.
private final class OriginBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: HookOrigin

    init(_ origin: HookOrigin) {
        current = origin
    }

    var value: HookOrigin {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func set(_ origin: HookOrigin) {
        lock.lock()
        current = origin
        lock.unlock()
    }
}
