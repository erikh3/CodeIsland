import SwiftUI
import CodeIslandCore

/// Session-card row for the agent's own checklist (TaskCreate / TodoWrite /
/// Codex update_plan): a segmented bar, "2/5", and what the agent is doing
/// right now. Click it to list every item; hover for the full list as a tooltip.
///
/// A finished list lingers for ``AgentTaskList/completedLinger`` and then fades
/// via a single one-shot sleep tied to its `completedAt` — no polling timer, so
/// an idle panel stays idle.
struct AgentTaskProgressView: View, Equatable {
    let tasks: AgentTaskList
    let fontSize: CGFloat

    @State private var showAll: Bool
    /// `completedAt` of a finished list that has already faded out.
    @State private var fadedCompletion: Date?

    init(tasks: AgentTaskList, fontSize: CGFloat, initiallyExpanded: Bool = false) {
        self.tasks = tasks
        self.fontSize = fontSize
        _showAll = State(initialValue: initiallyExpanded)
    }

    static let doneColor = Color(red: 0.3, green: 0.85, blue: 0.4)
    static let activeColor = Color(red: 1.0, green: 0.78, blue: 0.3)
    static let pendingColor = Color.white.opacity(0.18)
    /// Longer lists collapse into "+N more" when expanded inline.
    static let maxListedItems = 12

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tasks == rhs.tasks && lhs.fontSize == rhs.fontSize
    }

    private var smallSize: CGFloat { max(9, fontSize - 1) }

    var body: some View {
        if isShown {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(NotchAnimation.micro) { showAll.toggle() }
                } label: {
                    compactRow
                }
                .buttonStyle(.plain)
                .help(tooltip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(
                    format: L10n.shared["task_progress_a11y"],
                    tasks.completedCount,
                    tasks.items.count
                ))

                if showAll {
                    fullList
                        .transition(.opacity)
                }
            }
            .padding(.leading, 4)
            .task(id: tasks.completedAt) { await fadeOutWhenFinished() }
            .transition(.opacity)
        }
    }

    private var isShown: Bool {
        guard !tasks.isEmpty else { return false }
        if let completedAt = tasks.completedAt, fadedCompletion == completedAt { return false }
        return tasks.isVisible(now: Date())
    }

    /// Sleep once until the finished list's deadline, then fade it. Cancelled
    /// automatically when the list changes (new `completedAt`) or the card
    /// leaves the screen; a card rendered after the deadline never shows it.
    private func fadeOutWhenFinished() async {
        guard let completedAt = tasks.completedAt,
              let deadline = tasks.hideDeadline() else { return }
        let delay = deadline.timeIntervalSinceNow
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.35)) { fadedCompletion = completedAt }
    }

    private var compactRow: some View {
        HStack(spacing: 6) {
            AgentTaskBar(items: tasks.items)
                .frame(width: 46, height: 5)

            Text("\(tasks.completedCount)/\(tasks.items.count)")
                .font(.system(size: smallSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(tasks.isAllCompleted ? Self.doneColor : .white.opacity(0.6))
                .fixedSize()

            if tasks.isAllCompleted {
                Text(L10n.shared["task_progress_all_done"])
                    .font(.system(size: smallSize, design: .monospaced))
                    .foregroundStyle(Self.doneColor.opacity(0.85))
                    .lineLimit(1)
            } else if let current = tasks.current {
                Text(current.progressLabel)
                    .font(.system(size: smallSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let next = tasks.items.first(where: { $0.status == .pending }) {
                // Nothing claimed yet — show what is next, dimmed.
                Text(next.title)
                    .font(.system(size: smallSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            Image(systemName: showAll ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .contentShape(Rectangle())
    }

    private var fullList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tasks.items.prefix(Self.maxListedItems)) { item in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Self.symbol(item.status))
                        // The bar's pending grey is too faint for a glyph.
                        .foregroundStyle(item.status == .pending ? .white.opacity(0.4) : Self.color(item.status))
                    Text(item.title)
                        .foregroundStyle(Self.titleColor(item.status))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: smallSize, design: .monospaced))
            }
            if tasks.items.count > Self.maxListedItems {
                Text(String(format: L10n.shared["task_progress_more"], tasks.items.count - Self.maxListedItems))
                    .font(.system(size: smallSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.leading, 2)
    }

    private var tooltip: String {
        let limit = 30
        var lines = tasks.items.prefix(limit).map { "\(Self.symbol($0.status)) \($0.title)" }
        if tasks.items.count > limit {
            lines.append(String(format: L10n.shared["task_progress_more"], tasks.items.count - limit))
        }
        return lines.joined(separator: "\n")
    }

    /// U+FE0E keeps ▶ in text presentation instead of the emoji glyph.
    static func symbol(_ status: AgentTaskStatus) -> String {
        switch status {
        case .completed: return "✓"
        case .inProgress: return "▶\u{FE0E}"
        case .pending: return "○"
        }
    }

    static func color(_ status: AgentTaskStatus) -> Color {
        switch status {
        case .completed: return doneColor
        case .inProgress: return activeColor
        case .pending: return pendingColor
        }
    }

    private static func titleColor(_ status: AgentTaskStatus) -> Color {
        switch status {
        case .completed: return .white.opacity(0.4)
        case .inProgress: return .white.opacity(0.9)
        case .pending: return .white.opacity(0.6)
        }
    }
}

/// One segment per task while they stay readable; a proportional
/// done/in-progress fill beyond that. A static Canvas — redrawn only when the
/// list changes.
private struct AgentTaskBar: View {
    let items: [AgentTaskItem]

    static let maxSegments = 12

    var body: some View {
        Canvas { context, size in
            guard !items.isEmpty else { return }
            if items.count <= Self.maxSegments {
                let gap: CGFloat = 1.5
                let width = (size.width - gap * CGFloat(items.count - 1)) / CGFloat(items.count)
                for (index, item) in items.enumerated() {
                    let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: size.height / 2),
                        with: .color(AgentTaskProgressView.color(item.status))
                    )
                }
            } else {
                let total = CGFloat(items.count)
                let done = CGFloat(items.filter { $0.status == .completed }.count)
                let active = CGFloat(items.filter { $0.status == .inProgress }.count)
                let track = CGRect(origin: .zero, size: size)
                context.clip(to: Path(roundedRect: track, cornerRadius: size.height / 2))
                context.fill(Path(track), with: .color(AgentTaskProgressView.pendingColor))
                let doneWidth = size.width * done / total
                context.fill(
                    Path(CGRect(x: 0, y: 0, width: doneWidth, height: size.height)),
                    with: .color(AgentTaskProgressView.doneColor)
                )
                context.fill(
                    Path(CGRect(x: doneWidth, y: 0, width: size.width * active / total, height: size.height)),
                    with: .color(AgentTaskProgressView.activeColor)
                )
            }
        }
    }
}
