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
- ~58k Zeilen Rust, ~43k Zeilen TS/TSX, 35 SQL-Migrationen, ~531 Rust-Tests, ~264 TS-Tests.
- SQLite (WAL + FTS5) + lokale Embeddings (bge-small, candle); Credentials im OS-Keyring.
- Lizenz AGPL-3.0-only — gilt bei Verbreitung eines Forks weiter.
- `async-imap 0.12` / `imap-proto 0.17` (seit 2026-11-17): 0.16.7 konnte iClouds `NIL` als
  Transfer-Encoding und UTF-8 in quoted strings nicht parsen → Body-Fetch und Session-Desync.
- `base64` 0.22 lehnt Base64 mit nicht-null Padding-Bits im letzten Symbol ab (RFC 2045 verlangt
  Nullen, Mailer halten sich nicht daran). `decode_base64_transfer` nutzt deshalb eigene Engines
  mit `with_decode_allow_trailing_bits(true)`.
- HTML-Sanitizer (Ammonia) behält seit 2026-11-17 `<style>` und `class`; `clean_content_tags` ist
  `["script","title"]`. Sicherheitsgrenze ist die iframe-CSP (`default-src 'none'`), nicht der
  Sanitizer — Ammonia kann keine Stylesheets filtern. `<title>`-Text wird verworfen (Metadaten).
- `looks_like_undecoded_quoted_printable` zählt nur noch `=3D` vor einem Anführungszeichen und
  UTF-8-Escapes-Läufe außerhalb von RFC-2047-Encoded-Words (Schwelle 2). Vorher: jedes `=XX`,
  ab 8 → ~1100 Fehlalarme pro Start (URL-Parameter, Encoded-Words, Base64).
- iCloud-IMAP lehnt **gleichzeitige** Verbindungen mit `[AUTHENTICATIONFAILED]` ab, obwohl das
  App-Passwort gültig ist. Die App öffnet Sync-Actor, Body-Fetcher und Mutation-Worker parallel;
  einzelne Versuche scheitern, der nächste gelingt. Nicht als falsches Passwort deuten.

## Sync-Fixes (alle in `HANDOVER.md` begründet)
- `imap/mod.rs` `fetch_headers_inner`: BODYSTRUCTURE kommt aus einem **zweiten** FETCH
  (`attach_mime_plans`), nie kombiniert mit `BODY[HEADER.FIELDS]` — die Kombination desynchronisiert
  iCloud-Sessions. Item-Listen immer aus nicht-leeren Teilen bauen (kein doppeltes Leerzeichen).
- `imap/identity.rs` `fetch_identities`: baute die Query mit leerem Provider-Item als
  `"RFC822.SIZE  BODY.PEEK[...]"` (zwei Leerzeichen) → iCloud lehnt ab → **jede** Identitätsliste
  kam leer zurück. Folge: Trash-Reconciler adoptierte keine uid-losen Zeilen, und Moves konnten ihre
  Ziel-UID nicht ermitteln (Zeile blieb `uid NULL`). Behoben 2026-11-17, 12 Zeilen adoptiert.
- `sync/engine.rs`: `initial_backfill` markiert bei leerer 90-Tage-Suche nicht mehr als fertig;
  `fill_missing_uids` gleicht nach dem Walk gegen `UID SEARCH ALL` ab; Session-Verlust-Erkennung
  (SELECT ohne UIDNEXT/UIDVALIDITY); Body-Worker ruft `sync_failures::record_content` auf.
- `config.rs` / `accounts/credentials.rs`: `COMAIL_DATA_DIR`, `COMAIL_KEYRING_SERVICE`.
- `src-tauri/src/lib.rs`: `isolate_instance()` leitet beides aus dem Bundle-Identifier ab.

## Bauen
- `sh scripts/build-local-app.sh` → `/Applications/Comail.app`
- `sh scripts/build-dev-app.sh` → `Comail Dev.app`
- `pnpm dev:isolated` → Hot-Reload-Dev-Instanz
- Signatur: bevorzugt eine echte `Apple Development`-Identität (Team-ID `2XSHYS8HMR`), Fallback
  `comail-dev` (einmalig via `bash src-tauri/scripts/macos-dev-cert.sh`). Nur eine Apple-Signatur
  trägt eine Team-ID und damit eine stabile Keychain-Partition-ID; selbstsigniert → CDHash →
  Freigabe bei jedem Rebuild. Verifiziert 2026-11-17: fremdes Binary mit derselben Signatur liest
  den Eintrag ohne Prompt.

## Backup
- `Tasks/2026-11-17-comail-mail-backup.nosync/` — 11744 `.eml`, 2,5 GB, `manifest.json` mit UIDVALIDITY.
- Erzeugt mit `scripts/imap-backup.py`, rein lesend (`SELECT readonly`, `BODY.PEEK[]`).
- Verifikation immer über Message-ID-Mengen, **nicht** über Zähler pro Ordner: die App dedupliziert
  über Message-IDs, das Backup zählt pro Ordner. Letzter Abgleich: 0 fehlend.

## Offen
- MCP in beiden Instanzen aus (`mcpEnabled: false`, Port 47823).
- Embeddings laufen nach dem Body-Requeue noch nach (~2300 offen, ~300/Minute).
- Büroklammer aus dem Header-Fetch ist gebaut, aber noch nicht mit einer echten neuen Mail mit
  Anhang verifiziert (Stand 2026-11-17 22:10).

## Umgebung
- node 26.7.0, pnpm 10.7.0 (lädt pnpm@11.11.0 selbst nach), cargo/rustc 1.99.1 via Homebrew, kein rustup,
  nur Xcode Command Line Tools (kein volles Xcode → keine Siri-Intents, kein `actool`).
- `.nosync` hält Ordner aus iCloud *und* Syncthing heraus (bestätigt vom Nutzer 2026-11-16).
