# Localization (en + de) — design

Backlog item 9. Adapts the design already running in `pensieve`, whose comments record failures
this project has not had to pay for yet.

## The problem this is really solving

`project.yml` already states it, beside the settings that make it true:

> a key must match its Swift literal character-for-character or the translation silently falls back
> to the development language

Nothing warns. Not the compiler, not `xcodebuild` — with `SWIFT_EMIT_LOC_STRINGS: NO` there is no
extraction step at all. A German user gets English and nobody testing in English ever sees it. In
pensieve this shipped: the widget's gallery description went out English-only.

So the deliverable is not "a catalogue". It is a catalogue **plus the two mechanisms that make a
mismatch impossible to ship**: a tool that is the only writer, and tests that compare the catalogue
against the source in both directions.

## Why not the obvious alternatives

**Hand-edit the JSON.** Rejected. `JSONSerialization` keeps the last of a duplicate key pair, so a
duplicate can sit in the file indefinitely with the losing copy edited forever after and never
rendered. Only a scan of the file *text* can see it — which is why the tool refuses to write a file
that has one, rather than parsing and re-emitting it.

**Turn `SWIFT_EMIT_LOC_STRINGS` back on.** Rejected, and `project.yml` says why: compiler extraction
rewrites the *source* catalogue on every build, reordering keys and resetting states.

## Components

### 1. `Sources/MeetingFocusApp/Localizable.xcstrings`

Hand-authored, `en` source plus `de`. Roughly 45 keys, drawn from 42 call sites in `SettingsView`
and `MenuBarView`. Placed alongside the sources it serves, matching pensieve; `BUILD_SOURCES`
already globs `Sources/MeetingFocusApp`, so build invalidation works unchanged.

German is authored by this work as `state: "needs_review"`, not `"translated"` — the honest state
for text a German speaker has not yet read. The integrity test accepts `needs_review`, so the suite
goes green while the catalogue still says plainly which strings are unreviewed.

### 2. `Tools/xcstrings/`

Swift, no dependencies, compiled by the Makefile exactly as `axprobe` is. Verbs:

| Verb | Purpose |
|---|---|
| `add` | new key; requires a translation for every declared language |
| `set` | change translations on an existing key |
| `remove` | delete a key |
| `rename` | move a key, carrying translations, following the source value only when it *was* the key |
| `add-language` | declare a language in `project.yml` and seed every catalogue with it |
| `audit` | per-language counts, duplicates, canonical-form check; exit status is the answer |
| `fmt [--check]` | rewrite to canonical form, or report that it is not |

Files: `main.swift` (argument parsing, dispatch), `Commands.swift` (verbs), `StringCatalog.swift`
(load, mutate, canonicalise), `ProjectConfiguration.swift` (read and edit `project.yml`),
`JSONValue.swift` (order-preserving JSON so diffs stay readable).

Two non-obvious requirements carried over:

- **`JSONValue` models JSON explicitly** rather than round-tripping through `Any`. The bridge makes
  `false` and `0` the same `NSNumber`, so naive re-encoding rewrites `"shouldTranslate" : false` as
  `0`; and `JSONEncoder` cannot produce Xcode's layout at all.
- **No language is named anywhere in the tool.** `project.yml`'s `knownRegions` is the authority,
  because a language nobody has translated a single string into yet exists in exactly one place.

### 3. `Tests/LocalizationTests/` — a new SwiftPM test target

Pure file I/O: it reads the Swift sources and the catalogue from disk via `#filePath`, and imports
neither the app nor the core. So it needs no test host and no UI test target, and `swift test` runs
it in milliseconds.

A separate target rather than folding into `MeetingFocusCoreTests`, because these tests are about
the *app*, and `MeetingFocusCoreTests` exists to prove the dependency-free core.

**Coverage — both directions, because they fail differently.** A literal with no key renders English
under German; a key with no literal is dead weight that makes the catalogue look like it covers more
than it does.

Comparison is by **shape**, not text: every interpolation on the Swift side and every format
specifier on the catalogue side collapses to one sentinel. `\(count)` becomes `%lld` and
`\(name)` becomes `%@`, and which one depends on the interpolated *type* — knowable to the compiler,
not to a source scan. Collapsing sidesteps that while the surrounding characters still must agree
exactly.

The "missing key" direction filters to known localizing call sites (`Text(`, `Toggle(`, `.help(`,
`titleKey:`, …). The "dead key" direction deliberately does *not* filter: a key built by a runtime
lookup is alive but not attributable to a call site, and in pensieve judging those by call site
produced 37 false positives.

**Integrity** — the three things invisible to coverage and to every tool in the build:

1. duplicate keys, by scanning the file text;
2. every declared language translates every translatable key;
3. `project.yml`'s language declarations agree with each other.

**Every check asserts its own inputs are non-empty.** A set subtraction is empty both when
everything agrees and when the scan found nothing, so a renamed directory or a broken scanner would
otherwise turn these into permanently green no-ops.

### 4. `LocalizationRules.swift` — shared source

