//! Formatmodell des Verfassen-Editors.
//!
//! Ein Dokument ist reiner Text plus Spannen (Byte-Bereiche in UTF-8) mit Fett
//! und Kursiv. Diese Spannen sind die einzige Wahrheit: das Eingabefeld zeigt
//! sie über `InputState::set_span_styles`, der Versand liest sie in
//! [`EditorDoc::to_html`] — zwei Verbraucher, ein Modell.
//!
//! Beim Bearbeiten müssen die Spannen mitwandern. Das Eingabefeld meldet nur
//! „Text hat sich geändert", deshalb rechnet [`EditorDoc::set_text`] den
//! Unterschied selbst aus: gemeinsamer Anfang und gemeinsames Ende bilden den
//! ersetzten Bereich, alles davor bleibt stehen, alles dahinter verschiebt sich.
//!
//! Regeln an den Rändern (so wie in Mail und Word):
//!
//! * Tippen **innerhalb** einer Spanne dehnt sie.
//! * Tippen **am Anfang** einer Spanne schiebt sie nach hinten — der neue Text
//!   ist nicht fett.
//! * Tippen **am Ende** einer Spanne führt sie weiter — der neue Text ist auch
//!   fett, die Spanne wächst mit.
//! * Löschen innerhalb einer Spanne kürzt sie; fällt sie ganz weg, verschwindet
//!   der Eintrag.
//! * Ein **Vorformat** (`Strg+B`/`Strg+I` ohne Auswahl) gilt für den nächsten
//!   eingefügten Text und überschreibt, was vom Nachbarn käme — damit lässt
//!   sich Fett am Ende einer fetten Stelle auch wieder abschalten.

use std::ops::Range;

/// Auszeichnungen eines Bereichs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Format {
    pub bold: bool,
    pub italic: bool,
}

// Teile des Modells ruft erst die Formatleiste und der Versand auf (L2);
// bis dahin sind sie nur über die Tests benutzt.
#[allow(dead_code)]
impl Format {
    /// Keine Auszeichnung.
    pub const NONE: Self = Self { bold: false, italic: false };
    /// Nur fett.
    pub const BOLD: Self = Self { bold: true, italic: false };
    /// Nur kursiv.
    pub const ITALIC: Self = Self { bold: false, italic: true };
    /// Fett und kursiv.
    pub const BOLD_ITALIC: Self = Self { bold: true, italic: true };

    pub fn is_empty(self) -> bool {
        !self.bold && !self.italic
    }

    /// Vereinigung beider Auszeichnungen.
    pub fn union(self, other: Self) -> Self {
        Self {
            bold: self.bold || other.bold,
            italic: self.italic || other.italic,
        }
    }

    /// `self` ohne die Auszeichnungen von `other`.
    pub fn without(self, other: Self) -> Self {
        Self {
            bold: self.bold && !other.bold,
            italic: self.italic && !other.italic,
        }
    }

    /// Enthält `self` alle Auszeichnungen von `other`?
    pub fn contains(self, other: Self) -> bool {
        (self.bold || !other.bold) && (self.italic || !other.italic)
    }
}

/// Ein formatierter Bereich im Text (Byte-Bereich, UTF-8).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Span {
    pub range: Range<usize>,
    pub format: Format,
}

impl Span {
    pub fn new(range: Range<usize>, format: Format) -> Self {
        Self { range, format }
    }
}

/// Was [`EditorDoc::set_text_mit`] an einem Text getan hat.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Aenderung {
    Nichts,
    /// Reine Einfügung an `start`; der eingefügte Text reicht bis `ende`.
    Eingefuegt { start: usize, ende: usize },
    /// Ersetzt oder gelöscht.
    Ersetzt,
}

/// Text und Formatierung eines Entwurfs.
///
/// Invariante: `spans` ist nach Start sortiert, die Bereiche überlappen sich
/// nicht und sind nie leer. Alle Methoden halten das ein.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EditorDoc {
    pub text: String,
    pub spans: Vec<Span>,
}

