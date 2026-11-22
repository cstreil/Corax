#!/bin/bash
# Corax-Release: bauen, prüfen, mit Sparkle signieren, veröffentlichen.
#
#   scripts/release.sh                          # nur bauen, prüfen, signieren (lokal)
#   scripts/release.sh --publish --dry-run      # alle Prüfungen und Schritte, ohne Upload
#   scripts/release.sh --publish                # bauen und veröffentlichen
#   scripts/release.sh --publish --notes-file notizen.md
#
# Version und Build stehen in apps/macos/VERSION (Zeile 1 = Version,
# Zeile 2 = Build-Nummer). Ablauf und Wiederherstellung: docs/native-ui/RELEASE.md
#
# Schlüssel: `generate_keys` legt den privaten EdDSA-Schlüssel im Schlüsselbund
# ab, `sign_update` liest ihn von dort. Für lokale Probeläufe ohne Schlüsselbund
# gibt SPARKLE_KEY_FILE eine Datei außerhalb des Repos an (nie im Projekt).
#
# Variablen:
#   CORAX_RELEASES_REPO    Releases-Repo (Default: coraxapp/releases)
#   CORAX_FEED_URL         Adresse des Appcasts (Default: <Repo>/latest/download/appcast.xml)
#   CORAX_PUBLIC_ED_KEY    öffentlicher Schlüssel für die Info.plist
#   CORAX_DOWNLOAD_URL     Adresse des ZIPs im Appcast (Default: am Versions-Tag)
#   CORAX_APP_NAME         Bundle-Name (Default: Corax)
#   SPARKLE_BIN            Verzeichnis mit sign_update (Default: automatisch)
#   SPARKLE_KEY_FILE       privater Testschlüssel als Datei statt Schlüsselbund
#   CORAX_BUILD_DIR        Bundle-Ausgabe (Default: apps/macos/build)
#   CORAX_DIST_DIR         Ausgabe für ZIP und Appcast (Default: dist/corax/<version>)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$(cd "$here/.." && pwd)"
root="$(cd "$package/../.." && pwd)"

usage() {
    cat <<'EOF'
Corax-Release: bauen, prüfen, mit Sparkle signieren, veröffentlichen.

  release.sh                        nur bauen, prüfen, signieren (lokal)
  release.sh --publish --dry-run    alle Prüfungen und Schritte, ohne Upload
  release.sh --publish              bauen und veröffentlichen
  release.sh --publish --notes-file notizen.md

Version und Build: apps/macos/VERSION (Zeile 1 Version, Zeile 2 Build).
Ablauf und Wiederherstellung: docs/native-ui/RELEASE.md
EOF
}

fail() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ---------------------------------------------------------------- Argumente

