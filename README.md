# MeetingFocus

A small macOS menu bar utility that detects when you are actually *in* a meeting — not merely
that a meeting app is open — and runs the Shortcuts you configure when a meeting starts and ends.

The typical use is toggling a Focus mode so notifications stay quiet for the duration of a call,
across your Mac and (because Focus syncs between Apple devices) your iPhone too.

## Requirements

- macOS 26 or later
- Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Accessibility permission, for the Teams detector

## Build and run

```sh
xcodegen generate
open MeetingFocus.xcodeproj
```

Or from the command line:

```sh
xcodegen generate
xcodebuild -project MeetingFocus.xcodeproj -scheme MeetingFocus -configuration Debug build
xcodebuild -project MeetingFocus.xcodeproj -scheme MeetingFocusCoreTests -destination 'platform=macOS' test
```

`project.yml` is the source of truth for the project; `MeetingFocus.xcodeproj` is generated from
it and committed so the project opens without XcodeGen installed. Edit the YAML, not the
`.xcodeproj`.

## How detection works

Two independent signals, combined rather than chosen between, because they fail in opposite
directions.

| Detector | Signal | Confidence | Covers |
|---|---|---|---|
| `TeamsAccessibilityDetector` | Teams' own meeting UI, matched on `AXDOMIdentifier` | definitive | Microsoft Teams |
| `AudioProcessDetector` | per-process microphone capture (CoreAudio) | corroborating | Zoom, Slack, Webex, Discord, browser meetings |

The Accessibility detector is precise: it reads the meeting title, distinguishes the lobby from an
active call, and is unaffected by muting. The audio detector is coarse but needs no per-app work
and reaches browser-based meetings such as Google Meet, where there is no app UI to inspect.

Where both describe the same application, the definitive verdict wins. That is what stops a mute
from ending a Teams meeting.

Detection never matches on user-visible text. The development machine ran a German UI, where the
meeting controls read "Besprechungssteuerung"; a string-based detector would work only in English.

## Permissions

Only **Accessibility** is required, and only for the Teams detector. Without it the app degrades
to microphone-only detection and says so in its menu rather than failing quietly.

No Screen Recording, Microphone or Camera permission is needed. No private APIs, no privileged
helper, no background daemon.

## Configuration

Settings offers per-detector toggles, the shortcut to run on start and on end (picked from your
actual shortcut list), and how long to wait before running the end shortcut.

That wait matters. Back-to-back meetings are normal — a 12-second gap between two real meetings
was measured during development — and without it your Focus mode would switch off and on again in
the gap. If a new meeting begins during the wait, no end or start shortcut runs at all.

## When detection breaks

The Teams detector matches internal HTML element ids that Microsoft can rename in any release.
They live in `Resources/teams-markers.json` rather than in source, so a fix is a data change.

To re-derive them, enable Debug mode in Settings and watch:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "com.matchory.MeetingFocus"'
```

A warning is logged when a window looks like a meeting but no markers match — the signature of a
rename. Meeting titles are redacted from logs by design.

## Documentation

- [`docs/teams-accessibility.md`](docs/teams-accessibility.md) — the investigation this is built
  on, including hypotheses that were tested and rejected
- [`docs/architecture.md`](docs/architecture.md) — structure and extension points
- [`docs/constraints.md`](docs/constraints.md) — platform constraints and which of them are
  load-bearing
