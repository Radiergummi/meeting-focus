# External meeting state — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let another Shortcut, script or automation set and read MeetingFocus's meeting state, and give a manual claim a duration so a forgotten override heals itself.

**Architecture:** The mechanism already exists — the menu bar switch feeds a `"manual"` detector tier into `MeetingStateMachine`, and `dismissActiveMeetings()` lets the user overrule a detector for exactly as long as that detector keeps claiming the meeting. This plan adds a duration on the assert direction, the *withdraw* operation the duration exposes (retract the claim without declaring there is no meeting), and two inbound surfaces — App Intents and AppleScript — that reach the same `MeetingMonitor` methods the switch does.

**Tech Stack:** Swift 6 (strict concurrency: complete), macOS 26, XCTest via SwiftPM for `MeetingFocusCore`, XcodeGen (`project.yml` → `MeetingFocus.xcodeproj`), AppIntents, Cocoa Scripting (`.sdef` + `NSScriptCommand`).

**Spec:** `docs/superpowers/specs/2026-08-26-external-meeting-state-design.md`

## Global Constraints

- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`. `MeetingMonitor`, `MeetingStateMachine` and `AutomationCoordinator` are all `@MainActor`.
- `MeetingFocusCore` has **no dependencies and no platform APIs** — nothing importing AppKit or AppIntents may go in it. That is what keeps `swift test` fast.
- Every user-visible string in `Sources/MeetingFocusApp` must be `String(localized:)` **or** `LocalizedStringResource`, with a matching key in `Sources/MeetingFocusApp/Localizable.xcstrings` for both `en` and `de`. `Tests/LocalizationTests` fails the build otherwise. Edit the catalogue with the `xcstrings` tool (`make xcstrings`), never by hand.
- `recentEvents` strings are the exception: `note()` uses plain literals today and this work does not change that.
- The project file is generated. Edit `project.yml`, then `make generate`. Never edit `MeetingFocus.xcodeproj/project.pbxproj` directly.
- Verification gate for every task: `make lint test` must pass, and `xcodebuild -project MeetingFocus.xcodeproj -scheme MeetingFocus -configuration Debug build CODE_SIGNING_ALLOWED=NO` must succeed.
- Duration defaults: 60 minutes when a caller names none; clamped to a floor of 1 second and a ceiling of 8 hours.
- **No `CFBundleURLTypes`.** A URL scheme was considered and rejected; see the spec.

**Already landed in 47b9f65 — do not rebuild:** the menu switch, re-asserting the manual claim on the tick, and `AutomationCoordinator.endImmediately()`.

---

### Task 1: Duration, withdrawal, and the source in the log

Adds the third operation. Today `setInMeeting(false)` both retracts the manual claim *and* dismisses whatever the detectors assert. An expiry must do only the first: routing a lapsing timer through dismissal would silently suppress a real, detected call for as long as it ran.

**Files:**
- Create: `Sources/MeetingFocusCore/ManualMeeting.swift`
- Create: `Tests/MeetingFocusCoreTests/ManualMeetingTests.swift`
- Modify: `Tests/MeetingFocusCoreTests/MeetingStateMachineTests.swift` (append one test)
- Modify: `Sources/MeetingFocusApp/MeetingMonitor.swift` (the `// MARK: The switch` section and `startTicking()`)
- Modify: `Sources/MeetingFocusApp/UI/MenuBarController.swift` (`meetingSwitched(_:)` call site)

**Interfaces:**
- Consumes: `MeetingStateMachine.retractEvidence(fromDetector:)`, `MeetingStateMachine.dismissActiveMeetings()`, `AutomationCoordinator.endImmediately()` — all existing.
- Produces, for Tasks 2 and 3:
  - `ManualMeetingDuration.default: TimeInterval`, `.maximum: TimeInterval`, `.clamped(_ requested: TimeInterval) -> TimeInterval`
  - `MeetingMonitor.setInMeeting(_ inMeeting: Bool, for duration: TimeInterval?, source: String, title: String?)`
  - `MeetingMonitor.withdrawManualMeeting(isInstruction: Bool)`
  - `MeetingMonitor.manualMeeting: Bool` (existing), `MeetingMonitor.manualMeetingExpiresAt: Date?`

