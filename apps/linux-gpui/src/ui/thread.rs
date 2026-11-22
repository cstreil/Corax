//! Der aufgeklappte Thread: Karte direkt unter der Liste, Körper über Blitz.
//!
//! Aufbau wie in der Mac-App (`ThreadDetailView`): Kopf mit Betreff und
//! Nachrichtenzahl, dann je Nachricht Absender, Empfänger, Datum, Körper und
//! Anhänge. Die Karte hat eine **exakt gerechnete Höhe** — daran hängt das
//! Scrollen nach dem Aufklappen (§4.4) und die Zeilenhöhe in der Liste.

use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

use gpui::prelude::*;
use gpui::*;

use crate::core::host::Request;
use crate::core::models::{AttachmentMeta, MessageDetail, ThreadDetail};
use crate::html::{RemoteImages, Resources};
use crate::html_view;
use crate::mailtext::{self, RichText};
use crate::state::AppState;
use crate::theme::mix;
use crate::theme::Theme;

/// Rand links/rechts der Karte in der Liste.
pub const KARTE_RAND: f32 = 8.0;
/// Innenabstand der Karte.
pub const KARTE_PAD: f32 = 12.0;
const KOPF_HOEHE: f32 = 46.0;
const MSG_GAP: f32 = 10.0;
const MSG_KOPF: f32 = 26.0;
const HINWEIS_HOEHE: f32 = 18.0;
const ANHANG_HOEHE: f32 = 26.0;

/// Eine fertig gebaute Karte (Bilder gerendert, Höhe bekannt).
#[derive(Clone)]
pub struct Karte {
    pub breite: f32,
    pub hoehe: f32,
    pub nachrichten: Vec<KarteNachricht>,
    pub ms: f64,
    pub bilder: usize,
    /// Externe Bilder, für die beim Zeichnen keine Bytes vorlagen (Einkaufsliste).
    pub fern: Vec<String>,
}

impl Karte {
    pub fn bilder_text(&self) -> String {
        format!("{} Bild(er)", self.bilder)
    }
}

#[derive(Clone)]
pub struct KarteNachricht {
    pub von: String,
    pub initialen: String,
    pub an: String,
    pub datum: String,
    pub ungelesen: bool,
    pub koerper: Koerper,
    pub anhaenge: Vec<AttachmentMeta>,
    pub blockiert: usize,
    /// Bilder werden gerade geholt (Hinweiszeile statt „Laden").
    pub laedt: bool,
    /// Bilder, die nicht geholt werden konnten (mit „erneut laden").
    pub fehler: usize,
}

#[derive(Clone)]
pub enum Koerper {
    Bild { bild: Arc<Image>, breite: f32, hoehe: f32 },
    Text { rich: RichText, hoehe: f32 },
    Leer { hoehe: f32 },
}

impl Koerper {
    pub fn hoehe(&self) -> f32 {
        match self {
            Koerper::Bild { hoehe, .. } => *hoehe,
            Koerper::Text { hoehe, .. } => *hoehe,
            Koerper::Leer { hoehe } => *hoehe,
        }
    }
}

/// Baut die Karte eines Threads: je Nachricht den Körper zeichnen und daraus
/// die exakte Höhe rechnen. `bilder` ist der Bild-Speicher der App (geteilte
/// [`Resources`]), `laedt` zeigt die Hinweiszeile „Bilder werden geladen …".
pub fn karte_bauen(
    detail: &ThreadDetail,
    breite: u32,
    remote: RemoteImages,
    basis: Option<&Path>,
    bilder: Arc<Resources>,
    laedt: bool,
    fehler_anzahl: usize,
    _theme: &Theme,
) -> Karte {
    let start = Instant::now();
    let b = breite as f32;
    let mut nachrichten = Vec::with_capacity(detail.messages.len());
    let mut bilder_anzahl = 0usize;
    let mut alle_fern: Vec<String> = Vec::new();

    for message in &detail.messages {
        let (koerper, blockiert, fern) =
            koerper_bauen(message, breite, remote, basis, Arc::clone(&bilder));
        if matches!(koerper, Koerper::Bild { .. }) {
            bilder_anzahl += 1;
        }
        alle_fern.extend(fern.iter().cloned());
        nachrichten.push(KarteNachricht {
            von: message.from.display(),
            initialen: message.from.initials(),
            an: empfaenger_zeile(message),
            datum: crate::ui::list::datum_lang(message.date),
            ungelesen: !message.is_read,
            koerper,
            anhaenge: message.attachments.clone(),
            blockiert,
            laedt: laedt && !fern.is_empty(),
            // Der Fehler gehört zur Mail, nicht zur Nachricht: nur wo noch
            // Bilder fehlen, steht die Zeile.
            fehler: if fern.is_empty() { 0 } else { fehler_anzahl },
        });
    }
    alle_fern.sort();
    alle_fern.dedup();

    let hoehe = karten_hoehe(&nachrichten);
    Karte {
        breite: b,
        hoehe,
        nachrichten,
        ms: start.elapsed().as_secs_f64() * 1000.0,
        bilder: bilder_anzahl,
        fern: alle_fern,
    }
}

