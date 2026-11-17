# MEMORY — comail (eigener Fork)

## Stand
- Fork von https://github.com/NextOSP/comail, Branch `master` @ `d2384cd`, Version 0.2.41.
- Remote `upstream` = Original; `origin` ist frei für den eigenen Fork.
- Ausführliche Übergabe (Änderungen, Begründungen, Verifikation, offene Punkte): `HANDOVER.md`.
- Zwei Instanzen, gleiches Binary, getrennte Daten:
  - `com.deanoss.comail` → `/Applications/Comail.app`, Daten `~/Library/Application Support/comail`
  - `com.deanoss.comail.dev` → `Comail Dev.app`, Daten `…/com.deanoss.comail.dev`
- Upstream-Release-App deinstalliert (liegt in `~/.Trash/Comail.app`).

## Technik
- Tauri 2: Rust-Core `src-tauri/crates/comail-core` (Tauri-frei) + Adapter `src-tauri/src` + React/TS-UI `src/`.
- ~58k Zeilen Rust, ~43k Zeilen TS/TSX, 35 SQL-Migrationen, ~528 Rust-Tests, ~264 TS-Tests.
- SQLite (WAL + FTS5) + lokale Embeddings (bge-small, candle); Credentials im OS-Keyring.
- Lizenz AGPL-3.0-only — gilt bei Verbreitung eines Forks weiter.

## Sync-Fixes (alle in `HANDOVER.md` begründet)
- `imap/mod.rs` `fetch_headers_inner`: **kein BODYSTRUCTURE** im Header-Fetch (desynchronisierte sonst die
  Session bei iCloud), Item-Liste aus nicht-leeren Teilen (kein doppeltes Leerzeichen).
- `sync/engine.rs`: `initial_backfill` markiert bei leerer 90-Tage-Suche nicht mehr als fertig;
  `fill_missing_uids` gleicht nach dem Walk gegen `UID SEARCH ALL` ab; Session-Verlust-Erkennung
  (SELECT ohne UIDNEXT/UIDVALIDITY); Body-Worker ruft `sync_failures::record_content` auf.
- `config.rs` / `accounts/credentials.rs`: `COMAIL_DATA_DIR`, `COMAIL_KEYRING_SERVICE`.
- `src-tauri/src/lib.rs`: `isolate_instance()` leitet beides aus dem Bundle-Identifier ab.

## Bauen
- `sh scripts/build-local-app.sh` → `/Applications/Comail.app`
- `sh scripts/build-dev-app.sh` → `Comail Dev.app`
- `pnpm dev:isolated` → Hot-Reload-Dev-Instanz
- Einmalig: `bash src-tauri/scripts/macos-dev-cert.sh` (Signatur-Identität `comail-dev`).

## Backup
- `Tasks/2026-11-17-comail-mail-backup.nosync/` — 11744 `.eml`, 2,5 GB, `manifest.json` mit UIDVALIDITY.
- Erzeugt mit `scripts/imap-backup.py`, rein lesend (`SELECT readonly`, `BODY.PEEK[]`).
- Verifikation immer über Message-ID-Mengen, **nicht** über Zähler pro Ordner: die App dedupliziert
  über Message-IDs, das Backup zählt pro Ordner. Letzter Abgleich: 0 fehlend.

## Offen
- Body-Fetch: async-imap 0.11.3 kann manche BODYSTRUCTURE-Antworten nicht parsen → ein Teil der Mails
  ohne Body/Embedding (als `content`-Failure vermerkt, blockiert nichts). Fix: Fallback auf `BODY.PEEK[]`
  + lokales MIME-Parsing (`mail-parser` ist bereits Dependency).
- MCP in beiden Instanzen aus (`mcpEnabled: false`, Port 47823).

## Umgebung
- node 26.7.0, pnpm 10.7.0 (lädt pnpm@11.11.0 selbst nach), cargo/rustc 1.99.1 via Homebrew, kein rustup,
  nur Xcode Command Line Tools (kein volles Xcode → keine Siri-Intents, kein `actool`).
- `.nosync` hält Ordner aus iCloud *und* Syncthing heraus (bestätigt vom Nutzer 2026-11-16).
