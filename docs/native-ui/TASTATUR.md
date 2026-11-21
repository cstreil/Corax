# Rabe native — Tastaturbelegung

Stand 2026-11-20 · Vom Nutzer abgenommen (M2.14) · Gilt für macOS und später Linux.
Quelle ist die Tabelle `ShortcutMap` in `RabeKit/Support/ShortcutMap.swift`; ein Test prüft, dass jede Zeile hier wörtlich vorkommt.

Zwei Schichten:

- **Einzeltasten** sind schneller, wirken aber nur, wenn kein Textfeld den Fokus hat. Einstellungen → Allgemein → „Einzeltasten-Kürzel" schaltet sie ab (Standard: an).
- **Menü-Kombis** (⌘ usw.) stehen im Menü und gelten immer, auch im Textfeld.
- Erkannt wird das **Zeichen**, nicht die Taste: `/ ? # ! + -` funktionieren auch auf der deutschen Tastatur.
- Kontexte sind strikt getrennt: In der Liste wirken keine Thread-Tasten, im Kalender keine Mail-Tasten.

## Liste

| Aktion | Einzeltaste | Kombi |
|---|---|---|
| nächster / voriger Thread | `J` / `K` | `↓` / `↑` |
| Seite weiter / zurück | — | `Bild↓` / `Bild↑` |
| erster / letzter Thread | — | `Pos1` / `Ende` |
| Thread aufklappen | `O` | `↵` |
| Auswahl erweitern | — | `⇧↓` / `⇧↑` |
| alles auswählen / aufheben | `A` | `⌘A` |
| Zeile zur Auswahl | `X` | `⌘-Klick` |
| Split wechseln | `Tab` / `⇧Tab` | `⌃Tab` / `⌃⇧Tab` |
| direkt zu Split n | — | `⌥⌘1…9` |

## Liste und offener Thread

| Aktion | Einzeltaste | Kombi |
|---|---|---|
| Erledigt | `E` | `⌃⌘A` |
| zurück in den Posteingang | `⇧E` | `⇧⌃⌘A` |
| Papierkorb | `#` | `⌫` / `⌘⌫` |
| Später (morgen 8:00) | `H` | `⌃⌘H` |
| Stern | `S` | `⇧⌘L` |
| gelesen / ungelesen | `U` | `⇧⌘U` |
| Spam / kein Spam | `!` | `⇧⌘J` |
| Rückgängig | `Z` | `⌘Z` |
| Verschieben … | `V` | `⌃⌘M` |
| Label … | `L` | `⌃⌘L` |
| Newsletter abmelden | — | `⌃⌘U` |
| Antworten | `R` | `⌘R` |
| Allen antworten | `⇧R` | `⇧⌘R` |
| Weiterleiten | `F` | `⇧⌘F` |

## Offener Thread

| Aktion | Einzeltaste | Kombi |
|---|---|---|
| in der Nachricht weiter / zurück | `J` / `K` | `↓` / `↑` |
| seitenweise | `Space` / `⇧Space` | `Bild↓` / `Bild↑` |
| erste / letzte Nachricht | — | `Pos1` / `Ende` |
| zuklappen | — | `↵` / `Esc` |
| ersten Anhang öffnen | `O` | `⌘↓` |
| Quick Look | `Y` | `⌘Y` |
| Bilder laden | — | `⇧⌘I` |

## Überall