/// Höhe der Karte aus ihren Teilen — dieselben Zahlen, die [`karte`] setzt.
fn karten_hoehe(nachrichten: &[KarteNachricht]) -> f32 {
    let mut hoehe = KARTE_PAD + KOPF_HOEHE;
    for nachricht in nachrichten {
        hoehe += MSG_GAP + MSG_KOPF + nachricht.koerper.hoehe();
        if nachricht.blockiert > 0 || nachricht.laedt || nachricht.fehler > 0 {
            hoehe += HINWEIS_HOEHE;
        }
        hoehe += nachricht.anhaenge.len() as f32 * ANHANG_HOEHE;
    }
    hoehe + KARTE_PAD + 2.0
}

fn koerper_bauen(
    message: &MessageDetail,
    breite: u32,
    remote: RemoteImages,
    basis: Option<&Path>,
    bilder: Arc<Resources>,
) -> (Koerper, usize, Vec<String>) {
    // `cid:`-Bilder sind kein Thema mehr: der Kern schreibt sie vor der
    // Auslieferung in `data:`-URIs um, die [`Resources`] selbst dekodiert.
    let policy = html_view::policy(remote);

    if let Some(html) = message.html_body.as_deref().filter(|html| !html.trim().is_empty()) {
        match html_view::rendere_html(html, breite, &policy, bilder, basis) {
            Ok(koerper) => {
                let blockiert = koerper.blockiert;
                let fern = koerper.fern.clone();
                let art = Koerper::Bild {
                    bild: koerper.bild,
                    breite: koerper.breite as f32,
                    hoehe: koerper.hoehe as f32,
                };
                return (art, blockiert, fern);
            }
            Err(error) => eprintln!("L1-HTML fehler: {error}"),
        }
    }

    // Reiner Text oder Rückfall: Text mit Auszeichnung, Höhe geschätzt.
    let text = message
        .text_body
        .clone()
        .filter(|text| !text.trim().is_empty())
        .unwrap_or_else(|| message.snippet.clone());
    if text.trim().is_empty() {
        return (Koerper::Leer { hoehe: 24.0 }, 0, Vec::new());
    }
    // Textkörper gehen denselben Weg wie HTML (Blitz), damit Zeilenumbrüche
    // und Schrift stimmen.
    match html_view::rendere_text(&text, breite) {
        Ok(koerper) => {
            let art = Koerper::Bild {
                bild: koerper.bild,
                breite: koerper.breite as f32,
                hoehe: koerper.hoehe as f32,
            };
            (art, 0, Vec::new())
        }
        Err(error) => {
            eprintln!("L1-TEXT fehler: {error}");
            let rich = mailtext::to_text(&text);
            let hoehe = text_hoehe(&rich.text, breite as f32);
            (Koerper::Text { rich, hoehe }, 0, Vec::new())
        }
    }
}

/// Grobe Höhe eines Textkörpers, wenn Blitz nicht zeichnen kann.
fn text_hoehe(text: &str, breite: f32) -> f32 {
    let zeichen_pro_zeile = (breite / 7.2).max(20.0);
    let mut zeilen = 0.0f32;
    for zeile in text.lines() {
        zeilen += (zeile.chars().count() as f32 / zeichen_pro_zeile).ceil().max(1.0);
    }
    (zeilen * 19.0 + 8.0).max(24.0)
}

