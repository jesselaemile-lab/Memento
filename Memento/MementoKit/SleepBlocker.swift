import Foundation

/// Keeps the Mac awake while a long-running operation (scan, plan execution) is in flight.
/// Prevents idle system sleep even when the screen is locked or turned off.
/// Note: closing the lid still sleeps the machine — no app-level API can override that.
final class SleepBlocker {
    private var activity: NSObjectProtocol?

    func begin(reason: String) {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: reason
        )
    }

    func end() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    deinit { end() }
}
