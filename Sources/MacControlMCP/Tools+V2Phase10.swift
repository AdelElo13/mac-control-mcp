import Foundation

// MARK: - Tool definitions (v0.7.0 Phase 10: complete surface)
//
// 13 new tools closing v0.6.0 substrate-gaps + top-5 capability gaps:
//
//   A1 → capture_screen_v2 / artifact_gc
//   F2 → undo_last_action + undo_peek
//   Voice/recording: speech_to_text, text_to_speech, audio_record,
//                    record_screen
//   Browser DOM layers: browser_dom_tree, browser_visible_text,
//                       browser_iframes
//   Apple native: foundation_models_generate, list_app_intents,
//                 invoke_app_intent

extension ToolRegistry {
    static let definitionsV2Phase10: [MCPToolDefinition] = [

        // MARK: A1 — image-size discipline (via new capture_screen_v2)

        MCPToolDefinition(
            name: "capture_screen_v2",
            description: """
                Capture the main display, store as a content-addressed \
                artifact at ~/.mac-control-mcp/artifacts/<sha256>.png, and \
                return {content_ref, bytes, sha256}. Default inline=false \
                prevents context-size blowups (claude-code #13383, #45785). \
                Optional max_dimension (default 4000px) and max_bytes \
                (default 4MB) downscale before return.
                """,
            inputSchema: schema(
                properties: [
                    "inline": .object(["type": .string("boolean")]),
                    "max_dimension": .object(["type": .array([.string("integer"), .string("string")])]),
                    "max_bytes": .object(["type": .array([.string("integer"), .string("string")])])
                ]
            )
        ),
        MCPToolDefinition(
            name: "artifact_gc",
            description: "Force a sweep of expired artifacts at ~/.mac-control-mcp/artifacts/ (normally auto-swept on every store).",
            inputSchema: schema(properties: [:])
        ),

        // MARK: F2 — undo

        MCPToolDefinition(
            name: "undo_last_action",
            description: """
                Undo the most recent destructive tool call(s) using \
                pre-image snapshots. Pops from the LRU queue (depth 20). \
                Returns {undone: [...], failed: [...], remaining}. \
                Best-effort: not cross-crash persistent, not transactional \
                across external app activity.
                """,
            inputSchema: schema(
                properties: [
                    "steps": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("How many steps to undo (default 1).")
                    ])
                ]
            )
        ),
        MCPToolDefinition(
            name: "undo_peek",
            description: "Return the current undo queue without popping. Read-only introspection.",
            inputSchema: schema(properties: [:])
        ),

        // MARK: Voice + recording

        MCPToolDefinition(
            name: "speech_to_text",
            description: """
                Transcribe an audio file via Apple's Speech framework. \
                On-device when supported. Triggers Speech Recognition TCC \
                prompt on first use.
                """,
            inputSchema: schema(
                properties: [
                    "audio_path": .object(["type": .string("string")]),
                    "language": .object(["type": .string("string")])
                ],
                required: ["audio_path"]
            )
        ),
        MCPToolDefinition(
            name: "text_to_speech",
            description: """
                Speak text aloud via AVSpeechSynthesizer (default) or \
                write to an AIFF/WAV file via /usr/bin/say (when \
                output_path is set).
                """,
            inputSchema: schema(
                properties: [
                    "text": .object(["type": .string("string")]),
                    "voice": .object(["type": .string("string")]),
                    "output_path": .object(["type": .string("string")])
                ],
                required: ["text"]
            )
        ),
        MCPToolDefinition(
            name: "audio_record",
            description: """
                Record <seconds> of microphone audio to an M4A file. \
                Triggers Microphone TCC prompt on first use. Default \
                output ~/Desktop/mac-control-mcp-<ts>.m4a.
                """,
            inputSchema: schema(
                properties: [
                    "seconds": .object(["type": .string("number")]),
                    "output_path": .object(["type": .string("string")])
                ],
                required: ["seconds"]
            )
        ),
        MCPToolDefinition(
            name: "record_screen",
            description: """
                Record <seconds> of main-display video via /usr/sbin/screencapture \
                (sanctioned macOS binary; auto-handles TCC). MP4 output.
                """,
            inputSchema: schema(
                properties: [
                    "seconds": .object(["type": .string("number")]),
                    "output_path": .object(["type": .string("string")]),
                    "include_audio": .object(["type": .string("boolean")])
                ],
                required: ["seconds"]
            )
        ),

        // MARK: Browser DOM layers

        MCPToolDefinition(
            name: "browser_dom_tree",
            description: """
                Walk the DOM of the active tab INCLUDING Shadow DOM and \
                open shadow roots. Returns a tree of {tag, id, classes, \
                text, role, isShadow, children}. Works in Safari + Chrome \
                via browser_eval_js under the hood.
                """,
            inputSchema: schema(
                properties: [
                    "browser": .object(["type": .string("string")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "browser_visible_text",
            description: """
                Return all currently-visible text (filters display:none \
                and visibility:hidden). Faster than dom_tree when you \
                just want 'what does the user see'.
                """,
            inputSchema: schema(
                properties: [
                    "browser": .object(["type": .string("string")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "browser_iframes",
            description: """
                List every <iframe>, same-origin status, size, and \
                (when same-origin) a text summary of its contentDocument. \
                Cross-origin iframes fail-closed with sameOrigin=false.
                """,
            inputSchema: schema(
                properties: [
                    "browser": .object(["type": .string("string")])
                ]
            )
        ),

        // MARK: Apple native

        MCPToolDefinition(
            name: "foundation_models_generate",
            description: """
                Generate text via Apple's Foundation Models framework \
                (macOS Tahoe 26+, Apple Intelligence). On-device, free, \
                offline. Gracefully reports 'not available' when framework \
                missing.
                """,
            inputSchema: schema(
                properties: [
                    "prompt": .object(["type": .string("string")]),
                    "system": .object(["type": .string("string")])
                ],
                required: ["prompt"]
            )
        ),
        MCPToolDefinition(
            name: "list_app_intents",
            description: """
                Enumerate installed apps that ship App Intents metadata \
                (via Info.plist AppShortcuts / Intents keys). Returns \
                {bundleId, appName, intentCount}.
                """,
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "invoke_app_intent",
            description: """
                Invoke a named App Intent by routing through /usr/bin/shortcuts. \
                User must have a Shortcut with the exact intent name. \
                Returns stdout of the shortcut invocation.
                """,
            inputSchema: schema(
                properties: [
                    "bundle_id": .object(["type": .string("string")]),
                    "intent": .object(["type": .string("string")]),
                    "input": .object(["type": .string("string")])
                ],
                required: ["bundle_id", "intent"]
            )
        )
    ]

    // MARK: - Handlers

    // A1

    func callCaptureScreenV2(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let inline = arguments["inline"]?.boolValue ?? false
        let maxDim = arguments["max_dimension"]?.intValue ?? 4000
        let maxBytes = arguments["max_bytes"]?.intValue ?? (4 * 1024 * 1024)
        // First capture to a temp file via existing ScreenController path.
        do {
            let tmpDir = NSTemporaryDirectory()
            let tmpPath = tmpDir + "mc-\(Int(Date().timeIntervalSince1970)).png"
            let capture = try await screen.captureDisplay(outputPath: tmpPath)
            guard let artifact = await artifactStore.storeImage(
                sourcePath: capture.path,
                maxBytes: maxBytes,
                maxDimension: maxDim
            ) else {
                return errorResult(
                    "image exceeds max_bytes=\(maxBytes) even after downscale — try smaller max_dimension",
                    ["ok": .bool(false)]
                )
            }
            try? FileManager.default.removeItem(atPath: tmpPath)
            var payload: [String: JSONValue] = [
                "ok": .bool(true),
                "content_ref": .string(artifact.contentRef),
                "bytes": .number(Double(artifact.bytes)),
                "sha256": .string(artifact.sha256),
                "mime_type": .string(artifact.mimeType),
                "_schema": .string(artifact.schema)
            ]
            if inline, let data = try? Data(contentsOf: URL(fileURLWithPath: artifact.contentRef)) {
                payload["inline_base64"] = .string(data.base64EncodedString())
            }
            return successResult(
                "captured to \(artifact.contentRef) (\(artifact.bytes) bytes)",
                payload
            )
        } catch {
            return errorResult(
                "capture_screen_v2 failed: \(error)",
                ["ok": .bool(false), "error": .string(String(describing: error))]
            )
        }
    }

    func callArtifactGC() async -> ToolCallResult {
        await artifactStore.gcExpired()
        return successResult("artifact gc complete", ["ok": .bool(true)])
    }

    // F2

    func callUndoLastAction(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let steps = arguments["steps"]?.intValue ?? 1
        let r = await undo.undo(steps: steps)
        let msg = "undone: \(r.undone.count), failed: \(r.failed.count), remaining: \(r.remaining)"
        return r.ok
            ? successResult(msg, ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(msg, ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callUndoPeek() async -> ToolCallResult {
        let q = await undo.peek()
        return successResult("undo queue: \(q.count) entries",
                             ["ok": .bool(true), "entries": encodeAsJSONValue(q)])
    }

    // Voice

    func callSpeechToText(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let audioPath = arguments["audio_path"]?.stringValue, !audioPath.isEmpty else {
            return invalidArgument("speech_to_text requires 'audio_path'.")
        }
        let lang = arguments["language"]?.stringValue ?? "en-US"
        let r = await voice.speechToText(audioPath: audioPath, language: lang)
        return r.ok
            ? successResult("transcribed: \(r.text?.count ?? 0) chars",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "speech_to_text failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callTextToSpeech(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
            return invalidArgument("text_to_speech requires 'text'.")
        }
        let voiceName = arguments["voice"]?.stringValue
        let output = arguments["output_path"]?.stringValue
        let r = await voice.textToSpeech(text: text, voice: voiceName, outputPath: output)
        return r.ok
            ? successResult("spoke (\(r.mode))",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "text_to_speech failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callAudioRecord(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let seconds = arguments["seconds"]?.doubleValue else {
            return invalidArgument("audio_record requires 'seconds'.")
        }
        let output = arguments["output_path"]?.stringValue
        let r = await voice.audioRecord(seconds: seconds, outputPath: output)
        return r.ok
            ? successResult("recorded \(r.seconds)s → \(r.outputPath ?? "?")",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "audio_record failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callRecordScreen(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let seconds = arguments["seconds"]?.doubleValue else {
            return invalidArgument("record_screen requires 'seconds'.")
        }
        let output = arguments["output_path"]?.stringValue
        let includeAudio = arguments["include_audio"]?.boolValue ?? false
        let r = await voice.recordScreen(
            seconds: seconds,
            outputPath: output,
            includeAudio: includeAudio
        )
        return r.ok
            ? successResult("recorded \(r.seconds)s → \(r.outputPath ?? "?")",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "record_screen failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    // Browser DOM

    func callBrowserDOMTree(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let b = arguments["browser"]?.stringValue ?? "safari"
        let r = await browserDOM.domTree(browser: b)
        return r.ok
            ? successResult("dom tree: \(r.nodeCount) nodes",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "browser_dom_tree failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callBrowserVisibleText(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let b = arguments["browser"]?.stringValue ?? "safari"
        let r = await browserDOM.visibleText(browser: b)
        return r.ok
            ? successResult("\(r.charCount) chars visible",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "browser_visible_text failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callBrowserIframes(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let b = arguments["browser"]?.stringValue ?? "safari"
        let r = await browserDOM.iframes(browser: b)
        return r.ok
            ? successResult("\(r.count) iframe(s)",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "browser_iframes failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    // Apple native

    func callFoundationModelsGenerate(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let prompt = arguments["prompt"]?.stringValue, !prompt.isEmpty else {
            return invalidArgument("foundation_models_generate requires 'prompt'.")
        }
        let system = arguments["system"]?.stringValue
        let r = await appleNative.foundationModelsGenerate(prompt: prompt, system: system)
        return r.ok
            ? successResult("generated \(r.text?.count ?? 0) chars",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.hint ?? r.error ?? "foundation_models_generate failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callListAppIntents() async -> ToolCallResult {
        let r = await appleNative.listAppIntents()
        return successResult("found \(r.apps.count) app(s) with Intents metadata",
                             ["ok": .bool(true), "result": encodeAsJSONValue(r)])
    }

    func callInvokeAppIntent(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let bundleID = arguments["bundle_id"]?.stringValue, !bundleID.isEmpty,
              let intent = arguments["intent"]?.stringValue, !intent.isEmpty else {
            return invalidArgument("invoke_app_intent requires 'bundle_id' and 'intent'.")
        }
        let input = arguments["input"]?.stringValue
        let r = await appleNative.invokeAppIntent(
            bundleId: bundleID, intent: intent, input: input
        )
        return r.ok
            ? successResult("invoked \(intent)",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.stderr ?? "invoke_app_intent failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }
}
