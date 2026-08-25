import Foundation

public enum FocusShortcutDirection: Sendable {
    case turnOn, turnOff
}

private enum RecipeCodingKeys: String, CodingKey {
    case actionIdentifier, clientVersion, minimumClientVersion
    case iconGlyph, iconColor, parameterKeys, assertionTypeWhenOn
}

private enum ParameterKeyCodingKeys: String, CodingKey {
    case enabled, assertionType
}

/// The Set Focus action as data rather than source, for the same reason `teams-markers.json` is
/// data: the identifiers are Apple's private vocabulary and can be renamed by any macOS release, so
/// a fix should be a data change. It is also the seam a remotely refreshed manifest would use.
public struct FocusShortcutRecipe: Decodable, Sendable {
    public struct ParameterKeys: Decodable, Sendable {
        public var enabled: String = "Enabled"
        public var assertionType: String = "AssertionType"

        public init(
            enabled: String = "Enabled",
            assertionType: String = "AssertionType"
        ) {
            self.enabled = enabled
            self.assertionType = assertionType
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: ParameterKeyCodingKeys.self)
            let defaults = ParameterKeys()
            enabled = try container.decodeIfPresent(String.self, forKey: .enabled) ?? defaults.enabled
            assertionType = try container.decodeIfPresent(String.self, forKey: .assertionType) ?? defaults.assertionType
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
    ///
    /// Deliberately omits the `FocusModes` parameter. There is no way to read the user's Focus modes
    /// without Full Disk Access, so the action ships without one — which Shortcuts renders as a valid
    /// action set to Do Not Disturb, with the Focus name tappable so the user can retarget it.
    public static func plistData(
        recipe: FocusShortcutRecipe,
        direction: FocusShortcutDirection
    ) throws -> Data {
        var parameters: [String: Any] = [
            recipe.parameterKeys.enabled: direction == .turnOn ? 1 : 0,
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
