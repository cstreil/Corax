# Rabe native — Architektur

Stand 2026-11-18 · Entscheidung: **Option A** — SwiftUI/AppKit (macOS) + Qt 6/QML (Linux, Skins KDE und Omarchy) auf dem unveränderten Rust-Kern `comail-core`. Kein Tauri, kein Electron.

## 1. Ist-Stand (geprüft)

- `src-tauri/crates/comail-core` — Tauri-frei, ~55k Zeilen Rust: IMAP/SMTP, SQLite (WAL, FTS5), Sync, Suche (FTS5 + Embeddings), KI, CalDAV, MCP, Linux-Desktop-Palette (`system_theme.rs`). Einstieg `Core::start(Paths) -> Result<Core>`, `Core` ist `Clone`, alle Methoden `async` (tokio).
- `src-tauri/src/commands.rs` — 105 dünne `#[tauri::command]`-Wrapper „deserialisieren → Core → serialisieren“. Fehler als JSON `{"code","message"}` (`CoreError::to_ipc_json`).
- `src-tauri/src/events.rs` — leitet `CoreEvent` (tokio `broadcast`) an die UI weiter, bündelt `MailUpdated` über 100 ms.
- `src-tauri/src/lib.rs` — `isolate_instance` (Datenverzeichnis/Keyring-Service aus Bundle-ID), Logging, Tray, Deep-Link `mailto:`, Single-Instance.
- `src-tauri/src/notifications.rs` (369 Z.) — entscheidet und zeigt Desktop-Benachrichtigungen (Tauri-Plugin).
- HTML-Mails: `src/components/thread/MessageCard.tsx` baut ein `srcdoc` mit CSP `default-src 'none'; style-src 'unsafe-inline'; img-src data: cid:` (Remote-Bilder nur per Einstellung/Override), `referrer no-referrer`, Dark-Mode-Anpassung per JS nach dem Laden.
- Mockups: `Work/Tasks/2026-11-18-mail-app-mockup/` — `index.html` (macOS Papier/Graphit/Glas, iOS), `linux.html` (KDE Breeze hell/dunkel mit Befehlsleiste, Omarchy im Terminal-Look mit Modi NORMAL/INSERT/SUCHE/BEFEHL und Theme-Menü), Daten `mail-data.js`, Screenshots `previews/`.
- Werkzeuge auf dem Mac: Swift 6.4.2, **nur Command Line Tools (kein Xcode, kein `actool`, kein `xcodebuild`)**, Rust 1.99.1 (Homebrew, kein rustup), Qt 6.12 **nur qtbase** (kein QtQuick). Linux-Testgeräte: Scott (x86, CachyOS, Plasma 6.8 Wayland), Burton (ARM, Omarchy/Hyprland).

## 2. Zielbild

```
                ┌────────────── comail-core (unverändert) ──────────────┐
                └───────────────────────────▲────────────────────────────┘
                                            │ Rust-API
                ┌───────────────────────── rabe-host ────────────────────┐
                │ Start/Isolation/Logging/Instanz-Lock · tokio-Runtime    │
                │ dispatch(cmd, json) → json  (Port von commands.rs)      │
                │ UiEvent-Strom (Port von events.rs, 100-ms-Bündelung)    │
                │ HostDelegate-Trait (open_url, open_path, notify, …)     │
                │ html::wrap_for_display (CSP, Theme-Variablen)           │
                └───────▲──────────────────────────────────▲─────────────┘
                        │                                  │ Rust direkt
              rabe-uniffi (UniFFI)                 rabe-qt (cxx-qt, Binary)
                        │ Swift-Bindings                   │ QObjects/ListModels
              apps/macos  SwiftUI + AppKit          apps/linux/qml  QML-Skins kde | omarchy
```

### Ablage

| Pfad | Art | Inhalt |
|---|---|---|
| `src-tauri/crates/rabe-host/` | lib, Member des bestehenden Workspace | Host-Logik, Dispatcher, Events, HTML-Hülle |
| `src-tauri/crates/rabe-host/src/bin/rabe-cli.rs` | bin | `rabe-cli invoke <cmd> '<json>'`, `rabe-cli events` — Test ohne UI |
| `src-tauri/crates/rabe-uniffi/` | staticlib, Member | UniFFI-Fassade für Swift |
| `apps/macos/` | SwiftPM-Paket `Rabe` | macOS-App; `scripts/build-app.sh` baut `.app` ohne Xcode |
| `apps/linux/` | eigener Cargo-Workspace, Crate `rabe-qt` | Linux-App (cxx-qt, Cargo-only-Build), `qml/`, `packaging/PKGBUILD` |

Begründung: Kern und Tauri-App bleiben unangetastet (Upstream-Merges bleiben billig, die Tauri-App bleibt bis zur Ablösung Alltags-App). Zusätzlich ändert sich in `src-tauri/Cargo.toml` nur die Zeile `members`. Qt-Abhängigkeiten liegen außerhalb des Tauri-Workspace, damit macOS- und Tauri-Builds kein QtQuick brauchen. `rabe-qt` bindet `rabe-host` per Pfad ein (`../../src-tauri/crates/rabe-host`).

## 3. Kernentscheidungen

