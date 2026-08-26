# Backlog

Everything known to be outstanding as of 2026-08-26, ordered by priority within each section.
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

**No longer blocked**, and `v0.1.1` is staged: `project.yml` reads `0.1.1`, `CHANGELOG.md` has a
`[0.1.1]` section — including the onboarding entry it was missing, which README documented and the
changelog did not — and `Scripts/preflight.sh 0.1.1` passes every check but one. The exception is
the working tree, dirty with the in-progress ⌥ diagnostics work; `git tag` tags HEAD, so that has to
land first or it simply would not ship. What remains after it does: push the local commits, then
`git tag v0.1.1 && git push origin v0.1.1`.

### 2. Add the release secrets — done; the workflow itself is still unproven
Added 2026-08-26, split by what each thing actually is:

| Name | Kind | Contents |
|---|---|---|
| `SIGNING_DATA` | secret | base64 of the Developer ID Application `.p12` |
| `SIGNING_PASSWORD` | secret | its export password |
| `APPLE_API_KEY_DATA` | secret | contents of the App Store Connect `.p8` |
| `APPLE_API_KEY_ID` | variable | key id |
| `APPLE_API_ISSUER` | variable | issuer id |

The last two are variables rather than secrets deliberately: they are identifiers, useless without
the `.p8`, and `notarytool` puts them in its own output and file paths anyway. `release.yml` was
written against `secrets.` for all five — and `secrets.NAME` for a name that is a *variable*
expands to the empty string, so `signing.sh` would have aborted the run before anything was built.
It now reads those two through `vars.`.

Note what this asks: the Developer ID key must exist on a runner, in an ephemeral keychain on a
disposable VM. The alternative is every user trusting an unverifiable binary. It is a real trade
and should be made knowingly, not by default.

Whether the workflow *runs* is a separate claim, and still an untested one — that is item 1.

### 3. Back up the Sparkle private signing key — done
Backed up 2026-08-26, confirmed by the maintainer. Kept here rather than deleted because the reason
still governs: the key is the single point of failure for the project's ability to fix itself, since
detection depends on Teams element ids that *will* be renamed. Anything that regenerates it — a new
machine, a wiped keychain — re-opens this item.

### 4. Verify the app's in-meeting path end to end, at least once
Never observed. The app has only ever reported `notInMeeting` — and as of 2026-08-26 the reason
is known, which is the substance of this item rather than a detail of it. Chromium publishes web
content to the accessibility API only once it believes an assistive client needs it, and *reading*
the tree does not convince it. Measured during a live call: the whole Teams application exposed 42
nodes and **zero** `AXDOMIdentifier` elements. The app was not mismatching markers; it was blind,
and reporting `notInMeeting` from that. `TeamsAccessibilityDetector.wakeAccessibilityTree` now
performs the write that wakes it, and a scan that finds no identifiers at all reports
`indeterminate` rather than absence, so a blind definitive detector can no longer outrank the
microphone tier. See `teams-accessibility.md` §7.

