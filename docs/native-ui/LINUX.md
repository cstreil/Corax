# Corax für Linux/Omarchy — Entscheidung und Plan

Stand 2026-11-22 · Entscheidung Nutzer: **GPUI 0.2.2 + Blitz** (HTML/CSS-Engine für Mail-Körper). Ersetzt Option A „Qt 6/QML“ aus `ARCHITEKTUR.md` für Linux. KDE-Skin vorerst nicht.

## 1. Begründung (Vergleichs-Spike, Tarantino: Intel UHD 620, 1920×1080 @1×)

| | GPUI + Blitz | Qt 6.12/QML + cxx-qt |
|---|---|---|
| Liste 10 000 Zeilen | 60 fps, 0 Frames > 33 ms, ohne Tuning | 60 fps nur mit `reuseItems`/`cacheBuffer` (ohne: 38 fps, 90 Frames > 33 ms) |
| Mail öffnen (5 Korpus-Mails) | 68–136 ms | 39–160 ms |
| Mail-Körper scrollen | 60 fps, 0 Frames > 33 ms | 60 fps, 0 Frames > 33 ms |
| Kaltstart | 94 ms | 932 ms |
| Tippen Taste → Frame p50 | 12 ms | 4 ms |
| RSS nach 5 Mails | 146 MiB | 144 MiB |
| Newsletter „wie im Browser“ | 5/5 | 4/5 (max-width/Schriftgrößen ignoriert) |
| Binary / Kaltbau | 110 MB / 15,5 min | 102 MB / 11 min |
| Kernanbindung | im Prozess, ohne FFI | cxx-qt-Brücke |
| Schätzung voller Port | 57–78 PT | 57–84 PT |

Ausschlaggebend: Hauptkriterium des Nutzers ist ruckelfreie Darstellung (Frames > 33 ms beim Öffnen/Scrollen von HTML-Mails); dazu inline Newsletter-Darstellung ohne externen Browser. Berichte: `BERICHT-GPUI-SPIKE.md`, `BERICHT-VERGLEICH-GPUI.md`, `BERICHT-VERGLEICH-QT.md`.

## 2. Architektur

```
apps/linux-gpui/            eigener Cargo-Workspace (Tauri-Workspace bleibt unberührt)
  Cargo.toml                gpui =0.2.2, blitz-* =0.3.0-beta.4, reqwest =0.12.28 (exakt wie der Kern)
  vendor/xattr              Patch ENOATTR→ENODATA (glibc)        [patch.crates-io]
  vendor/serde_fmt          Patch From<Error> for fmt::Error      [patch.crates-io]
  src/main.rs               App-Start, Fenster (app_id com.coraxapp.corax), ohne --sandbox Exit 2
  src/core/host.rs          corax-host im Prozess, eigener Tokio-Thread, typisierte Anfragen, Kanäle
  src/core/models.rs        Rust-Typen der Kern-Antworten (serde), damit die UI nichts parst
  src/state/app.rs          Zustand: Liste, Auswahl, Karte, Suche, Bildabruf, Messläufe
  src/ui/sidebar.rs         Konten, Ansichten, Labels, Zähler
  src/ui/list.rs            Threadliste (gpui::list, variable Höhen), Splits/Datumsgruppen/Paging
  src/ui/thread.rs          Karte inline: Nachrichten, Blitz-Körper, Anhänge, Bildhinweis
  src/ui/toolbar.rs         Kopfzeile: Titel, Suche, Status
  src/input/textfield.rs    eigenes Textfeld (EntityInputHandler, Dead Keys mit Zurückhalten)
  src/html/mod.rs           Schnittstelle der HTML-Schicht
  src/html/view.rs          Blitz → vello_cpu-Bitmap → gpui img, Bild-Anbieter, Höhenmessung
  src/html/sanitize.rs      Sanitizer und Anzeige-Policy (Remote-Bilder blocken)
  src/html/resources.rs     Bild-Speicher: Anhänge, data:, nachgeladene Remote-Bilder
  src/html/fetch.rs         Bildabruf: SSRF-/Rebinding-Schutz, Grenzen, Signaturprüfung
  src/keys.rs               Tastatur: getipptes Zeichen, Einzeltasten + Strg-Kombinationen
  src/mailtext.rs           Textkörper → Rich-Text mit Hervorhebungen
  src/theme.rs              Omarchy-Theme aus ~/.local/state/omarchy/current/theme/colors.toml, live
  src/perf.rs               Frame-Messung (§4.11 des Briefings)
  src/hooks.rs              Test-Hooks (Befehlsdatei) — nur mit Feature test-hooks im Binary
  tests/html_sanitize.rs    Integrationstests Sanitizer (Korpus + bösartige Fälle)
  tests/html_resources.rs   Integrationstests Bild-Speicher
  tests/html_fetch.rs       Integrationstests Bildabruf (lokaler Testserver, keine echten Ziele)
```

