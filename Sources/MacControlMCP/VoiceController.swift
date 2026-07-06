import Foundation
import AVFoundation
#if canImport(Speech)
import Speech
#endif

/// Voice + recording surface for v0.7.0.  Four tools ship under this
/// controller:
///
///   - `speech_to_text(audio_path OR record_seconds)` — Apple Speech
///     framework, on-device when supported.  Triggers Speech Recognition
///     TCC permission on first use.
///   - `text_to_speech(text, voice?, output_path?)` — AVSpeechSynthesizer.
///     Either speaks aloud OR writes an AIFF/WAV file depending on
///     `output_path`.
///   - `audio_record(seconds, output_path?)` — AVAudioRecorder.
///     Triggers Microphone TCC on first use.
///   - `record_screen(seconds, output_path?, include_audio?)` —
///     ScreenCaptureKit (macOS 14+) MP4 output.  Triggers Screen
///     Recording TCC on first use.
///
/// All paths that touch TCC degrade gracefully with a structured
/// `{ok:false, hint: "..."}` result rather than crashing.
/// Keeps `AVSpeechSynthesizer` instances alive for the duration of an
/// utterance. `text_to_speech` speak-mode created a local synthesizer that
/// was deallocated the moment the call returned, cancelling speech before a
/// word came out (while still reporting ok:true). This retains each
/// synthesizer until its delegate reports the utterance finished/cancelled.
@MainActor
final class SpeechRetainer: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
    static let shared = SpeechRetainer()
    // Keyed by ObjectIdentifier (Sendable) so the nonisolated delegate
    // callbacks can schedule removal without capturing the non-Sendable
    // synthesizer across the actor hop.
    private var active: [ObjectIdentifier: AVSpeechSynthesizer] = [:]

    func speak(_ utterance: AVSpeechUtterance, with synth: AVSpeechSynthesizer) {
        synth.delegate = self
        active[ObjectIdentifier(synth)] = synth
        synth.speak(utterance)
    }

    func speechSynthesizer(_ synth: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        active.removeValue(forKey: ObjectIdentifier(synth))
    }
    func speechSynthesizer(_ synth: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        active.removeValue(forKey: ObjectIdentifier(synth))
    }
}

