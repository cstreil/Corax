//! Verhalten des Formatmodells beim Bearbeiten (`src/editor/format.rs`).
//!
//! Die Einzelfälle stehen als Unit-Tests in der Datei selbst; hier laufen die
//! Abläufe, die im Editor entstehen: Tippsalven, Löschen, Einsetzen, Export.

#[path = "../src/editor/format.rs"]
mod format;

use format::{EditorDoc, Format, Span};

/// Tippt Text Zeichen für Zeichen an Position `pos` (wie es das Feld meldet:
/// jedes Zeichen ein `set_text`).
fn tippe(doc: &mut EditorDoc, mut pos: usize, text: &str) {
    for zeichen in text.chars() {
        let neu = format!(
            "{}{}{}",
            &doc.text[..pos],
            zeichen,
            &doc.text[pos..]
        );
        doc.set_text(&neu);
        pos += zeichen.len_utf8();
    }
}

#[test]
fn tippsalve_vor_und_in_der_spanne() {
    let mut doc = EditorDoc::from_plain("hallo welt");
    doc.set_format(6..10, Format::BOLD);

    tippe(&mut doc, 0, "gut: ");
    assert_eq!(doc.text, "gut: hallo welt");
    assert_eq!(doc.spans, vec![Span::new(11..15, Format::BOLD)]);

    // Mitten in die fette Spanne tippen: sie wächst mit.
    tippe(&mut doc, 13, "XY");
    assert_eq!(doc.text, "gut: hallo weXYlt");
    assert_eq!(doc.spans, vec![Span::new(11..17, Format::BOLD)]);
    assert!(doc.has_format(11..17, Format::BOLD));
}

#[test]
fn rueckwaerts_loeschen_in_der_spanne() {
    let mut doc = EditorDoc::from_plain("hallo welt");
    doc.set_format(6..10, Format::BOLD);

    // Drei Zeichen am Ende der Spanne weg — sie schrumpft.
    for _ in 0..3 {
        let ende = doc.text.len();
        doc.replace_range(ende - 1..ende, "");
    }
    assert_eq!(doc.text, "hallo w");
    assert_eq!(doc.spans, vec![Span::new(6..7, Format::BOLD)]);

    // Letztes fettes Zeichen weg → Spanne entfällt.
    doc.replace_range(6..7, "");
    assert_eq!(doc.text, "hallo ");
    assert!(doc.spans.is_empty());
}

#[test]
fn einsetzen_ersetzt_auswahl() {
    let mut doc = EditorDoc::from_plain("eins zwei drei");
    doc.set_format(0..4, Format::BOLD);
    doc.set_format(9..13, Format::ITALIC);

    // "zwei" (5..9) durch "zweiundzwanzig" ersetzen: die Spannen davor bleibt,
    // die dahinter rutscht mit.
    doc.replace_range(5..9, "zweiundzwanzig");
    assert_eq!(doc.text, "eins zweiundzwanzig drei");
    assert_eq!(
        doc.spans,
        vec![
            Span::new(0..4, Format::BOLD),
            Span::new(19..23, Format::ITALIC),
        ]
    );
}

#[test]
fn antwort_mit_zitat_ohne_auszeichnung() {
    // Der Antworttext kommt als Klartext (Zitat des Originals), die eigene
    // Zeile wird fett gesetzt.
    let mut doc = EditorDoc::from_plain("Danke für die Rückmeldung.\n\n> Ihr Termin am Freitag");
    doc.set_format(0..26, Format::BOLD);
    assert_eq!(doc.spans, vec![Span::new(0..26, Format::BOLD)]);
    assert_eq!(
        doc.to_plain(),
        "Danke für die Rückmeldung.\n\n> Ihr Termin am Freitag"
    );
}

#[test]
fn fett_und_kursiv_ineinander() {
    let mut doc = EditorDoc::from_plain("Das ist wichtig");

    // Auswahl "wichtig" fett, dann halb kursiv.
    doc.toggle_format(8..15, Format::BOLD);
    doc.toggle_format(11..15, Format::ITALIC);
    assert_eq!(
        doc.spans,
        vec![
            Span::new(8..11, Format::BOLD),
            Span::new(11..15, Format::BOLD_ITALIC),
        ]
    );

    // Zweites Strg+B auf den schon fetten Bereich entfernt das Fett wieder.
    doc.toggle_format(8..15, Format::BOLD);
    assert_eq!(doc.spans, vec![Span::new(11..15, Format::ITALIC)]);
}

#[test]
fn html_export_verschachtelt_und_maskiert() {
    let mut doc = EditorDoc::from_plain("Hallo & Tschüss <du>\n\nfett und kursiv");
    doc.set_format(0..5, Format::BOLD); // "Hallo"
    doc.set_format(23..27, Format::BOLD); // "fett"
    doc.set_format(28..31, Format::BOLD_ITALIC); // "und"

    let html = doc.to_html();
    assert_eq!(
        html,
        "<div><b>Hallo</b> &amp; Tschüss &lt;du&gt;</div>\n<div><br></div>\n<div><b>fett</b> <i><b>und</b></i> kursiv</div>",
        "unerwartetes HTML:\n{html}"
    );
    // Der Text selbst bleibt unangetastet.
    assert!(doc.text.contains("<du>"));
}

#[test]
fn leeres_dokument_und_klartext() {
    let doc = EditorDoc::new();
    assert!(doc.is_empty());
    assert_eq!(doc.to_plain(), "");
    assert_eq!(doc.to_html(), "<div><br></div>");

    let doc = EditorDoc::from_plain("nur text");
    assert_eq!(doc.to_plain(), "nur text");
    assert!(doc.spans.is_empty());
}

#[test]
fn spanne_ueber_zeilengrenze_bleibt_gueltig() {
    let mut doc = EditorDoc::from_plain("erste zeile\nzweite zeile");
    doc.set_format(6..18, Format::BOLD); // "zeile\nzweite"
    let html = doc.to_html();
    assert_eq!(
        html,
        "<div>erste <b>zeile</b></div>\n<div><b>zweite</b> zeile</div>"
    );
}

#[test]
fn vorformat_tippt_sich_fort() {
    let mut doc = EditorDoc::from_plain("hallo");
    // Strg+B ohne Auswahl: das nächste Zeichen wird fett ...
    doc.set_text_mit("halloX", Some(Format::BOLD));
    assert_eq!(doc.spans, vec![Span::new(5..6, Format::BOLD)]);

    // ... und weil der Cursor am Ende der neuen Spanne steht, bleibt es fett.
    // Das Feld meldet jedes Zeichen einzeln, das Vorformat liegt weiter an.
    doc.set_text_mit("halloXY", Some(Format::BOLD));
    assert_eq!(doc.spans, vec![Span::new(5..7, Format::BOLD)]);
}

#[test]
fn fett_am_spanende_abschalten_und_weiter_tippen() {
    let mut doc = EditorDoc::from_plain("hallo welt");
    doc.set_format(6..10, Format::BOLD);

    // Strg+B am Ende der fetten Stelle schaltet Fett ab.
    doc.set_text_mit("hallo welt!", Some(Format::NONE));
    assert_eq!(doc.spans, vec![Span::new(6..10, Format::BOLD)]);
    assert_eq!(doc.format_at(10), Format::NONE);

    // Danach bleibt es beim normalen Text.
    doc.set_text("hallo welt!?");
    assert_eq!(doc.spans, vec![Span::new(6..10, Format::BOLD)]);
}

