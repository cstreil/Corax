# MEMORY — Rabe (Fork von comail)

## Stand
- Fork von NextOSP/comail: https://github.com/cstreil/Rabe (public, AGPL-3.0-only); `origin` = Fork,
  `upstream` = Original, Arbeit auf `fork/sync-fixes`. Repo am 2026-11-18 von `comail` in `Rabe`
  umbenannt (alte URLs leiten 301 um). Details `FORK.md`, Fix-Begründungen `HANDOVER.md`.
- Upstream v0.2.44 (`ded0898`) eingezogen → Branch `chore/merge-upstream-0.2.44` (50 Commits, PR #1 offen),
  darauf Rabe-Umbenennung, Shortcut `a`, Keyring-Migration, eigener Updater.
- **v0.2.46 veröffentlicht** (2026-11-18): eigenes Rabe-Icon, Themes Glas/Graphit, dezenter
  Antwortrahmen, `R`/`⇧R` statt `Enter`. Update-Test 0.2.44 → 0.2.45 in `/Applications/Rabe.app`
  bestanden (Keychain bleibt, Sync ohne Passwortabfrage); 0.2.45 → 0.2.46 testet der Nutzer selbst.
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
- IMAP-Mailboxen sind modifiziertes UTF-7 (`mutf7.rs`); Schlüssel **nicht** normalisieren (iCloud legt
  Umlaute zerlegt ab, komponiert → `[NONEXISTENT]`; NFC nur in der Anzeige). iCloud lehnt parallele
  Verbindungen mit `[AUTHENTICATIONFAILED]` ab, obwohl das App-Passwort gilt.

## Sync-Fixes
- Zwei-Schritt-FETCH (BODYSTRUCTURE getrennt, `header_fetch_query(items, false)`, `attach_mime_plans` nur
  bei `with_structure`), `done` erst nach Abgleich (036/037), `isolate_instance` leitet Datenverzeichnis
  und Keyring-Service aus dem Bundle-Identifier ab (`COMAIL_DATA_DIR`, `COMAIL_KEYRING_SERVICE`).
  Begründungen und Code-Stellen: `HANDOVER.md`.
- Review (Auditor 2026-11-18): Sicherheit freigegeben (iframe-CSP als Grenze); akzeptiertes Restrisiko
  eine Base64-Endzeile mit 60–76 Zeichen als QP-Marker.

## Eigene Features
- Themes seit 2026-11-18: `snow` = „Glas" (hell, blauer Akzent `#2f62ff`), `carbon` = „Graphit"
  (dunkel, Akzent `#ff8d52`); Palette aus `Tasks/2026-11-18-mail-app-mockup`. IDs bewusst unverändert
  (localStorage, Unions, Locale-Keys) — nur Werte und Labels.
- Offene Mail = **eine ruhige Karte inklusive Kopf** (`border-hairline` + `shadow-card`); das Antwortziel
  markiert nur `border-accent/40` mit 1-px-Ring (10 %). Kein 2-px-Akzentrahmen mehr (Commit `811a106`).
- Icon seit 2026-11-18: Rabenkopf (Variante A) aus `design/icon/`; `pnpm tauri icon` erzeugt `src-tauri/icons/`,
  Upstreams `Icon.icon` ist entfallen (kein `actool`/Icon Composer auf diesem Mac).
- `inboxDefaultSplits` Default **aus**: eine ungeteilte Inbox; eigene Splits/Auto-Tabs erscheinen weiter.
- Inline-Mailansicht: Mail klappt als Panel unter ihrer Zeile auf (Deckel 75 %, min. drei Zeilen,
  `ResizeObserver`); Klick auf die Kopfzeile klappt ein, `openThreadFull` öffnet die Vollansicht.
- Deutsch: 1708/1837, Anrede „du"; 129 bewusst englisch in `UNTRANSLATED_BY_DESIGN`
  (`src/i18n/localeParity.test.ts`), Test schlägt bei neuem Englisch fehl. Werkzeuge:
  `node scripts/i18n-status.mjs de [--missing]`, Regeln in `docs/i18n-de.md`.
- `src/lib/snooze.ts` parst nur englische Zeitwörter; deutsche Keyword-Tabelle vom Nutzer 2026-11-18
  zurückgestellt (danach Platzhalter in `common:timePopover`/`calendar:create` umstellen).

## Linux (angefangen 2026-11-18)
- Scott (x86/CachyOS, Plasma 6.8.2 Wayland, `ssh scott`) und Burton (ARM/Omarchy, Hyprland, `ssh burton`)
  bauen `Rabe_0.2.46_*.deb` mit `CARGO_BUILD_JOBS=3 pnpm tauri build --bundles deb` (~11–45 min).
  AppImage scheitert an linuxdeploy, wird nicht verfolgt; für Arch ist ein PKGBUILD richtig, `.deb` nur
  Zwischenstand. `patchelf` fehlt auf Burton, dort braucht `sudo` ein Passwort.
- `System` liest unter Linux die Desktop-Palette: `comail-core/src/system_theme.rs`, Command
  `system_colors`, Overlay `src/themes/system.ts`. Plasma aus `~/.config/kdeglobals`, Omarchy 4 aus
  `~/.local/state/omarchy/current/theme/colors.toml` (der 3er-Pfad `~/.config/omarchy/current` gilt nur
  für Omarchy 3). **Omarchy vor Plasma prüfen**: Omarchy schreibt eine eigene `kdeglobals`, deren
  `[Colors:Selection] BackgroundNormal` das Auswahl-Grau ist, nicht der Akzent. `mode` entscheidet
  hell/dunkel, Luminanz nur als Rückfall.
- Die Palette überschreibt nur Flächen, Text, Akzent und Hairline; Schatten, KI- und Selection-Töne
  bleiben aus Glas/Graphit. Ein selbst gewählter Akzent schlägt den Desktop-Akzent; `violet` ist der
  Standard und lässt den Desktop-Akzent durch. `applySystemColors(null)` darf `--accent` nie löschen.
- Burton steht auf Omarchy-Theme `matte-black` (dunkel, Akzent `#e68e0d`), Rabe dort auf `carbon`/`violet`.
- Offen: Deko je Desktop (Hyprland zeichnet eigene Fensterknöpfe), Arch-Paketierung, Scott hat kein Konto.

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
  `scripts/imap-backup.py` (nur lesend). Letzter Abgleich über Message-IDs: 0 fehlend.

## Offen
- **Linux-Builds von `2eb0ec4` stehen aus**: Scott und Burton gingen am 2026-11-18 gegen 20:30 offline;
  die vorherigen Builds (vor den beiden Theme-Fixes) habe ich abgebrochen. Nach dem Aufwecken neu bauen
  und die Palette im Screenshot prüfen (Burton: `theme` in `app_settings` auf `system` setzen).
- Eigene Einstellungen fehlen: „Passwort ändern" für IMAP (nur OAuth-Reauth), deutsche Snooze-Zeitwörter.
- Aufräum-Reste: `/Applications/Comail.app` (Upstream 0.2.41) und alte Dev-Daten (`com.deanoss.comail.dev`,
  `de.streil.rabe.dev` je ~885 MB) stehen noch; `Comail Dev.app` liegt in `~/.Trash`.
- cua: `open -a "/Applications/Rabe Dev.app"` nötig (`cua.activate` hilft nicht), Klicks ~1 Zeile höher als
  geschätzt (Screenshot-Pixel × 1,043), gesperrter Desktop → `SESSION_LOCKED`; `screencapture -x -l <id>` als Ausweg.
- MCP (Port 47823), Token im Keyring je Instanz: **Release = Service `comail`**, Dev = `de.streil.rabe.dev`
  (`isolate_instance` setzt den Service nur für Nicht-Release-Builds). DSH-Capability `rabe` läuft über
  `~/.dsh/bin/rabe-mcp-shim.py` (stdio → HTTP, liest den Token der laufenden Instanz, erneuert ihn bei 401).
  Freigaben Release: Entwürfe ja, Organisieren/Senden aus → 17 Tools statt 19.
- Semantische Suche: Vektor in `message_embeddings` (f32, L2), beim Start in flachen RAM-Index (brute
  force, ~1 ms); hybrid mit FTS5 über RRF. Dev-Instanz: multilinguales MiniLM, 11k Mails indiziert.
- Selbst gesendete Mail an die eigene Adresse erscheint nur einmal (Message-ID-Dedupe).

## Umgebung
- node 26.7.0, pnpm 10.7.0, cargo/rustc 1.99.1 via Homebrew (kein rustup), nur Xcode Command Line Tools;
  macOS 27.3 ohne `actool`. `.nosync` hält Ordner aus iCloud *und* Syncthing heraus.