- [ ] **Step 1: Write the failing duration tests**

Create `Tests/MeetingFocusCoreTests/ManualMeetingTests.swift`:

```swift
import XCTest
@testable import MeetingFocusCore

final class ManualMeetingTests: XCTestCase {
    func testKeepsAReasonableDuration() {
        XCTAssertEqual(ManualMeetingDuration.clamped(30 * 60), 30 * 60)
    }

    /// A caller-settable duration invites `minutes: 100000`, which would reintroduce the forgotten
    /// override the duration exists to prevent.
    func testClampsToAWorkingDay() {
        XCTAssertEqual(ManualMeetingDuration.clamped(100_000 * 60), ManualMeetingDuration.maximum)
    }

    /// Zero or negative would expire the claim the instant it was made, which is not what any caller
    /// asking for a manual meeting means.
    func testClampsZeroAndNegativeToTheFloor() {
        XCTAssertEqual(ManualMeetingDuration.clamped(0), 1)
        XCTAssertEqual(ManualMeetingDuration.clamped(-5), 1)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter ManualMeetingTests`
Expected: compile failure — `cannot find 'ManualMeetingDuration' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/MeetingFocusCore/ManualMeeting.swift`:

```swift
import Foundation

/// How long a manual meeting claim stands when something other than the menu switch makes it.
///
/// The switch needs no duration: a person at the keyboard flipped it and can flip it back. An
/// automation may not be watching, so an external caller gets an hour unless it says otherwise —
/// and a caller-settable duration invites `minutes: 100000`, which would reintroduce through the
/// back door exactly the forgotten override the duration exists to close.
///
/// Clamped rather than rejected, so a slightly wrong automation keeps working. What it actually got
/// is returned to it, so it is corrected rather than silently overruled.
public enum ManualMeetingDuration {
    /// What an external caller gets when it names no duration.
    public static let `default`: TimeInterval = 60 * 60
    /// A working day. Longer than this is a forgotten override, not an intention.
    public static let maximum: TimeInterval = 8 * 60 * 60

    public static func clamped(_ requested: TimeInterval) -> TimeInterval {
        min(max(requested, 1), maximum)
    }
}
```

- [ ] **Step 4: Run it and watch it pass**

Run: `swift test --filter ManualMeetingTests`
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Write the failing withdrawal test**

This is the test most worth having in this task: the failure it guards against is silent. Append to `Tests/MeetingFocusCoreTests/MeetingStateMachineTests.swift`, before the closing brace:

```swift
    /// Withdrawing a manual claim is not the same statement as "I am not in a meeting". A duration
    /// lapsing must leave a call a detector can see running, or the timer would silently suppress a
    /// real meeting for as long as it lasted. The dismissal tests above cover the other half.
    func testRetractingTheManualClaimLeavesADetectedMeetingRunning() {
        let manual = "manual"
        machine.ingest(evidence(.inMeeting, subject: manual, detector: manual, at: clock.now))
        machine.ingest(evidence(.inMeeting, subject: Subjects.teams, at: clock.now))
        clock.advance(1.0)
        machine.tick()
        XCTAssertEqual(started.count, 2)

        machine.retractEvidence(fromDetector: manual)

        XCTAssertTrue(machine.isInMeeting, "the Teams call is still in progress")
        XCTAssertEqual(machine.state(forSubject: Subjects.teams), .inMeeting)
        XCTAssertEqual(machine.state(forSubject: manual), .idle)
        XCTAssertEqual(ended.count, 1, "only the manual claim ends")
    }
```

