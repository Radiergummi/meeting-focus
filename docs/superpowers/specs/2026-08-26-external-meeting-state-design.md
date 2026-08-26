# Toggling meeting state from outside the app — design

Written against the manual override switch in the menu bar — `MeetingMonitor.setInMeeting(_:)`,
`MeetingStateMachine.dismissActiveMeetings()`, `MenuBarController.switchRow` — and building on it.

> **Landed while this was being written**, in 47b9f65: the switch itself, re-asserting the manual
> claim on the tick rather than ingesting it once, and `AutomationCoordinator.endImmediately()` so
> that switching off releases Focus at once instead of 45 seconds later. The sections below that
> describe those three are kept as the reasoning behind them; what remains to build is the duration,
> the withdraw operation, and the two external surfaces.

## The problem this is really solving

The app runs one user-configured Shortcut when it detects a meeting starting and another when it
detects one ending. Both directions of that flow are the app's own: it decides, it acts. Nothing
else on the machine can participate.

That closes off the automations the detectors will never cover. A phone call is a meeting. So is an
in-person conversation, a Zoom in a browser profile the audio allowlist has never heard of, a
recording session, an hour of deep work someone wants to defend the same way they defend a call. The
menu bar switch now answers all of those — but only if you are at the keyboard, looking at the menu
bar, at the moment it matters. A Stream Deck button, a calendar automation, a hotkey, a script that
knows something the app cannot: none of them can say so.

The reverse is also missing. Other automations cannot ask whether a meeting is in progress, so
"don't run the noisy backup while I'm on a call" has to be built by guessing from a calendar rather
than by asking the app that already knows.

## What is already in the tree

The manual switch answers most of the *mechanism* question, and answers it well:

- **On** ingests `definitive` evidence under a `"manual"` detector and subject, so the claim flows
  through fusion, the state machine, automation and the detection log exactly as a detected call
  does. `aggregateState` stays the single answer to the question.
- **Off** retracts that evidence and calls `dismissActiveMeetings()`, which ignores a subject's
  evidence for exactly as long as that evidence keeps claiming the meeting that was dismissed. So
  "I am not in a meeting" outranks every detector, and lasts precisely as long as the call it was
  said about — no timer, no cap, and no risk of pinning a subject shut so that the next real meeting
  in the same application never registers.

What is missing is any way to reach that mechanism from outside the app, and a duration.

## The three operations

Adding a duration exposes an operation the switch does not have. Today there are two — assert and
dismiss — and the second does double duty:

| Operation    | Meaning                              | Effect                                        |
| ------------ | ------------------------------------ | --------------------------------------------- |
| **Assert**   | "I am in a meeting"                  | Ingest `manual` definitive evidence            |
| **Withdraw** | "Never mind — go back to detecting"  | Retract `manual` evidence only                 |
| **Dismiss**  | "I am *not* in a meeting"            | Retract, and `dismissActiveMeetings()`         |

Withdraw and dismiss are different statements, and conflating them is a bug waiting for its first
user. If a manual override expires while a real Teams call is running, routing expiry through
`setInMeeting(false)` would dismiss the *Teams* meeting: a timer lapsing would silently suppress a
real, detected call for as long as it ran. **Expiry must withdraw, never dismiss.**

The three-way maps onto the external surface without forcing: `Set (in a meeting)`,
`Set (not in a meeting)`, `Clear`.

## Why not the obvious alternatives

**An override gate above the state machine.** A separate latch in `MeetingMonitor` holding a forced
state and its expiry, consulted in `refresh()` before publishing. This was the design until the
switch landed; it is now redundant, and it is worse. It would keep the machine's honest state
underneath the override — which sounds like a virtue and is not, because there is then no single
answer to "am I in a meeting" and every consumer has to know which one it wants. The evidence tier
already in the tree keeps `aggregateState` authoritative.

**A new `.override` confidence tier above `definitive`.** Everything would flow through fusion, and
`retractEvidence(fromDetector:)` would clear it. But `isInMeeting` is an OR across subjects, so a
manual "not in a meeting" still could not end a Teams call without also changing that — which means
perturbing `EvidenceFusion`, whose documented virtue is having deliberately few rules, and still
needing a second mechanism for the hard half. `dismissActiveMeetings()` solves it without touching
fusion at all.

**A URL scheme.** Considered and rejected. A custom URL scheme has no return channel — `open
meetingfocus://state` delivers the URL and returns immediately, so the one shape that would make it
worth having, reading state, is the shape it cannot do. And any web page you visit can fire a custom
URL, so the write direction is a drive-by risk for no benefit the other two surfaces do not already
provide. The app registers no scheme.