| # | Entscheidung | Begründung | Verworfen |
|---|---|---|---|
| E1 | Brücke = **ein JSON-Dispatcher** `dispatch(cmd, args_json)` mit denselben Command-Namen und Argumenten wie `commands.rs` | Wiederverwendet serde-Typen und den erprobten Tauri-Vertrag 1:1; `src/ipc/*.ts` dokumentiert ihn bereits; 105 Commands mechanisch portierbar; zwei Nutzer (Swift, QML-Dialoge). JSON-Kosten für eine 50er-Seite liegen im Bereich von 0,1–1 ms. | UniFFI-Records für alle Typen (Spiegel von ~60 Typen, Settings mit ~60 Feldern, hoher Pflegeaufwand); `uniffi`-Derives im Kern (ändert Upstream-Code) |
| E2 | Linux-Listen als **Rust-`QAbstractListModel` über cxx-qt**, typisiert direkt auf `Core` | ListView-Performance, kein JSON im Scroll-Pfad | QML-JS-Arrays aus JSON (zu langsam bei 10k Zeilen) |
| E3 | macOS-Mailliste = **AppKit `NSTableView`** (view-based) in SwiftUI eingebettet, Rest SwiftUI | Variable Zeilenhöhen mit animiertem Inline-Aufklappen (`noteHeightOfRows`), präzise Tastatur-/Selektionskontrolle, 10k+ Zeilen | SwiftUI `List` (Höhenanimation und Tastatursteuerung unzuverlässig) |
| E4 | HTML: macOS `WKWebView` je aufgeklappter Nachricht; Linux **nativ als Text** (QML `Text`/`TextEdit`, RichText-Subset) und **QtWebEngine nur auf Anforderung** („Original anzeigen“, per `Loader`) | WKWebView ist Systembestand; QtWebEngine ist Chromium (≥100 MB RAM) und soll erst laden, wenn nötig | QtWebEngine immer (RAM, Startzeit) |
| E5 | HTML-Hülle zentral in `rabe-host::html::wrap_for_display` mit derselben CSP wie `MessageCard.tsx`; Seiten-JS aus; Dark-Mode-Anpassung als App-Skript (WKUserScript bzw. `runJavaScript`) | Eine Sicherheitsgrenze für beide Plattformen, gleich der freigegebenen Tauri-Grenze | eigene CSP je UI |
| E6 | Linux: **ein** Programm, Skin per Laufzeit: `omarchy` wenn `~/.local/state/omarchy/current/theme/colors.toml` existiert und Hyprland läuft, sonst `kde`; Override `RABE_SKIN`/Einstellung | Kein zweites Toolkit, gemeinsamer Zustand und Modelle | ratatui-TUI (keine Pixelanimation, kein Trackpad-Momentum — siehe Chat 2026-11-18) |
| E7 | KDE-Skin: QtQuick Controls mit Stil `org.kde.desktop` (Fallback `Fusion`), Farben aus `kdeglobals`; **kein Kirigami in M1** | Echter Breeze-Look, minimale Abhängigkeiten | Kirigami (zusätzliche Abhängigkeit ohne M1-Nutzen) |
| E8 | macOS-Build **ohne Xcode**: Rust-Staticlib + UniFFI-Swift-Datei + C-Modulmap als SwiftPM-Target, `.app` per Skript, Signatur mit vorhandener `Apple Development`-Identität | Läuft auf dem jetzigen Mac; Xcode bleibt optional | XCFramework (braucht `xcodebuild`) |
| E9 | Mindestversion macOS 26 | `glassEffect` (Glas-Theme), Observation | ältere macOS (Glas nur mit Ersatzmaterial) |
| E10 | Eigene Instanz `de.streil.rabe.native` (eigenes Datenverzeichnis und Keyring-Service) bis zur Ablösung; erst dann `de.streil.rabe` | Kein paralleler Zugriff zweier Sync-Engines auf eine DB | Mitbenutzung der Release-DB |

## 4. Schnittstellen

### rabe-host (Rust)

```rust
pub struct HostConfig {
    pub identifier: String,          // Bundle-ID / App-ID, z. B. "de.streil.rabe.native"
    pub release_identifier: String,  // "de.streil.rabe"
    pub resource_dir: Option<PathBuf>,
}

pub trait HostDelegate: Send + Sync + 'static {
    fn open_url(&self, url: String);             // OAuth, Links
    fn open_path(&self, path: String);           // Anhang öffnen, Log-Ordner
    fn on_event(&self, event: UiEvent);          // aus Hintergrund-Thread; UI wechselt selbst auf Main
}

pub struct Host { /* Runtime, Core, Lock */ }

impl Host {
    pub fn start(cfg: HostConfig, delegate: Arc<dyn HostDelegate>) -> Result<Host, HostError>;
    pub async fn dispatch(&self, cmd: &str, args_json: &str) -> Result<String, HostError>;
    pub fn core(&self) -> &comail_core::Core;    // für rabe-qt
    pub fn runtime(&self) -> &tokio::runtime::Runtime;
    pub fn shutdown(self);
}

#[derive(Serialize)] #[serde(tag = "name", content = "payload")]
pub enum UiEvent {           // Namen wie die Tauri-Events
    #[serde(rename = "mail:updated")] MailUpdated { thread_ids: Vec<i64> },   // gebündelt 100 ms
    #[serde(rename = "mail:new")]     MailNew { account_id: i64, thread_ids: Vec<i64> },
    #[serde(rename = "sync:progress")] SyncProgress(SyncProgress),
    // … 1:1 alle Varianten aus events.rs::emit
}

pub struct HostError { pub code: String, pub message: String } // aus CoreError::code()/to_string()
```

