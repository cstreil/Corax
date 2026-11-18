#!/bin/sh
# Baut Rabe.app aus dem Fork und installiert sie nach /Applications.
#
# Zwei lokale Eigenheiten werden behandelt:
#  - Ohne volles Xcode fehlen die Siri-Intents-Metadaten
#    (gen/apple-intents/Metadata.appintents), tauri.conf.json referenziert sie
#    aber im Bundle. Der Eintrag wird für den Build entfernt und danach
#    wiederhergestellt.
#  - Die App wird mit der stabilen "comail-dev"-Identität signiert, damit die
#    Keychain-Freigabe Rebuilds überlebt. Voraussetzung:
#    bash src-tauri/scripts/macos-dev-cert.sh (einmalig).
#
# Updater-Artefakte und -Endpunkte sind über tauri.local.conf.json aus, damit
# sich der Fork nicht selbst durch Upstream-Releases ersetzt.
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

pnpm tauri build --config src-tauri/tauri.local.conf.json --bundles app

APP=src-tauri/target/release/bundle/macos/Rabe.app
rm -rf /Applications/Rabe.app
cp -R "$APP" /Applications/Rabe.app
xattr -cr /Applications/Rabe.app
codesign --force --sign "comail-dev" --identifier "de.streil.rabe" \
  --timestamp=none /Applications/Rabe.app

echo
echo "Installiert: /Applications/Rabe.app"
