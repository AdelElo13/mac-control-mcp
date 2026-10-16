/// Single source of the server version reported by `initialize`
/// (serverInfo) and `mcp_server_info`. Bump together with
/// npm/package.json, server.json and scripts/build-bundle.sh.
enum ServerVersion {
    static let current = "0.10.3"
}