- `dispatch`: Argumente als JSON-Objekt mit den Parameternamen aus `commands.rs` in camelCase (wie Tauri sie vom Frontend erwartet), Rückgabe = serde-JSON des Ergebnisses. Unbekanntes Kommando → `HostError{code:"unknown_command"}`; ungültige Argumente → `code:"bad_args"`.
- Tauri-gebundene Commands: `start_oauth`/`reauth_account` → `delegate.open_url`; `open_attachment`, `open_logs_dir` → `delegate.open_path`; `focus_main_window`, `cinema_close` entfallen (`unknown_command`); `ui_ready` → `Core::notify_ui_ready`.
- `Host::start` erwirbt `flock` auf `<data_dir>/instance.lock`; belegt → `HostError{code:"instance_locked"}`.

### rabe-uniffi (Swift sieht)

```rust
#[uniffi::export(with_foreign)]
pub trait RabeDelegate: Send + Sync { fn open_url(&self, url: String); fn open_path(&self, path: String); fn on_event(&self, event_json: String); }

#[derive(uniffi::Object)] pub struct RabeHost;
#[uniffi::export(async_runtime = "tokio")]
impl RabeHost {
    #[uniffi::constructor] pub fn start(identifier: String, resource_dir: Option<String>, delegate: Arc<dyn RabeDelegate>) -> Result<Arc<Self>, RabeError>;
    pub async fn invoke(&self, cmd: String, args_json: String) -> Result<String, RabeError>;
    pub fn html_for_display(&self, html: String, theme_json: String, load_remote_images: bool) -> String;
}
#[derive(uniffi::Error)] pub enum RabeError { Core { code: String, message: String } }
```

Swift-Seite: `RabeClient` (actor) mit typisierten Wrappern (`listThreads(view:…) async throws -> ThreadPage`) und `Codable`-Typen gespiegelt aus `src/ipc/*.ts`.

### rabe-qt (QML sieht)

- `Rabe` (Singleton-QObject): `invoke(cmd, argsJson) → Promise-artig über Signal `result(requestId, json, error)``, Signale je UiEvent, Property `skin`.
- `ThreadListModel` (QAbstractListModel): Rollen `threadId, subject, snippet, from, date, unread, starred, hasAttachments, labels, group`; Properties `view, splitId, accountId, labelId, folderId`; `canFetchMore/fetchMore` (Seiten à 100); reagiert auf `mail:updated` mit gezieltem Nachladen der betroffenen Zeilen.
- `ThreadDetailModel`, `AccountsModel`, `SidebarModel`, `Theme` (Palette aus `system_theme.rs`, Dateibeobachtung von `colors.toml`/`kdeglobals`, Signal `changed` → 450-ms-Farbübergang).

## 5. Funktionsumfang

**M1 (was die Mockups zeigen):** IMAP-Konto per App-Passwort anlegen · Sidebar mit Konten, Ansichten, Labels, Ungelesen-Zählern · Liste mit Tabs (Splits), Datumsgruppen, Paging · Thread inline aufklappen, Nachrichten, Anhänge öffnen/speichern, HTML sicher · Aktionen gelesen/ungelesen, Stern, Erledigt, Papierkorb, Snooze (Presets), Rückgängig mit Toast · Antworten/Allen/Weiterleiten/Neu (Text), Kontaktvorschläge, Entwurf, Senden mit Undo-Send · Suche · Kurzbefehle wie Comail und Befehlspalette (`⌘K` / KDE-Befehlsleiste / Omarchy `:`) · Themes: macOS Papier/Graphit/Glas, KDE Breeze hell/dunkel + Systemakzent, Omarchy live · Sync-Status/Offline · Benachrichtigung neuer Mail.

**M2 (Parität):** **Erstes Paket M2.0 `RabeKit`** (Entscheidung Nutzer 2026-11-19, Vorbereitung iOS): plattformneutraler Swift-Code (`Core/`: RabeClient, Models, EventRouter, DelegateBridge ohne AppKit; `State/`: Stores; Theme-Werte; `Support/Format`, `Strings`) als eigenes Library-Target `RabeKit` im SwiftPM-Paket, Mac-App nur noch UI (`NSTableView`, Fenster, Menüs). Regel ab dann: kein `import AppKit` in `RabeKit`. Umsetzung durch Coder nach Abschluss der Audit-P2-Nacharbeiten (Dateiumzug würde laufende Audit-Verweise stören). Danach Kalender, KI (Zusammenfassung, Entwürfe, Ask, Palette in Klartext), Splits-/Regel-Editor, Snippets, Avatar-Layout, vollständige Einstellungen, MCP-Einstellungen, Abmelden, Tray/Menüleisten-Icon, `mailto:`.

**M2-Kalender-Nachträge (Nutzer 2026-11-20):** M2.12 CalDAV verbinden + Ansichtsknöpfe + Tastaturbedienung (`BRIEFING-M2.12.md`); danach **Jahresansicht** und **Terminliste** wie in Apple Kalender auf dem iPhone, Einträge klappen inline auf wie in der Mailliste (Entwurf Frontend).

