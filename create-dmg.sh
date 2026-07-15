#!/bin/bash
# Build iQualize and create a distributable DMG installer
set -e

cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/iQualize/Info.plist)
DMG_NAME="iQualize-${VERSION}.dmg"
DMG_VOLUME="iQualize"

echo "=== Building iQualize v${VERSION} ==="
bash install.sh

echo "=== Creating DMG ==="

STAGING=.build/dmg-staging
TMP_DMG=.build/tmp-rw.dmg

# Clean previous staging
rm -rf "$STAGING" "$TMP_DMG" "$DMG_NAME"
mkdir -p "$STAGING"

# Copy app bundle from /Applications
cp -R /Applications/iQualize.app "$STAGING/"

# Create Applications symlink (the drag target)
ln -s /Applications "$STAGING/Applications"

# Create writable DMG
hdiutil create -volname "$DMG_VOLUME" -srcfolder "$STAGING" \
    -ov -format UDRW -fs HFS+ "$TMP_DMG"

# Mount it to configure window appearance
DEVICE=$(hdiutil attach -readwrite -noverify "$TMP_DMG" | grep "Apple_HFS" | awk '{print $1}')
MOUNT_POINT="/Volumes/$DMG_VOLUME"

# Configure Finder window: icon positions, size, view options
osascript <<EOF
tell application "Finder"
    tell disk "$DMG_VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 200, 780, 540}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "iQualize.app" of container window to {140, 170}
        set position of item "Applications" of container window to {440, 170}
        update without registering applications
        close
    end tell
end tell
EOF

# Flush and detach
sync
hdiutil detach "$DEVICE"

# Convert to compressed read-only DMG
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"

# Clean up
rm -rf "$STAGING" "$TMP_DMG"

echo ""
echo "=== Verifying DMG ==="
# Gate the build on a valid signature so a "damaged" DMG (issue #115) can never
# be produced. set -e aborts create-dmg.sh if this fails.
bash "$(dirname "$0")/verify-dmg.sh" "$DMG_NAME"

echo ""
echo "=== Done: $DMG_NAME ==="
ls -lh "$DMG_NAME"
