//! Verfassen: Modell, Adressen, Zitat, Autosave — Gegenstück zu `ComposeStore`
//! der Mac-App, aber ohne SwiftUI: die Oberfläche steht in `ui/compose_dock.rs`
//! und `ui/compose_form.rs`, der Editor kommt als Fassade aus `crate::editor`.
//!
//! Alles Rechnerische hier ist eine reine Funktion und ohne Fenster testbar:
//! Adressen aus Text, Betreff-Präfixe, Zitat und die Autosave-Entscheidung.
//!
//! Bis das Panel (`ui/compose_dock.rs`) den Zustand liest, ist das Modell noch
//! ohne Abnehmer — die Tests nutzen es bereits.
#![allow(dead_code)]

use std::path::PathBuf;
use std::time::{Duration, Instant};

/// Wie das Verfassen begonnen wurde.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Modus {
    Neu,
    Antwort,
    AllenAntworten,
    Weiterleiten,
}

impl Modus {
    pub fn titel(self) -> &'static str {
        match self {
            Modus::Neu => "Neue Nachricht",
            Modus::Antwort => "Antworten",
            Modus::AllenAntworten => "Allen antworten",
            Modus::Weiterleiten => "Weiterleiten",
        }
    }

    /// `mode` im Kern (`save_draft`): „new", „reply", „reply_all", „forward".
    pub fn kern_name(self) -> &'static str {
        match self {
            Modus::Neu => "new",
            Modus::Antwort => "reply",
            Modus::AllenAntworten => "reply_all",
            Modus::Weiterleiten => "forward",
        }
    }
}

/// Eine Adresse, wie sie im Feld steht („Max Mustermann <max@example.com>") oder
/// nur als Mailadresse.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Adresse {
    pub name: Option<String>,
    pub email: String,
}

impl Adresse {
    pub fn aus_text(text: &str) -> Self {
        let text = text.trim();
        if let (Some(start), Some(ende)) = (text.rfind('<'), text.rfind('>')) {
            if ende > start {
                let name = text[..start].trim().trim_matches('"').trim();
                return Adresse {
                    name: (!name.is_empty()).then(|| name.to_string()),
                    email: text[start + 1..ende].trim().to_string(),
                };
            }
        }
        Adresse { name: None, email: text.to_string() }
    }

    pub fn anzeige(&self) -> String {
        match self.name.as_deref().filter(|name| !name.is_empty()) {
            Some(name) => format!("{name} <{}>", self.email),
            None => self.email.clone(),
        }
    }

    /// Reicht das als Adresse? (bewusst streng: eine `@`-Stelle, Punkt in der Domain)
    pub fn gueltig(&self) -> bool {
        gueltige_mail(&self.email)
    }
}

fn gueltige_mail(email: &str) -> bool {
    let email = email.trim();
    if email.is_empty() || email.contains(char::is_whitespace) || email.matches('@').count() != 1 {
        return false;
    }
    let (lokal, domain) = email.split_once('@').unwrap_or(("", ""));
    !lokal.is_empty()
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !domain.contains("..")
}

/// Adressfeld in Adressen zerlegen: Komma oder Semikolon trennt, Anführungs-
/// zeichen um Namen sind erlaubt.
pub fn adressen_parsen(text: &str) -> Vec<Adresse> {
    text.split([',', ';'])
        .map(str::trim)
        .filter(|teil| !teil.is_empty())
        .map(Adresse::aus_text)
        .collect()
}

/// Einträge, die keine gültige Adresse sind — für die rote Markierung.
pub fn ungueltige(text: &str) -> Vec<String> {
    adressen_parsen(text)
        .into_iter()
        .filter(|adresse| !adresse.gueltig())
        .map(|adresse| adresse.email)
        .collect()
}