/// „an mich", „an mich und 2 weitere" — wie in der Mac-App.
fn empfaenger_zeile(message: &MessageDetail) -> String {
    if message.is_outgoing {
        let namen: Vec<String> = message.to.iter().take(2).map(|a| a.display()).collect();
        if namen.is_empty() {
            "an niemanden".into()
        } else if message.to.len() > 2 {
            format!("an {}, …", namen.join(", "))
        } else {
            format!("an {}", namen.join(", "))
        }
    } else if message.cc.is_empty() {
        "an mich".into()
    } else {
        format!("an mich und {} weitere", message.cc.len())
    }
}

// ---------------------------------------------------------------- Rendern

/// Die Karte als Zeile in der Liste.
pub fn karte(
    state: &mut AppState,
    id: i64,
    hoehe: f32,
    window: &mut Window,
    cx: &mut Context<AppState>,
) -> AnyElement {
    let basis_stil = window.text_style();
    let theme = state.theme.clone();
    let Some(karte) = state.karten.get(&id).cloned() else {
        return div().h(px(hoehe)).into_any_element();
    };
    let Some(thread) = state.detail_von(id) else {
        return div().h(px(hoehe)).into_any_element();
    };

    let kopf = div()
        .h(px(KOPF_HOEHE))
        .w_full()
        .flex()
        .flex_row()
        .items_start()
        .gap_2()
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap_1()
                .child(
                    div()
                        .text_lg()
                        .text_color(rgb(theme.ink_strong()))
                        .truncate()
                        .child(thread.thread.subject.clone()),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(rgb(theme.ink3()))
                        .child(format!(
                            "{} Nachricht(en) · {}",
                            thread.messages.len(),
                            thread.thread.account_email
                        )),
                ),
        )
        .child(
            div()
                .flex_shrink_0()
                .text_xs()
                .text_color(rgb(theme.ink3()))
                .child("Esc schließt"),
        );

    let breite = karte.breite;
    let mut nachrichten = Vec::with_capacity(karte.nachrichten.len());
    for nachricht in &karte.nachrichten {
        nachrichten.push(nachricht_block(state, id, nachricht, breite, &theme, &basis_stil, cx));
    }

    div()
        .id(ElementId::Name(format!("karte-{id}").into()))
        .h(px(hoehe))
        .w_full()
        .flex()
        .flex_col()
        .overflow_hidden()
        .px(px(KARTE_PAD))
        .bg(rgb(theme.raised()))
        .border_1()
        .border_color(rgb(mix(theme.accent(), theme.line(), 0.35)))
        .rounded_md()
        .on_mouse_down(MouseButton::Left, cx.listener(|_state, _event, _window, _cx| {}))
        .child(
            div()
                .mx(px(KARTE_RAND))
                .flex()
                .flex_col()
                .child(kopf)
                .children(nachrichten),
        )
        .into_any_element()
}

