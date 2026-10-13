import Foundation

/// Validates user-supplied output paths so the MCP server cannot be used to
/// overwrite arbitrary files on the host. Screenshot/OCR tools accept an
/// `output_path` argument; without this validator a client could write to
/// ~/.ssh/authorized_keys, /etc/hosts, anywhere the user can write.
///
/// Policy: an output path must resolve (after symlink + `..` normalization)
/// to a location under one of the allowed root directories. Allowed roots
/// default to TMPDIR and the user's Desktop / Documents / Downloads /
/// Pictures, plus private per-user directories directly under /tmp (see
/// `privateSharedTempRoot`). We refuse anything that escapes via symlinks
/// or traversal.
enum PathValidator {
    enum ValidationError: Error, CustomStringConvertible {
        case outsideAllowedRoots(String)
        case unresolvable(String)
        case missingParent(String)
        case targetIsSymlink(String)

        var description: String {
            switch self {
            case .outsideAllowedRoots(let p):
                let tmp = NSTemporaryDirectory()
                return "output_path '\(p)' is outside allowed roots. " +
                    "Use one of: \(tmp) (user-scoped temp — prefer this for throwaway files), ~/Desktop, ~/Documents, ~/Downloads, ~/Pictures, " +
                    "or a private directory directly under /tmp that you own with mode 0700 (e.g. an agent scratchpad like /tmp/claude-\(getuid())/...). " +
                    "Other /tmp and /private/tmp paths are rejected on purpose (TOCTOU symlink risk)."
            case .unresolvable(let p):
                return "output_path '\(p)' cannot be resolved."
            case .missingParent(let p):
                return "parent directory for '\(p)' does not exist."
            case .targetIsSymlink(let p):
                return "output_path '\(p)' already exists as a symlink; refusing to overwrite (could redirect the write outside allowed roots)."
            }
        }
    }

    static func allowedRoots() -> [URL] {
        var roots: [URL] = []
        // User-scoped temp (NSTemporaryDirectory → /var/folders/.../T/).
        // This is the ONLY temp path we accept. /tmp and /private/tmp
        // are shared across the system and open a TOCTOU hole between
        // `validate(...)` and the subsequent write: another process on
        // the same host can swap a symlink/regular-file at the same
        // path and redirect the write outside the allowed roots. The
        // user-scoped temp is per-UID and not writable by other users,
        // so it doesn't carry that risk. (Codex v11 MEDIUM — added
        // `/tmp` was convenient but materially weakened the guarantee.)
        roots.append(URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL)

        let home = URL(fileURLWithPath: NSHomeDirectory())
        for name in ["Desktop", "Documents", "Downloads", "Pictures"] {
            roots.append(home.appendingPathComponent(name).standardizedFileURL)
        }
        return roots
    }

    /// Agent scratchpads such as Claude Code's `/tmp/claude-<uid>/...` live
    /// in the shared /tmp, which is rejected in general because another
    /// user could swap a path component between validation and the write.
    /// That risk is gone when the FIRST directory below /tmp is a real
    /// directory (not a symlink) owned by us with no group/other access:
    /// nobody else can create, rename or replace anything underneath it.
    /// Returns that directory when `resolvedParent` lies inside one.
    static func privateSharedTempRoot(containing resolvedParent: URL) -> URL? {
        // Foundation's resolvingSymlinksInPath strips a leading /private, so
        // accept both ["/", "tmp", "<dir>", ...] and ["/", "private", "tmp", "<dir>", ...].
        var components = resolvedParent.standardizedFileURL.pathComponents
        if components.count >= 2, components[1] == "private" { components.remove(at: 1) }
        guard components.count >= 3, components[0] == "/", components[1] == "tmp" else { return nil }
        let dir = components[2]
        guard !dir.isEmpty, dir != ".", dir != ".." else { return nil }
        let top = "/private/tmp/" + dir
        return isPrivateOwnedDirectory(top) ? URL(fileURLWithPath: top) : nil
    }

    /// lstat-based (does not follow symlinks): a directory owned by the
    /// current uid with no group/other permission bits.
    static func isPrivateOwnedDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard st.st_uid == getuid() else { return false }
        return (st.st_mode & 0o077) == 0
    }

    /// Resolve a candidate path to an absolute canonical URL and verify it
    /// lands under at least one allowed root. The parent directory must
    /// exist; we do not create intermediate folders on the caller's behalf.
    static func validate(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let parent = url.deletingLastPathComponent()

        // Resolve parent to canonical form (symlinks + `..`) before checking
        // containment; otherwise `/tmp/../etc/hosts` would slip through.
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw ValidationError.missingParent(path)
        }
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL

        let roots = allowedRoots().map { $0.resolvingSymlinksInPath().standardizedFileURL }
        let parentPath = resolvedParent.path
        let ok = roots.contains { root in
            let rootPath = root.path
            return parentPath == rootPath || parentPath.hasPrefix(rootPath + "/")
        }
        guard ok || privateSharedTempRoot(containing: resolvedParent) != nil else {
            throw ValidationError.outsideAllowedRoots(path)
        }

        // Rebuild the final path against the resolved parent to ensure no
        // shenanigans in the filename itself.
        let filename = url.lastPathComponent
        let finalPath = resolvedParent.appendingPathComponent(filename).path

        // If the target already exists as a symbolic link, refuse to
        // overwrite it. Codex v2 flagged that a pre-existing symlink under
        // an allowed parent could redirect the write outside allowed roots
        // (e.g. a symlink at ~/Desktop/harmless.png → /etc/hosts). We do
        // not want the caller to be able to chain a directory-traversal
        // attack by planting a symlink and then invoking capture_screen.
        var isSymlink = false
        if let attrs = try? FileManager.default.attributesOfItem(atPath: finalPath),
           let type = attrs[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            isSymlink = true
        }
        guard !isSymlink else {
            throw ValidationError.targetIsSymlink(path)
        }

        return finalPath
    }
}