- [ ] **Step 6: Run it**

Run: `swift test --filter testRetractingTheManualClaimLeavesADetectedMeetingRunning`
Expected: **PASS on the first run.** `retractEvidence(fromDetector:)` already behaves this way; this test pins behaviour that Task 1's production change is about to start depending on. That is the one legitimate reason to keep a test that passes immediately — confirm by deleting the `retractEvidence` line and re-running (it should then fail on `ended.count`), then restore it.

- [ ] **Step 7: Add duration and withdrawal to `MeetingMonitor`**

In `Sources/MeetingFocusApp/MeetingMonitor.swift`, replace the `// MARK: The switch` section. Keep the existing doc comment on `setInMeeting`; add to it.

```swift
    /// Whether the user has declared a meeting by hand. Not persisted: a meeting someone switched on
    /// is over by the time the app is next launched.
    private(set) var manualMeeting = false
    /// When the claim lapses, or nil for indefinite — which only the menu switch asks for.
    private(set) var manualMeetingExpiresAt: Date?

    private static let manualDetectorID = "manual"

    /// Says whether the user is in a meeting, in the user's own voice.
    ///
    /// On is evidence rather than a second opinion: a definitive claim goes into the same machine the
    /// detectors feed, so automation, the status row and the detection log treat it exactly as they
    /// treat a detected call, and `aggregateState` stays the one answer to the question.
    ///
    /// Off both withdraws that claim and dismisses whatever the detectors are still asserting, which
    /// is why this is a method rather than a settable flag: turning the switch off while Teams is
    /// mid-call has to do something even though no *manual* meeting exists to withdraw. "Not in a
    /// meeting" is a statement about the user, and it outranks every detector for exactly as long as
    /// the call it was said about — see `MeetingStateMachine.dismissActiveMeetings`.
    ///
    /// - Parameter duration: nil is indefinite, which only the menu switch may ask for; a person at
    ///   the keyboard can flip the switch back, where an automation may never look again.
    func setInMeeting(
        _ inMeeting: Bool,
        for duration: TimeInterval? = nil,
        source: String = "menu",
        title: String? = nil
    ) {
        manualMeeting = inMeeting
        if inMeeting {
            manualMeetingTitle = title
            manualMeetingExpiresAt = duration.map {
                timeSource.now.addingTimeInterval(ManualMeetingDuration.clamped($0))
            }
            assertManualMeeting()
            note("Manual meeting via \(source)")
        } else {
            manualMeetingExpiresAt = nil
            manualMeetingTitle = nil
            machine.retractEvidence(fromDetector: Self.manualDetectorID)
            machine.dismissActiveMeetings()
            // Dismissing ends the meeting, but automation would still hold that end for `endCooldown`
            // and leave the user's Focus mode on for another 45 seconds. The cooldown is there for the
            // gap between back-to-back meetings; it is not for someone saying they are done.
            coordinator.endImmediately()
            note("Not in a meeting via \(source)")
        }
        refresh()
    }

    /// Withdraws the manual claim, and says nothing at all about the detectors.
    ///
    /// The distinction this draws is the whole reason it exists. `setInMeeting(false)` is the
    /// statement "I am not in a meeting", which dismisses a detected call too. Withdrawal is only
    /// "stop claiming" — so a duration running out while Teams is mid-call leaves that call alone
    /// instead of silently suppressing it for as long as it lasts.
    ///
    /// - Parameter isInstruction: true when a person or an automation asked for this, false when a
    ///   duration simply ran out. An instruction ends automation at once; a lapsing timer uses the
    ///   ordinary cooldown, because the likeliest expiry is a call that ran a little long and is
    ///   about to be re-declared.
    func withdrawManualMeeting(isInstruction: Bool) {
        guard manualMeeting else { return }
        manualMeeting = false
        manualMeetingExpiresAt = nil
        manualMeetingTitle = nil
        machine.retractEvidence(fromDetector: Self.manualDetectorID)
        note(isInstruction ? "Manual meeting withdrawn" : "Manual meeting expired")
        refresh()
        if isInstruction, !machine.isInMeeting { coordinator.endImmediately() }
    }

    private var manualMeetingTitle: String?

    private func assertManualMeeting() {
        machine.ingest(MeetingEvidence(
            detectorID: Self.manualDetectorID,
            subjectID: Self.manualDetectorID,
            verdict: .inMeeting,
            confidence: .definitive,
            // Named, because this is what the menu and the detection log call it.
            applicationName: String(localized: "Manual meeting"),
            title: manualMeetingTitle,
            observedAt: Date()
        ))
    }
```

