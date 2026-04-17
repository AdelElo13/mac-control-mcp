import Foundation

/// Validates user-supplied output paths so the MCP server cannot be used to
/// overwrite arbitrary files on the host. Screenshot/OCR tools accept an
/// `output_path` argument; without this validator a client could write to
/// ~/.ssh/authorized_keys, /etc/hosts, anywhere the user can write.
///
/// Policy: an output path must resolve (after symlink + `..` normalization)
/// to a location under one of the allowed root directories. Allowed roots
/// default to TMPDIR and the user's Desktop / Documents / Downloads /
/// Pictures. We refuse anything that escapes via symlinks or traversal.
enum PathValidator {
    enum ValidationError: Error, CustomStringConvertible {
        case outsideAllowedRoots(String)
        case unresolvable(String)
        case missingParent(String)
        case targetIsSymlink(String)

        var description: String {
            switch self {
            case .outsideAllowedRoots(let p):
                return "output_path '\(p)' is outside allowed roots (temp dir, Desktop, Documents, Downloads, Pictures)."
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
        roots.append(URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL)
        // POSIX temp locations. /tmp is the conventional shell temp on
        // macOS and resolves to /private/tmp; both are standard and both
        // are writable only by the same user's effective permissions,
        // so they're no less safe than the user-scoped temp. A previous
        // version rejected `/tmp/foo.png` even though that's where most
        // clients default their screenshots — causing every capture_*
        // call with /tmp paths to fail.
        roots.append(URL(fileURLWithPath: "/tmp").standardizedFileURL)
        roots.append(URL(fileURLWithPath: "/private/tmp").standardizedFileURL)

        let home = URL(fileURLWithPath: NSHomeDirectory())
        for name in ["Desktop", "Documents", "Downloads", "Pictures"] {
            roots.append(home.appendingPathComponent(name).standardizedFileURL)
        }
        return roots
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
        guard ok else {
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
