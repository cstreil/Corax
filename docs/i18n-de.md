# Deutsche Übersetzung — Arbeitsauftrag

Ziel: Comail vollständig auf Deutsch. `en` ist die Quelle, `de` ist übersetzt.
Die wenigen Werte, die bewusst englisch bleiben (Produktnamen, Adressen,
Formate, Suchsyntax), stehen als Liste im Paritätstest — alles andere muss
übersetzt sein.

## Dateien

```
src/i18n/locales/en/*.json     Quelle — nicht anfassen
src/i18n/locales/de/*.json     Ziel — hier wird gearbeitet
src/i18n/index.ts              lädt Locales automatisch, nichts zu ändern
scripts/i18n-status.mjs        Fortschritt
src/i18n/localeParity.test.ts  Struktur-/Platzhalter-Test
```

Der `de`-Ordner ist eine 1:1-Kopie von `en`. **Schlüssel, Reihenfolge und
Verschachtelung bleiben unverändert**, geändert werden nur die Textwerte.
UTF-8, zwei Leerzeichen Einrückung, gültiges JSON.

## Umfang

1833 Textwerte in 9 Dateien:

| Datei | Werte |
|---|---|
| settings.json | 779 |
| common.json | 274 |
| onboarding.json | 240 |
| thread.json | 135 |
| commands.json | 126 |
| calendar.json | 123 |
| compose.json | 103 |
| inbox.json | 27 |
| errors.json | 26 |

## Harte Regeln

1. **Platzhalter unverändert**: `{{count}}`, `{{name}}`, `{{email}}` usw. bleiben
   Zeichen für Zeichen stehen, dürfen aber innerhalb des Satzes verschoben
   werden (deutsche Wortstellung).
2. **Inline-Tags unverändert**: `<b>…</b>`, `<code>…</code>`, `<kbd>…</kbd>` —
   gleiche Tags, gleiche Anzahl, nur der Text dazwischen wird übersetzt.
3. **Plural**: Schlüssel mit `_one` = genau 1, `_other` = 0 und ab 2. Deutsch hat
   wie Englisch nur diese beiden Formen. Beide Varianten müssen sich natürlich
   lesen, `{{count}}` bleibt enthalten.
4. **Demo-Daten in `onboarding.preview`**: Das ist ein Objekt mit Beispieldaten
   für die Vorschau, kein Fließtext. Übersetzen: `title`, `tabs[].name`,
   `paletteItems[].title`/`section`, `labels.*`, `rows[].subject`, `rows[].snippet`,
   `replyText`, `today`, `doneToast`, `undo`, `palettePlaceholder` sowie die
   Wochentagskürzel in `rows[].time` (`SAT` → `SA`). `time` ist Anzeigetext:
   Uhrzeiten (`09:41`) bleiben, Wochentage werden übersetzt.
   **Nicht übersetzen**: Personennamen (`from`), `group`, `key`, `count`,
   `unread`, `labels`-Verweise in `rows[]`.
5. **Keine Strukturänderung**: keine Keys hinzufügen, löschen, umbenennen,
   verschieben oder Arrays kürzen.
