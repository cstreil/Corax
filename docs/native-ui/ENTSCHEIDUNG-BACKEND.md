# Entscheidungspapier: Backend für Rabe auf Apple-Plattformen

Stand 2026-11-21 · Architect · Anlass: Frage des Nutzers, ob ein reiner macOS/iOS-Fokus ein anderes Backend nahelegt.
Status: **Vorschlag**, nicht beschlossen. Ändert nichts an M2/M3.

## 1. Ergebnis

Bei reinem Apple-Fokus: **eigenes Backend in Swift**, das den Comail-Kern vollständig ersetzt.

- **Zwei Arten von Quellen hinter einer Schnittstelle.**
  - **Systemquellen:** Kalender und Erinnerungen über `EventKit`, Kontakte über `Contacts`. Für iCloud, Google, Exchange und alles, was in den macOS-Einstellungen eingerichtet ist, gleicht das System selbst ab.
  - **JMAP-Quellen:** Mail, Kalender, Kontakte und später Aufgaben über eine JMAP-Sitzung (Fastmail, Stalwart, Mailflare, Thundermail).
  - **IMAP/SMTP:** nur für Mail, als dritte Quelle.
- **Lokale Datenhaltung:** SQLite über GRDB, Volltextsuche mit FTS5, zusätzlich Core Spotlight für die systemweite Suche.
- **Lizenz:** Danach ist kein AGPL-Code mehr enthalten. Das ist die Voraussetzung für einen Verkauf und den App Store.

## 2. Ist-Stand (geprüft)

- `comail-core`: ≈ 42 k Zeilen Rust. Davon `db` 10,6 k, `sync` 5,7 k, `ai` 3,7 k, `caldav` 3,2 k, `route` 3,0 k, `queue` 3,0 k, `imap` 2,8 k, `mime` 2,6 k, `mcp` 2,5 k, `trash` 1,3 k, `calendar` 1,3 k, `search` 1,1 k, `embed` 0,9 k, `oauth` 0,8 k, Rest < 0,5 k je Modul.
- Bibliotheken: `async-imap`, `lettre` (SMTP), `mail-parser`/`mail-builder` (MIME), `rusqlite`, `candle` (lokale Embeddings).
- App ↔ Kern über `rabe-host` (Befehle/Ereignisse) und `rabe-uniffi`. `RabeKit` ist plattformneutrales Swift und schon für iOS vorbereitet.
- Lizenz: Rabe ist ein Fork von NextOSP/comail unter **AGPL-3.0** (`FORK.md`, `LICENSE`). Die Swift-UI ist neu geschrieben. Der Kern und `src-tauri/swift/ComailIntents.swift` sind Comail-Code.

## 3. Bausteine

