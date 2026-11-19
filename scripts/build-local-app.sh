#!/bin/sh
# Baut Rabe.app aus dem Fork, signiert sie und installiert sie nach /Applications.
#
# Drei lokale Eigenheiten werden behandelt:
#  - Ohne volles Xcode fehlen die Siri-Intents-Metadaten
#    (gen/apple-intents/Metadata.appintents), tauri.conf.json referenziert sie
#    aber im Bundle. Der Eintrag wird für den Build entfernt und danach
#    wiederhergestellt.
#  - Signiert wird mit einer echten "Apple Development"-Identität, nicht mit
#    einer selbstgemachten: nur ein Apple-Zertifikat trägt eine Team-ID, und
#    daraus leitet macOS die Keychain-Partition ab. Mit der ad-hoc-Signatur von
#    tauri hinge die Freigabe am CDHash und jedes Update würde erneut nach dem
#    IMAP-Passwort fragen. Fallback: die selbstgemachte "comail-dev"-Identität
#    (einmalig: bash src-tauri/scripts/macos-dev-cert.sh).
#  - Der Updater bleibt aktiv. Endpoint und Public Key stehen in
#    tauri.conf.json; Updates werden von scripts/release-fork.sh signiert.
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

pnpm tauri build --bundles app

APP="src-tauri/target/release/bundle/macos/Rabe.app"
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
if [ -z "$SIGN_IDENTITY" ] && security find-certificate -c "comail-dev" >/dev/null 2>&1; then
  SIGN_IDENTITY="comail-dev"
fi
if [ -n "$SIGN_IDENTITY" ]; then
  # Sign a copy outside the iCloud work tree: fileprovider keeps
  # com.apple.FinderInfo on bundles in there, and codesign rejects that with
  # "resource fork, Finder information, or similar detritus not allowed".
  SIGN_DIR="$(mktemp -d)"
  ditto "$APP" "$SIGN_DIR/Rabe.app"
  xattr -cr "$SIGN_DIR/Rabe.app"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "de.streil.rabe" \
    --timestamp=none "$SIGN_DIR/Rabe.app"
  rm -rf "$APP"
  ditto "$SIGN_DIR/Rabe.app" "$APP"
  rm -rf "$SIGN_DIR"
  echo "Signiert mit: $SIGN_IDENTITY"
else
  echo "Warnung: keine Signatur-Identität gefunden - App bleibt ad-hoc signiert." >&2
  echo "         Einmalig: bash src-tauri/scripts/macos-dev-cert.sh" >&2
fi

# release-fork.sh baut nur und verpackt selbst; alles andere installiert.
if [ "${NO_INSTALL:-0}" = "1" ]; then
  echo
  echo "Nicht installiert (NO_INSTALL=1). Bundle: $APP"
  exit 0
fi

osascript -e 'quit app "Rabe"' 2>/dev/null || true
sleep 2
rm -rf /Applications/Rabe.app
ditto "$APP" /Applications/Rabe.app

echo
echo "Installiert: /Applications/Rabe.app"
