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

Onboarding now sets `startShortcutName` and `endShortcutName` itself — it installs and selects both
Do Not Disturb shortcuts before the user ever reaches Settings, which is what this item used to name
as the blocking prerequisite. What remains is holding one real meeting and watching the log. Turning
on Settings → Diagnostics → Debug mode also makes each detection visible in the menu while the call
runs.

Accessibility is granted: `me.mazetti.meetingfocus` carries `auth_value = 2` for
`kTCCServiceAccessibility`, so nothing is blocked on permission.

---

## P1 — Known unknowns that size the roadmap

### 5. Settle whether muting releases the microphone stream
**This decides how much per-app work the product needs.** If mute releases the input stream, every
application we want to support properly needs its own Accessibility detector; if it does not, the
audio tier covers Zoom, Slack, Meet and Discord correctly with no per-app work and per-app
detectors become optional polish.

Teams is unaffected either way (its Accessibility evidence is definitive and overrides audio), so
this is not a blocker — but it is the highest-leverage unknown in the project.

Strong prior that it does **not** release the stream: both Teams and Zoom ship a "your mic is muted,
we can hear you talking" prompt, which is only possible while capturing.

The correlator now exists as `axprobe correlate` (rebuilt 2026-08-25; the original lived in a
scratch directory and was lost). It samples both tiers once a second, prints only transitions, and
refuses to draw a conclusion from a run that never saw a call. What remains is running it:

```sh
make axprobe && ./.build/axprobe correlate com.microsoft.teams2 600
```

Join a real call, mute for ~15 seconds, unmute, leave. The answer is whether `input` ever reads
`idle` while `ax` reads `in-call`. Verified so far only against an idle Teams and against
CoreAudio directly (`corespeechd` reads `IsRunningInput=1`, so the audio half is live); the
in-call half is unmeasured because it needs a call.

### 6. Verify or remove the `joining` marker ids
`Resources/teams-markers.json` carries `prejoin-join-button` / `prejoin-join-btn` marked
`UNVERIFIED` — they are inferred, never observed. A 26-second lobby *was* measured, so the state is
real; the ids are guesses. Capture the lobby with `axprobe ids com.microsoft.teams2` while sitting
in a pre-join screen, then either fix them or delete them. Shipping a guess that silently never
matches is worse than shipping no `joining` state.

### 7. Confirm whether Graph's `InAMeeting` is calendar-derived
Blocks the provider tier (M2). If the activity is partly derived from calendar rather than actual
call state, it will report a meeting the user never joined — which would make it unusable as
anything but weak corroboration.

---

## P2 — Requested features not yet built

### 8. App icon
There is no asset catalogue and no `ASSETCATALOG_COMPILER_APPICON_NAME`, so the app ships with the
generic placeholder icon in Finder, Login Items and the update dialog. The menu bar itself uses an
SF Symbol and is fine.

### 9. One-click Focus setup — shipped
A four-step onboarding window now installs two locally signed Do Not Disturb shortcuts and selects
them automatically, so a fresh installation reaches working automation without the user ever
authoring a shortcut or typing a name. The reason this was deferred — macOS treats shortcut files
from unidentified sources as untrusted — no longer holds: the shortcut is generated and signed on
the user's own machine, so nothing unsigned is ever shipped and there is no bundled file to trust.
See `constraints.md` A4 and C4.

---

## P3 — Roadmap

### 10. Provider integrations (M2)
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

### 11. Native Zoom and Slack detectors (M3)
Slack is Electron/Chromium, so the `AXDOMIdentifier` technique should transfer directly. Zoom is
native AppKit and needs its own marker study — it may expose no stable identifiers at all, leaving
only localized titles. Neither is installed on the development machine, so both statements are
reasoning rather than findings.

### 12. Browser tier for naming meetings (M3)
Tabs are enumerable as `AXTabButton` with titles (verified on Safari), and web areas expose
`AXURL`, so `meet.google.com` is identifiable. Audio already covers the *state*; this only adds the
*name*. Where several capturing tabs are open, drop the identity and keep the state — ambiguity
must not guess.

