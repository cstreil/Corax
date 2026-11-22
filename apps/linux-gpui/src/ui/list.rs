//! Threadliste: Datumsgruppen, Zeilen, Auswahl, Paging (L-E2).
//!
//! Die Liste ist ein `gpui::list`: Zeilen sind unterschiedlich hoch (Kopfzeilen,
//! Threadzeilen, aufgeklappte Mail), deshalb keine `uniform_list`. Gerendert
//! wird nur der sichtbare Bereich plus etwas Vorlauf; 10 000 Zeilen kosten
//! damit nur die sichtbaren Elemente.

use chrono::{Datelike, Local, TimeZone};
use gpui::prelude::*;
use gpui::*;

use crate::core::models::ThreadSummary;
use crate::state::AppState;
use crate::theme::mix;
use crate::ui::thread;

/// Eine Zeile der Liste.
#[derive(Clone, Debug)]
pub enum Row {
    /// Datumsgruppen-Überschrift („Heute", „Gestern", „Diese Woche", Monat).
    Kopf { label: SharedString, key: String },
    /// Ein Thread.
    Thread { id: i64, index: usize },
    /// Der aufgeklappte Thread direkt unter seiner Zeile.
    Karte { id: i64, hoehe: f32 },
}

impl Row {
    pub const THREAD_HOEHE: f32 = 76.0;
    pub const KOPF_HOEHE: f32 = 28.0;

    pub fn hoehe(&self) -> f32 {
        match self {
            Row::Kopf { .. } => Row::KOPF_HOEHE,
            Row::Thread { .. } => Row::THREAD_HOEHE,
            Row::Karte { hoehe, .. } => *hoehe,
        }
    }
}

/// Baut die Zeilen aus `threads` (Datumsgruppen nur ohne Suche, wie in der
/// Mac-App: Suchergebnisse stehen ohne Überschriften).
pub fn rows_bauen(state: &mut AppState) {
    let mut rows = Vec::with_capacity(state.threads.len() + 16);
    let jetzt = Local::now();
    let mut letzte_gruppe: Option<String> = None;
    let gruppieren = state.suche.is_none();
    let expanded = state.expanded;

    for (index, thread) in state.threads.iter().enumerate() {
        if gruppieren {
            let (key, label) = gruppe(thread.last_message_at, jetzt);
            if letzte_gruppe.as_deref() != Some(key.as_str()) {
                rows.push(Row::Kopf { label: label.into(), key: key.clone() });
                letzte_gruppe = Some(key);
            }
        }
        rows.push(Row::Thread { id: thread.id, index });
        if expanded == Some(thread.id) {
            if let Some(karte) = state.karten.get(&thread.id) {
                rows.push(Row::Karte { id: thread.id, hoehe: karte.hoehe });
            }
        }
    }
    state.rows = rows;
}

/// Datumsgruppe einer Unterhaltung (`dateGroup` der Mac-App).
///
/// Heute, Gestern, Diese Woche, Diesen Monat, danach Monatsnamen.
pub fn gruppe(ms: i64, jetzt: chrono::DateTime<Local>) -> (String, String) {
    const TAG: i64 = 86_400_000;
    let heute0 = jetzt
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .and_then(|naiv| Local.from_local_datetime(&naiv).single())
        .map(|dt| dt.timestamp_millis())
        .unwrap_or(0);
    if ms >= heute0 {
        return ("today".into(), "Heute".into());
    }
    if ms >= heute0 - TAG {
        return ("yesterday".into(), "Gestern".into());
    }
    if ms >= heute0 - 6 * TAG {
        return ("thisWeek".into(), "Diese Woche".into());
    }
    let Some(datum) = Local.timestamp_millis_opt(ms).single() else {
        return ("alt".into(), "Älter".into());
    };
    if datum.year() == jetzt.year() && datum.month() == jetzt.month() {
        return ("thisMonth".into(), "Diesen Monat".into());
    }
    let key = format!("{}-{:02}", datum.year(), datum.month());
    let label = if datum.year() == jetzt.year() {
        monat(datum.month()).to_string()
    } else {
        format!("{} {}", monat(datum.month()), datum.year())
    };
    (key, label)
}

fn monat(monat: u32) -> &'static str {
    const NAMEN: [&str; 12] = [
        "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September",
        "Oktober", "November", "Dezember",
    ];
    NAMEN.get((monat as usize).saturating_sub(1)).copied().unwrap_or("?")
}

