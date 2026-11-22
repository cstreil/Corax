import Foundation

/// M2.11: wie weit die Liste beim Aufklappen einer Mail scrollt.
///
/// Vorbild ist `anchor()` im Mockup: die aufgeklappte Mail soll so viel Platz
/// wie möglich bekommen, aber über ihr bleibt immer eine Zeile der Liste
/// stehen — sonst verliert man beim Lesen den Zusammenhang. Ist die Mail höher
/// als das Fenster, ergibt sich das von selbst: oben eine Zeile, der Rest der
/// Mail liegt unterhalb.
public enum ListReveal {
    /// - Parameters:
    ///   - rowTop: Oberkante der aufgeklappten Thread-Zeile (Dokument-y).
    ///   - aboveTop: Oberkante der Zeile darüber — beliebiger Typ, auch ein
    ///     Abschnittskopf. Gibt es keine, gilt `rowTop`.
    ///   - cardBottom: Unterkante der Detailzeile.
    ///   - belowH: Höhe der Zeile darunter; 0, wenn keine folgt.
    ///   - visibleMinY: Oberkante des sichtbaren Bereichs unter dem Inset.
    ///   - visibleHeight: Höhe dieses Bereichs.
    /// - Returns: das Dokument-y, das oben im sichtbaren Bereich stehen soll;
    ///   `nil`, wenn nicht gescrollt wird.
    public static func revealTop(rowTop: CGFloat, aboveTop: CGFloat, cardBottom: CGFloat,
                                 belowH: CGFloat, visibleMinY: CGFloat,
                                 visibleHeight: CGFloat) -> CGFloat? {
        guard visibleHeight > 0 else { return nil }
        // So weit, dass die Karte plus eine Zeile darunter am unteren Rand endet.
        let want = cardBottom + belowH - visibleHeight
        // Nicht unter die Oberkante und nie über die Zeile darüber hinaus.
        var top = min(max(visibleMinY, want), aboveTop)
        // Oben angeschnitten: die Zeile darüber ist das Höchste der Gefühle.
        if rowTop < visibleMinY { top = aboveTop }
        // Steht schon richtig (Rundung der Layoutwerte).
        if abs(top - visibleMinY) <= 1 { return nil }
        return top
    }
}
