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
  Cargo.toml                gpui =0.2.2, blitz-* =0.3.0-beta.4 (exakt gepinnt), corax-host per Pfad
  vendor/xattr              Patch ENOATTR→ENODATA (glibc)        [patch.crates-io]
  vendor/serde_fmt          Patch From<Error> for fmt::Error      [patch.crates-io]
  src/main.rs               App-Start, Fenster (app_id com.coraxapp.corax, set_window_title)
  src/mailcore.rs           corax-host im Prozess, eigener Tokio-Thread, Kanäle zur UI
  src/theme.rs              Omarchy-Theme aus ~/.local/state/omarchy/current/theme/colors.toml, live
  src/blitzview.rs          Mail-Körper: Blitz → vello_cpu-Bitmap → gpui img, Scrollen, Links
  src/textfield.rs          Textfeld (EntityInputHandler, Dead Keys mit Zurückhalten)
```

Festlegungen:
- **L-E1 Kern:** `corax-host` direkt im Prozess (kein JSON-Dispatcher, kein FFI). UI-Thread ruft den Host nie blockierend; Aufrufe über Kanäle, Ergebnisse als Ereignisse in eine Zustandsschicht (Gegenstück zu den Stores der Mac-App).
- **L-E2 Listen:** `uniform_list`/`list` mit Range-Callback; Daten seitenweise vom Kern.
- **L-E3 HTML:** Blitz für alle HTML-Körper; Netz nur über eigenen Datei-/Cache-Anbieter, Remote-Bilder standardmäßig aus (wie macOS `rabe-block-remote`-Regel), Freigabe je Absender. Sanitizer vor Blitz (Skripte, Formulare, Tracking-Pixel).
- **L-E4 Editor:** zuerst `gpui-component` `Input` prüfen (L2); nur wenn untauglich, eigenes Feld ausbauen.
- **L-E5 Look:** Mock-up `Work/Tasks/2026-11-18-mail-app-mockup/linux.html` (Omarchy-Teil) mit den Funktionen und Elementen der macOS-App; Farben/Schrift aus dem aktiven Omarchy-Theme.
- **L-E6 Tastatur:** Belegung wie `TASTATUR.md` (Einzeltasten + Strg-Kombinationen statt ⌘), über GPUI-Actions/Keymap.
- **L-E7 Abhängigkeiten:** Versionen exakt pinnen, Patches im Repo, `cargo update` nur gezielt mit Bau auf Tarantino.

## 3. Meilensteine

| | Inhalt | Abnahme (auf Tarantino, Sandbox) |
|---|---|---|
| **L1 Gerüst + Lesen** | Projektstruktur aus dem Spike, Zustandsschicht, Sidebar (Konten, Ansichten, Labels, Zähler), Threadliste mit Splits/Datumsgruppen/Paging, Thread inline aufklappen mit Blitz-Körper, Anhänge öffnen, Suche, Kürzel j/k/Enter/Esc//, Theme live | 10 000 Zeilen 60 fps, 0 Frames > 33 ms beim Scrollen und Öffnen; Korpus 5/5 korrekt |
| **L2 Aktionen + Verfassen** | gelesen/Stern/Erledigt/Papierkorb/Snooze, Rückgängig-Toast; Verfassen-Panel (unten rechts, minimierbar), Antworten/Allen/Weiterleiten, Kontaktvorschläge, Entwurf, Senden mit Undo; Editor (L-E4) inkl. Auswahl, Undo, Dead Keys, fett/kursiv | Tipp-Latenz p95 < 16 ms; Senden über Sandbox |
| **L3 Kalender** | Tag/Woche/Monat/Jahr/Liste, Termine inline aufklappen (Woche als Karte), anlegen/bearbeiten, Serien-Abfrage | Verhalten wie macOS laut Gruppengedächtnis |
| **L4 Einstellungen, KI, MCP** | Konten (App-Passwort + Verbindungstest), Splits, Signaturen, Snippets, KI-Panel (`I`, `⇧I`), MCP-Einstellungen, Befehlspalette (`:`) | Funktionsliste macOS abgehakt |
| **L5 Paket + Alltag** | PKGBUILD/Omarchy-Installation, `.desktop`, `mailto:`, Benachrichtigungen, Secret Service, Instanz-Lock, Updater-Weg | Installation auf Tarantino aus Paket, Alltagstest Nutzer |

Jeder Meilenstein: Briefing → Umsetzung → Beleg auf Tarantino → Audit an der Phasengrenze → Commit nach Live-Test des Nutzers.

## 4. Risiken

1. Blitz ist Beta (0.3.0-beta.4), Stylo/Vello-Kette: Pinnen, Patches im Repo, bei Bruch Rückfall `gpui-component` `TextView::html` (Lesemodus).
2. GPUI vor 1.0, API-Änderungen: exakt pinnen, Updates nur als eigenes Paket.
3. Editor-Reife (Auswahl, Undo, IME jenseits Dead Keys): L2 beginnt mit Prüfung von `gpui-component` `Input`.
4. HiDPI ungeprüft (Tarantino 1×): in L1 mit `GPUI_SCALE`/zweitem Monitor gegenprüfen, sonst in L5.
5. Bauzeit 15 min kalt / Binary 110 MB: für die Entwicklung inkrementell (~40 s) unkritisch; Release-Profil in L5 optimieren.
