import AppKit
import Darwin
import CoraxKit

/// M3.1: nur nachsehen, welche anderen Apps laufen — nichts davon anfassen.
enum ApplicationChecks {
    /// Läuft eine App mit dieser Kennung?
    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
            .isEmpty
    }

    /// Läuft die Tauri-App (`de.streil.rabe`)? Sie gleicht dieselben Konten ab;
    /// wir warnen nur und lesen ihre Kennung.
    static var tauriRunning: Bool { isRunning(bundleID: AppIdentity.tauriID) }

    /// Hält eine andere Instanz diesen Datenordner? Der Host nimmt beim Start
    /// ein `flock` auf `<ordner>/instance.lock`; ein Test darauf sagt es
    /// unabhängig von Bundle-Kennungen (die Sandbox hieß früher wie die echte
    /// Instanz). Nur prüfen, nichts anfassen.
    static func isDataDirectoryLocked(_ directory: URL) -> Bool {
        let path = directory.appendingPathComponent("instance.lock").path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
