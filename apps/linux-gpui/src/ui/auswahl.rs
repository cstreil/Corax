//! Die Auswahl-Overlays: „Später" (`⇧H`), „Verschieben" (`V`), „Label" (`L`).
//!
//! Alle drei sind dieselbe Liste mit unterschiedlicher Bedeutung — eine Zeile
//! ist ein Vorschlag, ein Ordner oder ein Label. Die Bedeutung entscheidet
//! [`Auswahlart`]; was ein Klick oder `↵` auslöst, steht in
//! [`AppState::auswahl_nehmen`].
//!
//! Bedienung wie ein Menü: `↑`/`↓` bzw. `J`/`K` wählen, `↵` übernimmt, `Esc`
//! schließt, ein Klick außerhalb ebenfalls. Bei „Später" lässt sich darunter
//! ein eigenes Datum tippen (Grammatik in [`crate::ui::snooze::parse`]).

use gpui::prelude::*;
use gpui::*;

use crate::state::AppState;
use crate::theme::mix;

/// Was die Liste bedeutet.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Auswahlart {
    /// Vorschläge für „Später"; `key` ist der Zeitpunkt in Millisekunden.
    Spaeter,
    /// Ordner; `key` ist die Ordner-ID (`targetFolderId`).
    Verschieben,
    /// Labels; `key` ist die Label-ID (`labelId`).
    Label,
    /// Zeitpunkt für „Später senden"; `key` ist `sendAt` in Millisekunden.
    Senden,
}

/// Eine Zeile der Auswahl.
#[derive(Clone, Debug)]
pub struct Eintrag {
    /// Zeitpunkt, Ordner-ID oder Label-ID.
    pub key: i64,
    pub name: SharedString,
    /// Rechts stehende Zugabe (Uhrzeit, „verschoben nach …", Haken).
    pub neben: SharedString,
    /// Gesetzt (Label liegt am Thread).
    pub marke: bool,
}

/// Eine offene Auswahl.
#[derive(Clone, Debug)]
pub struct Auswahl {
    pub art: Auswahlart,
    pub titel: SharedString,
    pub eintraege: Vec<Eintrag>,
    /// Gewählte Zeile; `== eintraege.len()` ist die Zeile „Eigenes Datum".
    pub index: usize,
    /// Gibt es unter der Liste ein Feld für ein eigenes Datum?
    pub eigenes: bool,
    /// Hinweis nach einer ungültigen Datumseingabe.
    pub fehler: Option<SharedString>,
}

impl Auswahl {
    /// Anzahl der Zeilen einschließlich „Eigenes Datum".
    pub fn zeilen(&self) -> usize {
        self.eintraege.len() + usize::from(self.eigenes)
    }
}