Festlegungen:
- **L-E1 Kern:** `corax-host` direkt im Prozess, angesprochen über `Host::dispatch(cmd, json)` — JSON-Schnittstelle wie auf macOS, **kein FFI**. Der UI-Thread ruft nie blockierend; Anfragen gehen über Kanäle an einen eigenen Kern-Thread, Antworten und Ereignisse (`mail:new`, `sync:status` …) kommen als typisierte Werte in die Zustandsschicht (Gegenstück zu den Stores der Mac-App).
- **L-E2 Listen:** `uniform_list`/`list` mit Range-Callback; Daten seitenweise vom Kern.
- **L-E3 HTML:** Blitz für alle HTML-Körper; der Renderer bekommt **keinen** Netzzugriff, sondern fragt einen eigenen Anbieter. Remote-Bilder sind standardmäßig aus (wie die `block-remote`-Regel auf macOS); „Laden“ gibt sie **für genau diese Mail** frei, der Abruf läuft über die Laufzeit des Kerns mit SSRF-/Rebinding-Schutz (`html/fetch.rs`), Treffer landen im Bild-Speicher. Sanitizer läuft vor Blitz (Skripte, Formulare, Tracking-Pixel). Merken je Absender und eine Obergrenze des Speichers folgen in L4.
- **L-E4 Editor (festgelegt nach der Prüfung, L2):** `gpui-component =0.5.1` — die letzte Fassung mit `gpui ^0.2.2` — und daraus **nur** das mehrzeilige `Input`, hinter einer eigenen Fassade `ComposeEditor`, damit ein späterer Austausch eine Datei kostet. Auswahl, Zwischenablage, Dead Keys, Umlaute und Undo/Redo sind damit fertig (Tipp-Latenz p95 3,5 ms); Redo bekommt zusätzlich `Strg+Shift+Z` (Vorgabe der Bibliothek ist `Strg+Y`). Fett und Kursiv bauen wir selbst — `src/text/` der Bibliothek ist reine Anzeige, kein Rich-Text-Modell. Grundlage: `BERICHT-L2-EDITOR-EVAL.md`.
- **L-E5 Look:** Mock-up `Work/Tasks/2026-11-18-mail-app-mockup/linux.html` (Omarchy-Teil) mit den Funktionen und Elementen der macOS-App; Farben/Schrift aus dem aktiven Omarchy-Theme.
- **L-E6 Tastatur:** Belegung wie `TASTATUR.md` (Einzeltasten + Strg-Kombinationen statt ⌘). Ausgewertet wird das **getippte Zeichen** (`Keystroke::key_char`), nicht die GPUI-Keymap: `bind_keys` vergleicht die Tastenbelegung, damit gingen `/ ? # ! + -` und `\` auf der deutschen Tastatur verloren (Briefing §4.7). Einzeltasten wirken nur ohne Textfeldfokus.
- **L-E7 Abhängigkeiten:** Exakt gepinnt wird, was uns allein gehört: `gpui`, `blitz-*`, `gpui-component`, `reqwest` (in der Fassung des Kerns) und `rfd` (Datei-Dialog, s. u.). `tokio`, `serde`, `serde_json` und `chrono` teilen wir mit dem Kern — dort hält das Lockfile die Fassung, gebaut wird mit `--locked`; exakte Pins würden bei jedem Kern-Update Konflikte in der Auflösung erzeugen. Patches im Repo, `cargo update` nur gezielt mit Bau auf Tarantino. Lizenz des Pakets: `AGPL-3.0-only` wie `src-tauri` und die Kern-Crates.

  **`rfd =0.16.0`** (MIT) ist der Datei-Dialog für Anhänge und seit L2 im Baum. Grund für die
  direkte Abhängigkeit: Portale statt GTK. Gebaut werden nur die Features `xdg-portal` und
  **`async-std`**, also `org.freedesktop.portal.Desktop` (FileChooser); `gtk3`, `gtk4` und
  `wayland` bleiben aus.

  `async-std` statt `tokio` ist kein Geschmack, sondern nötig: `rfd` und `gpui` teilen sich
  **ein** ashpd 0.11.1, und `desktop/secret.rs` dort deklariert je Laufzeit-Feature ein
  `let mut x1` (`#[cfg(feature = "tokio")]` und `#[cfg(feature = "async-std")]`). Mit beiden
  Features bricht der Bau auf Linux (E0252/E0061/E0277, gesehen am 2026-11-22). `gpui` schaltet
  am selben ashpd `async-std` ein, also fährt `rfd` dieselbe Laufzeit; der Kern selbst bleibt
  bei tokio, der Dialog läuft dort als Future ohne eigene Runtime. Auf macOS ist ashpd gar
  nicht im Baum (nur Linux-Abhängigkeit), dort fällt der Konflikt nicht auf.

  Nachgeprüft am 2026-11-22:

  ```
  cargo tree -i rfd --target x86_64-unknown-linux-gnu
    rfd v0.16.0 ← corax-linux
  cargo tree -i ashpd@0.11.1 --target x86_64-unknown-linux-gnu
    ashpd v0.11.1 ← rfd v0.16.0, ← gpui v0.2.2        (keine neue ashpd-Kante)
  cargo tree --target x86_64-unknown-linux-gnu | grep -cE "gtk|gdk"   → 0
  ```

  Der Dialog läuft wie der Bildabruf auf der Laufzeit des Kerns (`Request::AnhaengeWaehlen`),
  die Oberfläche blockiert dabei nicht. Fehlt das Portal auf einem System, kommt eine leere
  Auswahl zurück; die App meldet dann „kein Anhang gewählt", statt etwas anderes zu starten.