Note: `assertManualMeeting()` is called once per tick, so the `note(...)` calls belong in `setInMeeting`/`withdrawManualMeeting` and must **not** move into it — otherwise the detection log fills with one line a second.

- [ ] **Step 8: Add the lapse check to the tick**

In `startTicking()`, replace the existing re-assertion line:

```swift
                // Kept fresh rather than asserted once: evidence has a TTL, and a claim that expires
                // leaves the machine holding a state nothing is saying any more.
                if self.manualMeeting {
                    if let expiry = self.manualMeetingExpiresAt, self.timeSource.now >= expiry {
                        self.withdrawManualMeeting(isInstruction: false)
                    } else {
                        self.assertManualMeeting()
                    }
                }
                self.machine.tick()
```

- [ ] **Step 9: Keep the menu switch indefinite**

`MenuBarController.meetingSwitched(_:)` must go on passing no duration, so the switch behaves exactly as it does today. Confirm the call site still reads:

```swift
    @objc private func meetingSwitched(_ sender: NSSwitch) {
        monitor.setInMeeting(sender.state == .on)
    }
```

The new parameters all default, so no edit is needed. Verify rather than change.

- [ ] **Step 10: Verify**

Run: `make lint test`
Expected: 62 tests, 0 failures, no lint violations (58 today, plus three duration tests and one state-machine test).

Run: `xcodebuild -project MeetingFocus.xcodeproj -scheme MeetingFocus -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 11: Commit**

```bash
git add Sources/MeetingFocusCore/ManualMeeting.swift \
        Tests/MeetingFocusCoreTests/ManualMeetingTests.swift \
        Tests/MeetingFocusCoreTests/MeetingStateMachineTests.swift \
        Sources/MeetingFocusApp/MeetingMonitor.swift
git commit -m "Give a manual meeting a duration, and something to lapse into"
```

---

### Task 2: App Intents

Three actions in Shortcuts, Spotlight and `shortcuts run`, reaching the methods Task 1 produced.

**Files:**
- Create: `Sources/MeetingFocusApp/Intents/IntentBridge.swift`
- Create: `Sources/MeetingFocusApp/Intents/MeetingStateIntents.swift`
- Modify: `Sources/MeetingFocusApp/MeetingFocusApp.swift` (`applicationDidFinishLaunching`)
- Modify: `Sources/MeetingFocusApp/Localizable.xcstrings` (via `make xcstrings`)
- Modify: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: everything under "Produces" in Task 1.
- Produces, for Task 3: `IntentBridge.monitor: MeetingMonitor?` — the main-actor handle both surfaces use to reach the live monitor.

- [ ] **Step 1: Add the bridge**

Intents are instantiated by the system and have no other route to the live monitor. `AppDelegate` owns it strongly (`private(set) lazy var monitor`), so this holds it weakly.

Create `Sources/MeetingFocusApp/Intents/IntentBridge.swift`:

```swift
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
```

- [ ] **Step 2: Populate it at launch**

In `Sources/MeetingFocusApp/MeetingFocusApp.swift`, inside `applicationDidFinishLaunching`, after `_ = menuBar`:

```swift
        // Intents and scripting commands are built by the system and handed nothing; this is their
        // only route to the object this launch is about.
        IntentBridge.monitor = monitor
