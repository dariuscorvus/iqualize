#!/bin/bash
# Verify a built DMG is safe to release.
#
# The failure this guards against is issue #115: an app signed against a
# certificate that isn't on the build machine ends up with a broken/inconsistent
# code signature, which macOS reports to users as "iQualize is damaged and can't
# be opened." `codesign --verify` catches exactly that state, so this runs it on
# the app inside the image before any release.
#
# Note: this deliberately does NOT run `spctl`. The app is ad-hoc signed, not
# notarized, so Gatekeeper (spctl) rejects it by design — gating on spctl would
# fail every legitimate build. A valid ad-hoc signature is the bar here; users
# still strip the quarantine xattr per the README.
#
# Exit status: 0 = OK, non-zero = do not release.
set -euo pipefail

DMG="${1:?usage: verify-dmg.sh <path-to-dmg>}"
if [ ! -f "$DMG" ]; then
    echo "verify-dmg: FAIL — no such file: $DMG" >&2
    exit 1
fi

echo "verify-dmg: checking $DMG"

# 1) Disk image integrity.
if ! hdiutil verify "$DMG" >/dev/null 2>&1; then
    echo "verify-dmg: FAIL — disk image checksum is invalid" >&2
    exit 1
fi

# 2) Mount read-only in a private mountpoint (no Finder window).
MOUNT="$(mktemp -d)"
cleanup() {
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null

APP="$MOUNT/iQualize.app"
if [ ! -d "$APP" ]; then
    echo "verify-dmg: FAIL — iQualize.app not found in the image" >&2
    exit 1
fi

# 3) The signature must be valid and consistent — the "damaged" check.
if ! codesign --verify --deep --strict --verbose=2 "$APP" 2>&1; then
    echo "verify-dmg: FAIL — app signature is invalid; macOS would report this as \"damaged\"" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "verify-dmg: OK — iQualize.app v${VERSION}, signature valid, image intact"
