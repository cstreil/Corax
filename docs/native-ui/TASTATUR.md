# Rabe native — Tastaturbelegung

Stand 2026-11-19 · Festgelegt vom Nutzer · Gilt für macOS und später Linux (Skins KDE und Omarchy).
**Verbindlich festgelegt** sind Navigation (Pfeile, Bild↑/↓, Pos1/Ende), `↵`, `A`/`⇧A`/`W`, `O` und `Esc`. Alle übrigen Belegungen (`E`, `#`, `H`, `S`, `U`, `Z`, `C`, `/`, `?`, `Tab`, Zweitbelegungen) sind **vorläufig** aus dem Mockup übernommen. Der Nutzer legt sie später fest.
Einzeltasten wirken nur, wenn kein Textfeld den Fokus hat. Modifizierte Kürzel (`⌘K`, `⌘↵`, `⌘,` …) gelten überall.

## Zustand A — Liste (kein Thread aufgeklappt)

| Taste | Aktion |
|---|---|
| `↓` / `↑` (auch `J` / `K`) | nächster / vorheriger Thread |
| `Bild↓` / `Bild↑` | eine sichtbare Seite weiter / zurück; die Auswahl wandert mit (gleiche Position im Fenster, sonst erste bzw. letzte sichtbare Zeile) |
| `Pos1` / `Ende` | erster / letzter Thread der Ansicht (`Ende` lädt bei Bedarf alle Seiten nach) |
| `↵` (auch `O`, `Space`) | ausgewählten Thread aufklappen |
| `E` · `#` / `⌫` · `H` · `S` · `U` · `Z` | Erledigt · Papierkorb · Später · Stern · Ungelesen · Rückgängig |
| `A` / `⇧A` / `W` (auch `R` / `⇧R` / `F`) | antworten / allen antworten / weiterleiten auf die letzte Nachricht des Threads (klappt dabei auf) |
| `C` · `/` · `?` · `Tab` / `⇧Tab` | Neue Mail · Suche · Tastenkürzel · Tab wechseln |
| `⇧↓` / `⇧↑` | Auswahl vom Anker bis zur nächsten Zeile erweitern / verkleinern |
| `⌘A` | alle geladenen Threads auswählen; nochmal drücken hebt auf die Cursor-Zeile auf |
| `⌘`-Klick | eine Zeile zur Auswahl hinzufügen oder herausnehmen |
| `⇧`-Klick | Bereich vom Anker bis zur geklickten Zeile auswählen |
| `V` · `L` | Verschieben-Popover · Label-Popover (Tippsuche, `↑`/`↓`, `↵`, `Esc`) |
| `⇧E` | aus „Erledigt“ zurück in den Posteingang |
| `!` | als Spam markieren (im Spam-Ordner: kein Spam) |
| `#` | im Papierkorb endgültig löschen — erst nach dem Bestätigungsdialog |
| `G`, dann `I` · `S` · `D` · `T` · `E` · `H` · `#` · `!` · `A` | Posteingang · Markiert · Entwürfe · Gesendet · Erledigt · Zurückgestellt · Papierkorb · Spam · Alle E-Mails (1,2 s Zeitfenster) |

`⌘U` (Abmelden) fragt vorher nach: der Kern meldet per POST oder Mail ab, und das lässt sich nicht zurücknehmen. `U` allein markiert nur ungelesen.

## Zustand B — Thread aufgeklappt

Im Thread gibt es immer eine **fokussierte Nachricht** (beim Aufklappen: die neueste ungelesene, sonst die letzte). Sie ist dezent markiert wie das bisherige Antwortziel. Antworten und Weiterleiten beziehen sich auf sie.

| Taste | Aktion |
|---|---|
| `↓` | Ist das untere Ende der fokussierten Nachricht noch nicht sichtbar: Liste um eine Scrollschritt-Höhe (≈ 3 Zeilen) nach unten scrollen. Sonst: Fokus auf die nächste Nachricht im Thread, deren Anfang einblenden. Nach der letzten Nachricht passiert nichts (kein Wechsel zum nächsten Thread der Liste). |
| `↑` | spiegelbildlich: nach oben scrollen, bis der Anfang der fokussierten Nachricht sichtbar ist, dann Fokus auf die vorige Nachricht und deren Ende einblenden; an der ersten Nachricht ist Schluss. |
| `J` / `K` | wie `↓` / `↑` |
| `Bild↓` / `Bild↑` | seitenweise innerhalb der Nachricht, gleiche Grenzlogik wie `↓` / `↑` |
| `Pos1` / `Ende` | erste / letzte Nachricht im Thread fokussieren und einblenden |
| `↵` | Thread zuklappen (Auswahl bleibt auf dem Thread) |
| `A` / `⇧A` / `W` (auch `R` / `⇧R` / `F`) | antworten / allen antworten / weiterleiten auf die fokussierte Nachricht → Inline-Entwurf mit Fokus im Textfeld |
| `O` | ersten Anhang der fokussierten Nachricht öffnen (über `open_attachment`) |
| `Space` | Anhänge der fokussierten Nachricht in der Quick-Look-Vorschau öffnen; `←`/`→` blättert, `Esc` schließt |
| `⇧R` | markierten Text aus der Mail als Zitat in die Antwort übernehmen; ohne Markierung wie in Tauri „allen antworten“ |
| `Esc` | ohne Entwurf: Thread zuklappen |
| `E` · `#` / `⌫` · `H` · `S` · `U` · `Z` | wirken auf den Thread (danach Zustand A, Auswahl auf dem nächsten Thread) |