```

- [ ] **Step 3: Write the intents**

Create `Sources/MeetingFocusApp/Intents/MeetingStateIntents.swift`:

```swift
import AppIntents
import MeetingFocusCore

enum MeetingStateChoice: String, AppEnum {
    case inMeeting
    case notInMeeting

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Meeting State" }
    static var caseDisplayRepresentations: [MeetingStateChoice: DisplayRepresentation] {
        [.inMeeting: "In a meeting", .notInMeeting: "Not in a meeting"]
    }
}

enum MeetingFocusIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource {
        "MeetingFocus is still starting up. Try again in a moment."
    }
}

/// One action rather than separate Start and End actions: a shortcut that computes the state passes
/// it through, and a fixed button simply presets the parameter.
struct SetMeetingStateIntent: AppIntent {
    static var title: LocalizedStringResource { "Set Meeting State" }
    static var description: IntentDescription {
        IntentDescription("Tells MeetingFocus whether you are in a meeting, overruling what it has detected.")
    }

    @Parameter(title: "State")
    var state: MeetingStateChoice

    @Parameter(title: "Minutes", default: 60, inclusiveRange: (1, 480))
    var minutes: Int

    @Parameter(title: "Title")
    var meetingTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Set meeting state to \(\.$state) for \(\.$minutes) minutes") {
            \.$meetingTitle
        }
    }

    /// Returns when the claim lapses, so a caller that asked for more than the cap can see what it
    /// actually got rather than being silently corrected. Nil for "not in a meeting", which has no
    /// duration: it lasts exactly as long as the call it was said about.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Date?> {
        guard let monitor = IntentBridge.monitor else { throw MeetingFocusIntentError.notReady }
        switch state {
        case .inMeeting:
            monitor.setInMeeting(
                true,
                for: TimeInterval(minutes) * 60,
                source: "shortcuts",
                title: meetingTitle
            )
            return .result(value: monitor.manualMeetingExpiresAt)
        case .notInMeeting:
            monitor.setInMeeting(false, source: "shortcuts")
            return .result(value: nil)
        }
    }
}

/// Withdrawal, not dismissal — see `MeetingMonitor.withdrawManualMeeting(isInstruction:)`.
struct ClearMeetingOverrideIntent: AppIntent {
    static var title: LocalizedStringResource { "Clear Meeting Override" }
    static var description: IntentDescription {
        IntentDescription("Withdraws a manual claim and lets MeetingFocus go back to detecting. Leaves a detected meeting running.")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let monitor = IntentBridge.monitor else { throw MeetingFocusIntentError.notReady }
        monitor.withdrawManualMeeting(isInstruction: true)
        return .result()
    }
}

