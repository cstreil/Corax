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
| `Esc` | ohne Entwurf: Thread zuklappen |
| `E` · `#` / `⌫` · `H` · `S` · `U` · `Z` | wirken auf den Thread (danach Zustand A, Auswahl auf dem nächsten Thread) |

## Im Entwurf (Textfeld hat Fokus)

| Taste | Aktion |
|---|---|
| `⌘↵` | senden (mit Undo-Send) |
| `Esc` | Entwurf sofort verwerfen (`delete_draft`), Fokus zurück auf die Nachricht; Toast „Entwurf verworfen · Rückgängig“ stellt Inhalt und Entwurf wieder her. Keine Rückfrage. |

## Änderungen gegenüber Tauri-Rabe

- `a` öffnete dort in einer Unterhaltung den Anhang; jetzt `A` = antworten, Anhang = `O` (nur Zustand B).
- `↵` klappt auf und zu, statt nur zu öffnen; `Esc` verwirft im Entwurf statt zu schließen.