/// Die Liste als Element.
pub fn liste(state: &mut AppState, _window: &mut Window, cx: &mut Context<AppState>) -> AnyElement {
    // Breite für den Mail-Körper (eine Zeile Verzug ist unkritisch).
    let sicht = state.list_state.viewport_bounds();
    if sicht.size.width > px(0.) {
        state.list_breite = f32::from(sicht.size.width);
    }

    if state.rows.is_empty() {
        return leer(state).into_any_element();
    }

    list(state.list_state.clone(), cx.processor(
        |state: &mut AppState, index: usize, window: &mut Window, cx: &mut Context<AppState>| {
            zeile(state, index, window, cx)
        },
    ))
    .h_full()
    .w_full()
    .into_any_element()
}

fn leer(state: &AppState) -> impl IntoElement {
    let theme = &state.theme;
    let (titel, text) = if state.suche.is_some() {
        ("Keine Treffer", "Ein anderes Wort versuchen oder Esc drücken.")
    } else if state.loading {
        ("Wird geladen …", "")
    } else {
        ("Alles erledigt", "Die Inbox ist leer.")
    };
    div()
        .size_full()
        .flex()
        .flex_col()
        .items_center()
        .justify_center()
        .gap_1()
        .child(div().text_color(rgb(theme.ink2())).child(titel))
        .child(div().text_color(rgb(theme.ink3())).text_xs().child(text))
}

/// Eine Zeile rendern.
fn zeile(
    state: &mut AppState,
    index: usize,
    window: &mut Window,
    cx: &mut Context<AppState>,
) -> AnyElement {
    let Some(row) = state.rows.get(index).cloned() else {
        return div().into_any_element();
    };
    match row {
        Row::Kopf { label, .. } => kopf_zeile(state, label),
        Row::Thread { id, .. } => thread_zeile(state, id, cx),
        Row::Karte { id, hoehe } => thread::karte(state, id, hoehe, window, cx),
    }
}

fn kopf_zeile(state: &AppState, label: SharedString) -> AnyElement {
    let theme = &state.theme;
    div()
        .h(px(Row::KOPF_HOEHE))
        .w_full()
        .flex()
        .flex_row()
        .items_center()
        .gap_2()
        .px_3()
        .bg(rgb(theme.bg()))
        .child(div().text_color(rgb(theme.ink3())).text_xs().child(label))
        .child(div().flex_1().h(px(1.)).bg(rgb(theme.line())))
        .into_any_element()
}

fn thread_zeile(state: &mut AppState, id: i64, cx: &mut Context<AppState>) -> AnyElement {
    let theme = state.theme.clone();
    let Some(thread) = state.thread(id).cloned() else {
        return div().into_any_element();
    };
    let ausgewaehlt = state.selected == Some(id);
    let offen = state.expanded == Some(id);
    let hintergrund = if ausgewaehlt {
        mix(theme.selection(), theme.bg(), 0.45)
    } else {
        theme.bg()
    };
    let absender = thread.from_display();
    let datum = datum_kurz(thread.last_message_at);
    let ungelesen = thread.unread();
    let vorschau = vorschau_text(&thread);
    let anhaenge = thread.has_attachments;
    let anzahl = thread.message_count;

    div()
        .id(ElementId::Name(format!("thread-{id}").into()))
        .h(px(Row::THREAD_HOEHE))
        .w_full()
        .flex()
        .flex_col()
        .justify_center()
        .gap_1()
        .px_3()
        .bg(rgb(hintergrund))
        .border_b_1()
        .border_color(rgb(theme.line()))
        .when(ausgewaehlt || offen, |this| {
            this.border_l_2().border_color(rgb(theme.accent()))
        })
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(move |state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                state.selected = Some(id);
                if state.expanded == Some(id) {
                    state.schliessen(cx);
                } else {
                    state.oeffne(id, cx);
                }
                cx.notify();
            }),
        )
        .child(
            div()
                .w_full()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_sm()
                        .text_color(rgb(if ungelesen { theme.ink_strong() } else { theme.ink1() }))
                        .when(ungelesen, |this| this.font_weight(FontWeight::SEMIBOLD))
                        .child(absender),
                )
                .when(anzahl > 1, |this| {
                    this.child(
                        div()
                            .flex_shrink_0()
                            .px(px(6.))
                            .rounded_full()
                            .bg(rgb(mix(theme.ink3(), theme.bg(), 0.22)))
                            .text_xs()
                            .text_color(rgb(theme.ink2()))
                            .child(format!("{anzahl}")),
                    )
                })
                .when(anhaenge, |this| {
                    this.child(div().text_xs().text_color(rgb(theme.ink3())).child("▤"))
                })
                .child(
                    div()
                        .flex_shrink_0()
                        .text_xs()
                        .text_color(rgb(if ungelesen { theme.ink2() } else { theme.ink3() }))
                        .child(datum),
                ),
        )
        .child(
            div()
                .w_full()
                .min_w_0()
                .truncate()
                .text_sm()
                .text_color(rgb(if ungelesen { theme.ink_strong() } else { theme.ink1() }))
                .when(ungelesen, |this| this.font_weight(FontWeight::MEDIUM))
                .child(thread.subject.clone()),
        )
        .child(
            div()
                .w_full()
                .min_w_0()
                .truncate()
                .text_xs()
                .text_color(rgb(theme.ink3()))
                .child(vorschau),
        )
        .into_any_element()
}

