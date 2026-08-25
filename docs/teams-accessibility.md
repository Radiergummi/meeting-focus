# Microsoft Teams meeting detection via the macOS Accessibility API

Investigation record. Every observation below was measured on the machine and date stated —
nothing here is inherited from documentation or from older Teams versions.

## Test environment

| | |
|---|---|
| macOS | 26.6.1 (build 25G76) |
| Teams | `com.microsoft.teams2` version 26213.1006.5011.1671 ("new" Teams, WebView2/Chromium) |
| UI locale | German (`de-DE`); web areas report `AXLanguage = de-de` |
| Date | 2026-08-25 |
| Probe | `Sources/axprobe` (tree dump, notification watcher, CoreAudio correlator) |

The German locale was a lucky accident: it exposed immediately that any detector built on
English UI strings would be broken for a large share of users.

## 1. Identifying the process

`com.microsoft.teams2` is the only bundle identifier worth binding to. The app spawns a
family of helper processes (`…teams2.modulehost`, `…teams2.helper`, `…WebView Helper`,
`TeamsWidgetExtension`, an XPC notification service, plus a `MSTeamsAudioDevice.driver`
Core Audio plug-in), but the AX tree hangs off the main `MSTeams` process only.

`NSRunningApplication.runningApplications(withBundleIdentifier:)` plus
`NSWorkspace.didLaunch/didTerminateApplicationNotification` is sufficient for lifecycle.

Classic Teams (`com.microsoft.teams`) was not present and was not tested. Nothing here should
be assumed to apply to it.

## 2. Window model

Teams uses **multiple top-level windows**, and their count and titles change during normal use.
Observed titles:

- `Chat | Microsoft Teams`, `Calendar | Microsoft Teams`, `Aktivität | … | Microsoft Teams`,
  `Workflows | …` — the main window, retitled as the user navigates.
- `Architecture Review Kickoff Part I | Microsoft Teams` — a joined meeting; the window title
  carries the **meeting subject**.
- `Besprechung beitreten | Daily | Microsoft Teams` — the **pre-join / lobby** window.
- `Kompakte Besprechungsansicht | Daily | Microsoft Teams` — the **compact meeting view**,
  which appears and disappears *during* a meeting as a second meeting-related window.

So: a meeting is normally its own window, but window titles are partly localized
(`Besprechung beitreten`, `Kompakte Besprechungsansicht`) and cannot be used for state.
The meeting subject is usable as a display title after stripping the ` | Microsoft Teams` suffix.

## 3. The reliable signal: `AXDOMIdentifier`

Chromium exposes the underlying HTML `id` of each web element as the `AXDOMIdentifier`
attribute (alongside `AXDOMClassList`, `AXURL`, `ChromeAXNodeId`). These are **not localized**
and are semantically meaningful. Confirmed present in the meeting UI:

| `AXDOMIdentifier` | Role | Meaning |
|---|---|---|
| `call-duration-custom` | `AXGroup` | Elapsed call timer. **Primary marker.** |
| `indicators` | `AXToolbar` | Call-indicator toolbar |
| `e2ee-status` | `AXButton` | Encryption status |
| `horizontalMiddleEnd` | `AXToolbar` | Meeting-controls toolbar |
| `horizontalEnd` | `AXGroup[AXApplicationGroup]` | Call-controls container |
| `hangup-button` | `AXButton` | Leave / end call |
| `microphone-button` | `AXButton` | Mute toggle |
| `video-button` | `AXButton` | Camera toggle |
| `roster-button`, `chat-button`, `share-button`, `raisehands-button`, `reaction-menu-button`, `view-mode-button`, `meeting-details-button`, `meeting-apps-add-btn`, `callingButtons-showMoreBtn`, `screensharing-control-button`, `annotation-button` | `AXButton` | Other meeting controls |