fn nachricht_block(
    state: &mut AppState,
    thread_id: i64,
    nachricht: &KarteNachricht,
    _breite: f32,
    theme: &Theme,
    basis_stil: &TextStyle,
    cx: &mut Context<AppState>,
) -> AnyElement {
    let kopf = div()
        .h(px(MSG_KOPF))
        .flex()
        .flex_row()
        .items_center()
        .gap_2()
        .child(
            div()
                .flex_shrink_0()
                .size(px(20.))
                .rounded_full()
                .bg(rgb(mix(theme.accent(), theme.bg(), 0.55)))
                .flex()
                .items_center()
                .justify_center()
                .text_xs()
                .text_color(rgb(theme.ink_strong()))
                .child(nachricht.initialen.clone()),
        )
        .child(
            div()
                .flex_shrink_0()
                .text_sm()
                .text_color(rgb(if nachricht.ungelesen {
                    theme.ink_strong()
                } else {
                    theme.ink1()
                }))
                .when(nachricht.ungelesen, |this| this.font_weight(FontWeight::SEMIBOLD))
                .child(nachricht.von.clone()),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_xs()
                .text_color(rgb(theme.ink3()))
                .child(nachricht.an.clone()),
        )
        .child(
            div()
                .flex_shrink_0()
                .text_xs()
                .text_color(rgb(theme.ink3()))
                .child(nachricht.datum.clone()),
        );

    let koerper: AnyElement = match &nachricht.koerper {
        Koerper::Bild { bild, breite: b, hoehe } => div()
            .w_full()
            .flex()
            .justify_center()
            .child(img(bild.clone()).w(px(*b)).h(px(*hoehe)).flex_shrink_0())
            .into_any_element(),
        Koerper::Text { rich, hoehe } => {
            let mut highlights = Vec::new();
            for (range, kind) in &rich.ranges {
                let style = match kind {
                    mailtext::Emphasis::Bold => HighlightStyle {
                        font_weight: Some(FontWeight::BOLD),
                        ..Default::default()
                    },
                    mailtext::Emphasis::Italic => HighlightStyle {
                        font_style: Some(FontStyle::Italic),
                        ..Default::default()
                    },
                    mailtext::Emphasis::Link => HighlightStyle {
                        color: Some(rgb(theme.accent()).into()),
                        ..Default::default()
                    },
                };
                highlights.push((range.clone(), style));
            }
            let mut text_style = basis_stil.clone();
            text_style.font_family = theme.font();
            div()
                .h(px(*hoehe))
                .w_full()
                .overflow_hidden()
                .text_sm()
                .text_color(rgb(theme.ink2()))
                .child(
                    StyledText::new(rich.text.clone())
                        .with_default_highlights(&text_style, highlights),
                )
                .into_any_element()
        }
        Koerper::Leer { hoehe } => div().h(px(*hoehe)).into_any_element(),
    };

    let hinweis = if nachricht.laedt {
        Some(
            div()
                .h(px(HINWEIS_HOEHE))
                .flex()
                .items_center()
                .child(
                    div()
                        .text_xs()
                        .text_color(rgb(theme.ink2()))
                        .child("Bilder werden geladen …"),
                )
                .into_any_element(),
        )
    } else if nachricht.blockiert > 0 {
        let n = nachricht.blockiert;
        Some(
            div()
            .h(px(HINWEIS_HOEHE))
            .flex()
            .items_center()
            .gap_2()
            .child(
                div()
                    .text_xs()
                    .text_color(rgb(theme.yellow()))
                    .child(format!("{n} externe Bilder blockiert")),
            )
            .child(
                div()
                    .id(ElementId::Name(format!("bilder-laden-{thread_id}").into()))
                    .text_xs()
                    .text_color(rgb(theme.accent()))
                    .child("Laden")
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                            state.remote_laden(thread_id, cx);
                        }),
                    ),
            )
                .into_any_element(),
        )
    } else if nachricht.fehler > 0 {
        let n = nachricht.fehler;
        Some(
            div()
                .h(px(HINWEIS_HOEHE))
                .flex()
                .items_center()
                .gap_2()
                .child(
                    div()
                        .text_xs()
                        .text_color(rgb(theme.yellow()))
                        .child(format!(
                            "{n} Bild{} nicht ladbar",
                            if n == 1 { "" } else { "er" }
                        )),
                )
                .child(
                    div()
                        .id(ElementId::Name(format!("bilder-erneut-{thread_id}").into()))
                        .text_xs()
                        .text_color(rgb(theme.accent()))
                        .child("erneut laden")
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(move |state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                                state.remote_laden(thread_id, cx);
                            }),
                        ),
                )
                .into_any_element(),
        )
    } else {
        None
    };

    let anhaenge = nachricht.anhaenge.iter().map(|anhang| {
        anhang_zeile(state, anhang, theme, cx)
    });

    div()
        .mt(px(MSG_GAP))
        .flex()
        .flex_col()
        .w_full()
        .child(kopf)
        .children(hinweis)
        .child(koerper)
        .children(anhaenge)
        .into_any_element()
}

