//! Tastatur nach `TASTATUR.md` (L1-Umfang).
//!
//! Erkannt wird das **Zeichen**, nicht die Taste (`Keystroke::key_char`): auf
//! der deutschen Tastatur liegen `/ ? # ! \ + -` hinter Shift bzw. AltGr, mit
//! `key` allein käme dort „7", „ß", „3" … an. Namenstasten (Enter, Esc,
//! Pfeile, Bild, Pos1/Ende, Tab) werden über `key` erkannt.
//!
//! Einzeltasten wirken nur, wenn kein Textfeld den Fokus hat (wie auf dem Mac);
//! das entscheidet der Aufrufer und meldet es über [`Kontext`].
//!
//! Absichtlich *keine* GPUI-Keymap: `bind_keys` vergleicht die Tastenbelegung
//! (`key`), nicht das getippte Zeichen. Die Tabelle hier ist eine Funktion und
//! damit ohne Fenster testbar.

use gpui::KeyDownEvent;

/// Was die Taste auslöst.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// `j` / `↓`
    Weiter,
    /// `k` / `↑`
    Zurueck,
    /// `Bild↓`
    SeiteWeiter,
    /// `Bild↑`
    SeiteZurueck,
    /// `Pos1` / `Ende`
    Anfang,
    Ende,
    /// `Enter` / `o` – klappt auf oder zu (je nach Zustand).
    Oeffnen,
    /// `Esc`
    Schliessen,
    /// `Tab` / `Strg+Tab`
    NaechsterSplit,
    VorigerSplit,
    /// `/`
    Suche,
    /// `?`
    Hilfe,
    /// `\` / `Strg+S`
    Seitenleiste,
    /// `G` gefolgt von `I S D T E H # ! A`
    GeheZu(crate::core::models::MailView),
}

/// In welchem Zustand die Taste ankommt.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Kontext {
    /// Ein Textfeld hat den Fokus: Einzeltasten aus, nur Esc kommt durch.
    pub textfeld: bool,
    /// Ein `G` wartet auf die zweite Taste.
    pub g_prefix: bool,
}

/// Was mit der Taste passiert.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ergebnis {
    Aktion(Action),
    /// `G` allein: die Statuszeile wartet 2 s auf die zweite Taste.
    GeheZuBeginn,
    /// Weder Aktion noch Präfix.
    Nichts,
}

