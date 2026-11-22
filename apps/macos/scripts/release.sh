#!/bin/bash
# M3.2: Release bauen, als ZIP packen, mit Sparkle (EdDSA) signieren und den
# Appcast ergänzen. Lädt nichts hoch und veröffentlicht nichts.
#
#   apps/macos/scripts/release.sh
#
# Version und Build stehen in apps/macos/VERSION (Zeile 1 = Version,
# Zeile 2 = Build-Nummer).
#
# Schlüssel: `generate_keys` legt den privaten EdDSA-Schlüssel im Schlüsselbund
# ab; sign_update liest ihn von dort. Für lokale Tests gibt SPARKLE_KEY_FILE
# eine Datei außerhalb des Repos an (z. B. /tmp/…), nie im Projekt.
#
# Variablen:
#   CORAX_FEED_URL         Adresse des Appcasts (Default: Releases-Repo)
#   CORAX_PUBLIC_ED_KEY    öffentlicher Schlüssel für die Info.plist
#   CORAX_DOWNLOAD_URL     Adresse des ZIPs im Appcast (Default: neben dem Feed)
#   CORAX_APP_NAME         Bundle-Name (Default: Corax)
#   SPARKLE_BIN            Verzeichnis mit sign_update (Default: automatisch)
#   SPARKLE_KEY_FILE       privater Testschlüssel als Datei statt Schlüsselbund
#   CORAX_BUILD_DIR        Bundle-Ausgabe für Probeläufe (Default: apps/macos/build)
#   CORAX_DIST_DIR         Ausgabe für ZIP und Appcast (Default: dist/corax/<version>)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$(cd "$here/.." && pwd)"
root="$(cd "$package/../.." && pwd)"

fail() { echo "error: $*" >&2; exit 1; }

version_file="$package/VERSION"
[ -f "$version_file" ] || fail "apps/macos/VERSION fehlt (Zeile 1 Version, Zeile 2 Build)"
version="$(sed -n '1p' "$version_file" | tr -d '[:space:]')"
build="$(sed -n '2p' "$version_file" | tr -d '[:space:]')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version '$version' ist nicht x.y.z"
[[ "$build" =~ ^[0-9]+$ ]] || fail "Build-Nummer '$build' ist keine Zahl"

feed_url="${CORAX_FEED_URL:-https://github.com/coraxapp/releases/releases/latest/download/appcast.xml}"
# Öffentlicher EdDSA-Schlüssel für die Info.plist. Öffentlich, unbedenklich —
# der private Teil liegt im Schlüsselbund des Nutzers und kommt nie ins Repo,
# in eine Datei oder ins Log.
public_key="${CORAX_PUBLIC_ED_KEY:-6ZCcUiZJOasvKpYZCbOC3ksOKdzHfKRSnlLhvwRVPPw=}"
app_name="${CORAX_APP_NAME:-Corax}"
# Probelauf wie in build-app.sh: CORAX_BUILD_DIR und CORAX_DIST_DIR woandershin.
build_dir="${CORAX_BUILD_DIR:-$package/build}"
app="$build_dir/$app_name.app"
dist="${CORAX_DIST_DIR:-$root/dist/corax/$version}"

echo "==> Version $version (Build $build)"
echo "==> Feed: $feed_url"

# 1) Bundle bauen. build-app.sh liest die Variablen (Diff M3.2 an Coder 1).
CORAX_VERSION="$version" CORAX_BUILD="$build" CORAX_FEED_URL="$feed_url" \
CORAX_PUBLIC_ED_KEY="$public_key" \
    bash "$package/scripts/build-app.sh"
[ -d "$app" ] || fail "kein Bundle unter $app"

# 2) Prüfen, dass die Update-Werte wirklich im Bundle stehen.
plist="$app/Contents/Info.plist"
plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
plist_feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist" 2>/dev/null || true)"
plist_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null || true)"
[ "$plist_version" = "$version" ] || fail "Bundle hat Version '$plist_version' statt '$version' — build-app.sh ändert (M3.2-Diff)"
[ "$plist_build" = "$build" ] || fail "Bundle hat Build '$plist_build' statt '$build' — build-app.sh ändern (M3.2-Diff)"
[ "$plist_feed" = "$feed_url" ] || fail "SUFeedURL fehlt/falsch im Bundle — build-app.sh ändern (M3.2-Diff)"
[ -n "$public_key" ] && [ "$plist_key" = "$public_key" ] || fail "SUPublicEDKey fehlt/falsch im Bundle — CORAX_PUBLIC_ED_KEY setzen und build-app.sh ändern"
[ -d "$app/Contents/Frameworks/Sparkle.framework" ] || fail "Sparkle.framework fehlt im Bundle — build-app.sh ändern (M3.2-Diff)"

