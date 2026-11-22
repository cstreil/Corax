#!/bin/bash
# Build the app bundle (`Corax.app`) without Xcode.
#
#   Rust staticlib -> UniFFI Swift bindings -> swift build -> .app bundle -> codesign
#
# Usage: sh apps/macos/scripts/build-app.sh
#
# The Rust side is built with the workspace release profile (LTO), so the first
# run takes a while; later runs only relink what changed.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$(cd "$here/.." && pwd)"
root="$(cd "$package/../.." && pwd)"
tauri="$root/src-tauri"
target="$tauri/target/release"
generated="$package/Generated"
# M3.1: Name und Kennung stehen nur hier im Skript (der Swift-Code liest
# dieselben Werte aus `Sources/CoraxKit/Support/AppIdentity.swift`; der Test
# `M31IdentityTests` vergleicht beide Seiten, damit sie nicht auseinanderlaufen).
APP_NAME="Corax"
BUNDLE_ID="com.coraxapp.corax"

# Ablage des Bundles: standardmäßig `apps/macos/build` (das Release-Bundle des
# Nutzers). Für einen Probelauf woandershin: CORAX_BUILD_DIR=/tmp/…
build_dir="${CORAX_BUILD_DIR:-$package/build}"
app="$build_dir/$APP_NAME.app"

# M3.2: Version und Build aus apps/macos/VERSION (Zeile 1 Version, Zeile 2
# Build-Nummer), Update-Quelle und Schlüssel aus der Umgebung. release.sh setzt
# diese Variablen; ein normaler Entwicklungsbau lässt Feed und Schlüssel leer
# und bekommt damit keinen laufenden Updater.
version="$(sed -n '1p' "$package/VERSION" 2>/dev/null | tr -d '[:space:]')"
build_number="$(sed -n '2p' "$package/VERSION" 2>/dev/null | tr -d '[:space:]')"
: "${version:=0.0.1}"
: "${build_number:=1}"
feed_url="${CORAX_FEED_URL:-}"
public_key="${CORAX_PUBLIC_ED_KEY:-}"

# Both halves must agree on the minimum system version, otherwise `ld` warns
# that the Rust objects were built for a newer macOS than the bundle targets.
export MACOSX_DEPLOYMENT_TARGET=27.0

echo "==> toolchain: $(xcode-select -p 2>/dev/null || echo 'no developer dir')"

# CoraxKit must stay free of AppKit/SwiftUI/WebKit/UIKit (M2.0, requirement 8).
"$here/check-coraxkit.sh"
echo "==> cargo build --release -p corax-uniffi (MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET)"
cargo build --manifest-path "$tauri/Cargo.toml" --release -p corax-uniffi

library="$target/libcorax_uniffi.a"
bindgen="$target/uniffi-bindgen"
[ -f "$library" ] || { echo "error: missing $library" >&2; exit 1; }
[ -x "$bindgen" ] || { echo "error: missing $bindgen" >&2; exit 1; }

echo "==> uniffi-bindgen (library mode)"
rm -rf "$generated"
mkdir -p "$generated/swift" "$generated/ffi/include" "$generated/raw"
# The bindgen reads `cargo metadata` to find the crate's uniffi.toml, so it has
# to run inside the workspace.
(
    cd "$tauri"
    "$bindgen" generate \
        --library "$library" \
        --language swift \
        --out-dir "$generated/raw" \
        --no-format
)

mv "$generated/raw/CoraxBindings.swift" "$generated/swift/"
mv "$generated/raw/CoraxFFI.h" "$generated/ffi/include/"
mv "$generated/raw/CoraxFFI.modulemap" "$generated/ffi/include/module.modulemap"
rmdir "$generated/raw"

# SwiftPM expects a compiled object for a C target; the module itself is
# headers only, so one empty translation unit keeps the linker happy.
cat > "$generated/ffi/CoraxFFI.c" <<'C'
#include "CoraxFFI.h"

void corax_ffi_module_anchor(void) {}
C

# CORAX_TEST_HOOKS=1 compiles the test hooks (CORAX_DEBUG_AUTOMATION,
# CORAX_REMOTE_IMAGES) into the release build, for walkthrough.sh. Default: off.
swift_flags=()
if [ "${CORAX_TEST_HOOKS:-0}" = "1" ]; then
    swift_flags=(-Xswiftc -DCORAX_TEST_HOOKS)
    echo "==> test hooks enabled (CORAX_TEST_HOOKS=1)"
fi