/// Betreff mit Präfix: „Re: " für Antworten, „Fwd: " fürs Weiterleiten, und nur
/// einmal (bekannte Präfixe werden erkannt, wie in der Mac-App).
pub fn betreff(betreff: &str, modus: Modus) -> String {
    let betreff = betreff.trim();
    let (praefix, bekannt): (&str, &[&str]) = match modus {
        Modus::Neu => return betreff.to_string(),
        Modus::Antwort | Modus::AllenAntworten => ("Re: ", &["re:", "aw:"]),
        Modus::Weiterleiten => ("Fwd: ", &["fwd:", "fw:", "wg:"]),
    };
    let klein = betreff.to_lowercase();
    let klein = klein.trim_start();
    if bekannt.iter().any(|vorhanden| klein.starts_with(vorhanden)) {
        betreff.to_string()
    } else if betreff.is_empty() {
        praefix.trim_end().to_string()
    } else {
        format!("{praefix}{betreff}")
    }
}

/// Zitat einer Antwort: Kopfzeile und der Originaltext mit „> " je Zeile.
pub fn zitat(original: &str, von: &str, datum: &str) -> String {
    let mut aus = String::with_capacity(original.len() + 128);
    aus.push_str(&format!("\n\nAm {datum} schrieb {von}:\n\n"));
    for zeile in original.lines() {
        if zeile.is_empty() {
            aus.push('>');
        } else {
            aus.push_str("> ");
            aus.push_str(zeile);
        }
        aus.push('\n');
    }
    // Kein Leerzeichen am Ende: der Cursor soll oben stehen, wo man schreibt.
    aus.trim_end().to_string() + "\n"
}

/// Weiterleitung: Kopfblock der Originalmail, dann der Text.
pub fn weiterleitung(
    original: &str,
    von: &str,
    an: &str,
    datum: &str,
    betreff_original: &str,
) -> String {
    format!(
        "\n\n---------- Weitergeleitete Nachricht ----------\n\
         Von: {von}\nAn: {an}\nDatum: {datum}\nBetreff: {betreff_original}\n\n{original}\n"
    )
}

/// So lange tippt niemand mehr, bis gespeichert wird.
pub const AUTOSAVE_PAUSE: Duration = Duration::from_millis(700);

/// Ist der Autosave fällig? `seit` ist der Zeitpunkt der letzten Änderung.
pub fn autosave_faellig(schmutzig: bool, seit: Option<Instant>, jetzt: Instant) -> bool {
    if !schmutzig {
        return false;
    }
    match seit {
        Some(seit) => jetzt.duration_since(seit) >= AUTOSAVE_PAUSE,
        // Ohne Zeitmarke (z. B. nach dem Wiederöffnen) sofort speichern.
        None => true,
    }
}

/// Ein Anhang im Verfassen-Fenster.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Anhang {
    pub pfad: PathBuf,
    pub name: String,
    pub groesse: u64,
    pub mime: String,
}

/// Nimmt die Anhang-Zeile `Entf`/`Backspace` an? (`Entf` und `Backspace`
/// löschen beide, wie in der Mac-App.)
pub fn entfernen_taste(taste: &str) -> bool {
    matches!(taste, "delete" | "backspace")
}

/// Auswahl nach dem Löschen: dieselbe Stelle, sonst die letzte; `None`, wenn
/// nichts mehr da ist (dann geht der Fokus zurück in den Körper).
pub fn auswahl_nach_loeschen(index: usize, laenge: usize) -> Option<usize> {
    if laenge == 0 {
        None
    } else {
        Some(index.min(laenge - 1))
    }
}

impl Anhang {
    pub fn groesse_text(&self) -> String {
        let bytes = self.groesse;
        if bytes < 1024 {
            format!("{bytes} B")
        } else if bytes < 1024 * 1024 {
            format!("{} KB", bytes / 1024)
        } else {
            format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
        }
    }
}