publish=0
dry_run=0
notes_file=""
while [ $# -gt 0 ]; do
    case "$1" in
        --publish) publish=1 ;;
        --dry-run) publish=1; dry_run=1 ;;
        --notes-file) [ $# -ge 2 ] || fail "--notes-file braucht einen Pfad"; notes_file="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unbekannter Schalter: $1" ;;
    esac
    shift
done
[ "$dry_run" = 1 ] && [ "$publish" = 0 ] && fail "--dry-run ohne --publish ergibt nichts"

# ---------------------------------------------------------------- Konstanten

version_file="$package/VERSION"
[ -f "$version_file" ] || fail "apps/macos/VERSION fehlt (Zeile 1 Version, Zeile 2 Build)"
version="$(sed -n '1p' "$version_file" | tr -d '[:space:]')"
build="$(sed -n '2p' "$version_file" | tr -d '[:space:]')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version '$version' ist nicht x.y.z"
[[ "$build" =~ ^[0-9]+$ ]] || fail "Build-Nummer '$build' ist keine Zahl"
[ "$build" -ge 1 ] || fail "Build-Nummer muss mindestens 1 sein"

repo="${CORAX_RELEASES_REPO:-coraxapp/releases}"
feed_url="${CORAX_FEED_URL:-https://github.com/$repo/releases/latest/download/appcast.xml}"
# Öffentlicher EdDSA-Schlüssel für die Info.plist. Öffentlich, unbedenklich —
# der private Teil liegt im Schlüsselbund des Nutzers und kommt nie ins Repo,
# in eine Datei oder ins Log.
public_key="${CORAX_PUBLIC_ED_KEY:-6ZCcUiZJOasvKpYZCbOC3ksOKdzHfKRSnlLhvwRVPPw=}"
app_name="${CORAX_APP_NAME:-Corax}"
build_dir="${CORAX_BUILD_DIR:-$package/build}"
app="$build_dir/$app_name.app"
dist="${CORAX_DIST_DIR:-$root/dist/corax/$version}"
tag="v$version"
zip="$dist/$app_name-$version.zip"
appcast="$dist/appcast.xml"
live_feed="$dist/live-appcast.xml"

# Reste eines früheren Laufs wegräumen, damit nichts Altes mitgeht.
mkdir -p "$dist"
rm -f "$live_feed"

info "Version $version (Build $build)"
info "Feed: $feed_url"
[ "$publish" = 1 ] && info "Modus: $([ "$dry_run" = 1 ] && echo 'Probelauf, kein Upload' || echo 'veröffentlichen')"

uploaded=0
feed_was_up=0
previous_version=""

# Was ist schon draußen, wenn es nach dem Upload scheitert? Löschen tut das
# Skript nichts; es sagt nur, was liegt und wie man es zurücknimmt.
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$uploaded" = 1 ]; then
        cat >&2 <<EOF

!! FEHLER NACH DEM UPLOAD — das ist bereits veröffentlicht:
   Release $tag in $repo mit $app_name-$version.zip und appcast.xml
   Der Feed zeigt jetzt auf Build $build.
   Zurücknehmen (löscht Release, Assets und den Tag):
     gh release delete $tag --repo $repo --yes --cleanup-tag
   Danach zeigt "latest" wieder auf ${previous_version:-die vorherige Version}.
EOF
    fi
    return $rc
}
trap on_exit EXIT

# ---------------------------------------------------------------- Vorabprüfungen

check_clean_tree() {
    local dirty
    # apps/macos/VERSION darf für einen Release geändert sein; sie wird erst nach
    # dem Live-Test committet. Alles andere muss aus einem Commit stammen.
    dirty="$(git -C "$root" status --porcelain -- . ':(exclude)apps/macos/VERSION')"
    if [ -n "$dirty" ]; then
        echo "error: Arbeitsbaum ist nicht sauber — ein Release kommt aus einem Commit:" >&2
        printf '%s\n' "$dirty" | sed 's/^/  /' >&2
        echo "  Erlaubt ist nur apps/macos/VERSION (kommt erst nach dem Live-Test in den Commit)." >&2
        exit 1
    fi
    if [ -n "$(git -C "$root" status --porcelain -- apps/macos/VERSION)" ]; then
        info "Hinweis: apps/macos/VERSION ist geändert — wird nicht automatisch committet."
    fi
}

check_gh() {
    command -v gh >/dev/null 2>&1 || fail "gh fehlt — GitHub CLI installieren und anmelden"
    gh auth status >/dev/null 2>&1 \
        || fail "gh ist nicht angemeldet — 'gh auth login' ausführen (Konto mit Zugriff auf $repo)"
}

check_sparkle_key() {
    if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
        [ -f "$SPARKLE_KEY_FILE" ] || fail "SPARKLE_KEY_FILE '$SPARKLE_KEY_FILE' fehlt"
        info "Schlüssel: Datei $SPARKLE_KEY_FILE (Probelauf)"
        return
    fi
    # Nur nachsehen, ob der Eintrag da ist — den Schlüssel liest das Skript nie.
    if ! security find-generic-password -s "https://sparkle-project.org" -a "ed25519" >/dev/null 2>&1; then
        fail "kein Sparkle-Schlüssel im Schlüsselbund (Dienst https://sparkle-project.org, Konto ed25519) — 'generate_keys' ausführen"
    fi
    info "Schlüssel: im Schlüsselbund vorhanden"
}