/// `isInMeeting` is a plain `Bool` because that is what makes a Shortcuts `If` block work without
/// string comparison, and it is the property most callers want.
struct MeetingStatusIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Meeting Status" }
    static var description: IntentDescription {
        IntentDescription("Reports whether MeetingFocus believes you are in a meeting.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        guard let monitor = IntentBridge.monitor else { throw MeetingFocusIntentError.notReady }
        let inMeeting = monitor.aggregateState == .inMeeting
        let name = monitor.activeMeetings.first.map { $0.title ?? $0.applicationName }
        let dialog: IntentDialog = if let name {
            IntentDialog("In a meeting: \(name)")
        } else {
            IntentDialog("Not in a meeting")
        }
        return .result(value: inMeeting, dialog: dialog)
    }
}
```

**API note, and the one thing in this plan to verify against the SDK rather than trust:** the spec asks for a richer status return (`state`, `title`, `isManual`, `expiresAt`) via a `TransientAppEntity`. The `Bool`-plus-dialog form above is the version that is certain to compile and covers what callers actually branch on. If `TransientAppEntity` turns out to be straightforward in this SDK, extend `MeetingStatusIntent` to return one carrying all five properties; if it fights you, ship the `Bool` and record the reduction in `CHANGELOG.md`. Do not spend more than one attempt on it.

- [ ] **Step 4: Build and confirm the metadata processor is satisfied**

Run: `xcodebuild -project MeetingFocus.xcodeproj -scheme MeetingFocus -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -i appintents`

Expected: the warning `Metadata extraction skipped. No AppIntents.framework dependency found.` is **gone**. `import AppIntents` autolinks the framework; if the warning persists, add `AppIntents.framework` to the target's `dependencies:` in `project.yml` and run `make generate`.

- [ ] **Step 5: Add the catalogue keys**

`LocalizedStringResource` literals are extracted like `String(localized:)`. Run `make xcstrings`, then add German for every new key: "Meeting State", "In a meeting", "Not in a meeting", "Set Meeting State", "Clear Meeting Override", "Get Meeting Status", "Minutes", "Title", "State", and the three `IntentDescription` sentences, the error sentence, and both dialog forms.

Run: `swift test --filter LocalizationTests`
Expected: 5 tests, 0 failures. This suite is what tells you the list above is complete — trust it over the list.

- [ ] **Step 6: Verify by hand**

```bash
make install && open /Applications/MeetingFocus.app
```

- Open Shortcuts, add an action, search "MeetingFocus". Expected: the three actions appear.
  **If they do not:** the system indexes an app's intents only once its bundle is registered with Launch Services. `make install` puts it in `/Applications`; launch it once, then re-check. This caveat is why Step 7 puts it in the README.
- Build a shortcut with `Set Meeting State → In a meeting for 5 minutes`. Run it. Expected: the menu bar switch turns on, the status row reads "In a meeting", and the configured start Shortcut runs.
- Check the returned expiry is five minutes out.
- Run `Set Meeting State → In a meeting for 100000 minutes`. Expected: the returned expiry is 8 hours out, not 100000 minutes.
- Run `Clear Meeting Override`. Expected: the switch turns off and the end Shortcut runs at once, not 45 seconds later.
- Start a real Teams call, run `Set Meeting State → In a meeting for 1 minute`, and wait it out. Expected: the Teams call is **still** in progress after the claim lapses. This is the failure Task 1's test guards; confirm it end to end.

- [ ] **Step 7: Document**

`README.md` — a section describing the three actions, and the Launch Services caveat verbatim: intents may not appear in Shortcuts until the app has been launched once from `/Applications`.

`CHANGELOG.md` — under `### Added`.

- [ ] **Step 8: Commit**

```bash
git add Sources/MeetingFocusApp/Intents Sources/MeetingFocusApp/MeetingFocusApp.swift \
        Sources/MeetingFocusApp/Localizable.xcstrings README.md CHANGELOG.md
git commit -m "Let a Shortcut set and read the meeting state"
```

---

### Task 3: AppleScript

The surface App Intents does not provide: `osascript`, `tell application`, and any Apple Events client.

**Files:**
- Create: `Resources/MeetingFocus.sdef`
- Create: `Sources/MeetingFocusApp/Scripting/ScriptingSupport.swift`
- Modify: `project.yml` (Info.plist keys), then `make generate`
- Modify: `docs/constraints.md`, `docs/architecture.md`, `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: `IntentBridge.monitor` from Task 2, and Task 1's `MeetingMonitor` methods.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Declare the scripting definition**

In `project.yml`, in the `info.properties` block for the `MeetingFocus` target, beside `NSAppleEventsUsageDescription`:

```yaml
        # Receiving Apple Events, which is the opposite direction from NSAppleEventsUsageDescription
        # above — that one covers this app *sending* them to Shortcuts.
        NSAppleScriptEnabled: true
        OSAScriptingDefinition: MeetingFocus.sdef
