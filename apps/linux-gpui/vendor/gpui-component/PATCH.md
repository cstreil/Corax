# Gepatchte Kopie: gpui-component 0.5.1

Herkunft: crates.io, `gpui-component` 0.5.1 (veröffentlicht am 05.02.2026).
SHA-256 des Original-Archivs (`gpui-component-0.5.1.crate`):

```
d021d46b4088d3d93a57ccdf443da85695a77272108caca2f6fe5369f584966a
```

Lizenz: **Apache-2.0** (`LICENSE-APACHE` liegt bei, unverändert). Die Lizenz ist
mit unserem AGPL-3.0 vereinbar, einschließlich der Patentlizenz.

Kopie eingebunden über `[patch.crates-io]` in `apps/linux-gpui/Cargo.toml`;
die Abhängigkeit bleibt `gpui-component = "=0.5.1"`.

## Warum gepatcht

`Input` zeigt reinen Text: gpui-component 0.5.1 hat keine Schnittstelle für
Stile auf Textbereichen. Für Fett und Kursiv im Verfassen-Fenster brauchen wir
deshalb genau eine Erweiterung — zusätzliche `HighlightStyle`-Spannen, die in
die Textläufe des Feldes eingehen. Der Weg über ein eigenes Feld wurde
verworfen, weil er Auswahl, Undo/Redo, IME und Zwischenablage nachbauen müsste
(siehe `BERICHT-L2-FORMAT-PROTOTYP.md`).

## Was geändert ist

Nur zwei Dateien, insgesamt 163 Zeilen hinzugefügt, 36 ersetzt:

```
src/input/state.rs
  + Feld `span_styles: Vec<(Range<usize>, HighlightStyle)>`
  + `set_span_styles(styles, cx)` / `span_styles()` (nur lesend, für Tests)
  + `selected_range()` — aktuelle Auswahl als UTF-8-Bereich; ohne sie käme
    die Formatleiste nicht an die Auswahl
  + Initialisierung in `InputState::new`

src/input/element.rs
  ~ `highlight_lines` liefert die Spannen in jedem Modus (bisher nur im
    Code-Editor) und schneidet sie mit `merge_span_styles` in eine lückenlose,
    überlappungsfreie Lauf-Kette über den sichtbaren Bereich. Eine Lücke wäre
    nicht kosmetisch: `runs_for_range` zählt Läufe kumulativ, fehlende Läufe
    kosten Glyphen und Cursor-Positionen.
  + Basisfarbe der Läufe ist die Textfarbe des Feldes — ohne das erbt ein
    hervorgehobener Lauf die Farbe des Fensterstils (Text wurde grau).
  + Unsichtbarer Unterstrich (Dicke 0) mit eigener Farbe je Schrift auf jedem
    Lauf. Das ist ein Workaround für gpui 0.2.2, nicht für die Darstellung:
    `TextSystem::layout_line` verschmilzt aufeinanderfolgende Läufe, solange
    sich Farbe/Unterstrich/Durchstreichung nicht ändern, und vergleicht dabei
    `font_run.font_id == last_font` — also immer wahr — statt die Schrift des
    neuen Laufs. Folge: Die ganze Zeile bekommt die Schrift des ERSTEN Laufs;
    Fett/Kursiv blieben unsichtbar, sobald nicht die ganze Zeile ausgezeichnet
    ist. Der unterschiedliche (unsichtbare) Unterstrich erzwingt die Laufgrenze.
```

Der Workaround ist bei gpui 0.2.2 nötig (exakt gepinnt, `Cargo.lock`). Ein
Upgrade auf eine Fassung mit korrigiertem `layout_line` macht ihn überflüssig —
dann fallen die vier Zeilen in `element.rs` wieder raus.

Unverändert: Undo/Redo samt Gruppierung, IME/Dead Keys, Auswahl, Zwischenablage,
Scrollen, Zeilennummern, Code-Editor-Modus. Die Spannen wirken nur auf die
Darstellung.

## Prüfen

Gegen das Original aus dem Registry-Cache:

```sh
REG=$(ls -d ~/.cargo/registry/src/*/gpui-component-0.5.1)
diff -ru "$REG" apps/linux-gpui/vendor/gpui-component | grep -E '^(\+\+\+|---|@@)'
```

Erwartet: nur `src/input/element.rs` und `src/input/state.rs`.

Der vollständige Diff des Prototyps liegt im Task-Ordner als
`belege-l2/proto-span-styles.patch`.

## Pflege

Die Version bleibt gepinnt (`=0.5.1`). Ein Upgrade heißt: neuen Stand von
crates.io nehmen, die beiden Stellen erneut anwenden, Diff gegen diesen Ordner
prüfen. `gpui` selbst bleibt ungepatcht.
