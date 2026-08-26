# Changelog

Notable changes, newest first, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file is **load-bearing**, not decoration: `.github/workflows/release.yml` extracts the section
matching the release tag and puts it at the top of the GitHub release notes. A tag whose version has
no section here fails the release before anything is signed, which is the point — a release nobody
can describe is one nobody should install.

Entries describe what changed *for someone using the app*. Development tooling, refactors and
documentation belong in the commit history, not here.

## [Unreleased]

## [0.1.1] — 2026-08-26

### Added

- A first-run setup window that takes a new installation all the way to working automation without anyone authoring a Shortcut or typing its name. It explains what Accessibility is needed for before asking, then installs and selects two Do Not Disturb shortcuts, one for the start of a meeting and one for the end. Both are generated and signed on your own machine, so nothing unsigned is ever downloaded. Reopen it from "Set Up MeetingFocus…" in the menu.
- Three App Intents — **Set Meeting State**, **Clear Meeting Override**, **Get Meeting Status** — so a Shortcut, Spotlight or `shortcuts run` can set and read the meeting state. `Get Meeting Status` returns a plain `Bool`, so a Shortcuts `If` block can branch on it without a string comparison.
- An AppleScript dictionary covering the same ground for `osascript` and any other Apple Events client: `in meeting`, `meeting state`, `meeting title`, `manual` and `override expires` as properties, plus `set meeting state … for … titled …` and `clear meeting override` as commands.
- An app icon, in Finder, Login Items, the update dialog, the disk image and the setup window. The menu bar keeps its own symbol, because that one has to change with the meeting.
- The menu bar icon can be hidden, for people who want the app to run invisibly. Detection and automation keep running, and opening MeetingFocus again from Applications brings the icon back.
- Technical information in the menu, on the terms the Wi-Fi menu uses: hold ⌥ Option while opening it to see which detectors are running, whether Accessibility is granted, the build, and the last ten detections. This replaces the Debug mode switch, which had to be turned on before the log started filling — by which time the detection you wanted explained had already happened.
- German alongside English, including the menu bar icon's VoiceOver label. Marked `needs_review` in the catalogue until a native speaker has read it.

### Changed

- The menu's two checkmarks are replaced by a single switch on the status row, which both reports whether you are in a meeting and lets you say so yourself. Switching it on declares a meeting when nothing detected one. Switching it off ends the meeting, releases your Focus at once rather than after the cooldown, and stops believing the detector that reported it until that detector agrees the call is over. Monitoring can no longer be switched off from the menu, because quitting is that gesture; automation keeps its switch in Settings.
- Your Focus mode is released 20 seconds after a meeting ends rather than 45. The wait exists only to swallow the gap between back-to-back meetings, measured at 12 seconds. Existing installations keep the value they have; the slider is in Settings.
- "Set Up MeetingFocus…" is now the ⌥ alternate of "Settings…" rather than a row of its own. Onboarding presents itself on a fresh install, and reaching it again is a once-in-a-while repair.

### Fixed

- **Teams meetings are now actually detected.** Teams renders its interface as web content, which macOS publishes to assistive software only once it believes something needs it — and reading is not enough to ask. MeetingFocus was looking at an empty tree and concluding no meeting was happening: during a real call it could see 42 elements and none of the meeting's. It now asks for the full interface, and where it still cannot see, it says so rather than reporting "no meeting" and overriding the microphone detector that could see the call perfectly well.
- **A Focus mode could be left on with nothing able to turn it off again.** Everything the app knew about a meeting in progress lived in memory, so quitting, crashing, updating or rebooting during a call destroyed the only thing that could have run your end shortcut — and a relaunch during the same call ran the start shortcut a second time over a Focus mode already on. That state now survives a restart, so the meeting ends normally and a relaunch mid-call is invisible.
- A meeting could never end if the detector watching it went blind without saying so — a Teams window whose interface went dormant while your microphone was muted had that shape. The hold now gives up after ten minutes.
- Renaming either Do Not Disturb shortcut no longer stops MeetingFocus finding it: the app remembers which shortcut it is, not only what it is called, so a rename or a change of language keeps working. Re-running setup no longer adds a second copy of a shortcut you already have.
- Turning a detector on or off in Settings takes effect immediately, rather than doing nothing until the app is next launched.
- A scripting command sent before the app had finished launching reported success having done nothing. It now fails with an Apple Event error, the way the equivalent App Intent already did.
- An automation renewing its manual claim on a short interval wrote a detection-log line every time, evicting the twenty entries someone had opened the log to read. Renewals are now silent; only a fresh declaration is logged.
- A failed Shortcut no longer leaves its error message in the menu until the app is relaunched. It clears the next time a shortcut runs successfully.
- Six pieces of the UI could never be translated, because they were typed where SwiftUI does not localize: the status line, the Monitoring and Automation rows, the menu bar icon's VoiceOver label, the two shortcut-picker labels, and the Accessibility status line in Settings.

## [0.1.0] — 2026-08-25

First release.

### Added

- Meeting detection for Microsoft Teams, by reading Teams' own in-call UI through the
  Accessibility API. Matches locale-independent element ids rather than translated window titles,
  so it works regardless of the language Teams is running in.
- Meeting detection from microphone activity, attributed per process, covering Zoom, Slack, Webex,
  Discord and browser-based meetings with no per-application setup. Scoped by an allowlist so
  dictation and speech services do not register as meetings.
- Shortcuts automation on meeting start and end, which is what makes toggling a Focus possible —
  macOS exposes no public API for setting one.
- A configurable delay before the end shortcut runs, so a short gap between back-to-back meetings
  does not release your Focus.
- Menu bar state at a glance, plus a Settings window for detectors, automation, launch at login
  and diagnostics.
- Automatic updates via Sparkle, signed with a key held by the maintainer rather than by CI.

[Unreleased]: https://github.com/Radiergummi/meeting-focus/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Radiergummi/meeting-focus/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Radiergummi/meeting-focus/releases/tag/v0.1.0
