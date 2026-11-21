import Foundation

/// M3.3: die Texte der Intents als reine Funktionen — ohne AppIntents, ohne
/// App, damit sie in Tests ohne Siri prüfbar sind.
public enum IntentText {
    /// „482913" → „4 8 2 9 1 3". Siri liest eine zusammenhängende Zahl als
    /// eine Größe vor; mit Abstand liest sie die Ziffern einzeln.
    public static func spokenDigits(_ code: String) -> String {
        code.filter(\.isNumber).map(String.init).joined(separator: " ")
    }

    /// Entfernt Quellenmarker wie `[1]` oder `[1, 2]` und räumt die Lücken auf.
    /// „a [1] b [2, 3]." → „a b."
    public static func stripCitations(_ text: String) -> String {
        var out = ""
        var depth = 0
        for character in text {
            if character == "[" {
                depth += 1
                continue
            }
            if depth > 0 {
                if character == "]" { depth -= 1 }
                continue
            }
            out.append(character)
        }
        // Satzzeichen hängen nach dem Entfernen nicht mehr an einem Wort.
        out = out.replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: "  ", with: " ")
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    /// „Code von ‹Absender›: 4 8 2 9 1 3", bei Kopie zusätzlich „kopiert".
    public static func codeLine(sender: String, digits: String, copied: Bool) -> String {
        let who = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = who.isEmpty ? "Code:" : "Code von \(who):"
        return copied ? "\(prefix) \(digits) – kopiert" : "\(prefix) \(digits)"
    }

    public static func noCodeLine(minutes: Int) -> String {
        "Kein Bestätigungscode in den letzten \(minutes) Minuten."
    }

    /// „Du hast 3 ungelesene Mails im Posteingang." mit Singular und Null-Fall.
    public static func unreadLine(_ count: Int) -> String {
        switch count {
        case 0: return "Der Posteingang ist leer."
        case 1: return "Du hast 1 ungelesene Mail im Posteingang."
        default: return "Du hast \(count) ungelesene Mails im Posteingang."
        }
    }

    /// Höchstens sechs Zeilen „‹Absender›: ‹Betreff›" mit Kopfzeile.
    /// `threads` sind die ungelesenen, `total` die Gesamtzahl der Ungelesenen.
    public static func overview(_ threads: [(sender: String, subject: String)], total: Int) -> String {
        guard total > 0, !threads.isEmpty else { return "Alles gelesen." }
        var lines = ["\(total) ungelesene \(total == 1 ? "Mail" : "Mails") im Posteingang:"]
        for thread in threads.prefix(6) {
            let who = thread.sender.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = thread.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (who.isEmpty, subject.isEmpty) {
            case (true, true): lines.append("(ohne Absender)")
            case (true, false): lines.append(subject)
            case (false, true): lines.append(who)
            case (false, false): lines.append("\(who): \(subject)")
            }
        }
        let shown = min(threads.count, 6)
        if total > shown {
            lines.append("… und \(total - shown) weitere.")
        }
        return lines.joined(separator: "\n")
    }

    /// Absenderzeile eines Threads: Name, sonst Adresse.
    public static func sender(of name: String?, email: String) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? email : trimmed
    }
}