/// Das Overlay. Wird nur gezeichnet, wenn [`AppState::auswahl`] gesetzt ist.
pub fn overlay(state: &mut AppState, cx: &mut Context<AppState>) -> AnyElement {
    let theme = state.theme.clone();
    let Some(auswahl) = state.auswahl.clone() else {
        return div().into_any_element();
    };
    let eintraege = auswahl.eintraege.clone();
    let index = auswahl.index;
    let titel = auswahl.titel.clone();
    let fehler = auswahl.fehler.clone();
    let eigenes = auswahl.eigenes;
    let art = auswahl.art;

    let mut zeilen: Vec<AnyElement> = Vec::with_capacity(eintraege.len() + 1);
    for (i, eintrag) in eintraege.iter().enumerate() {
        zeilen.push(zeile(i, eintrag, i == index, &theme, cx));
    }
    if eigenes {
        zeilen.push(
            div()
                .id("auswahl-eigenes")
                .h(px(28.))
                .px_2()
                .rounded_sm()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .text_sm()
                .when(index == eintraege.len(), |this| {
                    this.bg(rgb(mix(theme.accent(), theme.raised(), 0.22)))
                        .text_color(rgb(theme.accent()))
                })
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                        cx.stop_propagation();
                        state.auswahl_eigenes_feld(cx);
                    }),
                )
                .child(div().flex_1().child("Eigenes Datum …"))
                .child(
                    div()
                        .flex_shrink_0()
                        .text_xs()
                        .text_color(rgb(theme.ink3()))
                        .child("tippen"),
                )
                .into_any_element(),
        );
    }

    let hinweis = match (art, fehler.is_some()) {
        (Auswahlart::Spaeter, true) => "Datum nicht verstanden — z. B. „morgen 9:00“ oder „24.11. 18:00“"
            .to_string(),
        (Auswahlart::Spaeter, false) => "↑↓ wählen · ↵ übernehmen · Esc schließt".to_string(),
        (Auswahlart::Verschieben, _) => "↑↓ wählen · ↵ verschieben · Esc schließt".to_string(),
        (Auswahlart::Label, _) => "↑↓ wählen · ↵ setzen/entfernen · Esc schließt".to_string(),
        (Auswahlart::Senden, _) => "↑↓ wählen · ↵ Zeitpunkt übernehmen · Esc schließt".to_string(),
    };

    let mut karte = div()
        .id("auswahl")
        .w(px(460.))
        .px_2()
        .py_2()
        .rounded_md()
        .bg(rgb(theme.raised()))
        .border_1()
        .border_color(rgb(mix(theme.accent(), theme.line(), 0.6)))
        .flex()
        .flex_col()
        .gap_1()
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(|_state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                cx.stop_propagation();
            }),
        )
        .child(
            div()
                .px_2()
                .pb_1()
                .text_xs()
                .text_color(rgb(theme.ink3()))
                .child(titel),
        )
        .children(zeilen);

    if eigenes {
        karte = karte.child(
            div()
                .mt_1()
                .px_1()
                .child(state.datumfeld.clone()),
        );
    }
    if let Some(fehler) = fehler {
        karte = karte.child(
            div()
                .px_2()
                .text_xs()
                .text_color(rgb(theme.red()))
                .child(fehler),
        );
    }

    div()
        .id("auswahl-hintergrund")
        .absolute()
        .top_0()
        .left_0()
        .size_full()
        .flex()
        .justify_center()
        .items_start()
        .pt(px(64.))
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(|state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                state.auswahl_schliessen(cx);
            }),
        )
        .child(
            karte.child(
                div()
                    .px_2()
                    .pt_1()
                    .text_xs()
                    .text_color(rgb(theme.ink3()))
                    .child(hinweis),
            ),
        )
        .into_any_element()
}

fn zeile(
    i: usize,
    eintrag: &Eintrag,
    gewaehlt: bool,
    theme: &crate::theme::Theme,
    cx: &mut Context<AppState>,
) -> AnyElement {
    let name = eintrag.name.clone();
    let neben = eintrag.neben.clone();
    let marke = eintrag.marke;
    div()
        .id(ElementId::Name(format!("auswahl-{i}").into()))
        .h(px(28.))
        .px_2()
        .rounded_sm()
        .flex()
        .flex_row()
        .items_center()
        .gap_2()
        .text_sm()
        .when(gewaehlt, |this| {
            this.bg(rgb(mix(theme.accent(), theme.raised(), 0.22)))
        })
        .when(marke, |this| this.text_color(rgb(theme.accent())))
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(move |state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                cx.stop_propagation();
                state.auswahl_nehmen(i, cx);
            }),
        )
        .child(div().flex_1().min_w_0().truncate().child(name))
        .child(
            div()
                .flex_shrink_0()
                .text_xs()
                .text_color(rgb(theme.ink3()))
                .child(neben),
        )
        .when(marke, |this| {
            this.child(
                div()
                    .flex_shrink_0()
                    .text_xs()
                    .text_color(rgb(theme.accent()))
                    .child("✓"),
            )
        })
        .into_any_element()
}
