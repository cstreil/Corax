# MEMORY — comail (eigener Fork)

## Stand
- Fork von NextOSP/comail: https://github.com/cstreil/comail (public, AGPL-3.0-only).
  `origin` = eigener Fork, `upstream` = Original.
- Arbeit auf `fork/sync-fixes`, Basis `upstream/master` @ `d2384cd` (v0.2.41), 24 Commits darüber.
  Fork-`master` steht auf v0.2.44; GitHub meldet den Arbeitsbranch als diverged (24 ahead, 37 behind).
- **Merge von v0.2.44 aufgeschoben bis nach der deutschen Übersetzung** (2026-11-18). Erwartete
  Konflikte: `imap/mod.rs` (+460 Zeilen), `sync/engine.rs` (+852), `imap/identity.rs`, 4 neue Keys
  in `en/settings.json` (macht `de` kurzzeitig unvollständig).
- Push über lokales `gh` (Account `cstreil`, HTTPS/Keychain); der GitHub-Connector legt Repos an,
  macht aber kein `git push`.
- Fork und Merge: `FORK.md`. Sync-Fixes mit Begründung: `HANDOVER.md`.
- Zwei Instanzen, gleiches Binary, getrennte Daten:
  - `com.deanoss.comail` → `/Applications/Comail.app`, Daten `~/Library/Application Support/comail`
  - `com.deanoss.comail.dev` → `Comail Dev.app`, Daten `…/com.deanoss.comail.dev`
- Upstream-Release-App deinstalliert (liegt in `~/.Trash/Comail.app`).

## Technik
- Tauri 2: Rust-Core `src-tauri/crates/comail-core` (Tauri-frei) + Adapter `src-tauri/src` + React/TS `src/`.
- ~58k Zeilen Rust, ~43k Zeilen TS/TSX, 38 SQL-Migrationen, ~500 Rust-, 398 TS-Tests.
- SQLite (WAL + FTS5) + lokale Embeddings (bge-small, candle); Credentials im OS-Keyring.
- Lizenz AGPL-3.0-only — gilt bei Verbreitung eines Forks weiter.
- `async-imap 0.12` / `imap-proto 0.17` (2026-11-17): 0.16.7 stolperte über iClouds `NIL` als
  Transfer-Encoding und UTF-8 in quoted strings → Body-Fetch und Session-Desync.
- `base64` 0.22 lehnt Padding-Bits im letzten Symbol ab; `decode_base64_transfer` nutzt eigene
  Engines mit `with_decode_allow_trailing_bits(true)`.
- HTML-Sanitizer (Ammonia) behält `<style>`/`class`; Sicherheitsgrenze ist die iframe-CSP
  (`default-src 'none'`), nicht der Sanitizer. `<title>`-Text wird verworfen.
- QP-Heuristik: nur `=3D` vor Anführungszeichen und UTF-8-Escapes außerhalb RFC-2047-Words
  (Schwelle 2) — vorher ~1100 Fehlalarme pro Start.
- IMAP-Mailbox-Namen sind modifiziertes UTF-7: `src/imap/mutf7.rs` dekodiert (LIST) bzw. kodiert
  (SELECT/APPEND/CREATE/COPY/MOVE). **Keine** Unicode-Normalisierung des Schlüssels: iCloud speichert
  Umlaute zerlegt (a + U+0308), die komponierte Form liefert `[NONEXISTENT]`. NFC nur in der Anzeige.
- iCloud-IMAP lehnt gleichzeitige Verbindungen mit `[AUTHENTICATIONFAILED]` ab, obwohl das
  App-Passwort gilt — nicht als falsches Passwort deuten.

## Sync-Fixes (Begründung in `HANDOVER.md`)
- `imap/mod.rs`: BODYSTRUCTURE aus zweitem FETCH (`attach_mime_plans`), nie mit
  `BODY[HEADER.FIELDS]` kombiniert; Item-Listen aus nicht-leeren Teilen bauen.
- `imap/identity.rs`: leerer Provider-Item erzeugte doppelte Leerzeichen → iCloud lehnte ab, jede
  Identitätsliste kam leer zurück, Trash-Adoption und Move-Ziel-UID fehlten.
- `sync/engine.rs`: `initial_backfill` markiert bei leerer Suche nicht mehr als fertig;
  `fill_missing_uids` gleicht gegen `UID SEARCH ALL` ab; Session-Verlust wird erkannt.
- `isolate_instance` leitet Datenverzeichnis und Keyring-Service aus dem Bundle-Identifier ab
  (`COMAIL_DATA_DIR`, `COMAIL_KEYRING_SERVICE`).

## Code-Review (2026-11-18, Auditor)
- Zwei Runden über `upstream/master..HEAD`; **Sicherheit freigegeben** (iframe-CSP als Grenze).
- `565ada5`: `done` erst nach Abgleich (`folders.backfill_reconciled`, Migration 036);
  `attach_mime_plans` schluckt nur `No`/`Bad`; `initial_backfill` startet bei UIDNEXT.