/// Tastendruck auswerten. `None` = die Taste gehört nicht der Liste.
pub fn auswerten(event: &KeyDownEvent, ctx: Kontext) -> Ergebnis {
    let keystroke = &event.keystroke;
    let mods = keystroke.modifiers;

    // Esc beendet auch im Textfeld die Eingabe.
    if keystroke.key == "escape" {
        return Ergebnis::Aktion(Action::Schliessen);
    }
    if ctx.textfeld {
        return Ergebnis::Nichts;
    }

    // Strg+Tab wechselt den Split; Strg+S die Seitenleiste (⌃⌘S der Mac-App).
    if mods.control && !mods.alt && !mods.platform {
        match keystroke.key.as_str() {
            "tab" => {
                return Ergebnis::Aktion(if mods.shift {
                    Action::VorigerSplit
                } else {
                    Action::NaechsterSplit
                });
            }
            "s" => return Ergebnis::Aktion(Action::Seitenleiste),
            _ => {}
        }
    }

    // Namenstasten (unabhängig von der Belegung).
    if !mods.alt && !mods.platform {
        match keystroke.key.as_str() {
            "enter" | "return" => return Ergebnis::Aktion(Action::Oeffnen),
            "down" => return Ergebnis::Aktion(Action::Weiter),
            "up" => return Ergebnis::Aktion(Action::Zurueck),
            "pagedown" => return Ergebnis::Aktion(Action::SeiteWeiter),
            "pageup" => return Ergebnis::Aktion(Action::SeiteZurueck),
            "home" => return Ergebnis::Aktion(Action::Anfang),
            "end" => return Ergebnis::Aktion(Action::Ende),
            "tab" => {
                return Ergebnis::Aktion(if mods.shift {
                    Action::VorigerSplit
                } else {
                    Action::NaechsterSplit
                });
            }
            _ => {}
        }
    }

    // Zeichen: was die Belegung tatsächlich getippt hat. AltGr (auf der
    // deutschen Tastatur für `\`, `|`, `~`) kommt als Strg+Alt an, deshalb
    // zählen hier Strg/Alt nicht als Ausschluss.
    let Some(zeichen) = getipptes_zeichen(keystroke) else {
        return Ergebnis::Nichts;
    };
    let klein = zeichen.to_lowercase().next().unwrap_or(zeichen);

    if ctx.g_prefix {
        if let Some(view) = crate::core::models::MailView::from_go_key(klein) {
            return Ergebnis::Aktion(Action::GeheZu(view));
        }
        // Ein `G` ohne gültige Folge startet nur neu, wenn es wieder `g` ist.
        if klein != 'g' {
            return Ergebnis::Nichts;
        }
    }

    match klein {
        'j' => Ergebnis::Aktion(Action::Weiter),
        'k' => Ergebnis::Aktion(Action::Zurueck),
        'o' | 'l' => Ergebnis::Aktion(Action::Oeffnen),
        '/' => Ergebnis::Aktion(Action::Suche),
        '?' => Ergebnis::Aktion(Action::Hilfe),
        '\\' => Ergebnis::Aktion(Action::Seitenleiste),
        'g' => Ergebnis::GeheZuBeginn,
        _ => Ergebnis::Nichts,
    }
}

/// Das getippte Zeichen, falls die Taste eines erzeugt hat.
fn getipptes_zeichen(keystroke: &gpui::Keystroke) -> Option<char> {
    if let Some(text) = keystroke.key_char.as_deref() {
        let mut chars = text.chars();
        if let (Some(c), None) = (chars.next(), chars.next()) {
            return Some(c);
        }
    }
    // Kein `key_char` (z. B. unter X11 bei manchen Belegungen): nur ein
    // einzelnes Zeichen als Namenstaste verwenden, nie „enter" oder „f1".
    let mut chars = keystroke.key.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) => Some(c),
        _ => None,
    }
}

