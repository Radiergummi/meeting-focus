# MeetingFocus — design

**Status:** awaiting review · **Date:** 2026-08-25

A macOS menu bar app that detects when the user is actually participating in a meeting and
invokes user-configured Shortcuts when that state changes.

Findings that this design rests on are recorded in
[`docs/teams-accessibility.md`](../../teams-accessibility.md); the constraints it must respect,
and which of them could corner us, are tracked in [`docs/constraints.md`](../../constraints.md).

## 1. Goal and non-goal

Goal: know, correctly and automatically, whether the user is in a meeting — using whatever
signal is available — and expose that to macOS automation.

Explicit non-goal: being clever about *one* application. The brief started Teams-only; research
showed the interesting problem is signal fusion, because every individual signal has a failure
mode that another signal covers.

## 1a. Product framing and distribution

**Positioning:** "automations that fire when you join or leave a meeting", with Focus-toggling as
the headline recipe rather than the mechanism. The distinction is load-bearing — see the Focus
constraint below.

**Distribution:** Developer ID signed, **notarized and stapled**, shipped as a DMG attached to a
GitHub release. Chosen decisions:

- **The Mac App Store is deferred indefinitely.** App Sandbox categorically blocks cross-app
  Accessibility calls and no entitlement unlocks it; the Mac App Store requires the sandbox.
  Magnet/Divvy/BetterSnapTool only predate the mandate. A sandboxed SKU would therefore lose the
  Teams AX detector entirely.
- Verified during investigation: the **CoreAudio per-process audio API does work inside App
  Sandbox** (measured with a signed sandboxed bundle — 40 process objects, 37 bundle IDs
  readable, correct attribution of a capturing process). So a reduced sandboxed SKU remains
  possible later, running audio-only, without redesign. The evidence model already supports it as
  a build-time detector subset.
- **iOS is out of scope, permanently for this use case.** There is no mechanism on iOS to observe
  another app's meeting state, and no background execution model to poll one. It is also
  unnecessary: **Focus syncs across Apple devices**, so a Focus set on the Mac silences the
  iPhone. This is a marketing claim we can make honestly without shipping an iOS app.
- DMG rather than `.pkg` for M1: idiomatic for a menu bar utility and simpler to notarize. A
  `.pkg` becomes worthwhile only if we later want to pre-register the login item.

**Requires from the maintainer** (cannot be automated here): an App Store Connect API key or an
app-specific password for `notarytool`, to notarize release builds.

## 1b. The Focus constraint

There is **no public API to set or toggle a Focus mode** on macOS or iOS. `INFocusStatusCenter`
is read-only — it reports whether *some* Focus is active, not which one, and requires the
Communication Notifications capability. Requests for a write API have gone unanswered for years.

Consequently "first-party Focus integration" is not implementable with public APIs, and doing it
privately would be both fragile and unshippable. What is actually achievable, and what this
design adopts, is removing the *setup friction* rather than the Shortcut itself:

1. Ship a prepared `.shortcut` file in the bundle ("MeetingFocus — Set Focus").
2. Offer a one-click "Install Focus automation" button in Settings which opens it; the user
   confirms once in Shortcuts.
3. The app then invokes it by name like any other shortcut.

The user never authors an automation, and we stay entirely within supported API. This is the same
approach a Mac App Store window manager used successfully to delegate privileged work to
Shortcuts.

## 2. Signal inventory

Measured or researched during investigation. "Confidence" is this design's term for how much a
signal is allowed to influence the outcome.