## Im Entwurf (Textfeld hat Fokus)

| Taste | Aktion |
|---|---|
| `⌘↵` | senden (mit Undo-Send) |
| `⌘⇧↵` | senden und erledigen (der beantwortete Thread wandert nach „Erledigt“) |
| `⌘⇧L` | Später senden: Zeitwahl („morgen 9:00“, „in 2 stunden“, „30m“, Vorgaben) → `queue_send` mit `sendAt` |
| `⌘⇧Z` | sofort senden, ohne Undo-Fenster (`queue_send` mit `sendAt = jetzt`) |
| `⌘⇧A` | Dateien anhängen (auch per Drag & Drop auf das Fenster) |
| `⌘;` | Textbaustein einfügen (Tippsuche über die Bausteine aus den Einstellungen) |
| `Esc` | offenes Popup schließen (Link-Feld, `@`-Liste); ohne Popup den Entwurf sofort verwerfen (`delete_draft`), Fokus zurück auf die Nachricht; Toast „Entwurf verworfen · Rückgängig“ stellt Inhalt und Entwurf wieder her. Keine Rückfrage. |

## Im Entwurf: Formatierung (M2.6, `NSTextView` statt Textfeld)

| Taste | Aktion |
|---|---|
| `⌘B` / `⌘I` / `⌘U` | fett / kursiv / unterstrichen (am Cursor = für den nächsten Text) |
| `⌘⇧X` | durchgestrichen |
| `⌘⇧7` / `⌘⇧8` | nummerierte Liste / Aufzählung (`↵` setzt fort, `Tab` rückt ein, `⇧Tab` hebt auf) |
| `⌘⇧9` | Zitat (`blockquote`) |
| `⌘K` | Link-Feld: Eingabe wird zu `https://…`, E-Mail zu `mailto:…`, leer entfernt den Link |
| `⌘\` | Formatierung entfernen (ohne Auswahl: der ganze Körper; Links, Bilder und `@`-Namen bleiben) |
| `@` | Vorschlagsliste der Kontakte, `↑`/`↓`/`↵` wählen, `Esc` schließt; die Wahl setzt den Namen als Chip und den Empfänger nach „An“ |
| `Bild einfügen` | Knopf in der Formatleiste; Bilder auch per `⌘V` und Drag & Drop, eingebettet als `data:`-URL (höchstens 1400 px und 2 MB) |

## Änderungen gegenüber Tauri-Rabe

- `a` öffnete dort in einer Unterhaltung den Anhang; jetzt `A` = antworten, Anhang = `O` (nur Zustand B).
- `↵` klappt auf und zu, statt nur zu öffnen; `Esc` verwirft im Entwurf statt zu schließen.
- **M2.5 — Mehrfachauswahl:** Tauri lässt eine Auswahl über `↓`/`↑` stehen, hier fällt sie auf die Cursor-Zeile zurück. Grund: die W3-Regel („nie auf einen Thread wirken, den der Benutzer nicht gerade ausgewählt hat“) bleibt so auch nach dem Weiterbewegen sichtbar. Die letzte gewählte Zeile lässt sich nicht abwählen; `⌘A` mit voller Auswahl fällt darauf zurück statt auf „nichts ausgewählt“.
- **M2.5 — Zitat:** markierter Text wird aus dem HTML-Body gelesen (WKWebView-Auswahl). Bei reinen Text-Mails gibt SwiftUI die Auswahl nicht her; `⇧R` fällt dort wie in Tauri auf „allen antworten“ zurück (Log: `quote_selection empty fallback=reply_all`).
- **M2.5 — Textbausteine:** `use_snippet` (Nutzungszähler des Kerns) wird nicht aufgerufen; der Text wird lokal eingefügt.
- **M2.5 — Anhänge:** beim Antworten/Weiterleiten werden die Anhänge der Ausgangsmail nicht automatisch angeboten (Tauri fragt das beim Weiterleiten); angehängt wird über Dialog, Drag & Drop oder der Hook.
- **M2.6 — Format-Kürzel:** `⌘K` gehört im Entwurf dem Link-Feld (Tauri öffnet dort die Befehlspalette erst außerhalb des Editors); `⌘\` entspricht Tauris „Formatierung entfernen“.
- **M2.6 — Zitat beim Antworten:** das Original steht als `blockquote` im Entwurf (Text → Signatur → Zitat, wie bei Apple Mail). Tauri hält es getrennt und klappt es hinter „⋯“ ein; hier ist es sichtbar und mitbearbeitbar.
- **M2.6 — `@`-Erwähnung:** der Chip trägt die E-Mail als `span.co-mention` (wie Tauri); der Empfänger wird zusätzlich nach „An“ gesetzt. Quelle ist `suggest_contacts` (dieselbe Suche wie im Empfängerfeld) statt `list_contacts`.
