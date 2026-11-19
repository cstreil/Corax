# Briefing P2 — Rabe native: macOS-Oberfläche M1

Empfänger: **Frontend** · Verfasser: Architect · Stand 2026-11-18 · Status: versendet 2026-11-19 (Sandbox P1b steht; Audit P1 läuft parallel, Befunde kommen ggf. nach)

> Nachtrag P1b: Sandbox existiert (`~/Library/Application Support/de.streil.rabe.native.sandbox`, 10 Threads, 15 Nachrichten, 7 Anhänge, 3 Labels, Tab „Newsletter“). App-Umschaltung per `RABE_IDENTIFIER` liegt in `apps/macos/Sources/Rabe/{Instance.swift, AppModel.swift, AppDelegate.swift, main.swift}` — beim Umbau auf SwiftUI `App` erhalten. Bericht: `Work/Tasks/2026-11-18-rabe-native-p0/BERICHT-P1b.md`. Tests mit Keychain-Zugriff (`ai_status`) lösen einen macOS-Sicherheitsdialog aus; nie bestätigen.

## 1. Ziel
`Rabe Native.app` ist für Lesen, Triage und Antworten im Alltag nutzbar und sieht aus wie das macOS-Mockup in den Themes Papier, Graphit und Glas. Unter der Haube läuft der unveränderte Rust-Kern über `rabe-host`/`rabe-uniffi`.

## 2. Kontext
- Repo `Work/Projekte/comail.nosync`, Branch `feat/native-ui` (uncommitted). Zuerst lesen: `docs/native-ui/ARCHITEKTUR.md` (bes. §3, §4, §5 M1, §6 Budget, §7a/7b).
- Mockup (Gestaltung ist verbindlich): `Work/Tasks/2026-11-18-mail-app-mockup/index.html` (Ansicht „macOS“, Themes `paper`/`graphite`/`glass`, im Browser bedienbar), Screenshots `previews/a-papier.png`, `b-graphit.png`, `c-glas.png`. Daten `mail-data.js`.
  - Fenster ohne Seitenleiste: Toolbar mit Ampel, Titel (aktuelle Ansicht), Tabs, Suche (`/`), Neu, Tastenkürzel-Knopf. Darunter die Liste mit Datumsgruppen und Initialen-Avataren; der Thread klappt **inline unter seiner Zeile** auf (Nachrichten, Anhänge, Antwortfeld, `⌘↵` senden, `Esc` verwerfen). Hinweisleiste unten, Toast mit Rückgängig, Sheet „Tastenkürzel“.
  - Design-Tokens je Theme (`--page`, `--win`, `--surface`, `--ink/2/3`, `--line`, `--hover`, `--sel`, `--accent`, `--accent-ink`, `--shadow`, `--blur`, `--ease: cubic-bezier(.22,.8,.2,1)`, `--dur: .36s`) stehen im `<style>` von `index.html`.
- Bestehende App: `apps/macos/` (SwiftPM-Paket `Rabe`, Targets `RabeFFI`, `RabeBindings`, `Rabe`), `apps/macos/scripts/build-app.sh` (baut Rust-Staticlib, Bindings, `.app`, signiert). Einstieg aktuell AppKit, weil P0 ohne Xcode lief. **Xcode 27.2 ist jetzt aktiv**, SwiftUI-`App` mit `@State` ist erlaubt.
- Brücke (Swift sieht): `RabeHost.start(identifier:resourceDir:delegate:)` (nicht blockierend), `waitReady()`, `invoke(cmd:argsJson:) async throws -> String`, `html…`-Funktionen (`wrapForDisplay`, `hasRemoteImages`, `darkModeScript`), Delegate `openUrl`, `openPath`, `onEvent(eventJson)`, `notify(...) -> Bool`, `copyToClipboard(text) -> Bool`. Exakte Signaturen: generierte Swift-Datei des Targets `RabeBindings`.
- Command-Vertrag = Tauri-Frontend: Namen, Argumente und JSON-Formen aus `src/ipc/commands.ts` und `src/ipc/types.ts`, Events aus `src/ipc/events.ts` (`{"name","payload"}`). Fehler `{"code","message"}`, Codes siehe `src/ipc/errors.ts`.
- Logik, die heute im React-Frontend liegt und **portiert, nicht neu erfunden** wird: `src/lib/quotes.ts` (Zitate), `src/lib/listItems.ts` (Datumsgruppen, Listeneinträge), `src/lib/format.ts` (Datum, Namen), `src/lib/snooze.ts` (Presets), `src/lib/selection.ts`, `src/lib/mailto.ts`, `src/lib/signatures.ts`, `src/lib/emailDark.ts` (läuft künftig über `darkModeScript`), `src/components/compose/Composer.tsx` + `RecipientField.tsx` (Antwort-Empfänger, Betreff-Präfix, Entwurf, Undo-Send), `src/components/common/Toasts.tsx`, `ShortcutHelp.tsx`, `src/keyboard/` (Tastaturbelegung), `src/i18n/` (deutsche Texte: wo vorhanden, wörtlich übernehmen).
- Instanzen: Standard `de.streil.rabe.native` = **echtes iCloud-Konto** des Nutzers. Sandbox `RABE_IDENTIFIER=de.streil.rabe.native.sandbox` = Mockup-Daten, Server nicht erreichbar (`*.invalid`); Seed: `cargo run -p rabe-host --bin rabe-cli -- --identifier de.streil.rabe.native.sandbox seed-sandbox --reset` in `src-tauri`.

