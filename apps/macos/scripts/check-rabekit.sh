#!/bin/bash
# check-rabekit.sh — `RabeKit` must not pull a UI toolkit into the core.
#
# M2.0, requirement 3: `Sources/RabeKit` may import Foundation, Observation, os,
# RabeBindings and UserNotifications — nothing else. No AppKit, SwiftUI, WebKit
# or UIKit. Requirement 8: this script fails when a forbidden import appears;
# `build-app.sh` runs it before the build.
#
# Exit codes: 0 = clean, 1 = at least one forbidden import.
# Usage: scripts/check-rabekit.sh [--quiet]

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$(cd "$here/.." && pwd)"
sources="$package/Sources/RabeKit"
quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1

if [ ! -d "$sources" ]; then
    echo "error: $sources is missing" >&2
    exit 1
fi

allowed=" Foundation Observation os RabeBindings UserNotifications "
violations=""
files=0
imports=0

while IFS= read -r file; do
    files=$((files + 1))
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        imports=$((imports + 1))
        module="$(printf '%s\n' "$hit" \
            | sed -E 's/.*import[[:space:]]+(struct |class |enum |protocol |typealias |func |var |let )?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*).*/\2/')"
        case "$allowed" in
            *" $module "*) ;;
            *) violations="${violations}${hit}"$'\n' ;;
        esac
    done < <(grep -nHE '^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*[[:space:]]+)*import[[:space:]]+[A-Za-z_]' "$file")
done < <(find "$sources" -name '*.swift' | sort)

# Belt and braces: a UIKit/AppKit symbol used through a re-exporting module
# (Foundation does not, but a future import might) is caught by the compiler;
# here we only look for the toolkits themselves appearing as an import.
import_count="$(find "$sources" -name '*.swift' -exec grep -hcE '^[[:space:]]*import[[:space:]]' {} + | awk '{s+=$1} END {print s+0}')"

if [ -n "$violations" ]; then
    echo "check-rabekit: forbidden import(s) in Sources/RabeKit" >&2
    printf '%s' "$violations" >&2
    echo >&2
    echo "allowed: Foundation, Observation, os, RabeBindings, UserNotifications" >&2
    echo "The Mac implementation belongs in Sources/Rabe (PlatformServices)." >&2
    exit 1
fi

if [ "$quiet" -eq 0 ]; then
    echo "check-rabekit: ok ($import_count imports in $files files, only Foundation/Observation/os/RabeBindings/UserNotifications)"
fi
exit 0