`call-duration-custom` is the best single marker: it is present for the entire call, it survived
every UI change observed, and its value yields the meeting's elapsed time and therefore its
start instant. Its localized `AXTitle` (`"Verstrichene Zeit 47:13"`) must **not** be parsed;
the child `AXStaticText` carries the bare numeric value (`"45:25"`).

`microphone-button`'s `AXDescription` also reveals mute state, but only via localized text
(`"Mikrofon stummschalten"` = currently unmuted). Usable for diagnostics, not for logic.

### A caveat on identifier stability

`axprobe ids com.microsoft.teams2` reports **170** elements exposing an `AXDOMIdentifier`, and most
are randomly generated GUIDs:

```
0bf73c61-9c1a-45a9-825c-401123208d17                         AXGroup
3fda5456-…~96d44937-…~RecentChats                            AXGroup
14d6962d-6eeb-4f48-8890-de55454bb136                         Aktivität (⌘ 1)
```

Only the semantic, hand-authored ids are stable enough to match on — which is why detection uses an
explicit allowlist of known ids rather than any structural heuristic over the identifier space. A
"match anything that looks like a control" approach would key on GUIDs that change per session.

## 4. Measured state transitions

Ground truth from the notification watcher plus a 2-second structural poll.

**Leave** (first meeting):

```
10:49:34  inMeeting=true   2 windows, 561 nodes, 8/8 markers present
10:52:17.498  AXUIElementDestroyed  (×2, then ×4 more at .662)
10:52:17.501  AXFocusedWindowChanged / AXMainWindowChanged → main window
10:52:18.620  inMeeting=false  1 window, 415 nodes, markers = {}
```

**Join** (second meeting, 8 minutes later):

```
11:00:00  inMeeting=false  250 nodes, window "Besprechung beitreten | Daily"   ← lobby
11:00:02  inMeeting=false  344 nodes, same window                              ← lobby, tree filling in
11:00:26  inMeeting=true   537 nodes, window "Daily | Microsoft Teams"         ← joined (26s in lobby)
11:00:34  inMeeting=true   634 nodes, + "Kompakte Besprechungsansicht | Daily"
```

**Back-to-back meetings** (same session, 24 minutes later):

```
11:24:47  inMeeting=false  windows ["Daily | Microsoft Teams", "Chat | …"]   ← Daily's call ended
11:24:48  inMeeting=false  windows ["Chat | …"]                              ← meeting window gone
11:24:57  inMeeting=false  windows ["Microsoft Teams", "Chat | …"]           ← new window, untitled
11:24:59  inMeeting=true   windows ["Marcel Möbus | Microsoft Teams", …]     ← 1:1 call joined
```

A genuine **12-second idle gap between two real meetings**. Detection handled it correctly, but it
is the case that breaks naive automation: firing `ended` then `started` 12 seconds apart would
flap the user's Focus mode. It is also worth noting the new window appeared briefly titled just
`Microsoft Teams` before acquiring the participant's name — another reason titles cannot drive state.

The CoreAudio correlator showed `teams2.modulehost[in=1]` at 11:24:57, **2 seconds before** the AX
markers appeared. The audio tier leads the AX tier slightly on join, which is useful corroboration.

Two things follow. A genuine **`joining` state exists and lasts a long time** (26 s here) — it is
worth modelling. And detection remained stable at `inMeeting=true` across repeated
appearance/disappearance of the compact-view window (11:11:52 → 11:12:20), so window churn
during a meeting does not disturb the marker-based test.

## 5. Notifications

`AXObserverAddNotification` succeeded (`0`) for every notification tried:
`AXWindowCreated`, `AXUIElementDestroyed`, `AXWindowMiniaturized`, `AXWindowDeminiaturized`,
`AXFocusedWindowChanged`, `AXMainWindowChanged`, `AXTitleChanged`, `AXCreated`,
`AXApplicationActivated`, `AXApplicationDeactivated`, `AXLayoutChanged`,
`AXSelectedChildrenChanged`.

Useful in practice:

