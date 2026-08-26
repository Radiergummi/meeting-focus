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

- The menu bar icon can be hidden, for people who want the app to run invisibly. Detection and
  automation keep running. Opening MeetingFocus again from the Applications folder brings the icon
  back — necessary, because with the icon hidden the app has no other visible surface.
- German (`de`) alongside English. Every string in the menu and in Settings is translated, including
  the menu bar icon's VoiceOver label. German is marked `needs_review` in the catalogue until a
  native speaker has read it.

### Fixed

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

[Unreleased]: https://github.com/Radiergummi/meeting-focus/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Radiergummi/meeting-focus/releases/tag/v0.1.0
