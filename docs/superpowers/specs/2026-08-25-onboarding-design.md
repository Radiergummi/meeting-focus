# Onboarding flow with one-click Focus setup — design

Backlog item 9, plus the prerequisite that blocks backlog item 4. Supersedes the reasoning recorded
in `constraints.md` C4 and open question F2.

## The problem this is really solving

Backlog item 4 says the in-meeting path has never been observed firing, and names the reason:

> **Prerequisite, or the shortcut half cannot fire:** `startShortcutName` and `endShortcutName` are
> both empty in `UserDefaults`, so `ShortcutsAutomationHandler` logs "no shortcut configured,
> skipping" and returns.

That is not a bug. It is the default state of every installation. A user who downloads the app today
gets working detection wired to nothing, and the only route to a working automation is: read the
README, open Shortcuts, learn what the Set Focus action is, author a shortcut, name it, come back,
and pick it in Settings. Every one of those steps is a place to stop.

So the deliverable is not "a welcome window". It is **the app configuring its own automation**, with
the window as the surface that asks permission to do so. The measure of success is that a new
installation reaches a state where a real meeting changes the user's Focus, without the user ever
authoring a shortcut or typing a name.

## What the spike established

Investigated 2026-08-25. The action is legacy and stable, read out of a real shortcut in the
maintainer's own library (`~/Library/Shortcuts/Shortcuts.sqlite`, `ZSHORTCUTACTIONS.ZDATA`, a binary
plist):

```
WFWorkflowActionIdentifier: is.workflow.actions.dnd.set
  Enabled:       1 | 0
  FocusModes:    { Identifier: com.apple.focus.work, DisplayString: "Arbeiten" }
  AssertionType: Turned Off | Time | Event Ends | I Leave | Until
  Operation:     Turn | Toggle          (defaults to Turn)
```

The `AssertionType` and `Operation` vocabularies are not guesses — they come from WorkflowKit's own
`Localizable.loctable`, which enumerates them as parameter values.

Three findings that the implementation depends on, each found by hitting it:

1. **`shortcuts sign` rejects XML plists.** The input must be a binary plist, or it fails with "the
   file couldn't be opened because it isn't in the correct format".
2. **The input filename must end in `.shortcut`.** Same error otherwise, which is what makes this
   costly to diagnose — one error message for two unrelated causes.
3. **`--mode anyone` produces a signed AEA1 container** (`shortcuts sign --mode anyone -i in -o out`,
   ~21 KB). Signing happens on the user's own machine with Apple's own tool, so the resulting file is
   trusted by construction and no bundled-file trust question arises.

The Focus list is readable from `~/Library/DoNotDisturb/DB/ModeConfigurations.json` — identifier plus
localized display name, including user-created Focus modes, which no bundled or hosted artifact could
know about.

**Not verified:** the Add-Shortcut confirmation sheet itself. Signing, format and parameter shape are
all confirmed; that the sheet renders the action cleanly rather than as an unknown-action placeholder
is confirmed only by the parameters having been copied from a working shortcut. First implementation
step is to look at it.

## Why not the obvious alternatives

**Why not install silently?** There is no API to write to the Shortcuts library. One confirmation is
the floor, so the UI must promise "install" and not "done".

**Why not host pre-built shortcuts, one per macOS release?** Considered and rejected. It cannot
personalise — the entire value is baking in *the user's chosen Focus*, and custom Focus modes have
arbitrary identifiers no hosted file can enumerate, so the hosted route degrades to a generic
shortcut the user then edits in Shortcuts, which is most of the friction being removed. It also puts
the network into first-run, makes the maintainer's signing identity a second Sparkle-key-shaped
operational secret, and adds a per-release file matrix to maintain forever. The premise is weak too:
`is.workflow.actions.dnd.set` is the *legacy* identifier and has survived from iOS 12 through
macOS 26, including the entire Focus rework.

**What that idea was right about** is fixability without an app release, which is C2's argument for
externalising the Teams markers. That is kept: the recipe is bundled *data*, so a remote recipe
manifest later needs no redesign — C2 item 3's seam, applied to a second file.

