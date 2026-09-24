import AppKit
import CodeIslandCore

/// Watches the system for "nobody is at the screen" moments — screen locked,
/// screen saver running, displays asleep — and feeds `SceneMuteState`.
///
/// Sources, all observable without any permission:
/// - `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` and
///   `com.apple.screensaver.didstart` / `didstop` on the distributed center
///   (posted by loginwindow / ScreenSaverEngine for any process to see);
/// - `NSWorkspace.screensDidSleep` / `screensDidWake`.
///
/// Focus / Do Not Disturb and screen sharing are deliberately absent: neither
/// has a public API that works without an extra permission prompt or Full Disk
/// Access (see the follow-up notes in the feature report).
@MainActor
final class SceneMuteMonitor {
    static let shared = SceneMuteMonitor()

    private(set) var state = SceneMuteState()

    /// Called on the main actor whenever the quiet scene begins or ends.
    /// Follow-up reminders use the "ended" edge to deliver what they held back.
    var onQuietChanged: ((_ isQuiet: Bool) -> Void)?

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private init() {}

    var isQuietScene: Bool { state.isQuiet }

    /// Begin observing. Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let distributedSignals: [(String, SceneMuteState.Signal)] = [
            ("com.apple.screenIsLocked", .screenLocked),
            ("com.apple.screenIsUnlocked", .screenUnlocked),
            ("com.apple.screensaver.didstart", .screensaverStarted),
            ("com.apple.screensaver.didstop", .screensaverStopped),
        ]
        for (name, signal) in distributedSignals {
            observe(distributed, Notification.Name(name), signal)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification, .displaysSlept)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .displaysWoke)
    }

    /// Applies one signal. Internal so tests can drive the monitor directly.
    func apply(_ signal: SceneMuteState.Signal) {
        guard state.apply(signal) else { return }
        onQuietChanged?(state.isQuiet)
    }

    /// Test hook: forget every signal seen so far.
    func resetForTesting() {
        state = SceneMuteState()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ signal: SceneMuteState.Signal) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.apply(signal) }
        }
        observers.append((center, token))
    }
}
