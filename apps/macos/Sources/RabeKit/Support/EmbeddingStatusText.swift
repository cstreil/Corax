import Foundation

/// M2.10: die Texte der Zeile „Semantischer Index" in den Einstellungen.
///
/// Vorher stand dort nur „Aktiv" — das heißt „eingeschaltet", nicht „das Modell
/// ist geladen". Der Kern liefert `ready` längst mit; hier werden die drei
/// Zustände und der Prozentwert daraus, damit die Einstellungen-Seite nur noch
/// zeichnen muss (und beides prüfbar ist).
public enum EmbeddingStatusText {
    /// „Aus", „Aktiv · Modell wird geladen" oder „Bereit".
    public static func title(enabled: Bool, ready: Bool) -> String {
        guard enabled else { return "Aus" }
        return ready ? "Bereit" : "Aktiv · Modell wird geladen"
    }

    /// Gerundeter Fortschritt in Prozent; bei `total == 0` null.
    public static func percent(embedded: Int64, total: Int64) -> Int {
        guard total > 0 else { return 0 }
        let value = Double(embedded) / Double(total) * 100
        return Int(value.rounded())
    }

    /// „11 034/11 071 eingebettet · 29 offen".
    public static func counts(embedded: Int64, total: Int64, pending: Int64) -> String {
        let base = "\(embedded)/\(total) eingebettet"
        return pending > 0 ? base + " · \(pending) offen" : base
    }
}
