# MeetingFocus

A small macOS menu bar utility that detects when you are actually *in* a meeting — not merely
that a meeting app is open — and runs the Shortcuts you configure when a meeting starts and ends.

The typical use is toggling a Focus mode so notifications stay quiet for the duration of a call,
across your Mac and (because Focus syncs between Apple devices) your iPhone too.

## Requirements

- macOS 26 or later
- Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Accessibility permission, for the Teams detector

## Build and run

```sh
xcodegen generate
open MeetingFocus.xcodeproj
```

Or from the command line:

```sh
xcodegen generate
xcodebuild -project MeetingFocus.xcodeproj -scheme MeetingFocus -configuration Debug build
xcodebuild -project MeetingFocus.xcodeproj -scheme MeetingFocusCoreTests -destination 'platform=macOS' test
```

`project.yml` is the source of truth for the project; `MeetingFocus.xcodeproj` is generated from
it and committed so the project opens without XcodeGen installed. Edit the YAML, not the
`.xcodeproj`.

## How detection works

Two independent signals, combined rather than chosen between, because they fail in opposite
directions.

| Detector | Signal | Confidence | Covers |
|---|---|---|---|
| `TeamsAccessibilityDetector` | Teams' own meeting UI, matched on `AXDOMIdentifier` | definitive | Microsoft Teams |
| `AudioProcessDetector` | per-process microphone capture (CoreAudio) | corroborating | Zoom, Slack, Webex, Discord, browser meetings |

The Accessibility detector is precise: it reads the meeting title, distinguishes the lobby from an
active call, and is unaffected by muting. The audio detector is coarse but needs no per-app work
and reaches browser-based meetings such as Google Meet, where there is no app UI to inspect.

Where both describe the same application, the definitive verdict wins. That is what stops a mute
from ending a Teams meeting.

Detection never matches on user-visible text. The development machine ran a German UI, where the
meeting controls read "Besprechungssteuerung"; a string-based detector would work only in English.

## Permissions

Only **Accessibility** is required, and only for the Teams detector. Without it the app degrades
to microphone-only detection and says so in its menu rather than failing quietly.

No Screen Recording, Microphone or Camera permission is needed. No private APIs, no privileged
helper, no background daemon.

## Configuration

Settings offers per-detector toggles, the shortcut to run on start and on end (picked from your
actual shortcut list), and how long to wait before running the end shortcut.

That wait matters. Back-to-back meetings are normal — a 12-second gap between two real meetings
was measured during development — and without it your Focus mode would switch off and on again in
the gap. If a new meeting begins during the wait, no end or start shortcut runs at all.

## Setting up a Focus automation

MeetingFocus cannot change your Focus mode directly. **No public macOS API exists for that** —
`INFocusStatusCenter` can only *read* whether a Focus is active. Shortcuts is the only supported
route, which is why it is the automation backend rather than a convenience.

One-time setup:

1. Open **Shortcuts** and create a shortcut named e.g. `Meeting Started`.
2. Add the **Set Focus** action and choose the Focus you want (Do Not Disturb, Work, …), set to
   **On**.
3. Create a second shortcut, e.g. `Meeting Ended`, with **Set Focus** set to **Off**.
4. In MeetingFocus → Settings, pick those two shortcuts from the dropdowns.

Because Focus syncs between Apple devices, this also silences your iPhone for the duration of the
call — no iOS app required.

A prepared shortcut is deliberately *not* bundled with the app. macOS treats shortcut files from
unidentified sources as untrusted, so importing one is not reliably a single click, and a setup
step that sometimes silently fails is worse than one that is explicit. If that changes, the
cleanest route would be an iCloud shortcut share link, which is trusted by construction.

## When detection breaks

The Teams detector matches internal HTML element ids that Microsoft can rename in any release.
They live in `Resources/teams-markers.json` rather than in source, so a fix is a data change.

To re-derive them, enable Debug mode in Settings and watch:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "me.mazetti.meetingfocus"'
```

A warning is logged when a window looks like a meeting but no markers match — the signature of a
rename. Meeting titles are redacted from logs by design.

## Releasing

```sh
./Scripts/release.sh                    # signed, notarized, stapled DMG + signed appcast
./Scripts/release.sh --skip-notarize    # local test build only — do not distribute
```

The script runs the tests, archives, exports with Developer ID, verifies hardened runtime /
Developer ID authority / secure timestamp before submitting, notarizes and staples, builds the DMG,
and generates the Sparkle appcast.

Then, **in this order**:

```sh
gh release create v0.1.0 build/MeetingFocus-0.1.0.dmg \
    --repo Radiergummi/meeting-focus --title "MeetingFocus 0.1.0"