| Bereich | Lösung | Bemerkung |
|---|---|---|
| Kalender (System) | `EventKit` | Serien mit `EKSpan .thisEvent/.futureEvents` sind eingebaut, damit entfällt der Entwurf M2.18a. Abgleich, ctag, Organisator-Kennung und Zeitzonen übernimmt das System. |
| Einladungen (iMIP) | eigenes Lesen von iCalendar und Antwort per Mail | `EventKit` kann Teilnehmer **nicht** setzen und keine Einladungen versenden. Annehmen oder Ablehnen aus einer Mail bleibt deshalb unser Code. |
| Erinnerungen (System) | `EventKit` (`EKReminder`) | ist das Gegenstück zu JMAP-Aufgaben |
| Kontakte (System) | `Contacts` | Vorschläge, Avatare |
| JMAP-Kern + Mail | RFC 8620/8621 über `URLSession` | `Email/changes`, `EmailSubmission`, Push über EventSource. Die vorhandene Swift-Bibliothek (`swift-jmap-client`, MIT, 8 Commits, „vibe-coded“) ist zu unreif, daher eigene Implementierung. |
| JMAP-Kontakte | RFC 9610 (JSContact) | Standard seit 2024-12 |
| JMAP-Kalender | draft-ietf-jmap-calendars-34 (JSCalendar) | wartet beim RFC Editor, gilt als stabil genug zum Planen |
| JMAP-Aufgaben | draft-ietf-jmap-tasks-07 | noch Entwurf; umsetzen erst, wenn ein Server ihn anbietet |
| IMAP | Apples `swift-nio-imap` (Apache-2.0) | liefert nur Protokoll und Parser. Abgleich, IDLE, CONDSTORE/QRESYNC, Nachladen und Papierkorb-Identität bauen wir selbst. Unsere iCloud-Erfahrungen (`FORK.md`) dienen als Spezifikation. |
| SMTP | eigene Implementierung auf `swift-nio` oder Network.framework | ist klein, das bisherige `smtp/` hat 113 Zeilen |
| MIME lesen und bauen | eigene Implementierung | Die schwächste Stelle in Swift. Eine reife Bibliothek mit verkaufstauglicher Lizenz ist noch zu suchen, sonst schreiben wir sie selbst (Zeichensätze, QP/Base64 tolerant). |
| Speicher | GRDB/SQLite, FTS5 | SwiftData ist für hunderttausende Mails ungeeignet |
| KI | Apple Foundation Models (lokal) und die bisherigen Anbieter | Embeddings über `NaturalLanguage`/Core ML statt `candle` |
| MCP | offizielles Swift-SDK (`modelcontextprotocol/swift-sdk`) | Lizenz vor Einsatz prüfen |
| Konten/Geheimnisse | Schlüsselbund, `ASWebAuthenticationSession` für OAuth | |
| Systemintegration | App Intents (Siri), Core Spotlight, BackgroundTasks (iOS) | |

## 4. Zielstruktur

```
RabeKit (bestehend, UI-nah)
  └─ benutzt ─▶ RabeEngine (neu, SwiftPM-Target, kein AppKit/UIKit)
                 ├─ Store/        GRDB-Schema, Migrationen, FTS5
                 ├─ Sources/
                 │   ├─ MailSource (Protokoll) ─ IMAPSource · JMAPMailSource
                 │   ├─ CalendarSource ─ EventKitSource · JMAPCalendarSource
                 │   ├─ ContactSource ─ ContactsSource · JMAPContactSource
                 │   └─ TaskSource ─ RemindersSource · JMAPTaskSource (später)
                 ├─ MIME/  SMTP/  Queue/ (Undo, Senden später, Snooze)
                 ├─ Rules/ (Splits, Autolabel, Automationen)
                 └─ AI/  MCP/
```

- Die Stores in `RabeKit` sprechen heute mit `RabeClient`, also mit `rabe-host`. Während des Umbaus bekommt `RabeClient` eine zweite Implementierung auf `RabeEngine`. Umgeschaltet wird **je Bereich** (Kalender, Kontakte, Mail), nicht alles auf einmal.
- JMAP-Kalender sind nur in Rabe sichtbar, nicht im Apple Kalender, weil iOS und macOS keine JMAP-Konten kennen. Das nehmen wir bewusst in Kauf.

## 5. Reihenfolge und Aufwand

Die Schätzung ist in Coder-Tagen auf dem bisherigen Arbeitsniveau angegeben und **grob** (±30 %).

| # | Paket | Tage | Bemerkung |
|---|---|---|---|
| B0 | Fundament `RabeEngine`: Store, Konten, Schlüsselbund, Quellen-Protokolle | 5–8 | |
| B1 | Kalender, Erinnerungen und Kontakte über `EventKit`/`Contacts`, plus iMIP-Antworten | 6–10 | **unabhängig vom Rust-Kern** und damit auch früher möglich. Danach fallen `caldav/` und `calendar/` in der App weg. |
| B2 | JMAP-Mail | 10–15 | der erste Mailweg ohne Comail |
| B3 | IMAP-Engine in Swift | 20–30 | größtes Risiko (iCloud-Eigenheiten, Nachladen, Trash) |
| B4 | MIME und SMTP | 8–12 | weniger, falls eine Bibliothek passt |
| B5 | Queue, Undo, Snooze, Splits/Regeln, Planer | 10–15 | |
| B6 | KI, Embeddings, MCP | 8–12 | |
| B7 | JMAP-Kalender und -Kontakte (Aufgaben später) | 8–12 | |
| B8 | Umzug der lokalen Daten (Einstellungen, Entwürfe, Regeln; Mails neu laden), Rust entfernen | 4–6 | |
| | **Summe** | **≈ 80–120** | |