## 3. Anforderungen
**Funktion**
1. Liste der aktuellen Ansicht mit Paging (`list_threads`, `cursor`/`nextCursor`), Datumsgruppen, Absender-Initialen in Farbe, Betreff, Vorschau, Datum, Markierungen ungelesen/Stern/Anhang/Label. Tabs = Splits (`list_splits`, Ungelesen-Punkt aus `unread_counts`), `Tab`/`⇧Tab` wechselt.
2. Ansicht und Konto wechseln über den Fenstertitel (Menü), die Menüleiste „Postfach“ (Eingang, Markiert, Später, Gesendet, Entwürfe, Erledigt, Papierkorb, Spam, Alle; Konten mit `⌃1`–`⌃9`) und `⌘K`.
3. Thread inline aufklappen/zuklappen (`↵`/`Space`, Klick), `get_thread`/`get_body`. Text- und HTML-Nachrichten, ältere Nachrichten eines Threads gefaltet wie im Mockup, Anhänge öffnen (`open_attachment` → Delegate `openPath`) und sichern (`NSSavePanel` → `save_attachment`). Leiste „Bilder laden“, wenn `hasRemoteImages`.
4. Aktionen über `perform_action` mit Tasten wie im Mockup-Sheet: `E` Erledigt, `#` Papierkorb, `H` Später (Presets aus `snooze.ts`, `H` direkt = morgen 8:00 wie im Mockup), `S` Stern, `U` ungelesen, `Z` Rückgängig (`undo_last`). Optimistisch: Zeile verschwindet im selben Frame, Toast mit „Rückgängig“; Fehler → Zeile zurück und Fehlermeldung.
5. Antworten: `R` antwortet, `⇧R` an alle (Rabe-Belegung, siehe MEMORY.md). Inline-Antwortfeld wie im Mockup, `F` Weiterleiten, `C` neue Mail in eigenem Fenster. Empfängerfelder mit `suggest_contacts`, Betreff, Text (nur Text in M1). Entwurf automatisch speichern (`save_draft`, 1 s entprellt), `⌘↵` → `queue_send`, Toast „Gesendet · Rückgängig“ (`cancel_send`) für die Undo-Send-Dauer aus den Einstellungen.
6. Suche: `/` fokussiert das Suchfeld, `↵` → `search`, Ergebnisse in derselben Liste, `Esc` zurück.
7. `?` zeigt das Tastenkürzel-Sheet, `⌘K` eine Befehlspalette mit allen M1-Aktionen und Ansichten.
8. Themes Papier/Graphit/Glas plus „System“ (hell → Papier, dunkel → Graphit), Auswahl in den Einstellungen und in der Menüleiste „Darstellung“. Gespeichert in `settings.theme` mit den IDs `paper`, `carbon` (= Graphit), `snow` (= Glas), `system`. `carbon` und `snow` sind bestehende IDs, nicht umbenennen. Glas nutzt echtes macOS-Material (`glassEffect`/`NSVisualEffectView`), Akzentfarbe aus `settings.accent_color`.
9. Sync-Status und Offline in der Hinweisleiste (`get_sync_status`, Events `sync:progress`, `network:state`). Liste aktualisiert sich bei `mail:updated` gezielt für die betroffenen Thread-IDs.
10. Benachrichtigungen: beim ersten Start `UNUserNotificationCenter.requestAuthorization`. Klick auf eine Benachrichtigung öffnet den Thread.
11. Konto anlegen, wenn keins existiert: Sheet für IMAP mit App-Passwort (`test_connection`, `add_account_password`). OAuth ist M2.
12. Einstellungen-Fenster (`⌘,`) nur mit M1-Punkten: Theme, Akzent, Undo-Send-Dauer, Remote-Bilder laden, Benachrichtigungen. `get_settings`/`set_settings` immer mit dem vollständigen Objekt (Read-Modify-Write).

