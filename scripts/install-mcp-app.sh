#!/usr/bin/env bash
set -euo pipefail

APP_NAME="mac-control-mcp"
CONFIG="debug"
APP_PATH="${HOME}/Applications/${APP_NAME}.app"
BUNDLE_ID="${MAC_CONTROL_BUNDLE_ID:-dev.mac-control.mcp}"
REQUEST_PERMISSION=1

usage() {
  cat <<'EOF'
Usage: scripts/install-mcp-app.sh [options]

Wraps .build/<configuration>/mac-control-mcp into a minimal .app bundle,
codesigns it, and installs it to ~/Applications by default.

Options:
  --configuration <debug|release>   Build configuration to package (default: debug)
  --app-path <path>                 Destination app bundle path (default: ~/Applications/mac-control-mcp.app)
  --bundle-id <id>                  CFBundleIdentifier (default: dev.mac-control.mcp)
  --no-request-permission           Do not trigger Screen Recording request at the end
  -h, --help                        Show this help

Environment:
  MAC_CONTROL_SIGN_IDENTITY         Override signing identity (example: "Apple Development: Jane Doe (ABCDE12345)")
  MAC_CONTROL_BUNDLE_ID             Alternative way to set bundle ID
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { echo "Missing value for --configuration" >&2; exit 2; }
      CONFIG="$2"
      shift 2
      ;;
    --app-path)
      [[ $# -ge 2 ]] || { echo "Missing value for --app-path" >&2; exit 2; }
      APP_PATH="$2"
      shift 2
      ;;
    --bundle-id)
      [[ $# -ge 2 ]] || { echo "Missing value for --bundle-id" >&2; exit 2; }
      BUNDLE_ID="$2"
      shift 2
      ;;
    --no-request-permission)
      REQUEST_PERMISSION=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$CONFIG" in
  debug|release) ;;
  *)
    echo "Unsupported configuration: $CONFIG (expected debug or release)" >&2
    exit 2
    ;;
esac

BIN_PATH=".build/${CONFIG}/${APP_NAME}"
PLIST_TEMPLATE="Packaging/mac-control-mcp-Info.plist"
APP_BIN_PATH="${APP_PATH}/Contents/MacOS/${APP_NAME}"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Missing executable: $BIN_PATH" >&2
  echo "Run: swift build -c $CONFIG" >&2
  exit 1
fi

if [[ ! -f "$PLIST_TEMPLATE" ]]; then
  echo "Missing plist template: $PLIST_TEMPLATE" >&2
  exit 1
fi

pick_sign_identity() {
  local identities line
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  while IFS= read -r line; do
    if [[ "$line" =~ \"(Apple\ Development:[^\"]+)\" ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<< "$identities"

  while IFS= read -r line; do
    if [[ "$line" =~ \"(Developer\ ID\ Application:[^\"]+)\" ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<< "$identities"

  echo "-"
}

SIGN_IDENTITY="${MAC_CONTROL_SIGN_IDENTITY:-$(pick_sign_identity)}"

mkdir -p "$(dirname "$APP_PATH")"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

sed "s|__BUNDLE_ID__|${BUNDLE_ID}|g" "$PLIST_TEMPLATE" > "$APP_PATH/Contents/Info.plist"
cp "$BIN_PATH" "$APP_BIN_PATH"
chmod 0755 "$APP_BIN_PATH"
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "Installed: $APP_PATH"
echo "Executable: $APP_BIN_PATH"
echo "Signing identity: $SIGN_IDENTITY"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Warning: ad-hoc signing is not a stable TCC identity across rebuilds." >&2
fi

if [[ "$REQUEST_PERMISSION" -eq 1 ]]; then
  echo "Requesting Screen Recording permission..."
  set +e
  "$APP_BIN_PATH" --request-screen-recording
  request_exit=$?
  set -e

  status="$("$APP_BIN_PATH" --check-screen-recording 2>/dev/null || true)"
  if [[ "$status" == "granted" ]]; then
    echo "Screen Recording permission: granted"
  else
    echo "Screen Recording permission: denied"
    if [[ "$request_exit" -ne 0 ]]; then
      echo "If macOS opened System Settings, click Allow for mac-control-mcp and rerun this script once." >&2
    fi
  fi
fi