6. **Keine leeren Werte**. Ist ein Text im Deutschen identisch („Comail", „IMAP",
   „Status"), bleibt er stehen — aber nur, wenn der Schlüssel in
   `UNTRANSLATED_BY_DESIGN` (`src/i18n/localeParity.test.ts`) aufgeführt ist. Ein
   neuer englischer Wert lässt den Test rot werden, statt still ausgeliefert zu
   werden.

## Terminologie

Ein Begriff pro Sache, in allen Dateien gleich:

| Englisch | Deutsch |
|---|---|
| conversation / thread | Unterhaltung |
| split inbox | Geteilte Inbox |
| tab (einer Inbox) | Tab |
| Important / Other | Wichtig / Sonstige |
| label | Label |
| folder | Ordner |
| snooze | Zurückstellen |
| archive (Verb) | archivieren |
| done | erledigt |
| draft | Entwurf |
| starred | markiert |
| attachment | Anhang |
| compose | verfassen |
| reply / reply all | antworten / allen antworten |
| forward | weiterleiten |
| undo | rückgängig |
| command palette | Befehlspalette |
| shortcut | Tastenkürzel |
| snippet | Textbaustein |
| sender / recipient | Absender / Empfänger |
| account | Konto |
| settings | Einstellungen |
| decision model | Entscheidungsmodell |
| automation | Automatisierung |
| search | Suche |
| split (Regel) | Aufteilung |
| AI | KI |
| tier | Stufe |
| provider | Anbieter |
| backup (Anbieter) | Ersatz |
| theme | Design |
| attendee | Teilnehmende |
| unsubscribe | Abbestellen |
| message | Nachricht |
| mail | E-Mail / E-Mails |
| confidence | Konfidenz |
| auto (Badge) | Automatisch |

Marken und Protokolle bleiben: Comail, IMAP, SMTP, Gmail, iCloud, Google,
Microsoft, Outlook, CalDAV, OAuth. „Email" wird zu „E-Mail" (mit Bindestrich).

## Stil

- **Anrede: „du"** — vom Nutzer bestätigt (2026-11-18). Possessiv: „dein
  Posteingang", nie „Sie/Ihr".
- Sachlich, knapp, keine Floskeln. Imperativ für Aktionen („Archivieren",
  „Weiterleiten"), nicht „Du kannst …".
- Die englischen Texte sind kurz. Deutsch ist ~30 % länger: Bei Buttons, Tabs und
  Fehlermeldungen die Länge im Blick behalten, lieber kürzer formulieren.
- Fehlermeldungen: nennen, was schiefging, und wenn möglich den nächsten Schritt.
  Keine Übersetzung von Platzhaltern wie `{{error}}` — der bleibt.
- Keine geschlechtsspezifischen Konstruktionen erzwingen; wo es geht, neutrale
  Formulierungen („Person", „Kontakt") statt „Benutzer:in".

## Arbeitsreihenfolge

Nach Umfang, damit früh sichtbarer Fortschritt entsteht:

1. `settings.json` (779)
2. `common.json` (274)
3. `onboarding.json` (240)
4. `thread.json` (135)
5. `commands.json` (126)
6. `calendar.json` (123)
7. `compose.json` (103)
8. `inbox.json` (27)
9. `errors.json` (26)

Nach jeder Datei prüfen:

```sh
node scripts/i18n-status.mjs de
pnpm exec vitest run src/i18n/localeParity.test.ts
```

Fortschritt der aktuellen Datei auflisten:

```sh
node scripts/i18n-status.mjs de --missing
```

## Abnahme

- `node scripts/i18n-status.mjs de` zeigt **1704/1833**. Die 129 restlichen Werte
  stehen in `UNTRANSLATED_BY_DESIGN` (`src/i18n/localeParity.test.ts`):
  Produktnamen, Adressen, Formate, Suchsyntax und Demo-Zeilen.
- `pnpm exec vitest run src/i18n/localeParity.test.ts` grün: Struktur,
  Platzhalter, Tags, leere Werte und „kein unbemerktes Englisch".
- `pnpm typecheck` und `pnpm test` grün
- Sichtprüfung in der App: `sh scripts/build-dev-app.sh`, installieren,
  Einstellungen → Sprache → Deutsch; die engen Stellen (Tab-Leiste,
  Befehlspalette, Einstellungszeilen, Toolbar-Buttons) auf Überlauf prüfen

## Bewusst englisch

- Beispiele für natürliche Zeitangaben (`common:timePopover.placeholder`,
  `calendar:create.quickPlaceholder`): `src/lib/snooze.ts` parst nur englische
  Schlüsselwörter. Ein deutsches Beispiel („morgen") würde nicht funktionieren —
  englisch bleibt, bis es eine Keyword-Tabelle pro Sprache gibt.
- Suchoperatoren (`common:search.ops.*`, `search.values.*`) sind Syntax.
- `compose:replyPrefix` / `forwardPrefix` bleiben `Re:` / `Fwd:`, damit die
  Betreff-Erkennung greift.
- `compose:sendingIn` enthält `{s}` mit einfachen Klammern; `Toasts.tsx` ersetzt
  das im Countdown. Nicht in `{{s}}` umwandeln.

## Nicht Teil des Auftrags

- Code ändern (außer einer bewusst vereinbarten Korrektur an der Quelle)
- `en` oder andere Locales ändern
- Formatierung/Reihenfolge der JSON-Dateien ändern
- Neue Features oder Texte, die es im Englischen nicht gibt