**Why not a bundled unsigned `.shortcut`?** This is what C4 and F2 assume, and why they concluded a
one-click path was not reliably available. Local signing removes the assumption: nothing unsigned is
ever shipped, so nothing needs to be trusted.

**Why not a Setup tab in Settings instead of a window?** Cheaper, and it stays useful as a health
check, but first launch then means opening Settings, which reads as homework rather than a welcome.
Rejected for the first-run case; a health-check view remains available later and is out of scope
here.

## The flow

A `Window` scene, id `"onboarding"`, `.windowResizability(.contentSize)`, single instance, opened
with `openWindow(id:)`. `AppDelegate.applicationDidFinishLaunching` opens it when
`!settings.onboardingCompleted`. It needs `NSApp.activate(ignoringOtherApps:)` on the run-loop pass
after opening, for the same reason `MenuBarView.showSettings()` does: `LSUIElement` puts the app
under the accessory activation policy, where opening a window never activates the app.

The window never blocks monitoring. The monitor starts exactly as it does today.

`enum Step: Int, CaseIterable` with the view switching on it and a four-dot indicator, matching the
computed-property style now used in `MenuBarView` and `SettingsView`. Four steps does not justify
step objects.

| Step | Does | Skippable |
|---|---|---|
| `welcome` | One paragraph on what the app does. `[Get Started]` | — |
| `permission` | Why Accessibility is needed, then `[Grant Accessibility…]` raises the system prompt. Turns into a live ✓ when `monitor.accessibilityTrusted` flips. | `[Later]` |
| `focus` | "Which Focus should meetings turn on?" over the user's real Focus modes, then `[Install Shortcuts]`. ✓ when both names appear in the library. | `[Later]` |
| `finish` | Launch at login toggle, and what the three menu bar icon states mean. `[Done]` | — |

The picker defaults to the Focus whose identifier is `com.apple.focus.work` when present, else the
first entry. **Two shortcuts are installed, not one** — one turning the Focus on, one turning it off,
because `AutomationCoordinator` emits a start and an end command and each maps to a named shortcut.
That means two Add confirmations, which the step's copy must say plainly before the first one
appears.

**The permission step's copy must not name Teams.** Per-app detectors are the next piece of work,
after which Teams is one adapter among several and Accessibility is what every AX detector needs.
Copy that says "reads the windows of your meeting apps" ages; copy that says "reads Teams' own window
contents" — as the menu bar popover used to — needs rewriting the moment the second detector lands.

**There is no detector step.** An earlier draft had one, offering the Teams and microphone toggles.
It was cut: the app detects meetings out of the box given the permission, the toggles are an escape
hatch for someone who does not want microphone-activity monitoring, and putting them in onboarding
implies the app needs configuring to work. This also keeps the un-wired `MeetingMonitor.restart()`
out of scope.

**State** is two new `AppSettings` keys beside the existing ones: `onboardingCompleted: Bool` and
`onboardingStep: Int`. The window opens at the saved step, so quitting halfway resumes there;
`[Later]` advances the index without acting; `[Done]` sets `onboardingCompleted`. No new store.

A new menu item, `Set Up MeetingFocus…`, opens the window at any time.

## Components

### 1. `Resources/focus-shortcut.json` — the recipe

Action identifier, parameter key names and client-version values as data, so a format change is a
data fix rather than a code change, and so a remote manifest later replaces one file. Same role
`teams-markers.json` plays for detection.

### 2. `Sources/MeetingFocusCore/FocusShortcut.swift`

`FocusShortcutRecipe: Decodable`, `enum Direction { case on, off }`, and a pure
`plist(recipe:focus:direction:) throws -> Data` serialising via `PropertyListSerialization` in
**binary** format.

`FocusShortcutRecipe` gets an **explicit initializer**. Swift's synthesized `Decodable` does not
apply property default values, which is exactly how `teams-markers.json` silently failed to decode on
first run and fell back to hardcoded markers — the failure C2's externalisation existed to prevent.
Not paying for that lesson twice.

This belongs in the core because the core is where everything that decides lives, with no AppKit,
Accessibility or network dependency. `PropertyListSerialization` is Foundation, which the core
already uses.

### 3. `Tests/MeetingFocusCoreTests/FocusShortcutTests.swift`