| Signal | API | Scope | Confidence | Failure mode |
|---|---|---|---|---|
| Teams meeting UI | Accessibility, `AXDOMIdentifier` | one app | **definitive** | vendor renames ids |
| Per-process microphone | CoreAudio process objects (14.4+) | any local app | **corroborating** | mute (unresolved); Bluetooth under-reporting; app holds mic outside meetings |
| Device-level microphone | `kAudioDevicePropertyDeviceIsRunningSomewhere` | system | **rejected** | no attribution — dictation tools indistinguishable from meetings |
| Camera | CoreMediaIO `…IsRunningSomewhere` | system | **not used in M1** | no public per-process API; many meetings are camera-off |
| Provider presence | Microsoft Graph / Zoom / Slack, OAuth | the *user* | **corroborating** | latency, tenant restrictions, describes user not device |
| Browser tab titles | Accessibility, `AXTabButton` | browser tabs | **enrichment only** | ambiguous when several capturing tabs are open |

Two properties make the fusion worthwhile rather than merely additive:

- The AX tier is **immune to mute**; the audio tier is not.
- The audio tier reaches **browser-based meetings** (Google Meet, Teams web), where there is no
  app UI to inspect; the AX tier cannot.

## 3. Evidence model

Detectors do not decide state. They report evidence; one fusion layer decides. This is the
central design decision and what makes new signals cheap to add.

```swift
enum Verdict: Sendable { case inMeeting, notInMeeting, indeterminate }
enum Confidence: Sendable, Comparable { case corroborating, definitive }

struct MeetingEvidence: Sendable, Equatable {
    let detectorID: String
    let subjectID: String        // usually a bundle id; "remote:msgraph" for provider tiers
    let verdict: Verdict
    let confidence: Confidence
    let title: String?
    let externalID: String?
    let startedAt: Date?         // e.g. derived from Teams' call-duration element
    let observedAt: Date
}
```

`indeterminate` is load-bearing. It is the difference between "the tree says there is no meeting"
and "I could not read the tree" — the latter must never end a meeting. This is how the
"cope with temporary loss of accessibility information" requirement is actually satisfied.

The `Meeting` model produced by fusion carries what the brief requires, and stays extensible:

```swift
struct Meeting: Sendable, Equatable, Identifiable {
    let id: UUID
    let applicationName: String       // "Microsoft Teams"
    let applicationBundleID: String   // "com.microsoft.teams2"
    let detectorID: String            // which detector established it
    let startedAt: Date               // measured, not inferred, where the signal allows
    var endedAt: Date?
    var title: String?                // meeting subject, when exposed
    var externalID: String?           // provider meeting id, when obtainable
    var confidence: Confidence        // how it was established
}
```

Detector interface:

```swift
protocol MeetingDetector: Sendable {
    var id: String { get }
    var evidence: AsyncStream<MeetingEvidence> { get }
    func start() async throws
    func stop() async
}
```

An `AsyncStream` replaces the brief's escaping closure: it composes with structured concurrency
and gives cancellation for free.

## 4. Fusion rules

Deliberately small enough to hold in your head and to test exhaustively.

1. Group evidence by `subjectID`.
2. Within a subject, the **highest-confidence non-`indeterminate`** verdict wins. So Teams AX
   saying `inMeeting` beats audio saying `notInMeeting` (the mute case). Audio alone still
   establishes a meeting for apps with no AX detector.
3. `indeterminate` never changes a subject's state; the previous state persists.
4. Aggregate state is `inMeeting` if **any** subject is `inMeeting`. This gives the required
   overlapping Teams + Zoom behaviour.
5. App termination (`NSWorkspace.didTerminateApplicationNotification`) is authoritative and
   resolves that subject to `notInMeeting` immediately, bypassing grace.

6. **Ambiguity suppresses rather than guesses.** Where a signal cannot be attributed to one
   meeting — most concretely, several browser tabs capturing at once — the ambiguous *identity* is
   dropped while the *state* is kept. We still know a meeting is running; we simply decline to
   name it. Wispr Flow arrived at the same rule independently (see the findings document), and it
   is the correct default for anything driving automation.

Title/identity resolution is strictly separate from state resolution. Nothing that only enriches
a title may ever influence whether a meeting is considered active. This keeps calendar data and
browser tab titles from being able to cause a false start or a false end.