- `4089252`: `backfill_reconcile_retry_at` (Migration 037) hält 15 min zurück; `isolate_instance`
  meldet den Grund und beendet mit `exit(1)`.
- Akzeptiertes Restrisiko: eine Base64-Endzeile mit 60–76 Zeichen zählt als QP-Marker.

## Bauen
- `sh scripts/build-local-app.sh` → `/Applications/Comail.app`; `sh scripts/build-dev-app.sh` →
  `src-tauri/target/release/bundle/macos/Comail Dev.app` (installiert nicht selbst).
- `pnpm dev:isolated` → Hot-Reload-Dev-Instanz.
- Signatur: echte `Apple Development`-Identität (Team-ID `2XSHYS8HMR`) bevorzugt, Fallback
  `comail-dev`. Nur Apple-Signaturen tragen eine Team-ID und damit eine stabile Keychain-Partition-ID.
- Das Dev-Build-Skript patcht `tauri.conf.json` (Siri-Metadaten) und stellt sie per `trap` zurück:
  während des Builds ist der Arbeitsbaum schmutzig, nicht committen.

## Backup
- `Tasks/2026-11-17-comail-mail-backup.nosync/` — 11744 `.eml`, 2,5 GB, `manifest.json` mit UIDVALIDITY.
- Erzeugt mit `scripts/imap-backup.py`, rein lesend. Abgleich über Message-ID-Mengen, nicht über
  Zähler pro Ordner (die App dedupliziert über Message-IDs). Letzter Abgleich: 0 fehlend.

## Eigene Features
- `inboxDefaultSplits` (Default **aus**): keine eingebauten Tabs Wichtig/Sonstige → eine ungeteilte
  Inbox; eigene Splits und Auto-Label-Tabs erscheinen weiter, dann mit „Inbox"-Tab davor.
  `lib/splitOrder.ts`, `SplitTabs`, `Sidebar`, `keyboard/context.ts`, `InboxScreen`.
- Inline-Mailansicht (2026-11-17): Mail klappt als Panel unter ihrer Zeile auf (Deckel 75 %, min. drei
  Zeilen; `ResizeObserver` meldet die Höhe mit Thread-ID). Klick auf die Kopfzeile klappt ein;
  `ui.threadFullView`/`openThreadFull` öffnen die alte Vollansicht. Im Panel kein Back-Link/Fußzeile.

## i18n / Deutsch (fertig 2026-11-18)
- `de` ist übersetzt: 1704 von 1833 Textwerten, Anrede „du" (vom Nutzer bestätigt).
- 129 Werte bleiben bewusst englisch (Produktnamen, Adressen, Modell-IDs, Einheiten, Formate,
  Suchsyntax, Demo-Zeilen) und stehen in `UNTRANSLATED_BY_DESIGN` in
  `src/i18n/localeParity.test.ts`; der Test schlägt fehl, sobald neues Englisch in `de` auftaucht.
- Verdrahtet: `LANGUAGE_NAMES` (`de: "Deutsch"`), `tray_labels` („Comail öffnen"),
  `TRANSLATION_STATUS.md`; Systemsprache wählt `de` automatisch.
- Werkzeuge: `node scripts/i18n-status.mjs [de] [--missing]`; `docs/i18n-de.md` (Regeln, Glossar,
  Abnahme). Die maschinell übersetzten Sprachen dürfen Keys verpassen (Fallback auf Englisch).
- `@types/node` fehlt absichtlich: Tests nutzen `import.meta.glob`, keine Node-APIs.
- Offener Produktfehler: `src/lib/snooze.ts` parst nur englische Zeitwörter („tomorrow",
  „monday 9am") — ein deutsches „morgen" funktioniert nicht, eine Keyword-Tabelle fehlt.

## Offen
- cua: `cua.activate` holt Comail nicht nach vorn (erst `open -a "Comail Dev"`); Klicks landen ~1 Zeile
  höher als geschätzt (Screenshot-Pixel × 1,043); bei gesperrtem Desktop kommt `SESSION_LOCKED`.
- MCP in beiden Instanzen aus (`mcpEnabled: false`, Port 47823).
- Selbst gesendete Mail an die eigene Adresse erscheint nur einmal (Message-ID-Dedupe), im zuletzt
  synchronisierten Ordner.

## Umgebung
- node 26.7.0, pnpm 10.7.0 (lädt pnpm@11.11.0 nach), cargo/rustc 1.99.1 via Homebrew, kein rustup,
  nur Xcode Command Line Tools (kein volles Xcode → keine Siri-Intents, kein `actool`).
- `.nosync` hält Ordner aus iCloud *und* Syncthing heraus (bestätigt vom Nutzer 2026-11-16).
