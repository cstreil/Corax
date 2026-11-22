//! Test-Hooks für Messläufe auf Tarantino (§4.10), nur mit `--features test-hooks`.
//!
//! Die Hooks lesen eine Befehlsdatei (`$CORAX_CMD`), Zeile für Zeile, und
//! steuern die App so, wie es eine Hand täte: öffnen, tippen, scrollen, Theme
//! wechseln. Im Release-Build ist dieses Modul nicht enthalten.

use std::path::PathBuf;
use std::time::Instant;

use chrono::Local;
use gpui::Context;

use crate::core::models::{Address, MessageDetail, ThreadSummary};
use crate::perf;
use crate::state::AppState;
use crate::theme::Theme;

pub fn poll(state: &mut AppState, cx: &mut Context<AppState>) {
    let Some(pfad) = std::env::var("CORAX_CMD").ok().map(PathBuf::from) else {
        return;
    };
    let Ok(meta) = std::fs::metadata(&pfad) else { return };
    let len = meta.len();
    if len <= state.hook_pos {
        return;
    }
    let Ok(text) = std::fs::read_to_string(&pfad) else { return };
    let start = (state.hook_pos as usize).min(text.len());
    let frisch = text[start..].to_string();
    state.hook_pos = len;
    for zeile in frisch.lines() {
        befehl(state, zeile.trim(), cx);
    }
}

fn befehl(state: &mut AppState, zeile: &str, cx: &mut Context<AppState>) {
    if zeile.is_empty() {
        return;
    }
    if let Some(pfad) = zeile.strip_prefix("bild:").map(str::trim) {
        // Körper-Bild der offenen Mail als PNG ablegen (Beleg für den Bericht).
        if let Some(id) = state.expanded {
            if let Some(karte) = state.karten.get(&id) {
                if let Some(nachricht) = karte.nachrichten.first() {
                    match &nachricht.koerper {
                        crate::ui::thread::Koerper::Bild { bild, .. } => {
                            match std::fs::write(pfad, &bild.bytes) {
                                Ok(()) => eprintln!("L1-BILD {pfad} {} B", bild.bytes.len()),
                                Err(error) => eprintln!("L1-BILD fehler: {error}"),
                            }
                        }
                        _ => eprintln!("L1-BILD kein Bild"),
                    }
                }
            }
        }
        return;
    }
    if zeile == "cache-leeren" {
        // Für Messreihen: jede Messung soll wieder frisch rendern.
        state.karten.clear();
        return;
    }
    if let Some(nummer) = zeile.strip_prefix("korpus:") {
        korpus_oeffnen(state, nummer.trim(), cx);
        return;
    }
    if let Some(url) = zeile.strip_prefix("extern:").map(str::trim) {
        // Mail mit entferntem Bild: prüft „Laden" ohne echte Maildaten.
        extern_oeffnen(state, url, cx);
        return;
    }
    if zeile == "laden" {
        // „Laden" in der Hinweiszeile, wie ein Klick darauf.
        if let Some(id) = state.expanded {
            state.remote_laden(id, cx);
        }
        return;
    }
    if let Some(n) = zeile.strip_prefix("fill:") {
        let n: usize = n.trim().parse().unwrap_or(10_000);
        state.synthetisch = Some(synthetische_threads(n));
        state.laden(cx);
        eprintln!("L1-FILL n={n}");
        return;
    }
    if let Some(n) = zeile.strip_prefix("bench:") {
        let n: usize = n.trim().parse().unwrap_or(300);
        state.messlauf_starten("liste".into(), n, cx);
        return;
    }
    if let Some(name) = zeile.strip_prefix("theme:") {
        // Ein Theme aus ~/.config/omarchy/themes ansehen, ohne die Sitzung
        // umzustellen; `theme-sitzung:` gibt die Sitzung wieder frei.
        let theme = Theme::load_named(name.trim());
        eprintln!("L1-THEME-HOOK name={} farben={}", theme.name, theme.colors.len());
        state.theme_override = Some(name.trim().to_string());
        state.theme_setzen(theme, cx);
        return;
    }
    if zeile == "theme-sitzung:" {
        state.theme_override = None;
        let theme = Theme::load();
        state.theme_setzen(theme, cx);
        return;
    }
    if let Some(dims) = zeile.strip_prefix("size:") {
        if let Some((w, h)) = dims.split_once('x') {
            if let (Ok(w), Ok(h)) = (w.trim().parse::<f32>(), h.trim().parse::<f32>()) {
                state.pending_size = Some((w, h));
                cx.notify();
            }
        }
        return;
    }
    if let Some(text) = zeile.strip_prefix("type:") {
        state.suchfeld.update(cx, |field, cx| {
            field.type_text(text);
            cx.notify();
        });
        return;
    }
    match zeile {
        "j" => state.bewegen(1, cx),
        "k" => state.bewegen(-1, cx),
        "open" | "enter" => state.oeffnen_oder_schliessen(cx),
        "esc" => state.schliessen(cx),
        "search" => state.suche_starten(cx),
        "search-aus" => state.suche_ausfuehren(cx),
        "search-zu" => state.suche_beenden(cx),
        "help" => {
            state.hilfe = !state.hilfe;
            cx.notify();
        }
        "sidebar" => {
            state.seitenleiste = !state.seitenleiste;
            cx.notify();
        }
        "inbox" => state.gehe_zu(crate::core::models::MailView::Inbox, cx),
        "top" => state.an_den_rand(true, cx),
        "ende" => state.an_den_rand(false, cx),
        "stats" => {
            let stats = perf::frame_stats();
            eprintln!("L1-FRAMES {}", stats.zeile());
        }
        "dump" => dump(state),
        "quit" => {
            eprintln!("L1-ENDE ms={:.1}", perf::seit_start_ms());
            std::process::exit(0);
        }
        anderes => {
            state.status = format!("unbekannter Hook: {anderes}").into();
            cx.notify();
        }
    }
}

