# Backlog

Everything known to be outstanding as of 2026-08-25, ordered by priority within each section.
Items carry the reason they matter, because a task without its rationale gets done wrong or
dropped for the wrong reason.

Related: [`constraints.md`](constraints.md) tracks platform limits and which are load-bearing;
[`teams-accessibility.md`](teams-accessibility.md) is the investigation record.

---

## P0 — Correctness of claims already made

### 1. Re-release through CI so the shipped build actually has provenance
`v0.1.0` is published but was built **locally**, before the release workflow existed. Verified:

```
gh attestation verify MeetingFocus-0.1.0.dmg → HTTP 404 (no attestation)
Info.plist :MFBuildCommit                    → does not exist
```

The README and release template now promise verifiable provenance, and the one shipped artifact
has none — the claim is currently false for every existing download, and the appcast advertises
that same unattested build. Fix by tagging a release through `.github/workflows/release.yml` and
either replacing `v0.1.0` or superseding it with `v0.1.1`.

**Blocked on:** repo secrets (item 2).

### 2. Add the release secrets, then prove the release workflow runs
`.github/workflows/release.yml` has never executed. Required repository secrets:

| Secret | Contents |
|---|---|
| `SIGNING_DATA` | base64 of the Developer ID Application `.p12` |
| `SIGNING_PASSWORD` | its export password |
| `APPLE_API_KEY_DATA` | contents of the App Store Connect `.p8` |
| `APPLE_API_KEY_ID` | key id |
| `APPLE_API_ISSUER` | issuer id |

Note what this asks: the Developer ID key must exist on a runner, in an ephemeral keychain on a
disposable VM. The alternative is every user trusting an unverifiable binary. It is a real trade
and should be made knowingly, not by default.

### 3. Back up the Sparkle private signing key
It exists **only** in the maintainer's login keychain as "Private key for signing Sparkle updates".
Lose it and no installed copy can ever be updated — every user would have to reinstall by hand.
Since detection depends on Teams element ids that *will* be renamed, this key is the single point
of failure for the project's ability to fix itself. Export command is in the README; store it in a
password manager and delete the file.

