//! Fassade um das Eingabefeld fürs Verfassen (`ComposeEditor`).
//!
//! Einzige Stelle im Baum, die `gpui_component::input` kennt: tauscht man das
//! Feld später aus, kostet das diese Datei und nicht das Verfassen-Formular.
//!
//! Das Feld kennt nur Text. Fett und Kursiv leben deshalb im Schattenmodell
//! [`EditorDoc`] (Text plus Spannen) und werden über die gepatchte
//! `InputState::set_span_styles` ans Feld gegeben (siehe
//! `vendor/gpui-component/PATCH.md`). Bei jedem `Change`-Ereignis zieht
//! [`EditorDoc::set_text_mit`] die Spannen mit — Tippen, Löschen, Einfügen, IME
//! und Undo landen alle dort.
//!
//! Dazu die Formatleiste ([`format_bar`]): sie schaltet Fett und Kursiv für die
//! Auswahl um; ohne Auswahl gilt das Format für den nächsten getippten Text
//! („Vorformat"), und zwar nur an der Cursor-Stelle, an der es gesetzt wurde.

pub mod format;
pub mod format_bar;

use std::ops::Range;

use gpui::*;
use gpui_component::input::{Input, InputEvent, InputState};

use crate::theme::Theme;

pub use format::{Aenderung, EditorDoc, Format, Verlauf};

/// Ereignisse des Editors an das Verfassen-Formular.
///
/// Noch ohne Abnehmer: das Formular (L2) bindet die Fassade ein, danach fallen
/// die `allow(dead_code)` hier und an `ComposeEditor` weg.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditorEvent {
    /// Text oder Formatierung haben sich geändert (Anlass für Autosave).
    Changed,
    /// Abschicken verlangt; die Form entscheidet, was das heißt.
    Submit,
}

/// Eingabefeld mit Fett und Kursiv.
#[allow(dead_code)]
pub struct ComposeEditor {
    feld: Entity<InputState>,
    /// Schattenmodell: Text plus Spannen.
    doc: EditorDoc,
    /// Läuft gerade `set_content`? Dann ist ein `Change`-Ereignis unsere eigene
    /// Änderung und darf nicht zurückgelesen werden.
    laden: bool,
    /// Vorformat für den nächsten getippten Text und die Cursor-Stelle, an der
    /// es gilt. `Some((pos, Format::NONE))` heißt bewusst „nicht fett" — das
    /// schaltet Fett am Ende einer fetten Stelle ab.
    vorformat: Option<(usize, Format)>,
    /// Undo/Redo der Formatierung: Spannen plus Text je Schritt. Den
    /// Textverlauf führt das Feld selbst.
    verlauf: Verlauf,
    /// Tasten-Interceptor für `Strg+Z`/`Strg+Y`. Er lebt, solange der Editor
    /// lebt; ohne ihn käme die Taste nie an (das Feld bindet `ctrl-z` selbst).
    _tasten: Subscription,
    theme: Theme,
}

impl EventEmitter<EditorEvent> for ComposeEditor {}

#[allow(dead_code)]
impl ComposeEditor {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let feld = cx.new(|cx| {
            InputState::new(window, cx)
                .multi_line(true)
                .rows(12)
                .placeholder("Nachricht schreiben …")
        });

        // `Strg+Z`/`Strg+Y` gehören dem Feld: es bindet `ctrl-z` und `ctrl-y`
        // selbst, und Tastenbelegungen laufen vor jedem Element-Handler. Der
        // Interceptor läuft davor und nimmt den Schritt nur, solange der Text
        // noch zu den gemerkten Spannen passt — sonst bleibt es beim
        // Text-Undo des Feldes.
        let schwach = cx.entity().downgrade();
        let tasten = cx.intercept_keystrokes(move |event, window, cx| {
            let Some(this) = schwach.upgrade() else {
                return;
            };
            if !this.read(cx).hat_fokus(window, cx) {
                return;
            }
            let griff = this.update(cx, |this, cx| this.verlauf_taste(&event.keystroke, cx));
            if griff {
                cx.stop_propagation();
            }
        });

        cx.subscribe(&feld, |this, _feld, event: &InputEvent, cx| {
            if !matches!(event, InputEvent::Change) || this.laden {
                return;
            }
            let text = this.feld.read(cx).value().to_string();
            this.tausch(&text, cx);
            this.stile_setzen(cx);
            cx.emit(EditorEvent::Changed);
            cx.notify();
        })
        .detach();

        // Bewegt sich der Cursor, ohne dass getippt wurde, fällt das Vorformat
        // weg. Es gilt nur an der Stelle, an der es gesetzt wurde — sonst käme
        // es zurück, sobald der Cursor zufällig wieder dort steht.
        cx.observe(&feld, |this, feld, cx| {
            if this.vorformat.is_none() {
                return;
            }
            let auswahl = feld.read(cx).selected_range();
            if vorformat_gueltig(this.vorformat, &auswahl).is_none() {
                this.vorformat = None;
                cx.notify();
            }
        })
        .detach();