/// Ein offenes Verfassen-Fenster (mehrere möglich, wie das Dock der Mac-App).
#[derive(Clone, Debug)]
pub struct Compose {
    /// Fortlaufende Kennung im UI (nicht die Entwurfs-ID des Kerns).
    pub id: u64,
    pub modus: Modus,
    pub konto: i64,
    pub draft_id: Option<i64>,
    pub an: String,
    pub cc: String,
    pub bcc: String,
    pub betreff: String,
    /// Text und Formatierung; `None` heißt noch nie geladen (leer).
    pub doc: Option<crate::editor::EditorDoc>,
    pub anhaenge: Vec<Anhang>,
    pub minimiert: bool,
    /// Thread, auf den geantwortet wird (für `inReplyToMessageId`).
    pub antwort_auf: Option<i64>,
    /// Zuletzt gespeicherter Textstand (An/Text/Betreff), um Doppelarbeit zu sparen.
    pub gesichert: Option<String>,
    /// Letzte Änderung — Grundlage für [`autosave_faellig`].
    pub geaendert_um: Option<Instant>,
    /// Fehler des Kerns beim Speichern/Senden (bleibt sichtbar bis zur nächsten Aktion).
    pub fehler: Option<String>,
    /// „Wird gesendet · Rückgängig": Kennung der Warteschlangen-Aktion und Ende.
    pub sendung: Option<(i64, Instant)>,
}

impl Compose {
    pub fn neu(id: u64, modus: Modus, konto: i64) -> Self {
        Compose {
            id,
            modus,
            konto,
            draft_id: None,
            an: String::new(),
            cc: String::new(),
            bcc: String::new(),
            betreff: String::new(),
            doc: None,
            anhaenge: Vec::new(),
            minimiert: false,
            antwort_auf: None,
            gesichert: None,
            geaendert_um: None,
            fehler: None,
            sendung: None,
        }
    }

    /// Fingerabdruck des Inhalts: gleicher Stand → kein zweites `save_draft`.
    pub fn stand(&self, text: &str) -> String {
        format!("{}\u{1}{}\u{1}{}\u{1}{}\u{1}{}", self.an, self.cc, self.bcc, self.betreff, text)
    }

    /// Ist das Fenster leer genug, um es ohne Rückfrage zu schließen?
    pub fn leer(&self, text: &str) -> bool {
        self.an.trim().is_empty()
            && self.cc.trim().is_empty()
            && self.bcc.trim().is_empty()
            && self.betreff.trim().is_empty()
            && text.trim().is_empty()
    }

    /// Erste Zeile für die Leiste des minimierten Fensters.
    pub fn titel(&self) -> String {
        let betreff = self.betreff.trim();
        if betreff.is_empty() {
            self.modus.titel().to_string()
        } else {
            betreff.to_string()
        }
    }