fn dump(state: &AppState) {
    let offen = state
        .expanded
        .and_then(|id| state.karten.get(&id).map(|karte| (id, karte.hoehe)))
        .map(|(id, hoehe)| format!("{id}:{hoehe:.0}"))
        .unwrap_or_else(|| "-".into());
    eprintln!(
        "L1-DUMP threads={} rows={} auswahl={:?} offen={} suche={:?} theme={} ansicht={}",
        state.threads.len(),
        state.rows.len(),
        state.selected,
        offen,
        state.suche,
        state.theme.name,
        state.view.name()
    );
}

/// Korpus-Mail öffnen: als eigenen Thread vorn in die Liste, dann aufklappen.
fn korpus_oeffnen(state: &mut AppState, nummer: &str, cx: &mut Context<AppState>) {
    // Ab hier läuft die Uhr: dieselbe Strecke wie ein echtes Öffnen (Datei
    // lesen, Sanitizer, Blitz, Zeile setzen, Frame).
    let start = Instant::now();
    let dateien = [
        "01-newsletter-shop.html",
        "02-newsletter-welcome.html",
        "03-bilder-galerie.html",
        "04-lange-mail.html",
        "05-transaktionsmail.html",
    ];
    let index: usize = nummer.parse::<usize>().unwrap_or(1).saturating_sub(1);
    let datei = dateien.get(index).copied().unwrap_or(dateien[0]);
    let ordner = state
        .korpus
        .clone()
        .unwrap_or_else(|| PathBuf::from(format!("{}/korpus", std::env::var("HOME").unwrap_or_default())));
    let pfad = ordner.join(datei);
    let html = match std::fs::read_to_string(&pfad) {
        Ok(html) => html,
        Err(error) => {
            eprintln!("L1-KORPUS fehler {}: {error}", pfad.display());
            return;
        }
    };

    mail_oeffnen(
        state,
        format!("L1-KORPUS datei={datei}"),
        900_000 + index as i64 + 1,
        datei,
        html,
        start,
        cx,
    );
}