Compiled into **both** the test target and the tool, by naming it on the tool's `swiftc` line. Both
need to answer "what are the declared languages?" and "which keys appear twice?", and two
implementations of one rule is the drift this file exists to prevent. It may therefore import
nothing the tool cannot link — no `Testing`, no `XCTest`.

### 5. Source changes

*This section was wrong when first written — it claimed "almost none". Building the coverage scanner
found three real bugs, which is the most useful thing this work did.*

`Text("Monitoring")` and `Toggle("…", isOn:)` do take `LocalizedStringKey`, so those literals
localize themselves once the catalogue exists. But **`Text(String)` renders verbatim**, and three
places were typed `String`:

| Site | Consequence before the fix |
|---|---|
| `MenuBarView.statusText` | The most prominent string in the menu — "In a meeting" — never translated |
| `MenuBarLabel.label` | The menu bar icon's VoiceOver label stayed English for every German user |
| `MenuBarView.row(_ title:)` | "Monitoring" and "Automation" rows never translated |

All three are now `LocalizedStringKey`. This is exactly the failure mode `project.yml` warns about,
and no test, compiler warning or build step would have reported it — the strings were *present*, in
a catalogue, spelled correctly, and simply never looked up.

`row(_:_:)` is added to the scanner's localizing-site list, so its callers' literals are enforced
like any other. The two `switch`-returning properties cannot be attributed to a call site, so their
keys are covered by the dead-key direction rather than the missing-key one — a residual gap, and the
same one pensieve accepts for runtime-built keys.

The three `ShortcutsAutomationHandler.Failure.errorDescription` messages also needed
`String(localized:)`, as expected. The exit code is widened to `Int` so the key carries `%lld`;
`Int32` would require a key spelled `%d`.

### 6. Makefile

- `XCSTRINGS = ./.build/xcstrings`, built like `AXPROBE`, with `LOCALIZATION_RULES` on its source
  line.
- **`TEST_INPUTS` must gain `Sources/MeetingFocusApp`.** The coverage test reads that tree even
  though `swift test` never compiles it. Without it, adding a literal to a view leaves the step
  record valid and `make test` reports cached-green over a real failure. Pensieve's Makefile
  documents this trap; the cost is small for the same reason it is subtle — app sources are not
  compiled by the suite, so an app-only edit re-runs the tests without rebuilding anything.
- `.make/smoke` gains a check that the compiled catalogue reached the bundle, mirroring the existing
  `teams-markers.json` assertion.

`audit` and `fmt --check` are **not** wired into `make lint` or CI, matching pensieve. The tests are
the gate; the tool is the editor. Duplicate keys and untranslated strings — the failures that matter
— are already caught by the suite, and canonical form cannot drift while the tool is the only
writer.

## Adaptations from pensieve

| Pensieve | Here | Why |
|---|---|---|
| ≥3 language declarations expected | **≥2** | One bundled target, so `knownRegions` + one `CFBundleLocalizations` |
| Two catalogues (app, widget) | One | `--catalog` substring matching still earns its place for `fmt`/`audit` over a discovered set |
| Coverage tests in `PensieveKitTests` | Own target | `MeetingFocusCoreTests` exists to prove the dependency-free core |
| Extra sources folded in (`PensieveKit`) | Not needed | Nothing here supplies keys through a runtime lookup |

## Verification

1. `swift test` — coverage and integrity green, and each check proves its inputs were non-empty.
2. `xcstrings audit` — reports `de` as fully `needs_review`, no duplicates, canonical.
3. `xcstrings fmt --check` — clean.
4. `make all` — lint, test, build, smoke, with smoke confirming the catalogue reached the bundle.
5. **A render proof, without a UI test target.** Launch the built app under
   `-AppleLanguages (de)` and read its menu through the Accessibility API — the technique that
   settled the menu bar icon question. This closes the gap the key/literal tests cannot: a catalogue
   that is perfect but fails to compile into the bundle passes every test above.

## Outcome

All five localization tests pass; `make -B all` is green (lint 0 violations, 17 + 5 tests, build,
smoke). 49 keys, English `translated` and German `needs_review`. `fmt --check` clean.

The render proof:

```
-AppleLanguages (en)  ->  AXTitle: Not in a meeting
-AppleLanguages (de)  ->  AXTitle: Nicht in einer Besprechung
```

That reads `MenuBarLabel.label` specifically — one of the three sites fixed above — so it confirms
both that the catalogue is selected at runtime and that the `String` → `LocalizedStringKey` change
took effect. Before the fix, both lines would have said "Not in a meeting".

The smoke check was negative-tested by removing `de.lproj` and confirming `make smoke` fails on it,
because a bundle check that cannot fail is worse than none.

## Out of scope

- A UI test target (backlog item 15). Step 5 above gets the render proof without one.
- Localizing the README, release notes or `docs/`.
- Any third language. `add-language` exists for that day; nothing here anticipates it.
- Localizing detection. Detection must **never** match localized strings — the opposite rule to the
  app's own UI, in the same codebase.
