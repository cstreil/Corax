# MEMORY — Corax (Fork von comail)

## Stand (2026-11-19)
- Fork `cstreil/Corax` (public, AGPL-3.0-only); `origin` = Fork, `upstream` = NextOSP/comail, Arbeit auf `fork/sync-fixes`. Details `FORK.md`, Fix-Begründungen `HANDOVER.md`.
- v0.2.46 veröffentlicht (2026-11-18: eigenes Icon, Themes, `R`/`⇧R`, eigener Updater); Upstream v0.2.44 (`ded0898`) eingezogen. Update 0.2.44 → 0.2.45 in `/Applications/Corax.app` getestet.
- Push nur lokal über `gh` (Account `cstreil`; einmalig `gh repo set-default cstreil/Corax`) — der GitHub-Connector pusht nicht.
- Zwei Instanzen, gleiches Binary: `de.streil.rabe` = `/Applications/Corax.app`, `de.streil.rabe.dev` = `Corax Dev.app`.

## Technik
- Tauri 2: Rust-Core `src-tauri/crates/comail-core` (Tauri-frei) + Adapter + React/TS; ~58k Rust, ~43k TS/TSX, 39 Migrationen, 533 Rust-/400 TS-Tests; SQLite (WAL, FTS5), lokale Embeddings (candle), Credentials im Keyring.
- Migrationen: Fork 036/037/038; Upstreams Datei bleibt **039** — nicht umnummerieren (bricht jede Fork-DB).
- `async-imap 0.12` (0.16 scheiterte an iClouds `NIL`/UTF-8 in quoted strings); `base64 0.22` mit `with_decode_allow_trailing_bits(true)`; QP-Heuristik nur `=3D` vor Anführungszeichen, Schwelle 2.
- HTML: Ammonia behält `<style>`/`class`, Grenze ist die iframe-CSP (`default-src 'none'`).
- Ordner (mUTF-7): Schlüssel **nicht** normalisieren — iCloud legt Umlaute zerlegt ab, NFC nur in der Anzeige; iCloud lehnt parallele Verbindungen mit `[AUTHENTICATIONFAILED]` ab.

## Muss Upstream-Merges überleben
- Zwei-Schritt-FETCH (BODYSTRUCTURE getrennt): iCloud desynchronisiert bei kombiniertem FETCH.
- `done` erst nach Abgleich (036/037); `isolate_instance` leitet Datenverzeichnis und Keyring-Service aus dem Bundle-Identifier ab (`COMAIL_DATA_DIR`, `COMAIL_KEYRING_SERVICE`).
- Auditor-Review 2026-11-18: Sicherheit freigegeben (iframe-CSP als Grenze); akzeptiertes Restrisiko: Base64-Endzeile mit 60–76 Zeichen als QP-Marker.

## Eigene Features
- Themes `snow` = „Glas" (hell, `#2f62ff`), `carbon` = „Graphit" (dunkel, `#ff8d52`); IDs bewusst unverändert.
- Icon: Vogelkopf (Variante A) aus `design/icon/`, `pnpm tauri icon`; Upstreams `Icon.icon` ist entfallen.
- Offene Mail = **eine ruhige Karte inkl. Kopf**; das Antwortziel markiert nur `border-accent/40` mit 1-px-Ring.
- `inboxDefaultSplits` Default **aus** (eine ungeteilte Inbox); Inline-Mail klappt als Panel unter der Zeile auf, Klick auf die Kopfzeile klappt ein.
- Deutsch: 1708/1837, Anrede „du"; Rest bewusst englisch in `UNTRANSLATED_BY_DESIGN` (`src/i18n/localeParity.test.ts`); `node scripts/i18n-status.mjs de`, Regeln `docs/i18n-de.md`.
- Snooze `src/lib/snooze.ts` parst nur Englisch; deutsche Zeitwörter zurückgestellt (dann `common:timePopover`/`calendar:create` umstellen).