echo "==> swift build -c release"
mkdir -p "$build_dir"
build_log="$build_dir/swift-build.log"
# `--disable-sandbox`: SwiftPM übersetzt das Manifest jeder Abhängigkeit in
# einem eigenen `sandbox-exec`. Seit Sparkle dazukommt, muss das auch auf einem
# warmen Bauweg laufen; in eingeschränkten Umgebungen (CI, Agenten-Sitzung)
# scheitert `sandbox_apply` dort. Für den normalen Bau ändert der Schalter
# nichts, er betrifft nur SwiftPMs eigenes Sandboxing der Manifest-Übersetzung.
if ! swift build -c release --disable-sandbox ${swift_flags[@]+"${swift_flags[@]}"} --package-path "$package" 2>&1 | tee "$build_log"; then
    echo "error: swift build failed (see $build_log)" >&2
    exit 1
fi

# The linker warns when an input object was built for a newer macOS than the
# target. Our own crates build for $MACOSX_DEPLOYMENT_TARGET; anything left over
# comes from the prebuilt Rust standard library of the installed toolchain.
version_warnings=$(grep -c "was built for newer" "$build_log" || true)
if [ "${version_warnings:-0}" -gt 0 ]; then
    echo
    echo "note: $version_warnings linker version warning(s) remain."
    echo "      These objects ship inside the installed Rust toolchain:"
    echo "      $(grep -o "libcorax_uniffi.a\[[0-9]*\]([^)]*)" "$build_log" | sed -n '1,3p' | tr '\n' ' ')"
    echo "      $(grep -o "built for newer 'macOS' version ([0-9.]*)" "$build_log" | sort -u | tr '\n' ' ')"
    echo "      Cause: the prebuilt std of $(rustc --version 2>/dev/null | cut -d' ' -f1-2) is built for that version."
    echo "      Fix: LSMinimumSystemVersion to the same version, or a toolchain whose std is built for 26.0."
    echo
fi
bin_path="$(swift build -c release --disable-sandbox ${swift_flags[@]+"${swift_flags[@]}"} --package-path "$package" --show-bin-path)"
executable="$bin_path/Corax"
[ -x "$executable" ] || { echo "error: no executable at $executable" >&2; exit 1; }

# M3.3: Siri und Kurzbefehle brauchen `Metadata.appintents` im Bundle; SwiftPM
# erzeugt die Datei nicht selbst, deshalb läuft Apples Metadaten-Prozessor hier.
# Fehlt das Ergebnis, bricht der Bau ab — ohne die Datei böte das System keinen
# einzigen Intent an.
echo "==> app intents metadata"
meta_out="$generated/appintents"
rm -rf "$meta_out"
mkdir -p "$meta_out"
intents_src="$package/Sources/CoraxIntents"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
processor="$(xcrun --sdk macosx --find appintentsmetadataprocessor)"
swiftc_path="$(xcrun --sdk macosx --find swiftc)"
# Dieselbe Ableitung wie in `src-tauri/build.rs`: das Verzeichnis der Toolchain
# ist drei Ebenen über `swiftc`.
toolchain_dir="$(dirname "$(dirname "$(dirname "$swiftc_path")")")"
xcode_build="$(xcodebuild -version 2>/dev/null | awk '/^Build version/ {print $3}')"
target_arch="$(uname -m)"
find "$intents_src" -name '*.swift' | sort > "$meta_out/sources.txt"
# SwiftPM (Xcode-Backend) übersetzt das Manifest der Intents-Ziele bereits mit
# `-emit-const-values-path` und `-const-gather-protocols-file`; die Datei liegt
# bei den Zwischenergebnissen und wird hier wiederverwendet, statt die Quellen
# ein zweites Mal zu übersetzen. Fehlt sie, läuft der Prozessor ohne.
const_values="$(find "$bin_path/../.." -name 'CoraxIntents-*.swiftconstvalues' -type f -print 2>/dev/null | head -1)"
: > "$meta_out/constvalues.txt"
if [ -n "$const_values" ]; then
    echo "$const_values" > "$meta_out/constvalues.txt"
    echo "      const values: $const_values"
fi
"$processor" \
    --output "$meta_out" \
    --toolchain-dir "$toolchain_dir" \
    --module-name CoraxIntents \
    --sdk-root "$sdk_path" \
    --xcode-version "$xcode_build" \
    --platform-family macOS \
    --deployment-target "$MACOSX_DEPLOYMENT_TARGET" \
    --target-triple "$target_arch-apple-macosx$MACOSX_DEPLOYMENT_TARGET" \
    --source-file-list "$meta_out/sources.txt" \
    --swift-const-vals-list "$meta_out/constvalues.txt" \
    --no-app-shortcuts-localization \
    --force
[ -f "$meta_out/Metadata.appintents/extract.actionsdata" ] || {
    echo "error: appintentsmetadataprocessor produced no Metadata.appintents" >&2
    exit 1
}

echo "==> assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$executable" "$app/Contents/MacOS/Corax"
ditto --norsrc "$meta_out/Metadata.appintents" "$app/Contents/Resources/Metadata.appintents"
# M3.2: Sparkle.framework mit ins Bundle; der Linker sucht es zur Laufzeit
# unter Contents/Frameworks (@executable_path/../Frameworks).
if [ -d "$bin_path/Sparkle.framework" ]; then
    mkdir -p "$app/Contents/Frameworks"
    ditto --norsrc "$bin_path/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
