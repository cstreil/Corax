//! Kopfzeile mit Suche und Tabs, Fußzeile mit Status, Kürzel-Overlay.
//!
//! Die Kopfzeile ist bewusst schmal und ruhig (Omarchy-Mock-up): Marke, wo man
//! ist, Suche, Zähler. Alles Weitere steht in der Fußzeile.

use gpui::prelude::*;
use gpui::*;

use crate::keys;
use crate::state::{AppState, Tab};
use crate::theme::mix;
use crate::ui::sidebar::hex_farbe;

const KOPF_HOEHE: f32 = 44.0;
const FUSS_HOEHE: f32 = 24.0;

pub fn toolbar(state: &mut AppState, _window: &mut Window, cx: &mut Context<AppState>) -> AnyElement {
    let theme = state.theme.clone();
    let titel = if let Some(suche) = &state.suche {
        format!("Suche: {suche}")
    } else if let Some(id) = state.label_id {
        state
            .labels
            .iter()
            .find(|label| label.id == id)
            .map(|label| label.name.clone())
            .unwrap_or_else(|| "Label".into())
    } else {
        state.view.name().to_string()
    };
    let anzahl = state.threads.len();
    let tabs: Vec<Tab> = state.tabs();

    let mut kinder: Vec<AnyElement> = Vec::new();
    kinder.push(
        div()
            .id("seitenleiste-knopf")
            .flex_shrink_0()
            .px_2()
            .py_1()
            .rounded_sm()
            .text_color(rgb(theme.ink2()))
            .when(!state.seitenleiste, |this| this.text_color(rgb(theme.ink3())))
            .child("☰")
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                    state.seitenleiste = !state.seitenleiste;
                    cx.notify();
                }),
            )
            .into_any_element(),
    );
    kinder.push(
        div()
            .flex_shrink_0()
            .text_sm()
            .text_color(rgb(theme.accent()))
            .child("corax")
            .into_any_element(),
    );
    kinder.push(
        div()
            .flex_shrink_0()
            .text_sm()
            .text_color(rgb(theme.ink_strong()))
            .child(titel)
            .into_any_element(),
    );
    kinder.push(
        div()
            .flex_shrink_0()
            .text_xs()
            .text_color(rgb(theme.ink3()))
            .child(format!("{anzahl}"))
            .into_any_element(),
    );

    for (index, tab) in tabs.iter().enumerate() {
        let aktiv = index == state.tab;
        let id = tab.id.clone();
        kinder.push(
            div()
                .id(ElementId::Name(format!("tab-{id}").into()))
                .flex_shrink_0()
                .px_2()
                .py(px(3.))
                .rounded_sm()
                .when(aktiv, |this| this.bg(rgb(mix(theme.selection(), theme.surface(), 0.6))))
                .flex()
                .flex_row()
                .items_center()
                .gap_1()
                .child(
                    div()
                        .text_xs()
                        .text_color(rgb(if aktiv { theme.ink_strong() } else { theme.ink2() }))
                        .child(tab.titel.clone()),
                )
                .when(tab.unread > 0, |this| {
                    this.child(
                        div()
                            .text_xs()
                            .text_color(rgb(theme.accent()))
                            .child(format!("{}", tab.unread)),
                    )
                })
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                        state.split_waehlen(index, cx);
                    }),
                )
                .into_any_element(),
        );
    }

    kinder.push(div().flex_1().into_any_element());
    kinder.push(
        div()
            .flex_shrink_0()
            .w(px(280.))
            .child(state.suchfeld.clone())
            .into_any_element(),
    );
    kinder.push(
        div()
            .flex_shrink_0()
            .text_xs()
            .text_color(rgb(theme.ink3()))
            .child("? Kürzel")
            .into_any_element(),
    );

    div()
        .id("kopfzeile")
        .h(px(KOPF_HOEHE))
        .w_full()
        .flex()
        .flex_row()
        .items_center()
        .gap_2()
        .px_3()
        .bg(rgb(theme.surface()))
        .border_b_1()
        .border_color(rgb(theme.line()))
        .children(kinder)
        .into_any_element()
}