- **Leave is announced.** `AXUIElementDestroyed` + `AXMainWindowChanged` fired **1.12 s before**
  the poll noticed. Notification-driven rescan is therefore a real latency win.
- **`AXTitleChanged` fires at ~1 Hz for the whole call**, emitted by the duration label. It is a
  free in-meeting heartbeat, and it is far too noisy to act on directly (83 events in 65 s).
- `AXSelectedChildrenChanged` is frequent background noise from lists and tab groups.

Not established: no `AXWindowCreated` was captured for a meeting window, because the join
happened while the watcher was subscribed but the lobby window appears to be a *retitled*
existing window rather than a new one. **Notifications alone are not yet proven sufficient for
join detection**, which is why the design keeps a bounded poll as the correctness base and uses
notifications only to reduce latency.

## 6. Cost

A full marker scan of all Teams windows walked **250–3,479 nodes**, varying by more than an order
of magnitude with what the main window happened to be displaying — a meeting window is small
(~150 nodes), while a Chat window listing GitHub notifications reached ~3,300 on its own. Every
scan still completed well inside the 2-second poll interval.

The spread matters more than the absolute cost: any node cap tuned to the small case will silently
truncate the large one and produce a **false negative**. Bound generously (25,000) and rely on
early exit at the first marker for speed, not on a tight cap.

One real cost to note: querying a Chromium app's AX tree causes Chromium to build and maintain
its full accessibility tree, which consumes CPU and memory **inside Teams**. This is inherent to
the approach and should be disclosed to users.

## 7. Hypotheses tested and rejected

Recording these so they are not re-attempted.

- **`AXTimeGroup` subrole as the marker.** Looked ideal — the duration element carries it. Rejected:
  the Chat window contained **35** `AXTimeGroup` elements (message timestamps) versus 1 in the
  meeting window. It maps `<time>`, not "call".
- **Presence of the meeting-controls toolbar.** Rejected: the control bar **auto-hides during a
  meeting**. Toolbar count in the meeting window dropped 3 → 2 at 10:47:47 mid-call. Using it
  would emit a false `meeting.ended`.
- **Window-title matching.** Rejected: partly localized, and `Chat | Microsoft Teams` is
  structurally identical to a meeting title.
- **`AXManualAccessibility` / `AXEnhancedUserInterface` to force the web tree.** Setting these
  returned `-25205` (attribute unsupported) and `-25208` (illegal argument). Not needed — the web
  tree was fully populated regardless.

## 8. Permissions

Only **Accessibility** (`kTCCServiceAccessibility`) is required — granted in
System Settings → Privacy & Security → Accessibility. `AXIsProcessTrusted()` reports state;
`AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt` requests it.

No Screen Recording, Microphone, Camera, or Automation permission is needed for the AX path.
No private API, no privileged helper, no entitlement beyond ordinary code signing.

Note that TCC keys the grant to the app's **code signature**: ad-hoc signed builds lose the
grant on almost every rebuild. This project signs with Developer ID `TH593VRB6W` for a stable identity.

## 9. Cross-checking against microphone state (CoreAudio)

Measured with the public per-process API added in macOS 14.4
(`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput` / `…Output`
/ `…BundleID` / `…PID`), validated end-to-end against an `afplay` control (`out=1`).

While in a meeting, unmuted:

```
AX inCall=true  micButton="Mikrofon stummschalten"
CoreAudio  teams2.modulehost[in=1 out=1]  deviceRunning=1
```

Observed alongside it: `com.electron.wispr-flow.helper[in=1]` and `com.apple.CoreSpeech[in=1]` —
always-on dictation/speech services holding the microphone. Device-level
`kAudioDevicePropertyDeviceIsRunningSomewhere` therefore cannot distinguish a meeting from
dictation; **per-process attribution is essential** if microphone state is used at all.

