import Foundation

/// M2.18n: die `g`-Folge — eine Tabelle für Auswertung und Anzeige.
///
/// `G` allein tat bisher nichts Sichtbares: die App wartete stumm 1,2 s auf den
/// zweiten Buchstaben. Diese Tabelle ist die eine Quelle für beides — der
/// Dispatcher sucht die zweite Taste hier, und die Statuszeile zeigt daraus den
/// Hinweis „Gehe zu: I Posteingang · … · O Ordner/Label“.
public struct GoSequenceTarget: Identifiable, Equatable, Sendable {
    /// Die zweite Taste der Folge, klein geschrieben (`"#"`, `"!"` sind Zeichen).
    public let key: String
    /// Das Postfach; `nil` heißt: danach fragt die App nach Ordner oder Label.
    public let view: MailView?
    public let title: String

    public var id: String { key }

    public init(key: String, view: MailView?, title: String) {
        self.key = key
        self.view = view
        self.title = title
    }
}

public enum GoSequence {
    /// Reihenfolge = Reihenfolge im Hinweis.
    public static let targets: [GoSequenceTarget] = [
        GoSequenceTarget(key: "i", view: .inbox, title: "Posteingang"),
        GoSequenceTarget(key: "s", view: .starred, title: "Markiert"),
        GoSequenceTarget(key: "d", view: .drafts, title: "Entwürfe"),
        GoSequenceTarget(key: "t", view: .sent, title: "Gesendet"),
        GoSequenceTarget(key: "e", view: .done, title: "Erledigt"),
        GoSequenceTarget(key: "h", view: .snoozed, title: "Später"),
        GoSequenceTarget(key: "#", view: .trash, title: "Papierkorb"),
        GoSequenceTarget(key: "!", view: .spam, title: "Spam"),
        GoSequenceTarget(key: "a", view: .all, title: "Alle"),
        GoSequenceTarget(key: "o", view: nil, title: "Ordner/Label …"),
    ]

    /// Der Hinweis in der Statuszeile, während die Folge läuft.
    public static let headline = "Gehe zu:"

    /// So lange wartet die App auf die zweite Taste (M2.18n: 1,2 → 2 s, weil
    /// der Hinweis erst gelesen werden will).
    public static let window: TimeInterval = 2

    public static func target(for key: String) -> GoSequenceTarget? {
        let lower = key.lowercased()
        return targets.first { $0.key == lower }
    }
}