**Nicht-funktional**
13. Leistung gemäß ARCHITEKTUR §6: Liste ≤ 400 ms nach `host:ready`, Thread aus Cache ≤ 50 ms (Text) / ≤ 120 ms (HTML), keine Frames > 16,7 ms beim Scrollen. Hänger-Zähler als Debug-Overlay (`⌥⌘P`, `NSView.displayLink`), Messpunkte per `os_signpost`.
14. Animationen mit Mockup-Kurve (`.22,.8,.2,1`, 360 ms) für Aufklappen, Zeile entfernen, Toast. `Bewegung reduzieren` schaltet sie ab.
15. Bedienung komplett per Tastatur, VoiceOver-Labels für Zeilen, Aktionen und Felder.
16. Deutsch als Oberflächensprache (Texte aus `src/i18n/de`), Anrede „du“. Strings zentral in `Localizable.xcstrings` oder einer Swift-Tabelle.

## 4. Nicht-Ziele
Kalender, KI-Funktionen, Splits-/Regel-Editor, Snippets, OAuth, Avatar-Layout/Senderfotos, Rich-Text-Composer, Tray/Menüleisten-Icon, `mailto:`, Updater, iOS, Linux. Keine Änderungen an `src-tauri/` (Kern, Tauri-App, `rabe-host`). Fehlt dort etwas, eine Notiz an Architect statt eines Umbaus. Kein Commit/Push.

## 5. Umsetzung
1. **Gerüst**: `Sources/Rabe/App/RabeApp.swift` (SwiftUI `App`, ein Hauptfenster, `Commands` für die Menüleiste), `AppDelegate` für Host-Start und -Ende. AppKit-Einstieg aus P0 ersetzen. `RABE_IDENTIFIER` aus P1b beibehalten.
2. **Kernschicht**: `Core/RabeClient.swift` (actor, typisierte Wrapper je Command, decodiert mit `JSONDecoder` und `.convertFromSnakeCase` passend zum Vertrag), `Core/Models.swift` (Codable aus `src/ipc/types.ts`, nur M1-Typen), `Core/EventRouter.swift` (Event-JSON → typisierte Events auf `MainActor`).
3. **Zustand** (`@Observable`, `@MainActor`): `MailboxStore` (Ansicht, Split, Konto, Seiten, Auswahl, aufgeklappter Thread, optimistische Aktionen samt Rollback und Undo-Stapel), `ThreadCache` (LRU 50 ThreadDetails), `ComposeStore` (je Entwurf), `SearchStore`, `SettingsStore`, `SyncStore`.
4. **Liste** `UI/MailList/`: `NSTableView` (view-based, per `NSViewRepresentable`) mit drei Zeilentypen: Gruppenkopf, Thread-Zeile (feste Höhe, selbst gezeichnet bzw. leichte Views, keine SwiftUI-Hosting-View pro Zeile), Detailzeile für den aufgeklappten Thread (eine `NSHostingView` mit SwiftUI-Inhalt). Höhenänderung animiert über `noteHeightOfRows` in `NSAnimationContext`. Einzeltasten (`J/K/E/#/H/S/U/R/⇧R/F/Z/?`) im `keyDown` der Tabelle; die Menüleiste zeigt sie nur an.
5. **HTML** `UI/Thread/HTMLMessageView.swift`: `WKWebView` mit `WKWebsiteDataStore.nonPersistent()`, `defaultWebpagePreferences.allowsContentJavaScript = false`. Inhalt = `wrapForDisplay(html, theme, loadRemoteImages)`. `darkModeScript` und Höhenmessung laufen in `WKContentWorld.defaultClient` (`evaluateJavaScript(_:in:in:)`). Navigation: `http`/`https` → `NSWorkspace.open`, `mailto` → Composer, alles andere abbrechen. Zusätzlich `WKContentRuleList`, die `http(s)`-Ladevorgänge blockt, solange Remote-Bilder aus sind. Höhe: Platzhalter aus Textlänge, nach Messung animiert anpassen. Web-Views aus einem kleinen Pool wiederverwenden.
6. **Aktionen und Tastatur**: zentrales `ActionDispatcher` (Taste/Menü/Palette → Store-Methode), damit alle drei Wege dasselbe tun.
7. **Composer** inline und als Fenster, gemeinsame `ComposeView`.
8. **Themes** `UI/Theme/`: `Theme`-Struct mit den Tokens aus dem Mockup, Umgebung per `@Environment`. Wechsel animiert.
9. **Palette, Sheet, Toast, Hinweisleiste, Einstellungen, Konto-Sheet.**
10. **Build**: `build-app.sh` weiter nutzen. `LSMinimumSystemVersion` und Deployment-Target **27.0** (ARCHITEKTUR §7b). Assets/Icon dürfen jetzt über Xcode-Werkzeuge (`actool`) laufen.

