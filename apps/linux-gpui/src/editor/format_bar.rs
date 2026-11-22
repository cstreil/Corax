//! Formatleiste über dem Verfassen-Feld: Fett und Kursiv.
//!
//! Die Leiste hält keinen eigenen Zustand. Sie liest bei jedem Zeichnen
//! [`ComposeEditor::format_state`] — Auswahl, Vorformat oder das Format vor dem
//! Cursor — und schaltet über [`ComposeEditor::toggle_format`] um. Damit gibt
//! es nur eine Wahrheit über die Formatierung, und `Strg+B`/`Strg+I` sowie ein
//! Klick auf den Knopf landen im selben Weg.

// Bis das Verfassen-Panel den Editor einbindet (L2), ruft niemand die Leiste.
#![allow(dead_code)]

use gpui::prelude::*;
use gpui::*;

use crate::theme::Theme;

use super::{ComposeEditor, Format};

/// Die Leiste. Sie steht im Editor über dem Textfeld.
pub fn leiste(this: &ComposeEditor, cx: &mut Context<ComposeEditor>) -> AnyElement {
    let state = this.format_state(cx);
    let theme = this.theme.clone();

    div()
        .id("format-leiste")
        .flex()
        .items_center()
        .gap_1()
        .px_2()
        .py_1()
        .w_full()
        .border_b_1()
        .border_color(rgb(theme.line()))
        .child(knopf(
            "format-fett",
            "B",
            Format::BOLD,
            state.bold,
            FontWeight::BOLD,
            false,
            &theme,
            cx,
        ))
        .child(knopf(
            "format-kursiv",
            "I",
            Format::ITALIC,
            state.italic,
            FontWeight::NORMAL,
            true,
            &theme,
            cx,
        ))
        .into_any_element()
}

/// Ein Knopf der Leiste. `aktiv` färbt ihn ein, ein Klick schaltet um und holt
/// den Fokus zurück ins Feld, damit man gleich weitertippen kann.
#[allow(clippy::too_many_arguments)]
fn knopf(
    id: &'static str,
    beschriftung: &'static str,
    format: Format,
    aktiv: bool,
    gewicht: FontWeight,
    kursiv: bool,
    theme: &Theme,
    cx: &mut Context<ComposeEditor>,
) -> AnyElement {
    let hintergrund = if aktiv {
        rgb(theme.selection())
    } else {
        rgb(theme.raised())
    };
    let schrift = if aktiv {
        rgb(theme.ink_strong())
    } else {
        rgb(theme.ink2())
    };

    let mut knopf = div()
        .id(id)
        .w(px(26.))
        .h(px(22.))
        .flex()
        .items_center()
        .justify_center()
        .rounded_sm()
        .bg(hintergrund)
        .text_color(schrift)
        .text_sm()
        .font_weight(gewicht)
        .cursor_pointer()
        .hover(|stil| stil.bg(rgb(theme.raised())));
    if kursiv {
        knopf = knopf.italic();
    }
    knopf
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(move |this: &mut ComposeEditor, _event: &MouseDownEvent, window, cx| {
                this.toggle_format(format, cx);
                this.focus(window, cx);
                // Der Klick gehört dem Knopf: die Wurzel darf den Fokus nicht
                // wieder an die Liste ziehen.
                cx.stop_propagation();
            }),
        )
        .child(beschriftung)
        .into_any_element()
}
