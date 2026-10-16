import Testing
import Foundation
import ApplicationServices
@testable import MacControlMCP

/// Password fields are off limits for every route into them (v0.10.3).
///
/// Live probe on v0.10.2 against ControlZoo's NSSecureTextField showed
/// six write routes that reached the field: set_element_attribute AXValue,
/// untargeted type_text (keys / ax / auto), press_key, press_key_sequence
/// and key_down. AppKit reports the field as role AXTextField with
/// subrole AXSecureTextField, so role-only checks missed it too.
///
/// These tests pin the pure guard and the focused-element tool routes
/// with an injected focus probe, so no real key events are posted. The
/// element-targeted routes are covered live by the ControlZoo matrix.
@Suite("Secure field guard")
struct SecureFieldGuardTests {
    // MARK: - Detection

    @Test("detects a password field by role or by subrole")
    func detection() {
        #expect(SecureFieldGuard.isSecure(role: "AXSecureTextField", subrole: nil))
        // NSSecureTextField: role AXTextField + subrole AXSecureTextField.
        #expect(SecureFieldGuard.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
        #expect(!SecureFieldGuard.isSecure(role: "AXTextField", subrole: nil))
        #expect(!SecureFieldGuard.isSecure(role: "AXTextField", subrole: "AXSearchField"))
        #expect(!SecureFieldGuard.isSecure(role: nil, subrole: nil))
    }

    // MARK: - Key policy

    @Test("navigation keys stay allowed while a password field has focus")
    func navigationAllowed() {
        for key in ["tab", "Tab", "return", "enter", "escape", "esc", "up", "down", "left", "right",
                    "left_arrow", "home", "end", "page_up", "page_down", "shift"] {
            #expect(SecureFieldGuard.keyAllowed(key, modifiers: []), "\(key) should be allowed")
        }
        #expect(SecureFieldGuard.keyAllowed("tab", modifiers: ["shift"]), "shift+tab moves focus back")
    }

    @Test("text-producing and editing keys are refused while a password field has focus")
    func textKeysRefused() {
        for key in ["a", "1", "space", ";", "delete", "backspace", "forward_delete", "f5"] {
            #expect(!SecureFieldGuard.keyAllowed(key, modifiers: []), "\(key) should be refused")
        }
        #expect(!SecureFieldGuard.keyAllowed("v", modifiers: ["command"]), "cmd+v pastes into the field")
        #expect(!SecureFieldGuard.keyAllowed("tab", modifiers: ["command"]))
        #expect(!SecureFieldGuard.keyAllowed("a", modifiers: ["shift"]))
    }

    // MARK: - Read redaction

