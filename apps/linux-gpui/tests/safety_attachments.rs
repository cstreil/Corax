//! Abnahmefälle für A2 (`src/safety/attachments.rs`).
//!
//! Der Typenkatalog stammt aus dem Briefing §4; die Fälle hier sind die, die
//! Coder 1 vor `open_attachment` wirklich sieht. Die Einzelfälle stehen als
//! Unit-Tests in der Datei selbst.

#[path = "../src/safety/attachments.rs"]
mod attachments;

use attachments::{OpenDecision, check_attachment};

/// Alle Typen, die das Briefing mindestens blockiert oder gefragt haben will.
const BRIEFING_TYPEN: &[&str] = &[
    "desktop", "sh", "bash", "run", "AppImage", "jar", "exe", "msi", "bat", "cmd", "ps1", "py",
    "pl", "rb", "deb", "rpm", "flatpakref",
];

fn ist_eingriff(entscheidung: &OpenDecision) -> bool {
    matches!(entscheidung, OpenDecision::Ask { .. } | OpenDecision::Block { .. })
}

#[test]
fn jeder_typ_aus_dem_briefing_wird_abgefangen() {
    for endung in BRIEFING_TYPEN {
        let name = format!("anhang.{endung}");
        let entscheidung = check_attachment(&name, "application/octet-stream", b"harmlos");
        assert!(
            ist_eingriff(&entscheidung),
            "{name} müsste gefragt oder blockiert werden, war {entscheidung:?}"
        );
    }
}

#[test]
fn harmlose_dateien_bleiben_harmlos() {
    for (name, mime, kopf) in [
        ("urlaub.jpg", "image/jpeg", &b"\xff\xd8\xff\xe0"[..]),
        ("bericht.pdf", "application/pdf", &b"%PDF-1.7"[..]),
        ("notizen.txt", "text/plain", &b"Zeile eins"[..]),
        ("archiv.zip", "application/zip", &b"PK\x03\x04"[..]),
        ("ohne_endung", "application/octet-stream", &b"PK\x03\x04"[..]),
    ] {
        assert_eq!(
            check_attachment(name, mime, kopf),
            OpenDecision::Open,
            "{name} sollte direkt öffnen"
        );
    }
}

#[test]
fn ausfuehrbarer_inhalt_ohne_endung() {
    // ELF heißt `rechnung.pdf` — der Name täuscht, der Inhalt nicht.
    let elf = b"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00";
    assert!(matches!(
        check_attachment("rechnung.pdf", "application/pdf", elf),
        OpenDecision::Block { .. }
    ));

    // Shebang-Skript ohne Endung.
    assert!(matches!(
        check_attachment("rechnung", "text/plain", b"#!/usr/bin/env python3\n"),
        OpenDecision::Ask { .. }
    ));
}

#[test]
fn doppelte_endung_wird_erkannt() {
    let faelle = [
        ("rechnung.pdf.sh", OpenDecision::Block { reason: String::new() }),
        ("rechnung.sh.pdf", OpenDecision::Ask { reason: String::new() }),
        ("bild.jpg.exe", OpenDecision::Block { reason: String::new() }),
        ("bild.exe.jpg", OpenDecision::Ask { reason: String::new() }),
    ];
    for (name, erwartet) in faelle {
        let entscheidung = check_attachment(name, "", b"harmlos");
        assert_eq!(
            std::mem::discriminant(&entscheidung),
            std::mem::discriminant(&erwartet),
            "{name}: {entscheidung:?} statt {erwartet:?}"
        );
    }
}

#[test]
fn grund_wird_geliefert() {
    let OpenDecision::Block { reason } = check_attachment("start.sh", "", b"") else {
        panic!("start.sh muss blockiert werden");
    };
    assert!(!reason.trim().is_empty(), "Grund für den Hinweis fehlt");
    assert!(reason.contains("sh"), "Grund nennt die Endung nicht: {reason}");

    let OpenDecision::Ask { reason } = check_attachment("notiz", "text/plain", b"#!/bin/sh\n")
    else {
        panic!("Shebang muss nachfragen");
    };
    assert!(!reason.trim().is_empty());
}