/// Zeilen für das Hilfe-Overlay (`?`), gleiche Reihenfolge wie `TASTATUR.md`.
pub const HILFE: &[(&str, &str)] = &[
    ("J / K", "nächster / voriger Thread"),
    ("↵", "Thread aufklappen / zuklappen"),
    ("Esc", "zuklappen, Suche verlassen"),
    ("/", "Suche"),
    ("Tab / ⇧Tab", "Split wechseln"),
    ("G I", "Posteingang"),
    ("G S", "Markiert"),
    ("G D", "Entwürfe"),
    ("G T", "Gesendet"),
    ("G E", "Erledigt"),
    ("G H", "Später"),
    ("G #", "Papierkorb"),
    ("G !", "Spam"),
    ("G A", "Alle"),
    ("\\", "Seitenleiste ein/aus"),
    ("?", "diese Übersicht"),
];

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{Keystroke, Modifiers};

    fn taste(key: &str, key_char: Option<&str>) -> KeyDownEvent {
        taste_mit(key, key_char, Modifiers::default())
    }

    fn taste_mit(key: &str, key_char: Option<&str>, modifiers: Modifiers) -> KeyDownEvent {
        KeyDownEvent {
            keystroke: Keystroke {
                modifiers,
                key: key.to_string(),
                key_char: key_char.map(str::to_string),
            },
            is_held: false,
        }
    }

    fn aktion(event: &KeyDownEvent) -> Ergebnis {
        auswerten(event, Kontext::default())
    }

    #[test]
    fn buchstaben_und_namenstasten() {
        assert_eq!(aktion(&taste("j", Some("j"))), Ergebnis::Aktion(Action::Weiter));
        assert_eq!(aktion(&taste("k", Some("k"))), Ergebnis::Aktion(Action::Zurueck));
        assert_eq!(aktion(&taste("enter", None)), Ergebnis::Aktion(Action::Oeffnen));
        assert_eq!(aktion(&taste("escape", None)), Ergebnis::Aktion(Action::Schliessen));
        assert_eq!(aktion(&taste("down", None)), Ergebnis::Aktion(Action::Weiter));
        assert_eq!(aktion(&taste("pagedown", None)), Ergebnis::Aktion(Action::SeiteWeiter));
    }

    #[test]
    fn deutsche_belegung_schraegstrich_und_fragezeichen() {
        // `/` ist auf Deutsch Shift+7, `?` Shift+ß, `#` Shift+3.
        let shift = Modifiers { shift: true, ..Default::default() };
        assert_eq!(
            aktion(&taste_mit("7", Some("/"), shift)),
            Ergebnis::Aktion(Action::Suche)
        );
        assert_eq!(
            aktion(&taste_mit("ß", Some("?"), shift)),
            Ergebnis::Aktion(Action::Hilfe)
        );
        // `#` gehört zu L2 (Papierkorb), darf aber die G-Folge bedienen.
        let g = auswerten(&taste("g", Some("g")), Kontext::default());
        assert_eq!(g, Ergebnis::GeheZuBeginn);
        assert_eq!(
            auswerten(
                &taste_mit("3", Some("#"), shift),
                Kontext { g_prefix: true, ..Default::default() }
            ),
            Ergebnis::Aktion(Action::GeheZu(crate::core::models::MailView::Trash))
        );
    }

    #[test]
    fn altgr_erreicht_backslash() {
        // AltGr kommt unter Wayland/X11 als Strg+Alt an.
        let altgr = Modifiers { control: true, alt: true, ..Default::default() };
        assert_eq!(
            aktion(&taste_mit("ß", Some("\\"), altgr)),
            Ergebnis::Aktion(Action::Seitenleiste)
        );
    }

    #[test]
    fn g_folge() {
        let ctx = Kontext { g_prefix: true, ..Default::default() };
        assert_eq!(
            auswerten(&taste("i", Some("i")), ctx),
            Ergebnis::Aktion(Action::GeheZu(crate::core::models::MailView::Inbox))
        );
        assert_eq!(
            auswerten(&taste("t", Some("t")), ctx),
            Ergebnis::Aktion(Action::GeheZu(crate::core::models::MailView::Sent))
        );
        assert_eq!(auswerten(&taste("x", Some("x")), ctx), Ergebnis::Nichts);
    }

    #[test]
    fn textfeld_nimmt_nur_escapen() {
        let ctx = Kontext { textfeld: true, ..Default::default() };
        assert_eq!(auswerten(&taste("j", Some("j")), ctx), Ergebnis::Nichts);
        assert_eq!(
            auswerten(&taste("escape", None), ctx),
            Ergebnis::Aktion(Action::Schliessen)
        );
    }

    #[test]
    fn strg_tab_wechselt_split() {
        let ctrl = Modifiers { control: true, ..Default::default() };
        assert_eq!(
            aktion(&taste_mit("tab", None, ctrl)),
            Ergebnis::Aktion(Action::NaechsterSplit)
        );
        let ctrl_shift = Modifiers { control: true, shift: true, ..Default::default() };
        assert_eq!(
            aktion(&taste_mit("tab", None, ctrl_shift)),
            Ergebnis::Aktion(Action::VorigerSplit)
        );
    }

    #[test]
    fn funktionstasten_sind_keine_zeichen() {
        assert_eq!(aktion(&taste("f1", None)), Ergebnis::Nichts);
        assert_eq!(aktion(&taste("shift", None)), Ergebnis::Nichts);
    }
}