        Self {
            feld,
            doc: EditorDoc::new(),
            laden: false,
            vorformat: None,
            verlauf: Verlauf::new(),
            _tasten: tasten,
            theme: Theme::load(),
        }
    }

    /// Setzt Text und Formatierung (Antwort mit Zitat, wieder geöffneter Entwurf).
    ///
    /// Weicht vom Briefing in einem Punkt ab: `gpui-component` braucht zum
    /// Setzen des Werts ein `Window`, deshalb kommt es hier mit.
    pub fn set_content(&mut self, doc: &EditorDoc, window: &mut Window, cx: &mut Context<Self>) {
        self.doc = doc.clone();
        self.vorformat = None;
        self.verlauf = Verlauf::new();
        self.laden = true;
        let text = doc.text.clone();
        self.feld
            .update(cx, |zustand, cx| zustand.set_value(text, window, cx));
        self.laden = false;
        self.stile_setzen(cx);
        cx.notify();
    }

    /// Aktueller Inhalt: Text aus dem Feld, Spannen aus dem Schattenmodell.
    pub fn content(&self, cx: &App) -> EditorDoc {
        let mut doc = self.doc.clone();
        doc.set_text(&self.feld.read(cx).value().to_string());
        doc
    }

    pub fn focus(&self, window: &mut Window, cx: &mut App) {
        self.feld
            .update(cx, |zustand, cx| zustand.focus(window, cx));
    }

    pub fn is_empty(&self, cx: &App) -> bool {
        self.feld.read(cx).value().trim().is_empty()
    }

    /// Auswahl als UTF-8-Bereich (`selected_range()` ist Teil des Patches).
    pub fn selected_range(&self, cx: &App) -> Range<usize> {
        self.feld.read(cx).selected_range()
    }

    /// Zustand der Formatleiste: Fett/Kursiv der Auswahl, sonst das, was ein
    /// Zeichen an dieser Stelle bekäme (Vorformat vor Cursor-Format).
    pub fn format_state(&self, cx: &App) -> Format {
        let range = self.selected_range(cx);
        if range.start < range.end {
            return Format {
                bold: self.doc.has_format(range.clone(), Format::BOLD),
                italic: self.doc.has_format(range, Format::ITALIC),
            };
        }
        vorformat_gueltig(self.vorformat, &range)
            .unwrap_or_else(|| self.doc.ererbte_format(range.start))
    }

    /// Schaltet Fett oder Kursiv um (Formatleiste, Strg+B/Strg+I).
    ///
    /// Mit Auswahl wirkt es sofort auf den Bereich; ohne Auswahl gilt es als
    /// Vorformat für den nächsten getippten Text (wie in Mail und Word).
    pub fn toggle_format(&mut self, format: Format, cx: &mut Context<Self>) {
        let text = self.feld.read(cx).value().to_string();
        self.doc.set_text(&text);
        self.verlauf.merken(&self.doc);
        let range = self.selected_range(cx);
        if range.start < range.end {
            self.vorformat = None;
            self.doc.toggle_format(range, format);
            self.stile_setzen(cx);
            cx.emit(EditorEvent::Changed);
        } else {
            let basis = vorformat_gueltig(self.vorformat, &range)
                .unwrap_or_else(|| self.doc.ererbte_format(range.start));
            let neu = Format {
                bold: if format.bold { !basis.bold } else { basis.bold },
                italic: if format.italic { !basis.italic } else { basis.italic },
            };
            self.vorformat = Some((range.start, neu));
        }
        cx.notify();
    }

    /// Farbe der Formatleiste bei Theme-Wechsel.
    pub fn set_theme(&mut self, theme: Theme, cx: &mut Context<Self>) {
        self.theme = theme;
        cx.notify();
    }

    /// Meldet „abschicken". Das Formular bindet das auf Strg+Enter; das Feld
    /// selbst kennt in 0.5.1 nur Enter und ⇧+Enter (`PressEnter { secondary }`).
    pub fn submit(&mut self, cx: &mut Context<Self>) {
        cx.emit(EditorEvent::Submit);
    }

    /// Übernimmt den Feldtext und trägt das Vorformat an den neuen Cursor
    /// weiter, solange Text nur eingefügt wurde. Löschen nimmt es weg.
    fn tausch(&mut self, text: &str, cx: &App) {
        let vorformat = self.vorformat.take();
        let aenderung = self.doc.set_text_mit(text, vorformat.map(|(_, format)| format));
        if !matches!(aenderung, Aenderung::Nichts) {
            // Getippt: ein zurückgenommener Format-Schritt passt nicht mehr.
            self.verlauf.verwerfen();
        }
        if let (Some((_, format)), Aenderung::Eingefuegt { .. }) = (vorformat, aenderung) {
            let auswahl = self.feld.read(cx).selected_range();
            if auswahl.start == auswahl.end {
                self.vorformat = Some((auswahl.start, format));
            }
        }
    }

    /// Strg+B / Strg+I. `true`, wenn die Taste verbraucht ist.
    fn kuerzel(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) -> bool {
        let keystroke = &event.keystroke;
        let mods = keystroke.modifiers;
        if !mods.control || mods.alt || mods.platform {
            return false;
        }
        let format = match keystroke.key.as_str() {
            "b" | "B" => Format::BOLD,
            "i" | "I" => Format::ITALIC,
            _ => return false,
        };
        self.toggle_format(format, cx);
        true
    }

    /// Hat das Textfeld gerade den Fokus? Nur dann gehören `Strg+Z`/`Strg+Y`
    /// uns; nebenan (Suche, andere Felder) darf der Interceptor nicht wirken.
    fn hat_fokus(&self, window: &Window, cx: &App) -> bool {
        use gpui::Focusable;
        self.feld.read(cx).focus_handle(cx).is_focused(window)
    }

    /// `Strg+Z`/`Strg+Y` (`Strg+⇧+Z`) für die Formatierung.
    ///
    /// `true`, wenn der Schritt uns gehörte und das Feld ihn nicht mehr bekommen
    /// darf. Passt der Text nicht mehr zu den gemerkten Spannen, bleibt der
    /// Schritt beim Feld — dessen Undo nimmt dann den Text zurück.
    fn verlauf_taste(&mut self, keystroke: &Keystroke, cx: &mut Context<Self>) -> bool {
        let mods = keystroke.modifiers;
        if !mods.control || mods.alt || mods.platform {
            return false;
        }
        let zurueck = match keystroke.key.as_str() {
            "z" | "Z" => !mods.shift,
            "y" | "Y" => false,
            _ => return false,
        };
        // Text aus dem Feld nachziehen, damit der Vergleich im Verlauf stimmt.
        let text = self.feld.read(cx).value().to_string();
        self.doc.set_text(&text);
        let getroffen = if zurueck {
            self.verlauf.zuruecknehmen(&mut self.doc)
        } else {
            self.verlauf.wiederholen(&mut self.doc)
        };
        if !getroffen {
            return false;
        }
        // Nach Undo/Redo gilt kein Vorformat mehr an dieser Cursor-Stelle.
        self.vorformat = None;
        self.stile_setzen(cx);
        cx.emit(EditorEvent::Changed);
        cx.notify();
        true
    }

    /// Spannen ans Feld geben; ein `HighlightStyle` je Bereich.
    fn stile_setzen(&mut self, cx: &mut Context<Self>) {
        let stile = span_stile(&self.doc);
        self.feld.update(cx, |zustand, cx| {
            zustand.set_span_styles(stile, cx);
        });
    }
}

