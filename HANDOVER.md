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

Dev-Instanz (`de.streil.rabe.dev`, Datenverzeichnis
`~/Library/Application Support/de.streil.rabe.dev`):

```
Mails            11015      (vollständig, siehe Verifikation)
Threads           7563
Ordner              40      alle backfill_done=1
Bodies           11015      alle im Cache
Embeddings        4201      von 11015, läuft
Session-Verluste     0      (vor dem Fix: 96)
Content-Fehler       0
```

Die Release-Instanz (`de.streil.rabe`, `/Applications/Rabe.app`) nutzt
dasselbe Binary mit der Basiskonfiguration und ein eigenes Datenverzeichnis.

## Änderungen und ihre Begründung

### 1. Header-Fetch: kein BODYSTRUCTURE mehr (`imap/mod.rs`, `fetch_headers_inner`)

Das war der Auslöser für den unvollständigen Sync — die eigentliche Ursache lag
aber im Parser (siehe Punkt 8).

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
  ≠ `de.streil.rabe` ab. Läuft vor `init_logging()`, damit auch das Log
  im richtigen Verzeichnis landet.

### 7. Build- und Dev-Skripte

| Datei | Zweck |
|---|---|
| `scripts/build-local-app.sh` | Release-Build aus dem Fork, installiert nach `/Applications` |
| `scripts/build-dev-app.sh` | `Rabe Dev.app` (Release-Profil, Dev-Identifier) |
| `scripts/dev-isolated.sh` | `tauri dev` mit Dev-Overlay |
| `scripts/imap-backup.py` | rein lesendes IMAP-Vollbackup als `.eml` |
| `src-tauri/tauri.dev.conf.json` | Dev-Overlay: Identifier, Name, Updater aus |
| `src-tauri/tauri.local.conf.json` | lokaler Build: Updater-Endpoints und -Artefakte aus |

`build-local-app.sh` und `build-dev-app.sh` entfernen für den Build
`bundle.macOS.files` aus `tauri.conf.json` und stellen die Datei per `trap`
wieder her: ohne volles Xcode fehlen die Siri-Intents-Metadaten, der
Bundle-Eintrag lässt das Bundling sonst scheitern.

### 8. async-imap 0.12 / imap-proto 0.17 — die eigentliche Parser-Ursache

Der Body-Fetch scheiterte bei einem Teil der Mails (`body worker: IMAP chunk
failed`). Ursache war **nicht** async-imap als Ganzes, sondern der
BODYSTRUCTURE-Parser in imap-proto 0.16.7, mit zwei Lücken:

1. **`NIL` als Transfer-Encoding.** iCloud sendet
   `("text" "plain" ("CHARSET" "UTF-8") NIL NIL NIL 160 8 …)` — das dritte
   `NIL` ist die Transfer-Encoding. `body_encoding` akzeptierte nur einen
   quoted string oder ein Literal. Betraf 511 von 520 Fehler-Logzeilen
   (89 von 91 UIDs).
2. **UTF-8-Bytes in quoted strings.** Umlaute in Anhangsnamen
   (`… Kostüme …`) lehnte `quoted` über `is_text_char` ab (UID 1043).

Ein Parse-Fehler bricht die ganze FETCH-Antwort ab und desynchronisiert die
Session — das ist auch die tiefere Erklärung für die 96 Session-Verluste.
Wichtig: der Fehler tritt bei `(UID BODYSTRUCTURE)` **allein** auf; die
Kombination mit `BODY[HEADER.FIELDS]` war nur der Auslöser, der ihn zuerst
sichtbar gemacht hat.

Behoben durch das Upgrade auf `async-imap 0.12.0` → `imap-proto 0.17.0`
(akzeptiert `NIL` als `SevenBit`, erlaubt UTF-8 in quoted strings). Angepasst
werden musste nur `imap/identity.rs`: `Response::Data`/`Done` tragen in 0.17
ein `outcome`-Feld statt `code`/`information`, und `UidSetMember` liegt jetzt
unter `imap_proto::rfc4315`.

Regressionstest: `mime::selective_section_tests::
parses_icloud_bodystructures_with_nil_encoding_and_utf8_names` parst die
Original-Antworten aus dem Log. Er schlägt mit imap-proto 0.16.7 fehl und
läuft mit 0.17.0 durch.

