//! Verfassen-Panel unten rechts (Entscheidung des Nutzers: angedockt und
//! minimierbar). Jedes offene Fenster ist ein [`Compose`]; aktiv ist höchstens
//! eines, die übrigen stehen als Leiste darüber und lassen sich zurückholen.
//!
//! Die Felder sind [`TextField`], der Textkörper ist Coder 2s `ComposeEditor`
//! (Fett/Kursiv, Formatleiste). Was der Nutzer tippt, wandert beim Wechseln,
//! Minimieren und Schließen über `compose_einlesen` zurück in den Zustand;
//! gespeichert wird nach Tipppause über `save_draft`.

use gpui::prelude::*;
use gpui::*;

use crate::state::AppState;
use crate::theme::mix;

const PANEL_BREITE: f32 = 520.0;
const PANEL_HOEHE: f32 = 432.0;
/// Höhe eines Vorschlags in der Liste unter dem An-Feld.
const VORSCHLAG_HOEHE: f32 = 26.0;

/// Das Dock: minimierte Fenster als Leiste und das aktive Fenster als Panel.
pub fn dock(state: &mut AppState, _window: &mut Window, cx: &mut Context<AppState>) -> AnyElement {
    if state.compose.is_empty() {
        return div().into_any_element();
    }
    let theme = state.theme.clone();

    let minimiert: Vec<(u64, String)> = state
        .compose
        .iter()
        .filter(|compose| compose.minimiert)
        .map(|compose| (compose.id, compose.titel()))
        .collect();

    let mut kinder: Vec<AnyElement> = Vec::with_capacity(minimiert.len() + 1);
    for (id, titel) in minimiert {
        kinder.push(
            div()
                .id(ElementId::Name(format!("compose-mini-{id}").into()))
                .w(px(PANEL_BREITE))
                .h(px(30.))
                .px_3()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .rounded_md()
                .bg(rgb(theme.raised()))
                .border_1()
                .border_color(rgb(theme.line()))
                .text_xs()
                .text_color(rgb(theme.ink2()))
                .child(div().flex_1().min_w_0().truncate().child(titel))
                .child(div().text_color(rgb(theme.ink3())).child("öffnen"))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |state: &mut AppState, _event: &MouseDownEvent, window, cx| {
                        cx.stop_propagation();
                        state.compose_fokus = true;
                        state.compose_wechseln(id, window, cx);
                    }),
                )
                .into_any_element(),
        );
    }
    if let Some(id) = state.compose_aktiv {
        kinder.push(panel(state, id, &theme, cx));
    }

    div()
        .id("compose-dock")
        .absolute()
        .bottom(px(30.))
        .right(px(12.))
        .flex()
        .flex_col()
        .items_end()
        .gap_1()
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(|state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                cx.stop_propagation();
                state.compose_fokus = true;
                cx.notify();
            }),
        )
        .children(kinder)
        .into_any_element()
}

