import Foundation
import Observation
import Sparkle

/// Owns Sparkle's standard updater (spec D10). The only network traffic
/// MFPete makes is this update check.
///
/// The updater starts only in a real launch with a public EdDSA key in
/// Info.plist. Development builds without a key, UI tests, and unit tests
/// leave it off, and Settings › About says so.
@Observable
final class UpdaterService {
    private(set) var isAvailable = false
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    func start() {
        guard controller == nil, Self.shouldStart else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        isAvailable = true
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private static var shouldStart: Bool {
        if UITestingFixture.isActive { return false }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