fn anhang_zeile(
    state: &mut AppState,
    anhang: &AttachmentMeta,
    theme: &Theme,
    cx: &mut Context<AppState>,
) -> AnyElement {
    let id = anhang.id;
    let art = anhang.kind();
    let ist_bild = anhang.mime_type.as_deref().unwrap_or("").starts_with("image/");
    let farbe = if ist_bild { theme.accent() } else { theme.red() };
    let _ = state;
    div()
        .id(ElementId::Name(format!("anhang-{id}").into()))
        .h(px(ANHANG_HOEHE))
        .mt(px(4.))
        .flex()
        .flex_row()
        .items_center()
        .gap_2()
        .child(
            div()
                .flex_shrink_0()
                .px_1()
                .rounded_sm()
                .bg(rgb(farbe))
                .text_xs()
                .text_color(rgb(theme.bg()))
                .child(art),
        )
        .child(div().text_xs().text_color(rgb(theme.ink1())).child(anhang.name()))
        .child(
            div()
                .text_xs()
                .text_color(rgb(theme.ink3()))
                .child(anhang.size_text()),
        )
        .child(
            div()
                .text_xs()
                .text_color(rgb(theme.accent()))
                .child("öffnen")
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |state: &mut AppState, _event: &MouseDownEvent, _window, _cx| {
                        state.kern.request(Request::OpenAttachment(id));
                    }),
                ),
        )
        .into_any_element()
}

// ------------------------------------------------------------- Scrollen

/// Wie weit gescrollt wird, damit die Karte so gut wie möglich sichtbar ist
/// (Port von `ListReveal.revealTop`, `CoraxKit/Support/ListReveal.swift`).
///
/// - `row_top` Oberkante der Thread-Zeile, `above_top` Oberkante der Zeile
///   darüber, `card_bottom` Unterkante der Karte, `below_h` Höhe der Zeile
///   darunter.
/// - Rückgabe: das y, das oben im sichtbaren Bereich stehen soll; `None` =
///   nicht scrollen.
pub fn reveal_top(
    row_top: f32,
    above_top: f32,
    card_bottom: f32,
    below_h: f32,
    visible_min: f32,
    visible_height: f32,
) -> Option<f32> {
    if visible_height <= 0.0 {
        return None;
    }
    // So weit, dass die Karte plus eine Zeile darunter am unteren Rand endet.
    let want = card_bottom + below_h - visible_height;
    // Nicht unter die Oberkante und nie über die Zeile darüber hinaus.
    let mut top = want.max(visible_min).min(above_top);
    // Oben angeschnitten: die Zeile darüber ist das Höchste der Gefühle.
    if row_top < visible_min {
        top = above_top;
    }
    // Steht schon richtig (Rundung der Layoutwerte).
    if (top - visible_min).abs() <= 1.0 {
        return None;
    }
    Some(top)
}

#[cfg(test)]
mod tests {
    // Nur die gerechnete Funktion importieren: `super::*` würde `gpui::test`
    // über das eingebaute `#[test]` legen.
    use super::reveal_top;

    #[test]
    fn kleine_mail_wird_ganz_gezeigt() {
        // Sicht 1000 hoch, Zeile bei 500, Karte 200 hoch, eine Zeile darunter.
        let top = reveal_top(500.0, 400.0, 500.0 + 76.0 + 200.0, 76.0, 0.0, 1000.0);
        // want = 776 + 76 - 1000 < 0 → auf visible_min begrenzt → kein Scrollen.
        assert_eq!(top, None);
    }

    #[test]
    fn lange_mail_laesst_eine_zeile_darueber_stehen() {
        // Karte 5000 hoch: nicht alles passt, oben bleibt die Zeile darüber.
        let top = reveal_top(500.0, 400.0, 500.0 + 76.0 + 5000.0, 76.0, 0.0, 900.0);
        assert_eq!(top, Some(400.0));
    }

    #[test]
    fn mittlere_mail_nie_ueber_die_zeile_darueber() {
        // Sicht 900, Karte 700: want = 1276 + 76 - 900 = 452, aber die Zeile
        // darüber (400) ist die Obergrenze — dieselbe Regel wie `ListReveal`.
        let top = reveal_top(500.0, 400.0, 500.0 + 76.0 + 700.0, 76.0, 0.0, 900.0);
        assert_eq!(top, Some(400.0));
    }

    #[test]
    fn angeschnittene_zeile_scrollt_auf_ihre_oberkante() {
        // Zeile beginnt über dem sichtbaren Bereich (row_top < visible_min).
        let top = reveal_top(-50.0, -126.0, -50.0 + 76.0 + 700.0, 76.0, 0.0, 900.0);
        assert_eq!(top, Some(-126.0));
    }

    #[test]
    fn ohne_platz_wird_nicht_gescrollt() {
        assert_eq!(reveal_top(0.0, 0.0, 100.0, 0.0, 0.0, 0.0), None);
    }
}
