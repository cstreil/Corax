#!/bin/sh
# Veröffentlicht eine Fork-Release: baut und signiert die App, packt sie für den
# Updater, signiert das Archiv und legt ein GitHub-Release mit latest.json an.
#
# Aufruf:
#   sh scripts/release-fork.sh                 # bauen + veröffentlichen
#   sh scripts/release-fork.sh --no-publish    # nur bauen, dist/ füllen
#
# Voraussetzungen:
#   - Updater-Schlüssel unter ~/.tauri/rabe-updater.key
#     (erzeugen: pnpm tauri signer generate -w ~/.tauri/rabe-updater.key)
#     Der passende Public Key steht in src-tauri/tauri.conf.json; ohne ihn
#     lehnt jede installierte App das Update ab.
#   - gh ist als cstreil angemeldet und cstreil/comail ist das Ziel.
#
# Die Version kommt aus tauri.conf.json. Vor jedem Release dort hochziehen —
# der Updater vergleicht Semver, gleiche Version heißt „kein Update".
set -e
cd "$(dirname "$0")/.."

KEY="${TAURI_SIGNING_PRIVATE_KEY_PATH:-$HOME/.tauri/rabe-updater.key}"
PUBLISH=1
[ "${1:-}" = "--no-publish" ] && PUBLISH=0

if [ ! -f "$KEY" ]; then
  echo "Fehler: kein Updater-Schlüssel unter $KEY" >&2
  exit 1
fi

VERSION="$(python3 -c 'import json,sys; print(json.load(open("src-tauri/tauri.conf.json"))["version"])')"
TAG="v$VERSION"
DIST="dist"
ARCHIVE="$DIST/Rabe.app.tar.gz"

echo "Version: $VERSION  (Tag $TAG)"

# 1. Bauen, signieren, nach /Applications installieren.
NO_INSTALL=1 sh scripts/build-local-app.sh

# 2. Archiv für den Updater. Das signierte Bundle aus dem Build-Verzeichnis,
#    damit die installierte App und das Archiv identisch sind.
rm -rf "$DIST"
mkdir -p "$DIST"
COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C src-tauri/target/release/bundle/macos Rabe.app

# 3. Archiv signieren (minisign, Schlüssel bleibt außerhalb des Repos).
#    Das Passwort muss explizit mitgegeben werden: ohne -p fragt die CLI am
#    Terminal nach und scheitert an einem Aufruf ohne TTY (os error 6).
#    Der Schlüssel dieses Forks hat bewusst kein Passwort (Datei ist 0600).
pnpm tauri signer sign -f "$KEY" -p "${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}" \
  "$ARCHIVE" >/dev/null
SIGNATURE="$(cat "$ARCHIVE.sig")"

# 4. Updater-Manifest. Die URL ist der Release-Asset-Pfad; installierte Apps
#    fragen releases/latest/download/latest.json und landen so auf der neuesten
#    Version.
python3 - "$VERSION" "$SIGNATURE" <<'PY'
import json, pathlib, sys
from datetime import datetime, timezone

version, signature = sys.argv[1], sys.argv[2]
url = f"https://github.com/cstreil/comail/releases/download/v{version}/Rabe.app.tar.gz"
manifest = {
    "version": version,
    "notes": f"Rabe {version}",
    "pub_date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "platforms": {
        "darwin-aarch64": {"signature": signature, "url": url},
    },
}
pathlib.Path("dist/latest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("dist/latest.json geschrieben")
PY

if [ "$PUBLISH" = 0 ]; then
  echo
  echo "Nicht veröffentlicht. Fertig zum Hochladen:"
  echo "  $ARCHIVE"
  echo "  $ARCHIVE.sig"
  echo "  $DIST/latest.json"
  exit 0
fi

# 5. Release anlegen. Existiert der Tag schon, bricht gh ab — dann Version
#    hochziehen statt überschreiben.
gh release create "$TAG" \
  --repo cstreil/comail \
  --title "Rabe $VERSION" \
  --notes "Rabe $VERSION — signiertes Update für macOS (Apple Silicon)." \
  "$ARCHIVE" "$ARCHIVE.sig" "$DIST/latest.json"

echo
echo "Veröffentlicht: $TAG"
echo "Feed: https://github.com/cstreil/comail/releases/latest/download/latest.json"
