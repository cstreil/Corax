#!/bin/sh
# Startet eine isolierte Entwicklungs-Instanz neben der installierten Corax-App.
#
# Das Overlay `src-tauri/tauri.dev.conf.json` setzt einen eigenen
# Bundle-Identifier (de.streil.rabe.dev). Daraus leitet die App beim Start
# selbst ab:
#   - Datenverzeichnis  ~/Library/Application Support/de.streil.rabe.dev
#                       (SQLite-DB, .eml-Dateien, Logs, Modellgewichte)
#   - Keyring-Service   de.streil.rabe.dev
#                       (Zugangsdaten und OAuth-Tokens)
#   - Single-Instance   eigener Socket, kollidiert nicht mit der Release-App
#   - Updater           deaktiviert, kein Selbst-Update auf Upstream-Builds
#
# Die installierte Release-App bleibt unberührt und kann parallel laufen.
set -e
cd "$(dirname "$0")/.."

# Falls die lokale Dev-Signierung eingerichtet ist (scripts/macos-dev-cert.sh),
# signiert der cargo-Runner mit diesem Identifier statt mit dem der Release-App.
export COMAIL_BUNDLE_ID="de.streil.rabe.dev"

echo "Identifier: de.streil.rabe.dev (isoliert von com.deanoss.comail)"
echo

exec pnpm tauri dev --config src-tauri/tauri.dev.conf.json "$@"
