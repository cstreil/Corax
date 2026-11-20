#!/bin/bash
# Build "Rabe Native.app" without Xcode.
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
app="$package/build/Rabe Native.app"

# Both halves must agree on the minimum system version, otherwise `ld` warns
# that the Rust objects were built for a newer macOS than the bundle targets.
export MACOSX_DEPLOYMENT_TARGET=27.0

echo "==> toolchain: $(xcode-select -p 2>/dev/null || echo 'no developer dir')"

# RabeKit must stay free of AppKit/SwiftUI/WebKit/UIKit (M2.0, requirement 8).
"$here/check-rabekit.sh"
echo "==> cargo build --release -p rabe-uniffi (MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET)"
cargo build --manifest-path "$tauri/Cargo.toml" --release -p rabe-uniffi

library="$target/librabe_uniffi.a"
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

mv "$generated/raw/RabeBindings.swift" "$generated/swift/"
mv "$generated/raw/RabeFFI.h" "$generated/ffi/include/"
mv "$generated/raw/RabeFFI.modulemap" "$generated/ffi/include/module.modulemap"
rmdir "$generated/raw"

# SwiftPM expects a compiled object for a C target; the module itself is
# headers only, so one empty translation unit keeps the linker happy.
cat > "$generated/ffi/RabeFFI.c" <<'C'
#include "RabeFFI.h"

void rabe_ffi_module_anchor(void) {}
C

# RABE_TEST_HOOKS=1 compiles the test hooks (RABE_DEBUG_AUTOMATION,
# RABE_REMOTE_IMAGES) into the release build, for walkthrough.sh. Default: off.
swift_flags=()
if [ "${RABE_TEST_HOOKS:-0}" = "1" ]; then
    swift_flags=(-Xswiftc -DRABE_TEST_HOOKS)
    echo "==> test hooks enabled (RABE_TEST_HOOKS=1)"
fi

echo "==> swift build -c release"
mkdir -p "$package/build"
build_log="$package/build/swift-build.log"
if ! swift build -c release ${swift_flags[@]+"${swift_flags[@]}"} --package-path "$package" 2>&1 | tee "$build_log"; then
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
    echo "      $(grep -o "librabe_uniffi.a\[[0-9]*\]([^)]*)" "$build_log" | sed -n '1,3p' | tr '\n' ' ')"
    echo "      $(grep -o "built for newer 'macOS' version ([0-9.]*)" "$build_log" | sort -u | tr '\n' ' ')"
    echo "      Cause: the prebuilt std of $(rustc --version 2>/dev/null | cut -d' ' -f1-2) is built for that version."
    echo "      Fix: LSMinimumSystemVersion to the same version, or a toolchain whose std is built for 26.0."
    echo
fi
bin_path="$(swift build -c release ${swift_flags[@]+"${swift_flags[@]}"} --package-path "$package" --show-bin-path)"
executable="$bin_path/Rabe"
[ -x "$executable" ] || { echo "error: no executable at $executable" >&2; exit 1; }

echo "==> assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$executable" "$app/Contents/MacOS/Rabe"
cp "$root/src-tauri/icons/icon.icns" "$app/Contents/Resources/icon.icns"
printf 'APPL????' > "$app/Contents/PkgInfo"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Rabe Native</string>
	<key>CFBundleDisplayName</key>
	<string>Rabe Native</string>
	<key>CFBundleExecutable</key>
	<string>Rabe</string>
	<key>CFBundleIdentifier</key>
	<string>de.streil.rabe.native</string>
	<key>CFBundleIconFile</key>
	<string>icon</string>
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
	<!-- M2.4: the bundle handles `mailto:` (RFC 6068), so macOS may hand the
	     app such a URL (Ai: "Neue Mail" from another app). Registering the
	     scheme does NOT make Rabe the default mail app — that is a choice in
	     Mail's settings. LSHandlerRank Alternate keeps the app out of the way
	     for anyone who did not pick it. -->
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>de.streil.rabe.native.mailto</string>
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

# Mark hook builds inside the bundle (W5): the release for the user must not
# carry the debug notification hooks.
if [ "${RABE_TEST_HOOKS:-0}" = "1" ]; then
    /usr/libexec/PlistBuddy -c "Add :RabeTestHooks bool true" "$app/Contents/Info.plist"
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
identity="${RABE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk 'NR==1 {print $2}')}"
if [ -z "${identity:-}" ]; then
    echo "error: no codesigning identity; set RABE_SIGN_IDENTITY" >&2
    exit 1
fi

# sign_bundle <bundle>: up to three attempts; on failure the last codesign
# error goes to stderr, so the caller can explain what happened.
sign_bundle() {
    bundle="$1"
    attempt=0
    err="$(mktemp "${TMPDIR:-/tmp}/rabe-codesign.XXXXXX")"
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        xattr -cr "$bundle" 2>/dev/null || true
        if codesign --force --timestamp=none --sign "$identity" \
            --identifier de.streil.rabe.native "$bundle" 2>"$err"; then
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
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/rabe-sign.XXXXXX")"
    echo "note: signing in place failed (iCloud keeps FinderInfo on the bundle root);"
    echo "      signing a copy in $scratch and copying it back."
    ditto --norsrc "$app" "$scratch/Rabe Native.app"
    if ! sign_bundle "$scratch/Rabe Native.app"; then
        echo "error: codesign failed in the scratch copy as well" >&2
        exit 1
    fi
    codesign --verify --verbose=2 "$scratch/Rabe Native.app"
    rm -rf "$app"
    ditto --norsrc "$scratch/Rabe Native.app" "$app"
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
if [ "${RABE_TEST_HOOKS:-0}" = "1" ]; then
    echo
    echo "WARNING: this bundle contains the test hooks (RABE_TEST_HOOKS=1)."
    echo "         Build without the flag before handing it to the user or copying it to /Applications."
fi