The `joining` / lobby state is tracked and shown in the UI but **does not trigger automation**. A
26-second lobby was measured; firing automation there would enable Focus before the user has
actually joined.

Debounce, per subject: **1 s** to confirm a start, **5 s** to confirm an end. A subject
established only by corroborating evidence uses a longer start debounce (3 s) to absorb
transient microphone activity.

## 5. Events and automation

Per-meeting `MeetingEvent.started/.ended` are emitted for the UI and the log. Automation fires
only on **aggregate edges** — `false → true` and `true → false`. That is what makes
"exactly once per meeting" hold when meetings overlap.

### Automation latency is not detection latency

Measured on 2026-08-25: a "Daily" meeting ended at 11:24:47 and a 1:1 call began at 11:24:59 —
**12 seconds of genuine idle between two real meetings**. Detection handled this correctly, but
naively forwarding both edges to automation would disable and re-enable Focus within 12 seconds,
flooding the user with notifications in the gap. Back-to-back meetings are the normal case in a
working day, not an edge case.

So the two concerns are separated:

- **Detection state** updates as fast as the signal allows (1 s start / 5 s end grace). The menu
  bar reflects reality immediately.
- **Automation** applies an additional `endCooldown` (default **45 s**) after the aggregate goes
  false. If a new meeting starts within the cooldown, the pending `meetingEnded` is **cancelled**
  and no `meetingStarted` is fired either — the automation simply never learns the gap happened.

This makes the automation contract "Focus stays on across a run of meetings, and releases once
you are actually done", which is what the user wants, rather than a literal transcription of
every edge. `endCooldown` is configurable, and settable to 0 for literal edge behaviour.

```swift
protocol AutomationHandler: Sendable {
    func meetingStarted(_ meeting: Meeting) async
    func meetingEnded(_ meeting: Meeting) async
}
```

M1 implementation runs `/usr/bin/shortcuts run <name>` via `Process`. `Info.plist` must carry
`NSAppleEventsUsageDescription`: driving Shortcuts can raise an Automation TCC prompt attributed
to MeetingFocus, and a missing usage string turns that into a silent denial. Chosen over
`shortcuts://run-shortcut?name=` because it returns an exit code, so a wrong shortcut name
surfaces as a visible error instead of silence; and over AppIntents, which has no public API to
run an arbitrary *user* shortcut by name. Calls are serialized, run off the state machine's
actor, and time out.

## 6. Structure

```
project.yml                       → MeetingFocus.xcodeproj (both committed)
Sources/MeetingFocusCore/         no AppKit, no AX, no network — this is what tests import
    Meeting.swift, MeetingState.swift, MeetingEvidence.swift
    MeetingStateMachine.swift, EvidenceFusion.swift
    Clock.swift, AutomationHandler.swift, MeetingDetector.swift
Sources/MeetingFocusApp/
    MeetingFocusApp.swift (LSUIElement), MenuBarView.swift, SettingsView.swift
    Detectors/TeamsAccessibilityDetector.swift
    Detectors/AudioProcessDetector.swift
    Accessibility/AXElement.swift, AccessibilityAuthorization.swift
    Automation/ShortcutsAutomationHandler.swift
    Diagnostics/Log.swift
Sources/axprobe/                  the diagnostic CLI that produced the findings
Tests/MeetingFocusCoreTests/
```

`MeetingFocusCore` having no platform dependencies is what enforces the brief's
detector/state-machine separation structurally rather than by convention, and lets the required
tests run without Teams installed.

## 7. Detectors in M1

**`TeamsAccessibilityDetector`** — `NSWorkspace` for lifecycle; `AXObserver` notifications to
trigger a coalesced (250 ms) rescan; bounded poll as the correctness base (2 s while in a
meeting, 5 s idle) because notification-only join detection is not yet proven. Scan matches only
on `AXDOMIdentifier`, never localized text.