Do **not** build tab-level state tracking: we need a boolean plus an optional title, not per-tab
precision.

### 13. UI tests
No UI test target. Pensieve's pattern exports and restores the app's `UserDefaults` domain around
the suite so a test run cannot shift real state — worth copying if this app ever writes state worth
protecting.

---

## P4 — Housekeeping

### 14. Decide on a contributor licence agreement
AGPL-3.0 conflicts with Mac App Store terms, so the licence closes that door while it applies. That
stays reversible **only** while one party holds copyright to all the code. Accepting an outside
patch without a CLA ends that permanently. Decide before the first external pull request, not after.
Recorded as C6 in `constraints.md`.

### 15. Sparkle is outside Dependabot's view
Declared in `project.yml` for the Xcode target, which Dependabot's `swift` ecosystem does not read;
bumped by hand. Pulling an updater framework into the dependency-free core to satisfy a scanner
would be worse. Recorded as C7 — check Sparkle's releases when touching the updater.

### 16. CodeQL: keep the default setup, or commit an explicit workflow
Default setup **works**. The `Analyze (swift)` job completed green in 25m11s and recorded one
analysis over 27 rules with 0 results and 0 alerts. (An earlier note here called the run stalled —
that was reading the run list while it was still going.) Current configuration:

    languages: [swift]   query_suite: default   threat_model: remote   schedule: weekly

Recommendation: keep it. It needs no maintenance, the 25 minutes is not on any critical path, and an
explicit workflow would add a file to maintain, a CodeQL action version for Dependabot to bump, and
a duplicated build for no extra signal at this size.

One thing worth revisiting inside the default setup, which is configurable without a workflow file:
`threat_model: remote` is the wrong model for a desktop app that opens no listening socket. The
local threat model is the one that fits what this app actually does — read other processes' UI and
run a user-named shortcut.

---

## P5 — Surfaced while building onboarding, not fixed

Onboarding (item 9) is what put working automation in front of a new user for the first time, and
in doing so it surfaced gaps nothing had exercised before. None of these blocked shipping it; each
needs its own reason recorded so it does not get done for the wrong one.

### 17. `MeetingMonitor.restart()` is never called
Toggling a detector in Settings does not take effect until the app relaunches — `restart()` exists
but nothing calls it. Pre-existing, not introduced by onboarding, but it is why onboarding has no
detector step: a toggle that silently does nothing until relaunch is worse than no toggle at all.
Fix this before adding one.

### 18. `defaultAudioAllowlist` is a hardcoded Swift constant
Covering a new meeting app in the audio tier needs an app release, not a data change —
`MeetingMonitor.swift` holds the allowlist inline. C2 externalised the Teams markers to
`Resources/teams-markers.json` for exactly this reason: a fix should be a data change, not a code
change. This list arguably belongs in the same patchable seam.

### 19. The generated shortcut's name doubles as its identifier
It is localized, and it is what gets stored in `startShortcutName` / `endShortcutName` and passed
to `shortcuts run`. Automation survives a system-language change, because the stored name is
written once and read back rather than re-derived — but re-running onboarding after changing the
system language will not recognise the existing pair under their new-language names and will
install a duplicate. Fix by storing identity separately from the display name shown in Shortcuts.

### 20. Retrying a partly-failed install can leave a numbered duplicate
`OnboardingFocusStep.install()` retries both directions from scratch, with no record of which one
already succeeded. A timeout on one direction followed by a retry produced `MeetingFocus – Fokus
aus 1` in Shortcuts during testing. Harmless — `ShortcutsAutomationHandler` binds on exact name, so
the duplicate never gets picked — but it clutters the shortcut library and asks the user to confirm
an Add they already gave once.

### 21. TipKit for the menu bar icon
Apple's own onboarding guidance names TipKit as the recommended alternative to a single onboarding
flow, and a tip anchored to the actual menu bar icon is a more native answer to "where did the app
go?" than a sentence in the final onboarding step.
