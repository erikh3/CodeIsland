import Foundation
import CodeIslandCore

/// Transcript-derived session metadata that hooks don't carry: a subagent's
/// own model / reasoning effort. (The session recap and the main thread's
/// model ride the transcript tailer — see `applyTranscriptDelta`.)
extension AppState {
    /// How long to wait before re-reading a subagent transcript that has no
    /// assistant turn yet (SubagentStart fires before the first one is written).
    nonisolated static let subagentModelReadRetryInterval: TimeInterval = 2

    /// Give a subagent its own model/effort, read from the child's transcript.
    ///
    /// Claude Code hooks never say which model a subagent runs, and Codex child
    /// hooks carry the model but not the effort. Borrowing the parent's values
    /// would mislabel every Task that runs on a different model, so the child's
    /// own transcript is the source. A successful read is cached per agent id
    /// because Codex recreates the SubagentState on every child turn.
    func maybeBackfillSubagentModel(sessionId: String, agentId: String, event: HookEvent) {
        guard let session = sessions[sessionId],
              let subagent = session.subagents[agentId] else { return }

        if let cached = subagentModelObservations[sessionId]?[agentId] {
            applySubagentModel(cached, sessionId: sessionId, agentId: agentId)
            return
        }
        guard subagent.model == nil || subagent.reasoningEffort == nil else { return }
        let now = Date()
        if let retryAt = subagentModelReadRetryAt[sessionId]?[agentId], retryAt > now { return }

        let observation: ModelObservation?
        switch SessionSnapshot.normalizedSupportedSource(session.source) {
        case "claude":
            observation = session.transcriptPath.flatMap {
                Self.readClaudeSubagentModel(parentTranscriptPath: $0, agentId: agentId)
            }
        case "codex":
            // Child-thread hooks carry the child's own rollout path.
            if let childPath = event.rawJSON["transcript_path"] as? String,
               !childPath.isEmpty, childPath != session.transcriptPath {
                observation = JSONLTailer.scanFileTail(path: childPath)?.modelObservation
            } else {
                observation = nil
            }
        default:
            // No child transcript to read; a model on the child's own hooks
            // (recordSubagentModel in the reducer) is all there is.
            subagentModelReadRetryAt[sessionId, default: [:]][agentId] = .distantFuture
            return
        }

        guard let observation else {
            subagentModelReadRetryAt[sessionId, default: [:]][agentId] =
                now.addingTimeInterval(Self.subagentModelReadRetryInterval)
            return
        }
        subagentModelObservations[sessionId, default: [:]][agentId] = observation
        subagentModelReadRetryAt[sessionId]?.removeValue(forKey: agentId)
        applySubagentModel(observation, sessionId: sessionId, agentId: agentId)
    }

    private func applySubagentModel(_ observation: ModelObservation, sessionId: String, agentId: String) {
        guard var subagent = sessions[sessionId]?.subagents[agentId] else { return }
        // A model the child's own hook reported is at least as current as the
        // cached transcript read, so only fill gaps.
        let model = subagent.model ?? observation.model
        let effort = subagent.reasoningEffort ?? observation.effort
        guard model != subagent.model || effort != subagent.reasoningEffort else { return }
        subagent.model = model
        subagent.reasoningEffort = effort
        sessions[sessionId]?.subagents[agentId] = subagent
    }

    /// Newest model/effort in a Claude subagent's transcript. Claude Code may
    /// nest the file one directory deeper (`subagents/<group>/agent-<id>.jsonl`)
    /// for grouped runs, so that single level is searched when the default
    /// location is missing.
    nonisolated static func readClaudeSubagentModel(
        parentTranscriptPath: String,
        agentId: String,
        maxBytes: Int = 64 * 1024
    ) -> ModelObservation? {
        guard let defaultPath = SubagentState.claudeTranscriptPath(
            parentTranscriptPath: parentTranscriptPath,
            agentId: agentId
        ) else { return nil }
        let fm = FileManager.default
        var path: String? = fm.fileExists(atPath: defaultPath) ? defaultPath : nil
        if path == nil {
            let subagentsDir = (defaultPath as NSString).deletingLastPathComponent
            let fileName = (defaultPath as NSString).lastPathComponent
            let groups = (try? fm.contentsOfDirectory(atPath: subagentsDir)) ?? []
            path = groups.lazy
                .map { "\(subagentsDir)/\($0)/\(fileName)" }
                .first { fm.fileExists(atPath: $0) }
        }
        guard let path, let data = readTranscriptTailData(path: path, maxBytes: maxBytes) else { return nil }
        return ModelObservation.latestInClaudeTranscript(data)
    }

    private nonisolated static func readTranscriptTailData(path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }
}