actor VoiceController {

    public struct SpeechResult: Codable, Sendable {
        public let ok: Bool
        public let text: String?
        public let language: String?
        public let error: String?
    }

    public struct SynthesisResult: Codable, Sendable {
        public let ok: Bool
        public let mode: String    // "speak" | "file"
        public let outputPath: String?
        public let error: String?
    }

    public struct RecordResult: Codable, Sendable {
        public let ok: Bool
        public let outputPath: String?
        public let seconds: Double
        public let error: String?
    }

    // MARK: - Speech-to-text

    /// Transcribe audio from a file path to text. `language` defaults to
    /// `en-US`.  For record-then-transcribe, call `audioRecord` first and
    /// pass the output path here.
    func speechToText(audioPath: String, language: String = "en-US") async -> SpeechResult {
        #if canImport(Speech)
        // v0.8.0: guard against bundles without NSSpeechRecognitionUsageDescription
        // in Info.plist. Without this key, SFSpeechRecognizer.authorizationStatus()
        // raises SIGABRT (TCC violation), which crashes XCTest runners whose
        // bundle has no Info.plist. The production .app gets the key via
        // build-bundle.sh; tests get a clean structured refusal.
        guard Bundle.main.infoDictionary?["NSSpeechRecognitionUsageDescription"] != nil else {
            return SpeechResult(ok: false, text: nil, language: language,
                                error: "NSSpeechRecognitionUsageDescription missing from Info.plist")
        }
        guard SFSpeechRecognizer.authorizationStatus() != .denied else {
            return SpeechResult(ok: false, text: nil, language: language,
                                error: "Speech Recognition TCC denied — grant in System Settings → Privacy & Security → Speech Recognition")
        }
        // Trigger the TCC prompt on first use.
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return SpeechResult(ok: false, text: nil, language: language,
                                error: "Speech Recognition authorization not granted")
        }
        guard FileManager.default.fileExists(atPath: audioPath) else {
            return SpeechResult(ok: false, text: nil, language: language,
                                error: "audio file not found: \(audioPath)")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            return SpeechResult(ok: false, text: nil, language: language,
                                error: "no recognizer for locale \(language)")
        }
        let url = URL(fileURLWithPath: audioPath)
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        // Hold strong refs to the recognizer + task and enforce a timeout.
        // The old code resumed only on error or `isFinal`, so a recognition
        // that stalls (e.g. server-side path when on-device isn't supported,
        // with no/slow network) left the continuation — and the tool call —
        // hanging forever. The lock-guarded box makes single-resume and the
        // cross-thread ref lifetime safe.
        let timeout: TimeInterval = 30
        return await withCheckedContinuation { continuation in
            final class State: @unchecked Sendable {
                let lock = NSLock()
                var resumed = false
                var task: SFSpeechRecognitionTask?
                var recognizer: SFSpeechRecognizer?
            }
            let state = State()
            state.recognizer = recognizer

            let finish: @Sendable (SpeechResult) -> Void = { result in
                state.lock.lock()
                if state.resumed { state.lock.unlock(); return }
                state.resumed = true
                let task = state.task
                state.task = nil
                state.recognizer = nil   // release the strong ref
                state.lock.unlock()
                task?.cancel()
                continuation.resume(returning: result)
            }

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    finish(SpeechResult(ok: false, text: nil, language: language,
                                        error: "recognition failed: \(error.localizedDescription)"))
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    finish(SpeechResult(ok: true,
                                        text: result.bestTranscription.formattedString,
                                        language: language, error: nil))
                }
            }
            state.lock.lock(); state.task = task; state.lock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(SpeechResult(ok: false, text: nil, language: language,
                                    error: "speech recognition timed out after \(Int(timeout))s"))
            }
        }
        #else
        return SpeechResult(ok: false, text: nil, language: language,
                            error: "Speech framework not available on this build")
        #endif
    }

    // MARK: - Text-to-speech

    /// Either speak `text` aloud (default) or write an audio file.
    /// AVSpeechSynthesizer is not an actor-safe class — we pin its work
    /// to a MainActor hop.  File output requires macOS 13+ via the
    /// `write(_:toBufferCallback:)` API; on earlier systems it falls
    /// back to system `say` (which always speaks aloud and can write
    /// an AIFF when a path is provided).
    func textToSpeech(text: String, voice: String?, outputPath: String?) async -> SynthesisResult {
        if let outputPath {
            // Route to `say` — the simplest way to write an AIFF without
            // dragging in AVAudioEngine tap plumbing.  `say` ships on every
            // macOS.
            var args: [String] = ["-o", outputPath]
            if let voice, !voice.isEmpty { args.append(contentsOf: ["-v", voice]) }
            args.append(text)
            let r = ProcessRunner.run("/usr/bin/say", args, timeout: 60)
            return SynthesisResult(
                ok: r.ok,
                mode: "file",
                outputPath: r.ok ? outputPath : nil,
                error: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        // Speak aloud via AVSpeechSynthesizer on the main actor. The
        // synthesizer is retained by SpeechRetainer until the utterance
        // finishes — a local instance would be deallocated immediately,
        // cancelling speech before anything is heard.
        let synthesisError = await MainActor.run { () -> String? in
            let synth = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: text)
            if let voice,
               let avVoice = AVSpeechSynthesisVoice(identifier: voice)
                   ?? AVSpeechSynthesisVoice(language: voice) {
                utterance.voice = avVoice
            }
            SpeechRetainer.shared.speak(utterance, with: synth)
            return nil
        }
        return SynthesisResult(ok: synthesisError == nil, mode: "speak",
                               outputPath: nil, error: synthesisError)
    }

    // MARK: - Audio record

    /// Record `seconds` of microphone audio to `outputPath`.  Uses
    /// AVAudioRecorder with 44.1 kHz AAC — the macOS stock "voice memo"
    /// profile.  Triggers Microphone TCC prompt on first call.
    func audioRecord(seconds: Double, outputPath: String?) async -> RecordResult {
        let clamped = max(0.5, min(seconds, 300))
        let finalPath = outputPath ?? defaultOutputPath(extension: "m4a")

        // Ensure parent directory exists (any path under allowed roots).
        let parentDir = (finalPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parentDir, withIntermediateDirectories: true
        )

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let url = URL(fileURLWithPath: finalPath)
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            return RecordResult(
                ok: false, outputPath: nil, seconds: 0,
                error: "AVAudioRecorder init failed: \(error.localizedDescription). If this is a TCC rejection, grant Microphone in System Settings → Privacy & Security → Microphone."
            )
        }

        guard recorder.record() else {
            return RecordResult(
                ok: false, outputPath: nil, seconds: 0,
                error: "recorder.record() returned false — Microphone permission missing?"
            )
        }

        // Use Task.sleep to yield the actor while we capture.
        try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
        recorder.stop()

        return RecordResult(
            ok: true, outputPath: finalPath, seconds: clamped, error: nil
        )
    }

    // MARK: - Screen record

    /// Record `seconds` of the main display to an MP4 at `outputPath`.
    /// v0.7.0 ships a **shell-out to `screencapture -v -V <seconds>`** —
    /// macOS's built-in Screen Capture utility — because it handles the
    /// TCC prompt, audio device plumbing, and encoding without us needing
    /// to reimplement ScreenCaptureKit plumbing. The underlying binary
    /// is signed + sanctioned; no private API.
    func recordScreen(seconds: Double, outputPath: String?, includeAudio: Bool) async -> RecordResult {
        let clamped = max(1.0, min(seconds, 600))
        let finalPath = outputPath ?? defaultOutputPath(extension: "mov")
        let parentDir = (finalPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parentDir, withIntermediateDirectories: true
        )

        // `screencapture -v` is the video-mode flag; `-V <seconds>` caps
        // the duration. Audio flag is `-g` (also known as `-gr`). `-x`
        // silences the capture sound.
        var args: [String] = ["-v", "-V", "\(Int(clamped))", "-x"]
        if includeAudio { args.append("-g") }
        args.append(finalPath)

        let r = ProcessRunner.run("/usr/sbin/screencapture", args,
                                  timeout: clamped + 10)
        if !r.ok {
            return RecordResult(
                ok: false, outputPath: nil, seconds: 0,
                error: "screencapture failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)). If this is a TCC rejection, grant Screen Recording in System Settings → Privacy & Security → Screen Recording."
            )
        }
        guard FileManager.default.fileExists(atPath: finalPath) else {
            return RecordResult(
                ok: false, outputPath: nil, seconds: 0,
                error: "screencapture returned 0 but no file at \(finalPath)"
            )
        }
        return RecordResult(
            ok: true, outputPath: finalPath, seconds: clamped, error: nil
        )
    }

    // MARK: - Helpers

    private func defaultOutputPath(extension ext: String) -> String {
        let ts = Int(Date().timeIntervalSince1970)
        let home = NSHomeDirectory()
        return "\(home)/Desktop/mac-control-mcp-\(ts).\(ext)"
    }
}
