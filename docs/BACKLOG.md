# Backlog

Everything known to be outstanding as of 2026-08-26, ordered by priority within each section.
P0 now holds one open item — number 4.
Items carry the reason they matter, because a task without its rationale gets done wrong or
dropped for the wrong reason.

Related: [`constraints.md`](constraints.md) tracks platform limits and which are load-bearing;
[`teams-accessibility.md`](teams-accessibility.md) is the investigation record.

---

## Waiting on one meeting — planned for 2026-08-28

**Items 4, 5 and 6 are one sitting, not three tasks.** All three need the same input and nothing
else: a real Teams call. Deferred from 2026-08-27 for want of a meeting, so the next call is where
the project's only open P0 and its highest-leverage unknown both get settled. Run all three at once
— a call spent measuring one of them is a call wasted on the other two.

```sh
# before joining
make axprobe
/usr/bin/log stream --level debug --predicate 'subsystem == "me.mazetti.meetingfocus"'   # item 4
./.build/axprobe correlate com.microsoft.teams2 600                                      # item 5

# while sitting in the pre-join lobby, before joining
./.build/axprobe ids com.microsoft.teams2                                                # item 6
```

Then: mute for ~15 seconds, unmute, leave. What each one answers — detection → event → shortcut
firing in the real app (4); whether `input` ever reads `idle` while `ax` reads `in-call` (5); whether
the lobby exposes anything resembling `prejoin-join-button` (6).

The probe was blind to Teams' web tree until 2026-08-27 and is not any more; see the prerequisite
note under item 5. Also worth holding in view while running it: `correlate` reporting `ax=blind`
means the wake was refused, which is a finding about Chromium and not a result about muting.

---

## P0 — Correctness of claims already made

### 1. Re-release through CI so the shipped build actually has provenance — done
Released 2026-08-26 as **v0.1.2**, built by `.github/workflows/release.yml` on a GitHub-hosted
runner, notarized, stapled and attested. The two commands this item quoted as failing for v0.1.0
now pass, checked against the published artifact rather than against the workflow's own output:

```
gh attestation verify MeetingFocus-0.1.2.dmg   → exit 0, slsa.dev/provenance/v1
                                                 commit ff5531d, release.yml@refs/tags/v0.1.2
Info.plist :MFBuildCommit                      → ff5531dbed8e3ac352fb58646fa17192da02e095
xcrun stapler validate                         → valid
spctl -a -t install                            → accepted, source=Notarized Developer ID
```

The same commands against the v0.1.0 disk image still return `HTTP 404` and exit 1, which is what
makes the pass meaningful rather than a check that quietly no-ops. The appcast advertises 0.1.2, so
the README's provenance claim is now true for every download it points at.

Two releases were cut getting here, and neither wasted: v0.1.1 exposed that the archive depended on
a development certificate no runner has (fixed in `931adc1`), and v0.1.2 exposed the build-number
collision recorded as item 25. **v0.1.1 remains published, superseded, and deliberately absent from
the feed** — it was advertised to nobody, and re-cutting it would produce an artifact whose digest
no longer matches the notes and attestation already published against it.

### 2. Add the release secrets — done, and the workflow is now proven
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

The workflow has now run green twice end to end, so the five names above are confirmed correct as
split — three `secrets.`, two `vars.` The `vars.` correction in `905035f` was load-bearing: with
`secrets.NAME` for a variable expanding to the empty string, the first real run would have aborted
in `signing.sh` before building anything.

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

Prerequisite discharged 2026-08-27: the probe did not perform the write that wakes Chromium's web
tree — only the app did — so this run would have read `ax` as `no-call` for the whole call and
measured nothing. `AccessibilityWake` is now shared with `axprobe` through `AXPROBE_SOURCES`, and
`correlate` distinguishes a blind run from a call-less one in its own summary rather than reporting
both as `INCONCLUSIVE` with the same wording.

Join a real call, mute for ~15 seconds, unmute, leave. The answer is whether `input` ever reads
`idle` while `ax` reads `in-call`. Verified so far only against an idle Teams and against
CoreAudio directly (`corespeechd` reads `IsRunningInput=1`, so the audio half is live); the
in-call half is unmeasured because it needs a call.

