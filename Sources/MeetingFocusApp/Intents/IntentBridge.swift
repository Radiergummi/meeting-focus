import Foundation

/// How an App Intent or a scripting command reaches the live monitor.
///
/// Both surfaces are instantiated by the system, outside the object graph `AppDelegate` builds, and
/// neither is handed anything. `AppDelegate` owns the monitor for the whole launch, so this holds it
/// weakly and hands back nil in the one window where there is nothing to hand back — before
/// `applicationDidFinishLaunching` has run.
@MainActor
enum IntentBridge {
    static weak var monitor: MeetingMonitor?
}
