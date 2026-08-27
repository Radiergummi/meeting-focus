# Detecting meetings in apps other than Teams — design

Written against `TeamsAccessibilityDetector`, `TeamsMarkers` and `Resources/teams-markers.json`, and
generalising all three. Closes backlog item 11 for Slack; leaves it open for Zoom.

## The problem this is really solving

Zoom, Slack, Discord, Google Meet and Webex are **already detected**. `Resources/audio-allowlist.json`
ships every one of their bundle identifiers, and `AudioProcessDetector` resolves helper processes back
to the owning application, so Zoom's `CptHost` and Chrome's renderers attribute correctly.

What they lack is not detection. It is *first-class* detection:

- `corroborating` confidence, so any definitive detector for the same subject overrides them
- no meeting title
- no `joining` state
- vulnerability to whatever muting does to the microphone stream (backlog item 5, unmeasured)

Teams has a definitive detector and nothing else does. The goal is parity for the tools people
actually hold meetings in — not a detector per application in the allowlist.

## What was decided, and what was rejected

**Discord stays on the audio tier**, deliberately. Discord has no concept of a meeting: you are
connected to a voice channel or you are not, and people sit in voice channels for hours doing
something else. A definitive `inMeeting` for "connected to voice" would be exactly right about
Discord's state and possibly wrong about the user's, and because it is definitive it would outrank
the audio tier rather than be corrected by it. Corroborating evidence about Discord is the honest
confidence level.

**Zoom and the browser tier are out of scope**, as separate specs. Three families, three unrelated
techniques:

| Family | Technique | Transfers from Teams? |
| --- | --- | --- |
| Slack (Electron/Chromium) | `AXDOMIdentifier` + `AccessibilityWake` | Directly |
| Zoom (native AppKit) | Unknown; `AXIdentifier` study needed, and matching localized text is forbidden | No |
| Google Meet & co. in a browser | Web-area `AXURL` + tab inspection, with the several-capturing-tabs ambiguity | No |

So this spec's end state is: **Teams and Slack definitive, everything else on the audio tier.**

**Rejected: a separate `SlackAccessibilityDetector`.** Zero risk to the Teams path, at the cost of
~250 duplicated lines, two places to fix each time the technique shifts, and three copies by the
third application — at which point the generalisation happens anyway from a worse position.

**Rejected: one detector instance per application.** It buys per-application poll cadence, which is
the same behaviour for one user ("poll faster if *any* application is in a call"), and costs N
lifecycles, N retraction calls, a collection in `MeetingMonitor`, and the `static let detectorID`
pattern that `MeetingMonitor` depends on to name a detector it holds no instance of.

**Chosen: one marker-driven detector over many subjects**, because `AudioProcessDetector` is already
exactly that shape — one detector, N subjects, `previouslyCapturing` so absence is reported
explicitly. Following the repo's own precedent keeps one `detectorID`, so retraction stays a single
unchanged call, and `MeetingStateMachine` and `EvidenceFusion` need no changes at all: they already
resolve per subject.

## Prerequisite, and why it is stated first

**Slack is not installed on the development machine.** Neither are Zoom, Discord or Webex — only
Teams, Chrome and Safari. Backlog item 11's per-application statements are, as it admits, reasoning
rather than findings, and `AXDOMIdentifier` values cannot be authored from reasoning.

The redeeming difference from the Teams work: **all of these can be put into a genuine in-call state
solo.** Zoom's "New Meeting", a Discord voice channel on your own server, a Meet you create and join
alone, a free Slack workspace's huddle. Item 4 has been blocked for days waiting on a second human;
marker derivation here is self-serviceable in an afternoon.

Slack's markers will be derived from a **solo huddle in a free workspace created for the purpose**.
The caveat is recorded in the manifest and re-checked when a multi-party huddle is available: a solo
huddle may expose a different tree.

## The design

### 1. The markers manifest

`Resources/teams-markers.json` becomes `Resources/app-markers.json`, holding an array. `Resources` is
already a `buildPhase: resources` directory (`project.yml:44`), so swapping the file needs no project
change.

```json
{
  "apps": [
    { "bundleIdentifiers": ["com.microsoft.teams2"],
      "applicationName": "Microsoft Teams",
      "titleSuffixesToStrip": [" | Microsoft Teams"],
      "inMeeting": { "primary": ["call-duration-custom"], "secondary": ["hangup-button", "…"] },
      "joining":   { "primary": ["prejoin-join-button"] },
      "durationElementID": "call-duration-custom" },

    { "bundleIdentifiers": ["com.tinyspeck.slackmacgap"],
      "applicationName": "Slack",
      "inMeeting": { "primary": ["<derived by the measurement below; the entry is not shipped until then>"] } }
  ]
}
```

Teams' values move across unchanged. Four schema changes fall out of Slack differing from Teams:

- **`durationElementID` becomes optional.** Teams exposes an elapsed timer; whether a Slack huddle
  does is unknown. Absent means `startedAt` is nil and the state machine uses first observation,
  which it already handles.