## Corax Native (Branch `feat/native-ui`)
- Ziel: Tauri-UI durch SwiftUI/AppKit (macOS) und Qt/QML (Linux) auf unverändertem `comail-core` ersetzen; Plan `docs/native-ui/ARCHITEKTUR.md`, E9 = macOS 27.0, Ziel nativer RSS ≤ 50 % der Tauri-App. P0/P1 abgenommen, P1b–P1e abgegeben (Audit P1e offen), Berichte `Work/Tasks/2026-11-18-rabe-native-p0/`.
- Neu: `src-tauri/crates/corax-host` (Start, Isolation, 102 Commands), `corax-uniffi`, `apps/macos` (SwiftPM, `apps/macos/scripts/build-app.sh`), `corax-cli`.
- **R9: schreibende Commands nie gegen `de.streil.rabe.native`** (echtes iCloud-Konto) — nur Sandbox; echte Instanz zusätzlich per `CORAX_ALLOW_WRITES=1` gesperrt.
- Sandbox `de.streil.rabe.native.sandbox` über `CORAX_IDENTIFIER`; `corax-cli --identifier … seed-sandbox` füllt Mockup-Mails, Konto auf `*.sandbox.invalid`. Sandbox-Settings: `inboxDefaultSplits` an, `autoLabels` aus, `embeddingBackend` none, MCP Port 47834.
- Test-Hooks `CORAX_DEBUG_AUTOMATION=1` + `walkthrough.sh` erreichen **jede** laufende App mit diesem Env (Distributed Notification).
- P2-Messung 2026-11-19: native 488,6 MiB vs Tauri 163,5 MiB RSS = **299 %** (Ziel ≤ 50 %), Ursache 449-MB-Embedding-Modell; `Work/Tasks/2026-11-18-rabe-native-p2/MESSUNG.md`.

## Linux
- Scott (x86/CachyOS, Plasma, `ssh scott`) und Burton (ARM/Omarchy, Hyprland, `ssh burton`) bauen das Linux-Paket (0.2.46); AppImage scheitert an linuxdeploy → für Arch ist ein PKGBUILD richtig.
- System-Palette in `comail-core/src/system_theme.rs`: Omarchy 4 liest `~/.local/state/omarchy/current/theme/colors.toml` und ist **vor** Plasma zu prüfen (Omarchy schreibt eigenes `kdeglobals`); `applySystemColors(null)` darf `--accent` nie löschen, eigener Akzent schlägt den Desktop-Akzent, `violet` ist Standard und lässt ihn durch.

## Bauen
- `sh scripts/build-dev-app.sh` → `Corax Dev.app`; `sh scripts/build-local-app.sh` → `/Applications/Corax.app`; `sh scripts/release-fork.sh [--no-publish]` (Release, Updater-Key `~/.tauri/rabe-updater.key`, Version vorher in `tauri.conf.json` hochziehen — gleiche Version = kein Update).
- Signatur: echte `Apple Development`-Identität (Team `2XSHYS8HMR`), Fallback `comail-dev`. Dev-Skript patcht `tauri.conf.json` und stellt per `trap` zurück — während des Builds nicht committen.

## Offen
- Linux-Builds von `2eb0ec4` fehlen (Hosts waren offline); auf Burton `theme` in `app_settings` auf `system` setzen.
- Fehlt: „Passwort ändern" für IMAP (nur OAuth-Reauth), deutsche Snooze-Zeitwörter, Arch-Paketierung, Deko je Desktop.
- Aufräum-Reste: `/Applications/Comail.app` (0.2.41), alte Dev-Daten (`com.deanoss.comail.dev`, `de.streil.rabe.dev` je ~885 MB), `Comail Dev.app` in `~/.Trash`.
- MCP Port 47823, Token im Keyring je Instanz (Release = Service `comail`, Dev = `de.streil.rabe.dev`); DSH-Capability über einen Shim aus `~/.dsh/bin`.

## Backup
- `Work/Tasks/2026-11-17-comail-mail-backup.nosync/`: 11744 `.eml`, 2,5 GB, `manifest.json` mit UIDVALIDITY; `scripts/imap-backup.py` (nur lesend), letzter Abgleich 0 fehlend.

## Umgebung
- node 26.7.0, pnpm 10.7.0, cargo/rustc 1.99.1 via Homebrew (kein rustup), nur Xcode CLT, macOS 27.3 ohne `actool`; `.nosync` hält Ordner aus iCloud *und* Syncthing heraus.
- cua: Apps über `open -a` starten, Klicks ~1 Zeile höher als geschätzt, gesperrter Desktop → `SESSION_LOCKED`, Ausweg `screencapture -x -l <id>`.