impl Render for ComposeEditor {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .flex()
            .flex_col()
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                if this.kuerzel(event, cx) {
                    cx.stop_propagation();
                }
            }))
            .child(format_bar::leiste(self, cx))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .w_full()
                    .child(Input::new(&self.feld).h_full()),
            )
    }
}

/// Das Vorformat gilt nur, solange der Cursor noch an seiner Stelle steht.
fn vorformat_gueltig(vorformat: Option<(usize, Format)>, auswahl: &Range<usize>) -> Option<Format> {
    match vorformat {
        Some((pos, format)) if auswahl.start == pos && auswahl.end == pos => Some(format),
        _ => None,
    }
}

/// Übersetzt die Spannen des Modells in Stile für das Feld.
fn span_stile(doc: &EditorDoc) -> Vec<(Range<usize>, HighlightStyle)> {
    doc.spans
        .iter()
        .filter_map(|span| {
            if span.format.is_empty() {
                return None;
            }
            let mut stil = HighlightStyle::default();
            if span.format.bold {
                stil.font_weight = Some(FontWeight::BOLD);
            }
            if span.format.italic {
                stil.font_style = Some(FontStyle::Italic);
            }
            Some((span.range.clone(), stil))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    // Kein `use super::*`: das würde `gpui::test` mit hereinziehen und die
    // `#[test]`-Makros rekursiv expandieren.
    use super::{Format, vorformat_gueltig};

    #[test]
    fn vorformat_gilt_nur_am_cursor() {
        let vorformat = Some((5, Format::BOLD));
        assert_eq!(
            vorformat_gueltig(vorformat, &(5..5)),
            Some(Format::BOLD),
            "Cursor steht noch"
        );
        assert_eq!(vorformat_gueltig(vorformat, &(6..6)), None, "Cursor bewegt");
        assert_eq!(vorformat_gueltig(vorformat, &(4..5)), None, "Auswahl");
        assert_eq!(vorformat_gueltig(None, &(5..5)), None);
    }

    #[test]
    fn vorformat_kann_fett_abschalten() {
        let vorformat = Some((5, Format::NONE));
        assert_eq!(vorformat_gueltig(vorformat, &(5..5)), Some(Format::NONE));
    }
}
