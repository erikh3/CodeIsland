import AppKit
import CoreGraphics

@MainActor
final class UserPresenceMonitor {
    typealias IdleSecondsProvider = @Sendable () -> TimeInterval

    private(set) var isSessionLocked = false
    private let idleSecondsProvider: IdleSecondsProvider
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    var onSessionLocked: (() -> Void)?

    init(
        idleSecondsProvider: @escaping IdleSecondsProvider = {
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: CGEventType(rawValue: ~0)!
            )
        },
        observeSystem: Bool = true
    ) {
        self.idleSecondsProvider = idleSecondsProvider
        if observeSystem {
            startObserving()
        }
    }

    func idleSeconds() async -> TimeInterval {
        let provider = idleSecondsProvider
        return await Task.detached(priority: .utility) { provider() }.value
    }

    func setSessionLockedForTesting(_ locked: Bool) {
        setSessionLocked(locked)
    }

    private func startObserving() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setSessionLocked(true) }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setSessionLocked(false) }
        })

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.append(distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setSessionLocked(true) }
        })
        distributedObservers.append(distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setSessionLocked(false) }
        })
    }

    private func setSessionLocked(_ locked: Bool) {
        guard isSessionLocked != locked else { return }
        isSessionLocked = locked
        if locked {
            onSessionLocked?()
        }
    }

    deinit {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        let distributedCenter = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            distributedCenter.removeObserver(observer)
        }
    }
}