Damit ist auch der Kompromiss aus Punkt 1 hinfällig: `BODYSTRUCTURE` kann
wieder in den Header-Fetch, dann erscheint die Büroklammer sofort. Die
Persistenz dafür ist noch vorhanden (`store_headers` schreibt `fh.mime_plan`
und `fh.has_attachments`), es müssten nur die beiden Felder in
`fetch_headers_inner` wieder befüllt werden.

### 9. Base64 mit nicht-null Padding-Bits (`mime/mod.rs`, `decode_base64_transfer`)

Drei Mails blieben dauerhaft ohne Body (`mime error: invalid Base64 selective
MIME section`, Message-IDs 148, 4631, 4703). Die gelieferten Abschnitte waren
vollständig — Länge exakt wie in der BODYSTRUCTURE deklariert — und in Python
strikt dekodierbar. Der Rust-Decoder lehnte sie trotzdem ab.

Ursache: **das letzte Base64-Symbol hat gesetzte, aber unbenutzte Bits.**
RFC 2045 verlangt dort Nullen, der Mailer hält sich nicht daran:

```
...PC9odG1sPi==   letztes Zeichen 'i' = 0b100010, 4 unbenutzte Bits = 0b0010
...PC90cj48L3RhYmxlPl==   'l' = 0b100101, 0b0101
...PC90cj48L3RhYmxlPn==   'n' = 0b100111, 0b0111
```

Die dekodierten Bytes sind eindeutig (die Bits werden verworfen), aber
`base64` 0.22 hat `decode_allow_trailing_bits` standardmäßig aus und lehnt den
ganzen Abschnitt ab. Behoben mit zwei eigenen Engines (`BASE64_PADDED`,
`BASE64_UNPADDED`) mit `with_decode_allow_trailing_bits(true)`.

Regressionstest: `mime::selective_section_tests::
decodes_base64_with_non_zero_padding_bits` mit den echten Endungen aus dem Log.

Diagnosehilfe, die dorthin geführt hat und geblieben ist: schlägt das Dekodieren
fehl, schreibt `decode_selective_content` die Rohbytes nach
`$TMPDIR/comail-section-<message_id>-<section>.{body,mime}` und die
Fehlermeldung nennt Länge, Position des ersten ungültigen Zeichens und die
letzten 32 Bytes.

### 10. Keychain-Freigabe bei jedem Rebuild (`scripts/build-dev-app.sh`)

Jeder Rebuild verlangte eine neue Keychain-Freigabe. Ursache ist nicht die
Signatur an sich, sondern die **Partition-ID** des Keychain-Eintrags
(`___INTEGRITY___`-ACL): eine App ohne Team-ID bekommt dort ihren CDHash, und
der ändert sich bei jedem Build. Das selbstsignierte `comail-dev`-Zertifikat
liefert keine Team-ID (`TeamIdentifier=not set`) und ist zusätzlich nicht
vertrauenswürdig (`CSSMERR_TP_NOT_TRUSTED`), deshalb greift auch die
Requirement-basierte ACL-Regel nicht.

`build-dev-app.sh` und `macos-dev-sign.sh` bevorzugen jetzt eine echte
`Apple Development`-Identität (erkannt über `security find-identity -v -p
codesigning`), Fallback bleibt `comail-dev`. Nur eine Apple-ausgestellte
Signatur trägt eine Team-ID und damit eine stabile Partition-ID.

Nebenbei behoben: `src-tauri/.cargo/config.toml` schrieb den Runner als
einfachen String. Cargo trennt den an Leerzeichen, was im Pfad
`…/Mobile Documents/…` scheitert — jetzt Array-Form (`runner = ["…"]`).

### 11. Command Code als KI- und Decision-Provider

Command Code (`commandcode.ai`) fehlte in beiden Provider-Listen. Es ist
OpenAI-kompatibel, deshalb war der Chat-Teil ein Preset:

| | |
|---|---|
| Chat | `https://api.commandcode.ai/provider/v1` (OpenAI Chat Completions) |
| Decision | `https://api.commandcode.ai/provider/v1/systemone` (TypeSafe System One) |
| Auth | `Authorization: Bearer <CMD_API_KEY>`, derselbe Key für CLI und API |

Der Endpunkt antwortet auch auf HTTP/1.0, was der App-Client spricht
(`ai/mod.rs` `format_request`) — geprüft mit `curl --http1.0`.