**M3 (Ablösung):** Updater (macOS Sparkle o. ä., Linux Paket), PKGBUILD, Instanz-Lock auch in der Tauri-App, Umschalten auf `de.streil.rabe`, **Siri/Kurzbefehle** (App Intents nativ nachbauen; Vorbild `src-tauri/swift/ComailIntents.swift`, sechs Aktionen: Bestätigungscode, Ungelesene, Überblick, Frag das Postfach, Mail verfassen, Suche; Entscheidung Nutzer 2026-11-20). **Am Ende von M3:** OAuth-Konten (Gmail, Microsoft 365). Bis dahin liegt der Fokus auf iCloud/IMAP (Entscheidung Nutzer 2026-11-19).

**Nach M3 (vorgemerkt, Entscheidung Nutzer 2026-11-20): JMAP** — erst wenn alles andere läuft und wir beginnen, Teile des Comail-Kerns durch eigenen Code zu ersetzen. Anlass: JMAP-only-Anbieter (Mailflare, Thundermail). Ist-Stand: Sync-Engine (`sync/`, ~5,7 k Zeilen) und `provider/MailboxBehavior` sind IMAP-gebunden, ohne Transport-Abstraktion; Kalender hat mit CalDAV und Graph schon zwei Backends. Vorgehen dann: zuerst Transport-Schicht aus der Sync-Engine lösen, dann JMAP-Mail (`Email/changes`, `EmailSubmission`, Push); JMAP-Kalender erst prüfen, sobald die Spezifikation stabil ist.

**Nach M3, Kandidaten (Abgleich mit Superhuman, `Work/Tasks/2026-11-20-superhuman-re/REPORT.md`, Entscheidung Nutzer 2026-11-20):** Nachfass-Erinnerungen bei ausbleibender Antwort und vorbereitete KI-Entwürfe vor dem Öffnen — beide lokal ohne Server machbar, brauchen Kern-Arbeit. **Kern-Ersatz-Phase, gesammelt (Entscheidung Nutzer 2026-11-21: größere Kern-Änderungen erst besprechen, sonst hierher):** Serien bearbeiten/löschen mit Geltungsbereich `this|following|all` (Entwurf `Work/Tasks/2026-11-19-rabe-native-m2/BERICHT-M2.18a.md`, ≈ 3–3,5 Tage; bis dahin Übergang: jede Wiederholung einzeln in Anzeige/Navigation, Bearbeiten nur „Alle“) · `calendar_status` mit Fehlerursache · Organisator-Aliasse · Papierkorb, wenn die Mail noch in einem anderen Ordner liegt · Selbstheilung verwaister `drafts_meta` + SQL-Fehlertext statt `code=db` · unsichtbare Zeichen in Newslettern (`wrapForDisplay`) · Gesten-ID für Undo · Erinnerung je Termin · JMAP.

**M3-Festlegungen (Nutzer 2026-11-21):** Der Fork heißt **Corax** (`de.streil.corax`); „Rabe“ bleibt der finalen, eigenständigen App vorbehalten (Repo `cstreil/rabe-app`). M3 umfasst: M3.1 Umbenennen, Bundle-Kennung und Übernahme der Daten aus `de.streil.rabe.native` · M3.2 Sparkle, Updates aus einem eigenen öffentlichen Releases-Repo · M3.3 Siri/App Intents (neu geschrieben) · M3.4 OAuth nur Google. **Microsoft/Azure erst nach M3.** Briefings in `Work/Tasks/2026-11-21-rabe-native-m3/`.

**Finale Kennungen (Nutzer 2026-11-21):** `de.streil.corax` ist eine Zwischenkennung. Vor dem ersten Push kommt als **M3.5** der Wechsel auf **`com.coraxapp.corax`** (Domain `coraxapp.com`, Sandbox `com.coraxapp.corax.sandbox`). Der Datenumzug liest dann zuerst aus `de.streil.corax`, danach aus `de.streil.rabe.native`. Im selben Paket ziehen GitHub-Organisation, Releases-Repo, Sparkle-Feed-URL und der EdDSA-Schlüssel um. Die finale App Rabe bekommt `com.rabeapp.rabe` (Domain `rabeapp.com`).

**Backend-Richtung (Vorschlag 2026-11-21, offen):** Bei reinem Apple-Fokus wird Comail vollständig durch ein eigenes Swift-Backend `RabeEngine` ersetzt. Kalender und Erinnerungen laufen über `EventKit`, Kontakte über `Contacts`, Mail, Kalender, Kontakte und später Aufgaben über JMAP, Mail zusätzlich über IMAP mit `swift-nio-imap`, gespeichert in GRDB/SQLite. Danach ist kein AGPL-Code mehr enthalten. Aufwand ≈ 80–120 Coder-Tage. Details, Reihenfolge B0–B8 und offene Fragen in `ENTSCHEIDUNG-BACKEND.md`.

**Bewusst nicht:** Team-Funktionen (geteilte Threads, Kommentare, gemeinsame Entwürfe/Bausteine; bräuchten einen Server) und Lesebestätigungen/Smart Send per Tracking-Pixel.

## 6. Leistungsbudget (Abnahme M1)

Referenz: Dev-Datenbank mit ~11k Mails, Apple Silicon bzw. Scott.

