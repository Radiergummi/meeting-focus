import Foundation
import Sparkle

/// Auto-update via Sparkle.
///
/// This is not a nice-to-have. Detection depends on internal element ids that Microsoft can rename
/// in any Teams release, so a build with no update path is a build that will eventually stop
/// working with no way to fix it in the field. Sparkle is what makes a marker fix deliverable.
///
/// Updates are signed with an EdDSA key whose public half is in `Info.plist` (`SUPublicEDKey`) and
/// whose private half lives in the maintainer's login keychain. Losing that key means no existing
/// installation can ever be updated again.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }
}
