//! Corax für Linux/Omarchy — Einstieg.
//!
//! Nur Start, Fenster und Fensterkennung: alles Weitere liegt in `state`
//! (Zustand), `ui` (Ansichten), `core` (Kern) und `html` (Mail-Körper).
//!
//! L1 läuft ausschließlich gegen die Sandbox: ohne `--sandbox` startet nichts,
//! damit ein versehentlicher Start nie echte Konten anfasst.

mod core;
mod html;
// `view.rs` ist Coder 1s Teil der HTML-Schicht; `html/mod.rs` (Coder 2) führt
// nur `sanitize` und `resources`, deshalb wird die Datei hier eingebunden.
#[path = "html/view.rs"]
mod html_view;
mod editor;
#[cfg(feature = "test-hooks")]
mod hooks;
mod input;
mod keys;
mod mailtext;
mod perf;
mod safety;
mod state;
mod theme;
mod ui;

use gpui::*;

use state::AppState;

fn main() {
    perf::start_uhr();

    let args: Vec<String> = std::env::args().collect();
    if !args.iter().any(|argument| argument == "--sandbox") {
        eprintln!(
            "Corax (L1) läuft nur gegen die Sandbox: `corax --sandbox`.\n\
             Ohne Flag startet nichts — echte Konten fasst dieser Stand nicht an."
        );
        std::process::exit(2);
    }

    let ident = core::SANDBOX_IDENTIFIER;
    match corax_host::seed_sandbox(ident, false) {
        Ok(report) => eprintln!(
            "L1-SANDBOX neu angelegt: {} Threads, {} Nachrichten, {} Anhänge in {}",
            report.threads,
            report.messages,
            report.attachments,
            report.data_dir
        ),
        Err(error) if error.code == "already_seeded" => {
            eprintln!("L1-SANDBOX vorhanden");
        }
        Err(error) => {
            eprintln!("L1-SANDBOX fehlgeschlagen: {error}");
            std::process::exit(1);
        }
    }

    Application::new().run(move |cx: &mut App| {
        // gpui-components braucht seinen Zustand (Theme, Tastenkarte), bevor das
        // erste Eingabefeld gezeichnet wird; sein Theme wird auf Corax gezogen.
        gpui_component::init(cx);
        theme::an_gpui_component(&theme::Theme::load(), cx);

        let bounds = Bounds::centered(None, size(px(1180.), px(780.)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(TitlebarOptions {
                    title: Some("Corax".into()),
                    ..Default::default()
                }),
                app_id: Some("com.coraxapp.corax".into()),
                ..Default::default()
            },
            |window, cx| {
                // Unter Wayland setzt nur dieser Aufruf den Titel; `titlebar`
                // wirkt nur unter macOS/Windows.
                window.set_window_title("Corax");
                let view = cx.new(|cx| AppState::new(ident, cx));
                // Ohne Fokus kommt keine Taste an: `on_key_down` hängt am
                // Wurzelelement (`track_focus`).
                let focus = view.read(cx).focus.clone();
                // `Strg+↵` sendet, auch wenn der Textkörper den Fokus hat:
                // gpui-components' Feld bindet `secondary-enter` (= `Strg+↵`)
                // selbst und macht daraus einen Zeilenumbruch; Tastenbelegungen
                // laufen vor jedem Element-Handler. Der Interceptor läuft davor.
                let schwach = view.downgrade();
                cx.intercept_keystrokes(move |event: &KeystrokeEvent, _window, cx| {
                    let taste = event.keystroke.key.as_str();
                    let ctrl = event.keystroke.modifiers.control;
                    let Some(state) = schwach.upgrade() else { return };
                    let im_dock = || {
                        state.read(cx).compose_aktiv.is_some() && state.read(cx).compose_fokus
                    };
                    if ctrl && matches!(taste, "enter" | "return") {
                        if !im_dock() {
                            return;
                        }
                        cx.stop_propagation();
                        state.update(cx, |state, cx| state.senden(cx));
                        return;
                    }
                    // `Tab` führt im Dock zu den Anhängen: das Eingabefeld bindet
                    // `tab` selbst (Einzug), deshalb hier davor.
                    if taste == "tab" {
                        if !im_dock() {
                            return;
                        }
                        let rueckwaerts = event.keystroke.modifiers.shift;
                        let mut griff = false;
                        state.update(cx, |state, cx| griff = state.verfassen_tab(rueckwaerts, cx));
                        if griff {
                            cx.stop_propagation();
                        }
                    }
                })
                .detach();
                // Das Eingabefeld (Verfassen) verlangt ein `Root` als
                // Fensterwurzel (`window.root::<Root>()` in gpui-component);
                // ohne stürzt schon sein erster Render ab. Die App-Wurzel
                // darunter behält Tastatur und Fokus-Handle.
                let root = cx.new(|cx| gpui_component::Root::new(view, window, cx));
                window.focus(&focus);
                root
            },
        )
        .expect("Fenster");
        cx.activate(true);
    });
}
