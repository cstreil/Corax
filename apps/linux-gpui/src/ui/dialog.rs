//! Rückfragen, die eine bewusste Bestätigung verlangen (endgültig löschen).
//!
//! Die Regel der Mac-App: die harmlose Antwort ist vorgewählt, `Esc` und `↵`
//! ohne Umschalten brechen ab, und es gibt **kein** „Rückgängig" — was gelöscht
//! ist, ist gelöscht. Deshalb steht die Entscheidung als reine Funktion hier
//! und ist ohne Fenster testbar; gezeichnet wird in [`dialog`].

use gpui::prelude::*;
use gpui::*;

use crate::state::AppState;
use crate::theme::mix;

/// Was eine Taste in der Rückfrage bedeutet.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Antwort {
    /// Taste gehört nicht der Rückfrage.
    Nichts,
    /// Auf den anderen Knopf wechseln (`Tab`, Pfeile).
    Umschalten,
    /// Abbrechen — die Vorgabe.
    Abbrechen,
    /// Den gefährlichen Knopf auslösen.
    Loeschen,
}

/// Tastenauswertung der Rückfrage. `loeschen_gewaehlt` ist der Zustand *vor*
/// dem Tastendruck; die Vorgabe ist immer „Abbrechen".
pub fn taste(taste: &str, loeschen_gewaehlt: bool) -> Antwort {
    match taste {
        "escape" => Antwort::Abbrechen,
        "tab" | "left" | "right" | "h" | "l" => Antwort::Umschalten,
        "enter" | "return" => {
            if loeschen_gewaehlt {
                Antwort::Loeschen
            } else {
                Antwort::Abbrechen
            }
        }
        _ => Antwort::Nichts,
    }
}

/// Die Rückfrage als Overlay: Text, zwei Knöpfe, Vorgabe „Abbrechen".
pub fn dialog(state: &mut AppState, cx: &mut Context<AppState>) -> AnyElement {
    let theme = state.theme.clone();
    let Some(frage) = state.bestaetigung.clone() else {
        return div().into_any_element();
    };
    let loeschen = frage.loeschen;

    let knopf = |beschriftung: SharedString,
                 gefahr: bool,
                 gewaehlt: bool,
                 cx: &mut Context<AppState>,
                 aktion: usize| {
        let farbe = if gefahr { theme.red() } else { theme.accent() };
        div()
            .id(ElementId::Name(format!("dialog-knopf-{aktion}").into()))
            .px_3()
            .py_1()
            .rounded_sm()
            .border_1()
            .border_color(rgb(if gewaehlt { farbe } else { theme.line() }))
            .when(gewaehlt, |this| this.bg(rgb(mix(farbe, theme.raised(), 0.22))))
            .text_sm()
            .text_color(rgb(if gewaehlt {
                farbe
            } else {
                theme.ink2()
            }))
            .child(beschriftung)
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                    cx.stop_propagation();
                    // 0 = Abbrechen, 1 = der gefährliche Knopf.
                    if aktion == 0 {
                        state.bestaetigung = None;
                        cx.notify();
                    } else {
                        state.bestaetigung_bestaetigen(cx);
                    }
                }),
            )
            .into_any_element()
    };

    div()
        .id("dialog-hintergrund")
        .absolute()
        .top_0()
        .left_0()
        .size_full()
        .bg(gpui::Rgba { r: 0.0, g: 0.0, b: 0.0, a: 0.55 })
        .flex()
        .items_center()
        .justify_center()
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(|state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                // Klick daneben bricht ab, wie `Esc`.
                state.bestaetigung = None;
                cx.notify();
            }),
        )
        .child(
            div()
                .id("dialog")
                .w(px(430.))
                .px_4()
                .py_3()
                .rounded_md()
                .bg(rgb(theme.raised()))
                .border_1()
                .border_color(rgb(theme.line()))
                .flex()
                .flex_col()
                .gap_3()
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|_state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                        cx.stop_propagation();
                    }),
                )
                .child(
                    div()
                        .text_sm()
                        .text_color(rgb(theme.ink_strong()))
                        .child(frage.text.clone()),
                )
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .justify_end()
                        .gap_2()
                        .child(knopf("Abbrechen".into(), false, !loeschen, cx, 0))
                        .child(knopf(frage.knopf.clone(), true, loeschen, cx, 1)),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(rgb(theme.ink3()))
                        .child(frage.hinweis.clone()),
                ),
        )
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::{Antwort, taste};

    #[test]
    fn vorgabe_ist_abbrechen() {
        // ↵ ohne Umschalten bricht ab — die harmlose Antwort ist vorgewählt.
        assert_eq!(taste("enter", false), Antwort::Abbrechen);
        assert_eq!(taste("escape", true), Antwort::Abbrechen);
    }

    #[test]
    fn erst_umschalten_erlaubt_das_loeschen() {
        assert_eq!(taste("tab", false), Antwort::Umschalten);
        assert_eq!(taste("left", true), Antwort::Umschalten);
        assert_eq!(taste("l", false), Antwort::Umschalten);
        // Nach dem Umschalten löst ↵ den gefährlichen Knopf aus.
        assert_eq!(taste("enter", true), Antwort::Loeschen);
    }

    #[test]
    fn fremde_tasten_aendern_nichts() {
        assert_eq!(taste("x", false), Antwort::Nichts);
        assert_eq!(taste("f5", true), Antwort::Nichts);
    }
}
