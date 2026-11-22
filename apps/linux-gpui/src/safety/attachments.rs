//! A2: Prüfung vor dem Öffnen eines Anhangs.
//!
//! Unter Linux öffnet die App einen Anhang über `xdg-open`. Je nach Desktop
//! heißt das auch: ein Skript ausführen, einen `.desktop`-Starter starten oder
//! ein Paket installieren. Deshalb entscheidet diese Prüfung vorher, was
//! passiert:
//!
//! * [`OpenDecision::Open`] — harmlos, direkt öffnen.
//! * [`OpenDecision::Ask`] — Rückfrage mit Grund; wer will, öffnet trotzdem.
//! * [`OpenDecision::Block`] — gar nicht öffnen („Speichern unter…“ bleibt).
//!
//! Geprüft werden Dateiname (auch doppelte Endungen), MIME-Typ und der Anfang
//! der Datei. Ein Programm bleibt ein Programm, auch wenn die Datei
//! `rechnung.pdf` heißt.

// Bis Coder 1 die Prüfung vor `open_attachment` einbindet (L2), ruft sie
// niemand im Binary auf.
#![allow(dead_code)]

use std::fmt;

/// Was mit einem Anhang geschehen soll.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OpenDecision {
    /// Harmlos: direkt öffnen.
    Open,
    /// Nur nach Rückfrage öffnen.
    Ask { reason: String },
    /// Nicht öffnen; der Anhang lässt sich weiter speichern.
    Block { reason: String },
}

impl OpenDecision {
    /// Öffnen ohne Rückfrage?
    pub fn is_open(&self) -> bool {
        matches!(self, Self::Open)
    }
}

impl fmt::Display for OpenDecision {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Open => write!(f, "öffnen"),
            Self::Ask { reason } => write!(f, "fragen: {reason}"),
            Self::Block { reason } => write!(f, "blockiert: {reason}"),
        }
    }
}

/// Endungen, die ein Doppelklick ausführt oder ein Paket installiert.
const AUSFUEHRBAR: &[&str] = &[
    "desktop", "sh", "bash", "run", "appimage", "jar", "exe", "msi", "bat", "cmd", "ps1", "deb",
    "rpm", "flatpakref",
];

/// Skriptsprachen: Text, aber mit einem Doppelklick schnell ausgeführt.
const SKRIPTSPRACHE: &[&str] = &["py", "pl", "rb"];

/// MIME-Typen, die ein Programm oder Paket bezeichnen.
const GEFAEHRLICHE_MIME: &[&str] = &[
    "application/x-desktop",
    "application/x-executable",
    "application/x-sharedlib",
    "application/x-msdownload",
    "application/vnd.debian.binary-package",
    "application/x-rpm",
    "application/java-archive",
    "application/x-appimage",
    "application/x-shellscript",
];

/// Prüft einen Anhang vor dem Öffnen.
///
/// `filename` darf ein Pfad sein (es zählt der letzte Teil), `mime` darf leer
/// sein, `head` sind die ersten Bytes der Datei (ein paar Dutzend genügen).
pub fn check_attachment(filename: &str, mime: &str, head: &[u8]) -> OpenDecision {
    let endungen = endungen(filename);

    // 1. Der Name: die letzte Endung bestimmt den Typ.
    if let Some(letzte) = endungen.last() {
        if AUSFUEHRBAR.contains(&letzte.as_str()) {
            return OpenDecision::Block {
                reason: format!(".{letzte} ist ein Programm, Skript oder Paket"),
            };
        }
        if SKRIPTSPRACHE.contains(&letzte.as_str()) {
            return OpenDecision::Ask {
                reason: format!(".{letzte} ist ein Skript"),
            };
        }
        // 2. Doppelte Endung: innen etwas Ausführbares, außen harmlos
        //    (`rechnung.sh.pdf`). Der letzte Typ wäre harmlos, der Name täuscht.
        if let Some(innen) = endungen[..endungen.len() - 1]
            .iter()
            .find(|e| AUSFUEHRBAR.contains(&e.as_str()) || SKRIPTSPRACHE.contains(&e.as_str()))
        {
            return OpenDecision::Ask {
                reason: format!(".{innen} steckt als zweite Endung im Namen"),
            };
        }
    }

    // 3. MIME-Typ, auch wenn der Name harmlos aussieht.
    let mime = mime.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    if GEFAEHRLICHE_MIME.contains(&mime.as_str()) {
        return OpenDecision::Block {
            reason: format!("Typ {mime}"),
        };
    }

    // 4. Der Inhalt: ELF-Programm, Windows-Programm oder Shebang-Skript.
    match inhalt(head) {
        Some(Inhalt::Elf) => OpenDecision::Block {
            reason: "ausführbare Programmdatei (ELF)".to_string(),
        },
        Some(Inhalt::Pe) => OpenDecision::Block {
            reason: "ausführbare Windows-Programmdatei (PE)".to_string(),
        },
        Some(Inhalt::Shebang) => OpenDecision::Ask {
            reason: "beginnt wie ein ausführbares Skript (#!)".to_string(),
        },
        None => OpenDecision::Open,
    }
}