**A timed expiry in both directions.** Rejected for force-off, where `dismissActiveMeetings()`'s
episode scoping is strictly better: it self-clears, needs no countdown in the menu bar, and has no
cap to argue about. A duration earns its place only on force-on, which has no underlying episode to
scope to.

**Persisting an override across relaunch.** An override is a live, short-lived statement of intent.
Resurrecting a forced "not in a meeting" after an update or a crash would be surprising, and the
existing code already declines to persist the switch for the same reason. On launch, detection is
authoritative.

## The design

### Duration, optional everywhere

`setInMeeting(_:)` gains a duration and a source:

```swift
func setInMeeting(_ inMeeting: Bool, for duration: TimeInterval? = nil, source: String = "menu")
```

`nil` means indefinite. **The menu switch passes `nil`, so its behaviour is exactly as built** — a
person at the keyboard can flip it back. The intents and AppleScript default to 60 minutes and clamp
at 8 hours, because an automation may not be watching, and a caller-settable duration otherwise
invites `minutes: 100000` and reintroduces through the back door the footgun the duration exists to
close. The clamped value is returned rather than silently applied, so an automation can see what it
actually got.

### Re-assert rather than ingest once

`assertManualMeeting()` currently ingests one piece of evidence. After `evidenceTTL` that evidence is
stale, `EvidenceFusion.resolve` returns nil for the `"manual"` subject, and the claim survives only
because `evaluate()` holds the previous state when nothing is resolvable. That reaches the right
answer through a rule about *unreadable* evidence rather than by saying what it means, and it leaves
nowhere for an expiry to live.

Instead, re-assert on the tick that already runs each second, until the expiry passes. Lapsing is
then simply: stop asserting, and let the subject resolve to idle on its own, through the ordinary
path with the ordinary grace.

### Ending automation immediately on an explicit dismiss

`dismissActiveMeetings()` ends the meeting authoritatively, but `refresh()` then feeds
`isInMeeting: false` to `AutomationCoordinator`, which sets `pendingEnd` and waits out `endCooldown`.
So flipping the switch off leaves the user's Focus mode on for 45 seconds.

That cooldown exists to absorb the measured gap between back-to-back meetings — a detector artefact.
A person saying "I'm done" is not that artefact, and a switch that appears to do nothing for three
quarters of a minute reads as broken. `AutomationCoordinator` gains an authoritative end, mirroring
the precedent `MeetingStateMachine.applicationTerminated` already sets.

The rule, stated once and applied everywhere:

> **An explicit instruction acts immediately. A timer lapsing uses the normal cooldown.**

So dismiss and clear bypass the cooldown; an expiry does not. That last part is deliberate: the
likeliest expiry is a forced meeting for a call that ran long, where the user re-forces it or a real
meeting starts moments later, and absorbing that gap is precisely what the cooldown is for.

### Surfaces

**App Intents**, in the main binary rather than an extension — the app is `LSUIElement` and always
resident, so an extension buys nothing.

- `SetMeetingStateIntent` — an `AppEnum` parameter (in a meeting / not in a meeting), plus optional
  duration and title, with a `ParameterSummary` so the action reads as a sentence: *"Set meeting
  state to In a meeting for 60 minutes."* One action rather than separate Start and End actions: a
  shortcut that computes the state passes it through, and a fixed button just presets the parameter.
  Returns the effective expiry.
- `ClearMeetingOverrideIntent` — withdraw. Hands control back to the detectors.
- `MeetingStatusIntent` — returns `isInMeeting`, `state`, `title`, `isManual`, `expiresAt`.
  `isInMeeting` as a plain `Bool` is what makes a Shortcuts `If` block work without string
  comparison, and is the property most callers want.

**AppleScript**, via `NSAppleScriptEnabled` and an `OSAScriptingDefinition` pointing at a
hand-authored `MeetingFocus.sdef`. Read-only properties — `meeting state`, `in meeting`, `manual`,
`override expires`, `meeting title` — plus commands for the writes. `in meeting` is *also* writable,
using the 60-minute default, because `tell application "MeetingFocus" to set in meeting to true` is
the form anyone will try first; the command exists for when a duration must be named.

Two things to expect rather than discover. Intents are instantiated by the system and must reach the
live `@MainActor MeetingMonitor`, which needs a small main-actor registry the app populates at
launch — the one inelegant piece of this design, and unavoidable. And the system indexes an app's
intents only once its bundle is registered with Launch Services, so intents may not appear in
Shortcuts until the app has been launched once from `/Applications`; given Sparkle distribution that
belongs in the README.

