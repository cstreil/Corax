import Foundation

/// Which instance the app talks to.
///
/// `RABE_IDENTIFIER` selects it. The sandbox is a seeded mockup mailbox on
/// `*.invalid` hosts: archiving, sending and snoozing work locally there and
/// never reach a server. Anything but the two known identifiers is refused
/// instead of silently falling back to the real mailbox.
public enum Instance {
    /// M3.1: Name und Kennungen stehen in `AppIdentity`.
    public static let native = AppIdentity.bundleID
    public static let sandbox = AppIdentity.sandboxID

    enum SelectionError: LocalizedError {
        case unknown(String)

        public var errorDescription: String? {
            switch self {
            case .unknown(let value):
                return "Ungültiger RABE_IDENTIFIER „\(value)“. Erlaubt sind \(Instance.native) und \(Instance.sandbox)."
            }
        }
    }

    public static func selected(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        switch environment["RABE_IDENTIFIER"] ?? "" {
        case "": return native
        case native: return native
        case sandbox: return sandbox
        case let other: throw SelectionError.unknown(other)
        }
    }

    public static var isSandbox: Bool {
        (try? selected()) == sandbox
    }

    /// Window title. The suffix keeps a working window from being mistaken for
    /// the real mailbox.
    public static var title: String { AppIdentity.windowTitle }

    /// Where the host keeps its database and logs, for the status line.
    static var dataDirectoryHint: String {
        isSandbox ? "Sandbox" : "Native"
    }
}