/// Die Endungen eines Dateinamens, von innen nach außen, klein geschrieben.
///
/// `rechnung.pdf.sh` → `["pdf", "sh"]`; `.bashrc` → `[]`; `a.tar.gz` →
/// `["tar", "gz"]`.
fn endungen(filename: &str) -> Vec<String> {
    let name = filename.rsplit(['/', '\\']).next().unwrap_or(filename).trim();
    let versteckt = name.starts_with('.');
    // Führende Punkte gehören zum Namen, nicht zur Endung (`.bashrc`).
    let basis = name.trim_start_matches('.');
    if basis.is_empty() {
        return Vec::new();
    }

    let mut teile: Vec<String> = basis
        .split('.')
        .skip(1) // der Name selbst ist keine Endung
        .filter(|teil| !teil.is_empty())
        .map(|teil| teil.to_ascii_lowercase())
        .collect();

    // Eine Datei, die nur aus der Endung besteht (`.desktop`, `.sh`), ist
    // trotzdem ein Starter bzw. Skript — der getrimmte Name zählt.
    if teile.is_empty() && versteckt {
        teile.push(basis.to_ascii_lowercase());
    }
    teile
}

/// Was im Dateianfang steckt.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Inhalt {
    Elf,
    Pe,
    Shebang,
}

fn inhalt(head: &[u8]) -> Option<Inhalt> {
    if head.starts_with(b"\x7fELF") {
        return Some(Inhalt::Elf);
    }
    if head.starts_with(b"#!") {
        return Some(Inhalt::Shebang);
    }
    if let Some(inhalt) = pe(head) {
        return Some(inhalt);
    }
    None
}

