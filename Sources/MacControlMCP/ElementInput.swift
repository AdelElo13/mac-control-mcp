import Foundation

// v0.10 C4: separate the focus/write sequence from AX transport so failure
// cases can be exercised without sending input to the developer's desktop.
enum ElementInput {
    static func focusAndRun(
        secure: Bool,
        focus: @Sendable () async -> ToolCallResult,
        isFocused: @Sendable () async -> Bool?,
        input: @Sendable () async -> ToolCallResult
    ) async -> ToolCallResult {
        guard !secure else {
            return ToolCallResult(text: "Refusing to edit a password field.", structuredContent: .object([
                "ok": .bool(false), "error_code": .string("not_supported"), "reason": .string("secure_field"), "verified": .bool(false)
            ]), isError: true)
        }
        let focused = await focus()
        guard !focused.isError else { return focused }
        guard await isFocused() == true else {
            return ToolCallResult(text: "AXFocused did not read back as true; no input was sent.", structuredContent: .object([
                "ok": .bool(false), "error_code": .string("focus_not_verified"), "verified": .bool(false)
            ]), isError: true)
        }
        return await input()
    }
}
