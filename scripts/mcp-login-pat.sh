#!/bin/bash
# Persistent mcp-publisher login via a long-lived GitHub PAT stored in macOS
# Keychain. Replaces the 15-minute device-code dance — one-time setup, then
# every `mcp-publisher publish` just works until the PAT is rotated.
#
# Keychain entry:
#   service=mcp-publisher-pat
#   account=<your login>
#   password=<GitHub PAT with read:packages + read:user scopes>
#
# Usage:
#   ./scripts/mcp-login-pat.sh           # login (reads PAT from Keychain)
#   ./scripts/mcp-login-pat.sh setup     # interactively store a new PAT
#   ./scripts/mcp-login-pat.sh check     # verify the stored PAT still works
#   ./scripts/mcp-login-pat.sh rotate    # replace the stored PAT

set -euo pipefail

SERVICE="mcp-publisher-pat"
ACCOUNT="${USER}"

cmd="${1:-login}"

# -----------------------------------------------------------------------------
# setup — walk the user through creating a PAT and storing it
# -----------------------------------------------------------------------------
setup_pat() {
    echo ""
    echo "=== Create a GitHub Personal Access Token for mcp-publisher ==="
    echo ""
    echo "1. This will open https://github.com/settings/tokens/new in Safari"
    echo "2. Give the token a name: 'mcp-publisher'"
    echo "3. Expiration: 1 year (or 'No expiration' — your choice)"
    echo "4. Select scopes:"
    echo "     ✓ read:packages"
    echo "     ✓ read:user"
    echo "5. Click 'Generate token'"
    echo "6. COPY THE TOKEN (it's shown only once)"
    echo "7. Come back here and paste it below"
    echo ""
    read -p "Press Enter to open the GitHub page…"
    open "https://github.com/settings/tokens/new?scopes=read:packages,read:user&description=mcp-publisher"
    echo ""
    echo -n "Paste the PAT here (input is hidden): "
    read -s PAT
    echo ""
    if [ -z "$PAT" ]; then
        echo "ERROR: empty PAT, aborting."
        exit 1
    fi
    # Store in Keychain (overwrites any existing entry)
    security add-generic-password -U \
        -s "$SERVICE" -a "$ACCOUNT" -w "$PAT" \
        -l "mcp-publisher PAT for $ACCOUNT"
    echo ""
    echo "[mcp-login-pat] stored in Keychain: service=$SERVICE account=$ACCOUNT"
    echo "[mcp-login-pat] verifying..."
    login_with_pat "$PAT"
}

# -----------------------------------------------------------------------------
# login — read PAT from Keychain, call mcp-publisher
# -----------------------------------------------------------------------------
login_with_pat() {
    local pat="$1"
    if ! mcp-publisher login github -token "$pat"; then
        echo ""
        echo "[mcp-login-pat] PAT login failed. Possible causes:"
        echo "  - token expired → re-run: $0 rotate"
        echo "  - token missing read:packages or read:user scope"
        echo "  - network/registry error"
        exit 1
    fi
    echo "[mcp-login-pat] authenticated — mcp-publisher is ready."
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
case "$cmd" in
    setup|init)
        setup_pat
        ;;
    rotate)
        # Delete existing, then run setup flow
        security delete-generic-password -s "$SERVICE" -a "$ACCOUNT" 2>/dev/null || true
        setup_pat
        ;;
    check)
        PAT=$(security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w 2>/dev/null || true)
        if [ -z "$PAT" ]; then
            echo "[mcp-login-pat] no PAT stored. Run: $0 setup"
            exit 1
        fi
        login_with_pat "$PAT"
        ;;
    login|"")
        PAT=$(security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w 2>/dev/null || true)
        if [ -z "$PAT" ]; then
            echo "[mcp-login-pat] no PAT in Keychain. First-time setup:"
            setup_pat
        else
            login_with_pat "$PAT"
        fi
        ;;
    *)
        echo "Usage: $0 {setup|login|check|rotate}"
        exit 1
        ;;
esac
