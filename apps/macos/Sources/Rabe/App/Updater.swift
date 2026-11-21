import AppKit
import RabeKit
import Sparkle

/// M3.2: Updates über Sparkle 2.
///
/// Der Feed steht im Release in der Info.plist (`SUFeedURL`), der Schlüssel in
/// `SUPublicEDKey`. In der Sandbox und in Hook-Builds entscheidet
/// `UpdaterPolicy`: dort bleibt der Updater aus, außer
/// `CORAX_UPDATER_TEST_FEED` zeigt ausdrücklich auf einen lokalen Feed.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// Steht so im Menü und in den Einstellungen; `false` in Sandbox/Hooks.
    @Published private(set) var available = false
    /// Grund, warum der Updater aus ist (steht im Log und in den Einstellungen).
    @Published private(set) var disabledReason: String?
    /// „Automatisch nach Updates suchen" (Standard an, täglich).
    @Published var automaticChecks = true {
        didSet { applyAutomaticallyChecks(oldValue) }
    }
    /// „Updates automatisch laden" (Standard aus).
    @Published var automaticDownloads = false {
        didSet { applyAutomaticallyDownloads(oldValue) }
    }
    @Published private(set) var lastResult: String?

    private var controller: SPUStandardUpdaterController?
    /// Nur für den Testschalter gesetzt; im Release kommt der Feed aus der Plist.
    nonisolated(unsafe) private var feedOverride: String?
    private var pendingSource = "automatic"

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Wird vom AppDelegate nach dem Start gerufen. Ohne Release-Feed und ohne
    /// Testschalter passiert nichts — die Sandbox zieht nie ein echtes Update.
    func start() {
        guard controller == nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let mode = UpdaterPolicy.decide(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            feedURL: info["SUFeedURL"] as? String,
            publicKey: info["SUPublicEDKey"] as? String,
            testHooks: Updater.isHookBuild,
            environment: ProcessInfo.processInfo.environment)

        switch mode {
        case .disabled(let reason):
            disabledReason = reason
            PerfLog.shared.write("update_disabled reason=\(reason) version=\(versionText)")
        case .enabled(let feed, let testFeed):
            feedOverride = testFeed ? feed.absoluteString : nil
            let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                          updaterDelegate: self,
                                                          userDriverDelegate: nil)
            self.controller = controller
            do {
                try controller.updater.start()
            } catch {
                disabledReason = "start_failed"
                PerfLog.shared.write("update_disabled reason=start_failed error=\(error.localizedDescription)")
                self.controller = nil
                return
            }
            available = true
            automaticChecks = controller.updater.automaticallyChecksForUpdates
            automaticDownloads = controller.updater.automaticallyDownloadsUpdates
            PerfLog.shared.write("update_ready feed=\(feed.absoluteString) test=\(testFeed ? 1 : 0) version=\(versionText)")
        }
    }

    /// Menüpunkt und Einstellungen. Loggt auch den Weg (manuell/automatisch).
    func checkForUpdates() {
        guard let controller else {
            PerfLog.shared.write("update_check source=manual result=disabled")
            return
        }
        guard controller.updater.canCheckForUpdates else {
            PerfLog.shared.write("update_check source=manual result=busy")
            return
        }
        pendingSource = "manual"
        PerfLog.shared.write("update_check source=manual result=started version=\(versionText)")
        controller.checkForUpdates(nil)
    }

    private func applyAutomaticallyChecks(_ oldValue: Bool) {
        guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticChecks else { return }
        updater.automaticallyChecksForUpdates = automaticChecks
        updater.updateCheckInterval = 86_400
        PerfLog.shared.write("update_settings automatic_checks=\(automaticChecks ? 1 : 0)")
    }

    private func applyAutomaticallyDownloads(_ oldValue: Bool) {
        guard let updater = controller?.updater,
              updater.automaticallyDownloadsUpdates != automaticDownloads else { return }
        updater.automaticallyDownloadsUpdates = automaticDownloads
        PerfLog.shared.write("update_settings automatic_downloads=\(automaticDownloads ? 1 : 0)")
    }

    private static var isHookBuild: Bool {
        #if RABE_TEST_HOOKS
        true
        #else
        false
        #endif
    }

    nonisolated private func log(_ line: String) {
        PerfLog.shared.write(line)
    }
}

// MARK: - SPUUpdaterDelegate (Aufrufe kommen auf dem Main Thread)

extension Updater: SPUUpdaterDelegate {
    /// Der Feed des Testschalters überstimmt die Plist. Im Release bleibt das
    /// nil, dann liest Sparkle `SUFeedURL`.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { self.feedOverride }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let line = "update_check source=\(MainActor.assumeIsolated { self.pendingSource }) result=found version=\(item.displayVersionString) build=\(item.versionString)"
        log(line)
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        let line = "update_check source=\(MainActor.assumeIsolated { self.pendingSource }) result=current"
        log(line)
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let line = "update_check source=\(MainActor.assumeIsolated { self.pendingSource }) result=error error=\(error.localizedDescription)"
        log(line)
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let line = "update_check source=\(MainActor.assumeIsolated { self.pendingSource }) result=aborted error=\(error.localizedDescription)"
        log(line)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let source = MainActor.assumeIsolated { self.pendingSource }
        let line = "update_cycle source=\(source) result=\(error == nil ? "done" : "error")\(error.map { " error=\($0.localizedDescription)" } ?? "")"
        log(line)
        Task { @MainActor in
            self.pendingSource = "automatic"
            self.lastResult = error == nil ? "fertig" : error?.localizedDescription
        }
    }

    /// Nach einer Installation neu starten ist Sparkles Aufgabe; wir merken nur,
    /// dass es weitergeht.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        log("update_install version=\(item.displayVersionString) build=\(item.versionString)")
    }
}