**Open question — mute.** Whether Teams releases the input stream while muted is *not yet
resolved*; a correlator logging AX mute state against `IsRunningInput` is running and will
capture the next toggle. Until it is answered, microphone state must not be allowed to end a
meeting on its own.

Also unverified but documented in Apple's developer forums: Bluetooth input devices may report
inactive while actually in use. Headsets are common in meetings, so this is a material risk for
the audio signal.

## 9a. App Sandbox behaviour (measured)

Relevant to distribution choices, so recorded here.

- **Accessibility is unavailable to sandboxed apps.** App Sandbox blocks cross-app AX calls and no
  entitlement unlocks it. Since the Mac App Store mandates the sandbox, the detector in this
  document cannot ship there. Existing MAS window managers (Magnet, Divvy, BetterSnapTool)
  predate the mandate.
- **The CoreAudio per-process audio API does work under App Sandbox.** Verified by building a
  Developer-ID-signed bundle with only `com.apple.security.app-sandbox` and running it:

  ```
  sandboxed=true
  processObjectList sizeErr=0 count=40
  bundleIDs readable=40  nonEmpty=37
  capturingInput=["com.apple.CoreSpeech", "com.microsoft.teams2.modulehost"]
  ```

  Per-process attribution survives the sandbox intact. A future sandboxed build could therefore
  run audio-only detection without redesign.

This project ships notarized and Developer-ID-signed outside the App Store, so the AX path is
available. The sandbox result is recorded only to keep the option open.

## 10. Generalisation to other clients

- **Slack** is Electron/Chromium, so the `AXDOMIdentifier` technique should transfer directly.
  Untested — Slack is not installed here.
- **Zoom** is a native AppKit app; its tree will look nothing like this and needs its own marker
  study. Untested — Zoom is not installed here.
- **Browser-based meetings** (Google Meet, Teams web, Zoom web) have no *meeting* UI reachable by
  bundle identifier — the app is the browser. The per-process audio signal reaches these, which is
  the main argument for keeping a generic audio tier.

  However, browser **tabs are enumerable over Accessibility**, which was verified here: Safari
  exposes each tab as `AXRadioButton[AXTabButton]` with the tab title in `AXDescription`
  (`"Claude Code"`, `"Domain settings - Mailgun Send"`, …). No Automation/AppleScript permission
  is involved — Accessibility alone suffices. This means a browser meeting can be *named*
  ("Google Meet — standup") even though the process-level signal only says "the browser is
  capturing".

  Wispr Flow's public documentation describes doing exactly this, and independently corroborates
  the layered design: it combines a capture signal with Chrome tab identification, "latch[ing]
  onto the Meet tab even in the background without macOS Automation permission". Two details of
  theirs are worth copying:

  - When **multiple capturing meeting tabs** are open, they *disable* tab identification for that
    session rather than guess. Ambiguity should suppress, not pick.
  - Calendar data supplies the meeting **title** ("the calendar event's title when recognized,
    otherwise 'Meeting detected'"), not the meeting *state*.

  They also report being unable to recover a conference link from native apps (Zoom, Teams,
  Webex, Slack desktop), which matches this investigation: native clients yield state and a
  subject line, but no dependable meeting identifier. `Meeting.externalID` must stay optional.

  Verified here: tab enumeration and tab titles. Not verified: whether a browser annotates a
  *capturing* tab in its accessibility tree (Wispr describes this as Chrome-specific; Chrome was
  not running during this investigation).

Both Slack and Zoom statements are reasoning, not findings.

## 11. Residual risk

`AXDOMIdentifier` values are Teams' internal HTML ids. Microsoft can rename them in any release
and nothing will warn us. Mitigations adopted:

1. Accept **any** marker from a tier set rather than requiring a specific one.
2. Ship `axprobe` so the id set can be re-derived in minutes.
3. Log a warning when a window looks meeting-shaped but yields no markers, so breakage is
   visible rather than silent.
4. Keep an independent, structurally different signal (per-process audio) as corroboration.
