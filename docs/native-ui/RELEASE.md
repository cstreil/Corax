# Release

Corax wird über Sparkle ausgeliefert. Ein Release ist **ein** Befehl:

```sh
apps/macos/scripts/release.sh --publish
```

Vorher steht die neue Version in `apps/macos/VERSION` (Zeile 1 Version, Zeile 2 Build).
Das Skript baut, prüft, signiert, veröffentlicht und prüft nach. Es committet nichts
und fasst `/Applications` nicht an.

## Ablauf

| Schritt | Was passiert |
|---|---|
| 1 | Argumente lesen, `VERSION` prüfen (x.y.z, Build ≥ 1) |
| 2 | **Vorabprüfungen** (nur mit `--publish`): Arbeitsbaum sauber, `gh` angemeldet, Sparkle-Schlüssel im Schlüsselbund, Live-Feed holen, Version vor dem Feed, Tag und Release frei |
| 3 | `build-app.sh`: Rust-Staticlib, Bindings, `.app`, Signatur |
| 4 | **Bundle prüfen**: `codesign -v`, `CFBundleExecutable` = `Corax`, Version und Build = `VERSION`, Feed und Schlüssel in der Plist, kein `LSEnvironment`, keine Hook-Treffer im Binary |
| 5 | ZIP packen (`ditto`, Symlinks und Rechte bleiben) und mit EdDSA signieren |
| 6 | Appcast: Live-Feed holen, neuen Eintrag oben einsortieren, alte Einträge behalten, `xmllint --noout` |
| 7 | **Veröffentlichen**: `gh release create v<version>` mit ZIP und `appcast.xml`, als Latest, kein Entwurf |
| 8 | **Nachprüfung**: Feed zeigt den neuen Build, ZIP-URL antwortet 200, Länge und SHA-256 des Downloads stimmen mit dem lokalen ZIP |
| 9 | Zusammenfassung mit Version, Größe, Hashes und Release-Adresse |

## Aufrufe

```sh
scripts/release.sh                        # nur bauen, prüfen, signieren (lokal)
scripts/release.sh --publish --dry-run    # alle Prüfungen und Schritte, ohne Upload
scripts/release.sh --publish              # veröffentlichen
scripts/release.sh --publish --notes-file notizen.md
```

`--dry-run` macht alles außer Schritt 7 und 8 und zeigt den `gh`-Befehl, der laufen
würde. Ein Probelauf braucht keine freie Version und keinen freien Tag, die
Vorabprüfungen laufen aber trotzdem — mit dem Test `VERSION` auf die nächste Nummer
gestellt, danach zurück.

Ohne `--notes-file` lautet der Release-Text „Corax \<version\> (Build \<build\>)“ plus
die Betreffzeile des letzten Commits.

## Vorabprüfungen

Jede bricht mit `error:` und einer Erklärung ab:

- **Arbeitsbaum:** kein Release aus ungesicherten Änderungen. Einzige Ausnahme ist
  `apps/macos/VERSION` selbst — sie wird erst nach dem Live-Test committet.
- **`gh`:** angemeldet, mit Zugriff auf das Releases-Repo.
- **Schlüssel:** `security find-generic-password -s https://sparkle-project.org -a ed25519`
  muss etwas finden. Das Skript liest den Schlüssel nie, `sign_update` holt ihn beim
  Signieren.
- **Live-Feed:** muss erreichbar sein (HTTP 200). Ein fehlender Feed (404) gilt als
  erster Release.
- **Version:** Build größer als der oberste Eintrag im Feed, Version nicht kleiner.
- **Tag und Release:** `v<version>` darf es in `coraxapp/releases` noch nicht geben.

## Bundle-Prüfungen

Ein Bundle darf nie mit Test-Hooks hinausgehen. Geprüft wird:

```sh
codesign -v Corax.app
PlistBuddy -c 'Print :CFBundleExecutable'      # Corax
PlistBuddy -c 'Print :CFBundleShortVersionString' / :CFBundleVersion
PlistBuddy -c 'Print :SUFeedURL' / :SUPublicEDKey
PlistBuddy -c 'Print :LSEnvironment'           # muss fehlschlagen
strings -a Contents/MacOS/Corax | grep -c CORAX_TEST_HOOKS|CORAX_DEBUG_AUTOMATION   # 0
```

## Variablen

| Variable | Bedeutung | Default |
|---|---|---|
| `CORAX_RELEASES_REPO` | Releases-Repo | `coraxapp/releases` |
| `CORAX_FEED_URL` | Adresse des Appcasts | `<Repo>/releases/latest/download/appcast.xml` |
| `CORAX_DOWNLOAD_URL` | ZIP-Adresse im Appcast | am Tag `v<version>` |
| `CORAX_APP_NAME` | Bundle-Name | `Corax` |
| `CORAX_BUILD_DIR` | Bundle-Ausgabe | `apps/macos/build` |
| `CORAX_DIST_DIR` | ZIP und Appcast | `dist/corax/<version>` |
| `SPARKLE_BIN` | Ordner mit `sign_update` | aus den SwiftPM-Artefakten |
| `SPARKLE_KEY_FILE` | privater Schlüssel als Datei (nur Probeläufe) | — |

## Wenn es nach dem Upload scheitert

Das Skript löscht nichts. Bricht es nach `gh release create` ab, sagt der Schlussblock
genau, was draußen ist (Release, ZIP, Appcast, aktueller Build) und wie man es
zurücknimmt:

```sh
gh release delete v<version> --repo coraxapp/releases --yes --cleanup-tag
```

`--cleanup-tag` entfernt auch den Tag. Danach zeigt `latest/download` wieder auf die
vorherige Version — GitHub braucht dafür ein paar Sekunden. Bereits installierte
Clients fallen auf den vorherigen Eintrag zurück, weil Sparkle die Versionen der Reihe
nach prüft.

## Nach dem Release

1. Der Nutzer drückt in Corax „Jetzt nach Updates suchen“ und installiert.
2. Nach dem Live-Test kommt `apps/macos/VERSION` in einen eigenen Commit.
3. Danach ist der Stand eingefroren; ein Tag `corax-<version>` (ohne `v`, damit kein
   CI-Workflow anspringt) markiert ihn.

## Was das Skript nicht macht

- keinen Commit, keinen Push, kein Tag im Code-Repo;
- nichts in `/Applications`;
- keine Notarisierung (kein Apple-Developer-Konto, siehe `FORK.md`).