### 4. Verify the app's in-meeting path end to end, at least once
Never observed. The app has only ever reported `notInMeeting`. The marker logic is byte-identical
to what ran correctly against three real meetings on 2026-08-25 and the state machine is
unit-tested, but **detection → event → shortcut has not fired in the real app**. Watch it during
one real call:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "me.mazetti.meetingfocus"'
```

### 5. Re-grant Accessibility to the current bundle
The bundle identifier changed to `me.mazetti.meetingfocus`, and TCC keys on the code signature, so
the earlier grant no longer applies. `make run` installs to `/Applications`, which is the path
worth granting — a build run from `.build-xcode` loses its grant on the next rebuild.

---

## P1 — Known unknowns that size the roadmap

### 6. Settle whether muting releases the microphone stream
**This decides how much per-app work the product needs.** If mute releases the input stream, every
application we want to support properly needs its own Accessibility detector; if it does not, the
audio tier covers Zoom, Slack, Meet and Discord correctly with no per-app work and per-app
detectors become optional polish.

Teams is unaffected either way (its Accessibility evidence is definitive and overrides audio), so
this is not a blocker — but it is the highest-leverage unknown in the project.

Strong prior that it does **not** release the stream: both Teams and Zoom ship a "your mic is muted,
we can hear you talking" prompt, which is only possible while capturing.

Test: in a real call, mute for ~15 seconds while watching AX in-call state against
`kAudioProcessPropertyIsRunningInput`. The correlator used for this lived in a scratch directory and
is **not in the repo** — worth rebuilding as an `axprobe` subcommand so it is not lost again.

### 7. Verify or remove the `joining` marker ids
`Resources/teams-markers.json` carries `prejoin-join-button` / `prejoin-join-btn` marked
`UNVERIFIED` — they are inferred, never observed. A 26-second lobby *was* measured, so the state is
real; the ids are guesses. Capture the lobby with `axprobe ids com.microsoft.teams2` while sitting
in a pre-join screen, then either fix them or delete them. Shipping a guess that silently never
matches is worse than shipping no `joining` state.

### 8. Confirm whether Graph's `InAMeeting` is calendar-derived
Blocks the provider tier (M2). If the activity is partly derived from calendar rather than actual
call state, it will report a meeting the user never joined — which would make it unusable as
anything but weak corroboration.

---

## P2 — Requested features not yet built

### 9. Localization (en + de)
Every UI string is currently an English literal. The project is already prepared: `knownRegions:
[en, de]`, `CFBundleLocalizations`, and both `SWIFT_EMIT_LOC_STRINGS` and
`STRING_CATALOG_GENERATE_SYMBOLS` off with the reasoning recorded in `project.yml`.

Remaining work, adapting pensieve's design:
- `Localizable.xcstrings` catalogue, hand-authored.
- `Tools/xcstrings` — the only thing that writes the catalogue: `add`/`set`/`remove`/`rename`/
  `add-language`/`audit`/`fmt`. Verbs rather than hand-aimed edits into JSON, refusing the two
  things a text edit does silently (dropping a duplicate key, leaving a declared language empty).
- Coverage and integrity tests: every rendered literal has a key and every key is rendered, so a
  new string cannot ship untranslated.
- No language named in the tool — `project.yml`'s `knownRegions` is the authority.

Worth noting the irony to keep straight: *detection* must never match localized strings, while the
*app's own UI* should be fully localized. These are opposite rules in the same codebase.

### 10. App icon
There is no asset catalogue and no `ASSETCATALOG_COMPILER_APPICON_NAME`, so the app ships with the
generic placeholder icon in Finder, Login Items and the update dialog. The menu bar itself uses an
SF Symbol and is fine.

### 11. Bundled Focus shortcut, if a one-click path is wanted
Currently documented as manual setup, deliberately: macOS treats shortcut files from unidentified
sources as untrusted, so an import step is not reliably one click. If revisited, an iCloud shortcut
share link is trusted by construction and needs no bundled file.

---

## P3 — Roadmap

### 12. Provider integrations (M2)
One provider end to end, plus Keychain storage and an OAuth flow. Transports researched:

| Provider | Signal | Transport for a desktop app |
|---|---|---|
| Microsoft Graph | `presence.activity` = `InAMeeting` | poll `GET /me/presence`; subscriptions need a public HTTPS endpoint and expire hourly |
| Slack | `user_huddle_changed` | Socket Mode — WebSocket, no public endpoint |
| Zoom | `user.presence_status_updated` | webhooks need an endpoint; reported inconsistent desktop vs mobile |
| Google Meet | conference started/ended | Workspace Events API + Pub/Sub — heaviest |

Remote evidence is `corroborating` and describes the *user*, not this Mac, so "meetings on my
phone count" becomes a setting. A corporate tenant can refuse the app registration outright, which
is why this can never be the foundation.

### 13. Native Zoom and Slack detectors (M3)
Slack is Electron/Chromium, so the `AXDOMIdentifier` technique should transfer directly. Zoom is
native AppKit and needs its own marker study — it may expose no stable identifiers at all, leaving
only localized titles. Neither is installed on the development machine, so both statements are
reasoning rather than findings.

### 14. Browser tier for naming meetings (M3)
Tabs are enumerable as `AXTabButton` with titles (verified on Safari), and web areas expose
`AXURL`, so `meet.google.com` is identifiable. Audio already covers the *state*; this only adds the
*name*. Where several capturing tabs are open, drop the identity and keep the state — ambiguity
must not guess.

Do **not** build tab-level state tracking: we need a boolean plus an optional title, not per-tab
precision.

### 15. UI tests
No UI test target. Pensieve's pattern exports and restores the app's `UserDefaults` domain around
the suite so a test run cannot shift real state — worth copying if this app ever writes state worth
protecting.

---

## P4 — Housekeeping

### 16. Remove the dead `showMenuBarIcon` setting
Registered in `AppSettings.Key` and in the defaults dictionary, but there is no property, no UI and
no reader. Either implement hiding the menu bar icon (it was a stated goal — "otherwise only as a
menubar item") or delete the key.

### 17. `lastAutomationError` is never cleared
Set on failure and rendered in the menu, but nothing resets it, so a single transient failure shows
until relaunch. Clear it on the next successful automation run.

### 18. Decide on a contributor licence agreement
AGPL-3.0 conflicts with Mac App Store terms, so the licence closes that door while it applies. That
stays reversible **only** while one party holds copyright to all the code. Accepting an outside
patch without a CLA ends that permanently. Decide before the first external pull request, not after.
Recorded as C6 in `constraints.md`.

### 19. Review the open Dependabot PR
`#1 ci: bump the github-actions group with 2 updates`. The three-day cooldown is configured, so
these are not same-day releases.

### 20. Sparkle is outside Dependabot's view
Declared in `project.yml` for the Xcode target, which Dependabot's `swift` ecosystem does not read;
bumped by hand. Pulling an updater framework into the dependency-free core to satisfy a scanner
would be worse. Recorded as C7 — check Sparkle's releases when touching the updater.

### 21. CHANGELOG
No changelog. Release notes are generated from `.github/templates/release.md`, which may be
sufficient — decide rather than drift.

### 22. CodeQL
GitHub auto-enabled default CodeQL setup on the public repo. Confirm it runs green and decide
whether to keep the default configuration or commit an explicit workflow.
