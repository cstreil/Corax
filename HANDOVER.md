# Übergabe — Stand der Fork-Arbeit

Diese Datei beschreibt, was an diesem Fork bisher geändert wurde, warum, und
wie man den aktuellen Zustand prüft. Sie ist für die Übergabe an einen
weiterarbeitenden Agenten gedacht. Die dauerhaften Projektfakten stehen
zusätzlich in `MEMORY.md`.

## Kontext

- Fork von <https://github.com/NextOSP/comail>, Branch `master` @ `d2384cd`, Version 0.2.41.
- Remote `upstream` = Original, `origin` ist frei für den eigenen Fork.
- Tauri 2: Rust-Core `src-tauri/crates/comail-core` (Tauri-frei), dünner Adapter
  `src-tauri/src`, React/TS-UI `src/`.
- Ziel: eigene Anpassungen. Vorher musste der Mail-Sync gegen iCloud überhaupt
  erst zuverlässig werden — das ist der Großteil der bisherigen Arbeit.

## Aktueller Stand (2026-11-17)

Dev-Instanz (`com.deanoss.comail.dev`, Datenverzeichnis
`~/Library/Application Support/com.deanoss.comail.dev`):

```
Mails            11012      (vollständig, siehe Verifikation)
Threads           7560
Ordner              40      alle backfill_done=1
Bodies            9387      von 11012 im Cache, Rest läuft
Embeddings        1618      von 11012, Rest läuft
Vektoren          2353
Session-Verluste     0      (vor dem Fix: 96)
```

Die Release-Instanz (`com.deanoss.comail`, `/Applications/Comail.app`) nutzt
dasselbe Binary mit der Basiskonfiguration und ein eigenes Datenverzeichnis.

## Änderungen und ihre Begründung

### 1. Header-Fetch: kein BODYSTRUCTURE mehr (`imap/mod.rs`, `fetch_headers_inner`)

Das war die eigentliche Ursache für den unvollständigen Sync.

iCloud liefert FETCH-Antworten, die async-imap 0.11.3 nicht parsen kann, wenn
`BODYSTRUCTURE` und `BODY[HEADER.FIELDS]` in **einer** Anfrage stehen. Ein
Parse-Fehler bricht die Antwort mitten im Stream ab. Wird die Session danach
weiterbenutzt, liest sie die Reste der alten Antwort — ab da liefert **jeder**
Befehl leere Ergebnisse: `SELECT` ohne UIDNEXT/UIDVALIDITY, `UID SEARCH ALL`
ohne Treffer. Der Backfill hält den Ordner für leer, markiert ihn als fertig
und speichert nichts.

Der Header-Fetch fordert deshalb nur noch Header an. Der MIME-Plan wird beim
Body-Fetch aus der BODYSTRUCTURE abgeleitet (`set_mime_plan` +
`upsert_planned_attachments` im Selective-Content-Pfad), es geht nichts verloren.
Einziger Kompromiss: das Büroklammer-Symbol erscheint erst, wenn der Body im
Cache ist.

Zusätzlich wird die Item-Liste aus nicht-leeren Teilen zusammengesetzt. Vorher
entstand bei IMAP-Konten (dort ist der providerspezifische Teil leer, nur Gmail
liefert `X-GM-*`) ein **doppeltes Leerzeichen** in der Liste, was iCloud
ebenfalls ablehnt.

### 2. `initial_backfill`: leere Suche ≠ leerer Ordner (`sync/engine.rs`)

`initial_backfill` sucht nur die letzten 90 Tage. Kam dabei nichts zurück,
wurde der Ordner als fertig markiert — auch wenn er ältere Mail enthält. Jetzt
startet der Walk in diesem Fall beim High-Water-Mark und läuft abwärts.

### 3. `fill_missing_uids`: Abgleich gegen die echte UID-Liste (`sync/engine.rs`)

Wenn der Range-Walk unten ankommt, wird der Ordner gegen `UID SEARCH ALL`
abgeglichen und alles Fehlende in 50er-Blöcken nachgeladen. Das fängt Fälle ab,
in denen ein Range-Fetch unvollständig zurückkam.

### 4. Session-Verlust-Erkennung (`sync/engine.rs`, History-Worker)

Ein gesundes `SELECT` liefert immer UIDNEXT und UIDVALIDITY. Fehlen beide, ist
die Session tot und async-imap liefert leere Antworten statt Fehlern. Das wird
jetzt als Fehler behandelt, damit der Worker die Session verwirft und neu
verbindet. Sicherheitsnetz — mit Fix 1 löst es nicht mehr aus.

### 5. Body-Worker vermerkt Fehler (`sync/engine.rs`)

Der Embedding-Worker pausiert, solange Mails mit `body_state='none'` **ohne**
Eintrag in `sync_failures` (stage `content`) existieren. Der Body-Worker legte
bei Einzel-Fehlern aber nie einen Eintrag an, sondern stellte die Mail nur
wieder in die Queue — der Embedder lief dadurch nie. Jetzt wird
`sync_failures::record_content` mit Retry-Zeit aufgerufen.

### 6. Instanz-Isolierung (`config.rs`, `accounts/credentials.rs`, `src-tauri/src/lib.rs`)

Damit ein Dev-Build neben einer installierten Release-App laufen kann, ohne
deren SQLite-DB, Roh-Mails, Logs, Modellgewichte oder Keychain-Einträge zu
teilen:

- `COMAIL_DATA_DIR` und `COMAIL_KEYRING_SERVICE` als Overrides.
- `isolate_instance()` in `lib.rs` leitet beides aus einem Bundle-Identifier
  ≠ `com.deanoss.comail` ab. Läuft vor `init_logging()`, damit auch das Log
  im richtigen Verzeichnis landet.

### 7. Build- und Dev-Skripte

| Datei | Zweck |
|---|---|
| `scripts/build-local-app.sh` | Release-Build aus dem Fork, installiert nach `/Applications` |
| `scripts/build-dev-app.sh` | `Comail Dev.app` (Release-Profil, Dev-Identifier) |
| `scripts/dev-isolated.sh` | `tauri dev` mit Dev-Overlay |
| `scripts/imap-backup.py` | rein lesendes IMAP-Vollbackup als `.eml` |
| `src-tauri/tauri.dev.conf.json` | Dev-Overlay: Identifier, Name, Updater aus |
| `src-tauri/tauri.local.conf.json` | lokaler Build: Updater-Endpoints und -Artefakte aus |

`build-local-app.sh` und `build-dev-app.sh` entfernen für den Build
`bundle.macOS.files` aus `tauri.conf.json` und stellen die Datei per `trap`
wieder her: ohne volles Xcode fehlen die Siri-Intents-Metadaten, der
Bundle-Eintrag lässt das Bundling sonst scheitern.

## Bauen und starten

```bash
cd "Projekte/comail.nosync"

sh scripts/build-local-app.sh   # → /Applications/Comail.app
sh scripts/build-dev-app.sh     # → Comail Dev.app, danach nach /Applications kopieren
pnpm dev:isolated               # Hot-Reload-Dev-Instanz
```

Voraussetzungen: `bash src-tauri/scripts/macos-dev-cert.sh` einmalig ausführen
(legt die Signatur-Identität `comail-dev` an, damit die Keychain-Freigabe
Rebuilds überlebt). Das Skript braucht `openssl pkcs12 -legacy`; ohne das Flag
scheitert `security import` mit „MAC verification failed" (Homebrew-OpenSSL 3+/4.x).

## Verifikation

Der verlässlichste Abgleich läuft über das Backup, **nicht** über Zähler pro
Ordner: die App dedupliziert über Message-IDs, das Backup zählt pro Ordner.
Eine Mail, die in INBOX und in einem Label-Ordner liegt, ist in der App eine
Zeile.

```bash
# Backup (rein lesend, SELECT readonly + BODY.PEEK[])
python3 scripts/imap-backup.py \
  "/Users/cs/Library/Mobile Documents/com~apple~CloudDocs/Work/Tasks/2026-11-17-comail-mail-backup.nosync"

# Abgleich: Message-IDs normalisieren (spitze Klammern entfernen, lowercase)
# und die Mengen differenzieren. Erwartung: "nur im Backup: 0".
```

Letzter Stand: Backup 11744 Dateien / 11011 eindeutige Message-IDs,
App 11012 eindeutige, **0 fehlend**.

## Offene Punkte

1. **Body-Fetch scheitert bei einem Teil der Mails.** async-imap kann manche
   BODYSTRUCTURE-Antworten nicht parsen (`body worker: IMAP chunk failed`).
   Betroffene Mails bekommen keinen Body und kein Embedding; sie sind als
   `content`-Failure vermerkt und blockieren nichts. Sauberer Fix: Fallback auf
   `BODY.PEEK[]` (ganze Mail) plus lokales MIME-Parsing mit `mail-parser`, das
   ist bereits Abhängigkeit von `comail-core`.
2. **Embeddings laufen noch** (1618 von 11012). Sobald die Bodies durch sind,
   zieht der Embedder mit ~100 Mails/Minute nach.
3. **Attachment-Symbol** erscheint erst nach dem Body-Cache (Folge von Fix 1).
   Falls das stört: BODYSTRUCTURE in einem eigenen, separaten Request nach dem
   Header-Fetch holen — aber niemals in derselben Anfrage.
4. **MCP ist aus** in beiden Instanzen (`mcpEnabled: false`, Port 47823). Für
   Agenten-Zugriff in den Settings aktivieren; bei parallelem Betrieb braucht
   die zweite Instanz einen anderen Port.

## Fallstricke

- **iCloud + async-imap 0.11.3**: kombinierte FETCH-Requests und doppelte
  Leerzeichen in der Item-Liste führen zu Antworten, die der Parser nicht
  verarbeitet. Eine teilweise konsumierte Antwort desynchronisiert die Session
  dauerhaft. Nach einem Parse-Fehler darf eine Session **nie** weiterbenutzt
  werden.
- iCloud verteilt Anfragen auf verschiedene Backend-Knoten
  (`p00-iscream-20/60/100-percent-…`), die sich unterschiedlich tolerant
  verhalten — Fehler wirken dadurch sporadisch.
- Kein volles Xcode auf dieser Maschine: Siri-Intents und `actool`
  (`Assets.car`) fehlen, das `.icns` wird trotzdem benutzt.
- `package.json` verlangt pnpm 11.11.0; pnpm lädt die Version bei Bedarf selbst
  nach. In nicht-interaktiven Shells ggf. `CI=true` setzen.
- `.nosync` im Ordnernamen hält den Ordner aus iCloud **und** Syncthing heraus.