Chat: neues Preset `commandcode` in `AI_PROVIDER_PRESETS`
(`SettingsPanel.tsx`), Default-Modell `deepseek/deepseek-v4.1-flash`.
**Einschränkung:** 90 der 102 Modelle laufen über `/chat/completions`, die 12
Claude-Modelle nur über `/messages` (Anthropic-Shape). Diesen Dialekt spricht
der Client nicht, Claude ist über Command Code also nicht nutzbar.

Decision: `COMMANDCODE_URL` + `DEFAULT_COMMANDCODE_MODEL` (`typesafe/jev`) in
`ai/decisions.rs`, neuer Key-Slot `Slot::DecisionCommandCodeKey`
(`decision_api_key_commandcode`), Zuordnung in `lib.rs` (`decision_config`,
`set_decision_key`) und `share_ai_key` (teilt den Chat-Key nur, wenn der
Chat-Provider ebenfalls Command Code ist). UI: Option in `DecisionSettings.tsx`
plus Modell-Vorschläge, Strings in allen fünf Locales.

Der Decision-Dialekt ist `Dialect::OpenRouter`, weil Command Code dieselbe
TypeSafe-Shape spricht — der vorhandene Parser
(`parse_response`, Test `parses_openrouter_answers`) passt unverändert.

### 12. HTML-Sanitizer behält `<style>` und `class` (`mime/mod.rs`, `SANITIZER`)

Die Allee-Theater-Auftragsbestätigung (Mail-ID 32, 16.11.2026) kam als
unformatierter Fließtext an. Ursache war der Sanitizer, nicht der Parser:

- Ammonia hat `clean_content_tags = ["script", "style"]` als Default und
  verwirft damit den **kompletten Inhalt** eines `<style>`-Blocks.
- `class` war kein generisches Attribut; nur `div` hatte über
  `add_allowed_classes("div", ["co-signature"])` eine Erlaubnis, und die
  filterte alle anderen Klassen weg (`class=""`).

Die Mail stylt ihren ganzen Body über einen 1705-Zeichen-`<style>`-Block und
23 Klassen (`.confirmation{width:660px}`, `.head1`, `.totalamount`, …). Ohne
beides bleibt nur der nackte Text.

Fix: `class` als generisches Attribut, `style` in `add_tags`, und
`clean_content_tags` auf `["script", "title"]` gesetzt (damit fällt `style`
heraus). `add_allowed_classes` für `div` entfällt — Ammonia verbietet ohnehin
die Kombination aus `allowed_classes` und `class` als generischem Attribut
(`assert!` in `Builder::clean`).

Zusätzlich: `<title>` ist Metadaten, kein Body-Text. Ammonia entfernt das Tag,
behielt aber den Text — die Betreffzeile erschien als Absatz über der Mail.
`title` steht deshalb jetzt in `clean_content_tags`.

**Sicherheitsgrenze ist die iframe-CSP, nicht der Sanitizer.** Ammonia kann
keine ganzen Stylesheets filtern (nur `style`-Attribute). Der Mail-Body läuft
in einem scriptlosen `<iframe sandbox="allow-same-origin">` mit
`default-src 'none'; style-src 'unsafe-inline'`. Damit sind `@import`,
`url()`-Fetches und Font-Loads blockiert; das CSS kann ausschließlich die Mail
selbst umgestalten. Remote-Bilder bleiben an die Einstellung gebunden.

Wirkung: 2669 → 4659 Bytes für Mail 32, `<style>` und alle 23 Klassen erhalten,
jede verwendete Klasse hat eine Regel im Stylesheet.

**Migration:** Der Sanitizer läuft nur beim Abruf. Bereits gecachte Bodies
behalten das alte HTML. Einmalig zurückgesetzt wurden die 234 Bodies mit
`class=""` **und** ohne `style="` — die, die sich allein auf Klassen stützten
(Allee Theater, Apple-Rechnungen). Sie wurden neu geladen.

### 13. QP-Heuristik präzisiert (`mime/mod.rs`, `qp_artifact_count`)

`looks_like_undecoded_quoted_printable` zählte jedes `=XX` und schlug ab acht
Treffern an. Das traf bei jedem Start ~1100 korrekt dekodierte Bodies, die
dann neu geladen wurden. Die Treffer waren ausnahmslos Fehlalarme:

| Quelle | Beispiel |
|---|---|
| URL-Query | `?g=875f3f54`, `&H=A6`, `savedSearchId=84` |
| URL-Parameter mit Hex-Wert | `midSig=3D`, `MSG_TITLE=81` |
| RFC-2047-Encoded-Word | `=?UTF-8?Q?Ihr_n=C3=A4chster_Urlaub?=` |
| Base64-Zeilenende | `…qW38c=` |
| Umbrochenes HTML-Attribut | `<a href=\n"https://…">` |
| ASCII-Trenner | `=============` |

Neu zählen nur zwei Formen, die QP erzeugt und sonst nichts:

1. `=3D` **direkt vor einem Anführungszeichen** — ein QP-Encoder schreibt jedes
   `=` eines HTML-Attributs als `=3D`, also `href=3D"…"`.
2. Ein Lauf von **zwei oder mehr** Escapes, der gültiges UTF-8 ergibt
   (`M=C3=BCnchen`), außerhalb eines Encoded-Words.

Schwelle bleibt 2. Gemessen an 11014 Bodies: alte Heuristik 1395 Treffer,
neue 0. Gegenprobe mit der echten QP-kodierten Allee-Mail: 178 Marker kodiert,
0 dekodiert.

**Fallstrick, der beim ersten Einbau übersehen wurde:** der Lauf-Scanner muss an
*jeder* Position prüfen, dass dort ein `=` steht. Ohne diese Prüfung wurden die
Bytes hinter einem einzelnen Escape als weitere Escapes gelesen (`=3D` + `20` +
`22` → `= `), was 1111 Bodies erneut requeute. Regressionstest:
`qp_heuristic_ignores_hex_after_a_single_escape`.

### 14. Identitäts-Fetch: doppeltes Leerzeichen (`imap/identity.rs`, `fetch_identities`)

`fetch_identities` baute seine FETCH-Query mit `format!` und der
Provider-Item-Liste dazwischen. Auf iCloud ist diese Liste leer, also stand
dort `RFC822.SIZE  BODY.PEEK[...]` — **zwei Leerzeichen**. iCloud lehnt das
ab, und weil der Fehler als leere Antwort durchging, kam **jede**
Identitätsliste leer zurück. Zwei Folgen:

1. Der Trash-Reconciler (`trash/reconcile.rs`) sah `identities=0` und
   `complete=false`, adoptierte also nie die uid-losen Zeilen. 12 Mails lagen
   im Papierkorb ohne UID, obwohl der Server-Move längst gelaufen war.
2. Nach einem Move konnte `move_action` die Ziel-UID nicht ermitteln
   (`verify_key` und `search_key` benutzen beide `fetch_identities`), also
   blieb die Zeile dauerhaft `uid NULL`.

Fix: Item-Liste aus nicht-leeren Teilen zusammenbauen — dieselbe Falle, die
`fetch_headers_inner` schon dokumentiert. Der Test-Helfer `header_fetch(false)`
hatte die kaputte Query als Erwartung kodiert und wurde mitkorrigiert;
Regressionstest `identity_fetch_query_stays_well_formed_without_provider_items`.

Verifiziert 2026-11-17: Listing `identities=484 complete=true`, alle 12
uid-losen Zeilen haben ihre UID (2539–2550).

### 15. Büroklammer aus dem Header-Fetch (`imap/mod.rs`, `attach_mime_plans`)

Der Header-Fetch holte bewusst kein BODYSTRUCTURE (siehe Punkt 1), also
erschien das Anhang-Symbol erst, wenn der Body im Cache lag. Jetzt folgt dem
Header-Fetch ein **zweiter** FETCH nur mit `(UID BODYSTRUCTURE)`; daraus
kommen `has_attachments` und der MIME-Plan direkt beim Insert.

Bewusst getrennt und nicht kombiniert: die Kombination von BODYSTRUCTURE und
`BODY[HEADER.FIELDS]` in einer Antwort ist genau das, was die iCloud-Session
desynchronisiert hat. Der separate Pfad ist im Body-Fetch bereits erprobt.
Ein Fehler dort kostet nur die Büroklammer, nie den Header-Batch.

## Bauen und starten

```bash
cd "Projekte/comail.nosync"

sh scripts/build-local-app.sh   # → /Applications/Rabe.app
sh scripts/build-dev-app.sh     # → Rabe Dev.app, danach nach /Applications kopieren
pnpm dev:isolated               # Hot-Reload-Dev-Instanz
```

