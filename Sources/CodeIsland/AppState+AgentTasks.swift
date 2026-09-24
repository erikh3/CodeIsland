import Foundation
import CodeIslandCore

/// An attach-time checklist backfill that is still scanning.
struct PendingAgentTaskBackfill {
    /// Tailer attachment the scan belongs to; a re-attach supersedes it.
    let attachmentToken: UUID
    /// Tail events that landed while the scan ran. They are newer than every
    /// scanned byte, so they replay on top of the rebuilt list.
    var bufferedEvents: [AgentTaskEvent] = []
}

extension AppState {
    /// Rebuild a session's checklist (TaskCreate / TodoWrite / update_plan)
    /// from transcript history without blocking the main actor — transcripts
    /// run to tens of MB.
    ///
    /// `endOffset` is the file size captured just before the tailer attached,
    /// so the scan and the live tail read disjoint bytes and no operation or
    /// prompt is seen twice.
    func startAgentTaskBackfill(sessionId: String, path: String, endOffset: UInt64, attachmentToken: UUID) {
        guard endOffset > 0 else {
            pendingAgentTaskBackfills.removeValue(forKey: sessionId)
            return
        }
        pendingAgentTaskBackfills[sessionId] = PendingAgentTaskBackfill(attachmentToken: attachmentToken)
        Task.detached(priority: .utility) { [weak self] in
            let backfill = AgentTaskTranscript.scanFile(atPath: path, endOffset: endOffset)
            await self?.finishAgentTaskBackfill(
                sessionId: sessionId,
                attachmentToken: attachmentToken,
                backfill: backfill
            )
        }
    }

    func finishAgentTaskBackfill(
        sessionId: String,
        attachmentToken: UUID,
        backfill: AgentTaskTranscript.Backfill?
    ) {
        guard let pending = pendingAgentTaskBackfills[sessionId],
              pending.attachmentToken == attachmentToken else { return }
        pendingAgentTaskBackfills.removeValue(forKey: sessionId)
        guard attachedTranscriptTokens[sessionId] == attachmentToken,
              let backfill,
              var session = sessions[sessionId] else { return }
        let rebuilt = Self.agentTasksAfterBackfill(
            live: session.agentTasks,
            backfill: backfill,
            bufferedEvents: pending.bufferedEvents,
            now: Date()
        )
        guard rebuilt != session.agentTasks else { return }
        session.agentTasks = rebuilt
        sessions[sessionId] = session
        scheduleSave()
    }

    /// The list after an attach-time scan. A scan without checklist-building
    /// operations (prompts and unrelated tool failures don't count) leaves
    /// the live list (which already holds the buffered tail events) alone;
    /// otherwise history is replayed and the buffered tail events are applied
    /// on top, as live events.
    nonisolated static func agentTasksAfterBackfill(
        live: AgentTaskList,
        backfill: AgentTaskTranscript.Backfill,
        bufferedEvents: [AgentTaskEvent],
        now: Date
    ) -> AgentTaskList {
        guard backfill.events.contains(where: \.buildsList) else { return live }
        var board = AgentTaskList.rebuilt(
            fromTranscript: backfill.events,
            coversWholeTranscript: backfill.coversWholeFile,
            live: live
        )
        board.apply(bufferedEvents, now: now)
        return board
    }

    /// Apply checklist events from a transcript tail delta. Returns whether
    /// the visible list changed.
    func applyAgentTaskTranscriptEvents(
        _ events: [AgentTaskEvent],
        sessionId: String,
        to session: inout SessionSnapshot
    ) -> Bool {
        pendingAgentTaskBackfills[sessionId]?.bufferedEvents.append(contentsOf: events)
        guard session.agentTasks.apply(events, now: Date()) else { return false }
        // Codex plans only ever arrive here — no hook would persist them.
        scheduleSave()
        return true
    }

    /// Current byte size of a transcript, or 0 when unreadable.
    nonisolated static func transcriptFileSize(_ path: String) -> UInt64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        return size?.uint64Value ?? 0
    }
}
