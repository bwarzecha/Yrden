#!/bin/bash
# Build script for Yrden Example App
#
# Usage:
#   ./build-app.sh           # Just build
#   ./build-app.sh --run     # Build and run

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_NAME="Yrden Example"
BUNDLE_ID="com.yrden.example"

# Build the executable
echo "Building YrdenExample..."
cd "$PROJECT_ROOT"
swift build --product YrdenExample -c release

# Find the built executable
EXECUTABLE="$PROJECT_ROOT/.build/arm64-apple-macosx/release/YrdenExample"

if [ ! -f "$EXECUTABLE" ]; then
    EXECUTABLE=$(find "$PROJECT_ROOT/.build" -path "*release/YrdenExample" -type f 2>/dev/null | grep -v ".dSYM" | head -1)
fi

if [ -z "$EXECUTABLE" ] || [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Could not find built executable"
    exit 1
fi

echo "Found executable: $EXECUTABLE"

# Create app bundle
APP_DIR="$PROJECT_ROOT/.build/YrdenExample.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Creating app bundle at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
cp "$EXECUTABLE" "$MACOS_DIR/YrdenExample"
chmod +x "$MACOS_DIR/YrdenExample"

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>YrdenExample</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

echo ""
echo "================================================"
echo "App bundle created: $APP_DIR"
echo "================================================"

# Handle options
case "$1" in
    --run)
        echo "Launching app..."
        open "$APP_DIR"
        ;;
    *)
        echo ""
        echo "To run: open $APP_DIR"
        echo "Or: ./build-app.sh --run"
        ;;
esac

echo "Done!"
