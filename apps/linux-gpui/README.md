# Corax für Linux/Omarchy (GPUI) — Stand L1

Nicht mehr der Prüf-Spike, sondern der Anfang der echten Linux-Oberfläche:
GPUI 0.2.2 als Fenster- und Eingabeschicht, Blitz für den Mail-Körper, der Kern
(`corax-host`) im selben Prozess über `Host::dispatch(cmd, json)`.

Umfang L1: lesen. Seitenleiste, Liste mit Splits/Datumsgruppen/Paging, Thread
inline aufklappen, HTML-Körper über Blitz, externe Bilder blockiert mit Knopf
„Laden", Suche, Kürzel, Theme live. Keine Aktionen, kein Verfassen, kein
Kalender, keine Einstellungen — das ist L2 bis L4 (`docs/native-ui/LINUX.md`).

## Starten

Läuft nur gegen die Sandbox, echte Konten fasst der Stand nicht an:

```sh
cargo run --release -- --sandbox
```

Ohne `--sandbox` endet der Start mit Exit 2 und einem Hinweis. Gebaut und
gemessen wird auf Tarantino (Omarchy, Hyprland):

```sh
rsync -a --delete --exclude target apps/linux-gpui/ tarantino:corax-spike/apps/linux-gpui/
ssh tarantino 'cd ~/corax-spike/apps/linux-gpui && cargo build --release'
```

Der Cargo-Workspace hier ist eigenständig; er hängt nur per Pfad an
`src-tauri/crates/corax-host`, der Tauri-Workspace bleibt unberührt.

## Aufbau

| Datei | Inhalt |
|---|---|
| `src/main.rs` | App-Start, Fenster (`com.coraxapp.corax`), Sandbox-Zwang |
| `src/core/host.rs` | Kern im Prozess, eigener Tokio-Thread, typisierte Anfragen und Antworten |
| `src/core/models.rs` | Rust-Typen der Kern-Antworten |
| `src/state/app.rs` | Zustand: Liste, Auswahl, Karte, Suche, Bildabruf, Messläufe |
| `src/ui/` | Seitenleiste, Liste (`gpui::list`), Karte, Kopfzeile |
| `src/html/view.rs` | Blitz → vello_cpu-Bitmap → `gpui::img`, Bild-Anbieter, Höhenmessung |
| `src/html/sanitize.rs` | Sanitizer und Anzeige-Policy (Remote-Bilder blocken) |
| `src/html/resources.rs` | Bild-Speicher: Anhänge, `data:`, nachgeladene Bilder |
| `src/html/fetch.rs` | Bildabruf mit SSRF-/Rebinding-Schutz, Grenzen, Signaturprüfung |
| `src/keys.rs` | Tastatur: getipptes Zeichen statt GPUI-Keymap (deutsche Belegung) |
| `src/input/textfield.rs` | eigenes Textfeld (EntityInputHandler, Dead Keys) für die Suche |
| `src/theme.rs` | Omarchy-Theme aus `~/.local/state/omarchy/current/theme/colors.toml`, live |
| `src/mailtext.rs` | Textkörper als Rich-Text, wenn kein HTML da ist |
| `src/perf.rs` | Frame-Messung für die Abnahme |
| `src/hooks.rs` | Test-Hooks — **nur** mit `--features test-hooks` im Binary |
| `tests/` | Integrationstests der HTML-Schicht (Sanitizer, Bild-Speicher, Bildabruf) |

## Bedienung

`j`/`k` oder Pfeile bewegen, `Enter` klappt auf und zu, `Esc` schließt wieder
ab, `/` springt in die Suche, `g t` wechselt die Ansicht, `\` klappt die
Seitenleiste ein, `?` zeigt die Kürzel. Ausgewertet wird das getippte Zeichen,
deshalb funktionieren `/ ? #` auch auf der deutschen Tastatur.

## Testen

```sh
cargo test                                   # 125 Tests (mit --features test-hooks)
cargo build --release                        # Abnahmebuild ohne Hooks
cargo build --release --features test-hooks  # Messbuild (Hooks + Messausgaben)
```

Die Hooks lesen eine Befehlsdatei aus `$CORAX_CMD` (`korpus:<1–5>`,
`extern:<url>`, `laden`, `fill:<n>`, `bench:<n>`, `theme:<name>`, `dump`,
`quit` …). Korpus-Mails kommen aus `$CORAX_KORPUS`; **beides gibt es nur im
Messbuild** — im Release-Build sind die Variablen nicht vorhanden.
