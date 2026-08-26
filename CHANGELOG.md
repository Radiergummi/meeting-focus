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

- A first-run setup window, which takes a new installation all the way to working automation
  without anyone having to author a Shortcut or type its name. It explains what Accessibility is
  needed for before asking for it, then installs and selects two Do Not Disturb shortcuts — one
  for the start of a meeting, one for the end. Both are generated and signed on your own machine,
  so nothing unsigned is ever downloaded. Reopen it any time from "Set Up MeetingFocus…" in the
  menu.
- The menu bar icon can be hidden, for people who want the app to run invisibly. Detection and
  automation keep running. Opening MeetingFocus again from the Applications folder brings the icon
  back — necessary, because with the icon hidden the app has no other visible surface.
- Technical information in the menu, on the terms the Wi-Fi menu uses: hold ⌥ Option while opening
  the menu bar item and it lists which detectors are running, whether Accessibility is granted, the
  build, and the last ten detections. This replaces the Debug mode switch in Settings, which had to
  be turned on before the log started filling — by which time the detection you wanted explained had
  already happened.
- German (`de`) alongside English. Every string in the menu and in Settings is translated, including
  the menu bar icon's VoiceOver label. German is marked `needs_review` in the catalogue until a
  native speaker has read it.

### Changed

- "Set Up MeetingFocus…" is now the ⌥ alternate of "Settings…" rather than a row of its own, with
  ⌘⌥, as its shortcut. Onboarding presents itself on a fresh install and reaching it again is a
  once-in-a-while repair, so it no longer takes a line in the everyday menu.

### Fixed

- **Teams meetings are now actually detected.** Teams renders its interface as web content, which
  macOS publishes to assistive software only once it believes something needs it — and reading it
  is not enough to ask. MeetingFocus was therefore looking at an empty tree and concluding no
  meeting was happening: during a real call it could see 42 elements and none of the meeting's.
  It now asks for the full interface, and sees all of it. Where it still cannot see, it now says so
  rather than reporting "no meeting", which previously overrode the microphone detector even though
  that one could see the call perfectly well.
- Renaming either Do Not Disturb shortcut in Shortcuts no longer stops MeetingFocus finding it.
  The app now remembers which shortcut it is, not only what it is called — so a rename, or running
  the app in a different language, keeps working. Re-running setup also no longer adds a second
  copy of a shortcut you already have.
- Turning a detector on or off in Settings takes effect immediately. It previously did nothing at
  all until the app was next launched.
- A failed Shortcut no longer leaves its error message in the menu until the app is relaunched. The
  message now clears the next time a shortcut runs successfully.
- Five pieces of the UI could never be translated, because they were typed as plain `String` where
  SwiftUI only localizes `LocalizedStringKey`: the status line ("In a meeting"), the Monitoring and
  Automation rows, the menu bar icon's VoiceOver label, and the two shortcut-picker row labels in
  Settings.
- The Accessibility status line in Settings had no catalogue entry at all, so it read English under
  every locale.

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
