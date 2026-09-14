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
# Bundle identifier: dev.macmcp.server (stable name).
#
# CAVEAT — TCC grants and ad-hoc signing (Codex v10 HIGH):
# macOS keys Screen Recording / Accessibility grants on the code's
# "designated requirement". For ad-hoc signed binaries (codesign --sign -)
# that requirement is cdhash-based, which changes every time the
# executable content changes. So: after rebuilding, the user typically
# has to re-grant permission. We cannot honestly claim the grant
# persists across rebuilds with ad-hoc signing alone — a Developer ID
# certificate would, but that needs an Apple Developer account.
#
# Workflow recommendation:
#   - develop: rebuild freely; re-grant on first capture after each build
#   - ship:    sign with a Developer ID cert + notarise for persistent grants
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

BUNDLE_ID="dev.macmcp.server"
APP_NAME="MacControlMCP"
INSTALL_DIR="${HOME}/Applications"
APP_PATH="${INSTALL_DIR}/${APP_NAME}.app"

echo "[build-bundle] swift build (release) — arm64 + x86_64..."
# Build both slices so the shipped .app is universal and runs on Intel
# Macs without emulation. We do two separate release builds (one per
# triple) and lipo them together. Swift Package Manager doesn't have a
# single-shot "universal" flag, so this is the standard pattern.
swift build -c release --disable-sandbox --arch arm64 --arch x86_64

BIN="${PROJECT_ROOT}/.build/apple/Products/Release/mac-control-mcp"
# Fallback for older SwiftPM versions that don't write to the
# multi-arch path.
if [ ! -f "$BIN" ]; then
    BIN="${PROJECT_ROOT}/.build/release/mac-control-mcp"
fi
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

# Copy app icon if present in assets/icons/AppIcon.icns. Bundle is still
# usable without it (Finder shows the generic .app icon), so this is a
# soft requirement.
ICON_SRC="${PROJECT_ROOT}/assets/icons/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "${APP_PATH}/Contents/Resources/AppIcon.icns"
fi

# Info.plist + entitlements live in scripts/bundle/ (checked in) so tests
# and CI can verify them without running this script. See the comments in
# those files for why each key exists.
BUNDLE_SRC="${PROJECT_ROOT}/scripts/bundle"
sed "s/__VERSION__/${VERSION:-0.9.0}/" "${BUNDLE_SRC}/Info.plist" > "${APP_PATH}/Contents/Info.plist"
plutil -lint "${APP_PATH}/Contents/Info.plist" >/dev/null
# Hardened-runtime resource entitlements. Under `--options runtime` TCC
# denies a resource WITHOUT prompting when the responsible process lacks
# the entitlement. With Claude Desktop (`disclaimer`) MacControlMCP.app is
# the responsible process, so these decide; with ChatGPT.app the client's
# own entitlements apply — which is why v0.8.2 worked there and not here.
#   apple-events          AppleScript: browser, Reminders, Mail, Messages, menus
#   device.audio-input    audio_record (AVAudioRecorder), speech_to_text
#   calendars             calendar_list_events / calendar_create_event (EventKit)
#   addressbook           contacts_search (CNContactStore)
#   location              wifi_scan SSIDs (CoreWLAN gates SSIDs on Location)
# NO XML comments in that file: AMFI's entitlement parser rejects them
# ("AMFIUnserializeXML: syntax error") and the app ends up with none.
ENT="${BUNDLE_SRC}/MacControlMCP.entitlements"
plutil -lint "$ENT" >/dev/null


# Codesigning strategy: prefer Developer ID Application (enables
# persistent TCC grants + Gatekeeper accepts the binary on other Macs +
# can be notarised), fall back to ad-hoc for local dev when no
# Developer ID cert is installed.
#
# Override either:
#   - SIGNING_IDENTITY env: pass the exact SHA-1 or "Developer ID Application: …"
#   - NOTARIZE_PROFILE env: name of a `xcrun notarytool store-credentials` profile
#     (if set AND signing is Developer ID, we submit + staple after signing)
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    SIGN_WITH="$SIGNING_IDENTITY"
    SIGN_LABEL="override ($SIGNING_IDENTITY)"
elif DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/ {print $2; exit}'); [ -n "$DEV_ID" ]; then
    SIGN_WITH="$DEV_ID"
    SIGN_LABEL="Developer ID ($DEV_ID)"
else
    SIGN_WITH="-"
    SIGN_LABEL="ad-hoc (no Developer ID cert found)"
fi

echo "[build-bundle] codesigning: $SIGN_LABEL ..."
codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_WITH" --entitlements "$ENT" "${APP_PATH}"

# Refuse to ship a bundle whose signed entitlements don't cover its usage
# descriptions — v0.8.2 shipped without calendars/addressbook/audio-input
# and TCC denied those silently whenever the .app was the responsible process.
echo "[build-bundle] verifying signed entitlements vs Info.plist..."
"${PROJECT_ROOT}/scripts/check-entitlements.sh" "${APP_PATH}"

# Notarise + staple if a Developer ID was used AND a notarytool profile
# was passed. Skip silently on ad-hoc so local dev stays fast.
if [ -n "${NOTARIZE_PROFILE:-}" ] && [ "$SIGN_WITH" != "-" ]; then
    echo "[build-bundle] notarising via profile '${NOTARIZE_PROFILE}'..."
    NOTARY_ZIP="${PROJECT_ROOT}/.build/${APP_NAME}-notary.zip"
    rm -f "$NOTARY_ZIP"
    (cd "$(dirname "$APP_PATH")" && /usr/bin/ditto -c -k --keepParent "$(basename "$APP_PATH")" "$NOTARY_ZIP")
    xcrun notarytool submit "$NOTARY_ZIP" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait
    echo "[build-bundle] stapling ticket..."
    xcrun stapler staple "${APP_PATH}"
    spctl --assess --type execute --verbose "${APP_PATH}" || true
fi

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