### 6. Verify or remove the `joining` marker ids
`Resources/teams-markers.json` carries `prejoin-join-button` / `prejoin-join-btn` marked
`UNVERIFIED` — they are inferred, never observed. A 26-second lobby *was* measured, so the state is
real; the ids are guesses. Capture the lobby with `axprobe ids com.microsoft.teams2` while sitting
in a pre-join screen, then either fix them or delete them. (That command only became trustworthy on
2026-08-27 — see the prerequisite note under item 5; before it, an empty capture would have been the
dormant tree rather than a wrong guess.) Shipping a guess that silently never
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

### 8. App icon — shipped
`Icons/MeetingFocus.icon` is an Icon Composer bundle, named by `ASSETCATALOG_COMPILER_APPICON_NAME`
and compiled by actool into `Assets.car`, so Finder, Login Items and the update dialog all show it.
The same compile step emits `MeetingFocus.icns` inside the bundle, which the release script reuses
as the disk image's volume icon and the onboarding welcome step reads back via
`NSApp.applicationIconImage` — one drawing behind all four, with nothing to redraw by hand.

The menu bar deliberately still uses an SF Symbol: it has to carry meeting state, which a fixed app
icon cannot.

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

### 13. UI tests — reframed 2026-08-26, and partly answered
The gap worth closing was never really *UI* tests. It was that nothing in the app target is
testable at all: `swift test` compiles none of it, which is why item 17's fix had to move into
`MeetingFocusCore` before it could be verified, and why `ShortcutListing` was put there rather than
beside the subprocess that produces its input.

A hosted Xcode unit-test target was considered and rejected. `Package.swift` already records why —
`xcodebuild test` "spent well over a minute spinning up a test host for logic that needs none" —
and this app makes it worse: it is `LSUIElement`, so a test host would launch the real menu bar
app, start monitoring and instantiate the updater on every run.

The rule adopted instead: **a decision belongs in the core, where it can be tested; the app target
holds platform glue and views.** `ExecutablePath.outermostApplicationBundle(forExecutableAt:)` is
the first migration under it — the rule behind constraint D1, a *verified* bug that had no test
because it lived in the app target. It is pure path arithmetic, so it moved; reading the resolved
bundle's identifier needs a live pid and a file system, so that stayed.

Note the file is compiled two ways deliberately, and `make axprobe` proves it: `BundleIdentifierResolver`
is shared with the probe by a flat `swiftc`, which has no module to import, hence the `canImport`
guard rather than a second copy free to drift.

**Still open:** genuine UI tests over the onboarding flow, and Pensieve's `UserDefaults`
export/restore pattern around any suite that touches settings — which matters more now that
identifiers are stored there. Deprioritised rather than dismissed: XCUITest is slow and flaky, and
every decision moved into the core is one it no longer needs to cover.

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

## P5 — Surfaced while building onboarding

Onboarding (item 9) is what put working automation in front of a new user for the first time, and
in doing so it surfaced gaps nothing had exercised before. None of these blocked shipping it; each
needs its own reason recorded so it does not get done for the wrong one.

### 17. `MeetingMonitor.restart()` is never called — done
Fixed 2026-08-26 in `1fe3005`, both halves. `MeetingMonitor` now observes the detector settings
directly — rather than hooking `SettingsView.onChange`, so that onboarding growing the same switches
cannot silently reintroduce this — and `MeetingStateMachine.retractEvidence(fromDetector:)` supplies
the half without which calling `restart()` would have been a regression. The prerequisite this item
named is therefore discharged: onboarding can have a detector step.

Original reasoning, kept because it is what the fix had to satisfy:

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

### 18. `defaultAudioAllowlist` is a hardcoded Swift constant — done
Fixed 2026-08-26, and the reasoning below needed correcting first. The C2 analogy is only half
right: `teams-markers.json` ships *inside a signed bundle*, so a user editing it breaks the
signature — patchability by data was never a user-facing property, only a contributor-facing one.

So this shipped as both halves. `Resources/audio-allowlist.json` makes covering another application
a reviewable JSON edit rather than a Swift change; and an optional
`~/Library/Application Support/MeetingFocus/audio-allowlist.json` lets a user whose application is
not covered fix it themselves, which is the difference between the app working for them and not.
The override is additive only — it cannot disable a shipped entry, because a file with no presence
in the UI is the wrong place to silently switch detection off. Documented in the README; a Settings
list is the answer if it turns out people need one, and is not built.

