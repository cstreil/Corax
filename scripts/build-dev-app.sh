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

echo
echo "Bundle: src-tauri/target/release/bundle/macos/Comail Dev.app"
