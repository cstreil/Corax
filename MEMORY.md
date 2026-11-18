# MEMORY — Rabe (Fork von comail)

## Stand
- Fork von NextOSP/comail: https://github.com/cstreil/Rabe (public, AGPL-3.0-only); `origin` = Fork,
  `upstream` = Original, Arbeit auf `fork/sync-fixes`. Repo am 2026-11-18 von `comail` in `Rabe`
  umbenannt (alte URLs leiten 301 um). Details `FORK.md`, Fix-Begründungen `HANDOVER.md`.
- Upstream v0.2.44 (`ded0898`) eingezogen → Branch `chore/merge-upstream-0.2.44` (50 Commits, PR #1 offen),
  darauf Rabe-Umbenennung, Shortcut `a`, Keyring-Migration, eigener Updater.
- **v0.2.45 veröffentlicht** (2026-11-18, Tag auf `4416fb4`); Update-Test 0.2.44 → 0.2.45 in
  `/Applications/Rabe.app` bestanden: Keychain bleibt, Sync verbindet ohne Passwortabfrage.
- Push über lokales `gh` (Account `cstreil`, HTTPS/Keychain); der GitHub-Connector pusht nicht. `gh` zielt
  im Fork sonst aufs Eltern-Repo → einmalig `gh repo set-default cstreil/Rabe`.
- Zwei Instanzen, gleiches Binary, getrennte Daten: `de.streil.rabe` → `/Applications/Rabe.app`,
  `de.streil.rabe.dev` → `Rabe Dev.app`. Upstream-Release-App deinstalliert (liegt in `~/.Trash`).

## Technik
- Tauri 2: Rust-Core `src-tauri/crates/comail-core` (Tauri-frei) + Adapter + React/TS `src/`; ~58k Zeilen
  Rust, ~43k TS/TSX, 39 Migrationen, 533 Rust-/400 TS-Tests. SQLite (WAL, FTS5), lokale Embeddings
  (bge-small, candle), Credentials im Keyring. AGPL-3.0-only gilt bei Verbreitung weiter.
- Migrationen: Fork 036/037/038 (`backfill_reconciled`, `_retry_at`, mUTF-7-Ordner), Upstreams Datei als
  **039** — nicht umnummerieren (bricht jede Fork-DB). `ensure_folder_sync_columns` legt Fork-Spalten nach
  der Schleife nach; danach `decode_folder_names` + Reconcile-Reset.
- `async-imap 0.12` (0.16.7 scheiterte an iClouds `NIL`-Encoding und UTF-8 in quoted strings);
  `base64 0.22` lehnt Padding-Bits ab → eigene Engines mit `with_decode_allow_trailing_bits(true)`.
  QP-Heuristik nur `=3D` vor Anführungszeichen, Schwelle 2 (vorher ~1100 Fehlalarme pro Start).
- HTML: Ammonia behält `<style>`/`class`; Grenze ist die iframe-CSP (`default-src 'none'`).
- IMAP-Mailboxen sind modifiziertes UTF-7 (`mutf7.rs`), **keine** Unicode-Normalisierung des Schlüssels
  (iCloud speichert Umlaute zerlegt; komponiert → `[NONEXISTENT]`, NFC nur in der Anzeige).
- iCloud-IMAP lehnt parallele Verbindungen mit `[AUTHENTICATIONFAILED]` ab, obwohl das App-Passwort gilt.

## Sync-Fixes
- Zwei-Schritt-FETCH (BODYSTRUCTURE getrennt, `header_fetch_query(items, false)`, `attach_mime_plans` nur
  bei `with_structure`), `done` erst nach Abgleich (036/037), `isolate_instance` leitet Datenverzeichnis
  und Keyring-Service aus dem Bundle-Identifier ab (`COMAIL_DATA_DIR`, `COMAIL_KEYRING_SERVICE`).
  Begründungen und Code-Stellen: `HANDOVER.md`.
- Review (Auditor 2026-11-18): Sicherheit freigegeben (iframe-CSP als Grenze); akzeptiertes Restrisiko
  eine Base64-Endzeile mit 60–76 Zeichen als QP-Marker.

## Eigene Features
- `inboxDefaultSplits` Default **aus**: eine ungeteilte Inbox; eigene Splits/Auto-Tabs erscheinen weiter.
- Inline-Mailansicht: Mail klappt als Panel unter ihrer Zeile auf (Deckel 75 %, min. drei Zeilen,
  `ResizeObserver`); Klick auf die Kopfzeile klappt ein, `openThreadFull` öffnet die Vollansicht.
- Deutsch: 1708/1837, Anrede „du"; 129 bewusst englisch in `UNTRANSLATED_BY_DESIGN`
  (`src/i18n/localeParity.test.ts`), Test schlägt bei neuem Englisch fehl. Werkzeuge:
  `node scripts/i18n-status.mjs de [--missing]`, Regeln in `docs/i18n-de.md`.
- `src/lib/snooze.ts` parst nur englische Zeitwörter; deutsche Keyword-Tabelle vom Nutzer 2026-11-18
  zurückgestellt (danach Platzhalter in `common:timePopover`/`calendar:create` umstellen).

## Bauen
- `sh scripts/build-dev-app.sh` → `src-tauri/target/release/bundle/macos/Rabe Dev.app` (installiert nicht
  selbst, dann `ditto` nach `/Applications`); `sh scripts/build-local-app.sh` → `/Applications/Rabe.app`.
- `sh scripts/release-fork.sh [--no-publish]` baut, packt `dist/Rabe.app.tar.gz`, signiert mit
  `~/.tauri/rabe-updater.key`, schreibt `latest.json`, legt das Release an (Tag auf HEAD). Version vorher
  in `tauri.conf.json` hochziehen — gleiche Version heißt „kein Update".
- Signatur: echte `Apple Development`-Identität (Team-ID `2XSHYS8HMR`), Fallback `comail-dev`.
- Das Dev-Skript patcht `tauri.conf.json` und stellt sie per `trap` zurück: während des Builds ist der
  Arbeitsbaum schmutzig, nicht committen. `pnpm dev:isolated` = Hot-Reload-Instanz.

## Backup
- `Tasks/2026-11-17-comail-mail-backup.nosync/` — 11744 `.eml`, 2,5 GB, `manifest.json` mit UIDVALIDITY;
  `scripts/imap-backup.py` (nur lesend), Abgleich über Message-ID-Mengen. Letzter Abgleich: 0 fehlend.

## Offen
- App-Icon ist noch das Upstream-Planeten-Icon (Dock/„Über"); `/Applications/Comail Dev.app` liegt noch da.
- Eigenes „Passwort ändern" für IMAP-Konten fehlt (nur OAuth-Reauth); Snooze-Zeitwörter Deutsch offen.
- cua: `open "/Applications/Rabe Dev.app"` nötig (`cua.activate` hilft nicht); Klicks ~1 Zeile höher als geschätzt
  (Screenshot-Pixel × 1,043); gesperrter Desktop → `SESSION_LOCKED`.
- MCP in beiden Instanzen aus (`mcpEnabled: false`, Port 47823).
- Selbst gesendete Mail an die eigene Adresse erscheint nur einmal (Message-ID-Dedupe).

## Umgebung
- node 26.7.0, pnpm 10.7.0, cargo/rustc 1.99.1 via Homebrew, kein rustup, nur Xcode Command Line Tools.
- `.nosync` hält Ordner aus iCloud *und* Syncthing heraus (bestätigt 2026-11-16).