## 3. Meilensteine

| | Inhalt | Abnahme (auf Tarantino, Sandbox) |
|---|---|---|
| **L1 Gerüst + Lesen** | Projektstruktur aus dem Spike, Zustandsschicht, Sidebar (Konten, Ansichten, Labels, Zähler), Threadliste mit Splits/Datumsgruppen/Paging, Thread inline aufklappen mit Blitz-Körper, Anhänge öffnen, Suche, Kürzel j/k/Enter/Esc//, Theme live | 10 000 Zeilen 60 fps, 0 Frames > 33 ms beim Scrollen und Öffnen; Korpus 5/5 korrekt |
| **L2 Aktionen + Verfassen** | gelesen/Stern/Erledigt/Papierkorb/Snooze, Rückgängig-Toast; Verfassen-Panel (unten rechts, minimierbar), Antworten/Allen/Weiterleiten, Kontaktvorschläge, Entwurf, Senden mit Undo; Editor (L-E4) inkl. Auswahl, Undo, Dead Keys, fett/kursiv. **Anhänge: gefährliche Typen sperren oder vorher fragen (AUDIT-L1 A2)** — `xdg-open` startet unter Linux sonst `.desktop`, `.jar`, `.sh` ohne Rückfrage | Tipp-Latenz p95 < 16 ms; Senden über Sandbox |
| **L3 Kalender** | Tag/Woche/Monat/Jahr/Liste, Termine inline aufklappen (Woche als Karte), anlegen/bearbeiten, Serien-Abfrage | Verhalten wie macOS laut Gruppengedächtnis |
| **L4 Einstellungen, KI, MCP** | Konten (App-Passwort + Verbindungstest), Splits, Signaturen, Snippets, KI-Panel (`I`, `⇧I`), MCP-Einstellungen, Befehlspalette (`:`) | Funktionsliste macOS abgehakt |
| **L5 Paket + Alltag** | PKGBUILD/Omarchy-Installation, `.desktop`, `mailto:`, Benachrichtigungen, Secret Service, Instanz-Lock, Updater-Weg | Installation auf Tarantino aus Paket, Alltagstest Nutzer |

Jeder Meilenstein: Briefing → Umsetzung → Beleg auf Tarantino → Audit an der Phasengrenze → Commit nach Live-Test des Nutzers.

## 4. Risiken

1. Blitz ist Beta (0.3.0-beta.4), Stylo/Vello-Kette: Pinnen, Patches im Repo, bei Bruch Rückfall `gpui-component` `TextView::html` (Lesemodus).
2. GPUI vor 1.0, API-Änderungen: exakt pinnen, Updates nur als eigenes Paket.
3. Editor-Reife: geklärt (L-E4). Offen bleibt IME jenseits Dead Keys; das prüft L2 am eigenen Feld.
4. HiDPI ungeprüft (Tarantino 1×): in L1 mit `GPUI_SCALE`/zweitem Monitor gegenprüfen, sonst in L5.
5. Bauzeit 15 min kalt / Binary 110 MB: für die Entwicklung inkrementell (~40 s) unkritisch; Release-Profil in L5 optimieren.
6. `gpui` auf crates.io endet bei **0.2.2**; Longbridge arbeitet ab `gpui-component` 0.6 mit einem eigenen Fork (`gpui-base` 0.10) weiter. Wir bleiben bewusst auf 0.2.2 — ein Umstieg hieße Fremd-Fork statt Upstream und eine Neubewertung von `view.rs`, Theme, Keys und Patches.
7. `gpui` 0.2.2, `TextSystem::layout_line` verschmilzt aufeinanderfolgende Textläufe gleicher Dekoration zu einem und vergleicht dabei die Schrift des vorigen Laufs mit sich selbst (`Some(font_run.font_id) == last_font`, immer wahr): die ganze Zeile nimmt die Schrift des **ersten** Laufs, Teilstellen mit anderem Gewicht oder Schnitt werden nicht gezeichnet (Foto `belege-l2/l2-55-anfang.png`). Workaround in `apps/linux-gpui/vendor/gpui-component/src/input/element.rs`: je Lauf ein unsichtbarer Unterstrich (Dicke 0) mit eigener Farbe je Schrift erzwingt die Laufgrenze, `gpui` selbst bleibt ungepatcht. Der Eingriff fällt bei einem Upgrade weg, das `layout_line` korrigiert (siehe `vendor/gpui-component/PATCH.md`).
