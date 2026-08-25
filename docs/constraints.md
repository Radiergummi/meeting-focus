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
The mitigation (bundled `.shortcut` + one-click install) removes the authoring burden, not the
dependency. Marketing must promise "triggers your automations", never "controls Focus directly".

### A2. `AXDOMIdentifier` values are Teams' internal HTML ids
Microsoft can rename them in any release with no warning and no deprecation path.

**Corners us? YES — this is the highest risk in the project**, and only in combination with C2
(no update channel). See C2 for the mitigation, which is the important one.

### A3. Detection must never match localized strings
The investigation machine ran a German UI. Roles, descriptions and window titles are all
translated.

**Corners us?** No — already designed around. Worth restating because it is easy to regress:
any future detector must be reviewed for string matching.

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

**Corners us?** No. **Blocks release though:** requires an App Store Connect API key or
app-specific password that only the maintainer can create.

### C2. There is no update channel
GitHub Releases alone means users sit on whatever version they downloaded.

**Corners us? YES — and this is the one to fix before shipping.** Combined with A2 the failure
mode is: Teams renames an id, detection silently stops working, and there is no way to deliver a
fix to people who already installed. Three mitigations, in order of value:

1. **Externalise the marker definitions** into a bundled JSON/plist rather than hardcoding them in
   Swift. Makes a fix a one-line data change, reviewable and even user-patchable. Cheap — do it in
   M1.
2. **Ship Sparkle** with an EdDSA-signed appcast from the start (M1.5). Without it, A2 is
   effectively unfixable in the field.
3. Optionally, later: a remote marker manifest so fixes need no app update at all. Adds a network
   dependency and a trust boundary — not now, but the externalised config in (1) is the seam that
   makes it possible without redesign.

### C3. Selling outside the App Store needs licensing and payments
License keys plus a payment provider, and a trial mechanism.

**Corners us?** No — purely additive, and revenue is explicitly a side-benefit. Do not build
license infrastructure in M1. Do not add feature gates speculatively either.

### C4. The bundled `.shortcut` may not be trusted
macOS Shortcuts can refuse or warn on unsigned shortcut files. The "one-click Focus setup" promise
depends on this working smoothly.

**Corners us?** Only the onboarding story, not the architecture. **Unverified — must test before
promising it.** Fallback is an iCloud shortcut share link, which is trusted by construction.

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
| App Store / sandboxed SKU | audio tier measured working under sandbox; evidence model supports detector subsets |
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
2. **Is the bundled `.shortcut` trusted?** (C4) Gates the onboarding promise.
3. **Does `joining` count as in-meeting for automation?** Product decision. Recommendation: no —
   keep the lobby state for the UI only. A 26-second lobby was measured, so firing automation there
   would enable Focus before the user has actually joined.
4. **Is Graph's `InAMeeting` calendar-derived?** Gates the provider tier (M2), not M1.
