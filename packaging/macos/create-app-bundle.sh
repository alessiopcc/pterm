#!/bin/bash
set -e

VERSION="${1:?Usage: create-app-bundle.sh VERSION}"

# Validate VERSION is a valid SemVer string to prevent shell injection
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?$ ]]; then
  echo "Invalid version: $VERSION" >&2; exit 1
fi
ARCH=$(uname -m | sed 's/arm64/arm64/;s/x86_64/x86_64/')
APP_DIR="PTerm.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Creating PTerm.app bundle (v${VERSION}, ${ARCH})..."

# Clean previous build
rm -rf "${APP_DIR}"

# Create directory structure
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy binary
cp zig-out/bin/pterm "${MACOS_DIR}/pterm"
chmod +x "${MACOS_DIR}/pterm"

# Create Info.plist
cat > "${CONTENTS_DIR}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.pterm.PTerm</string>
    <key>CFBundleName</key>
    <string>PTerm</string>
    <key>CFBundleDisplayName</key>
    <string>PTerm</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>pterm</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "PTerm.app bundle created."

# Create .dmg
echo "Creating .dmg installer..."
brew install create-dmg 2>/dev/null || true

DMG_NAME="pterm-${VERSION}-macos-${ARCH}.dmg"

create-dmg \
  --volname "PTerm ${VERSION}" \
  --app-drop-link 400 190 \
  --icon-size 100 \
  --no-internet-enable \
  "${DMG_NAME}" \
  "${APP_DIR}"

echo "Created ${DMG_NAME}"
