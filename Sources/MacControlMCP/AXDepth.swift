import Foundation

/// v0.9 (D-2) — ONE accessibility-search depth default for the whole
/// server.
///
/// Before this, seven tools shipped seven different ceilings:
/// `list_menu_paths` 4, `list_elements` 8, `get_ui_tree` 12,
/// `ax_tree_augmented` 12, `ground` 16, `find_element` 20,
/// `find_elements`/`query_elements` 32. An agent that searched with one
/// tool's default and found nothing could not tell whether the element
/// was absent or simply below that tool's ceiling — the exact failure
/// A-2 (ground blind at depth 17 in Electron UIs) was made of.
///
/// 24 is deliberately above the depths real Electron/Chromium UIs park
/// their controls at (17 measured in the Claude desktop app) and below
/// the point where a full walk stops paying for itself. Every tool that
/// takes `max_depth` clamps through `resolve(_:)`, and every tree/search
/// response echoes `max_depth_used`.
enum AXDepth {
    /// Project-wide default when the caller omits `max_depth`.
    static let `default` = 24

    /// Hard cap. Deeper requests are clamped, not rejected — a caller
    /// asking for 9999 wants "as deep as you go", not an error.
    static let maxAllowed = 64

    /// Clamp a caller-supplied depth into `1...maxAllowed`; `nil`
    /// (argument omitted) yields the project-wide default.
    static func resolve(_ requested: Int?) -> Int {
        guard let requested else { return `default` }
        return max(1, min(requested, maxAllowed))
    }
}
