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

### Added

- An app icon. MeetingFocus is no longer the generic placeholder in Finder, in Login Items or in
  the update dialog, the disk image you download shows it as the volume icon, and the first-run
  setup window opens with it. The menu bar keeps its own symbol, because that one has to change
  with the meeting.
- Three App Intents — **Set Meeting State**, **Clear Meeting Override**, **Get Meeting Status** —
  so a Shortcut, Spotlight or `shortcuts run` can set and read the meeting state from outside the
  app. `Get Meeting Status` returns a plain `Bool` rather than a richer entity, so a Shortcuts `If`
  block can branch on it without a string comparison.
- An AppleScript dictionary, so `osascript`, `tell application` and any other Apple Events client
  can read and set meeting state the same way the App Intents do — `in meeting`, `meeting state`,
  `meeting title`, `manual` and `override expires` as properties, plus `set meeting state … for …
  titled …` and `clear meeting override` as commands. Script Editor's Open Dictionary shows the
  full terminology.

### Changed

- Your Focus mode is now released 20 seconds after a meeting ends rather than 45. The wait exists
  only to swallow the gap between back-to-back meetings, which was measured at 12 seconds; the
  remaining half-minute was time spent silent after a call that was already over, and long enough
  that reaching for the Focus toggle yourself was the faster option. Installations that already
  have a value keep it — the slider is in Settings.

### Fixed

- **A Focus mode could be left on with nothing able to turn it off again.** Everything the app knew
  about a meeting in progress lived in memory, so quitting, crashing, installing an update or
  rebooting during a call ended the only thing that could have run your end shortcut. The next
  launch started from a blank slate and turned nothing off; if that launch landed during the same
  call it ran the start shortcut a second time over a Focus mode that was already on. The app now
  remembers that it turned your Focus on and picks that up again at launch — so the meeting ends
  normally, and a relaunch mid-call is invisible.
- A meeting could never end if the detector watching it went blind without saying so. Unreadable
  accessibility data correctly holds the previous state rather than ending a meeting, but a
  detector that keeps reporting "I cannot tell" held it indefinitely — a Teams window whose
  interface went dormant while your microphone was muted had that shape. The hold now gives up
  after ten minutes.
- A scripting command sent before the app had finished launching reported success having done
  nothing. It now fails with an Apple Event error, the way the equivalent App Intent already threw.
- An automation that renewed its manual claim on a short interval wrote a detection-log line every
  time, flushing all twenty entries within minutes and evicting whatever someone opened the log to
  read. A renewal is now silent; only a fresh declaration is logged.

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

- The menu's two checkmarks are gone, replaced by a single switch on the status row that both reports
  whether you are in a meeting and lets you say so yourself. Switching it on declares a meeting when
  nothing detected one; switching it off ends the meeting in progress and stops believing the detector
  that reported it, until that detector agrees the call is over — so the next real meeting registers
  normally. Switching it off also releases your Focus mode at once rather than 45 seconds later: the
  cooldown that absorbs the gap between back-to-back meetings is not for someone saying they are done. Monitoring can no longer be switched off from the menu, because quitting is that gesture;
  automation keeps its switch in Settings.
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
