#!/bin/bash
# Verify that every privacy usage description in Info.plist has the matching
# hardened-runtime entitlement. Without it, TCC denies the resource WITHOUT a
# prompt whenever MacControlMCP.app is the responsible process (e.g. launched
# by Claude Desktop via `disclaimer`) — the v0.8.2 calendar/contacts/mic bug.
#
# Usage:
#   scripts/check-entitlements.sh <path/to/MacControlMCP.app>
#       reads Info.plist from the bundle and the SIGNED entitlements via
#       `codesign -d --entitlements -` (what macOS actually enforces)
#   scripts/check-entitlements.sh --info-plist <Info.plist> --entitlements <file.entitlements>
#       source mode, no signing needed
#
# Exit 0 = consistent, 1 = missing/false entitlement or unknown usage key,
# 2 = usage error.
set -euo pipefail

PLISTBUDDY=/usr/libexec/PlistBuddy
INFO=""
ENT=""
TMP_ENT=""
# `if` instead of `[ ] && rm`: a false test as the trap's last command would
# become the script's exit status and turn a clean pass into exit 1.
cleanup() { if [ -n "$TMP_ENT" ]; then rm -f "$TMP_ENT"; fi; }
trap cleanup EXIT

if [ "${1:-}" = "--info-plist" ]; then
    INFO="${2:?missing Info.plist path}"
    [ "${3:-}" = "--entitlements" ] || { echo "usage: $0 --info-plist P --entitlements E" >&2; exit 2; }
    ENT="${4:?missing entitlements path}"
elif [ -n "${1:-}" ] && [ -d "$1" ]; then
    APP="$1"
    INFO="$APP/Contents/Info.plist"
    TMP_ENT="$(mktemp -t macmcp-ent)"
    if ! codesign -d --entitlements - --xml "$APP" > "$TMP_ENT" 2>/dev/null || [ ! -s "$TMP_ENT" ]; then
        echo "FAIL: could not read signed entitlements from $APP (is it signed with --entitlements?)" >&2
        exit 1
    fi
    ENT="$TMP_ENT"
else
    echo "usage: $0 <App.app> | --info-plist P --entitlements E" >&2
    exit 2
fi

[ -f "$INFO" ] || { echo "FAIL: Info.plist not found at $INFO" >&2; exit 1; }
[ -f "$ENT" ] || { echo "FAIL: entitlements not found at $ENT" >&2; exit 1; }

# Map a usage-description key to its required entitlement.
# "-" = no hardened-runtime entitlement exists for it (TCC-only).
# "?" = unknown key: the checker must be taught about it (fails the check,
#       so a new usage description can never slip in unmapped).
entitlement_for() {
    case "$1" in
        NSCalendarsUsageDescription|NSCalendarsFullAccessUsageDescription|NSCalendarsWriteOnlyAccessUsageDescription)
            echo com.apple.security.personal-information.calendars ;;
        NSRemindersUsageDescription|NSRemindersFullAccessUsageDescription)
            echo com.apple.security.personal-information.calendars ;;
        NSContactsUsageDescription)
            echo com.apple.security.personal-information.addressbook ;;
        NSLocationUsageDescription|NSLocationWhenInUseUsageDescription|NSLocationAlwaysUsageDescription|NSLocationAlwaysAndWhenInUseUsageDescription)
            echo com.apple.security.personal-information.location ;;
        NSMicrophoneUsageDescription|NSSpeechRecognitionUsageDescription)
            echo com.apple.security.device.audio-input ;;
        NSCameraUsageDescription)
            echo com.apple.security.device.camera ;;
        NSPhotoLibraryUsageDescription|NSPhotoLibraryAddUsageDescription)
            echo com.apple.security.personal-information.photos-library ;;
        NSAppleEventsUsageDescription)
            echo com.apple.security.automation.apple-events ;;
        NSScreenCaptureUsageDescription|NSAccessibilityUsageDescription|NSDesktopFolderUsageDescription|NSDocumentsFolderUsageDescription|NSDownloadsFolderUsageDescription|NSRemovableVolumesUsageDescription|NSNetworkVolumesUsageDescription|NSSystemAdministrationUsageDescription)
            echo - ;;
        *)
            echo "?" ;;
    esac
}

# Top-level keys of Info.plist that look like usage descriptions.
USAGE_KEYS=$(plutil -p "$INFO" | sed -n 's/^  "\(NS[A-Za-z]*UsageDescription\)" =>.*/\1/p' | sort -u)

failures=0
checked=0
for key in $USAGE_KEYS; do
    checked=$((checked + 1))
    ent=$(entitlement_for "$key")
    case "$ent" in
        "-") echo "ok    $key (no entitlement required)" ;;
        "?")
            echo "FAIL  $key: unknown usage description — add its entitlement mapping to scripts/check-entitlements.sh" >&2
            failures=$((failures + 1)) ;;
        *)
            value=$("$PLISTBUDDY" -c "Print :$ent" "$ENT" 2>/dev/null || echo "<missing>")
            if [ "$value" = "true" ]; then
                echo "ok    $key -> $ent"
            else
                echo "FAIL  $key requires $ent=true (found: $value)" >&2
                failures=$((failures + 1))
            fi ;;
    esac
done

if [ "$checked" -eq 0 ]; then
    echo "FAIL: no usage descriptions found in $INFO — wrong file?" >&2
    exit 1
fi
if [ "$failures" -gt 0 ]; then
    echo "check-entitlements: $failures problem(s) in $checked usage description(s)" >&2
    exit 1
fi
echo "check-entitlements: all $checked usage description(s) consistent"
