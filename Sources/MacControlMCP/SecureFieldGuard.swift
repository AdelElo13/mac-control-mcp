import Foundation
import ApplicationServices
import AppKit

/// Single source of truth for "is this a password field, and may this
/// input reach it?" (v0.10.3).
///
/// Password fields are off limits in both directions. Reading one would
/// hand a secret to the model, its transcript and every log. Writing one
/// means the agent already holds a credential in its context, which is
/// itself the leak — and a prompt-injected page could ask for exactly
/// that. Every route is refused in code, not by instruction text.
///
/// Detection covers both shapes macOS uses: role `AXSecureTextField`
/// (web views, some custom controls) and role `AXTextField` with subrole
/// `AXSecureTextField` (AppKit's NSSecureTextField). v0.10.2 checked the
/// role only in the text tools and missed the AppKit shape.
enum SecureFieldGuard {
    /// No exported kAX… constant exists for this name in ApplicationServices.
    static let secureName = "AXSecureTextField"

    static let refusalReason = "secure_field"
    static let refusalHint =
        "This is a password field. mac-control-mcp never reads, types or pastes into password fields; ask the user to enter the value themselves."

    // MARK: - Detection

    static func isSecure(role: String?, subrole: String?) -> Bool {
        role == secureName || subrole == secureName
    }

    /// Two attribute reads (role, subrole) in one IPC round trip.
    static func isSecure(_ element: AXUIElement) -> Bool {
        let names = [kAXRoleAttribute as String, kAXSubroleAttribute as String] as CFArray
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &raw) == .success,
              let values = raw as? [AnyObject], values.count == 2 else {
            return false
        }
        return isSecure(role: values[0] as? String, subrole: values[1] as? String)
    }

    /// Whether the system-wide keyboard focus currently sits in a password
    /// field. Returns false when focus cannot be read (no AX trust, locked
    /// screen): synthetic key events need AX trust as well, so an
    /// unreadable focus also means no event would land.
    ///
    /// The system-wide query can fail right after an app switch or for
    /// some Electron/Chromium windows, so the frontmost app's own
    /// AXFocusedUIElement is tried as a fallback.
    @Sendable static func focusedElementIsSecure() -> Bool {
        if let focused = focusedElement(of: AXUIElementCreateSystemWide()) {
            return isSecure(focused)
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let focused = focusedElement(of: AXUIElementCreateApplication(pid)) else {
            return false
        }
        return isSecure(focused)
    }

    private static func focusedElement(of root: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    // MARK: - Menu items

    /// Edit ▸ Paste, a context-menu Paste, Start Dictation or Emoji &
    /// Symbols all enter text into the focused field without a key event.
    /// While a password field has focus, no menu item may be pressed.
    static func isMenuItem(role: String?) -> Bool {
        role == (kAXMenuItemRole as String) || role == (kAXMenuBarItemRole as String)
    }

    /// Controls whose own drop-down menu only picks an option and never
    /// inserts text into the focused field.
    static let optionMenuOwners: Set<String> = [
        kAXPopUpButtonRole as String, kAXMenuButtonRole as String, kAXComboBoxRole as String
    ]

    /// A menu item that could insert text into the focused field: a menu
    /// bar item, or an item of a context / menu-bar menu. Items of a
    /// pop-up button, menu button or combo box are option pickers.
    static func isMenuItem(_ element: AXUIElement) -> Bool {
        guard isMenuItem(role: role(of: element)) else { return false }
        return !hasOptionMenuOwner(element)
    }

    static func hasOptionMenuOwner(_ element: AXUIElement, maxDepth: Int = 8) -> Bool {
        var current = element
        for _ in 0..<maxDepth {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeDowncast(parent, to: AXUIElement.self)
            if let role = role(of: current), optionMenuOwners.contains(role) { return true }
        }
        return false
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// The element under a screen point (global top-left coordinates).
    static func menuItemAt(x: Double, y: Double) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(x), Float(y), &hit) == .success,
              let hit else { return false }
        return isMenuItem(hit)
    }

    // MARK: - Content attributes

    /// Attributes that carry (part of) the field's content. Neither read
    /// nor written on a password field; identity and geometry stay
    /// available so the agent can still find and focus the field.
    static let contentAttributes: Set<String> = [
        kAXValueAttribute as String,
        kAXSelectedTextAttribute as String,
        kAXNumberOfCharactersAttribute as String,
        kAXVisibleCharacterRangeAttribute as String,
        kAXSelectedTextRangeAttribute as String,
        "AXSelectedTextRanges",
        "AXAttributedStringForRange",
        "AXStringForRange"
    ]

    static func isContentAttribute(_ name: String) -> Bool {
        contentAttributes.contains(name)
    }

    // MARK: - Key policy

    /// Keys that move focus, submit or cancel without entering or editing
    /// characters. Bare modifier keys are allowed so key_down("shift") +
    /// press_key("tab") still moves focus backwards.
    static let navigationKeys: Set<String> = [
        "tab", "return", "enter", "escape", "esc",
        "up", "down", "left", "right",
        "up_arrow", "down_arrow", "left_arrow", "right_arrow",
        "home", "end", "page_up", "page_down",
        "shift", "left_shift", "right_shift"
    ]

    /// Minimum pause after a navigation key inside press_key_sequence so a
    /// focus change has landed before the next step is probed.
    static let focusSettleMs = 150

    /// Only shift may accompany a navigation key: cmd+v pastes, cmd+a then
    /// delete clears, option/control produce characters.
    static func keyAllowed(_ key: String, modifiers: [String]) -> Bool {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard navigationKeys.contains(normalizedKey) else { return false }
        return modifiers.allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "shift"
        }
    }
}

// MARK: - Tool-level refusal

extension ToolRegistry {
    /// The uniform refusal every route returns, before any CGEvent or AX
    /// write is issued.
    func secureFieldRefusal(_ action: String) -> ToolCallResult {
        errorResult(
            "Refusing to \(action): the target is a password field.",
            [
                "ok": .bool(false),
                "error_code": .string("not_supported"),
                "reason": .string(SecureFieldGuard.refusalReason),
                "hint": .string(SecureFieldGuard.refusalHint)
            ]
        )
    }

    /// Refusal when keyboard focus is in a password field and any of the
    /// keys would enter or edit text. `nil` keys means "free text" (type_text).
    func refuseIfSecureFocus(_ action: String, keys: [(key: String, modifiers: [String])]? = nil) -> ToolCallResult? {
        if let keys, keys.allSatisfy({ SecureFieldGuard.keyAllowed($0.key, modifiers: $0.modifiers) }) {
            return nil
        }
        return secureFocusProbe() ? secureFieldRefusal(action) : nil
    }

    /// Refusal for pressing a menu item while a password field has focus.
    /// The menu check runs first so ordinary clicks pay no focus probe.
    func refuseMenuIfSecureFocus(isMenuItem: () -> Bool) -> ToolCallResult? {
        guard isMenuItem(), secureFocusProbe() else { return nil }
        return secureFieldRefusal("press a menu item while a password field has focus")
    }
}
