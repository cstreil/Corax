import Foundation
import Observation

/// Sender pictures for the avatar rows (M2.4, requirement 1).
///
/// The core resolves a picture once per sender (`sender_avatar`: Gravatar, BIMI,
/// then the site icon) and caches it on disk for a week; it answers with a
/// `data:` URL. This store keeps the decoded bytes in memory for the session,
/// bounded by count **and** bytes so a mailbox with many senders cannot grow it
/// without limit. The list asks for every visible row while it draws; the first
/// request starts the lookup, later ones read the cache, and a scroll therefore
/// costs no more than it did before.
@MainActor
@Observable
public final class AvatarPhotos {
    public enum Entry: Equatable {
        case loading
        case photo(Data)
        /// Asked and answered with no picture (the core caches misses too).
        case none
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Bumped whenever an entry changed, so the list can repaint its rows.
    public private(set) var revision = 0
    /// How many pictures are kept; the least recently shown is dropped first.
    public let capacity: Int
    /// Byte budget for all decoded pictures together.
    public let byteBudget: Int
    public private(set) var bytes = 0
    /// Set from the "Absenderfotos" setting; when off nothing is looked up.
    public var enabled: Bool {
        didSet { if !enabled { entries = [:]; order = []; bytes = 0; revision += 1 } }
    }

    /// Called after an entry changed, so a view that draws outside SwiftUI
    /// (the list table) can repaint its visible rows.
    public var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let resolve: @Sendable (String) async -> String?

    public init(capacity: Int = 200, byteBudget: Int = 24 * 1024 * 1024,
                enabled: Bool = true,
                resolve: @escaping @Sendable (String) async -> String?) {
        self.capacity = max(1, capacity)
        self.byteBudget = max(1, byteBudget)
        self.enabled = enabled
        self.resolve = resolve
    }

    /// The picture for a sender, if it is already known. A pure read: the LRU
    /// order follows `request(_:)`, which is called while a row draws, so no
    /// state changes during a `body` evaluation.
    public func photo(for email: String) -> Data? {
        guard case .photo(let data)? = entries[Self.key(email)] else { return nil }
        return data
    }

    /// The state of one sender, for the list and for tests.
    public func entry(for email: String) -> Entry? { entries[Self.key(email)] }

    /// Asks for a picture the first time a row draws the sender. A miss is
    /// remembered, so the core is asked once per address per session.
    public func request(_ email: String) {
        guard enabled else { return }
        let key = Self.key(email)
        guard !key.isEmpty, entries[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        entries[key] = .loading
        Task { [weak self] in
            let url = await self?.resolve(email) ?? nil
            guard let self else { return }
            self.inFlight.remove(key)
            if let url, let data = Self.decodeDataURL(url), !data.isEmpty {
                self.entries[key] = .photo(data)
                self.bytes += data.count
                self.touch(key)
                self.evictIfNeeded()
            } else {
                // `Entry.none` explicitly: `dict[key] = .none` would remove the
                // key, and a remembered miss would be asked again.
                self.entries[key] = Entry.none
                self.touch(key)
            }
            self.revision &+= 1
            self.onChange?()
        }
    }

    /// Tests: waits until all lookups have answered.
    public func waitUntilIdle() async {
        while !inFlight.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// `data:image/png;base64,…` → bytes. The core always sends base64; a
    /// malformed or non-data URL is treated as "no picture".
    public static func decodeDataURL(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("data:"),
              let comma = trimmed.firstIndex(of: ",") else { return nil }
        let header = trimmed[trimmed.startIndex..<comma].lowercased()
        guard header.contains(";base64") else { return nil }
        return Data(base64Encoded: String(trimmed[trimmed.index(after: comma)...]), options: [.ignoreUnknownCharacters])
    }

    public static func key(_ email: String) -> String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity || bytes > byteBudget {
            guard let oldest = order.first else { break }
            order.removeFirst()
            if case .photo(let data)? = entries[oldest] { bytes -= data.count }
            entries[oldest] = nil
        }
    }
}
