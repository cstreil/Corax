import Foundation

/// Which language the AI is told to answer in.
///
/// The core only understands concrete codes (`ai::ui_language_name`); "system"
/// means "no instruction", so the model picks whatever language the mail is in.
/// The live test showed exactly that: German UI, English summary. The app
/// therefore stores the resolved code and remembers, separately, that the value
/// follows the OS language.
public enum AILanguage {
    /// The codes `ai::ui_language_name` knows. Kept in step with the core (and
    /// with the locale folders under `src/i18n/locales`); `AILanguageTests` in
    /// the core pins the Rust side.
    public static let known: Set<String> = ["de", "en", "es", "fr", "zh", "vi"]

    /// The persisted value that means "follow the OS".
    public static let system = "system"

    /// The setting to persist for `choice`.
    ///
    /// `"system"` becomes the base code of the first preferred language the core
    /// knows — `["de-DE", "en-US"]` → `"de"` — and stays `"system"` when that
    /// language has no name in the core (e.g. Japanese: better no instruction
    /// than a wrong one).
    public static func stored(_ choice: String, preferred: [String]) -> String {
        guard choice == system else { return choice }
        guard let base = baseCode(of: preferred.first), known.contains(base) else { return system }
        return base
    }

    /// `"de-DE"` → `"de"`, `"zh-Hans-CN"` → `"zh"`.
    public static func baseCode(of tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        let base = tag.split(separator: "-").first.map(String.init) ?? tag
        let trimmed = base.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The OS languages in the app's own order, as stored by macOS.
    public static func preferredLanguages() -> [String] {
        Locale.preferredLanguages
    }
}
