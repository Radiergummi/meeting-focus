# Onboarding Flow With One-Click Focus Setup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A four-step welcome window that leaves a new installation with detection running and two Focus shortcuts installed and selected, so a real meeting changes the user's Focus without the user ever authoring a shortcut or typing a name.

**Architecture:** The plist format — the fragile part — is a pure builder in `MeetingFocusCore`, driven by a bundled `focus-shortcut.json` recipe and covered by `swift test` with no Mac state. Two thin platform types in `MeetingFocusApp/Automation` read the user's Focus list and do sign-then-open-then-confirm by spawning `/usr/bin/shortcuts`, the same binary the app already uses for `run` and `list`. The flow itself is a `Window` scene with an `enum Step` and the view switching on it.

**Tech Stack:** Swift 6, SwiftUI, XCTest (core), `PropertyListSerialization`, `Process`, `/usr/bin/shortcuts`, String Catalogue via `Tools/xcstrings`.

**Spec:** `docs/superpowers/specs/2026-08-25-onboarding-design.md`

**Before you start:** the repository is on `main` with a dirty working tree from unrelated work. Create a branch first (`git switch -c onboarding`) and, when staging, add only the files each task's commit step names — never `git add -A`.

## Global Constraints

- Deployment target macOS 26, Swift 6. Both are already set in `project.yml` and `Package.swift`; do not change them.
- **`MeetingFocusCore` has no AppKit, Accessibility, network or `Log` dependency.** Anything needing a bundle, a file path in the user's home, a subprocess or a logger belongs in `MeetingFocusApp`.
- **Every new user-visible literal needs a String Catalogue key in the same commit as the literal.** `Tests/LocalizationTests` fails both directions — a literal with no key, and a key with no literal — so a commit that adds one without the other breaks `make test`. Add keys with `./.build/xcstrings add --catalog Localizable --key "…" --translation "de=…"` (build the tool once with `make xcstrings`), then `./.build/xcstrings fmt --catalog Localizable`.
- **`Text(String)` renders verbatim.** Literals must reach `Text`, `Label`, `Button`, `Toggle`, `Picker` or `Tab` directly, or travel as `LocalizedStringKey`. A `String` parameter or a ternary inside `Text(...)` silently ships English.
- SwiftLint runs as CI runs it and rejects identifiers shorter than 3 characters. Avoid `on`, `id`, `to` as parameter or variable names.
  This bit Task 1: the enum cases were originally `on`/`off` in this plan and failed `swiftlint
  lint --strict` (`Makefile:123`). They are `turnOn`/`turnOff` throughout, and `.swiftlint.yml` was
  deliberately not relaxed. `String(decoding:as:)` fails `optional_data_string_conversion` for the
  same reason — use `String(bytes:encoding:)`.
- `shortcuts sign` has two undocumented requirements, each producing the same "isn't in the correct format" error: the input must be a **binary** plist, and the input path must end in **`.shortcut`**.
- The imported shortcut takes its name from the **filename** of the file that is opened.
- Copy must not name Teams. Per-app detectors are the next piece of work, after which Teams is one adapter among several. Say "your meeting apps".
- `Resources/` is a folder entry in `project.yml:44`, but xcodegen emits **explicit** file references, so a new file there is NOT bundled until `MeetingFocus.xcodeproj/project.pbxproj` is regenerated. `make build` does that automatically (the `$(PBXPROJ)` target depends on the source directory list), and the regenerated file is tracked and must be committed. Task 1 shipped `focus-shortcut.json` without it, so the resource sat outside the bundle until Task 3's build picked it up.
- End every commit message with the two trailer lines this repository uses:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01A7ZFCQch8EWhhCHQjiDGxN
  ```

**One refinement on the spec:** the spec puts the whole Focus-list reader in `MeetingFocusApp`. This plan splits it — parsing in Core (Task 2, tested against a fixture), file reading in the app (Task 5). Same reason the plist builder is in Core: the parsing is the part that breaks silently when Apple changes a private file's shape, and it is testable without a Mac.

---

### Task 1: The recipe and the plist builder

**Files:**
- Create: `Sources/MeetingFocusCore/FocusShortcut.swift`
- Create: `Resources/focus-shortcut.json`
- Test: `Tests/MeetingFocusCoreTests/FocusShortcutTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `FocusMode(identifier: String, name: String)`; `enum FocusShortcutDirection { case turnOn, turnOff }`; `FocusShortcutRecipe` with `static let fallback` and `init(from:)`; `FocusShortcut.plistData(recipe: FocusShortcutRecipe, focus: FocusMode, direction: FocusShortcutDirection) throws -> Data`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingFocusCoreTests/FocusShortcutTests.swift`:

```swift
import XCTest
@testable import MeetingFocusCore

/// The shape of a Shortcuts workflow plist is private, undocumented, and only reported wrong by the
/// signer refusing the file — so it is pinned here rather than discovered by running the app.
final class FocusShortcutTests: XCTestCase {
    private let recipe = FocusShortcutRecipe.fallback
    private let work = FocusMode(identifier: "com.apple.focus.work", name: "Arbeiten")

    private func parameters(_ data: Data) throws -> [String: Any] {
        let root = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        let actions = try XCTUnwrap(root?["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.dnd.set")
        return try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
    }

    func testOnCarriesTheFocusAndHoldsUntilTurnedOff() throws {
        let params = try parameters(
            FocusShortcut.plistData(recipe: recipe, focus: work, direction: .turnOn)
        )
        XCTAssertEqual(params["Enabled"] as? Int, 1)
        XCTAssertEqual(params["AssertionType"] as? String, "Turned Off")
        let modes = try XCTUnwrap(params["FocusModes"] as? [String: String])
        XCTAssertEqual(modes["Identifier"], "com.apple.focus.work")
        XCTAssertEqual(modes["DisplayString"], "Arbeiten")
    }

    /// An `AssertionType` on the off action would mean "turn it off until turned off", which
    /// Shortcuts shows as a nonsense summary.
    func testOffOmitsTheAssertion() throws {
        let params = try parameters(
            FocusShortcut.plistData(recipe: recipe, focus: work, direction: .turnOff)
        )
        XCTAssertEqual(params["Enabled"] as? Int, 0)
        XCTAssertNil(params["AssertionType"])
    }

    /// `shortcuts sign` rejects an XML plist with the same error it gives for a wrong file
    /// extension, so a format regression here is expensive to diagnose from the outside.
    func testOutputIsABinaryPlist() throws {
        let data = try FocusShortcut.plistData(recipe: recipe, focus: work, direction: .turnOn)
        XCTAssertEqual(try XCTUnwrap(String(bytes: data.prefix(6), encoding: .utf8)), "bplist")
    }

    func testShippedRecipeDecodesAndMatchesTheFallback() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Resources/focus-shortcut.json")
        let decoded = try JSONDecoder().decode(FocusShortcutRecipe.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.actionIdentifier, FocusShortcutRecipe.fallback.actionIdentifier)
        XCTAssertEqual(decoded.assertionTypeWhenOn, FocusShortcutRecipe.fallback.assertionTypeWhenOn)
        XCTAssertEqual(decoded.parameterKeys.enabled, FocusShortcutRecipe.fallback.parameterKeys.enabled)
    }

