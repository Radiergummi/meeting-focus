## Install

Download `MeetingFocus-VERSION_PLACEHOLDER.dmg`, drag the app to Applications, and launch it.
It lives in the menu bar — there is no dock icon.

On first launch it asks for **Accessibility** permission. That is what lets it read Microsoft
Teams' own window contents to tell whether you are actually in a meeting. Decline it and the app
still works, using microphone activity alone, and says so in its menu.

## What this build is, and how to check

This release was built by a public GitHub Actions run from a public commit — not on anybody's
laptop — and that run recorded a signed provenance attestation over the exact file below.

- **Commit:** `COMMIT_PLACEHOLDER`
- **Build log:** RUN_URL_PLACEHOLDER
- **Attestation:** ATTESTATION_URL_PLACEHOLDER
- **SHA-256:** `SHA256_PLACEHOLDER`

Verify the download really came from that source before trusting it:

```sh
shasum -a 256 MeetingFocus-VERSION_PLACEHOLDER.dmg
gh attestation verify MeetingFocus-VERSION_PLACEHOLDER.dmg --repo Radiergummi/meeting-focus
```

The app shows the same commit and build URL under Settings → This build, so a copy already
installed can be traced back too.

Note this is verifiable *provenance*, not a bit-for-bit reproducible build: Xcode output is not
deterministic, so rebuilding will not produce an identical file. What is proven is which source
and which public build produced this artifact.

## What it reads, and what it sends

It reads a lot and sends almost nothing, which is worth stating precisely:

- **Reads:** window titles and accessibility element ids of Microsoft Teams, and which processes
  are currently using the microphone. Meeting titles are shown in the menu and are redacted from
  the system log.
- **Sends:** nothing, with one exception — the update check fetches
  `https://meetingfocus.mazetti.me/appcast.xml`. No telemetry, no analytics, no account.
- **Stores:** your settings in `UserDefaults`. No database, no meeting history.

Updates are signed with an EdDSA key held by the maintainer, separately from the CI signing key,
so neither a compromised build system nor a stolen laptop is on its own enough to ship you code.