# Holt den Live-Feed nach $live_feed. Setzt feed_was_up=1, wenn es ihn gibt.
# $1 = "required": ohne Feed nicht weiter (Veröffentlichen), sonst nur warnen.
fetch_live_feed() {
    local mode="${1:-optional}" code previous
    code="$(curl -sS -o "$live_feed" -w '%{http_code}' -L "$feed_url" || true)"
    case "$code" in
        200)
            if grep -q "<item>" "$live_feed"; then
                feed_was_up=1
                previous="$(python3 - "$live_feed" <<'PY'
import sys
import xml.etree.ElementTree as ET
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(sys.argv[1]).getroot().find("channel").findall("item")
print((items[0].findtext(S + "shortVersionString") or "?") if items else "?")
PY
)"
                previous_version="$previous"
                info "Live-Feed: oben steht $previous"
            else
                info "Live-Feed ohne Einträge"
            fi
            ;;
        404)
            rm -f "$live_feed"
            info "Kein Live-Feed vorhanden (erster Release)"
            ;;
        *)
            rm -f "$live_feed"
            if [ "$mode" = required ]; then
                fail "Live-Feed nicht erreichbar (HTTP $code): $feed_url
  Ohne Feed lässt sich die Version nicht vergleichen. Netz prüfen oder
  CORAX_FEED_URL setzen."
            fi
            info "Warnung: Live-Feed nicht erreichbar (HTTP $code) — der Appcast wird neu angelegt."
            ;;
    esac
}

check_version_is_ahead() {
    [ "$feed_was_up" = 1 ] || return 0
    python3 - "$live_feed" "$version" "$build" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, new_version, new_build = sys.argv[1], sys.argv[2], int(sys.argv[3])
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
channel = ET.parse(path).getroot().find("channel")
items = channel.findall("item")
if not items:
    sys.exit(0)
top = items[0]
top_build = int((top.findtext(S + "version") or "0").strip())
top_version = (top.findtext(S + "shortVersionString") or "0").strip()


def parts(v):
    return [int(p) for p in v.split(".")]


if new_build <= top_build:
    sys.exit(
        f"error: Build {new_build} ist nicht größer als der im Feed ({top_build}).\n"
        f"  Die Version steht schon draußen. VERSION hochziehen, z. B. auf dem nächsten Build."
    )
if parts(new_version) < parts(top_version):
    sys.exit(
        f"error: Version {new_version} ist kleiner als die im Feed ({top_version})."
    )
PY
    info "Version ist vor dem Feed ($version/$build)"
}

check_tag_and_release_are_free() {
    if gh api "repos/$repo/git/refs/tags/$tag" >/dev/null 2>&1; then
        fail "Tag $tag existiert in $repo schon — VERSION hochziehen oder den Tag entfernen"
    fi
    if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
        fail "Release $tag existiert in $repo schon — 'gh release delete $tag --repo $repo --yes --cleanup-tag' prüfen"
    fi
    info "Tag und Release $tag sind frei"
}

if [ "$publish" = 1 ]; then
    info "Prüfe Voraussetzungen"
    if [ -n "$notes_file" ] && [ ! -f "$notes_file" ]; then
        fail "Notes-Datei '$notes_file' fehlt"
    fi
    check_clean_tree
    check_gh
    check_sparkle_key
    fetch_live_feed required
    check_version_is_ahead
    check_tag_and_release_are_free
else
    # Ohne --publish wird der Live-Feed trotzdem geholt, damit alte Einträge im
    # lokalen Appcast bleiben; scheitert das, geht es ohne weiter.
    fetch_live_feed optional
fi

# ---------------------------------------------------------------- Bauen

info "Baue $app_name.app"
CORAX_VERSION="$version" CORAX_BUILD="$build" CORAX_FEED_URL="$feed_url" \
CORAX_PUBLIC_ED_KEY="$public_key" \
    bash "$package/scripts/build-app.sh"
[ -d "$app" ] || fail "kein Bundle unter $app"

# ---------------------------------------------------------------- Bundle prüfen

plist="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/$app_name"

plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
plist_feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist" 2>/dev/null || true)"
plist_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null || true)"
plist_exec="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"