    pub fn markiere_geaendert(&mut self, jetzt: Instant) {
        self.geaendert_um = Some(jetzt);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adressen_mit_und_ohne_namen() {
        let liste = adressen_parsen("Max Mustermann <max@example.com>, anna@example.org");
        assert_eq!(liste.len(), 2);
        assert_eq!(liste[0].name.as_deref(), Some("Max Mustermann"));
        assert_eq!(liste[0].email, "max@example.com");
        assert_eq!(liste[1].name, None);
        assert_eq!(liste[1].anzeige(), "anna@example.org");
        assert_eq!(liste[0].anzeige(), "Max Mustermann <max@example.com>");
    }

    #[test]
    fn kaputte_adressen_werden_erkannt() {
        assert_eq!(ungueltige("max@example.com"), Vec::<String>::new());
        assert_eq!(ungueltige("max@, ,foo@bar"), vec!["max@", "foo@bar"]);
        assert_eq!(ungueltige("zwei@punkte@example.com").len(), 1);
    }

    #[test]
    fn betreff_praefixe_nur_einmal() {
        assert_eq!(betreff("Termin", Modus::Antwort), "Re: Termin");
        assert_eq!(betreff("Re: Termin", Modus::Antwort), "Re: Termin");
        assert_eq!(betreff("AW: Termin", Modus::Antwort), "AW: Termin");
        assert_eq!(betreff("Termin", Modus::Weiterleiten), "Fwd: Termin");
        assert_eq!(betreff("WG: Termin", Modus::Weiterleiten), "WG: Termin");
        assert_eq!(betreff("Termin", Modus::Neu), "Termin");
        assert_eq!(betreff("", Modus::Antwort), "Re:");
    }

    #[test]
    fn zitat_haengt_an_und_zeichnet_zeilen_aus() {
        let text = zitat("Hallo\n\nWelt", "Max <max@example.com>", "22.11.2026, 14:32");
        assert!(text.starts_with("\n\nAm 22.11.2026, 14:32 schrieb Max <max@example.com>:"));
        assert!(text.contains("> Hallo"));
        assert!(text.contains(">\n> Welt"));
        assert!(text.ends_with('\n'));
    }

    #[test]
    fn weiterleitung_traegt_die_kopfzeilen() {
        let text = weiterleitung("Inhalt", "Max <max@example.com>", "anna@example.org", "22.11.", "Termin");
        assert!(text.contains("---------- Weitergeleitete Nachricht ----------"));
        assert!(text.contains("Von: Max <max@example.com>"));
        assert!(text.contains("An: anna@example.org"));
        assert!(text.contains("Betreff: Termin"));
        assert!(text.ends_with("Inhalt\n"));
    }

    #[test]
    fn autosave_wartet_die_pause_ab() {
        let jetzt = Instant::now();
        assert!(!autosave_faellig(false, Some(jetzt), jetzt));
        assert!(!autosave_faellig(true, Some(jetzt), jetzt));
        assert!(autosave_faellig(
            true,
            Some(jetzt),
            jetzt + AUTOSAVE_PAUSE + Duration::from_millis(1)
        ));
        assert!(autosave_faellig(true, None, jetzt));
    }

    #[test]
    fn leer_und_stand() {
        let mut compose = Compose::neu(1, Modus::Neu, 7);
        assert!(compose.leer(""));
        compose.an = "max@example.com".into();
        assert!(!compose.leer(""));
        assert_ne!(compose.stand("Hallo"), compose.stand("Hallo!"));
        compose.betreff = "Termin".into();
        assert_eq!(compose.titel(), "Termin");
        compose.betreff.clear();
        assert_eq!(compose.titel(), "Neue Nachricht");
    }

    #[test]
    fn entfernen_geht_mit_entf_und_backspace() {
        for taste in ["delete", "backspace"] {
            assert!(entfernen_taste(taste), "{taste}");
        }
        for taste in ["enter", "tab", "x", "escape"] {
            assert!(!entfernen_taste(taste), "{taste}");
        }
    }

    #[test]
    fn auswahl_nach_dem_loeschen() {
        // Letzten gelöscht: die Auswahl rutscht auf den neuen letzten.
        assert_eq!(auswahl_nach_loeschen(2, 2), Some(1));
        // Mittleren gelöscht: dieselbe Stelle zeigt jetzt den nächsten.
        assert_eq!(auswahl_nach_loeschen(1, 2), Some(1));
        // Nichts mehr da: Fokus zurück in den Körper.
        assert_eq!(auswahl_nach_loeschen(0, 0), None);
    }

    #[test]
    fn anhang_groesse() {
        let mut anhang = Anhang {
            pfad: PathBuf::from("/tmp/a.pdf"),
            name: "a.pdf".into(),
            groesse: 2048,
            mime: "application/pdf".into(),
        };
        assert_eq!(anhang.groesse_text(), "2 KB");
        anhang.groesse = 3 * 1024 * 1024;
        assert_eq!(anhang.groesse_text(), "3.0 MB");
    }
}