fi
cp "$root/src-tauri/icons/icon.icns" "$app/Contents/Resources/icon.icns"
printf 'APPL????' > "$app/Contents/PkgInfo"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>Corax</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleIconFile</key>
	<string>icon</string>
	<!-- M3.3: die Kurzbefehl-Sätze sind deutsch; ohne diese Zeile ordnet Siri
	     sie keiner Sprache zu (es gibt keine Lokalisierungsdateien). -->
	<key>CFBundleDevelopmentRegion</key>
	<string>de</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>27.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<!-- M2.4: the bundle handles mailto: (RFC 6068), so macOS may hand the
	     app such a URL (Ai: "Neue Mail" from another app). Registering the
	     scheme does NOT make Corax the default mail app — that is a choice in
	     Mail's settings. LSHandlerRank Alternate keeps the app out of the way
	     for anyone who did not pick it. -->
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>${BUNDLE_ID}.mailto</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>mailto</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

# M3.2: Version, Build und Update-Werte aus den Variablen oben.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
if [ -n "$feed_url" ] && [ -n "$public_key" ]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $feed_url" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $public_key" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$app/Contents/Info.plist"
    echo "==> updater: feed=$feed_url version=$version ($build_number)"
else
    echo "==> updater: aus (kein Feed/Schlüssel — Entwicklungsbau)"
fi

# Mark hook builds inside the bundle (W5): the release for the user must not
# carry the debug notification hooks.
if [ "${CORAX_TEST_HOOKS:-0}" = "1" ]; then
    /usr/libexec/PlistBuddy -c "Add :CoraxTestHooks bool true" "$app/Contents/Info.plist"
fi

echo "==> codesign"
# iCloud/Finder leave `com.apple.FinderInfo` and fileprovider xattrs on the
# freshly written bundle; codesign refuses those ("detritus not allowed").
# iCloud can put them back between the cleanup and the signing, so retry.
#
# Inside iCloud Drive the file provider re-adds them within a second, so the
# in-place attempt can never win there (M2.8b: the bundle ended up unsigned and
# without `_CodeSignature`). In that case sign a copy in a scratch directory
# outside iCloud and copy it back with `ditto`, then verify at the real path.
identity="${CORAX_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk 'NR==1 {print $2}')}"
if [ -z "${identity:-}" ]; then
    echo "error: no codesigning identity; set CORAX_SIGN_IDENTITY" >&2
    exit 1
fi

# sign_bundle <bundle>: up to three attempts; on failure the last codesign
# error goes to stderr, so the caller can explain what happened.
sign_bundle() {
    bundle="$1"
    attempt=0
    err="$(mktemp "${TMPDIR:-/tmp}/corax-codesign.XXXXXX")"
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        xattr -cr "$bundle" 2>/dev/null || true
        if codesign --force --timestamp=none --sign "$identity" \
            --identifier "$BUNDLE_ID" "$bundle" 2>"$err"; then
            rm -f "$err"
            return 0
        fi
        if [ "$attempt" -lt 3 ]; then
            echo "note: codesign left bundle detritus behind, retrying ($attempt/3)"
            sleep 1
        fi
    done
    cat "$err" >&2
    rm -f "$err"
    return 1
}

if sign_bundle "$app"; then
    codesign --verify --verbose=2 "$app"
else
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/corax-sign.XXXXXX")"
    echo "note: signing in place failed (iCloud keeps FinderInfo on the bundle root);"
    echo "      signing a copy in $scratch and copying it back."
    ditto --norsrc "$app" "$scratch/$APP_NAME.app"
    if ! sign_bundle "$scratch/$APP_NAME.app"; then
        echo "error: codesign failed in the scratch copy as well" >&2
        exit 1
    fi
    codesign --verify --verbose=2 "$scratch/$APP_NAME.app"
    rm -rf "$app"
    ditto --norsrc "$scratch/$APP_NAME.app" "$app"
    rm -rf "$scratch"
    xattr -cr "$app" 2>/dev/null || true
    codesign --verify --verbose=2 "$app"
    echo "note: bundle signed. iCloud sets com.apple.FinderInfo back on the bundle root,"
    echo "      so \`codesign --verify --strict\` reports detritus there; plain"
    echo "      \`codesign -v\`, which the release check uses, stays clean."
fi

echo
echo "built: $app"
echo "start: open -a \"$app\""
if [ "${CORAX_TEST_HOOKS:-0}" = "1" ]; then
    echo
    echo "WARNING: this bundle contains the test hooks (CORAX_TEST_HOOKS=1)."
    echo "         Build without the flag before handing it to the user or copying it to /Applications."
fi
