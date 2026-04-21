#!/bin/bash
# Build every release artifact for a mac-control-mcp version tag.
#
# Runs:
#   1. build-bundle.sh with NOTARIZE_PROFILE so the .app is signed + notarized.
#   2. Assembles manifest.json for the .mcpb (dxt spec v0.1).
#   3. Zips .app + manifest → mac-control-mcp-v<VER>.mcpb
#   4. Tars .app        → MacControlMCP-v<VER>-macos-universal.tar.gz
#   5. Computes SHA256  → MacControlMCP-v<VER>-macos-universal.sha256
#
# After this script: upload the three assets via `gh release create`.
#
# Required env (only 1 is mandatory):
#   NOTARIZE_PROFILE   keychain profile name (default: mac-control-mcp)
#
# Usage:
#   VERSION=0.2.6 ./scripts/release.sh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

VERSION="${VERSION:?set VERSION=x.y.z}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-mac-control-mcp}"
OUT_DIR="${PROJECT_ROOT}/release-artifacts"

APP_NAME="MacControlMCP"
APP_PATH="${HOME}/Applications/${APP_NAME}.app"

MCPB_NAME="mac-control-mcp-v${VERSION}.mcpb"
TARBALL_NAME="MacControlMCP-v${VERSION}-macos-universal.tar.gz"
SHA_NAME="MacControlMCP-v${VERSION}-macos-universal.sha256"

echo "[release] version=${VERSION}"
echo "[release] notarize profile=${NOTARIZE_PROFILE}"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# -----------------------------------------------------------------------------
# 1. Build + sign + notarize the .app bundle.
# -----------------------------------------------------------------------------
echo ""
echo "[release] building .app bundle (signed + notarized)..."
NOTARIZE_PROFILE="$NOTARIZE_PROFILE" "$PROJECT_ROOT/scripts/build-bundle.sh"

if [ ! -d "$APP_PATH" ]; then
    echo "[release] ERROR: build-bundle.sh did not produce $APP_PATH"
    exit 1
fi

# -----------------------------------------------------------------------------
# 2. manifest.json for .mcpb (dxt spec v0.1).
# -----------------------------------------------------------------------------
MANIFEST_PATH="${OUT_DIR}/manifest.json"
echo ""
echo "[release] writing manifest.json..."

# Tool count is pulled from the registry so the manifest can never drift.
TOOL_COUNT=$(swift run mac-control-mcp --help 2>/dev/null | grep -Eo '[0-9]+ tools' | head -1 | awk '{print $1}' || true)
if [ -z "$TOOL_COUNT" ]; then
    # Fallback: count from the test expectation we just updated. Keep this in
    # sync with Tests/MacControlMCPTests/Phase5ToolsTests.swift.
    TOOL_COUNT=$(grep -E 'toolDefinitions\.count == ' Tests/MacControlMCPTests/Phase5ToolsTests.swift \
        | grep -Eo '[0-9]+' | head -1 || echo "64")
fi
echo "[release] tool count = ${TOOL_COUNT}"

cat > "$MANIFEST_PATH" <<EOF
{
  "dxt_version": "0.1",
  "name": "mac-control-mcp",
  "display_name": "mac-control-mcp",
  "version": "${VERSION}",
  "description": "Native Swift MCP server for full macOS automation — ${TOOL_COUNT} tools for accessibility, browser, screen capture, clipboard, windows, apps, and system control.",
  "long_description": "Gives MCP-compatible clients (Claude Desktop, Claude Code, Cursor) full macOS control through ${TOOL_COUNT} native Swift tools: Accessibility tree traversal, Safari/Chrome automation, ScreenCaptureKit window capture, OCR, Spotlight search via NSMetadataQuery, clipboard, window and app lifecycle, menus, file dialogs, and system settings. One signed+notarized .app bundle — no Python/Node runtime. Requires macOS 14.0+ and Apple Silicon or Intel.",
  "author": {
    "name": "Adil El-Ouariachi",
    "url": "https://github.com/AdelElo13"
  },
  "homepage": "https://github.com/AdelElo13/mac-control-mcp",
  "documentation": "https://github.com/AdelElo13/mac-control-mcp#readme",
  "support": "https://github.com/AdelElo13/mac-control-mcp/issues",
  "license": "MIT",
  "keywords": ["macos","automation","accessibility","screen-capture","swift","browser","spotlight"],
  "server": {
    "type": "binary",
    "entry_point": "MacControlMCP.app/Contents/MacOS/MacControlMCP",
    "mcp_config": {
      "command": "\${__dirname}/MacControlMCP.app/Contents/MacOS/MacControlMCP"
    }
  },
  "compatibility": {
    "platforms": ["darwin"],
    "runtimes": {}
  }
}
EOF

# -----------------------------------------------------------------------------
# 3. .mcpb bundle = zip( .app + manifest.json ).
# -----------------------------------------------------------------------------
echo ""
echo "[release] building ${MCPB_NAME}..."
STAGE_DIR=$(mktemp -d)
cp -R "$APP_PATH" "$STAGE_DIR/"
cp "$MANIFEST_PATH" "$STAGE_DIR/"
(cd "$STAGE_DIR" && zip -qry "${OUT_DIR}/${MCPB_NAME}" "${APP_NAME}.app" "manifest.json")
rm -rf "$STAGE_DIR"

# -----------------------------------------------------------------------------
# 4. Universal tarball = tar.gz( .app ).
# -----------------------------------------------------------------------------
echo "[release] building ${TARBALL_NAME}..."
(cd "$(dirname "$APP_PATH")" && tar -czf "${OUT_DIR}/${TARBALL_NAME}" "${APP_NAME}.app")

# -----------------------------------------------------------------------------
# 5. SHA256 of the tarball.
# -----------------------------------------------------------------------------
echo "[release] computing SHA256..."
(cd "$OUT_DIR" && shasum -a 256 "$TARBALL_NAME" > "$SHA_NAME")

echo ""
echo "[release] DONE. Assets:"
ls -lh "$OUT_DIR"
echo ""
echo "Next step:"
echo "  gh release create v${VERSION} -t \"v${VERSION}\" -F RELEASE_NOTES_v${VERSION}.md \\"
echo "    ${OUT_DIR}/${MCPB_NAME} \\"
echo "    ${OUT_DIR}/${TARBALL_NAME} \\"
echo "    ${OUT_DIR}/${SHA_NAME}"
