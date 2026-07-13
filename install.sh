#!/bin/bash
# Build iQualize and install to /Applications
set -e

cd "$(dirname "$0")"

echo "Building iQualize..."
swift build -c release 2>&1 | tail -5

APP=/Applications/iQualize.app
BIN="$APP/Contents/MacOS/iQualize"
BIN_PATH="$(swift build -c release --show-bin-path)"
SRC="$BIN_PATH/iQualize"
CLI_SRC="$BIN_PATH/iqualize-cli"
CLI_BIN="$APP/Contents/Resources/bin/iqualize"
HELPER_SRC="$BIN_PATH/iQualizeCapture"
HELPER_BIN="$APP/Contents/Helpers/iQualizeCapture"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Helpers"

NEEDS_RESIGN=0

# Install + sign the capture helper FIRST (the main binary's enclosing
# signature covers the helper, so the helper must already be in place when
# we sign the main bundle below). It owns the CATap + aggregate IOProc in a
# separate process — see CONTINUITY.md.
if [ -f "$HELPER_BIN" ] && cmp -s "$HELPER_SRC" "$HELPER_BIN"; then
    :
else
    cp -f "$HELPER_SRC" "$HELPER_BIN"
    codesign --force --sign "Apple Development" --entitlements iQualizeCapture.entitlements "$HELPER_BIN" 2>/dev/null && echo "Helper signed"
    NEEDS_RESIGN=1
    echo "Helper binary updated"
fi

# Only replace binary if it actually changed — preserves TCC permissions (cdhash stays the same)
if [ -f "$BIN" ] && cmp -s "$SRC" "$BIN"; then
    echo "Binary unchanged — skipping copy (TCC permissions preserved)"
else
    cp -f "$SRC" "$BIN"
    NEEDS_RESIGN=1
    echo "Binary updated"
fi

# Bundle the CLI so it rides along in the DMG too (see Settings > "Install Command Line Tool")
if [ -f "$CLI_BIN" ] && cmp -s "$CLI_SRC" "$CLI_BIN"; then
    :
else
    cp -f "$CLI_SRC" "$CLI_BIN"
    chmod +x "$CLI_BIN"
    NEEDS_RESIGN=1
    echo "CLI binary updated"
fi

# Copy app icon
cp -f Sources/iQualize/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Copy README so the in-app Help window can render the Features section
cp -f README.md "$APP/Contents/Resources/README.md"

# Always update Info.plist — a plist change invalidates the signature too
if ! cmp -s Sources/iQualize/Info.plist "$APP/Contents/Info.plist"; then
    cp -f Sources/iQualize/Info.plist "$APP/Contents/Info.plist"
    NEEDS_RESIGN=1
else
    cp -f Sources/iQualize/Info.plist "$APP/Contents/Info.plist"
fi

if [ "$NEEDS_RESIGN" = "1" ]; then
    SIGN_ID="Apple Development"
    codesign --force --sign "$SIGN_ID" --entitlements iQualize.entitlements "$APP" 2>/dev/null && echo "Signed with: $SIGN_ID"
fi

# Strip provenance xattr to prevent macOS security policy launch blocks
xattr -rc "$APP" 2>/dev/null

echo "Installed to /Applications/iQualize.app"

# Best-effort dev convenience — symlink the CLI onto PATH. Not fatal if /usr/local/bin
# isn't writable; Settings > "Install Command Line Tool" covers end users.
if ln -sf "$CLI_BIN" /usr/local/bin/iqualize 2>/dev/null; then
    echo "Symlinked CLI to /usr/local/bin/iqualize"
else
    echo "Note: couldn't symlink CLI to /usr/local/bin (try: sudo ln -sf '$CLI_BIN' /usr/local/bin/iqualize)"
fi
