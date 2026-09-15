import Foundation
import ApplicationServices
import CoreGraphics

/// Batched AX attribute reads for tree walks.
///
/// PERF (v0.8.3): every `AXUIElementCopyAttributeValue` is a synchronous
/// IPC round trip into the target process. The old walks read role,
/// title (up to 3 attributes: AXTitle → AXDescription → AXIdentifier),
/// value, position, size, children and sheets one at a time — ~9 round
/// trips per node. `AXUIElementCopyMultipleAttributeValues` returns all
/// of them in ONE round trip. Measured on a 422-node Chrome tree
/// (max_depth 10): 3,774 IPC calls / 63–67 ms per-attribute vs
/// 422 IPC calls / 25–27 ms batched.
///
/// Missing attributes come back in their slot as an `AXValue` of type
/// `.axError` (not as a failed call), so decoding must treat anything
/// that isn't the expected type as "absent" — which is exactly what the
/// single-attribute helpers did for a non-`.success` status.
enum AXAttributeBatch {
    /// Attributes needed to describe an element (ElementInfo / TreeNode
    /// minus children). Order is load-bearing: `decode` reads by index.
    static let infoAttributes: [String] = [
        kAXRoleAttribute as String,         // 0
        kAXTitleAttribute as String,        // 1
        kAXDescriptionAttribute as String,  // 2
        "AXIdentifier",                     // 3
        kAXValueAttribute as String,        // 4
        kAXPositionAttribute as String,     // 5
        kAXSizeAttribute as String,         // 6
        // v0.9 (C-5 review): AXSubrole is part of an element's path
        // fingerprint — it separates an AXButton that is a close box
        // from one that is a toolbar button when neither has a title.
        // Free: same batched round trip.
        kAXSubroleAttribute as String       // 7
    ]

    /// `infoAttributes` plus the two child lists a walk descends into.
    /// `AXSheets` is merged with `AXChildren` for the same reason as
    /// `AccessibilityController.childElements`: a presented sheet is not
    /// always reflected in AXChildren.
    static let nodeAttributes: [String] = infoAttributes + [
        kAXChildrenAttribute as String,     // 8
        "AXSheets"                          // 9
    ]

    struct Values: @unchecked Sendable {
        let role: String?
        /// AXTitle → AXDescription → AXIdentifier, skipping empty /
        /// whitespace-only strings (BUG-FIX v0.2.6 #4 semantics).
        let title: String?
        /// `AXIdentifier` verbatim (not folded into `title`). v0.9 (C-5)
        /// uses it as the strongest component of a stable element path;
        /// it costs nothing extra since the batch already fetches it.
        let identifier: String?
        /// `AXSubrole` — the second half of an element's identity when it
        /// has no title (v0.9 C-5 fingerprint).
        let subrole: String?
        let value: String?
        let position: CGPoint?
        let size: CGSize?
        /// AXChildren followed by AXSheets. Empty when children were not
        /// requested.
        let children: [AXUIElement]
        // v0.10 A5: preserve provenance instead of labelling description fallbacks as titles.
        var rawTitle: String? = nil
        var description: String? = nil
        var web: [String: String] = [:]
    }

    /// Fetch `nodeAttributes` (when `includeChildren`) or
    /// `infoAttributes` in one IPC round trip. Falls back to one call per
    /// attribute if the batched call itself fails, so behaviour never
    /// regresses below the old per-attribute path.
    // v0.10 C6: append web metadata only below AXWebArea, in the same IPC.
    static let webAttributes = ["AXURL", "AXDOMIdentifier", "AXDOMClassList"]

    /// `fallbackOnFailure: false` (v0.10 A1) keeps identity checks to ONE
    /// IPC round trip: a failed batch cannot prove identity and fails closed.
    static func fetch(
        _ element: AXUIElement, includeChildren: Bool, insideWebArea: Bool = false, fallbackOnFailure: Bool = true
    ) -> Values {
        let names = (includeChildren ? nodeAttributes : infoAttributes) + (insideWebArea ? webAttributes : [])
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw)
        if status == .success, let array = raw as? [AnyObject], array.count == names.count {
            return decode(array, includeChildren: includeChildren)
        }
        // v0.10 A1: identity validation must stay within one IPC round trip;
        // a failed batch cannot prove identity and must fail closed.
        guard fallbackOnFailure else { return decode([], includeChildren: includeChildren) }
        let slots: [AnyObject] = names.map { name in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                  let value else { return kCFNull }
            return value
        }
        return decode(slots, includeChildren: includeChildren)
    }

    /// Pure decoder over the slot array (index-aligned with
    /// `infoAttributes` / `nodeAttributes`). Unit-tested without a live
    /// AX target.
    static func decode(_ slots: [AnyObject], includeChildren: Bool) -> Values {
        func slot(_ i: Int) -> AnyObject? { i < slots.count ? slots[i] : nil }
        func nonEmpty(_ i: Int) -> String? {
            guard let s = string(slot(i)),
                  !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        let children: [AXUIElement] = includeChildren
            ? elements(slot(8)) + elements(slot(9))
            : []
        let webOffset = includeChildren ? 10 : 8
        var web: [String: String] = [:]
        if let url = slot(webOffset) as? URL { web["url"] = url.absoluteString }
        else if let url = string(slot(webOffset)) { web["url"] = url }
        if let id = nonEmpty(webOffset + 1) { web["dom_id"] = id }
        // v0.10 C6: an absent DOM identity is not an empty identity.
        if let classes = slot(webOffset + 2) as? [String] {
            let joined = classes.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " ")
            if !joined.isEmpty { web["dom_class"] = joined }
        } else if let classes = nonEmpty(webOffset + 2) { web["dom_class"] = classes }
        return Values(
            role: string(slot(0)),
            title: nonEmpty(1) ?? nonEmpty(2) ?? nonEmpty(3),
            identifier: nonEmpty(3),
            subrole: nonEmpty(7),
            value: string(slot(4)),
            position: point(slot(5)),
            size: size(slot(6)),
            children: children,
            rawTitle: nonEmpty(1),
            description: nonEmpty(2),
            web: web
        )
    }

    /// Same conversions as `AccessibilityController.stringAttribute`.
    static func string(_ value: AnyObject?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        if let a = value as? NSAttributedString { return a.string }
        // CFBoolean bridges to NSNumber too; stringValue gives "1"/"0",
        // matching the per-attribute helper.
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ value: AnyObject?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &s) ? s : nil
    }

    static func elements(_ value: AnyObject?) -> [AXUIElement] {
        guard let array = value as? NSArray else { return [] }
        return array.compactMap { child in
            let object = child as AnyObject
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(object, to: AXUIElement.self)
        }
    }
}
