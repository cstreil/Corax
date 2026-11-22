//! Seitenleiste: Konto, Ansichten, Labels, ungelesene (L-E5, Mock-up).
//!
//! 232 px breit wie die Mac-App (`SidebarState.width`); unter 872 px
//! Fensterbreite klappt sie von selbst ein. Sie zeigt das *Wohin*, die Liste
//! das *Was*.

use gpui::prelude::*;
use gpui::*;

use crate::core::models::MailView;
use crate::state::AppState;
use crate::theme::mix;

/// Breite der Leiste (Mac-App: `SidebarState.width`).
pub const BREITE: f32 = 232.0;
const ZEILE: f32 = 26.0;

pub fn seitenleiste(
    state: &mut AppState,
    _window: &mut Window,
    cx: &mut Context<AppState>,
) -> AnyElement {
    let theme = state.theme.clone();

    let konto = konto_block(state, cx);

    let mut ansichten = Vec::with_capacity(MailView::ALLE.len());
    for view in MailView::ALLE {
        ansichten.push(ansicht_zeile(state, view, cx));
    }

    let label_kopf = (!state.labels.is_empty()).then(|| {
        div()
            .mt_3()
            .px_2()
            .text_xs()
            .text_color(rgb(theme.ink3()))
            .child("Labels")
            .into_any_element()
    });
    let labels = state.labels.clone();
    let mut label_zeilen = Vec::with_capacity(labels.len());
    for label in &labels {
        label_zeilen.push(label_zeile(state, label, cx));
    }

    div()
        .id("seitenleiste")
        .w(px(BREITE))
        .h_full()
        .flex()
        .flex_col()
        .flex_shrink_0()
        .bg(rgb(theme.surface()))
        .border_r_1()
        .border_color(rgb(theme.line()))
        .child(konto)
        .child(
            div()
                .flex_1()
                .w_full()
                .px_2()
                .flex()
                .flex_col()
                .gap(px(1.))
                .children(ansichten)
                .children(label_kopf)
                .children(label_zeilen),
        )
        .child(
            div()
                .w_full()
                .px_3()
                .py_2()
                .border_t_1()
                .border_color(rgb(theme.line()))
                .text_xs()
                .text_color(rgb(theme.ink3()))
                .child(fusszeile_text(state)),
        )
        .into_any_element()
}

fn fusszeile_text(state: &AppState) -> String {
    let konten = state.accounts.len();
    if konten == 0 {
        "kein Konto".into()
    } else if konten == 1 {
        state
            .accounts
            .first()
            .map(|konto| konto.email.clone())
            .unwrap_or_default()
    } else {
        format!("{konten} Konten")
    }
}

fn konto_block(state: &mut AppState, cx: &mut Context<AppState>) -> AnyElement {
    let theme = state.theme.clone();
    let titel = match state.account_id {
        Some(id) => state
            .accounts
            .iter()
            .find(|konto| konto.id == id)
            .map(|konto| konto.label())
            .unwrap_or_else(|| "Konto".into()),
        None if state.accounts.len() > 1 => "Alle Konten".into(),
        None => state
            .accounts
            .first()
            .map(|konto| konto.label())
            .unwrap_or_else(|| "Kein Konto".into()),
    };
    let initialen: String = titel
        .split_whitespace()
        .take(2)
        .filter_map(|wort| wort.chars().next())
        .collect::<String>()
        .to_uppercase();
    let initialen = if initialen.is_empty() { "C".to_string() } else { initialen };
    let hinweis = if state.accounts.len() > 1 {
        "Konto wechseln"
    } else {
        "Sandbox"
    };

    div()
        .id("konto")
        .mx_2()
        .mt_2()
        .mb_1()
        .px_2()
        .py(px(6.))
        .rounded_md()
        .flex()
        .flex_row()
        .items_center()
        .gap_2()
        .bg(rgb(theme.bg()))
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(|state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                // L1 hat keinen Kontowähler: ein Klick schaltet reihum.
                if state.accounts.len() < 2 {
                    return;
                }
                let mut ids: Vec<Option<i64>> = vec![None];
                ids.extend(state.accounts.iter().map(|konto| Some(konto.id)));
                let jetzt = ids.iter().position(|id| *id == state.account_id).unwrap_or(0);
                let naechstes = ids[(jetzt + 1) % ids.len()];
                state.konto_waehlen(naechstes, cx);
            }),
        )
        .child(
            div()
                .flex_shrink_0()
                .size(px(22.))
                .rounded_full()
                .bg(rgb(theme.accent()))
                .flex()
                .items_center()
                .justify_center()
                .text_xs()
                .text_color(rgb(theme.bg()))
                .child(initialen),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .child(
                    div()
                        .truncate()
                        .text_sm()
                        .text_color(rgb(theme.ink1()))
                        .child(titel),
                )
                .child(
                    div()
                        .truncate()
                        .text_xs()
                        .text_color(rgb(theme.ink3()))
                        .child(hinweis),
                ),
        )
        .into_any_element()
}