fn panel(
    state: &mut AppState,
    id: u64,
    theme: &crate::theme::Theme,
    cx: &mut Context<AppState>,
) -> AnyElement {
    let Some(compose) = state.compose.iter().find(|compose| compose.id == id).cloned() else {
        return div().into_any_element();
    };
    let titel = compose.titel();
    let modus = compose.modus;

    let knopf = |beschriftung: &'static str,
                 taste: &'static str,
                 betont: bool,
                 cx: &mut Context<AppState>,
                 aktion: usize| {
        let rand = if betont { theme.accent() } else { theme.line() };
        let mut knopf = div()
            .id(ElementId::Name(format!("dock-knopf-{beschriftung}").into()))
            .px_3()
            .py(px(5.))
            .rounded_sm()
            .border_1()
            .border_color(rgb(rand))
            .flex()
            .flex_row()
            .items_center()
            .gap_1()
            .text_sm()
            .text_color(rgb(if betont { theme.accent() } else { theme.ink2() }))
            .child(beschriftung.to_string());
        if !taste.is_empty() {
            knopf = knopf.child(div().text_xs().text_color(rgb(theme.ink3())).child(taste));
        }
        knopf
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                    cx.stop_propagation();
                    match aktion {
                        0 => state.senden(cx),
                        1 => state.spaeter_senden(cx),
                        2 => state.compose_schliessen(true, cx),
                        3 => state.compose_minimieren(cx),
                        4 => state.anhaenge_waehlen(cx),
                        _ => {}
                    }
                }),
            )
            .into_any_element()
    };

    // Kopf: Art des Fensters, Betreff als Titel, Minimieren und Schließen.
    let kopf = div()
        .h(px(28.))
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
                .text_color(rgb(theme.ink_strong()))
                .child(format!("{} · {titel}", modus.titel())),
        )
        .child(
            div()
                .id("dock-minimieren")
                .px_2()
                .text_xs()
                .text_color(rgb(theme.ink3()))
                .child("–")
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                        cx.stop_propagation();
                        state.compose_minimieren(cx);
                    }),
                ),
        )
        .child(
            div()
                .id("dock-verwerfen-kreuz")
                .px_2()
                .text_xs()
                .text_color(rgb(theme.ink3()))
                .child("✕")
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                        cx.stop_propagation();
                        state.compose_schliessen(true, cx);
                    }),
                ),
        );

    // An-Feld und Vorschläge.
    let mut an_teil = div().flex().flex_col().gap_1().child(
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .child(div().w(px(38.)).text_xs().text_color(rgb(theme.ink3())).child("An"))
            .child(div().flex_1().child(state.feld_an.clone()))
            .child(
                div()
                    .id("dock-cc")
                    .text_xs()
                    .text_color(rgb(theme.accent()))
                    .child(if state.cc_bcc { "Cc/Bcc aus" } else { "Cc/Bcc" })
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                            cx.stop_propagation();
                            state.cc_bcc = !state.cc_bcc;
                            cx.notify();
                        }),
                    ),
            ),
    );
    if !state.vorschlaege.is_empty() {
        let zeilen: Vec<AnyElement> = state
            .vorschlaege
            .iter()
            .enumerate()
            .map(|(index, vorschlag)| {
                let gewaehlt = index == state.vorschlag_index;
                div()
                    .id(ElementId::Name(format!("vorschlag-{index}").into()))
                    .h(px(VORSCHLAG_HOEHE))
                    .px_2()
                    .flex()
                    .flex_row()
                    .items_center()
                    .text_xs()
                    .when(gewaehlt, |this| {
                        this.bg(rgb(mix(theme.accent(), theme.raised(), 0.22)))
                            .text_color(rgb(theme.accent()))
                    })
                    .child(vorschlag.anzeige())
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                            cx.stop_propagation();
                            state.vorschlag_nehmen(index, cx);
                        }),
                    )
                    .into_any_element()
            })
            .collect();
        an_teil = an_teil.child(
            div()
                .ml(px(46.))
                .rounded_sm()
                .bg(rgb(theme.raised()))
                .border_1()
                .border_color(rgb(theme.line()))
                .flex()
                .flex_col()
                .children(zeilen),
        );
    }
    if state.cc_bcc {
        an_teil = an_teil
            .child(feld_zeile(state, "Cc", state.feld_cc.clone()))
            .child(feld_zeile(state, "Bcc", state.feld_bcc.clone()));
    }
    an_teil = an_teil.child(feld_zeile(state, "Betreff", state.feld_betreff.clone()));

    // Anhänge: Name, Größe, Entfernen.
    let mut anhaenge_teil = div().flex().flex_col().gap_1();
    if !compose.anhaenge.is_empty() {
        let zeilen: Vec<AnyElement> = compose
            .anhaenge
            .iter()
            .enumerate()
            .map(|(index, anhang)| {
                // Mit `Tab` erreichbar: die markierte Zeile trägt einen Akzentrand
                // und sagt, welche Taste sie entfernt.
                let markiert = state.anhang_fokus == Some(index);
                div()
                    .id(ElementId::Name(format!("anhang-{index}").into()))
                    .h(px(22.))
                    .ml(px(46.))
                    .px_1()
                    .rounded_sm()
                    .border_1()
                    .border_color(rgb(if markiert { theme.accent() } else { theme.bg() }))
                    .bg(rgb(if markiert { theme.surface() } else { theme.bg() }))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .text_xs()
                    .text_color(rgb(theme.ink2()))
                    .child(div().flex_1().min_w_0().truncate().child(anhang.name.clone()))
                    .children(markiert.then(|| {
                        div()
                            .flex_shrink_0()
                            .text_color(rgb(theme.ink3()))
                            .child("Entf entfernt")
                    }))
                    .child(
                        div()
                            .flex_shrink_0()
                            .text_color(rgb(theme.ink3()))
                            .child(anhang.groesse_text()),
                    )
                    .child(
                        div()
                            .id(ElementId::Name(format!("anhang-weg-{index}").into()))
                            .flex_shrink_0()
                            .px_1()
                            .text_color(rgb(theme.ink3()))
                            .child("✕")
                            .on_mouse_down(
                                MouseButton::Left,
                                cx.listener(
                                    move |state: &mut AppState,
                                          _event: &MouseDownEvent,
                                          _window,
                                          cx| {
                                        cx.stop_propagation();
                                        state.anhang_entfernen(index, cx);
                                    },
                                ),
                            ),
                    )
                    .into_any_element()
            })
            .collect();
        anhaenge_teil = anhaenge_teil.child(div().flex().flex_col().children(zeilen));
    }

    // Textkörper: der Editor, sonst ein Hinweis (er entsteht beim ersten Öffnen).
    let koerper: AnyElement = match state.editor.as_ref() {
        Some(editor) => div()
            .flex_1()
            .min_h_0()
            .w_full()
            .rounded_md()
            .border_1()
            .border_color(rgb(theme.line()))
            .child(editor.clone())
            .into_any_element(),
        None => div()
            .flex_1()
            .flex()
            .items_center()
            .justify_center()
            .text_xs()
            .text_color(rgb(theme.ink3()))
            .child("Editor wird geladen …")
            .into_any_element(),
    };

    let fehler = compose.fehler.clone().map(|fehler| {
        div()
            .w_full()
            .text_xs()
            .text_color(rgb(theme.red()))
            .child(fehler)
    });

    div()
        .id(ElementId::Name(format!("compose-{id}").into()))
        .w(px(PANEL_BREITE))
        .h(px(PANEL_HOEHE))
        .flex()
        .flex_col()
        .gap_2()
        .px_3()
        .py_2()
        .rounded_md()
        .bg(rgb(theme.surface()))
        .border_1()
        .border_color(rgb(mix(theme.accent(), theme.line(), 0.6)))
        .shadow_lg()
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(|state: &mut AppState, _event: &MouseDownEvent, _window, cx| {
                cx.stop_propagation();
                state.compose_fokus = true;
                cx.notify();
            }),
        )
        .child(kopf)
        .child(an_teil)
        .child(anhaenge_teil)
        .children(fehler)
        .child(koerper)
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .child(knopf("Senden", "Strg+↵", true, cx, 0))
                .child(knopf(
                    if state.anhaenge_laeuft { "Anhänge …" } else { "Anhänge" },
                    "",
                    false,
                    cx,
                    4,
                ))
                .child(knopf("Später senden …", "", false, cx, 1))
                .child(div().flex_1())
                .child(knopf("Verwerfen", "", false, cx, 2)),
        )
        .into_any_element()
}

/// „An / Cc / Bcc / Betreff": Label links, Feld rechts.
fn feld_zeile(
    state: &AppState,
    beschriftung: &'static str,
    feld: Entity<crate::input::TextField>,
) -> AnyElement {
    let theme = &state.theme;
    div()
        .w_full()
        .flex()
        .flex_row()
        .items_center()
        .gap_2()
        .child(
            div()
                .w(px(38.))
                .text_xs()
                .text_color(rgb(theme.ink3()))
                .child(beschriftung),
        )
        .child(div().flex_1().child(feld))
        .into_any_element()
}
