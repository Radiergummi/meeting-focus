# Constraint register

Re-audited 2026-08-25 against the sharpened scope: **notarized Developer ID app, DMG via GitHub
Releases, macOS only, App Store and iOS deferred indefinitely.**

Purpose is to find decisions that would be expensive to reverse. Each entry says whether it
actually corners us.

---

## A. Hard constraints — permanent, no workaround

### A1. No public API sets a Focus mode
`INFocusStatusCenter` is read-only and needs the Communication Notifications capability.
Shortcuts is the *only* supported route to changing Focus.

**Corners us?** No, but it caps the product: we can never be more than a trigger for a Shortcut.
The mitigation (onboarding generates, signs and installs the shortcut) removes the authoring
burden, not the dependency. Marketing must promise "triggers your automations", never "controls
Focus directly".

### A2. `AXDOMIdentifier` values are Teams' internal HTML ids
Microsoft can rename them in any release with no warning and no deprecation path.

**Corners us? YES — this is the highest risk in the project**, and only in combination with C2
(no update channel). See C2 for the mitigation, which is the important one.

### A3. Detection must never match localized strings
The investigation machine ran a German UI. Roles, descriptions and window titles are all
translated.

**Corners us?** No — already designed around. Worth restating because it is easy to regress:
any future detector must be reviewed for string matching.

### A4. No API enumerates the user's Focus modes
`INFocusStatusCenter` only reports whether *a* Focus is currently active, and needs the
Communication Notifications capability even for that. The only source that lists Focus modes by
name is `~/Library/DoNotDisturb/DB/ModeConfigurations.json`, which is TCC-protected: reading it
needs **Full Disk Access**, the broadest permission macOS grants. Full Disk Access cannot be
requested programmatically — the user must add the app by hand in System Settings.

Found the expensive way: during the design spike the file was read successfully from a shell that
happened to already hold Full Disk Access, and the spec generalised from that one read to
"readable, no prompt, no API" — a Focus picker was designed on that premise. The app itself cannot
read it. Its own unified log said so: `no Focus configuration file at
/Users/moritz/Library/DoNotDisturb/DB/ModeConfigurations.json` — logged by `FocusModeCatalog`,
since deleted. Anything verified from a
privileged shell must be re-verified from the app's own process before it becomes a design
assumption.

**Corners us?** It caps what onboarding can offer, not the architecture. MeetingFocus installs a
shortcut that targets Do Not Disturb and tells the user how to retarget it; the user's own Focus
modes remain reachable to *them* inside Shortcuts, just not enumerable by *us*.

---

## B. Constraints removed by dropping the App Store

### B1. App Sandbox no longer applies
Cross-app Accessibility is available again; `Process` may spawn `/usr/bin/shortcuts`; no
`temporary-exception` entitlements needed; `SMAppService` is a free choice.

**Reversibility check:** if the App Store is ever revisited, the audio tier was *measured* to work
under sandbox (40 process objects, 37 bundle IDs, correct attribution), and the evidence model
supports compiling a detector subset. So this relaxation does not burn the App Store option.

---

## C. New constraints introduced by direct distribution

### C1. Notarization requires hardened runtime and Apple credentials
Developer ID Application signature + secure timestamp + hardened runtime, then `notarytool`.
Nothing we need conflicts with hardened runtime (AX and subprocess spawning are both fine).

**Corners us?** No. **Resolved.** Credentials are stored as the keychain profile
`MeetingFocus-Notary`, and `Scripts/release.sh` runs the full pipeline: archive, export, notarize
and staple the app, build the disk image, sign *and* notarize *and* staple that too, then verify
Gatekeeper accepts both.

Learned the hard way: stapling only the app leaves the disk image unsigned, and `spctl` then reports
`no usable signature` for the download even though the app inside is properly notarized. Both
artifacts need their own signature and ticket.

### C2. There is no update channel
GitHub Releases alone means users sit on whatever version they downloaded.

**Corners us? It would have — resolved.** Combined with A2 the failure mode was: Teams renames an
id, detection silently stops working, and there is no way to deliver a fix to anyone who already
installed. Both mitigations are now in place:

1. **Marker definitions are externalised** to `Resources/teams-markers.json`, so a fix is a data
   change rather than a code change. (This immediately justified itself: the file silently failed to
   decode on first run because Swift's synthesized `Decodable` does not apply property default
   values, and the app fell back to hardcoded markers — exactly the failure the externalisation was
   meant to prevent. Fixed with an explicit initializer.)
2. **Sparkle 2.9.6 is wired**, with an EdDSA-signed appcast generated by the release script and
   verified to contain a signature before publishing. Feed:
   `https://meetingfocus.mazetti.me/appcast.xml`.

The appcast deliberately uses version-pinned download URLs rather than `releases/latest/download`:
`latest` would make every entry, including older ones, resolve to the newest asset. The script also
seeds from the published appcast so previously released versions keep their entries.

**Remaining exposure:** the Sparkle private key lives only in the maintainer's login keychain. If it
is lost, no existing installation can ever be updated again. Backing it up is now the single most
important operational task in the project.

3. Still available later: a remote marker manifest so fixes need no app update at all. The
   externalised config in (1) is the seam that makes it possible without redesign.

### C3. Selling outside the App Store needs licensing and payments
License keys plus a payment provider, and a trial mechanism.

**Corners us?** No — purely additive, and revenue is explicitly a side-benefit. Do not build
license infrastructure in M1. Do not add feature gates speculatively either.

### C4. The bundled `.shortcut` may not be trusted
macOS Shortcuts can refuse or warn on unsigned shortcut files. The "one-click Focus setup" promise
depends on this working smoothly.

**Corners us?** Only the onboarding story, not the architecture.

**Resolved: nothing is ever bundled.** The shortcut is generated on the user's own machine and
signed there, by the user's own copy of Apple's tool, `/usr/bin/shortcuts sign --mode anyone`. No
bundled-file trust question arises at all, because no unsigned file is ever shipped.

Two mechanics behind that, both found by hitting them, and both producing the *same* unhelpful
error ("The file couldn't be opened because it isn't in the correct format"):

1. the input must be a **binary** plist — an XML plist is rejected outright;
2. the input **filename** must end in **`.shortcut`**, regardless of the file's actual contents.

Worth one more line: the imported shortcut takes its **name from the filename**, which is why the
installer writes the plist to a path already named as the shortcut should be named, rather than
renaming afterwards.

### C5. Automation permission for driving Shortcuts
Spawning `/usr/bin/shortcuts` may raise an Automation TCC prompt attributed to MeetingFocus. A
missing `NSAppleEventsUsageDescription` in `Info.plist` turns that into a silent denial.

**Corners us?** No. Easy to miss, cheap to get right, so recorded here.

---

## D. Constraints discovered by measurement today

### D1. Helper bundle IDs must normalise to the parent app — verified bug
The audio tier sees `com.microsoft.teams2.modulehost` / `…teams2.helper`, not
`com.microsoft.teams2`. Fusion groups evidence by subject id, so without normalisation Teams
appears as several distinct "meetings" and the AX detector's definitive verdict never overrides
the audio tier's.

The obvious fix was also wrong: `NSRunningApplication(processIdentifier:)` returns the *helper's
own* bundle id, because Teams' helpers are themselves registered `.app` bundles. Verified correct
approach — resolve `proc_pidpath`, walk to the **outermost** `.app`, read its `Info.plist`:

```
ModuleHost   pid 71771 → com.microsoft.teams2      [outermost→Microsoft Teams.app]
Teams WebView pid 71743 → com.microsoft.teams2      [outermost→Microsoft Teams.app]
wispr helper  pid 4290 → com.electron.wispr-flow   [outermost→Wispr Flow.app]
CoreSpeech    pid 2821 → nil                       [non-app process]
```

Non-app daemons resolving to `nil` is desirable: they can never match a meeting-app allowlist.

**Corners us?** Would have. Caught before implementation.

### D2. Traversal caps must be generous
Observed whole-app node counts 250 – 3,479, varying by what the main window displays. A cap tuned
to the meeting window (~150 nodes) silently truncates and yields false negatives. Cap 25,000,
depth 70, rely on early exit for speed.