./Scripts/publish-feed.sh
```

The order matters. `publish-feed.sh` deploys the appcast to the Cloudflare Worker, and it checks
every enclosure URL in the feed resolves before doing so — publishing a feed whose download 404s
would advertise an update that every client fails to install.

The feed is served by an assets-only Worker in `worker/`, so `appcast.xml` is a static file and
there is no Worker code to maintain per release.

### One-time setup

**Notarization credentials** — from
[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords:

```sh
xcrun notarytool store-credentials MeetingFocus-Notary \
    --apple-id "you@example.com" --team-id TH593VRB6W --password "xxxx-xxxx-xxxx-xxxx"
```

**Sparkle signing key** — already generated; the public half is `SUPublicEDKey` in `project.yml`.

> ⚠️ The private half lives in the login keychain as **"Private key for signing Sparkle updates"**.
> **Back it up somewhere safe.** If it is lost, no existing installation can ever be updated
> again — they would all have to be replaced by hand. Export it with:
>
> ```sh
> "$(find ~/Library/Developer/Xcode/DerivedData/MeetingFocus-*/SourcePackages/artifacts/sparkle \
>     -name generate_keys -type f | head -1)" -x sparkle-private-key.txt
> ```
>
> Store that file in a password manager and delete it from disk.

Note the appcast uses version-pinned download URLs rather than `releases/latest/download`, because
`latest` would make every entry — including older ones — resolve to the newest asset. The script
seeds from the published appcast so earlier versions keep their entries.

## Documentation

- [`docs/teams-accessibility.md`](docs/teams-accessibility.md) — the investigation this is built
  on, including hypotheses that were tested and rejected
- [`docs/architecture.md`](docs/architecture.md) — structure and extension points
- [`docs/constraints.md`](docs/constraints.md) — platform constraints and which of them are
  load-bearing
- [`docs/BACKLOG.md`](docs/BACKLOG.md) — what is outstanding, and why each item matters

## Trust: what this build is, and how to check it

This app reads other applications' window contents and watches which processes use your
microphone. "Is it spying on me?" is a fair question, and the answer should be checkable rather
than merely asserted.

**Releases are built in public.** Every release is produced by a
[GitHub Actions run](.github/workflows/release.yml) from a public commit on a disposable runner —
never on a developer machine — and that run records a signed
[build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations)
over the exact artifact published.

Verify a download before trusting it:

```sh
shasum -a 256 MeetingFocus-0.1.0.dmg          # compare against the release notes
gh attestation verify MeetingFocus-0.1.0.dmg --repo Radiergummi/meeting-focus
```

An already-installed copy can be traced too: **Settings → This build** shows the commit and links
to the build log that produced it.

**This is verifiable provenance, not a reproducible build.** Xcode output is not deterministic —
timestamps, code signing and link order all vary — so rebuilding will not produce a byte-identical
file, and any project claiming otherwise for a Swift app deserves a second look. What is proven is
*which source and which public build* produced the artifact you hold.

**Two independent keys, on purpose.** GitHub attests the build; the maintainer signs the Sparkle
update feed with a key that never leaves their machine. Neither a compromised CI nor a stolen
laptop is on its own sufficient to ship you code.

### What it reads, and what it sends

- **Reads:** window titles and accessibility element ids of Microsoft Teams, and which processes
  are currently capturing the microphone. Nothing else, and no window contents beyond those.
- **Sends:** nothing, with one exception — the update check fetches
  `https://meetingfocus.mazetti.me/appcast.xml`. No telemetry, no analytics, no account, no crash
  reporting.
- **Stores:** settings in `UserDefaults`. No database, no meeting history.
- **Logs:** meeting titles are marked private in the unified log, so they do not reach a
  sysdiagnose. Element ids and counts are logged publicly.

Accessibility is the only permission requested. No Screen Recording, Microphone or Camera
permission — the microphone check asks CoreAudio *which processes* are capturing, and never opens
an input stream.

## Licence

Copyright © 2026 Moritz Friedrich. Licensed under the
[GNU Affero General Public License v3.0](LICENSE).

Chosen as a deliberately restrictive copyleft licence: derivative works must stay under the same
terms. Note two consequences worth being aware of:

- **AGPL is incompatible with Mac App Store distribution.** Its terms conflict with the App Store's,
  so this licence closes that door for as long as it applies. That option was already deferred
  indefinitely (see [`docs/constraints.md`](docs/constraints.md)), and the copyright holder can
  relicense at any time — but only while they hold copyright to all of the code.
- **Outside contributions would complicate relicensing.** Accepting patches without a contributor
  licence agreement means no single party can relicense afterwards. Worth deciding before the first
  external pull request, not after.