/// Windows-Programm: `MZ`, und an `e_lfanew` steht `PE\0\0`.
fn pe(head: &[u8]) -> Option<Inhalt> {
    if !head.starts_with(b"MZ") {
        return None;
    }
    if head.len() < 0x40 {
        // Zu kurz zum Prüfen: ein Text, der zufällig mit „MZ" beginnt, ist
        // kein Windows-Programm.
        return None;
    }
    let offset = u32::from_le_bytes(head[0x3c..0x40].try_into().ok()?) as usize;
    if head.len() >= offset + 4 && &head[offset..offset + 4] == b"PE\0\0" {
        return Some(Inhalt::Pe);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn harmlose_anhaenge() {
        assert_eq!(check_attachment("foto.jpg", "image/jpeg", b"\xff\xd8\xff"), OpenDecision::Open);
        assert_eq!(
            check_attachment("bericht.pdf", "application/pdf", b"%PDF-1.7\n"),
            OpenDecision::Open
        );
        assert_eq!(check_attachment("notizen.txt", "text/plain", b"Hallo"), OpenDecision::Open);
        assert_eq!(
            check_attachment("archiv.tar.gz", "application/gzip", b"\x1f\x8b"),
            OpenDecision::Open
        );
        assert_eq!(check_attachment("ohne_endung", "", b"nur text"), OpenDecision::Open);
    }

    #[test]
    fn programme_und_pakete_werden_blockiert() {
        for endung in AUSFUEHRBAR {
            let name = format!("datei.{endung}");
            assert!(
                matches!(
                    check_attachment(&name, "", b""),
                    OpenDecision::Block { .. }
                ),
                "{name} muss blockiert werden"
            );
        }
    }

    #[test]
    fn grossschreibung_zaehlt_nicht() {
        assert!(matches!(
            check_attachment("INSTALL.SH", "", b""),
            OpenDecision::Block { .. }
        ));
        assert!(matches!(
            check_attachment("Install.AppImage", "", b""),
            OpenDecision::Block { .. }
        ));
    }

    #[test]
    fn skriptsprachen_fragen() {
        for endung in SKRIPTSPRACHE {
            let name = format!("werkzeug.{endung}");
            assert!(
                matches!(check_attachment(&name, "", b""), OpenDecision::Ask { .. }),
                "{name} muss nachfragen"
            );
        }
    }

    #[test]
    fn elf_ohne_endung_wird_blockiert() {
        let kopf = b"\x7fELF\x02\x01\x01\x00";
        assert!(matches!(
            check_attachment("rechnung", "application/octet-stream", kopf),
            OpenDecision::Block { .. }
        ));
        assert!(matches!(
            check_attachment("rechnung.pdf", "application/pdf", kopf),
            OpenDecision::Block { .. }
        ));
    }

    #[test]
    fn shebang_ohne_endung_fragt() {
        let kopf = b"#!/bin/bash\nrm -rf ~\n";
        assert!(matches!(
            check_attachment("notiz", "text/plain", kopf),
            OpenDecision::Ask { .. }
        ));
    }

    #[test]
    fn windows_programm_wird_blockiert() {
        let mut kopf = vec![0u8; 0x80];
        kopf[0] = b'M';
        kopf[1] = b'Z';
        kopf[0x3c..0x40].copy_from_slice(&0x40u32.to_le_bytes());
        kopf[0x40..0x44].copy_from_slice(b"PE\0\0");
        assert!(matches!(
            check_attachment("rechnung.pdf", "application/pdf", &kopf),
            OpenDecision::Block { .. }
        ));
    }

    #[test]
    fn doppelte_endung_fragt() {
        for name in ["rechnung.sh.pdf", "bild.exe.jpg", "text.py.txt"] {
            match check_attachment(name, "", b"harmlos") {
                OpenDecision::Ask { reason } => {
                    assert!(
                        reason.contains("zweite Endung") || reason.contains("Endung"),
                        "{name}: {reason}"
                    );
                }
                anderes => panic!("{name} muss nachfragen, war {anderes:?}"),
            }
        }
    }

    #[test]
    fn blockierende_letzte_endung_gewinnt() {
        assert!(matches!(
            check_attachment("rechnung.pdf.sh", "", b""),
            OpenDecision::Block { .. }
        ));
    }

    #[test]
    fn mime_typ_zaehlt_auch_ohne_endung() {
        assert!(matches!(
            check_attachment("paket", "application/vnd.debian.binary-package", b""),
            OpenDecision::Block { .. }
        ));
        assert!(matches!(
            check_attachment("anhang", "application/x-executable", b""),
            OpenDecision::Block { .. }
        ));
        // MIME mit Parametern bleibt erkennbar.
        assert!(matches!(
            check_attachment("anhang", "application/x-desktop; charset=utf-8", b""),
            OpenDecision::Block { .. }
        ));
    }

    #[test]
    fn pfad_und_punktdateien() {
        assert!(matches!(
            check_attachment("/tmp/anhang/rechnung.sh", "", b""),
            OpenDecision::Block { .. }
        ));
        // `.bashrc` ist eine Textdatei ohne Endung, kein Programm.
        assert_eq!(
            check_attachment(".bashrc", "text/plain", b"export PATH=$PATH"),
            OpenDecision::Open
        );
        // Eine Datei, die nur `.desktop` heißt, ist trotzdem ein Starter.
        assert!(matches!(
            check_attachment(".desktop", "", b""),
            OpenDecision::Block { .. }
        ));
    }

    #[test]
    fn anzeige_der_entscheidung() {
        assert_eq!(OpenDecision::Open.to_string(), "öffnen");
        assert_eq!(
            OpenDecision::Block { reason: "ELF".into() }.to_string(),
            "blockiert: ELF"
        );
    }
}
