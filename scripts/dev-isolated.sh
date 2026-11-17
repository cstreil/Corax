#!/bin/sh
# Startet eine isolierte Entwicklungs-Instanz neben der installierten Comail-App.
#
# Das Overlay `src-tauri/tauri.dev.conf.json` setzt einen eigenen
# Bundle-Identifier (com.deanoss.comail.dev). Daraus leitet die App beim Start
# selbst ab:
#   - Datenverzeichnis  ~/Library/Application Support/com.deanoss.comail.dev
#                       (SQLite-DB, .eml-Dateien, Logs, Modellgewichte)
#   - Keyring-Service   com.deanoss.comail.dev
#                       (Zugangsdaten und OAuth-Tokens)
#   - Single-Instance   eigener Socket, kollidiert nicht mit der Release-App
#   - Updater           deaktiviert, kein Selbst-Update auf Upstream-Builds
#
# Die installierte Release-App bleibt unberührt und kann parallel laufen.
set -e
cd "$(dirname "$0")/.."

# Falls die lokale Dev-Signierung eingerichtet ist (scripts/macos-dev-cert.sh),
# signiert der cargo-Runner mit diesem Identifier statt mit dem der Release-App.
export COMAIL_BUNDLE_ID="com.deanoss.comail.dev"

echo "Identifier: com.deanoss.comail.dev (isoliert von com.deanoss.comail)"
echo

exec pnpm tauri dev --config src-tauri/tauri.dev.conf.json "$@"
