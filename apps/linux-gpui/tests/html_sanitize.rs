//! Integrationstests der HTML-Sanitisierung: die fünf Korpus-Mails und die
//! bösartigen Fälle aus §7 des Briefings.
//!
//! Modul wird per `#[path]` eingebunden, weil das Paket nur ein Binary hat und
//! `src/html` damit für Integrationstests sonst nicht erreichbar wäre.

#[path = "../src/html/mod.rs"]
mod html;

use std::collections::HashSet;
use std::io::Write;
use std::path::PathBuf;

use html::{Policy, RemoteImages, sanitize};

/// Korpus-Ordner neben dem Repo (`Projekte/…` → `Tasks/…`).
fn standard_korpus() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../../Tasks/2026-11-22-corax-linux/korpus")
}

/// Korpus-Ordner: `CORAX_KORPUS` oder der Task-Ordner neben dem Repo.
///
/// `Err` heißt: die Variable ist gesetzt, taugt aber nicht — das ist ein
/// Fehler und keine Auslassung, sonst testet man nichts und merkt es nicht.
fn korpus_ordner() -> Result<Option<PathBuf>, String> {
    if let Ok(wert) = std::env::var("CORAX_KORPUS") {
        let pfad = PathBuf::from(&wert);
        return if pfad.is_dir() {
            Ok(Some(pfad))
        } else {
            Err(format!("CORAX_KORPUS={wert:?} ist kein Ordner"))
        };
    }
    let pfad = standard_korpus();
    Ok(pfad.is_dir().then_some(pfad))
}

/// Entfernt HTML-Kommentare. Sie zählen nicht zum Dokument: Newsletter
/// verstecken darin Outlook-eigene Blöcke (`<!--[if mso]>…<![endif]-->`), und
/// in einem Kommentar ist ein `<style>` kein Stylesheet.
fn ohne_kommentare(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(start) = rest.find("<!--") {
        out.push_str(&rest[..start]);
        match rest[start..].find("-->") {
            Some(ende) => rest = &rest[start + ende + 3..],
            None => return out,
        }
    }
    out.push_str(rest);
    out
}

/// sichtbare Wörter (≥ 5 Zeichen, klein) ohne `style`, `script` und `title`.
fn sichtbare_woerter(html: &str) -> HashSet<String> {
    let klein = html.to_ascii_lowercase();
    let mut text = String::with_capacity(html.len());
    let mut index = 0usize;
    while index < html.len() {
        let mut springen = None;
        for tag in ["style", "script", "title"] {
            if klein[index..].starts_with(&format!("<{tag}")) {
                springen = Some(match klein[index..].find(&format!("</{tag}")) {
                    Some(offset) => match klein[index + offset..].find('>') {
                        Some(close) => index + offset + close + 1,
                        None => html.len(),
                    },
                    None => html.len(),
                });
                break;
            }
        }
        match springen {
            Some(ziel) => index = ziel,
            None => {
                let zeichen = html[index..].chars().next().expect("Zeichen");
                text.push(zeichen);
                index += zeichen.len_utf8();
            }
        }
    }

    let mut woerter = HashSet::new();
    let mut aktuell = String::new();
    let mut im_tag = false;
    for zeichen in text.chars() {
        match zeichen {
            '<' => {
                im_tag = true;
                aktuell.clear();
            }
            '>' => {
                im_tag = false;
                aktuell.clear();
            }
            _ if im_tag => {}
            zeichen if zeichen.is_alphanumeric() => aktuell.push(zeichen.to_ascii_lowercase()),
            _ => {
                if aktuell.chars().count() >= 5 {
                    woerter.insert(std::mem::take(&mut aktuell));
                }
                aktuell.clear();
            }
        }
    }
    if aktuell.chars().count() >= 5 {
        woerter.insert(aktuell);
    }
    woerter
}

#[test]
fn korpus_mails_bleiben_vollstaendig() {
    let ordner = match korpus_ordner() {
        Ok(Some(ordner)) => ordner,
        Ok(None) => {
            // libtest fängt `print!`/`eprintln!` ab und zeigt sie bei grünen
            // Tests nicht. Der direkte Schreibzugriff auf stderr macht die
            // Auslassung sichtbar, sonst meldet ein Lauf ohne Korpus grün,
            // prüft aber nichts.
            let _ = writeln!(
                std::io::stderr(),
                "ÜBERSPRUNGEN korpus_mails_bleiben_vollstaendig: \
                 Korpus {} fehlt (CORAX_KORPUS setzen)",
                standard_korpus().display()
            );
            return;
        }
        Err(fehler) => panic!("{fehler}"),
    };
    let policy = Policy::default();
    let mut geprueft = 0usize;
    for eintrag in std::fs::read_dir(&ordner).expect("Korpus lesbar") {
        let pfad = eintrag.expect("Eintrag").path();
        if pfad.extension().and_then(|e| e.to_str()) != Some("html") {
            continue;
        }
        let name = pfad.file_name().unwrap_or_default().to_string_lossy().to_string();
        let roh = std::fs::read_to_string(&pfad).expect("Korpus-Datei lesbar");
        let out = sanitize(&roh, &policy);

        let erwartet = ohne_kommentare(&roh);
        assert_eq!(
            erwartet.matches("<style").count(),
            out.html.matches("<style").count(),
            "{name}: Stylesheet verloren"
        );
        assert_eq!(
            erwartet.matches("<img").count(),
            out.html.matches("<img").count(),
            "{name}: Bildanzahl verändert"
        );
        assert_eq!(out.blocked_remote, 0, "{name}: Korpus hat keine Remote-Bilder");
        assert!(
            out.removed.is_empty(),
            "{name}: nichts zu entfernen erwartet, war {:?}",
            out.removed
        );
        assert!(
            !out.html.to_ascii_lowercase().contains("<script"),
            "{name}: Skript stehen geblieben"
        );

        let vorher = sichtbare_woerter(&ohne_kommentare(&roh));
        let nachher = sichtbare_woerter(&out.html);
        let verloren: Vec<&String> = vorher.difference(&nachher).collect();
        let anteil = 1.0 - verloren.len() as f64 / vorher.len().max(1) as f64;
        assert!(
            anteil >= 0.98,
            "{name}: nur {:.1}% der sichtbaren Wörter erhalten, verloren z. B. {:?}",
            anteil * 100.0,
            &verloren[..verloren.len().min(8)]
        );
        geprueft += 1;
    }
    assert_eq!(geprueft, 5, "alle fünf Korpus-Mails prüfen");
}