#[allow(dead_code)]
impl EditorDoc {
    pub fn new() -> Self {
        Self::default()
    }

    /// Dokument aus Klartext, ohne Auszeichnung (Antwort, Entwurf, Zitat).
    pub fn from_plain(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            spans: Vec::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.text.is_empty()
    }

    /// Übernimmt neuen Text und zieht die Spannen mit.
    ///
    /// Wird bei jedem `Change`-Ereignis des Eingabefelds aufgerufen — Tippen,
    /// Löschen, Einfügen, IME und Undo laufen alle hier durch.
    pub fn set_text(&mut self, neu: &str) -> Aenderung {
        self.set_text_mit(neu, None)
    }

    /// Wie [`EditorDoc::set_text`], aber mit einem Vorformat für den
    /// eingefügten Text (`Strg+B`/`Strg+I` ohne Auswahl).
    ///
    /// Ist `vorformat` gesetzt, bekommt der eingefügte Text genau diese
    /// Auszeichnung — auch gegen das, was links davon steht. So lässt sich Fett
    /// am Ende einer fetten Stelle wieder abschalten.
    pub fn set_text_mit(&mut self, neu: &str, vorformat: Option<Format>) -> Aenderung {
        if self.text == neu {
            return Aenderung::Nichts;
        }
        let alt = std::mem::replace(&mut self.text, neu.to_string());
        let anfang = gemeinsamer_anfang(&alt, neu);
        let ende = gemeinsames_ende(&alt, neu, anfang);
        // Ersetzter alter Bereich ist `anfang..alt_ende`, der neue Text reicht
        // bis `neu_ende` (beides absolute Byte-Positionen).
        let alt_ende = alt.len() - ende;
        let neu_ende = neu.len() - ende;

        let aenderung = if alt_ende == anfang {
            // Reine Einfügung: `neu_ende - anfang` Bytes an `anfang`.
            self.einfuegen(anfang, neu_ende - anfang, vorformat);
            Aenderung::Eingefuegt {
                start: anfang,
                ende: neu_ende,
            }
        } else {
            self.spans = self
                .spans
                .drain(..)
                .filter_map(|span| verschiebe(span, anfang, alt_ende, neu_ende))
                .collect();
            Aenderung::Ersetzt
        };
        self.normalisieren();
        aenderung
    }

    /// Zieht die Spannen über eine reine Einfügung an `pos` mit `len` Bytes.
    ///
    /// Der eingefügte Text bekommt `vorformat`; ohne Vorformat das Format, das
    /// an dieser Stelle gelten würde: innerhalb und **am Ende** einer Spanne
    /// deren Format, am Anfang keines.
    fn einfuegen(&mut self, pos: usize, len: usize, vorformat: Option<Format>) {
        let format = vorformat.unwrap_or_else(|| self.ererbte_format(pos));
        let mut neu = Vec::with_capacity(self.spans.len() + 1);
        for span in std::mem::take(&mut self.spans) {
            let (start, ende) = (span.range.start, span.range.end);
            if ende <= pos {
                neu.push(span);
            } else if start >= pos {
                neu.push(Span::new(start + len..ende + len, span.format));
            } else {
                // `pos` liegt echt in der Spanne: links stehen lassen, rechts
                // schieben. Der eingefügte Text dazwischen bekommt sein eigenes
                // Format (bei gleichem Format fasst `normalisieren` alles
                // wieder zusammen).
                neu.push(Span::new(start..pos, span.format));
                neu.push(Span::new(pos + len..ende + len, span.format));
            }
        }
        if !format.is_empty() {
            neu.push(Span::new(pos..pos + len, format));
        }
        self.spans = neu;
    }

    /// Format, das ein an `pos` eingefügtes Zeichen erbte, wenn der Cursor
    /// dort steht: innerhalb einer Spanne und an ihrem Ende deren Format, am
    /// Anfang keines.
    pub fn ererbte_format(&self, pos: usize) -> Format {
        if let Some(span) = self
            .spans
            .iter()
            .find(|span| span.range.start < pos && pos < span.range.end)
        {
            return span.format;
        }
        self.spans
            .iter()
            .find(|span| span.range.end == pos)
            .map(|span| span.format)
            .unwrap_or_default()
    }

