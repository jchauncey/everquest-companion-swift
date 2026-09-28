// The app's updater: Sparkle, reading the appcast published beside each GitHub release
// (`SUFeedURL` in Info.plist → `releases/latest/download/appcast.xml`), and installing an update only
// when its EdDSA signature verifies against the public key baked into this build (`SUPublicEDKey`).
//
// THE ONLY NETWORK USE BESIDE SOUND PACKS. It asks one thing — is there a newer release — and
// downloads only what the user agrees to install. Whether it asks by itself is the user's choice:
// Sparkle puts that question on the second launch, and Preferences → Updates holds the answer.
//
// A build without a feed or a key (`swift run`, a bundle built before `make sparkle-key` was run)
// starts no updater at all, so it never shows Sparkle's "this app is misconfigured" alert; the
// Updates page says why there is nothing to check.
import Foundation
import Sparkle

@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// nil when this build carries no feed or no key.
    private let controller: SPUStandardUpdaterController?
    private var observers: [NSKeyValueObservation] = []

    private(set) var canCheck = false
    private(set) var lastCheck: Date?

    /// Why this build cannot update itself, when it cannot.
    let unavailableReason: String?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        if feed.isEmpty || key.isEmpty || key.hasPrefix("__") {
            controller = nil
            unavailableReason = Bundle.main.bundleURL.pathExtension == "app"
                ? "This build was made without an update signing key, so it cannot verify an update."
                : "Running from source: updates apply to the installed app."
            return
        }
        unavailableReason = nil
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        canCheck = c.updater.canCheckForUpdates
        lastCheck = c.updater.lastUpdateCheckDate
        observers = [
            c.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] u, _ in
                let v = u.canCheckForUpdates
                Task { @MainActor in self?.canCheck = v }
            },
            c.updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] u, _ in
                let d = u.lastUpdateCheckDate
                Task { @MainActor in self?.lastCheck = d }
            },
        ]
    }

    var available: Bool { controller != nil }

    /// Sparkle's own flow: a window that says whether there is an update and offers to install it.
    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// Whether Sparkle looks by itself (about once a day). Sparkle asks the user on the second
    /// launch; this is the same setting afterwards.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Download the update in the background, so installing it is one click.
    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }
}