#[test]
fn boesartiges_html_wird_entschaerft() {
    let boese = r##"<!doctype html>
<html><head>
  <title>Kopfzeile</title>
  <meta http-equiv="refresh" content="0;url=http://evil.example/">
  <meta charset="utf-8">
  <base href="http://evil.example/">
  <link rel="stylesheet" href="http://evil.example/x.css">
  <script>alert(1)</script>
</head><body onload="alert(2)">
  <p onclick="alert(3)" style="color:red">Text</p>
  <form action="http://evil.example/post"><input name="q"><button>Senden</button></form>
  <iframe src="http://evil.example/frame"></iframe>
  <object data="http://evil.example/o"></object>
  <a href="javascript:alert(4)">a</a>
  <a href="JaVaScRiPt:alert(5)">b</a>
  <img src="http://track.example/open?u=1" width="1" height="1">
  <img src="http://track.example/p.gif" style="display:none">
  <img src="http://cdn.example/bild.png" alt="Bild">
  <img src="cid:anhang@p" alt="Anhang">
  <script>alert(6)</script>
</body></html>"##;

    let out = sanitize(boese, &Policy::default());
    let zaehle = |art: &str| out.removed.iter().filter(|r| r.as_str() == art).count();

    assert_eq!(zaehle("script"), 2, "{:?}", out.removed);
    assert_eq!(zaehle("event-handler"), 2, "{:?}", out.removed);
    assert_eq!(zaehle("javascript-url"), 2, "{:?}", out.removed);
    assert_eq!(zaehle("form"), 1, "{:?}", out.removed);
    assert_eq!(zaehle("iframe"), 1, "{:?}", out.removed);
    assert_eq!(zaehle("object"), 1, "{:?}", out.removed);
    assert_eq!(zaehle("meta-refresh"), 1, "{:?}", out.removed);
    assert_eq!(zaehle("base"), 1, "{:?}", out.removed);
    assert_eq!(zaehle("link"), 1, "{:?}", out.removed);
    assert_eq!(zaehle("tracking-pixel"), 2, "{:?}", out.removed);

    // Ein echtes Remote-Bild bleibt gezählt, aber draußen; das cid-Bild bleibt.
    assert_eq!(out.blocked_remote, 1);
    assert!(out.html.contains("cid:anhang@p"));
    assert!(!out.html.contains("cdn.example"));
    assert!(!out.html.contains("track.example"));

    // Nichts Ausführbares mehr.
    let klein = out.html.to_ascii_lowercase();
    for verboten in [
        "<script",
        "onclick",
        "onload",
        "javascript:",
        "<form",
        "<iframe",
        "<object",
        "<base",
        "http-equiv=\"refresh\"",
        "<link",
    ] {
        assert!(!klein.contains(verboten), "„{verboten}“ steht noch drin");
    }
    // Sichtbarer Text bleibt.
    assert!(out.html.contains("Text"));
    assert!(out.html.contains("color:red"));
}

#[test]
fn policy_erlaubt_remote_bilder_laesst_pixel_weg() {
    let policy = Policy {
        remote_images: RemoteImages::Allowed,
        ..Policy::default()
    };
    let html = r#"<img src="https://cdn.example/bild.png"><img src="https://track.example/p.gif" height="1">"#;
    let out = sanitize(html, &policy);
    assert_eq!(out.blocked_remote, 0, "bei Allowed wird nichts blockiert");
    assert!(out.html.contains("cdn.example"));
    assert!(!out.html.contains("track.example"));
    assert_eq!(out.removed.iter().filter(|r| *r == "tracking-pixel").count(), 1);
}

#[test]
fn data_bilder_ueberleben_die_sanitisierung() {
    let html = r#"<img src="data:image/png;base64,iVBORw0KGgo=" alt="inline">"#;
    let out = sanitize(html, &Policy::default());
    assert!(out.html.contains("data:image/png;base64"), "{}", out.html);
    assert_eq!(out.blocked_remote, 0);
}