Zum Vergleich: Ein eigener Kern in Rust wäre ähnlich groß. B1 und die Systemintegration kämen dann zusätzlich als Swift-Code dazu, die FFI-Schicht bliebe bestehen.

## 6. Verworfen

- **Comail-Kern behalten:** wegen der AGPL nicht verkaufbar, und viele Fehler der letzten Wochen kommen aus Kalender und Abgleich im Kern.
- **Eigener Rust-Kern:** Linux bliebe möglich, die Tests ließen sich teils übernehmen. Dagegen sprechen zwei Sprachen, FFI, ein langsamer und großer Build (`src-tauri/target` 55 GB), und `EventKit` und `Contacts` wären trotzdem Swift. Das lohnt sich nur, wenn Linux ein echtes Ziel bleibt.
- **Eigenes CalDAV/CardDAV statt `EventKit`:** doppelte Arbeit für Konten, die das System ohnehin schon abgleicht. Bleibt als Rückfallweg, falls `EventKit` an einer Stelle nicht reicht.
- **SwiftData/Core Data:** zu langsam und zu wenig steuerbar bei großen Postfächern und Volltextsuche.

## 7. Risiken

1. **Saubere Neuentwicklung:** Damit der neue Code nicht als Ableitung der AGPL gilt, wird er aus RFCs, unseren Verhaltensbeschreibungen (`TASTATUR.md`, Berichte, `FORK.md`) und Tests geschrieben, **ohne Comail-Code zu übersetzen**. Coder bekommen für die Ersatzpakete Spezifikationen statt Comail-Dateien. Vor einem Verkauf sollte das juristisch geprüft werden. Das gilt auch für die geplanten Siri-Intents, die nicht aus `ComailIntents.swift` übernommen werden dürfen.
2. **Push auf iOS:** iOS hält im Hintergrund keine IMAP- oder JMAP-Verbindung offen. Für sofortige Benachrichtigungen braucht es einen kleinen Relay-Dienst: JMAP-PushSubscription (RFC 8620 §7.2) bzw. IMAP-IDLE → APNs. Das ist ein Server mit Betriebskosten und Datenschutzfragen und wird erst beim iOS-Start entschieden. Auf dem Mac ist das kein Problem.
3. **Grenzen von `EventKit`:** keine Teilnehmer und keine Einladungen, Zugriff nur mit Freigabe durch den Nutzer, eingeschränkte Abgleichsteuerung. Gemildert durch eigenes iMIP und den Rückfall auf JMAP/CalDAV.
4. **IMAP-Engine (B3):** Hier steckt die meiste Erfahrung des alten Kerns. Wir brauchen eine Testbank gegen echte Server (iCloud, Gmail, Dovecot) mit Sandbox-Konten.
5. **Spezifikationen:** JMAP-Kalender kann sich bis zum RFC noch im Detail ändern, JMAP-Aufgaben deutlich.

## 8. Offene Entscheidungen (Nutzer)

1. **Linux endgültig streichen?** Empfehlung: ja. Diese Entscheidung bestimmt, ob Swift oder Rust die Sprache wird.
2. **B1 (`EventKit`) vorziehen, direkt nach M3?** Empfehlung: ja. Das Paket ist unabhängig, entfernt die wackeligste Stelle und gilt auch dann, wenn der Rest später kommt.
3. **Wann beginnt der Ersatz?** Empfehlung: nach M3 und dem Gesamtcheck. Die Liste der Kern-Ersatz-Phase in `ARCHITEKTUR.md` §5 wird dann zum Backlog von B0–B8.
4. **Relay für iOS-Push:** erst beim iOS-Start entscheiden.