    /// Ersetzt einen Bereich — der bequeme Weg für Tests und Einfügen.
    pub fn replace_range(&mut self, range: Range<usize>, neu: &str) {
        let mut text = String::with_capacity(self.text.len() + neu.len());
        text.push_str(&self.text[..range.start]);
        text.push_str(neu);
        text.push_str(&self.text[range.end..]);
        self.set_text(&text);
    }

    /// Format an einer Byte-Position (für Formatleiste und Export).
    pub fn format_at(&self, pos: usize) -> Format {
        self.spans
            .iter()
            .find(|span| span.range.start <= pos && pos < span.range.end)
            .map(|span| span.format)
            .unwrap_or_default()
    }

    /// Hat jeder Byte im Bereich die Auszeichnung `format`?
    pub fn has_format(&self, range: Range<usize>, format: Format) -> bool {
        if range.start >= range.end || range.end > self.text.len() {
            return false;
        }
        let mut pos = range.start;
        while pos < range.end {
            let Some(span) = self
                .spans
                .iter()
                .find(|span| span.range.start <= pos && pos < span.range.end)
            else {
                return false;
            };
            if !span.format.contains(format) {
                return false;
            }
            pos = span.range.end.min(range.end);
        }
        true
    }

    /// Setzt eine Auszeichnung auf einen Bereich; vorhandene bleiben erhalten.
    pub fn set_format(&mut self, range: Range<usize>, format: Format) {
        if range.start >= range.end || range.end > self.text.len() || format.is_empty() {
            return;
        }
        self.split_at(range.start);
        self.split_at(range.end);

        let mut neu = Vec::with_capacity(self.spans.len() + 1);
        let mut pos = range.start;
        for span in std::mem::take(&mut self.spans) {
            if span.range.end <= range.start || span.range.start >= range.end {
                neu.push(span);
                continue;
            }
            // Lücke zwischen dem letzten Stück und dieser Spanne füllen.
            if pos < span.range.start {
                neu.push(Span::new(pos..span.range.start, format));
            }
            neu.push(Span::new(
                span.range.clone(),
                span.format.union(format),
            ));
            pos = span.range.end;
        }
        if pos < range.end {
            neu.push(Span::new(pos..range.end, format));
        }
        self.spans = neu;
        self.normalisieren();
    }

    /// Entfernt eine Auszeichnung aus einem Bereich; andere bleiben erhalten.
    pub fn clear_format(&mut self, range: Range<usize>, format: Format) {
        if range.start >= range.end || range.end > self.text.len() {
            return;
        }
        self.split_at(range.start);
        self.split_at(range.end);

        let mut neu = Vec::with_capacity(self.spans.len());
        for span in std::mem::take(&mut self.spans) {
            if span.range.end <= range.start || span.range.start >= range.end {
                neu.push(span);
                continue;
            }
            let rest = span.format.without(format);
            if !rest.is_empty() {
                neu.push(Span::new(span.range, rest));
            }
        }
        self.spans = neu;
        self.normalisieren();
    }

    /// Schaltet eine Auszeichnung für den Bereich um (Fett-Knopf, Strg+B).
    ///
    /// Ist der ganze Bereich schon so ausgezeichnet, wird sie entfernt — sonst
    /// gesetzt. So verhält sich die Formatleiste auf dem Mac.
    pub fn toggle_format(&mut self, range: Range<usize>, format: Format) {
        if self.has_format(range.clone(), format) {
            self.clear_format(range, format);
        } else {
            self.set_format(range, format);
        }
    }

    /// Klartext ohne Auszeichnung (für `text/plain`-Teil und Vorschau).
    pub fn to_plain(&self) -> String {
        self.text.clone()
    }

