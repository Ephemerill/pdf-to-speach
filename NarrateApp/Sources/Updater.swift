import Foundation
import Observation
import Sparkle

/// Updates via Sparkle. The feed (`SUFeedURL` in Info.plist) is the appcast on the repo's gh-pages
/// branch; every update archive in it is EdDSA-signed (`SUPublicEDKey`) and the app itself is
/// Developer ID signed and notarized, so Sparkle can verify, swap and relaunch with no prompts.
/// Sparkle draws its own windows (release notes, progress, "Install and Relaunch").
@Observable @MainActor
final class Updater {
    nonisolated static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// False while Sparkle is already busy with a check or an install.
    private(set) var canCheck = false

    /// Daily background checks (Options ▸ Updates).
    var automatic: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automatic }
    }

    init() {
        // Development runs (engine outside the bundle) never update themselves.
        let dev = ProcessInfo.processInfo.environment["NARRATE_ENGINE"] != nil
        controller = SPUStandardUpdaterController(startingUpdater: !dev, updaterDelegate: nil, userDriverDelegate: nil)
        automatic = controller.updater.automaticallyChecksForUpdates
        canCheck = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] u, _ in
            let can = u.canCheckForUpdates
            Task { @MainActor in self?.canCheck = can }
        }
    }

    func check() { controller.checkForUpdates(nil) }
}