/// Mail mit einem entfernten Bild: derselbe Weg wie oben, nur ohne Datei.
fn extern_oeffnen(state: &mut AppState, url: &str, cx: &mut Context<AppState>) {
    if url.is_empty() {
        eprintln!("L1-EXTERN ohne Adresse");
        return;
    }
    let start = Instant::now();
    let html = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><style>\
         body{{margin:16px;font:15px/1.6 system-ui,sans-serif;color:#1b1b1b;background:#fff}}\
         h1{{font-size:20px;margin:0 0 8px}}p{{margin:0 0 10px}}\
         img{{max-width:420px;height:auto;border:1px solid #ddd;border-radius:8px}}</style>\
         </head><body><h1>Entferntes Bild</h1>\
         <p>Dieser Körper verweist auf ein Bild im Netz — die Policy blockt es zuerst.</p>\
         <img src=\"{url}\" alt=\"fern\">\
         <p>Darunter steht Text, damit die Körperhöhe nach dem Laden sichtbar bleibt.</p>\
         </body></html>"
    );
    mail_oeffnen(
        state,
        format!("L1-EXTERN url={url}"),
        995_001,
        "Entferntes Bild",
        html,
        start,
        cx,
    );
}

/// Gemeinsamer Weg der Hook-Mails: vorn in die Liste, Karte bauen, aufklappen.
fn mail_oeffnen(
    state: &mut AppState,
    marke: String,
    id: i64,
    betreff: &str,
    html: String,
    start: Instant,
    cx: &mut Context<AppState>,
) {
    let jetzt = Local::now().timestamp_millis();
    let summary = ThreadSummary {
        id,
        account_id: 1,
        account_email: "sandbox@example.test".into(),
        subject: betreff.to_string(),
        snippet: "Testmail aus dem Hook".into(),
        participants: vec![Address { name: Some("Test".into()), email: "test@example.test".into() }],
        last_message_at: jetzt,
        message_count: 1,
        unread_count: 1,
        is_starred: false,
        has_attachments: false,
        snoozed_until: None,
        labels: Vec::new(),
    };
    let message = MessageDetail {
        id,
        thread_id: id,
        account_id: 1,
        from: Address { name: Some("Test".into()), email: "test@example.test".into() },
        to: vec![Address { name: Some("Christian".into()), email: "sandbox@example.test".into() }],
        cc: Vec::new(),
        subject: betreff.to_string(),
        date: jetzt,
        is_read: false,
        is_starred: false,
        is_draft: false,
        is_outgoing: false,
        snippet: String::new(),
        body_state: "ready".into(),
        text_body: None,
        html_body: Some(html),
        attachments: Vec::new(),
    };
    let detail = crate::core::models::ThreadDetail { thread: summary.clone(), messages: vec![message] };

    state.threads.retain(|thread| thread.id != id);
    state.threads.insert(0, summary);
    let alt = state.rows.len();
    crate::ui::list::rows_bauen(state);
    let neu = state.rows.len();
    state.list_state.splice(0..alt, neu);

    let breite = state.koerper_breite();
    let karte = crate::ui::thread::karte_bauen(
        &detail,
        breite,
        crate::html::RemoteImages::Blocked,
        state.korpus.as_deref(),
        std::sync::Arc::clone(&state.bilder),
        false,
        0,
        &state.theme,
    );
    eprintln!(
        "{marke} ms={:.1} hoehe={:.0} bilder={} blockiert={} fern={}",
        karte.ms,
        karte.hoehe,
        karte.bilder,
        karte.nachrichten.iter().map(|n| n.blockiert).sum::<usize>(),
        karte.fern.len()
    );
    state.details.insert(id, detail);
    state.karten.insert(id, karte);
    state.offen_seit = Some((id, start));
    state.oeffne(id, cx);
}

/// Synthetische Liste für die 10 000-Zeilen-Messung.
fn synthetische_threads(anzahl: usize) -> Vec<ThreadSummary> {
    let absender = [
        "Jana Peters", "iCloud", "GitHub", "Deutsche Bahn", "Mira Sanft", "Heise online",
        "Daniel Roth", "Postbank", "KDE e.V.", "Omarchy",
    ];
    let betreffe = [
        "Runde 3 zum Rebranding",
        "Ihre Rechnung für November",
        "Pull request #482 kommentiert",
        "Ihre Reise nach Berlin",
        "Wochenplan",
        "KI-Modelle im Vergleich",
        "Termin am Donnerstag",
        "Kontoauszug bereit",
        "Mitgliederversammlung",
        "Theme-Vorschau",
    ];
    let jetzt = Local::now().timestamp_millis();
    const TAG: i64 = 86_400_000;
    (0..anzahl)
        .map(|i| ThreadSummary {
            id: 1_000_000 + i as i64,
            account_id: 1,
            account_email: "sandbox@example.test".into(),
            subject: format!("{} ({})", betreffe[i % betreffe.len()], i + 1),
            snippet: "Vorschau der Nachricht, zwei Zeilen im Stil der Mac-App mit ruhiger Farbe …".into(),
            participants: vec![Address {
                name: Some(absender[i % absender.len()].to_string()),
                email: format!("absender{}@example.test", i % absender.len()),
            }],
            // Über die letzten 12 Monate verteilt, damit die Datumsgruppen greifen.
            last_message_at: jetzt - ((i as i64 % 360) * TAG) - ((i as i64 % 97) * 61_000),
            message_count: 1 + (i as i64 % 4),
            unread_count: if i % 7 == 0 { 1 } else { 0 },
            is_starred: i % 23 == 0,
            has_attachments: i % 11 == 0,
            snoozed_until: None,
            labels: Vec::new(),
        })
        .collect()
}
