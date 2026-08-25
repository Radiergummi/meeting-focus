import Foundation

/// Marker definitions loaded from a bundled JSON resource.
///
/// Deliberately data rather than source. These are Microsoft's internal HTML element ids, so they
/// can be renamed by any Teams release; keeping them in a resource means a fix is a data change
/// that can ship in a patch release, and it is the seam that would later allow a remotely
/// refreshed manifest without redesigning anything.
struct TeamsMarkers: Decodable, Sendable {
    struct MarkerSet: Decodable, Sendable {
        var primary: [String] = []
        var secondary: [String] = []
        var all: Set<String> { Set(primary).union(secondary) }

        init(primary: [String] = [], secondary: [String] = []) {
            self.primary = primary
            self.secondary = secondary
        }

        private enum CodingKeys: String, CodingKey { case primary, secondary }

        /// Swift's synthesized `Decodable` does not apply property default values, so a marker set
        /// that legitimately has no secondary entries would fail to decode. Both keys are optional
        /// here so the resource stays readable.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primary = try container.decodeIfPresent([String].self, forKey: .primary) ?? []
            secondary = try container.decodeIfPresent([String].self, forKey: .secondary) ?? []
        }
    }

    var bundleIdentifiers: [String]
    var applicationName: String
    var titleSuffixesToStrip: [String]
    var inMeeting: MarkerSet
    var joining: MarkerSet
    var durationElementID: String

    static func load(from bundle: Bundle = .main) -> TeamsMarkers {
        guard let url = bundle.url(forResource: "teams-markers", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TeamsMarkers.self, from: data)
        else {
            Log.detector.error("teams-markers.json missing or unreadable; using built-in fallback")
            return .fallback
        }
        return decoded
    }

    /// Used only if the resource cannot be read, so the app degrades rather than stops detecting.
    static let fallback = TeamsMarkers(
        bundleIdentifiers: ["com.microsoft.teams2"],
        applicationName: "Microsoft Teams",
        titleSuffixesToStrip: [" | Microsoft Teams"],
        inMeeting: MarkerSet(
            primary: ["call-duration-custom"],
            secondary: ["hangup-button", "microphone-button", "video-button", "indicators", "horizontalEnd"]
        ),
        joining: MarkerSet(primary: ["prejoin-join-button"]),
        durationElementID: "call-duration-custom"
    )
}
