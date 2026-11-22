//! Toast für die letzte Aktion: „Erledigt · Rückgängig" (wie die Mac-App).
//!
//! Er sitzt unten mittig über der Liste, läuft nach [`DAUER`] von selbst aus
//! und nimmt nur den einen Klick „Rückgängig" an. Den Zustand hält
//! [`AppState`](crate::state::AppState): solange ein Toast steht, läuft die
//! Uhr; der Tick räumt ihn weg.

use std::time::{Duration, Instant};

use gpui::prelude::*;
use gpui::*;

use crate::state::AppState;

/// So lange bleibt der Toast stehen (die Mac-App liegt bei 8 s).
pub const DAUER: Duration = Duration::from_secs(8);

/// Was der Knopf im Toast auslöst.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToastZiel {
    /// Letzte Aktion zurücknehmen (`undo_last`).
    Undo,
    /// Senden abbrechen (`cancel_send`) — die Kennung der Warteschlangen-Aktion.
    SendCancel(i64),
}

pub struct Toast {
    pub text: SharedString,
    /// Beschriftung des Knopfs; `None` heißt: nur ein Hinweis, nichts zu tun.
    pub aktion: Option<SharedString>,
    pub bis: Instant,
    pub ziel: ToastZiel,
}

impl Toast {
    /// Hinweis ohne Knopf (Bestätigungen, Fehlermeldungen).
    pub fn neu(text: impl Into<SharedString>, dauer: Duration) -> Self {
        Self {
            text: text.into(),
            aktion: None,
            bis: Instant::now() + dauer,
            ziel: ToastZiel::Undo,
        }
    }

    /// Hinweis mit „Rückgängig" (nach einer Aktion).
    pub fn mit_rueckgaengig(text: impl Into<SharedString>, dauer: Duration) -> Self {
        Self {
            text: text.into(),
            aktion: Some("Rückgängig".into()),
            bis: Instant::now() + dauer,
            ziel: ToastZiel::Undo,
        }
    }

    /// „Wird gesendet · Rückgängig": der Knopf bricht den Versand ab.
    pub fn mit_senden(action_id: i64, text: impl Into<SharedString>, dauer: Duration) -> Self {
        Self {
            text: text.into(),
            aktion: Some("Rückgängig".into()),
            bis: Instant::now() + dauer,
            ziel: ToastZiel::SendCancel(action_id),
        }
    }
}

/// Der Toast selbst. `text` ist der Satz links, der Knopf steht rechts.
pub fn toast(
    text: SharedString,
    aktion: Option<SharedString>,
    theme: &crate::theme::Theme,
    cx: &mut Context<AppState>,
) -> AnyElement {
    div()
        .id("toast")
        .flex()
        .items_center()
        .gap_3()
        .px_3()
        .py_2()
        .rounded_md()
        .bg(rgb(theme.raised()))
        .border_1()
        .border_color(rgb(theme.line()))
        .child(
            div()
                .text_sm()
                .text_color(rgb(theme.ink1()))
                .child(text),
        )
        .children(aktion.map(|aktion| {
            div()
                .id("toast-aktion")
                .text_sm()
                .text_color(rgb(theme.accent()))
                .child(aktion)
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                        state.toast_aktion(cx);
                    }),
                )
        }))
        .into_any_element()
}