    /// HTML des Körpers: eine Zeile je `<div>`, Fett als `<b>`, Kursiv als `<i>`.
    ///
    /// Leere Zeilen werden zu `<div><br></div>`; Text wird maskiert.
    pub fn to_html(&self) -> String {
        let mut html = String::with_capacity(self.text.len() + 32);
        let mut zeilen_anfang = 0usize;
        for (nummer, zeile) in self.text.split('\n').enumerate() {
            if nummer > 0 {
                html.push('\n');
            }
            let zeilen_ende = zeilen_anfang + zeile.len();
            html.push_str("<div>");
            if zeile.is_empty() {
                html.push_str("<br>");
            }
            let mut pos = zeilen_anfang;
            while pos < zeilen_ende {
                let format = self.format_at(pos);
                let naechste = self
                    .spans
                    .iter()
                    .flat_map(|span| [span.range.start, span.range.end])
                    .filter(|&grenze| grenze > pos && grenze < zeilen_ende)
                    .min()
                    .unwrap_or(zeilen_ende);
                schreibe_stueck(&mut html, &self.text[pos..naechste], format);
                pos = naechste;
            }
            html.push_str("</div>");
            zeilen_anfang = zeilen_ende + 1;
        }
        html
    }

    /// Teilt Spannen an einer Position, damit Grenzen danach exakt liegen.
    fn split_at(&mut self, pos: usize) {
        let mut neu = Vec::with_capacity(self.spans.len() + 1);
        for span in std::mem::take(&mut self.spans) {
            if span.range.start < pos && pos < span.range.end {
                neu.push(Span::new(span.range.start..pos, span.format));
                neu.push(Span::new(pos..span.range.end, span.format));
            } else {
                neu.push(span);
            }
        }
        self.spans = neu;
        // Nur sortieren: Zusammenfassen würde die gerade gesetzte Grenze
        // sofort wieder auflösen (gleiche Formate links und rechts von `pos`).
        self.sortieren();
    }

    fn sortieren(&mut self) {
        self.spans
            .sort_by_key(|span| (span.range.start, span.range.end));
    }

    /// Sortiert, wirft leere Spannen weg, fasst gleiche Nachbarn zusammen.
    fn normalisieren(&mut self) {
        self.spans.retain(|span| span.range.start < span.range.end);
        self.sortieren();

        let mut zusammen: Vec<Span> = Vec::with_capacity(self.spans.len());
        for span in std::mem::take(&mut self.spans) {
            if let Some(letzte) = zusammen.last_mut()
                && letzte.format == span.format
                && letzte.range.end >= span.range.start
            {
                letzte.range.end = letzte.range.end.max(span.range.end);
                continue;
            }
            zusammen.push(span);
        }
        self.spans = zusammen;
    }
}

/// Ein gemerkter Stand: Text und Auszeichnung zu einem Zeitpunkt.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Stand {
    text: String,
    spans: Vec<Span>,
}

/// Undo/Redo für die Formatierung.
///
/// Hier liegen nur Spannen und der Text, den das Feld beim Auslösen hatte. Den
/// Textverlauf führt das Eingabefeld selbst; deshalb wird ein Stand nur
/// wiederhergestellt, solange der Text noch derselbe ist. Hat sich der Text
/// geändert, gehört der Schritt dem Feld, und [`EditorDoc`] zieht die Spannen
/// beim Tippen ohnehin mechanisch mit.
///
/// `Strg+B`/`Strg+I` legen vor jeder Änderung einen Stand ab — auch wenn nur
/// das Vorformat wechselt; dort bleiben die Spannen gleich, und das Zurücknehmen
/// nimmt das Vorformat weg.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Verlauf {
    zurueckgenommene: Vec<Stand>,
    wiederholbare: Vec<Stand>,
}

impl Verlauf {
    /// Höchstens so viele Stände; ältere fallen weg.
    const MAX: usize = 100;

    pub fn new() -> Self {
        Self::default()
    }

    /// Vor einer Formatänderung aufrufen. Leert den Redo-Stapel, denn ein neuer
    /// Schritt macht den alten Weg zurück ungültig.
    pub fn merken(&mut self, doc: &EditorDoc) {
        if self.zurueckgenommene.len() >= Self::MAX {
            self.zurueckgenommene.remove(0);
        }
        self.zurueckgenommene.push(Stand {
            text: doc.text.clone(),
            spans: doc.spans.clone(),
        });
        self.wiederholbare.clear();
    }

