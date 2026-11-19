import Foundation
@testable import RabeKit

/// `PlatformServices` for the tests: records what the stores ask for, and
/// answers the save panel with a fixed path (or "cancelled").
final class TestPlatform: PlatformServices, @unchecked Sendable {
    private(set) var opened: [URL] = []
    private(set) var copied: [String] = []
    var savePath: String?

    func open(_ url: URL) { opened.append(url) }
    func copyToClipboard(_ text: String) -> Bool { copied.append(text); return true }

    @MainActor
    func chooseSaveLocation(suggestedName: String) async -> String? { savePath }
}