The merge rule lives in `MeetingFocusCore.AudioAllowlist` with nine tests, including one that
decodes the real shipped file and asserts it has not drifted from the built-in fallback — two
copies of one list being exactly what diverges unnoticed.

Original note:
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

---

## P6 — Surfaced while auditing what happens to a Focus mode already on

Both were found by asking the one question detection never asks: not "is there a meeting?" but
"having turned the user's Focus on, is there still anything in the system that could turn it back
off?" Twice the answer was no. Fixed together on 2026-08-26; recorded because the reasons still
govern anything that touches the end path.

### 23. Automation state did not survive the process — done
`AutomationCoordinator` held the running meeting in a field, so quitting, crashing, taking a Sparkle
update or rebooting mid-call destroyed the only thing that could ever have run the end shortcut. The
Focus mode stayed on until the user turned it off by hand. A relaunch landing during the same call
was worse, and is the fingerprint the bug was recognised by: with nothing recorded, the coordinator
started from idle and ran the *start* shortcut a second time over a Focus that was already on.

**A Focus mode is a system-wide fact, so the belief that we turned one on is now persisted like
one.** `AutomationStateStore` is written before each command is handed on — never beside it, so what
is recorded and what was run cannot disagree — and adopted at construction. The protocol lives in
`MeetingFocusCore` where the decision is testable; `AutomationStateDefaults` in the app target is the
`UserDefaults` half, deliberately *not* part of `AppSettings`: nobody chose it and nothing in
Settings shows it.

Not covered, and worth knowing before this is assumed to be more than it is: the store records a
meeting, not a shortcut run. An end shortcut that fails at launch fails exactly as it would at any
other time, and the mapping from command to shortcut still lives in the app target, which has no
test host — item 13's gap.

### 24. A hold on unusable evidence had no bound — done
`MeetingStateMachine` holds the previous state when evidence resolves to nothing, so that a
transient loss of accessibility can never end a meeting. That rule is right and stays. What was
missing is that **staleness is not the only way evidence becomes unusable**: `indeterminate` is
discarded however fresh it is, so a detector that has gone blind while still reporting kept the hold
alive forever. A dormant Teams accessibility tree during a muted call has exactly that shape, and
the result was a meeting nothing in the system could end.

The hold is now bounded by `Configuration.unresolvedHold` at ten minutes — long past any real
hiccup, finite because "hold forever" means a Focus mode that never comes back off. Giving up is not
going deaf: the subject starts the next meeting normally.

Related, and decided at the same time: `endCooldown` drops from 45 seconds to 20. Constraint D3
measured the back-to-back gap at 12 seconds, which is the only thing the wait is for; the remaining
half-minute was silence after a call that was already over, and long enough that reaching for the
Focus toggle yourself was the faster option. Existing installations keep whatever value they have.

### 25. Two releases shared one build number — done
Fixed 2026-08-26, and found the only way it could have been: by generating the feed and reading what
came out. Sparkle compares `CFBundleVersion`, not the marketing version, so 0.1.1 — stamped `1`, as
0.1.0 was — was not an update to an installed 0.1.0 at all. `generate_appcast` said as much:

```
Wrote 0 new updates, updated 1 existing update, and removed 0 old updates
```

It had rewritten 0.1.0's entry in place, producing a single item titled `0.1.0` that advertised the
0.1.1 download, with the older release gone. Deployed, it would have offered nobody anything.

**The intent was already in `release.yml`, and had never once worked.** `CURRENT_PROJECT_VERSION:
${{ github.run_number }}` was set as a step *environment variable*, and xcodebuild takes build
settings from its command line, not from the environment — so `project.yml`'s hardcoded `"1"` won
every time. Run number 2 produced a bundle stamped `1`. A setting that looks wired up and silently
does nothing is worse than one that is missing, because nothing ever asks after it.

Two changes, and the second is the one that matters: `release.sh` now forwards the value into the
archive as a build setting; and before notarizing, it compares the built bundle against the highest
`sparkle:version` in the published feed and refuses to continue unless it is strictly newer. The
failure was knowable from the bundle alone — no Apple round trip, no signature, no human noticing a
number had not moved. CI's first run under the check printed `build 3 supersedes the published 1`.

Worth keeping in view: this is the second bug in two releases whose shape was *a local build
depending on something not present in the artifact or the repository* — the first being the
development certificate of item 1. Both are the reason releases are built in public, and neither
would have surfaced from the tests.