pub fn fusszeile(state: &mut AppState, _cx: &mut Context<AppState>) -> AnyElement {
    let theme = state.theme.clone();
    let status = state.status_text();
    let hint = if !state.hint.is_empty() {
        state.hint.to_string()
    } else if state.expanded.is_some() {
        "J/K Auswahl · ↵ zuklappen · Esc zuklappen · / Suche · ? Kürzel".to_string()
    } else {
        "J/K Auswahl · ↵ aufklappen · / Suche · Tab Split · G I Posteingang · ? Kürzel".to_string()
    };

    div()
        .id("fusszeile")
        .h(px(FUSS_HOEHE))
        .w_full()
        .flex()
        .flex_row()
        .items_center()
        .gap_3()
        .px_3()
        .bg(rgb(theme.surface()))
        .border_t_1()
        .border_color(rgb(theme.line()))
        .child(
            div()
                .flex_shrink_0()
                .text_xs()
                .text_color(rgb(theme.ink3()))
                .child(hint),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_xs()
                .text_color(rgb(mix(theme.ink2(), theme.surface(), 0.2)))
                .child(status),
        )
        .into_any_element()
}

/// Kürzel-Übersicht (`?`), aus derselben Tabelle wie die Auswertung.
pub fn hilfe_overlay(state: &mut AppState, cx: &mut Context<AppState>) -> AnyElement {
    let theme = state.theme.clone();
    let zeilen: Vec<AnyElement> = keys::HILFE
        .iter()
        .map(|(taste, text)| {
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_3()
                .py(px(2.))
                .child(
                    div()
                        .w(px(90.))
                        .flex_shrink_0()
                        .text_color(rgb(theme.accent()))
                        .child(*taste),
                )
                .child(
                    div()
                        .flex_1()
                        .text_color(rgb(theme.ink1()))
                        .child(*text),
                )
                .into_any_element()
        })
        .collect();

    div()
        .id("hilfe")
        .absolute()
        .top_0()
        .left_0()
        .size_full()
        .bg(rgba(0x00000060))
        .flex()
        .items_center()
        .justify_center()
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(|state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                state.hilfe = false;
                cx.notify();
            }),
        )
        .child(
            div()
                .w(px(560.))
                .px_5()
                .py_4()
                .rounded_md()
                .bg(rgb(theme.raised()))
                .border_1()
                .border_color(rgb(theme.accent()))
                .flex()
                .flex_col()
                .gap_1()
                .text_sm()
                .child(
                    div()
                        .mb_2()
                        .text_lg()
                        .text_color(rgb(theme.accent()))
                        .child("Kürzel"),
                )
                .children(zeilen)
                .child(
                    div()
                        .mt_2()
                        .text_xs()
                        .text_color(rgb(theme.ink3()))
                        .child("Einzeltasten wirken nur außerhalb von Textfeldern. Esc schließt."),
                ),
        )
        .into_any_element()
}

/// Farbe mit Alpha aus einem `0xRRGGBBAA`-Wert.
fn rgba(wert: u32) -> Rgba {
    let r = ((wert >> 24) & 0xff) as f32 / 255.0;
    let g = ((wert >> 16) & 0xff) as f32 / 255.0;
    let b = ((wert >> 8) & 0xff) as f32 / 255.0;
    let a = (wert & 0xff) as f32 / 255.0;
    gpui::Rgba { r, g, b, a }
}

/// Wird von `sidebar` gebraucht; hier gehalten, damit die Farbhelfer beieinander
/// liegen, ohne die Seitenleiste in die Kopfzeile zu importieren.
#[allow(dead_code)]
fn farbe_von_label(hex: &str) -> Option<u32> {
    hex_farbe(hex)
}
