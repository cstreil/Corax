#!/bin/sh
# Baut eine eigenständige Comail Dev.app: eigener Identifier
# (com.deanoss.comail.dev), eigenes Datenverzeichnis, eigener Keyring-Service,
# kein Updater. Läuft parallel zu einer installierten Release-App.
#
# Ergebnis: src-tauri/target/release/bundle/macos/Comail Dev.app
#
# Release-Profil statt `tauri dev`, weil das Einbetten des Mail-Korpus im
# Debug-Build um Größenordnungen langsamer ist. Dieselbe Datenverzeichnis-
# Basis wie `pnpm dev:isolated` — beide teilen sich den Datenbestand, es darf
# aber immer nur eine der beiden laufen (gleicher Identifier).
#
# Zwei lokale Eigenheiten wie in build-local-app.sh:
#  - Ohne volles Xcode fehlen die Siri-Intents-Metadaten; der Bundle-Eintrag
#    wird für den Build entfernt und danach wiederhergestellt.
#  - `--bundles app` ist nötig, weil die Basiskonfiguration nur Linux-Ziele listet.
set -e
cd "$(dirname "$0")/.."

CONF=src-tauri/tauri.conf.json
BAK="$(mktemp)"
cp "$CONF" "$BAK"
trap 'cp "$BAK" "$CONF"; rm -f "$BAK"' EXIT

python3 - "$CONF" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
d.get("bundle", {}).get("macOS", {}).pop("files", None)
p.write_text(json.dumps(d, indent=2) + "\n")
PY

pnpm tauri build --config src-tauri/tauri.dev.conf.json --bundles app "$@"

# Sign with a stable identity, exactly like build-local-app.sh. Without this the
# bundle keeps tauri's ad-hoc signature, whose CDHash changes on every build -
# and the login keychain ties its "Always Allow" grant to that signature, so
# each rebuild would re-prompt for the stored IMAP credentials (and hang until
# someone clicks).
#
# A real "Apple Development" identity is preferred over the self-signed
# "comail-dev" one: only an Apple-issued certificate carries a Team ID, and
# macOS derives the keychain partition ID from it. A self-signed identity has
# no Team ID, so its partition ID falls back to the CDHash and every rebuild
# re-prompts no matter how often "Always Allow" was clicked.
APP="src-tauri/target/release/bundle/macos/Comail Dev.app"
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
if [ -z "$SIGN_IDENTITY" ] && security find-certificate -c "comail-dev" >/dev/null 2>&1; then
  SIGN_IDENTITY="comail-dev"
fi
if [ -n "$SIGN_IDENTITY" ]; then
  xattr -cr "$APP"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "com.deanoss.comail.dev" \
    --timestamp=none "$APP"
  echo "Signiert mit: $SIGN_IDENTITY"
else
  echo "Warnung: keine Signatur-Identität gefunden - App bleibt ad-hoc signiert." >&2
  echo "         Einmalig: bash src-tauri/scripts/macos-dev-cert.sh" >&2
fi

echo
echo "Bundle: $APP"
echo "Installieren: ditto \"$APP\" \"/Applications/Comail Dev.app\""
