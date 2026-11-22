import Foundation

/// Appends UI timings to the same log file the Rust host writes, so a run can
/// be read end to end (requirement A5: core start, dispatch durations, time to
/// first list). Format matches the host's tracing lines closely enough for
/// `grep` and `sort`.
public final class PerfLog: @unchecked Sendable {
    public static let shared = PerfLog()

    /// Set once the host reports its data directory.
    private var path: String?
    private let lock = NSLock()
    private(set) var startedAt = Date()

    private init() {}

    public func markStartNow() {
        lock.lock()
        startedAt = Date()
        lock.unlock()
    }

    /// Point at the identifier's usual log before the host has reported its
    /// own directory, so launch-time lines (window shown, first paint) are not
    /// lost to stderr when the app is opened from Finder.
    public func configureDefault(identifier: String = AppIdentity.bundleID) {
        guard
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else { return }
        configure(dataDirectory: base.appendingPathComponent(identifier).path)
    }

    public func configure(dataDirectory: String) {
        lock.lock()
        path = (dataDirectory as NSString).appendingPathComponent("logs/corax.log")
        lock.unlock()
    }

    /// Milliseconds since `start()` began.
    public var elapsedMilliseconds: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(Date().timeIntervalSince(startedAt) * 1000)
    }

    public func write(_ message: String) {
        let stamp = ISO8601DateFormatter.coraxTimestamp()
        let line = "\(stamp)  INFO ui \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))

        lock.lock()
        let target = path
        lock.unlock()
        guard let target else { return }

        let url = URL(fileURLWithPath: target)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let handle = try? FileHandle(forWritingTo: url) else {
            // First write in this process: create the file.
            try? Data(line.utf8).write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

extension ISO8601DateFormatter {
    static func coraxTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