- **`titleSuffixesToStrip` and `joining` become genuinely optional**, with the same
  `decodeIfPresent` treatment `MarkerSet` already needed — Swift's synthesized `Decodable` ignores
  property defaults, which that type's doc comment records the hard way. A Slack huddle has no lobby.
- **No `key` field.** `bundleIdentifiers.first` identifies an application and `applicationName` reads
  better in logs. No identifier is added that has nothing to do.
- **Load-time validation drops any application with no `inMeeting` markers, and logs it.** This is a
  safety rule, not tidiness. A definitive `notInMeeting` outranks the audio tier, so an entry that
  matches nothing would make MeetingFocus *blinder* than it is today — precisely the failure item 4
  spent days diagnosing. An unmeasured application must emit nothing rather than emit absence.

Placement mirrors the audio tier exactly: `MarkerManifest` and `AppMarkers` live in
`MeetingFocusCore` (Foundation only, so no dependency problem), and a `MarkerManifestLoading`
extension in the app target does the bundle IO — the same split as `AudioAllowlist` /
`AudioAllowlistLoading`. That is what makes decoding and validation testable by `swift test`, which
today they are not.

**No user override file**, for now. The argument for one is real — these are vendor element ids that
*will* be renamed, now for two applications independently, and an override would let a stuck user fix
it with `axprobe` instead of waiting for a release. But nobody has asked, and the bar is much higher
than the audio allowlist's one-line edit. Filed as a backlog item instead.

### 2. `MarkerMatcher` in Core

The verdict rules move out of the detector into a pure, tested type in `MeetingFocusCore`, leaving
only AX tree-walking in the app target. Input is what a walk found; output is a verdict:

```
input:  per-window (identifiers seen, window title, duration text) + total DOM identifiers seen
output: verdict, title, elapsed, matched markers

1. any window has an inMeeting marker   → .inMeeting   (title + elapsed from that window)
2. else any window has a joining marker → .joining
3. else total DOM identifiers == 0      → .indeterminate   (dormant tree, not absence)
4. else                                 → .notInMeeting
```

Rule 3 is the existing dormant-tree guard, moved verbatim. `seconds(fromDuration:)` and
`meetingTitle(from:)` move too; both are already pure statics.

This is the move items 17 and `ShortcutListing` already made, and here it is load-bearing rather than
tidiness: it is the only way to test Slack's markers without Slack running. Given a recorded
identifier set from an `axprobe ids` capture, assert the verdict — marker derivation becomes a test
fixture instead of something checkable only by holding a call.

It also pays for itself immediately. `seconds(fromDuration:)` guards with
`value < 60 || part == parts.first`, which compares by *value*, not position — so `"61:61"` parses as
3,721 seconds instead of being rejected, and `startedAt` is mis-dated by an hour.

**`suspectedMarkerBreakage` is removed.** It is declared at `TeamsAccessibilityDetector.swift:33`,
read at `:139`, and assigned nowhere, so the warning can never fire. The reason it was never
implemented is that "this window looks like a meeting" cannot be determined without matching
localized text, which the project forbids. The signature *is* detectable, but not here — see the
residual risk below.

### 3. `AccessibilityMarkerDetector`

One actor, one poll loop, `detectorID = "accessibility.markers"`. Per poll it walks every application
in the manifest that is currently running:

```
for app in manifest.apps:
    running = first NSRunningApplication matching app.bundleIdentifiers
    if none:  emit .notInMeeting once if this detector run ever emitted for it, then stay silent
    if !accessibilityTrusted:  emit .indeterminate
    else: walk tree → MarkerMatcher → emit; if 0 DOM ids, AccessibilityWake.request(pid)
return anyInMeeting ? .seconds(2) : .seconds(5)
```

**Applications that are not running emit nothing, after one explicit absence.** This mirrors
`AudioProcessDetector.previouslyCapturing`, and like it the memory is per detector run, held in the
actor and not persisted: emit the authoritative `notInMeeting` on the transition,
then go quiet, rather than restating absence about Slack every five seconds forever on a machine
where Slack is not installed. The one explicit absence is load-bearing — silence alone would leave
the subject to the 10-minute `unresolvedHold` instead of ending cleanly.

**Observers become a `[pid_t: AXChangeObserver]` reconciled at the end of each poll** — attached for
pids newly seen, dropped for pids gone. This closes a pre-existing gap for free: `attachObserver()`
runs once in `start()`, so an application launched later never gets an observer, and Teams restarting
silently loses the one it had. The poll already enumerates running applications, so this is the
natural place for it.

**The wake stays per-application and per-poll.** Slack is Electron, so it needs `AccessibilityWake`
exactly as Teams does, and the tree goes dormant again on every application restart — which is why
the existing code checks each poll rather than once at start.

Cost: the walk is bounded at 25,000 nodes and depth 70 *per application*, but runs only for running
applications, so a Teams-only machine sees no change.

### 4. Wiring, settings and strings

`MeetingMonitor`: `teamsDetector` becomes `markerDetector`, and retraction stays a **single**
unchanged call — `machine.retractEvidence(fromDetector: AccessibilityMarkerDetector.detectorID)`.
That is the payoff of one detector over many subjects.