| Messgröße | Ziel |
|---|---|
| Kaltstart bis Liste sichtbar | ≤ 400 ms |
| Thread aus Cache aufklappen bis erste Darstellung | ≤ 50 ms (Text), ≤ 120 ms (HTML) |
| Scrollen 10k Threads | keine Frames > 16,7 ms (Debug-Overlay zählt Hänger) |
| Aktion (Erledigt) bis Zeile weg | ≤ 1 Frame nach Tastendruck (optimistisch) |
| Speicher **UI-Anteil** (App-RSS minus Kern-Anteil, plus WebContent-/GPU-/Networking-Prozesse), Leerlauf | ≤ 50 % des Tauri-UI-Anteils; beide frisch gestartet, gleiches Embedding-Modell (Entscheidung Nutzer 2026-11-19; Gesamt-RSS wird vom Modell im Kern bestimmt) |

Messung: `rabe-host` loggt Zeitstempel (`tracing`, Ziel `perf`), UIs loggen Erst-Frame und Hänger.

## 7. Phasen und Zuständigkeit

| Phase | Inhalt | Wer | Prüfung |
|---|---|---|---|
| P0 | Machbarkeit: `rabe-host`-Gerüst (Start, Lock, `dispatch` für 4 Commands), `rabe-cli`, `rabe-uniffi`, SwiftPM-Fenster mit Inbox-Liste; cxx-qt-Fenster mit Liste auf Scott | Coder | Auditor kurz |
| P1 | Vollständiger Dispatcher (alle Commands), UiEvents, HTML-Hülle, Benachrichtigungslogik, Vertragstests | Coder | Auditor (Sicherheit HTML/FFI) |
| P2 | macOS-UI M1 | Frontend | Auditor |
| P3 | Linux-UI M1 (erst KDE, dann Omarchy) | Frontend | Auditor |
| P4 | M2-Parität | Coder + Frontend | Auditor |
| P5 | M3-Ablösung | Coder | Auditor |

**Reihenfolge (Nutzer, 2026-11-18):** erst macOS (P1 → P2 → macOS-Teile von P4) bis es im Alltag läuft; P3 (Linux) beginnt erst danach. Xcode 27.2 ist seit 2026-11-18 installiert und aktiv → SwiftUI-Makros verfügbar, Abweichung zu E8 aus P0 entfällt (App-Einstieg darf wieder SwiftUI `App` sein).

## 7a. Ergebnis P0 (2026-11-18, Bericht `Work/Tasks/2026-11-18-rabe-native-p0/BERICHT.md`)

- Steht: `rabe-host` (+ `rabe-cli`), `rabe-uniffi` (uniffi 0.32.2), `apps/macos` (SwiftPM + `scripts/build-app.sh`), `Rabe Native.app` ohne Xcode gebaut und signiert, Inbox mit Paging und `mail:updated`.
- Messwerte warm: Core-Start 697 ms, erste Liste 709 ms; `list_threads` 0,51 ms (20 Threads, 9,8 KB JSON), `get_thread` 3,96 ms. Kalt 6,2 s. → E1 (JSON-Dispatcher) bestätigt; Startzeit ist Kern-Start, nicht Brücke.
- **Abweichung E8:** Ohne Xcode fehlen die SwiftUI-Makro-Plugins (`SwiftUIMacros.StateMacro`), Observation-Makros sind da. Einstieg deshalb AppKit (`NSApplication`/`NSWindow`/`NSHostingView`); `@State` in SwiftUI-Views nicht nutzbar.
- **Kern-Befund:** `credentials::adopt_legacy` kopiert Zugangsdaten aus `com.deanoss.comail.dev` in den aktuellen Keyring-Service → die Native-Instanz synchronisiert echt und legt eigene Keyring-Einträge (u. a. `mcp_token`) an. Neue Instanzen sind also nie „ohne Zugangsdaten“.
- Weitere Punkte für P1: `MACOSX_DEPLOYMENT_TARGET=26.0` für Rust setzen (Objekte waren 27.x); Core-Start vom Hauptthread lösen (Fenster sofort, Liste nach Start); MCP-Server in Nicht-Release-Instanzen nicht auf dem Release-Port starten; Embedding-Modell (458 MB) wird je Instanz neu geladen.
- Linux-Spike offen (Scott nicht erreichbar).

## 7b. Ergebnis P1 und Festlegungen (2026-11-18, `BERICHT-P1.md`)

- 102 von 105 Commands dispatchbar (Ausnahmen `focus_main_window`, `cinema_close`, `ui_ready`), 0 `unsupported`; 30 Tests (Parität liest `generate_handler!`). Fenster sichtbar nach Median 148 ms, Core-Start im Hintergrund, MCP der Native-Instanz auf 47833.
- **E9 geändert: Mindestversion macOS 27.0.** Grund: Homebrew-`rustc` 1.99.1 liefert die Stdlib mit `minos 27.0` (16 `ld`-Warnungen); einziger Nutzer läuft auf 27.3. Rückweg zu 26 nur mit rustup-Toolchain (Systeminstallation, braucht Freigabe).
- **Sandbox-Instanz** `de.streil.rabe.native.sandbox`: DB aus den Mockup-Daten (`mail-data.js`), Konto mit nicht auflösbarem Host (`*.invalid`) → schreibende Aktionen laufen lokal durch, erreichen nie einen Server. Grund: `credentials::adopt_legacy` gibt jeder Nicht-Release-Instanz echte Zugangsdaten, „ohne Zugangsdaten“ gibt es nicht. Schreibende UI-Tests nur in der Sandbox; die Native-Instanz (echtes iCloud-Konto) bleibt bis zur Freigabe des Nutzers lesend.
- **Navigation macOS:** Das Mockup hat keine Seitenleiste. Ansichten und Konten wechselt man über den Fenstertitel (Menü), die Menüleiste „Postfach“ und `⌘K`. Keine Seitenleiste in M1.
- Benachrichtigungen brauchen `requestAuthorization` beim ersten Start (P2).

