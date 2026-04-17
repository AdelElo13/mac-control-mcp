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

        var description: String {
            switch self {
            case .outsideAllowedRoots(let p):
                return "output_path '\(p)' is outside allowed roots (temp dir, Desktop, Documents, Downloads, Pictures)."
            case .unresolvable(let p):
                return "output_path '\(p)' cannot be resolved."
            case .missingParent(let p):
                return "parent directory for '\(p)' does not exist."
            }
        }
    }

    static func allowedRoots() -> [URL] {
        var roots: [URL] = []
        roots.append(URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL)

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
        return resolvedParent.appendingPathComponent(filename).path
    }
}