    @Test("batched tree reads drop the value of a password field")
    func batchRedactsSecureValue() {
        var slots: [AnyObject] = Array(repeating: kCFNull, count: 8)
        slots[0] = "AXTextField" as NSString
        slots[4] = "hunter2" as NSString
        slots[7] = "AXSecureTextField" as NSString
        let attrs = AXAttributeBatch.decode(slots, includeChildren: false)
        #expect(attrs.value == nil)
        #expect(attrs.subrole == "AXSecureTextField", "the field must stay recognisable")

        slots[7] = kCFNull
        #expect(AXAttributeBatch.decode(slots, includeChildren: false).value == "hunter2",
                "an ordinary text field keeps its value")
    }

    @Test("content attributes of a password field are never described")
    func contentAttributeNames() {
        for name in ["AXValue", "AXSelectedText", "AXNumberOfCharacters", "AXVisibleCharacterRange"] {
            #expect(SecureFieldGuard.isContentAttribute(name), "\(name)")
        }
        for name in ["AXRole", "AXSubrole", "AXFocused", "AXIdentifier", "AXPosition"] {
            #expect(!SecureFieldGuard.isContentAttribute(name), "\(name)")
        }
    }

    // MARK: - Focused-element tool routes (no events posted)

    private func registry(secureFocused: Bool) -> ToolRegistry {
        ToolRegistry(accessibility: AccessibilityController(), secureFocusProbe: { secureFocused })
    }

    private func isSecureRefusal(_ result: ToolCallResult) -> Bool {
        guard result.isError, case .object(let payload) = result.structuredContent else { return false }
        return payload["error_code"] == .string("not_supported")
            && payload["reason"] == .string("secure_field")
    }

    @Test("type_text without element_id is refused for every strategy")
    func typeTextRefused() async {
        let registry = registry(secureFocused: true)
        for strategy in ["auto", "clipboard", "keys", "ax"] {
            let r = await registry.callTool(
                name: "type_text",
                arguments: ["text": .string("secret"), "strategy": .string(strategy)]
            )
            #expect(isSecureRefusal(r), "strategy \(strategy) reached the password field")
        }
    }

    @Test("press_key with a text key or cmd+v is refused")
    func pressKeyRefused() async {
        let registry = registry(secureFocused: true)
        let letter = await registry.callTool(name: "press_key", arguments: ["key": .string("a")])
        #expect(isSecureRefusal(letter))
        let paste = await registry.callTool(
            name: "press_key",
            arguments: ["key": .string("v"), "modifiers": .array([.string("command")])]
        )
        #expect(isSecureRefusal(paste))
    }

    @Test("press_key_sequence is refused when any step would type")
    func sequenceRefused() async {
        let registry = registry(secureFocused: true)
        let r = await registry.callTool(
            name: "press_key_sequence",
            arguments: ["steps": .array([
                .object(["key": .string("tab")]),
                .object(["key": .string("x")])
            ])]
        )
        #expect(isSecureRefusal(r))
    }

    @Test("key_down with a text key is refused")
    func keyDownRefused() async {
        let registry = registry(secureFocused: true)
        let r = await registry.callTool(name: "key_down", arguments: ["key": .string("b")])
        #expect(isSecureRefusal(r))
    }

    @Test("the refusal tells the agent to let the user type")
    func refusalHint() async {
        let registry = registry(secureFocused: true)
        let r = await registry.callTool(name: "type_text", arguments: ["text": .string("x")])
        guard case .object(let payload) = r.structuredContent,
              case .string(let hint) = payload["hint"] ?? .null else {
            Issue.record("refusal carries no hint"); return
        }
        #expect(hint.contains("user"))
    }

    // MARK: - Review round 1 (v0.10.3)

    @Test("menu items are recognised by role")
    func menuItemRole() {
        #expect(SecureFieldGuard.isMenuItem(role: "AXMenuItem"))
        #expect(SecureFieldGuard.isMenuItem(role: "AXMenuBarItem"))
        #expect(!SecureFieldGuard.isMenuItem(role: "AXButton"))
        #expect(!SecureFieldGuard.isMenuItem(role: nil))
    }

    @Test("click_menu_path is refused while a password field has focus (Edit > Paste)")
    func menuPathRefused() async {
        let registry = registry(secureFocused: true)
        let r = await registry.callTool(
            name: "click_menu_path",
            arguments: ["pid": .number(Double(getpid())), "path": .array([.string("Edit"), .string("Paste")])]
        )
        #expect(isSecureRefusal(r))
    }

    @Test("typeText re-probes right before every write, for every strategy")
    func typeTextAbortsLate() async {
        let controller = AccessibilityController()
        for strategy: AccessibilityController.TypeStrategy in [.auto, .clipboard, .keys, .ax] {
            let result = await controller.typeText(text: "secret", strategy: strategy, abortIf: { true })
            #expect(result.strategy == AccessibilityController.TypeTextResult.refusedSecureField,
                    "\(strategy) sent input although the probe said a password field has focus")
            #expect(!result.success)
        }
    }

    @Test("a refused key sequence reports how many steps were already sent")
    func sequenceStepsSent() async {
        let registry = registry(secureFocused: true)
        let r = await registry.callTool(
            name: "press_key_sequence",
            arguments: ["steps": .array([.object(["key": .string("x")])])]
        )
        #expect(isSecureRefusal(r))
        #expect(r.structuredContent.objectValue?["steps_sent"] == .number(0))
    }
}
