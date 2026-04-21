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

# Optional opt-in flag. Set PUBLISH=1 to auto-create GitHub release and publish
# to the MCP registry at the end. Default is off so the script stays safe to
# re-run for local testing.
PUBLISH="${PUBLISH:-0}"

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
echo "[release] assets built:"
ls -lh "$OUT_DIR"

# -----------------------------------------------------------------------------
# 6. Auto-sync server.json (registry manifest) with the actual mcpb sha256.
#
# History lesson: v0.2.6 shipped with a stale placeholder sha256 in server.json
# because the value was edited by hand and never re-checked. That silent drift
# blocks MCP-registry installers from verifying the bundle. Now the build
# computes the real hash and rewrites server.json, so sha is always correct.
# -----------------------------------------------------------------------------
SERVER_JSON="${PROJECT_ROOT}/server.json"
if [ -f "$SERVER_JSON" ]; then
    echo ""
    echo "[release] syncing server.json sha256 to actual .mcpb..."
    MCPB_SHA=$(shasum -a 256 "${OUT_DIR}/${MCPB_NAME}" | awk '{print $1}')
    MCPB_URL="https://github.com/AdelElo13/mac-control-mcp/releases/download/v${VERSION}/${MCPB_NAME}"
    # Use python to rewrite the JSON so we preserve formatting + escapes.
    python3 - "$SERVER_JSON" "$VERSION" "$MCPB_URL" "$MCPB_SHA" <<'PY'
import json, sys
path, version, url, sha = sys.argv[1:]
with open(path) as f: doc = json.load(f)
doc["version"] = version
pkg = doc.setdefault("packages", [{}])[0]
pkg["registryType"] = "mcpb"
pkg["identifier"] = url
pkg["fileSha256"] = sha
pkg.setdefault("transport", {"type": "stdio"})
with open(path, "w") as f: json.dump(doc, f, indent=2); f.write("\n")
print(f"  version={version}")
print(f"  identifier={url}")
print(f"  fileSha256={sha}")
PY
    echo "[release] validating server.json against MCP registry schema..."
    mcp-publisher validate
fi

# -----------------------------------------------------------------------------
# 7. Optional — when PUBLISH=1, create the GitHub release AND publish to the
#     MCP registry so the distribution channels can never drift again.
# -----------------------------------------------------------------------------
if [ "$PUBLISH" = "1" ]; then
    echo ""
    echo "[release] PUBLISH=1 — creating GitHub release + publishing to MCP registry"

    # Require RELEASE_NOTES file so the release body is human-reviewed prose,
    # not auto-generated git log noise.
    NOTES_FILE="${PROJECT_ROOT}/RELEASE_NOTES_v${VERSION}.md"
    if [ ! -f "$NOTES_FILE" ]; then
        echo "[release] ERROR: $NOTES_FILE missing. Write the release notes first."
        exit 1
    fi

    # Create the GitHub release (idempotent-ish: if the tag exists gh will complain).
    gh release create "v${VERSION}" \
        --title "v${VERSION}" \
        --notes-file "$NOTES_FILE" \
        "${OUT_DIR}/${MCPB_NAME}" \
        "${OUT_DIR}/${TARBALL_NAME}" \
        "${OUT_DIR}/${SHA_NAME}"

    # Publish to the MCP registry. If the token is expired the caller has to
    # `mcp-publisher login github` first — we don't try to auto-login because
    # device-code flow needs an interactive browser.
    echo ""
    echo "[release] publishing to MCP registry..."
    mcp-publisher publish

    echo ""
    echo "[release] PUBLISHED."
    echo "  GitHub release: https://github.com/AdelElo13/mac-control-mcp/releases/tag/v${VERSION}"
    echo "  MCP registry:   https://registry.modelcontextprotocol.io/v0/servers?search=mac-control-mcp"
else
    echo ""
    echo "[release] DONE (assets only; set PUBLISH=1 to also create the GitHub release and push to the MCP registry)."
    echo ""
    echo "Manual next steps:"
    echo "  gh release create v${VERSION} -t \"v${VERSION}\" -F RELEASE_NOTES_v${VERSION}.md \\"
    echo "    ${OUT_DIR}/${MCPB_NAME} \\"
    echo "    ${OUT_DIR}/${TARBALL_NAME} \\"
    echo "    ${OUT_DIR}/${SHA_NAME}"
    echo ""
    echo "  mcp-publisher publish   # assumes you already ran \`mcp-publisher login github\`"
fi