Voraussetzungen: eine gültige Codesigning-Identität. Bevorzugt wird eine echte
`Apple Development`-Identität (stabile Team-ID → stabile Keychain-Partition-ID,
siehe Punkt 10). Fehlt sie, fällt das Skript auf `comail-dev` zurück; das legt
`bash src-tauri/scripts/macos-dev-cert.sh` einmalig an. Dieses Skript braucht
`openssl pkcs12 -legacy`; ohne das Flag scheitert `security import` mit
„MAC verification failed" (Homebrew-OpenSSL 3+/4.x).

## Verifikation

Der verlässlichste Abgleich läuft über das Backup, **nicht** über Zähler pro
Ordner: die App dedupliziert über Message-IDs, das Backup zählt pro Ordner.
Eine Mail, die in INBOX und in einem Label-Ordner liegt, ist in der App eine
Zeile.

```bash
# Backup (rein lesend, SELECT readonly + BODY.PEEK[])
python3 scripts/imap-backup.py <zielverzeichnis> --user <adresse>

# Abgleich: Message-IDs normalisieren (spitze Klammern entfernen, lowercase)
# und die Mengen differenzieren. Erwartung: "nur im Backup: 0".
```

Letzter Stand: Backup 11744 Dateien / 11011 eindeutige Message-IDs,
App 11012 eindeutige, **0 fehlend**.

## Offene Punkte

1. **Embeddings laufen noch** (~2300 von 11016, ~300/Minute). Sobald die
   Bodies durch sind, zieht der Embedder nach.
2. **Büroklammer** (Punkt 15) ist gebaut und getestet, aber noch nicht mit
   einer echten neuen Mail mit Anhang verifiziert.
3. **MCP ist aus** in beiden Instanzen (`mcpEnabled: false`, Port 47823). Für
   Agenten-Zugriff in den Settings aktivieren; bei parallelem Betrieb braucht
   die zweite Instanz einen anderen Port.
4. **Keychain nach der Umbenennung** (2026-11-18): Mit dem Wechsel auf den
   Identifier `de.streil.rabe.dev` wandert der Keyring-Service. `credentials::load`
   übernimmt einen vorhandenen Eintrag aus dem alten Service
   (`com.deanoss.comail.dev`) beim ersten Lesen automatisch und legt ihn unter
   dem neuen Namen ab; die alte Kopie bleibt liegen und wird nicht mehr gelesen.
   Die Release-Instanz ist nicht betroffen, ihr Service ist die feste Konstante
   `comail`. Belegt: nach dem Umzug „receive: connected; IDLE push enabled" ohne
   Umgebungsvariable, Eintrag `1:password` unter `de.streil.rabe.dev`.
   Grund für die Migration: `Bearbeiten` im Konto kennt kein Passwortfeld, und
   `reauth_account` ist reiner OAuth-Flow — für IMAP-Konten gab es keinen Weg,
   ein Passwort neu zu hinterlegen. Offene Lücke: ein eigenes „Passwort ändern"
   für IMAP-Konten fehlt weiterhin.

## Fallstricke

- **iCloud + async-imap**: kombinierte FETCH-Requests und doppelte Leerzeichen
  in der Item-Liste führen zu Antworten, die der Parser nicht verarbeitet. Eine
  teilweise konsumierte Antwort desynchronisiert die Session dauerhaft. Nach
  einem Parse-Fehler darf eine Session **nie** weiterbenutzt werden. Seit dem
  Upgrade auf imap-proto 0.17 (Punkt 8) sind die beiden bekannten
  Parser-Lücken geschlossen; die Session-Regel gilt trotzdem weiter.
- iCloud verteilt Anfragen auf verschiedene Backend-Knoten
  (`p00-iscream-20/60/100-percent-…`), die sich unterschiedlich tolerant
  verhalten — Fehler wirken dadurch sporadisch.
- Kein volles Xcode auf dieser Maschine: Siri-Intents und `actool`
  (`Assets.car`) fehlen, das `.icns` wird trotzdem benutzt.
- `package.json` verlangt pnpm 11.11.0; pnpm lädt die Version bei Bedarf selbst
  nach. In nicht-interaktiven Shells ggf. `CI=true` setzen.
- `.nosync` im Ordnernamen hält den Ordner aus iCloud **und** Syncthing heraus.