# 3) Sparkle-Werkzeuge (sign_update) aus den SwiftPM-Artefakten.
sparkle_bin="${SPARKLE_BIN:-}"
if [ -z "$sparkle_bin" ]; then
    for candidate in "$package/.build" "${CORAX_SCRATCH:-/tmp/corax-build}"; do
        found="$(find "$candidate" -type f -name sign_update -path '*artifacts*' 2>/dev/null | head -1)"
        if [ -n "$found" ]; then
            sparkle_bin="$(dirname "$found")"
            break
        fi
    done
fi
[ -n "$sparkle_bin" ] && [ -x "$sparkle_bin/sign_update" ] \
    || fail "sign_update nicht gefunden — 'swift package resolve --disable-sandbox' ausführen oder SPARKLE_BIN setzen"

# 4) ZIP (mit Symlinks und Rechten, App-Ordner bleibt oberste Ebene).
mkdir -p "$dist"
zip="$dist/$app_name-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
size="$(stat -f '%z' "$zip")"
echo "==> ZIP: $zip ($size B)"

# 5) EdDSA-Signatur.
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    [ -f "$SPARKLE_KEY_FILE" ] || fail "SPARKLE_KEY_FILE '$SPARKLE_KEY_FILE' fehlt"
    signature="$("$sparkle_bin/sign_update" -f "$SPARKLE_KEY_FILE" "$zip")"
else
    signature="$("$sparkle_bin/sign_update" "$zip")"
fi
case "$signature" in
    *edSignature*) ;;
    *) fail "sign_update lieferte keine Signatur: $signature" ;;
esac
echo "==> signiert: $signature"

# 6) Appcast ergänzen (bisherige Versionen bleiben stehen).
# Die ZIP hängt am getaggten Release **ihrer** Version, nicht unter
# `latest/download`: der Feed zeigt auf "latest", die Datei selbst muss aber
# unveränderlich an ihrer Version hängen. CORAX_DOWNLOAD_URL sticht das aus.
if [ -n "${CORAX_DOWNLOAD_URL:-}" ]; then
    download_url="$CORAX_DOWNLOAD_URL"
elif [[ "$feed_url" == */latest/download/appcast.xml ]]; then
    download_url="${feed_url%/latest/download/appcast.xml}/download/v$version/$app_name-$version.zip"
else
    download_url="$(dirname "$feed_url")/$app_name-$version.zip"
fi
echo "==> Download: $download_url"
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || echo 27.0)"
appcast="$dist/appcast.xml"
python3 - "$appcast" "$version" "$build" "$download_url" "$size" "$signature" "$minimum_os" "$feed_url" <<'PY'
import sys, datetime, os
import xml.etree.ElementTree as ET

appcast, version, build, url, size, signature, minimum_os, feed = sys.argv[1:9]
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)
S = "{%s}" % NS

tree = None
if os.path.exists(appcast):
    tree = ET.parse(appcast)
    root = tree.getroot()
    channel = root.find("channel")
else:
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Corax"
    ET.SubElement(channel, "link").text = feed.rsplit("/", 1)[0]
    ET.SubElement(channel, "description").text = "Updates für Corax"
    ET.SubElement(channel, "language").text = "de"

if channel is None:
    sys.exit("appcast ohne <channel>")

# Ein Eintrag je Build: gleiche Build-Nummer ersetzen, nicht doppeln.
for item in list(channel.findall("item")):
    node = item.find(S + "version")
    if node is not None and node.text == build:
        channel.remove(item)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Corax {version}"
ET.SubElement(item, "pubDate").text = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
ET.SubElement(item, S + "version").text = build
ET.SubElement(item, S + "shortVersionString").text = version
ET.SubElement(item, S + "minimumSystemVersion").text = minimum_os
ET.SubElement(item, "enclosure", {
    "url": url,
    "length": size,
    "type": "application/octet-stream",
    S + "edSignature": signature.split('length=')[0].split('"')[1] if 'length=' in signature else signature,
})
# Vorhandene Einträge bleiben stehen; neue stehen oben, nach den Kanalangaben.
index = next((i for i, child in enumerate(list(channel)) if child.tag == "item"), len(channel))
channel.insert(index, item)
if hasattr(ET, "indent"):
    ET.indent(root, space="  ")
data = ET.tostring(root, encoding="utf-8", xml_declaration=True)
with open(appcast, "wb") as f:
    f.write(data + b"\n")
print(f"==> Appcast: {appcast}")
PY

zip_base="$(basename "$zip")"
echo
echo "fertig:"
echo "  ZIP      $zip"
echo "  Appcast  $appcast"
echo "  Größe    $size B"
echo
echo "Nichts hochgeladen. Zum Veröffentlichen ZIP und Appcast in das"
echo "Releases-Repo legen und den Feed unter $feed_url anbieten."