    /// Nimmt die letzte Formatänderung zurück, wenn der Text noch passt.
    /// `true`, wenn etwas zurückgenommen wurde.
    pub fn zuruecknehmen(&mut self, doc: &mut EditorDoc) -> bool {
        let Some(stand) = self.zurueckgenommene.last() else {
            return false;
        };
        if stand.text != doc.text {
            return false;
        }
        let stand = self.zurueckgenommene.pop().expect("gerade gelesen");
        self.wiederholbare.push(Stand {
            text: doc.text.clone(),
            spans: doc.spans.clone(),
        });
        doc.spans = stand.spans;
        true
    }

    /// Stellt eine zurückgenommene Formatänderung wieder her.
    pub fn wiederholen(&mut self, doc: &mut EditorDoc) -> bool {
        let Some(stand) = self.wiederholbare.last() else {
            return false;
        };
        if stand.text != doc.text {
            return false;
        }
        let stand = self.wiederholbare.pop().expect("gerade gelesen");
        self.zurueckgenommene.push(Stand {
            text: doc.text.clone(),
            spans: doc.spans.clone(),
        });
        doc.spans = stand.spans;
        true
    }

    /// Der Text hat sich geändert: Zurückgenommene Stände passen nicht mehr.
    pub fn verwerfen(&mut self) {
        self.wiederholbare.clear();
    }

    /// Nur für Tests und Anzeige: Anzahl der Stände (zurück, vor).
    #[cfg(test)]
    fn laenge(&self) -> (usize, usize) {
        (self.zurueckgenommene.len(), self.wiederholbare.len())
    }
}

/// Länge des gemeinsamen Anfangs zweier Texte, auf Zeichengrenzen gerundet.
fn gemeinsamer_anfang(alt: &str, neu: &str) -> usize {
    let (a, b) = (alt.as_bytes(), neu.as_bytes());
    let grenze = a.len().min(b.len());
    let mut i = 0usize;
    while i < grenze && a[i] == b[i] {
        i += 1;
    }
    while i > 0 && (!alt.is_char_boundary(i) || !neu.is_char_boundary(i)) {
        i -= 1;
    }
    i
}

/// Länge des gemeinsamen Endes; überschneidet sich nie mit dem Anfang.
fn gemeinsames_ende(alt: &str, neu: &str, anfang: usize) -> usize {
    let (a, b) = (alt.as_bytes(), neu.as_bytes());
    let grenze = (a.len() - anfang).min(b.len() - anfang);
    let mut i = 0usize;
    while i < grenze && a[a.len() - 1 - i] == b[b.len() - 1 - i] {
        i += 1;
    }
    while i > 0 && (!alt.is_char_boundary(alt.len() - i) || !neu.is_char_boundary(neu.len() - i)) {
        i -= 1;
    }
    i
}

/// Zieht eine Spanne über eine Ersetzung `a..b` → `a..neu_ende` mit.
///
/// `None`, wenn die Spanne dabei leer würde (der Text ist dort gelöscht).
fn verschiebe(span: Span, a: usize, b: usize, neu_ende: usize) -> Option<Span> {
    let (start, ende) = (span.range.start, span.range.end);
    let delta = neu_ende as isize - b as isize;

    let (neu_start, neu_ende_spanne) = if ende <= a {
        // liegt vollständig davor
        (start, ende)
    } else if start >= b {
        // liegt vollständig dahinter
        (
            (start as isize + delta) as usize,
            (ende as isize + delta) as usize,
        )
    } else {
        // überschneidet die Ersetzung
        let neuer_start = if start < a { start } else { a };
        let neues_ende = if ende > b {
            (ende as isize + delta) as usize
        } else {
            neu_ende
        };
        (neuer_start, neues_ende)
    };

    (neu_start < neu_ende_spanne).then(|| Span::new(neu_start..neu_ende_spanne, span.format))
}