[ "$plist_version" = "$version" ] || fail "Bundle hat Version '$plist_version' statt '$version' — build-app.sh ändern"
[ "$plist_build" = "$build" ] || fail "Bundle hat Build '$plist_build' statt '$build' — build-app.sh ändern"
[ "$plist_exec" = "$app_name" ] || fail "CFBundleExecutable ist '$plist_exec' statt '$app_name'"
[ "$plist_feed" = "$feed_url" ] || fail "SUFeedURL fehlt/falsch im Bundle — build-app.sh ändern"
[ -n "$public_key" ] && [ "$plist_key" = "$public_key" ] || fail "SUPublicEDKey fehlt/falsch im Bundle — CORAX_PUBLIC_ED_KEY setzen"
[ -d "$app/Contents/Frameworks/Sparkle.framework" ] || fail "Sparkle.framework fehlt im Bundle — build-app.sh ändern"
[ -f "$binary" ] || fail "Binärdatei $binary fehlt"

codesign -v "$app" 2>/dev/null || fail "Signatur ungültig — 'codesign -v $app' sagt warum"
info "Signatur gültig ($app_name)"

if /usr/libexec/PlistBuddy -c 'Print :LSEnvironment' "$plist" >/dev/null 2>&1; then
    fail "Info.plist hat LSEnvironment — ein Release-Bundle darf keine Test-Hooks tragen"
fi
hook_hits="$(strings -a "$binary" | grep -c -E "CORAX_TEST_HOOKS|CORAX_DEBUG_AUTOMATION" || true)"
[ "$hook_hits" = 0 ] || fail "Binary enthält $hook_hits Treffer auf Test-Hooks (CORAX_TEST_HOOKS/CORAX_DEBUG_AUTOMATION)"
info "Keine Test-Hooks im Bundle"

# ---------------------------------------------------------------- ZIP und Signatur

info "Packe $app_name-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
size="$(stat -f '%z' "$zip")"
info "ZIP: $zip ($size B)"

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

if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    signature="$("$sparkle_bin/sign_update" -f "$SPARKLE_KEY_FILE" "$zip")"
else
    signature="$("$sparkle_bin/sign_update" "$zip")"
fi
case "$signature" in
    *edSignature*) ;;
    *) fail "sign_update lieferte keine Signatur: $signature" ;;
esac
info "signiert: $signature"

# ---------------------------------------------------------------- Appcast

# Die ZIP hängt am getagten Release **ihrer** Version, nicht unter
# `latest/download`: der Feed zeigt auf "latest", die Datei selbst muss aber
# unveränderlich an ihrer Version hängen. CORAX_DOWNLOAD_URL sticht das aus.
if [ -n "${CORAX_DOWNLOAD_URL:-}" ]; then
    download_url="$CORAX_DOWNLOAD_URL"
else
    download_url="https://github.com/$repo/releases/download/$tag/$app_name-$version.zip"
fi
info "Download: $download_url"
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || echo 27.0)"

# Immer vom Live-Feed aus neu bauen: alte Einträge bleiben, der neue kommt oben
# hinein. Ein lokal liegengebliebener Appcast wird nicht weitergetragen.
base_feed=""
if [ "$feed_was_up" = 1 ]; then
    base_feed="$live_feed"
elif [ -f "$appcast" ] && grep -q "<item>" "$appcast"; then
    base_feed="$appcast"
fi
rm -f "$appcast"
python3 - "$appcast" "$base_feed" "$version" "$build" "$download_url" "$size" "$signature" "$minimum_os" "$feed_url" <<'PY'
import sys, datetime, os
import xml.etree.ElementTree as ET

appcast, base, version, build, url, size, signature, minimum_os, feed = sys.argv[1:10]
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)
S = "{%s}" % NS

tree = None
if base and os.path.exists(base):
    tree = ET.parse(base)
    root = tree.getroot()
    channel = root.find("channel")
else:
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Corax"
    ET.SubElement(channel, "link").text = feed.rsplit("/releases/", 1)[0]
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
PY

xmllint --noout "$appcast" || fail "Appcast ist kein gültiges XML: $appcast"
info "Appcast: $appcast"

# ---------------------------------------------------------------- Veröffentlichen