## 7c. Audit P1 (2026-11-19, `AUDIT-P1.md`)

- Freigabe zunächst nein: 0 kritisch, 3 hoch (H1 Sandbox-Reset löscht über `COMAIL_DATA_DIR` beliebige Verzeichnisse; H2 Release-Keyring/-Verzeichnis per Umgebungsvariable erreichbar; H3 vier Commands weichen vom IPC-Vertrag ab), 6 mittel. `html.rs`, `notify.rs`, Defaults und `flock` sind korrekt.
- Nacharbeit: Rust (H1–H3, M1 URL-Allowlist im Host, M4 `shutdown`, M5 CLI nur lesend gegen die Native-Instanz, Rust-Teile von M2/M3) → Coder P1c; Swift (WKWebView-Härtung M2, Mitteilungsberechtigung M3, Main-Thread, `shutdown`) → Frontend in P2. Danach Nachprüfung durch Auditor.
- M6: `credentials::adopt_legacy` (Fork-Code, Commit `4a1fbbc`, nicht Upstream) gab jeder Nicht-Release-Instanz Zugangsdaten aus `com.deanoss.comail.dev`. **Entscheidung Nutzer 2026-11-19:** Übernahme nur noch `com.deanoss.comail.dev → de.streil.rabe.dev`; einzige erlaubte Kern-Änderung in diesem Vorhaben.
- Nachprüfung (2026-11-19): H1/H3/M4 geschlossen; H2/M5 über frei wählbaren Identifier umgehbar → **Grundregel P1d:** `rabe-host` akzeptiert nur exakt `de.streil.rabe.native` und `de.streil.rabe.native.sandbox`; Datenverzeichnis und Keyring-Service ausschließlich daraus abgeleitet, `COMAIL_DATA_DIR`/`COMAIL_KEYRING_SERVICE` werden ignoriert und überschrieben.

- **Nachprüfung 2 (2026-11-19): P1 freigegeben** mit Auflagen → P1e: `notifications_allowed` = `false` nur bei endgültiger Ablehnung; `rabe-cli` startet die Native-Instanz gar nicht mehr (Core-Start weckt Scheduler/Embedding auch read-only; Einsicht per `sqlite3 -readonly`); `open_attachment` setzt Quarantäne-Attribut und übergibt den kanonischen Pfad.

## 7d. Ergebnis P2 (2026-11-19, `Work/Tasks/2026-11-18-rabe-native-p2/`)

- macOS-UI M1 steht: Liste/Inline-Aufklappen, HTML, Tastatur, Inline-Antwort mit Undo-Send, Themes Papier/Graphit/Glas. Zeiten (echte Instanz): Liste 8–21 ms, Thread Text 24–27 ms, HTML 32–93 ms → Budget §6 erfüllt.
- **Speicherbudget (§6) verfehlt und falsch angenommen:** Native 489 MiB RSS vs. Tauri 164 MiB (`MESSUNG.md`). Ursache ist der Kern, nicht die UI: Die Native-Instanz (Settings aus der Dev-DB) lädt `paraphrase-multilingual-MiniLM-L12-v2` (449 MB, komplett im Heap), der Release `bge-small-en-v1.5` (127 MB). Kern ohne Modell ≈ 24 MiB. Die UI-Prozesse (WebKit) sind nativ kleiner als in Tauri (40 vs. 68 MiB). Annahme „WebView dominiert den Speicher“ war falsch; das Ziel muss neu gefasst werden (UI-Anteil, gleiches Modell, beide frisch gestartet).
- **Entscheidung Nutzer 2026-11-19:** Mehrsprachiges Modell bleibt (deutsche Mails). Speicherziel auf UI-Anteil umgestellt (§6). Kern-Optimierung (Modell erst bei Bedarf laden bzw. per mmap) als eigenes Paket nach P2 vorgemerkt — wäre ein Eingriff in Upstream-Code.
- Animation: fehlendes Höhenwachstum, Renderfehler beim ersten Zyklus → P2c (Frontend).
- Mitteilungen: Bundle `de.streil.rabe.native` steht auf `denied` → Nutzer muss in den Systemeinstellungen freigeben.

- P2c/P2d (2026-11-19): Aufklapp-Animation korrekt (360 ms, kein Leer- oder Überstand); Tastaturbelegung nach `TASTATUR.md`; Nachladen 0,2–0,3 ms Main-Thread je Seite (vorher 12–17 ms); Scrollen „Alle“ 0–1 Hänger nach dem Warmlauf, einzelne 33-ms-Frames ungeklärt. Offen: Fokus liegt nach dem Start gelegentlich im Suchfeld. Nächster Schritt: Audit P2.

- **Audit P2 (2026-11-19, `AUDIT-P2.md`):** Sicherheit freigegeben, lesender Alltag ja; Schreibsperre erst nach W1–W5: W1 Rückgängig trifft per `undo_last` das automatische `mark_read` statt der Nutzeraktion (Kern kennt kein gezieltes Undo, `revert_action` ist privat → Lösung in der App: `mark_read` während des Toast-Fensters zurückhalten); W2 Entwurfs-Speichern nicht serialisiert; W3 Auswahl springt bei Listen-Update; W4 `save_attachment` falsche Argumentform; W5 Bundle mit Test-Hooks. → P2e (Coder).

