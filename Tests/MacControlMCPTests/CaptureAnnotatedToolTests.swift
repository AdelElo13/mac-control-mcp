import Testing
import Foundation
@testable import MacControlMCP

/// v0.9 workstream F — the `capture_annotated` TOOL surface.
///
/// Argument validation and registration only: anything that would actually
/// grab pixels is left to the live stdio probe, so `swift test` never
/// screenshots the developer's desktop or trips Screen Recording TCC.
@Suite("capture_annotated tool surface")
struct CaptureAnnotatedToolTests {

    static func registry() -> ToolRegistry {
        ToolRegistry(accessibility: AccessibilityController())
    }

    @Test("capture_annotated is registered and advertises its schema")
    func registeredWithSchema() throws {
        let definition = try #require(
            Self.registry().toolDefinitions.first { $0.name == "capture_annotated" }
        )
        let root = try #require(definition.inputSchema.objectValue)
        let properties = try #require(root["properties"]?.objectValue)
        for key in ["pid", "title_contains", "target", "max_depth", "max_elements",
                    "inline", "max_bytes", "format", "quality", "max_width"] {
            #expect(properties[key] != nil, "capture_annotated schema is missing \(key)")
        }
        // No required params: the frontmost app is the default target.
        #expect(root["required"] == nil)
        #expect(definition.description.contains("element_id"))
    }

    @Test("an unknown target is rejected before anything is captured")
    func rejectsUnknownTarget() async {
        let result = await Self.registry().callTool(
            name: "capture_annotated",
            arguments: ["pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                        "target": .string("hologram")]
        )
        #expect(result.isError)
        #expect(result.text.contains("target"))
    }

    @Test("a pid that belongs to no process fails honestly")
    func rejectsDeadPID() async {
        let result = await Self.registry().callTool(
            name: "capture_annotated", arguments: ["pid": .number(999_999)]
        )
        #expect(result.isError)
        let payload = result.structuredContent.objectValue ?? [:]
        #expect(payload["ok"] == .bool(false))
    }

    @Test("a non-numeric pid is an invalid_argument")
    func rejectsBadPID() async {
        let result = await Self.registry().callTool(
            name: "capture_annotated", arguments: ["pid": .string("frontmost")]
        )
        #expect(result.isError)
        #expect(result.text.contains("pid"))
    }

    @Test("image-output options are validated the same way as capture_screen_v2")
    func rejectsBadImageOptions() async {
        let result = await Self.registry().callTool(
            name: "capture_annotated",
            arguments: [
                "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "quality": .number(70)
            ]
        )
        #expect(result.isError)
        #expect(result.text.contains("quality"))
    }

    @Test("the annotate element filter is the drawn-box contract")
    func defaultsAreDocumented() {
        // The description quotes these numbers; keep them in one place.
        #expect(ToolRegistry.AnnotateDefaults.maxDepth == 24)
        #expect(ToolRegistry.AnnotateDefaults.maxElements == 200)
        #expect(ToolRegistry.AnnotateDefaults.maxElements <= ToolRegistry.AnnotateDefaults.maxElementsCeiling)
    }
}
