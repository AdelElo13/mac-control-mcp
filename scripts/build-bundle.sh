#!/bin/bash
# Builds mac-control-mcp as a proper macOS .app bundle so macOS TCC can
# track it and grant Screen Recording / Accessibility permissions.
#
# Why a bundle? Unsigned CLI binaries don't show up in System Settings →
# Privacy & Security at all. Wrapping in an .app with a proper Info.plist
# + bundle identifier makes TCC treat it like a regular app: the user
# gets a consent prompt on first request, and can see/toggle the app in
# Privacy settings. Without this, CGRequestScreenCaptureAccess() fails
# silently with no prompt on macOS 15+.
#
# Install location: ~/Applications/MacControlMCP.app (user-local; no sudo).
# Bundle identifier: dev.macmcp.server (stable across builds so permission
# grants survive rebuilds).
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

BUNDLE_ID="dev.macmcp.server"
APP_NAME="MacControlMCP"
INSTALL_DIR="${HOME}/Applications"
APP_PATH="${INSTALL_DIR}/${APP_NAME}.app"

echo "[build-bundle] swift build (release)..."
swift build -c release --disable-sandbox

BIN="${PROJECT_ROOT}/.build/release/mac-control-mcp"
if [ ! -f "$BIN" ]; then
    echo "ERROR: binary not found at $BIN"
    exit 1
fi

echo "[build-bundle] assembling bundle at ${APP_PATH}..."
rm -rf "$APP_PATH"
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

# Copy binary in as the executable
cp "$BIN" "${APP_PATH}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_PATH}/Contents/MacOS/${APP_NAME}"

# Info.plist — minimum fields TCC needs to identify the app stably.
#   - CFBundleIdentifier: stable identity across rebuilds so TCC grants
#     persist. The TCC database keys off this + code signing identity.
#   - CFBundleExecutable: matches the binary we just copied.
#   - LSBackgroundOnly: it's a CLI / MCP server; no Dock icon, no menu.
#   - NSPrincipalClass + LSUIElement keep it quiet.
cat > "${APP_PATH}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>mac-control-mcp</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <!--
    These usage-description strings are MANDATORY for TCC prompts. Without
    them, CGRequestScreenCaptureAccess / AXIsProcessTrustedWithOptions
    silently deny rather than showing the consent dialog. The strings
    appear in the system prompt and in System Settings → Privacy entries.
    -->
    <key>NSScreenCaptureUsageDescription</key>
    <string>mac-control-mcp captures windows and the screen on behalf of the MCP client (Claude Code, etc) to let an AI agent see and analyse on-screen content.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>mac-control-mcp automates other apps (menus, browser JS, volume, dark mode) via AppleScript.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>mac-control-mcp reads and controls UI elements across all apps to let an AI agent drive macOS.</string>
</dict>
</plist>
EOF

# Entitlements — make intent explicit. Codesign will embed these.
ENT="${PROJECT_ROOT}/.build/macmcp.entitlements"
cat > "$ENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <false/>
    <key>com.apple.security.device.camera</key>
    <false/>
</dict>
</plist>
EOF

echo "[build-bundle] ad-hoc codesigning with entitlements..."
codesign --force --deep --sign - --entitlements "$ENT" "${APP_PATH}"

# Register with LaunchServices so TCC actually sees the new app.
LS_REGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
if [ -x "$LS_REGISTER" ]; then
    echo "[build-bundle] registering with LaunchServices..."
    "$LS_REGISTER" -f "${APP_PATH}"
fi

echo ""
echo "[build-bundle] DONE."
echo "  Bundle:       ${APP_PATH}"
echo "  Binary:       ${APP_PATH}/Contents/MacOS/${APP_NAME}"
echo "  Bundle ID:    ${BUNDLE_ID}"
echo ""
echo "Launch the server via:"
echo "  ${APP_PATH}/Contents/MacOS/${APP_NAME}"
echo ""
echo "First capture_window / capture_screen call will trigger a system"
echo "consent prompt. After granting, restart the server."