    /// Swift's synthesized `Decodable` ignores property defaults, which is how `teams-markers.json`
    /// silently failed to decode on first run. A recipe naming only the action must still decode.
    func testRecipeDecodesFromAMinimalObject() throws {
        let json = Data(#"{"actionIdentifier": "is.workflow.actions.dnd.other"}"#.utf8)
        let decoded = try JSONDecoder().decode(FocusShortcutRecipe.self, from: json)
        XCTAssertEqual(decoded.actionIdentifier, "is.workflow.actions.dnd.other")
        XCTAssertEqual(decoded.assertionTypeWhenOn, FocusShortcutRecipe.fallback.assertionTypeWhenOn)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter FocusShortcutTests`
Expected: FAIL — `cannot find 'FocusShortcutRecipe' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/MeetingFocusCore/FocusShortcut.swift`:

```swift
import Foundation

/// A Focus mode as the system names it: `ModeConfigurations.json`'s key, and the display name the
/// user sees. Both go into the shortcut — the identifier is what Shortcuts acts on, the display
/// string is what its summary reads.
public struct FocusMode: Equatable, Sendable, Identifiable {
    public let identifier: String
    public let name: String

    public var id: String { identifier }

    public init(identifier: String, name: String) {
        self.identifier = identifier
        self.name = name
    }
}

public enum FocusShortcutDirection: Sendable {
    case turnOn, turnOff
}

private enum RecipeCodingKeys: String, CodingKey {
    case actionIdentifier, clientVersion, minimumClientVersion
    case iconGlyph, iconColor, parameterKeys, assertionTypeWhenOn
}

private enum ParameterKeyCodingKeys: String, CodingKey {
    case enabled, focusModes, assertionType, modeIdentifier, modeDisplayName
}

/// The Set Focus action as data rather than source, for the same reason `teams-markers.json` is
/// data: the identifiers are Apple's private vocabulary and can be renamed by any macOS release, so
/// a fix should be a data change. It is also the seam a remotely refreshed manifest would use.
public struct FocusShortcutRecipe: Decodable, Sendable {
    public struct ParameterKeys: Decodable, Sendable {
        public var enabled: String = "Enabled"
        public var focusModes: String = "FocusModes"
        public var assertionType: String = "AssertionType"
        public var modeIdentifier: String = "Identifier"
        public var modeDisplayName: String = "DisplayString"

        public init(
            enabled: String = "Enabled",
            focusModes: String = "FocusModes",
            assertionType: String = "AssertionType",
            modeIdentifier: String = "Identifier",
            modeDisplayName: String = "DisplayString"
        ) {
            self.enabled = enabled
            self.focusModes = focusModes
            self.assertionType = assertionType
            self.modeIdentifier = modeIdentifier
            self.modeDisplayName = modeDisplayName
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: ParameterKeyCodingKeys.self)
            let defaults = ParameterKeys()
            enabled = try container.decodeIfPresent(String.self, forKey: .enabled) ?? defaults.enabled
            focusModes = try container.decodeIfPresent(String.self, forKey: .focusModes) ?? defaults.focusModes
            assertionType = try container.decodeIfPresent(String.self, forKey: .assertionType) ?? defaults.assertionType
            modeIdentifier = try container.decodeIfPresent(String.self, forKey: .modeIdentifier) ?? defaults.modeIdentifier
            modeDisplayName = try container.decodeIfPresent(String.self, forKey: .modeDisplayName) ?? defaults.modeDisplayName
        }
    }

    public var actionIdentifier: String
    public var clientVersion: String
    public var minimumClientVersion: Int
    public var iconGlyph: Int
    public var iconColor: Int
    public var parameterKeys: ParameterKeys
    /// "until turned off" — the app turns the Focus off itself at the end of the meeting, so the
    /// shortcut must not attach an expiry of its own.
    public var assertionTypeWhenOn: String

    public init(
        actionIdentifier: String,
        clientVersion: String,
        minimumClientVersion: Int,
        iconGlyph: Int,
        iconColor: Int,
        parameterKeys: ParameterKeys,
        assertionTypeWhenOn: String
    ) {
        self.actionIdentifier = actionIdentifier
        self.clientVersion = clientVersion
        self.minimumClientVersion = minimumClientVersion
        self.iconGlyph = iconGlyph
        self.iconColor = iconColor
        self.parameterKeys = parameterKeys
        self.assertionTypeWhenOn = assertionTypeWhenOn
    }

    /// Every key is optional on the way in, so a recipe that patches only the action identifier
    /// still decodes. Synthesized `Decodable` would reject it — the failure that shipped once
    /// already with the Teams markers.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RecipeCodingKeys.self)
        let defaults = FocusShortcutRecipe.fallback
        actionIdentifier = try container.decodeIfPresent(String.self, forKey: .actionIdentifier)
            ?? defaults.actionIdentifier
        clientVersion = try container.decodeIfPresent(String.self, forKey: .clientVersion)
            ?? defaults.clientVersion
        minimumClientVersion = try container.decodeIfPresent(Int.self, forKey: .minimumClientVersion)
            ?? defaults.minimumClientVersion
        iconGlyph = try container.decodeIfPresent(Int.self, forKey: .iconGlyph) ?? defaults.iconGlyph
        iconColor = try container.decodeIfPresent(Int.self, forKey: .iconColor) ?? defaults.iconColor
        parameterKeys = try container.decodeIfPresent(ParameterKeys.self, forKey: .parameterKeys)
            ?? defaults.parameterKeys
        assertionTypeWhenOn = try container.decodeIfPresent(String.self, forKey: .assertionTypeWhenOn)
            ?? defaults.assertionTypeWhenOn
    }

    /// Used when the bundled resource cannot be read, so setup degrades rather than stops. Values
    /// read out of a working shortcut in a real library on 2026-08-25.
    public static let fallback = FocusShortcutRecipe(
        actionIdentifier: "is.workflow.actions.dnd.set",
        clientVersion: "2607.0.6.6",
        minimumClientVersion: 900,
        iconGlyph: 59511,
        iconColor: 4292093695,
        parameterKeys: ParameterKeys(),
        assertionTypeWhenOn: "Turned Off"
    )
}

public enum FocusShortcut {
    /// Serialises in binary because `shortcuts sign` rejects an XML plist outright, with the same
    /// error it gives for a wrong file extension.
    public static func plistData(
        recipe: FocusShortcutRecipe,
        focus: FocusMode,
        direction: FocusShortcutDirection
    ) throws -> Data {
        var parameters: [String: Any] = [
            recipe.parameterKeys.enabled: direction == .turnOn ? 1 : 0,
            recipe.parameterKeys.focusModes: [
                recipe.parameterKeys.modeIdentifier: focus.identifier,
                recipe.parameterKeys.modeDisplayName: focus.name,
            ],
        ]
        if direction == .turnOn {
            parameters[recipe.parameterKeys.assertionType] = recipe.assertionTypeWhenOn
        }

        let workflow: [String: Any] = [
            "WFWorkflowClientVersion": recipe.clientVersion,
            "WFWorkflowMinimumClientVersion": recipe.minimumClientVersion,
            "WFWorkflowMinimumClientVersionString": String(recipe.minimumClientVersion),
            "WFWorkflowTypes": [String](),
            "WFQuickActionSurfaces": [String](),
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowImportQuestions": [String](),
            "WFWorkflowInputContentItemClasses": [String](),
            "WFWorkflowIcon": [
                "WFWorkflowIconGlyphNumber": recipe.iconGlyph,
                "WFWorkflowIconStartColor": recipe.iconColor,
            ],
            "WFWorkflowActions": [
                [
                    "WFWorkflowActionIdentifier": recipe.actionIdentifier,
                    "WFWorkflowActionParameters": parameters,
                ],
            ],
        ]

        return try PropertyListSerialization.data(fromPropertyList: workflow, format: .binary, options: 0)
    }
}
```

Create `Resources/focus-shortcut.json`:

```json
{
  "actionIdentifier": "is.workflow.actions.dnd.set",
  "clientVersion": "2607.0.6.6",
  "minimumClientVersion": 900,
  "iconGlyph": 59511,
  "iconColor": 4292093695,
  "assertionTypeWhenOn": "Turned Off",
  "parameterKeys": {
    "enabled": "Enabled",
    "focusModes": "FocusModes",
    "assertionType": "AssertionType",
    "modeIdentifier": "Identifier",
    "modeDisplayName": "DisplayString"
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter FocusShortcutTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Prove the output is actually signable**

This is the one thing the unit tests cannot assert: that the shape they pin is a shape the signer
accepts. Verify by hand with the same tool the app will use:

```sh
mkdir -p /tmp/mf && cd /tmp/mf
# Write the on-variant with the values from Resources/focus-shortcut.json
plutil -convert binary1 -o "probe.shortcut" - <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>WFWorkflowActions</key><array><dict>
<key>WFWorkflowActionIdentifier</key><string>is.workflow.actions.dnd.set</string>
<key>WFWorkflowActionParameters</key><dict>
<key>Enabled</key><integer>1</integer>
<key>AssertionType</key><string>Turned Off</string>
<key>FocusModes</key><dict><key>Identifier</key><string>com.apple.focus.work</string><key>DisplayString</key><string>Work</string></dict>
</dict></dict></array>
<key>WFWorkflowClientVersion</key><string>2607.0.6.6</string>
<key>WFWorkflowMinimumClientVersion</key><integer>900</integer>
</dict></plist>
PLIST
shortcuts sign --mode anyone --input probe.shortcut --output signed.shortcut && echo OK
```

Expected: `OK`, and `signed.shortcut` starts with `AEA1` (`xxd signed.shortcut | head -1`).

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingFocusCore/FocusShortcut.swift Resources/focus-shortcut.json \
        Tests/MeetingFocusCoreTests/FocusShortcutTests.swift
git commit   # subject: "Build Focus shortcut plists from a bundled recipe"
```

---

### Task 2: Parsing the user's Focus list

**Files:**
- Modify: `Sources/MeetingFocusCore/FocusShortcut.swift` (append)
- Test: `Tests/MeetingFocusCoreTests/FocusShortcutTests.swift` (append a second class)

**Interfaces:**
- Consumes: `FocusMode` from Task 1.
- Produces: `FocusMode.parse(modeConfigurations: Data) -> [FocusMode]` — non-throwing, `[]` on anything unexpected, sorted by name.

- [ ] **Step 1: Write the failing test**

Append to `Tests/MeetingFocusCoreTests/FocusShortcutTests.swift`:

```swift
/// The Focus list comes from `~/Library/DoNotDisturb/DB/ModeConfigurations.json`, a private file
/// with no documented schema. Parsing it is where a macOS change lands first, so the shape is
/// pinned to a fixture rather than to whatever the developer's own Mac happens to hold.
final class FocusModeParsingTests: XCTestCase {
    private let sample = Data("""
    {"data": [{"modeConfigurations": {
      "com.apple.focus.work": {"mode": {"name": "Arbeiten", "modeIdentifier": "com.apple.focus.work"}},
      "com.apple.donotdisturb.mode.default": {"mode": {"name": "Nicht stören"}},
      "com.apple.sleep.sleep-mode": {"mode": {"name": "Schlafen"}}
    }}]}
    """.utf8)

    func testReadsEveryConfiguredFocusSortedByName() {
        let modes = FocusMode.parse(modeConfigurations: sample)
        XCTAssertEqual(modes.map(\.name), ["Arbeiten", "Nicht stören", "Schlafen"])
        XCTAssertEqual(modes.first?.identifier, "com.apple.focus.work")
    }

    /// A private file that has moved or changed shape must read as "no Focus modes", which the
    /// focus step degrades on — never as a crash and never as a half-parsed list.
    func testUnexpectedShapesYieldNothing() {
        XCTAssertTrue(FocusMode.parse(modeConfigurations: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(FocusMode.parse(modeConfigurations: Data("{}".utf8)).isEmpty)
        XCTAssertTrue(FocusMode.parse(modeConfigurations: Data(#"{"data": []}"#.utf8)).isEmpty)
    }

    /// An entry with no display name cannot be offered in a picker, so it is dropped rather than
    /// shown with its raw identifier.
    func testEntriesWithoutANameAreDropped() {
        let json = Data(#"{"data":[{"modeConfigurations":{"a.b.c":{"mode":{}}}}]}"#.utf8)
        XCTAssertTrue(FocusMode.parse(modeConfigurations: json).isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter FocusModeParsingTests`
Expected: FAIL — `type 'FocusMode' has no member 'parse'`.

- [ ] **Step 3: Write the implementation**

Append to `Sources/MeetingFocusCore/FocusShortcut.swift`:

```swift
public extension FocusMode {
    /// Reads DoNotDisturb's own configuration file. Private and undocumented, so every step is
    /// optional and an unreadable file yields an empty list rather than an error: the caller's
    /// fallback is to offer the manual route, which is a better outcome than a failure dialog.
    ///
    /// Shape, as observed on macOS 26:
    ///
    ///     { "data": [ { "modeConfigurations": {
    ///         "<identifier>": { "mode": { "name": "<display name>" } } } } ] }
    static func parse(modeConfigurations data: Data) -> [FocusMode] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]],
              let configurations = entries.first?["modeConfigurations"] as? [String: Any]
        else { return [] }

        return configurations.compactMap { identifier, value in
            guard let configuration = value as? [String: Any],
                  let mode = configuration["mode"] as? [String: Any],
                  let name = mode["name"] as? String,
                  !name.isEmpty
            else { return nil }
            return FocusMode(identifier: identifier, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter FocusModeParsingTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Run the whole core suite**

Run: `rm -f .make/test && make test`
Expected: green, including `FocusShortcutTests`, `FocusModeParsingTests`, and the pre-existing state-machine, coordinator and localization suites.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingFocusCore/FocusShortcut.swift Tests/MeetingFocusCoreTests/FocusShortcutTests.swift
git commit   # subject: "Parse the system's Focus list"
```

---

### Task 3: The window, its state, and the two copy-only steps

**Files:**
- Modify: `Sources/MeetingFocusApp/AppSettings.swift`
- Modify: `Sources/MeetingFocusApp/MeetingFocusApp.swift`
- Modify: `Sources/MeetingFocusApp/UI/MenuBarView.swift`
- Create: `Sources/MeetingFocusApp/UI/Onboarding/OnboardingView.swift`

**Interfaces:**
- Consumes: `AppSettings`, `MeetingMonitor`.
- Produces: `AppSettings.onboardingCompleted: Bool`, `AppSettings.onboardingStep: Int`; `OnboardingView(settings:monitor:)`; `OnboardingView.Step` (`welcome`, `permission`, `focus`, `finish`); the window id constant `MeetingFocusApp.onboardingWindowID = "onboarding"`.

- [ ] **Step 1: Add the two settings keys**

In `Sources/MeetingFocusApp/AppSettings.swift`, add to `enum Key`:

```swift
        static let onboardingCompleted = "onboardingCompleted"
        static let onboardingStep = "onboardingStep"
```

Add to the `defaults.register` dictionary:

```swift
            Key.onboardingCompleted: false,
            Key.onboardingStep: 0,
```

Add to `init` beside the other direct assignments:

```swift
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        onboardingStep = defaults.integer(forKey: Key.onboardingStep)
```

And the two properties, following the existing `didSet` pattern exactly:

```swift
    /// False on a fresh install *and* on an existing one, which is deliberate: an installation that
    /// predates onboarding has no shortcut configured either, so it benefits from the same walk.
    var onboardingCompleted: Bool = false {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }
    /// Where to resume. Quitting halfway through setup should not start it over.
    var onboardingStep: Int = 0 {
        didSet { defaults.set(onboardingStep, forKey: Key.onboardingStep) }
    }
```

- [ ] **Step 2: Write the onboarding shell with the welcome and finish steps**

Create `Sources/MeetingFocusApp/UI/Onboarding/OnboardingView.swift`:

```swift
import MeetingFocusCore
import SwiftUI

struct OnboardingView: View {
    /// The steps, in order. `permission` and `focus` are skippable; the two copy-only ends are not,
    /// because there is nothing on them to skip.
    enum Step: Int, CaseIterable {
        case welcome, permission, focus, finish
    }

    @Bindable var settings: AppSettings
    @Bindable var monitor: MeetingMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private var step: Step {
        Step(rawValue: settings.onboardingStep) ?? .welcome
    }

    var body: some View {
        VStack(spacing: 0) {
            indicator
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
        }
        .frame(width: 460, height: 380)
    }

    private var indicator: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { each in
                Circle()
                    .fill(each.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .permission: Text(verbatim: "permission")     // Task 4
        case .focus: Text(verbatim: "focus")               // Task 5
        case .finish: finish
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to MeetingFocus")
                .font(.title2.weight(.semibold))
            Text("""
                It notices when you join a meeting and turns on a Focus for you, then turns it off \
                again when the meeting ends. Setting that up takes three short steps.
                """)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Get Started") { advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You are set up")
                .font(.title2.weight(.semibold))
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    // A failure shows as the toggle bouncing back, because the value is re-read from
                    // the service rather than assumed. Settings → General reports the reason; this
                    // step deliberately does not grow an error label for the rare case.
                    try? LaunchAtLogin.setEnabled(newValue)
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            ))
            Text("A meeting detector that is not running cannot detect anything.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            // An LSUIElement app has no Dock tile, so the icon is the only thing the user can look
            // for. Saying what its three states mean is cheaper than a support question.
            Text("MeetingFocus lives in your menu bar. Its icon is hollow when you are not in a meeting, dotted while you are joining, and filled during one.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Done") {
                    settings.onboardingCompleted = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func advance() {
        settings.onboardingStep = min(step.rawValue + 1, Step.finish.rawValue)
    }
}
```

- [ ] **Step 3: Register the scene and the menu item**

In `Sources/MeetingFocusApp/MeetingFocusApp.swift`, add the id constant to the `MeetingFocusApp` struct and the scene after `Settings`:

```swift
    static let onboardingWindowID = "onboarding"
```

```swift
        Window("Set Up MeetingFocus", id: Self.onboardingWindowID) {
            OnboardingView(settings: delegate.settings, monitor: delegate.monitor)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // Opening itself on a fresh install is the whole point; on a configured one it must stay
        // shut, and `.suppressed` is what keeps a `Window` scene from being created at launch.
        .defaultLaunchBehavior(delegate.settings.onboardingCompleted ? .suppressed : .presented)
```

In `Sources/MeetingFocusApp/UI/MenuBarView.swift`, add the environment value beside `openSettings`:

```swift
    @Environment(\.openWindow) private var openWindow
```

and a first entry in `actions`:

```swift
        Button("Set Up MeetingFocus…") { showOnboarding() }
```

with the helper beside `showSettings()`, carrying the same activation hop for the same reason:

```swift
    private func showOnboarding() {
        openWindow(id: MeetingFocusApp.onboardingWindowID)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }
```

- [ ] **Step 4: Add the catalogue keys**

```sh
make xcstrings
X=./.build/xcstrings
$X add --catalog Localizable --key "Set Up MeetingFocus" --translation "de=MeetingFocus einrichten" --comment "Title of the onboarding window."
$X add --catalog Localizable --key "Set Up MeetingFocus…" --translation "de=MeetingFocus einrichten…" --comment "Menu item reopening the onboarding window."
$X add --catalog Localizable --key "Welcome to MeetingFocus" --translation "de=Willkommen bei MeetingFocus"
$X add --catalog Localizable --key "It notices when you join a meeting and turns on a Focus for you, then turns it off again when the meeting ends. Setting that up takes three short steps." --translation "de=Es erkennt, wenn du an einer Besprechung teilnimmst, und schaltet einen Fokus für dich ein — und am Ende der Besprechung wieder aus. Die Einrichtung dauert drei kurze Schritte."
$X add --catalog Localizable --key "Get Started" --translation "de=Los geht's"
$X add --catalog Localizable --key "You are set up" --translation "de=Alles eingerichtet"
$X add --catalog Localizable --key "A meeting detector that is not running cannot detect anything." --translation "de=Ein Besprechungserkenner, der nicht läuft, kann nichts erkennen."
$X add --catalog Localizable --key "MeetingFocus lives in your menu bar. Its icon is hollow when you are not in a meeting, dotted while you are joining, and filled during one." --translation "de=MeetingFocus sitzt in der Menüleiste. Das Symbol ist hohl, wenn du nicht in einer Besprechung bist, gepunktet beim Beitreten und gefüllt während einer Besprechung."
$X add --catalog Localizable --key "Done" --translation "de=Fertig"
$X fmt --catalog Localizable
```

Note `Launch at login` already exists as a key and is reused verbatim — do not add it again, and do not reword the literal.

- [ ] **Step 5: Verify**

Run: `rm -f .make/lint .make/test && make lint test build`
Expected: 0 violations, all tests pass (the localization coverage test is what proves step 4 matched step 2's literals character-for-character), BUILD SUCCEEDED.

Then by hand:

```sh
defaults delete me.mazetti.meetingfocus onboardingCompleted 2>/dev/null
defaults delete me.mazetti.meetingfocus onboardingStep 2>/dev/null
open ./.build-xcode/Build/Products/Debug/MeetingFocus.app
```

Expected: the window opens at launch, centred, showing Welcome with the first of four dots filled. Click *Get Started*, quit the app, relaunch — it reopens on the placeholder `permission` step, not on Welcome. Set `onboardingStep` to 3 (`defaults write me.mazetti.meetingfocus onboardingStep 3`), relaunch, click *Done*: the window closes and a further relaunch does not reopen it. The menu's *Set Up MeetingFocus…* reopens it and brings it to the front over another app's window.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingFocusApp/AppSettings.swift Sources/MeetingFocusApp/MeetingFocusApp.swift \
        Sources/MeetingFocusApp/UI/MenuBarView.swift \
        Sources/MeetingFocusApp/UI/Onboarding/OnboardingView.swift \
        Sources/MeetingFocusApp/Localizable.xcstrings
git commit   # subject: "Add a resumable onboarding window"
```

---

### Task 4: The permission step, and moving the launch-time prompt into it

**Files:**
- Modify: `Sources/MeetingFocusApp/UI/Onboarding/OnboardingView.swift`
- Modify: `Sources/MeetingFocusApp/MeetingFocusApp.swift:13-16` (the `applicationDidFinishLaunching` request)

**Interfaces:**
- Consumes: `OnboardingView.Step`, `monitor.accessibilityTrusted`, `AccessibilityAuthorization.requestIfNeeded()` / `.openSystemSettings()`.
- Produces: nothing new.

- [ ] **Step 1: Replace the placeholder with the step**

In `OnboardingView.swift`, change `case .permission:` to `permission`, and add:

```swift
    private var permission: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let MeetingFocus see your meetings")
                .font(.title2.weight(.semibold))
            // Deliberately not naming one app: per-app detectors are next, and copy naming Teams
            // would need rewriting the moment the second one lands.
            Text("""
                Accessibility permission lets MeetingFocus read the windows of your meeting apps, \
                which is how it can tell a real meeting from an open app. Without it, detection \
                falls back to microphone activity alone.
                """)
                .foregroundStyle(.secondary)
            if monitor.accessibilityTrusted {
                Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant Accessibility…") { AccessibilityAuthorization.requestIfNeeded() }
                Text("macOS asks you to confirm in System Settings. This window will tick when it is done.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Privacy & Security…") { AccessibilityAuthorization.openSystemSettings() }
                    .buttonStyle(.link)
            }
            Spacer()
            HStack {
                Button("Later") { advance() }
                Spacer()
                Button("Continue") { advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!monitor.accessibilityTrusted)
            }
        }
    }
```

- [ ] **Step 2: Stop asking at launch**

In `MeetingFocusApp.swift`, delete these lines from `applicationDidFinishLaunching`:

```swift
        // Ask once at launch; if it is refused the app degrades to microphone-only detection and
        // the menu explains how to grant it later.
        if !AccessibilityAuthorization.isTrusted {
            AccessibilityAuthorization.requestIfNeeded()
        }
```

and replace them with a comment recording why nothing asks here any more:

```swift
        // Deliberately does not ask for Accessibility. A permission dialog with no explanation in
        // front of it gets refused; the onboarding window's permission step asks instead, and the
        // menu and Settings both offer it afterwards.
```

- [ ] **Step 3: Add the catalogue keys**

```sh
X=./.build/xcstrings
$X add --catalog Localizable --key "Let MeetingFocus see your meetings" --translation "de=MeetingFocus deine Besprechungen sehen lassen"
$X add --catalog Localizable --key "Accessibility permission lets MeetingFocus read the windows of your meeting apps, which is how it can tell a real meeting from an open app. Without it, detection falls back to microphone activity alone." --translation "de=Die Bedienungshilfen-Berechtigung erlaubt MeetingFocus, die Fenster deiner Besprechungs-Apps zu lesen — so lässt sich eine echte Besprechung von einer bloß geöffneten App unterscheiden. Ohne sie bleibt nur die Mikrofonaktivität."
$X add --catalog Localizable --key "Grant Accessibility…" --translation "de=Bedienungshilfen erlauben…"
$X add --catalog Localizable --key "macOS asks you to confirm in System Settings. This window will tick when it is done." --translation "de=macOS bittet dich um Bestätigung in den Systemeinstellungen. Dieses Fenster hakt ab, sobald es erledigt ist."
$X add --catalog Localizable --key "Later" --translation "de=Später"
$X add --catalog Localizable --key "Continue" --translation "de=Weiter"
$X fmt --catalog Localizable
```

`Accessibility granted` and `Open Privacy & Security…` are pre-existing keys — but note `Open Privacy & Security…` was **removed** from the catalogue when the menu bar moved to a native menu. Check before adding:

```sh
$X audit --catalog Localizable | head -3
python3 -c "import json;d=json.load(open('Sources/MeetingFocusApp/Localizable.xcstrings'));print('Open Privacy & Security…' in d['strings'], 'Accessibility granted' in d['strings'])"
```

Add whichever prints `False`:

```sh
$X add --catalog Localizable --key "Open Privacy & Security…" --translation "de=Datenschutz & Sicherheit öffnen…"
$X add --catalog Localizable --key "Accessibility granted" --translation "de=Bedienungshilfen erteilt"
```

- [ ] **Step 4: Verify**

Run: `rm -f .make/lint .make/test && make lint test build`
Expected: 0 violations, tests pass, BUILD SUCCEEDED.

By hand, with permission already granted (the normal case on the dev machine): reset onboarding as in Task 3 Step 5, launch, click through to the permission step, and confirm it shows the green tick and an enabled *Continue*, and that **no system dialog appeared at launch**.

To see the ungranted path, revoke it in System Settings → Privacy & Security → Accessibility for MeetingFocus, relaunch, and confirm *Continue* is disabled, *Later* still advances, and *Grant Accessibility…* raises the system prompt. Re-grant afterwards.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingFocusApp/UI/Onboarding/OnboardingView.swift \
        Sources/MeetingFocusApp/MeetingFocusApp.swift Sources/MeetingFocusApp/Localizable.xcstrings
git commit   # subject: "Ask for Accessibility in onboarding, not at launch"
```

---

### Task 5: The focus step — install the two shortcuts

**Files:**
- Create: `Sources/MeetingFocusApp/Automation/FocusModeCatalog.swift`
- Create: `Sources/MeetingFocusApp/Automation/FocusShortcutInstaller.swift`
- Create: `Sources/MeetingFocusApp/UI/Onboarding/OnboardingFocusStep.swift`
- Modify: `Sources/MeetingFocusApp/UI/Onboarding/OnboardingView.swift` (replace the `focus` placeholder)

**Interfaces:**
- Consumes: `FocusMode`, `FocusShortcut.plistData(recipe:focus:direction:)`, `FocusShortcutRecipe`, `ShortcutsAutomationHandler.toolURL`, `ShortcutsAutomationHandler.availableShortcutNames()`, `AppSettings.startShortcutName` / `.endShortcutName`.
- Produces: `FocusModeCatalog.load() -> [FocusMode]`; `FocusShortcutInstaller.shortcutName(for: FocusShortcutDirection) -> String`, `.install(focus:direction:) throws`, `.awaitInstalled(names:) async -> Bool`; `OnboardingFocusStep(settings:advance:)`.

- [ ] **Step 1: Write the Focus-list reader**

Create `Sources/MeetingFocusApp/Automation/FocusModeCatalog.swift`:

```swift
import Foundation
import MeetingFocusCore

/// Reads the Focus modes configured on this Mac. There is no API for this — `INFocusStatusCenter`
/// reports only whether a Focus is on — so it comes from DoNotDisturb's own file. Private, so an
/// empty result is an expected outcome and the caller offers the manual route instead.
enum FocusModeCatalog {
    static let fileURL = URL.homeDirectory
        .appending(path: "Library/DoNotDisturb/DB/ModeConfigurations.json")

    static func load() -> [FocusMode] {
        guard let data = try? Data(contentsOf: fileURL) else {
            Log.automation.notice("no Focus configuration file at \(fileURL.path, privacy: .public)")
            return []
        }
        let modes = FocusMode.parse(modeConfigurations: data)
        Log.automation.info("read \(modes.count, privacy: .public) Focus modes")
        return modes
    }
}
```

- [ ] **Step 2: Write the installer**

Create `Sources/MeetingFocusApp/Automation/FocusShortcutInstaller.swift`:

```swift
import AppKit
import Foundation
import MeetingFocusCore

/// Generates a Focus shortcut, signs it with the user's own copy of Apple's tool, and hands it to
/// Shortcuts for the one confirmation macOS requires. Nothing here can add a shortcut silently —
/// there is no API to write to the Shortcuts library — so "install" is the honest word, not "done".
enum FocusShortcutInstaller {
    enum Failure: LocalizedError {
        case signing(String)
        case couldNotOpen

        var errorDescription: String? {
            switch self {
            case .signing(let message):
                message.isEmpty
                    ? String(localized: "The shortcut could not be signed.")
                    : message
            case .couldNotOpen:
                String(localized: "Shortcuts would not open the generated file.")
            }
        }
    }

    /// The imported shortcut takes its name from the filename, so these strings end up in the
    /// user's library permanently — which is why they are localized rather than fixed English.
    static func shortcutName(for direction: FocusShortcutDirection) -> String {
        switch direction {
        case .turnOn: String(localized: "MeetingFocus – Focus On")
        case .turnOff: String(localized: "MeetingFocus – Focus Off")
        }
    }

    static func install(focus: FocusMode, direction: FocusShortcutDirection) throws {
        let recipe = loadRecipe()
        let data = try FocusShortcut.plistData(recipe: recipe, focus: focus, direction: direction)

        let directory = URL.temporaryDirectory.appending(path: "MeetingFocus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Both paths end in `.shortcut` because the signer rejects any other input extension with
        // the same error it gives for an XML plist. The output's *name* is the shortcut's name.
        let name = shortcutName(for: direction)
        let unsigned = directory.appending(path: "\(name).unsigned.shortcut")
        let signed = directory.appending(path: "\(name).shortcut")

        try data.write(to: unsigned)
        try sign(input: unsigned, output: signed)

        guard NSWorkspace.shared.open(signed) else { throw Failure.couldNotOpen }
        Log.automation.info("opened generated shortcut \(name, privacy: .public) for import")
    }

    /// Polls the library, because the import completes when the *user* confirms it and nothing
    /// notifies us. Bounded: a user who cancels must not leave a spinner running forever.
    static func awaitInstalled(names: [String], timeout: Duration = .seconds(90)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let available = Set(await ShortcutsAutomationHandler.availableShortcutNames())
            if names.allSatisfy(available.contains) { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private static func loadRecipe(from bundle: Bundle = .main) -> FocusShortcutRecipe {
        guard let url = bundle.url(forResource: "focus-shortcut", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(FocusShortcutRecipe.self, from: data)
        else {
            Log.automation.error("focus-shortcut.json missing or unreadable; using built-in fallback")
            return .fallback
        }
        return decoded
    }

    private static func sign(input: URL, output: URL) throws {
        let process = Process()
        process.executableURL = ShortcutsAutomationHandler.toolURL
        process.arguments = ["sign", "--mode", "anyone", "--input", input.path, "--output", output.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = try? errors.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data ?? Data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Log.automation.error("shortcuts sign failed: \(message, privacy: .public)")
            throw Failure.signing(message)
        }
    }
}
```

- [ ] **Step 3: Write the step view**

Create `Sources/MeetingFocusApp/UI/Onboarding/OnboardingFocusStep.swift`:

```swift
import MeetingFocusCore
import SwiftUI

struct OnboardingFocusStep: View {
    @Bindable var settings: AppSettings
    let advance: () -> Void

    @State private var modes: [FocusMode] = []
    @State private var selected: String = ""
    @State private var installing = false
    @State private var installed = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which Focus should meetings turn on?")
                .font(.title2.weight(.semibold))

            if modes.isEmpty {
                unavailable
            } else if installed {
                Label("Shortcuts installed and selected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                picker
            }

            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }

            Spacer()
            HStack {
                Button("Later") { advance() }
                Spacer()
                Button(installed ? "Continue" : "Install Shortcuts") {
                    if installed { advance() } else { install() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(installing || (!installed && selected.isEmpty))
            }
        }
        .task {
            modes = FocusModeCatalog.load()
            // Work is the Focus almost everyone means; falling back to the first keeps the picker
            // usable for someone who deleted it.
            selected = modes.first { $0.identifier == "com.apple.focus.work" }?.identifier
                ?? modes.first?.identifier ?? ""
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Empty label, matching `SettingsView.shortcutPicker`: the heading above already says
            // what this picks, and a label hidden by `labelsHidden()` still demands a catalogue key.
            Picker("", selection: $selected) {
                ForEach(modes) { mode in Text(mode.name).tag(mode.identifier) }
            }
            .labelsHidden()
            // Said before the first sheet appears, because two confirmations in a row with no
            // warning reads as a glitch.
            Text("MeetingFocus will add two shortcuts — one to turn the Focus on, one to turn it off — and Shortcuts will ask you to confirm each.")
                .font(.caption).foregroundStyle(.secondary)
            if installing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to add them…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MeetingFocus could not read your Focus modes, so it cannot build the shortcuts for you.")
                .foregroundStyle(.secondary)
            Text("Make a shortcut with the Set Focus action, then pick it in Settings → Automation.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Shortcuts") {
                if let url = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.apple.shortcuts"
                ) {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
        }
    }

    private func install() {
        guard let focus = modes.first(where: { $0.identifier == selected }) else { return }
        failure = nil
        installing = true
        let names = [
            FocusShortcutInstaller.shortcutName(for: .on),
            FocusShortcutInstaller.shortcutName(for: .off),
        ]
        Task {
            do {
                try FocusShortcutInstaller.install(focus: focus, direction: .turnOn)
                try FocusShortcutInstaller.install(focus: focus, direction: .turnOff)
            } catch {
                failure = error.localizedDescription
                installing = false
                return
            }
            if await FocusShortcutInstaller.awaitInstalled(names: names) {
                // The whole point: the user never types a shortcut name.
                settings.startShortcutName = names[0]
                settings.endShortcutName = names[1]
                installed = true
            } else {
                failure = String(localized: "The shortcuts were not added. You can try again, or set them up in Settings.")
            }
            installing = false
        }
    }
}
```

In `OnboardingView.swift`, replace the placeholder:

```swift
        case .focus: OnboardingFocusStep(settings: settings, advance: advance)
```

- [ ] **Step 4: Add the catalogue keys**

```sh
X=./.build/xcstrings
$X add --catalog Localizable --key "Which Focus should meetings turn on?" --translation "de=Welchen Fokus sollen Besprechungen einschalten?"
$X add --catalog Localizable --key "MeetingFocus – Focus On" --translation "de=MeetingFocus – Fokus ein" --comment "Name of the generated shortcut that turns the Focus on. Lives in the user's Shortcuts library."
$X add --catalog Localizable --key "MeetingFocus – Focus Off" --translation "de=MeetingFocus – Fokus aus" --comment "Name of the generated shortcut that turns the Focus off."
$X add --catalog Localizable --key "Shortcuts installed and selected" --translation "de=Kurzbefehle installiert und ausgewählt"
$X add --catalog Localizable --key "Install Shortcuts" --translation "de=Kurzbefehle installieren"
$X add --catalog Localizable --key "MeetingFocus will add two shortcuts — one to turn the Focus on, one to turn it off — and Shortcuts will ask you to confirm each." --translation "de=MeetingFocus fügt zwei Kurzbefehle hinzu — einen zum Einschalten des Fokus, einen zum Ausschalten — und die Kurzbefehle-App bittet dich, jeden zu bestätigen."
$X add --catalog Localizable --key "Waiting for you to add them…" --translation "de=Warte darauf, dass du sie hinzufügst…"
$X add --catalog Localizable --key "MeetingFocus could not read your Focus modes, so it cannot build the shortcuts for you." --translation "de=MeetingFocus konnte deine Fokus-Modi nicht lesen und kann die Kurzbefehle daher nicht für dich erstellen."
$X add --catalog Localizable --key "Make a shortcut with the Set Focus action, then pick it in Settings → Automation." --translation "de=Erstelle einen Kurzbefehl mit der Aktion „Fokus einschalten“ und wähle ihn dann unter Einstellungen → Automatisierung aus."
$X add --catalog Localizable --key "The shortcuts were not added. You can try again, or set them up in Settings." --translation "de=Die Kurzbefehle wurden nicht hinzugefügt. Du kannst es erneut versuchen oder sie in den Einstellungen einrichten."
$X add --catalog Localizable --key "The shortcut could not be signed." --translation "de=Der Kurzbefehl konnte nicht signiert werden."
$X add --catalog Localizable --key "Shortcuts would not open the generated file." --translation "de=Die Kurzbefehle-App hat die erzeugte Datei nicht geöffnet."
$X fmt --catalog Localizable
```

`Open Shortcuts` already exists as a key from `SettingsView` — reuse it, do not add it.

- [ ] **Step 5: Verify**

Run: `rm -f .make/lint .make/test && make lint test build`
Expected: 0 violations, tests pass, BUILD SUCCEEDED.

**This is the manual check the spike could not do.** Reset onboarding, launch, walk to the focus step:

```sh
defaults delete me.mazetti.meetingfocus onboardingCompleted
defaults write me.mazetti.meetingfocus onboardingStep 2
defaults delete me.mazetti.meetingfocus startShortcutName 2>/dev/null
defaults delete me.mazetti.meetingfocus endShortcutName 2>/dev/null
open ./.build-xcode/Build/Products/Debug/MeetingFocus.app
```

Confirm, in order:

1. The picker lists the real Focus modes from this Mac, with Work preselected.
2. *Install Shortcuts* produces a Shortcuts confirmation sheet **that reads as the Set Focus action** — "Turn Work on" or the localized equivalent — and **not** an unknown-action placeholder. If it is a placeholder, stop: the parameter shape is wrong, and the fix belongs in Task 1's recipe, not here.
3. Adding both leaves the step ticked, and `defaults read me.mazetti.meetingfocus startShortcutName` prints `MeetingFocus – Focus On`.
4. `shortcuts list | grep MeetingFocus` shows both.
5. Cancelling both sheets instead leaves an error message and a working *Later*, not a stuck spinner.
6. `shortcuts run "MeetingFocus – Focus On"` actually turns the Focus on, and the off one turns it off. This is the end-to-end proof that the generated shortcut works, independent of the app.

Delete the two shortcuts from the library afterwards if you want to re-run the check.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingFocusApp/Automation/FocusModeCatalog.swift \
        Sources/MeetingFocusApp/Automation/FocusShortcutInstaller.swift \
        Sources/MeetingFocusApp/UI/Onboarding/OnboardingFocusStep.swift \
        Sources/MeetingFocusApp/UI/Onboarding/OnboardingView.swift \
        Sources/MeetingFocusApp/Localizable.xcstrings
git commit   # subject: "Install the Focus shortcuts from onboarding"
```

---

### Task 6: Correct the documents this supersedes

**Files:**
- Modify: `docs/constraints.md` (C4, and open question F2)
- Modify: `docs/BACKLOG.md` (items 4 and 9)
- Modify: `docs/architecture.md` (automation backend section, and the module table)
- Modify: `README.md` (the manual Focus-shortcut setup instructions)

**Interfaces:** none.

- [ ] **Step 1: Rewrite C4**

Its current verdict — "Resolved by not relying on it" — is now false. Replace the resolution paragraph with what was actually built: nothing unsigned is shipped, because the shortcut is generated on the user's machine and signed there by `/usr/bin/shortcuts sign --mode anyone`, so no bundled-file trust question arises. Keep the heading and the original concern; the register's value is that it records what was believed and when.

- [ ] **Step 2: Answer F2**

Open question 2, "Is the bundled `.shortcut` trusted? (C4) Gates the onboarding promise", is answered by dissolution: nothing is bundled, so nothing needs to be trusted. Record the finding — local signing, binary plist, `.shortcut` input extension — and remove it from the open-questions list.

- [ ] **Step 3: Rewrite backlog item 9**

Currently "Bundled Focus shortcut, if a one-click path is wanted", deferred because "macOS treats shortcut files from unidentified sources as untrusted". That reason no longer holds. Rewrite as done, naming what shipped, and drop the iCloud-share-link suggestion — it is superseded, not pending.

- [ ] **Step 4: Update backlog item 4**

It names empty `startShortcutName`/`endShortcutName` as the prerequisite blocking end-to-end verification. Note that onboarding now configures both, so the item is down to holding one real meeting and watching the log.

- [ ] **Step 5: Update architecture.md**

Add `Resources/focus-shortcut.json` to the module table beside `teams-markers.json`, with the same "as data so it can be patched" note. In "Adding an automation backend", note that the Shortcuts backend now also *generates* the shortcut it later runs, and where that lives.

- [ ] **Step 6: Update the README**

Its Focus-shortcut instructions describe the manual route as the only route. Lead with onboarding's one-click install and keep the manual steps as the fallback for someone whose Focus list cannot be read — do not delete them.

- [ ] **Step 7: Verify and commit**

Run: `make lint test build smoke`
Expected: all green.

```bash
git add docs/constraints.md docs/BACKLOG.md docs/architecture.md README.md
git commit   # subject: "Record that one-click Focus setup is no longer blocked"
```

- [ ] **Step 8: The verification that needs a real meeting**

Not gateable in one sitting, and the point of the whole plan, so it is written down rather than
assumed. After the tasks above, the app has what backlog item 4 says it was missing: both shortcut
names configured. During the next real call, watch it fire:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "me.mazetti.meetingfocus"'
```

Expected: a detection, then `.started`, then the start shortcut running, then the Focus turning on —
and at the end, after the 45-second cooldown, the reverse. Turning on Settings → Diagnostics → Debug
mode also surfaces each detection in the menu while the call runs.

If the Focus does not change but the log shows the shortcut running, the fault is in the generated
shortcut and Task 5 Step 5 item 6 is the isolation test. If nothing runs at all, read
`startShortcutName` from `defaults` — the installer writes it only after both imports are confirmed.

---

## Notes for the executor

**Things that will bite:**

- `shortcuts sign` gives one error message — "The file couldn't be opened because it isn't in the correct format" — for two unrelated causes: an XML plist, and an input path not ending in `.shortcut`. If you hit it, check both before suspecting the parameters.
- A `Window` scene in a SwiftUI app is created at launch by default. `.defaultLaunchBehavior(.suppressed)` is what stops the onboarding window from appearing for a user who has finished setup; without it the flag is read but the window still opens.
- `AppDelegate` cannot call `openWindow` — it is an `@Environment` value, only available inside a view. That is why the launch-time presentation is done with `.defaultLaunchBehavior` and the reopen from `MenuBarView`, and not from `applicationDidFinishLaunching`.
- Adding a literal without its catalogue key fails `make test`, and so does the reverse. Both directions are enforced by `Tests/LocalizationTests`. Add keys in the same commit.
- `String(localized:)` is how this codebase localizes a `String` (not a `Text`); see `ShortcutsAutomationHandler.Failure`.

**Out of scope — do not fix along the way** (each is recorded in the spec):

- `MeetingMonitor.restart()` is never called, so the Settings detector toggles need a relaunch.
- `defaultAudioAllowlist` is a hardcoded constant, so covering a new meeting app needs an app release.
- `SettingsView.shortcutPicker(_ title: String)` and the Accessibility-status ternary both render English regardless of locale, and `isLocalizingSite`'s suffix match hides the first by treating `shortcutPicker(` as `Picker(`.