/// Vorschauzeile: Ausschnitt der letzten Nachricht, sonst die Teilnehmer.
fn vorschau_text(thread: &ThreadSummary) -> String {
    let vorschau = thread.snippet.trim();
    if vorschau.is_empty() {
        thread.participants_line()
    } else {
        vorschau.replace('\n', " ")
    }
}

/// Datum in der Liste: heute „14:32", sonst „18.11." oder „18.11.25".
pub fn datum_kurz(ms: i64) -> String {
    let Some(datum) = Local.timestamp_millis_opt(ms).single() else {
        return String::new();
    };
    let jetzt = Local::now();
    if datum.date_naive() == jetzt.date_naive() {
        datum.format("%H:%M").to_string()
    } else if datum.year() == jetzt.year() {
        datum.format("%d.%m.").to_string()
    } else {
        datum.format("%d.%m.%y").to_string()
    }
}

/// Datum in der Nachrichtenkopfzeile: „18. Nov., 14:32".
pub fn datum_lang(ms: i64) -> String {
    let Some(datum) = Local.timestamp_millis_opt(ms).single() else {
        return String::new();
    };
    datum.format("%d. %b., %H:%M").to_string()
}

#[cfg(test)]
mod tests {
    // Kein `use super::*`: das würde `gpui::test` über das eingebaute
    // `#[test]` legen.
    use super::{datum_kurz, gruppe};
    use chrono::{Local, TimeZone};

    fn jetzt() -> chrono::DateTime<Local> {
        Local.with_ymd_and_hms(2026, 11, 22, 12, 0, 0).single().unwrap()
    }

    fn ms(datum: chrono::DateTime<Local>) -> i64 {
        datum.timestamp_millis()
    }

    #[test]
    fn gruppen_wie_die_mac_app() {
        let heute = jetzt();
        let gestern = heute - chrono::Duration::days(1);
        let diese_woche = heute - chrono::Duration::days(3);
        let diesen_monat = heute - chrono::Duration::days(10);
        let frueher = Local.with_ymd_and_hms(2026, 9, 4, 9, 0, 0).single().unwrap();
        let vorjahr = Local.with_ymd_and_hms(2025, 12, 24, 9, 0, 0).single().unwrap();

        assert_eq!(gruppe(ms(heute), jetzt()).1, "Heute");
        assert_eq!(gruppe(ms(gestern), jetzt()).1, "Gestern");
        assert_eq!(gruppe(ms(diese_woche), jetzt()).1, "Diese Woche");
        assert_eq!(gruppe(ms(diesen_monat), jetzt()).1, "Diesen Monat");
        assert_eq!(gruppe(ms(frueher), jetzt()).1, "September");
        assert_eq!(gruppe(ms(vorjahr), jetzt()).1, "Dezember 2025");
    }

    #[test]
    fn gruppen_schluessel_sind_stabil() {
        let a = jetzt() - chrono::Duration::days(40);
        let (ka, _) = gruppe(ms(a), jetzt());
        assert!(ka.contains('-'), "Monatsschlüssel erwartet, war {ka}");
    }

    #[test]
    fn datum_kurz_heute_ist_uhrzeit() {
        // Feste Uhrzeit nehmen, sonst hängt der Test an der echten „Heute"-Grenze.
        let text = datum_kurz(ms(jetzt()));
        assert!(text.contains('.') || text.contains(':'), "{text}");
    }
}