`NSScriptCommand` is ObjC-runtime machinery — `NSObject`, `@objc`, KVC accessors — in a project built
with `SWIFT_STRICT_CONCURRENCY: complete`. Scripting callbacks arrive on the main thread but are not
statically known to, so each entry point needs `MainActor.assumeIsolated`. This is the highest
friction part of the work: fiddly rather than hard.

### Localization

Intent titles, parameter names and dialogs are `LocalizedStringResource` and land in the String
Catalogue like everything else; the coverage tests will demand the German. An sdef is XML, and
localizing one means a `.strings` file per `.lproj` that the catalogue tooling knows nothing about.
**The sdef ships English-only**, recorded in `docs/constraints.md` as a known asymmetry, rather than
building a second localization pipeline for one file.

`recentEvents` gains a source — "Manual meeting (shortcuts)" versus "(menu)" — which is exactly the
line that answers "why did Focus turn on" when the answer is an automation the user forgot they
wrote. Those go in as plain literals, matching what `note()` already does; the ⌥ read-out is not
localized today and this work does not change that as a side effect.

## Components

### 1. `Sources/MeetingFocusCore/Automation.swift` — landed
`AutomationCoordinator.endImmediately()`: clears `pendingEnd`, sets state to idle, emits
`.meetingEnded` for `lastMeeting`. No-op when already idle, so a repeated call cannot double-end.

### 2. `Sources/MeetingFocusApp/MeetingMonitor.swift`
- `setInMeeting(_:for:source:)` — the duration and source are new; the dismiss branch already calls
  `coordinator.endImmediately()`.
- `withdrawManualMeeting()` — retract only, for expiry and for `Clear`. **This is the new operation
  the duration exposes, and the one that must not be confused with dismiss.**
- `manualMeetingExpiresAt: Date?`, and the lapse check beside the re-assertion already in
  `startTicking()`.
- `assertManualMeeting()` carries the source into the detection log.

### 3. `Sources/MeetingFocusApp/Intents/`
`MeetingStateIntents.swift` (the three intents), `MeetingStatusEntity.swift`, and a main-actor
registry the app populates at launch so an intent can reach the live monitor.

### 4. `Resources/MeetingFocus.sdef` and `Sources/MeetingFocusApp/Scripting/`
The scripting definition, plus `NSScriptCommand` subclasses and the KVC-compliant properties they
read.

### 5. `project.yml`
`NSAppleScriptEnabled: true` and `OSAScriptingDefinition: MeetingFocus` in the Info.plist block.
No `CFBundleURLTypes` — see the rejected alternatives.

### 6. Strings
Intent metadata into `Localizable.xcstrings`, en and de.

## Verification

In `swift test`:

- `endImmediately()` ends with no cooldown, cancels a pending end, and does not double-end against an
  already-idle coordinator — landed in `AutomationCoordinatorTests`.
- A withdrawn manual claim leaves a live meeting on another subject alone. This is the test most
  worth having: it is the difference between withdraw and dismiss, and the failure it catches is
  silent.
- `dismissActiveMeetings()` releases its subject once that subject's evidence stops claiming a
  meeting — already covered by the in-flight `MeetingStateMachineTests` changes; confirm it survives.

By hand, the way `docs/architecture.md` already records detectors being verified:

- The Set action appears in Shortcuts and runs; the returned expiry reflects the clamp.
- `osascript -e 'tell application "MeetingFocus" to get in meeting'` returns the right answer, and
  the write form takes effect.
- Flipping the switch off runs the end shortcut immediately, not 45 seconds later.
- A manual meeting set for one minute lapses on its own, and lapsing while a Teams call is running
  leaves that call in progress.

## Out of scope

- A URL scheme, in either direction.
- Passing meeting context (title, application, duration) as *input* to the outbound Shortcut.
  `shortcuts run` can take input; nothing in this design needs it, and it is a separate decision.
- A localized sdef.
- Persisting an override across relaunch.
- Per-subject overrides — "ignore Teams but let Zoom count". No use case has asked for it.

## Documentation to update on landing

- `README.md`: the two surfaces, and the Launch Services caveat about intents appearing.
- `docs/constraints.md`: the English-only sdef asymmetry; the rejection of the URL scheme and why.
- `docs/architecture.md`: the external surfaces on the inbound side of the diagram.
- `CHANGELOG.md`.
