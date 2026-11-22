import Foundation
import Observation

/// P2g: the visible write switch ("Postfach → Änderungen erlauben").
///
/// One gate for the whole app. `CoraxClient` asks it before every command and
/// `MailboxStore` before the automatic `mark_read`; the menu and the status
/// line show and change it. The state lives in the app's `UserDefaults` under
/// `writesAllowed.<identifier>` and defaults to off — the core never sees it
/// (`set_settings` is not involved).
///
/// The sandbox is the one exception: its gate is always on and cannot be
/// switched, because the walkthroughs write into the mock mailbox. The command
/// policy keys on the process identifier, not on this gate, so a sandbox stays
/// unrestricted even if the gate is presented as the real instance's.
@MainActor
@Observable
public final class WriteAccess {
    public enum Mode: Equatable {
        /// The real mailbox: the switch decides.
        case real
        /// The sandbox: always on, not switchable.
        case sandbox
    }

    /// Lazily built on first use, in `AppModel.init` (after `PerfLog` knows the
    /// log file, so the initial state is on record).
    public static let shared = WriteAccess(
        identifier: (try? Instance.selected()) ?? Instance.native,
        mode: Instance.isSandbox ? .sandbox : .real
    )

    public let identifier: String
    public private(set) var mode: Mode
    public private(set) var allowed: Bool
    @ObservationIgnored private let defaults: UserDefaults

    public var canToggle: Bool { mode == .real }
    /// Requirement 3/4: the status line shows "Nur lesen" only while the real
    /// instance may not write.
    public var showsReadOnlyHint: Bool { mode == .real && !allowed }

    var storeKey: String { Self.defaultsKey(for: identifier) }

    static func defaultsKey(for identifier: String) -> String { "writesAllowed.\(identifier)" }

    public init(identifier: String, mode: Mode, defaults: UserDefaults = .standard) {
        self.identifier = identifier
        self.mode = mode
        self.defaults = defaults
        allowed = mode == .real ? defaults.bool(forKey: Self.defaultsKey(for: identifier)) : true
        PerfLog.shared.write("writes_allowed_init=\(allowed) mode=\(mode == .real ? "real" : "sandbox")")
    }

    /// Switches the real instance and takes effect for the next command (the
    /// client and the stores read `allowed` right before sending).
    public func set(_ on: Bool) {
        guard canToggle, on != allowed else { return }
        allowed = on
        defaults.set(on, forKey: storeKey)
        PerfLog.shared.write("writes_allowed=\(on)")
    }

    public func toggle() { set(!allowed) }

    #if DEBUG || CORAX_TEST_HOOKS
    /// Hook builds only (`writegate:off|on`): shows the real instance's switch
    /// inside the sandbox for screenshots. The command policy still keys on the
    /// process identifier, so the sandbox keeps sending everything.
    public func debugPresentAsReal(readOnly: Bool) {
        mode = .real
        allowed = !readOnly
        PerfLog.shared.write("writegate_preview read_only=\(readOnly)")
    }
    #endif
}
