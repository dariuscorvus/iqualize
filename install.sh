#!/bin/bash
# Build iQualize and install to /Applications
set -e

cd "$(dirname "$0")"

# Pick a signing identity: an explicit IQ_SIGN_IDENTITY (release CI sets this
# to a Developer ID cert when configured), else a real Apple Development cert
# if one is installed, otherwise ad-hoc ("-"). Ad-hoc is fine for local dev —
# TCC keys on the cdhash, which stays stable across rebuilds when the binary is
# unchanged. It is NOT accepted by Gatekeeper on quarantined downloads (macOS
# reports "damaged"), so distributed DMGs still need the quarantine xattr
# stripped — see README.
# Previously this always passed "Apple Development"; when that cert is absent the
# codesign call failed silently and the app shipped with a broken signature.
if [ -n "${IQ_SIGN_IDENTITY:-}" ]; then
    SIGN_ID="$IQ_SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    SIGN_ID="Apple Development"
else
    SIGN_ID="-"
fi

# IQ_UNIVERSAL=1 builds both slices (Apple Silicon + Intel) — used for
# distributable DMGs (create-dmg.sh). Default dev builds stay native-only:
# the x86_64 slice roughly doubles compile time for nothing during iteration.
BUILD_FLAGS=(-c release)
if [ "${IQ_UNIVERSAL:-0}" = "1" ]; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
    echo "Building iQualize (universal: arm64 + x86_64)..."
else
    echo "Building iQualize..."
fi
swift build "${BUILD_FLAGS[@]}" 2>&1 | tail -5

APP=/Applications/iQualize.app
BIN="$APP/Contents/MacOS/iQualize"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
SRC="$BIN_PATH/iQualize"
CLI_SRC="$BIN_PATH/iqualize-cli"
CLI_BIN="$APP/Contents/Resources/bin/iqualize"
HELPER_SRC="$BIN_PATH/iQualizeCapture"
HELPER_BIN="$APP/Contents/Helpers/iQualizeCapture"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Helpers"

NEEDS_RESIGN=0

# Change detection: installed binaries never byte-match fresh build products,
# because signing rewrites them — the helper individually below, the main
# binary when the bundle seal is applied — so cmp against the installed copy
# always reports a change. Instead, compare each fresh product against the
# hash recorded at the previous install (build-hashes sidecar, sealed into the
# bundle). TCC does not depend on this skip: it pins the cdhash, which is
# deterministic when the product is unchanged and changes with any real code
# update regardless. What the skip buys is a truthful no-op — in particular it
# never rewrites the executable of a running app, which macOS punishes with
# SIGKILL.
HASHES="$APP/Contents/Resources/build-hashes"
hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
recorded() { grep "^$1=" "$HASHES" 2>/dev/null | cut -d= -f2; }
MAIN_HASH=$(hash_of "$SRC")
HELPER_HASH=$(hash_of "$HELPER_SRC")
CLI_HASH=$(hash_of "$CLI_SRC")

# Install + sign the capture helper FIRST (the main binary's enclosing
# signature covers the helper, so the helper must already be in place when
# we sign the main bundle below). It owns the CATap + aggregate IOProc in a
# separate process — see CONTINUITY.md. The explicit --identifier matters:
# without it, codesign derives one from the Mach-O UUID, which changes on
# every relink and would break a cert-based TCC grant across rebuilds.
if [ -f "$HELPER_BIN" ] && [ "$HELPER_HASH" = "$(recorded helper)" ]; then
    :
else
    cp -f "$HELPER_SRC" "$HELPER_BIN"
    codesign --force --sign "$SIGN_ID" --identifier com.iqualize.capture --entitlements iQualizeCapture.entitlements "$HELPER_BIN" && echo "Helper signed ($SIGN_ID)"
    NEEDS_RESIGN=1
    echo "Helper binary updated"
fi

if [ -f "$BIN" ] && [ "$MAIN_HASH" = "$(recorded main)" ]; then
    echo "Binary unchanged — skipping copy"
else
    cp -f "$SRC" "$BIN"
    NEEDS_RESIGN=1
    echo "Binary updated"
fi

# Bundle the CLI so it rides along in the DMG too (see Settings > "Install Command Line Tool")
if [ -f "$CLI_BIN" ] && [ "$CLI_HASH" = "$(recorded cli)" ]; then
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

# Stamp the build's git commit into the installed Info.plist (IQGitCommit) so
# the app can report it (iqualize status, About dialog). The source plist stays
# unstamped; the stamp goes into a temp copy that is compared against the
# installed plist — comparing the unstamped source directly would always differ
# and force a re-sign on every run. No git / no repo → no stamp, app omits it.
STAMPED_PLIST=$(mktemp)
cp Sources/iQualize/Info.plist "$STAMPED_PLIST"
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || true)
if [ -n "$GIT_COMMIT" ]; then
    git diff --quiet HEAD 2>/dev/null || GIT_COMMIT="${GIT_COMMIT}-dirty"
    /usr/libexec/PlistBuddy -c "Add :IQGitCommit string $GIT_COMMIT" "$STAMPED_PLIST"
fi

# Always update Info.plist — a plist change invalidates the signature too
if ! cmp -s "$STAMPED_PLIST" "$APP/Contents/Info.plist"; then
    NEEDS_RESIGN=1
fi
cp -f "$STAMPED_PLIST" "$APP/Contents/Info.plist"
rm -f "$STAMPED_PLIST"
# mktemp creates STAMPED_PLIST 0600, and cp inherits that mode when the
# destination doesn't already exist (first install on a fresh machine/CI
# runner) — this shipped in the v0.51.0 DMG and broke the system audio
# recording permission prompt for root-run installers (issue #142).
chmod 644 "$APP/Contents/Info.plist"

if [ "$NEEDS_RESIGN" = "1" ]; then
    # Record the pre-sign product hashes first so the sidecar is covered by
    # the bundle seal.
    printf 'helper=%s\nmain=%s\ncli=%s\n' "$HELPER_HASH" "$MAIN_HASH" "$CLI_HASH" > "$HASHES"
    # Sign the whole bundle after every resource is in place so the sealed
    # CodeResources is consistent (a partial/stale seal reads as "damaged").
    codesign --force --sign "$SIGN_ID" --entitlements iQualize.entitlements "$APP" && echo "Signed with: $SIGN_ID"
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