fn schreibe_stueck(html: &mut String, stueck: &str, format: Format) {
    let mut stueck = maskiere(stueck);
    if format.bold {
        stueck = format!("<b>{stueck}</b>");
    }
    if format.italic {
        stueck = format!("<i>{stueck}</i>");
    }
    html.push_str(&stueck);
}

fn maskiere(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for zeichen in text.chars() {
        match zeichen {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            anderes => out.push(anderes),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc_mit_spanne() -> EditorDoc {
        // "hallo welt", "welt" ist fett.
        let mut doc = EditorDoc::from_plain("hallo welt");
        doc.spans = vec![Span::new(6..10, Format::BOLD)];
        doc
    }

    #[test]
    fn tippen_am_anfang_schiebt_die_spanne() {
        let mut doc = doc_mit_spanne();
        doc.replace_range(0..0, "xx ");
        assert_eq!(doc.text, "xx hallo welt");
        assert_eq!(doc.spans, vec![Span::new(9..13, Format::BOLD)]);
        assert_eq!(doc.format_at(8), Format::NONE, "das neue Zeichen ist nicht fett");
        assert_eq!(doc.format_at(9), Format::BOLD);
    }

    #[test]
    fn tippen_innen_dehnt_die_spanne() {
        let mut doc = doc_mit_spanne();
        doc.replace_range(8..8, "AB");
        assert_eq!(doc.text, "hallo weABlt");
        assert_eq!(doc.spans, vec![Span::new(6..12, Format::BOLD)]);
    }

    #[test]
    fn tippen_am_ende_fuehrt_das_format_weiter() {
        let mut doc = doc_mit_spanne();
        doc.replace_range(10..10, "!");
        assert_eq!(doc.text, "hallo welt!");
        assert_eq!(doc.spans, vec![Span::new(6..11, Format::BOLD)]);
        assert_eq!(doc.format_at(10), Format::BOLD, "der neue Text ist auch fett");

        // Und immer so weiter: der Cursor steht am Ende der gewachsenen Spanne.
        doc.replace_range(11..11, "?");
        assert_eq!(doc.spans, vec![Span::new(6..12, Format::BOLD)]);
    }

    #[test]
    fn tippen_am_anfang_bleibt_ohne_format() {
        let mut doc = doc_mit_spanne();
        doc.replace_range(6..6, "X");
        assert_eq!(doc.text, "hallo Xwelt");
        assert_eq!(doc.spans, vec![Span::new(7..11, Format::BOLD)]);
        assert_eq!(doc.format_at(6), Format::NONE);
    }

    #[test]
    fn vorformat_gilt_fuer_den_naechsten_text() {
        let mut doc = EditorDoc::from_plain("hallo");
        let aenderung = doc.set_text_mit("hallo!", Some(Format::BOLD));
        assert_eq!(aenderung, Aenderung::Eingefuegt { start: 5, ende: 6 });
        assert_eq!(doc.spans, vec![Span::new(5..6, Format::BOLD)]);
        assert_eq!(doc.format_at(5), Format::BOLD);
    }

    #[test]
    fn vorformat_schaltet_fett_am_spanende_wieder_ab() {
        let mut doc = doc_mit_spanne();
        // Cursor am Ende der fetten Spanne, Strg+B schaltet Fett aus.
        doc.set_text_mit("hallo welt!", Some(Format::NONE));
        assert_eq!(doc.spans, vec![Span::new(6..10, Format::BOLD)]);
        assert_eq!(doc.format_at(10), Format::NONE);
    }

    #[test]
    fn vorformat_innen_teilt_die_spanne() {
        let mut doc = doc_mit_spanne();
        doc.set_text_mit("hallo weXlt", Some(Format::NONE));
        assert_eq!(
            doc.spans,
            vec![Span::new(6..8, Format::BOLD), Span::new(9..11, Format::BOLD)]
        );
        assert_eq!(doc.format_at(8), Format::NONE);
    }

    #[test]
    fn vorformat_kursiv_im_fetten_bereich() {
        let mut doc = doc_mit_spanne();
        doc.set_text_mit("hallo weXlt", Some(Format::ITALIC));
        assert_eq!(
            doc.spans,
            vec![
                Span::new(6..8, Format::BOLD),
                Span::new(8..9, Format::ITALIC),
                Span::new(9..11, Format::BOLD),
            ]
        );
    }

    #[test]
    fn format_at_cursor_kennt_das_spanende() {
        let doc = doc_mit_spanne();
        assert_eq!(doc.ererbte_format(8), Format::BOLD, "innen");
        assert_eq!(doc.ererbte_format(10), Format::BOLD, "Ende führt weiter");
        assert_eq!(doc.ererbte_format(6), Format::NONE, "Anfang nicht");
        assert_eq!(doc.ererbte_format(9), Format::BOLD);
        assert_eq!(doc.ererbte_format(0), Format::NONE);
    }

    #[test]
    fn set_text_meldet_die_art_der_aenderung() {
        let mut doc = EditorDoc::from_plain("abc");
        assert_eq!(doc.set_text("abc"), Aenderung::Nichts);
        assert_eq!(doc.set_text("abcd"), Aenderung::Eingefuegt { start: 3, ende: 4 });
        assert_eq!(
            doc.set_text("abd"),
            Aenderung::Ersetzt,
            "Löschen am Ende ist keine Einfügung"
        );
    }

    #[test]
    fn loeschen_innen_kuerzt_die_spanne() {
        let mut doc = doc_mit_spanne();
        // "we" löschen → "l"
        doc.replace_range(6..8, "");
        assert_eq!(doc.text, "hallo lt");
        assert_eq!(doc.spans, vec![Span::new(6..8, Format::BOLD)]);
    }

    #[test]
    fn loeschen_der_ganzen_spanne_entfernt_sie() {
        let mut doc = doc_mit_spanne();
        doc.replace_range(6..10, "");
        assert_eq!(doc.text, "hallo ");
        assert!(doc.spans.is_empty(), "{:?}", doc.spans);
    }

    #[test]
    fn ersetzen_ueber_das_spanende_hinweg() {
        let mut doc = doc_mit_spanne();
        // "o welt" (4..10) durch "!" ersetzen: der Text nach der Spanne fällt
        // weg, die Spanne endet im ersetzten Bereich und nimmt dessen Format an
        // (macOS setzt das Einfügezeichen an die Stelle der Auswahl).
        doc.replace_range(4..10, "!");
        assert_eq!(doc.text, "hall!");
        assert_eq!(doc.spans, vec![Span::new(4..5, Format::BOLD)]);
    }

    #[test]
    fn umlaute_bleiben_auf_zeichengrenzen() {
        let mut doc = EditorDoc::from_plain("äöü");
        doc.spans = vec![Span::new(2..4, Format::BOLD)]; // "öü"
        doc.replace_range(2..2, "ß"); // "äößü"
        assert_eq!(doc.text, "äßöü");
        assert_eq!(doc.spans, vec![Span::new(4..6, Format::BOLD)]);
    }

    #[test]
    fn format_setzen_und_umdrehen() {
        let mut doc = EditorDoc::from_plain("hallo welt");
        doc.set_format(0..5, Format::BOLD);
        assert_eq!(doc.spans, vec![Span::new(0..5, Format::BOLD)]);
        assert!(doc.has_format(0..5, Format::BOLD));

        doc.set_format(3..8, Format::ITALIC);
        assert_eq!(
            doc.spans,
            vec![
                Span::new(0..3, Format::BOLD),
                Span::new(3..5, Format::BOLD_ITALIC),
                Span::new(5..8, Format::ITALIC),
            ]
        );

        // Fett über einen schon fetten Bereich: abschalten. Die beiden
        // Kursiv-Stücke rücken danach zusammen.
        doc.toggle_format(0..5, Format::BOLD);
        assert_eq!(doc.spans, vec![Span::new(3..8, Format::ITALIC)]);
    }

    #[test]
    fn klartext_und_html() {
        let mut doc = EditorDoc::from_plain("hallo & welt\nzweite <zeile>");
        doc.set_format(0..5, Format::BOLD);
        doc.set_format(20..27, Format::ITALIC);
        assert_eq!(doc.to_plain(), "hallo & welt\nzweite <zeile>");
        assert_eq!(
            doc.to_html(),
            "<div><b>hallo</b> &amp; welt</div>\n<div>zweite <i>&lt;zeile&gt;</i></div>"
        );
        assert_eq!(EditorDoc::from_plain("").to_html(), "<div><br></div>");
    }

    #[test]
    fn fett_dann_undo() {
        let mut doc = EditorDoc::from_plain("Hallo Welt");
        let mut verlauf = Verlauf::new();

        verlauf.merken(&doc);
        doc.set_format(0..5, Format::BOLD);
        assert!(doc.has_format(0..5, Format::BOLD));

        assert!(verlauf.zuruecknehmen(&mut doc));
        assert!(!doc.has_format(0..5, Format::BOLD), "Auszeichnung ist weg");
        assert!(doc.spans.is_empty());
        assert_eq!(doc.text, "Hallo Welt", "Text bleibt");
        assert_eq!(verlauf.laenge(), (0, 1));

        // Nichts mehr zu holen: das Feld übernimmt den nächsten Undo.
        assert!(!verlauf.zuruecknehmen(&mut doc));
    }

    #[test]
    fn tippen_und_formatieren_gemischt() {
        let mut doc = EditorDoc::from_plain("Hallo");
        let mut verlauf = Verlauf::new();

        // Format setzen, dann tippen: der Stand passt nicht mehr zum Text.
        verlauf.merken(&doc);
        doc.set_format(0..5, Format::BOLD);
        doc.set_text_mit("Hallo Welt", None);
        assert!(!verlauf.zuruecknehmen(&mut doc), "Text ist ein anderer");
        assert!(doc.has_format(0..5, Format::BOLD), "Spannen bleiben, wie sie sind");

        // Zurückgetippt passt der Stand wieder — die Formatierung lässt sich
        // dann wie erwartet zurücknehmen.
        doc.set_text_mit("Hallo", None);
        assert!(verlauf.zuruecknehmen(&mut doc));
        assert!(doc.spans.is_empty());

        // Textänderung räumt den Redo-Weg ab.
        verlauf.merken(&doc);
        doc.set_format(0..5, Format::ITALIC);
        assert!(verlauf.zuruecknehmen(&mut doc));
        assert_eq!(verlauf.laenge(), (0, 1));
        verlauf.verwerfen();
        assert_eq!(verlauf.laenge(), (0, 0), "Redo nach Textänderung weg");
    }

    #[test]
    fn redo_stellt_wieder_her() {
        let mut doc = EditorDoc::from_plain("Hallo Welt");
        let mut verlauf = Verlauf::new();

        verlauf.merken(&doc);
        doc.set_format(6..10, Format::ITALIC);
        let mit_kursiv = doc.spans.clone();

        assert!(verlauf.zuruecknehmen(&mut doc));
        assert!(doc.spans.is_empty());

        assert!(verlauf.wiederholen(&mut doc));
        assert_eq!(doc.spans, mit_kursiv, "Redo stellt dieselbe Spanne her");
        assert!(doc.has_format(6..10, Format::ITALIC));
        assert!(!verlauf.wiederholen(&mut doc), "nur einmal");

        // Ein neuer Schritt macht den alten Redo-Weg ungültig.
        assert!(verlauf.zuruecknehmen(&mut doc));
        verlauf.merken(&doc);
        doc.set_format(0..5, Format::BOLD);
        assert_eq!(verlauf.laenge(), (1, 0));
        assert!(!verlauf.wiederholen(&mut doc));
    }

    #[test]
    fn verlauf_ist_begrenzt() {
        let mut doc = EditorDoc::from_plain("x");
        let mut verlauf = Verlauf::new();
        for _ in 0..Verlauf::MAX + 5 {
            verlauf.merken(&doc);
        }
        assert_eq!(verlauf.laenge(), (Verlauf::MAX, 0));
    }
}
