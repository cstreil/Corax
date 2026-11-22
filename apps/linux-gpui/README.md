# GPUI-Spike (uncommitted)

Prüf-App für die Frage, ob GPUI die künftige Corax-Oberfläche unter
Linux/Omarchy trägt. Kein Produkt, keine Vorlage für den Umbau.

Gebaut und gestartet wird auf Tarantino (Omarchy 4.5, Hyprland):

```sh
# Quelltext und Kern hinübertragen
rsync -a --exclude target apps/linux-gpui/ tarantino:corax-spike/apps/linux-gpui/
rsync -a --exclude target src-tauri/crates/ tarantino:corax-spike/src-tauri/crates/

# Sandbox füllen (einmalig) und bauen
ssh tarantino 'cd ~/corax-spike/apps/linux-gpui && \
  cargo run --bin corax-spike --release'
```

Das Workspace-Manifest `src-tauri/Cargo.toml` auf Tarantino ist eine Kopie
ohne die Tauri-App (nur `[workspace]` und `[workspace.dependencies]`), damit
der Spike nicht die halbe Tauri-Kette mitziehen muss.

## Prüffragen und wo sie im Code liegen

| # | Frage | Stelle |
|---|---|---|
| 1 | Bau, Lizenz, Abhängigkeiten | `Cargo.toml` |
| 2 | Fenster unter Hyprland | `main.rs` (`WindowOptions`, Titel) |
| 3 | Liste mit 10 000 Zeilen | `main.rs` (`uniform_list`, `SYNTHETIC_ROWS`) |
| 4 | Kern im selben Prozess | `mailcore.rs` (`corax_host::Host`), Status in der Kopfzeile |
| 5 | HTML-Mail als Text mit Auszeichnung | `htmltext.rs` (Konverter), Detailspalte in `main.rs` |
| 6 | Texteingabe | `textfield.rs` (`EntityInputHandler`), Suche oben, Verfassen mit `c` |
| 7 | Einzeltasten-Kürzel | `main.rs` (`on_key`, nur ohne Textfeldfokus) |
| 8 | Omarchy-Theme | `theme.rs` liest `~/.local/state/omarchy/current/theme`, Beobachtung in `Tick` |
| 9 | Zugangsdaten | nicht im Code — der Kern nutzt den Secret Service; Befund im Bericht |

## Bedienung

`j`/`k` oder Pfeile bewegen, `Enter`/`e` klappt auf und zu, `/` springt in die
Suche, `c` öffnet das Verfassen-Feld, `Esc` verlässt ein Feld. Die Kopfzeile
zeigt Theme, Thread-Zahl, Auswahl, die gemessene Baumzeit pro Frame und den
Zustand des Kerns.

`CORAX_SPIKE_ROWS` überschreibt die Zahl der synthetischen Zeilen (Default
10 000).
