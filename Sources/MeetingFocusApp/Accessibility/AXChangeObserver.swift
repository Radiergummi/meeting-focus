import ApplicationServices
import Foundation

/// Watches an application's accessibility notifications so state changes can be picked up sooner
/// than the next poll.
///
/// This is a latency optimisation, not the correctness mechanism. Measured on a real meeting
/// teardown, `AXUIElementDestroyed` and `AXMainWindowChanged` arrived 1.12 seconds before the poll
/// noticed. Join detection, by contrast, has not been shown to be reliably announced — Teams
/// appears to retitle an existing window rather than create one — so polling remains the base.
/// Every use is confined to the main actor (the run loop source is installed there), so the
/// unchecked conformance is what lets an actor-isolated detector hold one.
final class AXChangeObserver: @unchecked Sendable {
    private final class Box {
        let onChange: @Sendable () -> Void
        init(onChange: @Sendable @escaping () -> Void) { self.onChange = onChange }
    }

    private var observer: AXObserver?
    private var box: Box?

    /// Notifications worth waking for. `AXTitleChanged` is deliberately excluded: during a call
    /// Teams' elapsed-time label emits it at roughly 1 Hz (83 events in 65 seconds when measured),
    /// which would turn every meeting into a continuous rescan.
    private static let notifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowCreatedNotification,
        kAXMainWindowChangedNotification,
        kAXFocusedWindowChangedNotification,
    ]

    func start(pid: pid_t, onChange: @Sendable @escaping () -> Void) {
        stop()
        let box = Box(onChange: onChange)
        self.box = box

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }

        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let created else {
            Log.accessibility.warning("could not create AXObserver for pid \(pid)")
            return
        }
        observer = created

        let application = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(box).toOpaque()
        for notification in Self.notifications {
            let result = AXObserverAddNotification(created, application, notification as CFString, context)
            if result != .success {
                Log.accessibility.debug("subscribe \(notification) failed: \(result.rawValue)")
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        box = nil
    }

    deinit { stop() }
}
