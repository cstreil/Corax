import Foundation

/// M2.11b: wann eine gemeldete Dokumenthöhe in die Karte darf.
///
/// Eine HTML-Mail, die geladen wird, während die Webansicht noch keine Breite
/// hat, bricht ein Zeichen pro Zeile um und meldet ein Vielfaches ihrer wahren
/// Höhe (gemessen: 141 Zeichen Text → 3852 pt statt 156 pt). Dieser Wert bleibt
/// hängen, weil WebKit ihn nicht von selbst korrigiert. Deshalb: erst laden,
/// wenn Breite da ist — und nur Messungen mit Breite übernehmen.
public enum HTMLHeightGate {
    /// Darf die Seite jetzt geladen werden? Vorher nicht.
    public static func readyToLoad(viewWidth: CGFloat) -> Bool {
        viewWidth > 0
    }

    /// Ist die gemeldete Höhe brauchbar? Nur, wenn die Seite auch mit dieser
    /// Breite gerechnet hat: während des Ladens war `innerWidth` 0, die Ansicht
    /// aber 3852 pt hoch gemeldet.
    public static func accepts(height: CGFloat, viewWidth: CGFloat, innerWidth: CGFloat) -> Bool {
        guard height >= 1, viewWidth > 0, innerWidth > 0 else { return false }
        return abs(innerWidth - viewWidth) <= 8
    }
}