This makes the end-to-end run far more likely to succeed, and does not replace it. The marker logic is byte-identical
to what ran correctly against three real meetings on 2026-08-25 and the state machine is
unit-tested, but **detection → event → shortcut has not fired in the real app**. Watch it during
one real call:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "me.mazetti.meetingfocus"'
```

Onboarding now sets `startShortcutName` and `endShortcutName` itself — it installs and selects both
Do Not Disturb shortcuts before the user ever reaches Settings, which is what this item used to name
as the blocking prerequisite. What remains is holding one real meeting and watching the log. Opening
the menu bar item with ⌥ held also lists each detection while the call runs.

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

### 7. Confirm whether Graph's `InAMeeting` is calendar-derived — answered: yes
Answered 2026-08-26 from Microsoft's own documentation. It is calendar-derived, explicitly and by
design:

> The `setPresence` method doesn't support setting the presence states **Out of office (OOF)** or
> **In a meeting** directly. These states are automatically managed based on calendar events and
> mailbox configurations […] The **"In a meeting"** state is automatically reflected during
> scheduled calendar meeting events and doesn't require manual presence updates.
> — [Manage presence state using the Microsoft Graph API](https://learn.microsoft.com/en-us/graph/cloud-communications-manage-presence-state)

The Teams admin documentation draws the line in the same place, and it is the useful half of the
finding — different states come from *different sources*:

> a user's status is based on user activity (whether they're **Available** or **Away**); on the
> state of the Teams app (for example, whether they're **In a call** or **Presenting**); and on
> their Outlook calendar (for example, whether they're **In a meeting**).
> — [User presence in Teams](https://learn.microsoft.com/en-us/microsoftteams/presence-admins)

**So `inAMeeting` means "a meeting is on this person's calendar right now", not "this person
joined anything".** It fires for a declined-but-not-removed invitation, for a meeting slept
through, for a calendar block someone uses as focus time. As a meeting signal it is exactly the
false positive this item feared.

**This does not sink the provider tier; it re-points it.** `inACall` and `presenting` come from the
Teams application's own state, which is real call state. M2 should key on those two and treat
`inAMeeting` as calendar noise — usable, at most, as `corroborating` alongside something else.

Caveats found alongside, all of which bear on M2 and none of which were known before:

- **Which field carries it is documented inconsistently.** The permutation table gives
  `availability / activity` as `busy / inAMeeting` and `busy / inACall`, but the
  [presence resource](https://learn.microsoft.com/en-us/graph/api/resources/presence?view=graph-rest-1.0)
  lists `inACall`, `inAMeeting`, `presenting` and `focusing` under **availability**, and omits them
  from **activity**. The two pages contradict each other, so an implementation should match on
  either field rather than trusting one.
- **Latency is minutes, not seconds.** "Because the Teams client uses poll mode, it takes a few
  minutes to update the presence status" — and mailboxes hosted on-premises are documented at up to
  a *one hour* delay. Far too slow to drive a Focus on its own; this is corroboration, not a trigger.
- **A user can override presence by hand**, and a manual Busy or Do-not-disturb persists for a day.
- **Presence aggregates across every device**, resolving to whichever the user touched most
  recently — the existing note that remote evidence describes the *user* rather than this Mac is
  not just a privacy framing, it is literally how the value is computed.
- Presence *does* support change notifications, so the transport note below is about the cost of
  webhooks, not about whether subscriptions exist at all.

---

## P2 — Requested features

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

### 22. Calendar tier — meeting names, and a nudge on borderline starts
Decided 2026-08-26: the calendar **names** meetings and may **weakly corroborate** a start. It never
starts or ends one on its own.

That boundary is the whole design, and it comes straight out of item 7. Graph's `inAMeeting` is
calendar-derived, and reading the same calendar locally does not make it any more truthful about
whether the user actually *joined*: a declined-but-undeleted invitation, a meeting slept through and
a focus-time block all look identical to attendance. What the calendar knows is what was *scheduled*.

**Why local EventKit rather than the provider integrations of item 10.** `EKEventStore` reads
whichever accounts the user already has in Calendar.app, which for most people includes their
Microsoft 365 or Google calendar. That means no OAuth flow, no app registration, no Keychain token
storage, no public HTTPS endpoint for webhooks, and — decisively — no corporate tenant admin who can
refuse the registration outright, which is the reason item 10 says the provider tier can never be the
foundation. This does not merely simplify M2's Microsoft Graph row; it removes most of its purpose.
It also largely supersedes item 12, which exists only to source meeting *names* from browser tabs; a
calendar event is a better title than a tab title, and the audio tier currently produces no title at
all for Zoom, Meet or Slack.

**Rules, most of them inherited rather than invented:**

- Only events the user is actually busy for. Skip `EKEventAvailability.free`, and skip declined
  invitations. This mirrors Teams' own behaviour — a calendar item must be marked Busy or Out of
  Office before it affects presence — so the same events count in both systems.
- Two events overlapping now: drop the name, keep the state. Item 12's ambiguity rule, unchanged.
  Ambiguity must not guess.
- Corroboration means shortening `corroboratingStartGrace` (3s today) while a busy event is in
  progress, and nothing more. `EvidenceFusion` already resolves highest-confidence-first, so
  calendar input entered as `corroborating` can never override the Teams AX tier's `definitive`
  verdict.

**Unresolved, and the reason this is not simply another detector:** `MeetingEvidence.subjectID` is a
bundle identifier, and `MeetingStateMachine` keys its subjects by application. A calendar event has
no process, so it does not fit the `MeetingDetector` protocol. Two ways out, and the choice can be
deferred:

1. Treat the calendar as *enrichment* consulted when a meeting is created, not as evidence at all.
   Enough for the job as scoped, and it keeps the subject model untouched.
2. Attribute an event to a bundle by its join URL — `teams.microsoft.com/l/meetup-join`,
   `zoom.us/j/`, `meet.google.com` — which makes it fit the protocol properly, but reports nothing
   for events with no link, meaning in-person and phone meetings.

(1) is the smaller change and covers what was decided; (2) only becomes worth it if the corroboration
half needs to be per-application.

**Costs.** A second TCC prompt (`requestFullAccessToEvents`, with
`NSCalendarsFullAccessUsageDescription` in the bundle — the deployment target is macOS 26, so the
pre-macOS-14 `requestAccess(to:)` path does not apply), landing right after the Accessibility prompt
that onboarding was just built around. Reading someone's calendar also *feels* more invasive than
reading microphone activity, so this wants its own toggle and probably ships default-off.

---

## P3 — Roadmap

### 10. Provider integrations (M2)
One provider end to end, plus Keychain storage and an OAuth flow. Transports researched:

| Provider | Signal | Transport for a desktop app |
|---|---|---|
| Microsoft Graph | `inACall` / `presenting` — **not** `inAMeeting`, which is calendar-derived (item 7) | poll `GET /me/presence`; subscriptions need a public HTTPS endpoint and expire hourly |
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

**Largely superseded by item 22.** Naming is this item's only purpose, and a calendar event is a
better title than a tab title, for less work and no per-browser study. Keep this only for meetings
with no calendar entry at all — an ad-hoc Meet link someone was sent in chat.

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

**Calling `restart()` is not on its own the fix, and shipping only that would be a regression.**
`restart()` tears the detectors down and builds them again, but it does not touch
`MeetingStateMachine`, which keeps the evidence they already produced. When every piece of a
subject's evidence has aged past `evidenceTTL` (30s), `EvidenceFusion.resolve` returns `nil`, and
`MeetingStateMachine.evaluate` then *holds the previous state* rather than assuming idleness —
deliberately, so that a temporary loss of Accessibility can never end a meeting. Nothing else can
clear it: the only authoritative reset is `applicationTerminated`.

So turning off the detector that is currently the sole evidence for a live meeting would strand the
app `inMeeting` permanently — menu stuck, and the end shortcut never fired, meaning the user's Focus
stays on until they quit the meeting app or relaunch. That is worse than today's do-nothing toggle.

The fix therefore needs evidence retraction as well: a way to tell the machine that a detector's
evidence is gone, removing it from every subject and — where nothing else is left saying otherwise —
ending the meeting authoritatively, with the `.ended` event that releases the Focus. That belongs in
`MeetingFocusCore`, where it is unit-testable, rather than in the app target, which has no tests.

### 18. `defaultAudioAllowlist` is a hardcoded Swift constant
Covering a new meeting app in the audio tier needs an app release, not a data change —
`MeetingMonitor.swift` holds the allowlist inline. C2 externalised the Teams markers to
`Resources/teams-markers.json` for exactly this reason: a fix should be a data change, not a code
change. This list arguably belongs in the same patchable seam.

### 19. The generated shortcut's name doubles as its identifier — done
Fixed 2026-08-26, together with item 20: they were one bug wearing two hats, since both come from
identity and display name being the same string.

`shortcuts run` turns out to accept `<shortcut-name-or-identifier>`, and `shortcuts list
--show-identifiers` prints `Name (UUID)` — so identity was available all along. `AppSettings` now
stores `startShortcutIdentifier` / `endShortcutIdentifier` beside the names, onboarding records them
after installing, the Settings picker records one when the user chooses a shortcut by hand, and
`ShortcutsAutomationHandler` prefers the identifier and falls back to the name. The fallback is what
carries an installation configured before this existed.

Worth naming because the backlog did not: this also fixes the likelier version of the same bug.
A user who renames either shortcut in Shortcuts — entirely reasonable, they are their shortcuts —
used to silently lose their automation. Now it follows the rename.

Parsing lives in `MeetingFocusCore.ShortcutListing` rather than beside the subprocess, because the
awkward part is the string: a shortcut's *name* may contain parentheses too, so the identifier is
recognised from the right and confirmed to be a UUID. Six tests, including `Backup (old) (UUID)`
and `Morning routine (v2)`.

### 20. Retrying a partly-failed install can leave a numbered duplicate — done
Fixed 2026-08-26 as part of item 19. `OnboardingFocusStep.install()` now installs only the
directions actually missing, testing for each by stored identifier first and current name second.
The identifier check is the half that survives a language change, under which the installed pair
carries names this launch would never recognise.

Original report, kept for the reasoning:
`OnboardingFocusStep.install()` retries both directions from scratch, with no record of which one
already succeeded. A timeout on one direction followed by a retry produced `MeetingFocus – Fokus
aus 1` in Shortcuts during testing. Harmless — `ShortcutsAutomationHandler` binds on exact name, so
the duplicate never gets picked — but it clutters the shortcut library and asks the user to confirm
an Add they already gave once.

### 21. TipKit for the menu bar icon
Apple's own onboarding guidance names TipKit as the recommended alternative to a single onboarding
flow, and a tip anchored to the actual menu bar icon is a more native answer to "where did the app
go?" than a sentence in the final onboarding step.
