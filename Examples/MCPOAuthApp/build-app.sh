#!/bin/bash
# Build script for MCP OAuth Test App
#
# This script builds the MCPOAuthApp executable and packages it as a macOS app bundle
# with the necessary Info.plist for URL scheme handling.
#
# Usage:
#   ./build-app.sh
#   ./build-app.sh --install  # Also copy to /Applications
#   ./build-app.sh --run      # Build and run

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_NAME="MCP OAuth Test"
BUNDLE_ID="com.yrden.mcp-oauth-test"
SCHEME="yrden-mcp-oauth"

# Build the executable (use --product to ensure linking)
echo "Building MCPOAuthApp..."
cd "$PROJECT_ROOT"
swift build --product MCPOAuthApp -c release

# Find the built executable in the release directory
EXECUTABLE="$PROJECT_ROOT/.build/arm64-apple-macosx/release/MCPOAuthApp"

# Fallback: search if not at expected location
if [ ! -f "$EXECUTABLE" ]; then
    EXECUTABLE=$(find "$PROJECT_ROOT/.build" -path "*release/MCPOAuthApp" -type f 2>/dev/null | grep -v ".dSYM" | head -1)
fi

if [ -z "$EXECUTABLE" ] || [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Could not find built executable"
    echo "Searched in: $PROJECT_ROOT/.build"
    exit 1
fi

echo "Found executable: $EXECUTABLE"

# Create app bundle
APP_DIR="$PROJECT_ROOT/.build/MCPOAuthTest.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Creating app bundle at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
cp "$EXECUTABLE" "$MACOS_DIR/MCPOAuthApp"
chmod +x "$MACOS_DIR/MCPOAuthApp"

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MCPOAuthApp</string>
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
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>MCP OAuth Callback</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>$SCHEME</string>
            </array>
        </dict>
    </array>
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
echo "URL Scheme: $SCHEME://"
echo "================================================"
echo ""

# Handle command line options
case "$1" in
    --install)
        echo "Installing to /Applications..."
        rm -rf "/Applications/MCPOAuthTest.app"
        cp -R "$APP_DIR" "/Applications/"
        echo "Installed to /Applications/MCPOAuthTest.app"
        echo ""
        echo "IMPORTANT: Run the app once from Finder to register the URL scheme!"
        ;;
    --run)
        echo "Launching app..."
        open "$APP_DIR"
        ;;
    *)
        echo "Usage:"
        echo "  ./build-app.sh           # Just build"
        echo "  ./build-app.sh --install # Build and install to /Applications"
        echo "  ./build-app.sh --run     # Build and run"
        echo ""
        echo "To run manually:"
        echo "  open $APP_DIR"
        ;;
esac

echo ""
echo "Done!"