- The shipped `focus-shortcut.json` decodes.
- The built dictionary matches expected exactly, both directions — `AssertionType: "Turned Off"`
  present for `on`, absent for `off`.
- The output begins `bplist00`, since XML is silently useless here: it lints clean and fails only at
  the signing step.

No Mac state, no Shortcuts app, no live application. The fragile knowledge is the plist shape, and
this is what puts it under `swift test`.

### 4. `Sources/MeetingFocusApp/Automation/FocusModeCatalog.swift`

Reads `~/Library/DoNotDisturb/DB/ModeConfigurations.json` into `[(identifier, name)]`. A private
file, so failure is expected rather than exceptional: on empty, the `focus` step degrades to the
existing manual route instead of showing an empty picker.

### 5. `Sources/MeetingFocusApp/Automation/FocusShortcutInstaller.swift`

1. Writes the plist to a temp file **named as the shortcut should be named** — the import takes the
   shortcut's name from the filename — with a `.shortcut` extension, which the signer requires.
2. Spawns `/usr/bin/shortcuts sign --mode anyone`.
3. Opens the signed file, which raises the Add-Shortcut confirmation. Steps 1–3 run twice, once per
   direction, so the user sees two confirmations.
4. Polls `ShortcutsAutomationHandler.availableShortcutNames()` on a bounded timeout while the step is
   visible; when both names appear, writes `startShortcutName` and `endShortcutName`.

No new permission surface: the app already spawns `/usr/bin/shortcuts run` and `list` through
`Process` (`ShortcutsAutomationHandler.toolURL`), so `sign` is the same binary by the same mechanism.
C5's Automation-prompt concern is already handled — `NSAppleEventsUsageDescription` is present.

Every failure — missing recipe, signing failure, file will not open, names never appear — shows a
short message and falls back to the existing "Open Shortcuts" route, logged to `Log.automation`. The
step is never a dead end.

### 6. Strings

The two shortcut names are localized catalogue keys, because they live in the user's library
permanently and reading English names in a German Shortcuts library is worse than a translated
Settings label. Every new literal goes through `Tools/xcstrings`; `make test` enforces both
directions.

## Verification

- `make lint test build smoke` green, including the localization coverage tests over the new keys.
- `FocusShortcutTests` cover the plist shape without a Mac.
- Manual, and the first thing to do: run the flow, install, and confirm the Add sheet renders "Turn
  Arbeiten Focus on" rather than an unknown-action placeholder. This is the one thing the spike could
  not verify.
- Manual: complete the flow, then hold a real meeting and confirm the Focus changes — which is
  backlog item 4, finally unblocked, since the prerequisite it names is what this builds.
- Manual: quit at the `permission` step, relaunch, confirm the window resumes there.

## Out of scope

- Per-app detectors and retiring Teams' special position. Next piece of work; this design only avoids
  copy that would need rewriting when it lands.
- `MeetingMonitor.restart()` is never called, so the Settings detector toggles do not take effect
  until relaunch. Pre-existing; a backlog item, not this task.
- `defaultAudioAllowlist` is a hardcoded Swift constant, so covering a new meeting app needs an app
  release. Given C2 externalised the Teams markers for exactly this reason, it likely belongs in the
  same patchable data seam. A backlog item.
- The two pre-existing `Text(String)` localization holes in `SettingsView`
  (`shortcutPicker(_ title: String)` and the Accessibility-status ternary), and the
  `isLocalizingSite` suffix match that hides the first.
- A Setup/health-check tab in Settings.
- First-meeting verification. Considered as a closing step and cut as speculative.

## Documentation to update on landing

- `constraints.md` C4: the conclusion "resolved by not relying on it" is superseded. Local signing
  makes one-click install available without shipping anything unsigned.
- `constraints.md` F2 ("Is the bundled `.shortcut` trusted?"): answered, and the question dissolves —
  nothing bundled needs to be trusted.
- `BACKLOG.md` item 9: rewrite from "if a one-click path is wanted" to what was built. Its stated
  reason for deferring — untrusted imports — no longer holds.
- `BACKLOG.md` item 4: note that the prerequisite it names is now handled by onboarding.
- `architecture.md`: the automation section gains the recipe file and the installer.
