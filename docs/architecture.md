# Architecture

```
Meeting application          App Intents (Shortcuts) · AppleScript (osascript, `tell application`)
      │                                        │
      ▼                                        ▼
MeetingDetector  ──emits──▶  MeetingEvidence  ◀──asserts──  MeetingMonitor (manual claim)
      │
      ▼
EvidenceFusion   ──resolves per subject──▶  one verdict
      │
      ▼
MeetingStateMachine  ──debounces──▶  MeetingEvent (.started / .ended)
      │
      ▼
AutomationCoordinator  ──cooldown──▶  AutomationCommand
      │
      ▼
AutomationHandler  ──▶  Shortcuts (today) · Apple Events, webhooks, … (later)
```

## Why it is split this way

**Detectors do not decide anything.** They report what they can see and how much it should be
trusted. Everything that decides lives in `MeetingFocusCore`, which has no AppKit, Accessibility
or network dependency at all — that is what makes the state machine testable without Teams
installed, and it enforces the separation structurally rather than by convention.

**Confidence, not priority.** Each piece of evidence carries a `Confidence`. Within one subject the
highest confidence present wins. This single rule is what lets a precise app-specific detector
override a coarse generic one — concretely, why muting your microphone does not end a Teams
meeting — without either detector knowing the other exists.

**`indeterminate` is a first-class verdict.** "I could not read the accessibility tree" is not
"there is no meeting". Only the latter may end a meeting; the former holds the previous state.
Without this distinction, every transient hiccup would fire a spurious end.

**Detection time and automation time are different.** The UI must reflect reality immediately.
Automation must not, because back-to-back meetings are normal and flapping a Focus mode between
two calls is worse than reacting slowly. `AutomationCoordinator` holds an end for `endCooldown`
and cancels it if a new meeting begins.

**A manual claim is evidence, not a special case.** The menu switch, an App Intent and an
AppleScript command all resolve to the same call — `MeetingMonitor.setInMeeting` — which asserts
or retracts `definitive`-confidence evidence from a synthetic `"manual"` detector. It competes for
precedence exactly like Teams or the microphone tier rather than bypassing fusion, which is why
declaring a meeting by hand outranks every detector rather than merely overriding the UI.

## Modules

| Path | Contents |
|---|---|
| `Sources/MeetingFocusCore` | `Meeting`, `MeetingEvidence`, `EvidenceFusion`, `MeetingStateMachine`, `AutomationCoordinator`, `FocusShortcut`, protocols. Pure logic, no platform APIs |
| `Sources/MeetingFocusApp/Detectors` | `TeamsAccessibilityDetector`, `AudioProcessDetector`, `BundleIdentifierResolver`, marker loading |
| `Sources/MeetingFocusApp/Accessibility` | `AXElement` wrapper, permission handling, `AXChangeObserver` |
| `Sources/MeetingFocusApp/Automation` | `ShortcutsAutomationHandler`, `FocusShortcutInstaller` |
| `Sources/MeetingFocusApp/Intents` | `IntentBridge` (weak link to the live `MeetingMonitor`), the three App Intents |
| `Sources/MeetingFocusApp/Scripting` | `ScriptingSupport` — the Cocoa Scripting properties and commands the sdef describes |
| `Resources/MeetingFocus.sdef` | The AppleScript dictionary: `tell application "MeetingFocus"` terminology, English-only (see `docs/constraints.md` C8) |
| `Sources/MeetingFocusApp/UI` | `MenuBarController` (the status item and its menu, in AppKit — see the type's own note for why not `MenuBarExtra`), `SettingsView` |
| `Sources/MeetingFocusApp/UI/Onboarding` | `OnboardingView`, `OnboardingFocusStep`, `OnboardingPage`, `WindowChrome` — the first-run window that installs the Focus shortcuts |
| `Sources/MeetingFocusApp` | `MeetingMonitor` (wiring), `AppSettings`, app entry |
| `Resources/teams-markers.json` | Teams element ids, as data so they can be patched |
| `Resources/focus-shortcut.json` | The Set Focus action's identifier and parameter shape, as data so they can be patched |

## Extension points

### Adding a meeting application

Implement `MeetingDetector` and register it in `MeetingMonitor.start()`. Nothing else changes —
not the state machine, not the fusion rules, not the UI.

- **Electron/Chromium apps** (Slack): the `AXDOMIdentifier` approach should transfer directly.
- **Native apps** (Zoom): expect a different tree shape and study it with `axprobe` first.
- **Browsers**: tabs are enumerable as `AXTabButton` with titles, and web areas expose `AXURL`.
  Use those to *name* a meeting; use the audio tier to know one is running. Where several
  capturing tabs are open, drop the identity and keep the state — ambiguity must not guess.

Emit `definitive` confidence only if the detector observes the meeting UI itself.

### Adding an automation backend

Implement `AutomationHandler`. The coordinator already emits `AutomationCommand` values, so a
webhook or shell backend is additive.

Note that there is **no public API to set a Focus mode** on macOS. `INFocusStatusCenter` is
read-only. Shortcuts is the only supported route, which is why it is the first backend rather
than a convenience.

The Shortcuts backend now also *generates and installs* the shortcut it later runs, rather than
asking the user to author one by hand: `Automation/FocusShortcutInstaller.swift` builds a plist
from `Resources/focus-shortcut.json`, signs it with the user's own copy of `/usr/bin/shortcuts`,
and hands it to Shortcuts for the one confirmation macOS requires. See `docs/constraints.md` A4 and
C4 for why the recipe has no Focus name baked in.

### Adding a remote presence source

The evidence model already accommodates it: use a subject namespace of your own
(`"remote:msgraph"`), emit `corroborating` confidence, and remember that such evidence describes
the *user* rather than this Mac. See `docs/constraints.md` for the researched transports.

## Testing

`MeetingFocusCore` reads time only through an injected `TimeSource` and is driven by `ingest` and
`tick` rather than internal timers, so every debounce, cooldown and precedence rule is tested with
no sleeping and no real applications:

```sh
xcodebuild -project MeetingFocus.xcodeproj -scheme MeetingFocusCoreTests -destination 'platform=macOS' test
```

Detectors themselves depend on live applications and are verified manually.