## 6. Schnittstellen (Beispiele)
```swift
let page: ThreadPage = try await client.listThreads(view: .inbox, splitId: nil, accountId: nil, cursor: nil, limit: 100)
try await client.performAction(kind: .archive, threadIds: [42])   // → ActionResult(actionIds: [..])
let undone: Bool = try await client.undoLast()
// Event
{"name":"mail:updated","payload":{"threadIds":[42,43]}}
```
Fehler: `RabeError.core(code, message)` → Toast mit deutschem Text je Code (Tabelle aus `src/ipc/errors.ts` + i18n).

## 7. Abnahmekriterien
1. `sh apps/macos/scripts/build-app.sh` baut ohne Fehler, `codesign -v` ok.
2. Sandbox (`RABE_IDENTIFIER=de.streil.rabe.native.sandbox`): Screenshots aller drei Themes im selben Zustand wie `previews/a-papier.png`, `b-graphit.png`, `c-glas.png` (Inbox mit aufgeklapptem Thread „Rebranding – Entwürfe Runde 3“), nebeneinander mit dem Mockup in `Work/Tasks/2026-11-18-rabe-native-p2/`.
3. Sandbox-Durchlauf nur per Tastatur, als Protokoll mit Screenshots: J/K, ↵, E, Z, H, S, U, #, R → Text → ⌘↵ → Rückgängig, C, /, ?, ⌘K, Tab.
4. Echte Instanz **nur lesend**: Liste, Aufklappen, HTML-Mails (mindestens ein Newsletter mit Remote-Bildern, gesperrt und nach „Bilder laden“), Suche. Messwerte aus Anforderung 13 im Bericht.
5. Scrollen durch die echte Inbox und „Alle“ mit Overlay: Hänger-Zahl und längster Frame im Bericht.
6. Bericht `Work/Tasks/2026-11-18-rabe-native-p2/BERICHT.md`: was steht, Abweichungen von Mockup und Plan mit Grund, offene Punkte, angefasste Dateien.

## 8. Risiken und offene Fragen
- **Schreibende Aktionen nie gegen `de.streil.rabe.native`** (echtes Konto). Erst nach ausdrücklicher Freigabe durch den Nutzer.
- Variable Höhe der HTML-Zeile in `NSTableView` mit Animation: früh als Prototyp prüfen. Wenn es ruckelt, eine Notiz an Architect statt auf SwiftUI-`List` auszuweichen.
- Dark-Mode-Anpassung von HTML-Mails (Graphit) ohne Seiten-JS: Ergebnis sichtbar prüfen.
- Command-Formen: Bei Abweichungen zwischen `src/ipc` und tatsächlichem `dispatch`-Verhalten gilt `src/ipc`; Abweichung an Architect melden.
- Die Mockup-Tastenbelegung (`R` antworten) und die Rabe-Belegung (`R`/`⇧R`) sind konsistent. Bei weiteren Konflikten gilt das Mockup, sie kommen in den Bericht.
