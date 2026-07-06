import Foundation

/// Escaping for values interpolated into AppleScript double-quoted string
/// literals.
///
/// Order matters: the backslash must be escaped **first**, then the double
/// quote. Escaping the quote first would turn `"` into `\"`, and the
/// subsequent backslash pass would then double-escape that new backslash into
/// `\\"`, breaking the literal. Several call sites had hand-rolled escapers
/// that omitted the backslash pass entirely, so a value containing a backslash
/// (or `\"`) broke — or could inject into — the surrounding AppleScript.
enum AppleScriptString {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