**Marker definitions live in a bundled JSON resource, not in Swift source.** This is the mitigation
for the project's largest risk: Teams can rename its HTML ids at any release, and a data-only fix
is fast to ship, easy to review, and patchable by a user in a pinch. It is also the seam that would
later allow a remote marker manifest without redesign.

Traversal bounds must be generous, not tight: observed whole-app node counts ranged from **250 to
3,479** depending on what the main window was showing (a Chat window full of notifications is far
larger than a meeting window). An earlier draft of this design proposed a ~3,000 node cap, which
would have truncated the 3,479-node case and produced a **false negative**. The cap is therefore
25,000 nodes with depth ≤ 70, relying on early exit for cost: the scan stops at the first
`call-duration-custom` hit, and meeting windows are visited before the main window. Emits `startedAt` derived from
`call-duration-custom`, and `title` from the window title minus the ` | Microsoft Teams` suffix.
Emits `indeterminate` when the process is alive but the tree cannot be read.

**`AudioProcessDetector`** — enumerates CoreAudio process objects, **normalises each process to its
owning application** (mandatory — see below), filters to a configurable bundle-ID allowlist (Teams, Zoom, Slack, Webex, Discord, Chrome, Safari, Firefox, Edge, Arc, Dia), reports
`inMeeting`/`corroborating` for any allowlisted process with `IsRunningInput == 1`. Uses
`AudioObjectAddPropertyListenerBlock` for change notifications rather than polling. The
allowlist is what prevents dictation tools such as Wispr Flow from registering as meetings.

**Bundle-ID normalisation is not optional.** CoreAudio reports the *helper* process
(`com.microsoft.teams2.modulehost`), not the app. Since fusion groups evidence by `subjectID`,
un-normalised ids make Teams appear as several unrelated meetings and prevent the AX detector's
definitive verdict from overriding audio evidence. Resolve `proc_pidpath(pid)`, walk to the
**outermost** enclosing `.app`, and read its `Info.plist`. Do **not** use
`NSRunningApplication(processIdentifier:)` as the primary lookup — Teams' helpers are themselves
registered `.app` bundles, so it returns the helper's own id and defeats the normalisation
(verified 2026-08-25). Processes with no `.app` ancestor resolve to `nil`, which correctly excludes
system daemons such as `com.apple.CoreSpeech`.

## 8. Provider APIs (M2, designed for now)

Researched and deliberately deferred, because a corporate tenant can simply refuse the app
registration — and that is exactly the account where the meetings happen. The remote tier must
therefore be an enhancement, never the foundation.

| Provider | Signal | Transport for a desktop app |
|---|---|---|
| Microsoft Graph | `presence.activity` = `InAMeeting` / `InACall` | poll `GET /me/presence` (`Presence.Read`). Subscriptions need a public HTTPS endpoint and expire hourly |
| Slack | `user_huddle_changed` | **Socket Mode** — WebSocket, no public endpoint |
| Zoom | `user.presence_status_updated` | webhooks need an endpoint; WebSocket transport exists. Reported inconsistent between desktop and mobile |
| Google Meet | conference started/ended | Workspace Events API + Pub/Sub — heaviest |

Design consequences already accounted for in the evidence model: remote evidence carries a
`subjectID` of its own (`"remote:msgraph"`), is `corroborating` only, and — because it describes
the *user* rather than this Mac — is gated behind a setting for whether meetings on other
devices should count. Graph's `InAMeeting` may be partly calendar-derived; that must be verified
before it is trusted, or it will fire for meetings the user never joined.

Calendar access (EventKit locally, or a provider calendar API) is worth having for **titles
only** — matching an active meeting to a scheduled event gives a human-readable name. It must not
be used to infer state: a scheduled meeting is not an attended one. Wispr Flow's documentation
reflects the same split.

OAuth tokens go in the Keychain, never `UserDefaults`.

## 9. UI, settings, permissions