fn ansicht_zeile(state: &mut AppState, view: MailView, cx: &mut Context<AppState>) -> AnyElement {
    let theme = state.theme.clone();
    let aktiv = state.view == view && state.label_id.is_none() && state.suche.is_none();
    let badge = state.unread.badge(view);
    let text = view.name();
    let go = format!("G {}", view.go_key().to_uppercase());

    div()
        .id(ElementId::Name(format!("ansicht-{}", view.name()).into()))
        .h(px(ZEILE))
        .w_full()
        .px_2()
        .rounded_md()
        .flex()
        .flex_row()
        .items_center()
        .gap_2()
        .when(aktiv, |this| this.bg(rgb(mix(theme.selection(), theme.surface(), 0.55))))
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(move |state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                state.gehe_zu(view, cx);
            }),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_sm()
                .text_color(rgb(if aktiv { theme.ink_strong() } else { theme.ink1() }))
                .when(aktiv, |this| this.font_weight(FontWeight::MEDIUM))
                .child(text),
        )
        .when(badge > 0, |this| {
            this.child(
                div()
                    .flex_shrink_0()
                    .text_xs()
                    .text_color(rgb(if aktiv { theme.accent() } else { theme.ink3() }))
                    .child(format!("{badge}")),
            )
        })
        .child(
            div()
                .flex_shrink_0()
                .text_xs()
                .text_color(rgb(mix(theme.ink3(), theme.surface(), 0.35)))
                .child(go),
        )
        .into_any_element()
}

fn label_zeile(
    state: &mut AppState,
    label: &crate::core::models::Label,
    cx: &mut Context<AppState>,
) -> AnyElement {
    let theme = state.theme.clone();
    let aktiv = state.label_id == Some(label.id);
    let badge = state.unread.label_badge(label.id);
    let farbe = hex_farbe(&label.color).unwrap_or(theme.accent());
    let id = label.id;
    let name = label.name.clone();

    div()
        .id(ElementId::Name(format!("label-{id}").into()))
        .h(px(ZEILE))
        .w_full()
        .px_2()
        .rounded_md()
        .flex()
        .flex_row()
        .items_center()
        .gap_2()
        .when(aktiv, |this| this.bg(rgb(mix(theme.selection(), theme.surface(), 0.55))))
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(move |state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                state.label_waehlen(id, cx);
            }),
        )
        .child(div().flex_shrink_0().size(px(7.)).rounded_full().bg(rgb(farbe)))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_sm()
                .text_color(rgb(if aktiv { theme.ink_strong() } else { theme.ink1() }))
                .child(name),
        )
        .when(badge > 0, |this| {
            this.child(
                div()
                    .flex_shrink_0()
                    .text_xs()
                    .text_color(rgb(theme.ink3()))
                    .child(format!("{badge}")),
            )
        })
        .into_any_element()
}

/// `#rrggbb` aus dem Kern in eine Farbe.
pub fn hex_farbe(hex: &str) -> Option<u32> {
    let hex = hex.trim().trim_start_matches('#');
    if hex.len() != 6 {
        return None;
    }
    u32::from_str_radix(hex, 16).ok()
}