notes="$(printf 'Corax %s (Build %s)\n\n%s' "$version" "$build" "$(git -C "$root" log -1 --format=%s)")"
if [ -n "$notes_file" ]; then
    [ -f "$notes_file" ] || fail "Notes-Datei '$notes_file' fehlt"
    notes="$(cat "$notes_file")"
fi

if [ "$publish" = 0 ]; then
    info "Nicht veröffentlicht (kein --publish)."
elif [ "$dry_run" = 1 ]; then
    info "Probelauf: würde veröffentlichen"
    printf '  gh release create %s --repo %s --title "Corax %s" --latest \\\n    %s %s\n' \
        "$tag" "$repo" "$version" "$zip" "$appcast"
else
    info "Veröffentliche $tag in $repo"
    if ! gh release create "$tag" --repo "$repo" --title "Corax $version" --notes "$notes" --latest \
        "$zip" "$appcast"; then
        # Erst nachsehen, ob trotzdem etwas draußen ist: eine halb gelungene
        # Veröffentlichung darf man nicht als „nichts passiert" melden.
        if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
            uploaded=1
            fail "gh release create meldete einen Fehler, das Release $tag liegt aber schon in $repo — siehe Schlussblock"
        fi
        fail "gh release create fehlgeschlagen, es wurde nichts veröffentlicht"
    fi
    uploaded=1
fi

# ---------------------------------------------------------------- Nachprüfung

if [ "$uploaded" = 1 ]; then
    info "Prüfe Feed und ZIP"
    deadline=$((SECONDS + 180))
    feed_ok=0
    while [ "$SECONDS" -lt "$deadline" ]; do
        if code="$(curl -sS -o "$live_feed" -w '%{http_code}' -L "$feed_url" || true)" && [ "$code" = 200 ]; then
            if python3 - "$live_feed" "$build" <<'PY'
import sys
import xml.etree.ElementTree as ET
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(sys.argv[1]).getroot().find("channel").findall("item")
sys.exit(0 if items and (items[0].findtext(S + "version") or "").strip() == sys.argv[2] else 1)
PY
            then
                feed_ok=1
                break
            fi
        fi
        sleep 3
    done
    [ "$feed_ok" = 1 ] || fail "Feed zeigt nach 180 s nicht Build $build — $feed_url"

    served_zip="$dist/.served-$app_name-$version.zip"
    rm -f "$served_zip"
    code="$(curl -sSL -o "$served_zip" -w '%{http_code}' "$download_url" || true)"
    [ "$code" = 200 ] || fail "ZIP-URL antwortet mit HTTP $code: $download_url"
    served_size="$(stat -f '%z' "$served_zip")"
    [ "$served_size" = "$size" ] || fail "ZIP im Netz ist $served_size B, lokal $size B"
    local_sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
    served_sha="$(shasum -a 256 "$served_zip" | cut -d' ' -f1)"
    [ "$local_sha" = "$served_sha" ] || fail "ZIP im Netz hat sha256 $served_sha, lokal $local_sha"
    rm -f "$served_zip"
    info "Feed und ZIP stimmen mit dem lokalen Stand überein"
fi

# ---------------------------------------------------------------- Zusammenfassung

echo
echo "fertig:"
echo "  Version   $version (Build $build)"
echo "  ZIP       $zip"
echo "  Größe     $size B"
echo "  ZIP sha   $(shasum -a 256 "$zip" | cut -d' ' -f1)"
echo "  Binary    $(shasum -a 256 "$binary" | cut -d' ' -f1)"
echo "  Signatur  $(echo "$signature" | sed 's/.*edSignature="//; s/".*//' | cut -c1-32)…"
echo "  Appcast   $appcast"
if [ "$uploaded" = 1 ]; then
    echo "  Release   https://github.com/$repo/releases/tag/$tag"
    echo "  Feed      $feed_url"
elif [ "$dry_run" = 1 ]; then
    echo "  Probelauf: nichts hochgeladen."
else
    echo
    echo "Nichts hochgeladen. Zum Veröffentlichen: ${BASH_SOURCE[0]} --publish"
fi