`MenuBarExtra`, `LSUIElement`, showing monitoring state, current meeting state, detected
application, start time, automation status, Settings, Quit. The menu bar icon reflects state, so
meeting start/end is visible at a glance; an option hides the icon for users who want it invisible.

**Not a separate background agent.** `SMAppService.agent` was considered and rejected: a second
binary needs its **own** Accessibility grant, doubling permission friction, and a headless agent
cannot explain why it is asking or show that it has broken. Launch-at-login uses
`SMAppService.loginItem` on the single app instead — same persistence, half the moving parts, and
permission failures stay diagnosable by the user.

Settings (`@AppStorage`, no database): per-detector enable, start/end Shortcut names, automation
enable, debug mode.

Accessibility permission: state shown explicitly, prompt via
`AXIsProcessTrustedWithOptions`, button opening
`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`. When missing,
the AX detector reports `indeterminate` and the UI says so — the app degrades to the audio tier
rather than failing silently. Signed with Developer ID `TH593VRB6W` so the grant survives rebuilds.

`os.Logger` under subsystem `com.matchory.MeetingFocus`, categories `detector`, `accessibility`,
`state`, `automation`.

## 10. Testing

`MeetingFocusCore` is pure and clock-injected, so all of these are deterministic with no sleeps:

1. idle → inMeeting
2. inMeeting → idle
3. transient detection loss (`indeterminate` does not end a meeting)
4. duplicate detector events collapse to one transition
5. Teams + Zoom overlap — aggregate stays `inMeeting` until the last ends
6. app termination while in a meeting ends immediately
7. detector restart
8. automation fires exactly once per aggregate edge
9. definitive `inMeeting` overrides corroborating `notInMeeting` (the mute case)
10. corroborating evidence alone can establish a meeting, with the longer debounce
11. **back-to-back meetings**: a gap shorter than `endCooldown` produces no automation calls at
    all — neither `meetingEnded` nor a second `meetingStarted` (regression test for the measured
    12-second gap)
12. a gap longer than `endCooldown` produces exactly one `meetingEnded` then one `meetingStarted`

Teams and audio detectors are verified manually via `axprobe`; both depend on live applications
and are not automatable here.

## 11. Open questions

1. **Does Teams release the microphone when muted?** Deferred by decision until a sandboxed build
   is attempted. Recorded consequence: fusion rule 2 means **Teams is unaffected** (its AX
   evidence is definitive and overrides audio). But apps covered *only* by the audio tier —
   Zoom, Slack, browser meetings — would end early on mute if the stream is released. This is a
   documented limitation of the generic tier in M1, not a blocker. Mitigation if it bites: add
   hysteresis from "process running + recent capture history" rather than instantaneous state.
2. **Bluetooth input reporting.** Needs a test with a real headset.
3. **Is Graph's `InAMeeting` calendar-derived?** Blocks M2.
4. **Join-by-notification.** Whether `AXObserver` alone can catch a join, allowing the poll to be
   slowed further.

## 12. Milestones

- **M1** — Teams AX detector, generic audio detector, fusion + state machine, Shortcuts
  automation, menu bar, settings, permission handling, unit tests, docs.
- **M1.5** — notarized DMG release pipeline, **Sparkle auto-update with an EdDSA-signed appcast**
  (without it, a Teams id rename is unfixable in the field), bundled Focus shortcut + one-click
  install, `SMAppService.loginItem` launch-at-login.
- **M2** — one provider integration end to end (Graph or Slack), Keychain, OAuth.
- **M3** — native Zoom and Slack AX detectors; a browser tier that names meetings from tab
  titles; camera corroboration if it proves useful.

A deliberate simplification for the browser case: Wispr Flow needs *per-tab* precision because it
binds a recording to one specific meeting. MeetingFocus needs only a boolean plus an optional
title, so browser-level audio capture is already sufficient for state, and tab titles are pure
enrichment. We should not build tab-level state tracking we have no use for.