## 8. Risiken

1. **Kein Xcode:** SwiftPM-App-Bau per Skript ist machbar, aber ohne Instruments/Asset-Katalog. Icon als `.icns` (vorhanden in `src-tauri/icons/`). Fällt P0 hier durch → Xcode installieren.
2. **cxx-qt mit Pfad-Abhängigkeit in einen fremden Workspace** (Workspace-Vererbung von `comail-core`): in P0 mit `cargo check` belegen; Rückfall: `rabe-qt` als Member in `src-tauri` mit `default-members` ohne `rabe-qt`.
3. **Inline-Aufklappen mit HTML in Tabellenzeilen:** Höhe des `WKWebView` erst nach Laden bekannt → Platzhalterhöhe aus Text-Snippet, dann animiert anpassen.
4. **HTML ohne WebEngine unter Linux** sieht bei Newsletter-HTML schlechter aus → Knopf „Original anzeigen“ ist Pflicht in M1.
5. **Doppelte UI-Arbeit** über zwei Plattformen; Mitigation: Store-Logik (Paging, optimistische Aktionen, Undo) in `rabe-host` halten, wo sie plattformneutral ist — aber erst, wenn beide UIs sie wirklich brauchen.
6. **AGPL-3.0-only** gilt für die neuen Apps weiter (abgeleitetes Werk).
7. **Undo bei sehr großen Gruppen (W7):** `undo_last` fasst nur Aktionen ±150 ms um die jüngste; ab etwa 750 Threads in einem Aufruf bleibt ein Rest zurück. Die App lehnt Gruppen über 500 Threads ab (`GroupActionLimit`). Der Kern-Fix (Gesten-ID für Undo) ist vorgemerkt für den Moment, in dem Comail-Code ersetzt wird.

## 8a. Ergebnis M2 (2026-11-20, `Work/Tasks/2026-11-19-rabe-native-m2/`)

- M2.0–M2.6 liegen unter `apps/macos`: `RabeKit` (plattformneutral, `check-rabekit.sh` erlaubt nur Foundation/Observation/os/RabeBindings/UserNotifications) und `Rabe` (AppKit/SwiftUI/WebKit).
- **Composer M2.6:** der Körper ist ein `NSTextView` (TextKit 2, `RichTextEditor.swift`) mit eigener Formatleiste. Die HTML-Teilmenge lebt in `RabeKit/Support/{RichText,RichHTML}.swift`: `p br b i u s a href ul ol li blockquote img[data:]` plus die beiden Marker, die Tauri selbst schreibt (`div.co-signature`, `span.co-mention`). Kein `NSAttributedString.DocumentType.html` (CSS-Ballast). Parser und Schreiber sind iterativ, prüfen Grenzen (`RichLimits`) und verwerfen `script`/`style`/`iframe` samt Inhalt, `on*`-Attribute und fremde Schemata.
- **Brücke:** `Rabe/Support/RichTextBridge.swift` übersetzt `RichDocument` ↔ `NSAttributedString` (Absatzstile für Zitat/Liste/Signatur, Läufe für fett/kursiv/unterstrichen/durchgestrichen/Link/Chip/Bild).
- **Entwurf:** `ComposeDraft.bodyHtml` ist die Wahrheit; `body` (Text) wird abgeleitet, `bodyRevision` sagt dem Editor, wann er neu laden muss. `save_draft` bekommt Text- und HTML-Teil; der Host baut `multipart/alternative` und wandelt `data:`-Bilder in CID-Teile.
- **Kalender M2.6:** `DayListPopover` für „+n weitere“, `join-next-meeting` über `MeetingLink` (Regeln wie Tauri, nur `http`/`https`), `calendar-sidebar` als Befehl. `MiniMonth` und die Zeitwahl waren schon da.
- Offene M2-Punkte siehe `BERICHT-M2.6.md` §6 (Navigation: `toggle-sidebar`, `ContactPane`, `BundleRow`; Verfügbarkeit ohne Host-Befehl).

## 8b. Audit M2 — Nacharbeit (2026-11-20, `AUDIT-M2.md`, `NACHTRAG-M2.md`)