| Aktion | Einzeltaste | Kombi |
|---|---|---|
| Neue Mail | `C` | `⌘N` |
| Jetzt synchronisieren | — | `⇧⌘N` |
| Bestätigungscode kopieren | — | `⌥⇧⌘C` |
| Gehe zu Postfach I S D T E H # ! A | `G` | `⌘1…⌘9` |
| Gehe zu Ordner/Label … (G O) | — | `⇧⌘O` |
| Konto 1…9 / alle | — | `⌃1…⌃9` / `⌃0` |
| Seitenleiste | `\` | `⌃⌘S` |
| Suche | `/` | `⌥⌘F` / `⌘F` |
| Befehlspalette | — | `⌘K` |
| Kürzelhilfe | `?` | `⌘/` |
| Einstellungen · Leistung · Beenden | — | `⌘,` / `⌥⌘P` / `⌘Q` |

### Die `G`-Folge

`G` allein öffnet nichts. Sofort nach dem Druck zeigt die Statuszeile „Gehe zu: I Posteingang · S Markiert · D Entwürfe · T Gesendet · E Erledigt · H Später · # Papierkorb · ! Spam · A Alle · O Ordner/Label …“, und **2 Sekunden** lang wartet die App auf die zweite Taste; `Esc` bricht ab. Rechts in der Seitenleiste steht die Folge blass an jeder Zeile („G I“, „G S“ …), der Ungelesen-Zähler davor.

## KI

| Aktion | Einzeltaste | Kombi |
|---|---|---|
| Zusammenfassen / mit KI schreiben | `I` | `⌥⌘I` |
| Fragen an das Postfach | `⇧I` | `⇧⌥⌘I` |
| Korrekturlesen (im Entwurf) | — | `⌥⌘;` |
| KI-Filter (in der Suche) | — | `⌥⌘K` |

## Entwurf

| Aktion | Einzeltaste | Kombi |
|---|---|---|
| Senden | — | `⇧⌘D` / `⌘↵` |
| Senden und erledigen | — | `⌥⇧⌘D` / `⌘⇧↵` |
| Später senden … | — | `⌃⌘D` |
| Sofort senden | — | `⌃⌥⌘D` |
| Anhängen … | — | `⇧⌘A` |
| Textbaustein … | — | `⌃⌘K` |
| verwerfen (im Thread) | — | `⇧⌘⌫` |

## Verfassen-Panel

| Aktion | Einzeltaste | Kombi |
|---|---|---|
| minimieren | — | `Esc` |
| verwerfen | — | `⇧⌘⌫` |
| minimieren / wiederherstellen | — | `⇧⌘M` |
| Fokus reihum Liste ↔ Entwürfe | — | `⌃Tab` |

## Editor

| Aktion | Einzeltaste | Kombi |
|---|---|---|
| fett · kursiv · unterstrichen · durchgestrichen | — | `⌘B` / `⌘I` / `⌘U` / `⇧⌘X` |
| nummerierte Liste · Aufzählung · Zitat | — | `⇧⌘7` / `⇧⌘8` / `⌘'` |
| Link · Formatierung entfernen · Kontakt | — | `⌘K` / `⌘\` / `@` |

## Kalender

| Aktion | Einzeltaste | Kombi |
|---|---|---|
| Kalender öffnen / zurück zur Post | — | `⌥⌘2` / `⌥⌘1` |
| Tag / Woche / Monat | `D` / `W` / `M` | `⌘1` / `⌘2` / `⌘3` |
| Jahr | `Y` | `⌘4` |
| Terminliste | `L` | `⌘5` |
| Heute | `T` | `⌘T` |
| zurück / weiter blättern | `-` / `+` / `=` | `⌘←` / `⌘→` |
| Neuer Termin | `B` | `⌘N` |
| voriger / nächster Termin | `Tab` / `⇧Tab` | `↑` / `↓` |
| Termin aufklappen / zuklappen | — | `↵` |
| Termin bearbeiten | — | `⌘E` |
| Termin sichern (im Titelfeld ↵) | — | `⌘↵` |
| schrittweise zurück | — | `Esc` |
| Meeting beitreten | `O` | `⌘O` |
| Termin löschen | — | `⌫` |

## Hinweise

- `⌘N` heißt je nach Modus „Neue Mail" (Liste) oder „Neuer Termin" (Kalender); der Menüpunkt verzweigt nach Modus.
- `⌘1…⌘3` sind im Kalender Tag/Woche/Monat, `⌘1…⌘9` in der Liste die Postfächer.
- `⌘K` öffnet die Befehlspalette, im Editor das Link-Feld.
- `⌘J` ist entfallen; „Zusammenfassen / mit KI schreiben" liegt auf `I` und `⌥⌘I`.
- Markierter Text beim Antworten mit `R` oder `⇧R` wird zitiert (ersetzt „Mit Auswahl zitieren").
- `G` öffnet ein Zeitfenster von 1,2 s: `I` Posteingang, `S` Markiert, `D` Entwürfe, `T` Gesendet, `E` Erledigt, `H` Zurückgestellt, `#` Papierkorb, `!` Spam, `A` Alle.