```

Run: `make generate`

- [ ] **Step 2: Write the sdef**

Create `Resources/MeetingFocus.sdef`. `Resources` is already a resources build phase in `project.yml`, so the file needs no further wiring.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE dictionary SYSTEM "file://localhost/System/Library/DTDs/sdef.dtd">
<dictionary title="MeetingFocus Terminology">
  <suite name="MeetingFocus Suite" code="MFcs" description="Reading and setting meeting state.">

    <class name="application" code="capp" description="The MeetingFocus application.">
      <cocoa class="NSApplication"/>
      <property name="in meeting" code="MFim" type="boolean"
                description="Whether MeetingFocus believes you are in a meeting.">
        <cocoa key="scriptingInMeeting"/>
      </property>
      <property name="meeting state" code="MFms" type="text" access="r"
                description="idle, joining or inMeeting.">
        <cocoa key="scriptingMeetingState"/>
      </property>
      <property name="meeting title" code="MFmt" type="text" access="r"
                description="What the meeting in progress is called, if anything.">
        <cocoa key="scriptingMeetingTitle"/>
      </property>
      <property name="manual" code="MFmn" type="boolean" access="r"
                description="Whether the current state was declared by hand rather than detected.">
        <cocoa key="scriptingManual"/>
      </property>
      <property name="override expires" code="MFoe" type="date" access="r"
                description="When a manual claim lapses, if it has a duration.">
        <cocoa key="scriptingOverrideExpires"/>
      </property>
    </class>

    <command name="set meeting state" code="MFcssms"
             description="Declare whether you are in a meeting, for a given number of minutes.">
      <cocoa class="SetMeetingStateCommand"/>
      <direct-parameter type="boolean" description="Whether you are in a meeting."/>
      <parameter name="for" code="MFfr" type="integer" optional="yes"
                 description="Minutes the claim stands. Defaults to 60, capped at 480.">
        <cocoa key="minutes"/>
      </parameter>
      <parameter name="titled" code="MFtt" type="text" optional="yes"
                 description="What to call the meeting.">
        <cocoa key="meetingTitle"/>
      </parameter>
    </command>

    <command name="clear meeting override" code="MFcsclr"
             description="Withdraw a manual claim and go back to detecting.">
      <cocoa class="ClearMeetingOverrideCommand"/>
    </command>

  </suite>
</dictionary>
```

Note the command `code` attributes are eight characters: the suite's four (`MFcs`) followed by four identifying the command. Properties take four.

- [ ] **Step 3: Implement the properties and commands**

`NSScriptCommand` is ObjC-runtime machinery in a project built with `SWIFT_STRICT_CONCURRENCY: complete`. Scripting callbacks arrive on the main thread but are not statically known to, hence `MainActor.assumeIsolated`.

Create `Sources/MeetingFocusApp/Scripting/ScriptingSupport.swift`:

```swift
import AppKit
import Foundation
import MeetingFocusCore

/// The `application` class the sdef describes. Cocoa Scripting resolves `<cocoa key="…"/>` by KVC
/// against `NSApp`, so the properties live here rather than on the delegate.
///
/// `assumeIsolated` throughout: Apple Events are delivered on the main thread, but nothing in the
/// type system says so, and the alternative under complete concurrency checking is to make every
/// accessor async — which KVC cannot call.
extension NSApplication {
    @objc var scriptingInMeeting: NSNumber {
        get { MainActor.assumeIsolated { NSNumber(value: IntentBridge.monitor?.aggregateState == .inMeeting) } }
        set {
            MainActor.assumeIsolated {
                IntentBridge.monitor?.setInMeeting(
                    newValue.boolValue,
                    for: newValue.boolValue ? ManualMeetingDuration.default : nil,
                    source: "applescript"
                )
            }
        }
    }

    @objc var scriptingMeetingState: String {
        MainActor.assumeIsolated { IntentBridge.monitor?.aggregateState.rawValue ?? MeetingState.idle.rawValue }
    }

    @objc var scriptingMeetingTitle: String {
        MainActor.assumeIsolated {
            guard let meeting = IntentBridge.monitor?.activeMeetings.first else { return "" }
            return meeting.title ?? meeting.applicationName
        }
    }

    @objc var scriptingManual: NSNumber {
        MainActor.assumeIsolated { NSNumber(value: IntentBridge.monitor?.manualMeeting ?? false) }
    }

    @objc var scriptingOverrideExpires: Date? {
        MainActor.assumeIsolated { IntentBridge.monitor?.manualMeetingExpiresAt }
    }
}

/// `set meeting state to true for 30` — the form that can name a duration. The writable
/// `in meeting` property above is the form anyone tries first, and takes the default hour.
final class SetMeetingStateCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let monitor = IntentBridge.monitor else { return nil }
            let inMeeting = (directParameter as? NSNumber)?.boolValue ?? false
            let arguments = evaluatedArguments ?? [:]
            let minutes = (arguments["minutes"] as? NSNumber)?.doubleValue
            let title = arguments["meetingTitle"] as? String

            if inMeeting {
                monitor.setInMeeting(
                    true,
                    for: minutes.map { $0 * 60 } ?? ManualMeetingDuration.default,
                    source: "applescript",
                    title: title
                )
            } else {
                monitor.setInMeeting(false, source: "applescript")
            }
            return nil
        }
    }
}

final class ClearMeetingOverrideCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            IntentBridge.monitor?.withdrawManualMeeting(isInstruction: true)
            return nil
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project MeetingFocus.xcodeproj -scheme MeetingFocus -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`.

If the `@objc` extension properties are rejected because `NSApplication` already declares a member of that name, rename the Swift property and the `<cocoa key="…"/>` together — they must match exactly.

- [ ] **Step 5: Verify by hand**

```bash
make install && open /Applications/MeetingFocus.app
osascript -e 'tell application "MeetingFocus" to get meeting state'
osascript -e 'tell application "MeetingFocus" to set in meeting to true'
osascript -e 'tell application "MeetingFocus" to get in meeting'
osascript -e 'tell application "MeetingFocus" to set meeting state to true for 5 titled "Deep work"'
osascript -e 'tell application "MeetingFocus" to get override expires'
osascript -e 'tell application "MeetingFocus" to clear meeting override'
```

Expected in order: `idle`; the menu bar switch turns on; `true`; the menu headline reads "Deep work" and the claim expires in five minutes; a date five minutes out; the switch turns off and the end Shortcut runs at once.

The first call raises an Automation prompt attributed to Terminal — that is the caller's TCC permission, and expected. Also open `/Applications/Script Editor.app`, `File → Open Dictionary…`, and pick MeetingFocus: the suite should render with all five properties and both commands. A malformed sdef fails silently by simply not appearing, so this is the check that catches it.

- [ ] **Step 6: Document**

`docs/constraints.md` — a new entry recording two things: that the sdef ships English-only because localizing one means a `.strings` file per `.lproj` that the String Catalogue tooling knows nothing about, and that a URL scheme was rejected in both directions (no return channel for reads; web-page-triggerable for writes).

`docs/architecture.md` — the inbound surfaces on the diagram, beside the detectors.

`README.md` — the AppleScript examples above.

`CHANGELOG.md` — under `### Added`.

- [ ] **Step 7: Commit**

```bash
git add Resources/MeetingFocus.sdef Sources/MeetingFocusApp/Scripting \
        project.yml MeetingFocus.xcodeproj/project.pbxproj \
        docs/constraints.md docs/architecture.md README.md CHANGELOG.md
git commit -m "Make MeetingFocus scriptable"
```

---

## Out of scope

Carried from the spec, so an executor does not add them on initiative: a URL scheme in either direction; passing meeting context as *input* to the outbound Shortcut; a localized sdef; persisting an override across relaunch; per-subject overrides.