- **Freigabe:** `CommandPolicy.pendingAudit` ist leer. `reading` 43, `writing` 33 (alles Schreibende dort, damit „Änderungen erlauben" greift), `blocked` = `add_account_password`, `test_connection`, `mcp_install_client`. Alle sechs M2.5-`ActionKind`s und `queue_send` mit `sendAt` sind frei; die „Noch nicht freigegeben"-Banner in den Einstellungen sind entfernt.
- **B1:** `RichImage.parse` schneidet den `data:`-Header aus dem Originalstring und schreibt ihn erst danach klein (`lowercased()` kann die Länge ändern → Trap bei U+212A/ẞ/İ).
- **W1:** `RabeKit/Support/HeaderSafety.swift` — Betreff ohne Steuerzeichen (Zeilenumbrüche → ein Leerzeichen) vor jedem `save_draft`; `mailto:`-Adressen mit Steuerzeichen, Leerraum, `<`, `>`, `,`, `;`, `"`, `\`, `(`, `)` werden verworfen (auch `%2C`). Die Härtung im Kern (`build_message`) steht beim Nutzer.
- **W2/W3/W6:** Kein Rückgängig für `unarchive`/`not_spam`/`unsnooze`; Löschdialog und Verschiebe-/Label-Picker halten ihre Ziel-IDs beim Öffnen fest (auch `deletePermanently(ids:)`); das Label-Ticket läuft nach 30 s ab, damit `mark_read` nicht liegen bleibt.
- **W4/W5:** Links in KI-Antworten öffnen nur `http`/`https` (`SafeLink`, `OpenURLAction`); die vier Log-Zeilen loggen nur Längen und Zähler.
- **Auflagen:** `⌘U` fragt vor dem Abmelden (Toast „Abmelden"), Ziehen eines Termins mit Teilnehmenden mailt erst nach Klick, `relabel_auto` aus der Palette fragt (Kosten), MCP-Hinweis „Eintrag heißt comail und ersetzt den der Tauri-App".
- **K1/K2:** `maxHTMLBytes` zählt jetzt Bytes; Tag-Namen sind unabhängig von der Schreibweise (`<B>`, `<SCRIPT>`); alte Vorschau-Ordner werden nur noch bei totem Prozess gelöscht.
- **W7 gemessen (Sandbox, `rabe-cli`, ohne UI):** 110 Threads → 25 ms Streuung, Undo vollständig; 810 Threads → Aktionen über 158 ms, Undo holt 780 von 810 zurück (30 bleiben archiviert). Ursache: `perform_action` schreibt je Thread; `undo_last` nimmt nur Aktionen ±150 ms um die jüngste. Fix wäre eine Gesten-ID im Kern (Freigabe des Nutzers).

## 8c. M2.7 — Kern-Betreff, Gruppengrenze, N1/N2 (2026-11-20, `BERICHT-M2.7.md`)

- **Kern:** `mime::sanitize_subject` in `build_message` entfernt nur Cc (CR/LF/TAB → ein Leerzeichen, übrige Cc weg); Cf (ZWJ, Bidi-Marken, Variationsselektoren) bleibt. Anzeigenamen brauchen das nicht: `mail-builder` schreibt sie über `rfc2047_encode`, das CR/LF verwirft.
- **N1:** `HeaderSafety.subject` nutzt nicht mehr `CharacterSet.controlCharacters` (das enthält Cc **und** Cf), sondern eine eigene Cc-Prüfung; Emoji-Sequenzen und RTL-Text bleiben, auch in „Re: " auf einen fremden Betreff.
- **N2:** `applicationShouldTerminate` schreibt ausstehende `mark_read`-Tickets vor dem Beenden (`MailboxStore.flushBeforeTermination`, höchstens 2 s).
- **W7:** `GroupActionLimit.maxThreads = 500`; Gruppenaktionen darüber werden vor dem Kernaufruf mit Hinweis abgelehnt, `⌘A` darf weiter mehr wählen.

## 8d. M3.1 — Corax: Kennung, Datenübernahme, Schlüsselbund (2026-11-21, `BERICHT-M3.1.md`)

- **Eine Quelle für den Namen:** `RabeKit/Support/AppIdentity.swift` (Name „Corax", `bundleID` `de.streil.corax`, Sandbox `de.streil.corax.sandbox`, `legacyID`/`legacySandboxID`, Tauri `de.streil.rabe`). Fenstertitel, Menüleisten-Titel, Mitteilungsnamen, Signposter, URL-Schema, Mitteilungs-Präfixe und `scripts/build-app.sh` lesen von dort. Ein Test vergleicht Skript und Swift-Seite, ein zweiter verbietet die alte Kennung außerhalb von `AppIdentity`.
- **Host:** `rabe-host` entscheidet Datenordner und Schlüsselbund-Service allein aus der Kennung und führt dafür eine Whitelist (`NATIVE_IDENTIFIER`, `SANDBOX_IDENTIFIER`). Die beiden Konstanten tragen die neuen Kennungen; die alten Services (`de.streil.rabe.native`, `…sandbox`) stehen seither in der Schutzliste, damit keine Instanz dort schreiben kann. `comail-core` ist unverändert — es liest den Service aus der Umgebung.
- **Datenübernahme beim ersten Start:** `LegacyMigration` kopiert `~/Library/Application Support/<alte Kennung>` nach `<neue Kennung>.migrating` und benennt erst dann um (kein halber Zustand, Rückweg bleibt). Die Datenbank kommt über `VACUUM INTO` (`DatabaseCopy`, WAL-sicher), die UserDefaults ohne `.sandbox`-Schlüssel und ohne die Wahl des Nutzers zu überschreiben. Läuft die alte Instanz noch, wird nicht kopiert; der Hoststart bleibt aus, das nächste Fenster sagt warum.
- **Schlüsselbund:** Der Service **ist** die Kennung, Einträge heißen `<account_id>:<slot>`. `CredentialAdoption` liest vorhandene Einträge unter der alten Kennung und schreibt sie unter die neue; macOS fragt dabei je Eintrag nach Zugriff („Immer erlauben"), der Nutzer bestätigt das beim ersten echten Start.
- **Tauri-Warnung:** Läuft `de.streil.rabe` (Vorgängerin, gleicht dieselben Konten ab), warnt die App beim Start und bietet „Trotzdem fortfahren". Ermittelt über `NSRunningApplication`, die andere App wird nicht angefasst.
