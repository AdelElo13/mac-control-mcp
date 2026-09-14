import Foundation
import ApplicationServices
import CoreGraphics

/// The AX calls `TextEditingController` needs, behind a protocol so the
/// read-back / verification logic can be unit-tested without a live app.
///
/// v0.9 review (workstream E): the first cut called `AXUIElementCopyAttributeValue`
/// & friends inline, which meant the interesting paths — "the element accepted
/// the range write but did not apply it", "the AXSelectedText write silently
/// no-op'd" — could only ever be exercised by driving a real GUI app. Those are
/// exactly the paths that must not regress, so they get a seam.
///
/// Elements are still passed as `AXUIElement`; a fake backend simply ignores
/// the handle. Every range/length in this protocol is measured in **UTF-16
/// code units**, which is what the Accessibility API itself uses — never
/// Swift `Character` counts.
protocol AXTextBackend: Sendable {
    func focusedElement(pid: pid_t) -> AXUIElement?
    func attributeNames(of element: AXUIElement) -> (status: AXError, names: [String])
    func stringAttribute(_ element: AXUIElement, _ name: String) -> String?
    func intAttribute(_ element: AXUIElement, _ name: String) -> Int?
    func rangeAttribute(_ element: AXUIElement, _ name: String) -> TextEditingController.TextRange?
    func setRangeAttribute(
        _ element: AXUIElement, _ name: String, location: Int, length: Int
    ) -> AXError
    func setStringAttribute(_ element: AXUIElement, _ name: String, _ value: String) -> AXError
    func boundsForRange(
        _ element: AXUIElement, location: Int, length: Int
    ) -> TextEditingController.Bounds?
    func lineForIndex(_ element: AXUIElement, index: Int) -> Int?
    func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String?
}

/// The real thing: straight ApplicationServices calls.
struct LiveAXTextBackend: AXTextBackend {

    func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &value
        )
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    func attributeNames(of element: AXUIElement) -> (status: AXError, names: [String]) {
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &names)
        return (status, (names as? [String]) ?? [])
    }

    private func raw(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard status == .success else { return nil }
        return value
    }

    func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        raw(element, name) as? String
    }

    func intAttribute(_ element: AXUIElement, _ name: String) -> Int? {
        (raw(element, name) as? NSNumber)?.intValue
    }

    func rangeAttribute(_ element: AXUIElement, _ name: String) -> TextEditingController.TextRange? {
        guard let value = raw(element, name), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return TextEditingController.textRange(from: unsafeDowncast(value, to: AXValue.self))
    }

    func setRangeAttribute(
        _ element: AXUIElement, _ name: String, location: Int, length: Int
    ) -> AXError {
        guard let value = TextEditingController.makeRangeValue(location: location, length: length) else {
            return .illegalArgument
        }
        return AXUIElementSetAttributeValue(element, name as CFString, value)
    }

    func setStringAttribute(_ element: AXUIElement, _ name: String, _ value: String) -> AXError {
        AXUIElementSetAttributeValue(element, name as CFString, value as CFTypeRef)
    }

    func boundsForRange(
        _ element: AXUIElement, location: Int, length: Int
    ) -> TextEditingController.Bounds? {
        guard let parameter = TextEditingController.makeRangeValue(location: location, length: length) else {
            return nil
        }
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result
        )
        guard status == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else {
            return nil
        }
        return TextEditingController.bounds(from: unsafeDowncast(result, to: AXValue.self))
    }

    func lineForIndex(_ element: AXUIElement, index: Int) -> Int? {
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXLineForIndexParameterizedAttribute as CFString,
            NSNumber(value: index),
            &result
        )
        guard status == .success else { return nil }
        return (result as? NSNumber)?.intValue
    }

    func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
        guard let parameter = TextEditingController.makeRangeValue(location: location, length: length) else {
            return nil
        }
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result
        )
        guard status == .success else { return nil }
        return result as? String
    }
}