`AppSettings`: `teamsDetectorEnabled` becomes `accessibilityDetectorEnabled`, naming the mechanism
the way `audioDetectorEnabled` does. **With migration**: on init, if the new key is unset and the old
one is set, carry the value over and remove the old key. Without it, anyone who deliberately turned
Teams detection off silently gets it back on at update.

Four `en` strings and their `de` counterparts (`project.yml:5` lists only those two regions):

| Where | From | To |
| --- | --- | --- |
| `SettingsView:83` | `"Microsoft Teams (Accessibility)"` | `"Meeting app UI (Accessibility)"` |
| `SettingsView:84` | `"Reads Teams' own meeting UI…"` | `"Reads the meeting UI of supported apps — currently Microsoft Teams and Slack…"` |
| `MenuBarController:182` | `"Reading Microsoft Teams' meeting UI"` | `"Reading meeting app UI"` |
| `MenuBarController:183` | `"Not reading Microsoft Teams' meeting UI"` | `"Not reading meeting app UI"` |

Kept as static localized text rather than interpolating application names from the manifest, on
purpose: the comments at both sites warn that the coverage scan keys on the text immediately before a
literal, and interpolation is how that quietly breaks. The cost is that a third application edits one
sentence in two languages, which is cheaper than the alternative.

## Residual risk, recorded rather than fixed

The dormant-tree guard covers *zero* identifiers, not *renamed* ones. If Microsoft or Slack rename
their element ids while the tree is awake, `MarkerMatcher` returns a definitive `notInMeeting`, which
outranks and suppresses the audio tier's perfectly correct detection.

This hazard exists today for Teams; this change doubles its surface. It is the real argument for a
breakage alarm, and the alarm is computable — but in `MeetingStateMachine`, not in the detector, since
the state machine already sees both tiers per subject and "corroborating says `inMeeting` while
definitive says `notInMeeting`, sustained" is exactly the signature. Filed as a backlog item; out of
scope here.

## Deriving Slack's markers

A measurement, not a design step, and it needs a control — otherwise a huddle marker cannot be told
from something Slack shows all the time:

```sh
make axprobe
./.build/axprobe ids com.tinyspeck.slackmacgap                    # 1. control: idle, no huddle
# start a huddle
./.build/axprobe ids com.tinyspeck.slackmacgap                    # 2. in huddle
# candidates = (2) minus (1)
./.build/axprobe watch com.tinyspeck.slackmacgap <candidates…>    # 3. mute, minimise, wait
```

`axprobe` is already fully generic — every subcommand takes a bundle identifier — so no tooling work
is needed.

Step 3 picks the `primary` marker: the one that persists for the whole huddle and survives the window
being minimised and the controls auto-hiding, the analogue of Teams' `call-duration-custom`. Record
the Slack and macOS versions in the manifest `comment`, as `teams-markers.json` already does, plus
two caveats: the solo-huddle limitation, and whether Slack's tree was dormant before `axprobe` woke
it — that last is a finding about Electron in general, not just Slack.

## Verification

1. `swift test` green with new Core tests: `MarkerMatcher` verdict rules including
   dormant→`indeterminate`, manifest decoding with the optional fields, validation dropping a
   markerless application, and duration parsing including `"61:61"`. **Verify:** test output.
2. Teams behaviour unchanged. The fixtures are identifier sets captured from a real Teams tree, and
   their expected verdicts are derived by hand from the *current* marker logic before the refactor
   starts — written first, so they pin behaviour rather than describe whatever the new code does.
   **Verify:** fixture test.
3. Slack's primary marker present for a whole huddle, absent when idle. **Verify:** `axprobe watch`
   transcript.
4. Slack huddle detected end to end in the app. **Verify:**
   `log stream --predicate 'subsystem == "me.mazetti.meetingfocus"'` shows the verdict transition and
   the shortcut firing.

Criteria 2 and 4 depend on the same real-call verification item 4 has been blocked on. The fixture
tests give confidence that the refactor preserves Teams' logic — genuinely more than exists today —
but "detection → event → shortcut fires in the real app" stays unproven for Teams until that call
happens, and criterion 4 is its Slack twin.

## Out of scope

- Zoom (native AppKit study) and the browser tier — separate specs, per the table above
- A Discord detector — deliberately audio-tier only
- A user marker override file — backlog item
- The marker-breakage alarm in `MeetingStateMachine` — backlog item
- Per-application enable switches — one mechanism switch, as today
- Meeting titles from a calendar — backlog item 22, a better source than per-application scraping

## Documentation to update on landing

- `README.md` — detection table gains a Slack row; the Accessibility permission note now covers two
  applications, not "the Teams detector"
- `docs/architecture.md` — renamed detector
- `docs/slack-accessibility.md` — new, the investigation record, mirroring `teams-accessibility.md`
- `docs/BACKLOG.md` — item 11 closes for Slack, stays open for Zoom; two new items (breakage alarm,
  marker override)