### D3. Back-to-back meetings are normal
Measured a genuine 12-second gap between two real meetings. Automation needs an `endCooldown`
(45 s default) separate from detection debounce, or Focus flaps between consecutive meetings.

### D4. AX polling does **not** measurably cost Teams CPU
Instantaneous sampling, Teams idle, 2 s poll of a ~434-node tree:

```
with polling:    3.9 / 7.6 %
without polling: 3.8 / 7.7 %
```

**Constraint removed.** An earlier draft proposed gating deep AX walks behind an audio hint to save
CPU; that is now unjustified complexity, and it had a correctness hole anyway — users who
**join muted** would never trigger the audio gate and their meeting would go undetected.
Straightforward polling stands.

Caveat: this measures steady-state polling, not the one-time cost of Chromium *activating* its
accessibility tree, and the in-meeting tree is larger (3,479 nodes). Neither looks material.

### D5. Teams releases the microphone when idle
Measured repeatedly with no meeting: `teamsCapturing=false`, `capturing=[none]`. So Teams sitting
open does not produce a false positive for the audio tier.

---

## E. Deferred decisions that remain reversible

Recorded so nobody treats them as closed doors.

| Deferred | Still reversible because |
|---|---|
| App Store / sandboxed SKU | audio tier measured working under sandbox; evidence model supports detector subsets. **But see C6 — the AGPL licence now blocks this until relicensed** |
| iOS app | not needed for the use case — Focus syncs across devices, so the Mac silences the iPhone |
| Provider OAuth tiers | evidence model already accepts corroborating, high-latency, user-scoped evidence |
| Zoom / Slack / browser AX detectors | purely additive; each is one detector plus a marker study |
| Monetisation | additive; no architectural dependency |

---

## F. Open questions, in order of leverage

1. **Does muting release the microphone stream?** Now instrumented (`mute-watch.log`, supervised
   so it survives crashes and meeting ends). **This sizes the roadmap**: if mute releases the
   stream, every app we want to support properly needs its own AX detector; if not, the audio tier
   covers Zoom, Slack, Meet and Discord correctly with no per-app work. Strong prior that it does
   *not* release it, since both Teams and Zoom ship a "you're muted, we can hear you talking"
   prompt, which requires capturing while muted.
2. **Does `joining` count as in-meeting for automation?** Product decision. Recommendation: no —
   keep the lobby state for the UI only. A 26-second lobby was measured, so firing automation there
   would enable Focus before the user has actually joined.
3. **Is Graph's `InAMeeting` calendar-derived?** Gates the provider tier (M2), not M1.

### C6. AGPL-3.0 closes the App Store door

The project is licensed AGPL-3.0, whose terms conflict with the Mac App Store's, so a sandboxed
App Store SKU is not distributable while that licence applies.

**Corners us?** Not permanently, and only by choice. The copyright holder can relicense or
dual-license at will — but only while they hold copyright to all of the code. Accepting outside
contributions without a contributor licence agreement would end that, making the App Store option
genuinely unreachable. Decide on a CLA before the first external pull request, not after.

### C7. Dependabot cannot see the Sparkle dependency

Dependabot's `swift` ecosystem reads `Package.swift`. Sparkle is declared in `project.yml` for the
Xcode app target, because the app is not a SwiftPM target, so it falls outside what Dependabot
scans. `github-actions` is covered; Swift packages are covered only for `MeetingFocusCore`, which
deliberately has none.

**Corners us?** No. The fix would be to declare Sparkle as a dependency of `MeetingFocusCore` so it
appears in the manifest — which is worse: the core is deliberately free of platform APIs and
dependencies so `swift test` stays instant and the logic stays portable. Pulling an updater
framework into it to satisfy a scanner inverts that.

So Sparkle's version is bumped by hand. It is pinned by the committed `Package.resolved`, and the
release workflow would fail loudly on an incompatible bump, so the exposure is a missed update
rather than a silent one. Worth checking its releases when touching the updater.
