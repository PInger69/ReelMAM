#if canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import Foundation
import StadaMAMCore
import Speech

public enum AnalysisError: Error, LocalizedError {
    case speechNotAuthorized
    case speechUnavailable
    case audioExportFailed
    case noAudio
    case recognitionTimedOut

    public var errorDescription: String? {
        switch self {
        case .speechNotAuthorized: return "Speech recognition is not authorised. Enable it in System Settings › Privacy & Security."
        case .speechUnavailable: return "Speech recognition is not available for this language on this Mac."
        case .audioExportFailed: return "The clip's audio could not be read."
        case .noAudio: return "This clip has no audio to transcribe."
        case .recognitionTimedOut: return "Speech recognition stopped responding."
        }
    }
}

/// What a dialogue pass produced, including what it could not do.
public struct Transcription: Sendable {
    public var segments: [TranscriptSegment]
    /// Stretches that were too quiet to hold speech and were left alone.
    public var silentSeconds: Double
    /// Stretches the recogniser failed on; the rest of the clip is still transcribed.
    public var failedStretches: Int
    public var firstError: String?
    /// Which channels were listened to, e.g. "track 1 ch 3".
    public var listenedTo: [String]

    /// A plain-language caveat for the person logging the footage, or nil when all is well.
    public var warning: String? {
        if segments.isEmpty, failedStretches > 0 {
            return "No dialogue could be read (\(firstError ?? "recognition failed"))."
        }
        if failedStretches > 0 {
            return "\(failedStretches) stretch\(failedStretches == 1 ? "" : "es") of dialogue could not be read."
        }
        return nil
    }
}

/// Dialogue-to-text using Apple's recogniser, on-device whenever the Mac supports it.
///
/// A scene is transcribed the way a script supervisor listens: every live microphone channel,
/// in pieces short enough for the recogniser to stay accurate, with the vocabulary of a film
/// set (slate, take, sticks, room tone) primed, and silence left alone.
public enum Transcriber {
    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// Transcribes a clip into caption-sized, time-coded segments.
    public static func transcribe(mediaURL: URL, assetID: String, locale: Locale = .current,
                                  extraVocabulary: [String] = [],
                                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcription {
        guard await requestAuthorization() else { throw AnalysisError.speechNotAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { throw AnalysisError.speechUnavailable }

        let audio = try await SpeechAudio.open(url: mediaURL)
        let chunks = SpeechChunker.plan(levels: audio.levels, window: SpeechAudio.windowSeconds)
        let vocabulary = Array(Set(CinemaVocabulary.setVocabulary + extraVocabulary)).sorted()

        var words: [TimedWord] = []
        var silent = 0.0, failed = 0
        var firstError: String?
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress?(Double(index) / Double(max(chunks.count, 1)))
            if chunk.level < SpeechChunker.silenceLevel {
                silent += chunk.end - chunk.start
                continue
            }
            do {
                let samples = try audio.samples(from: chunk.start, to: chunk.end)
                let file = try SpeechAudio.write(samples, name: "speech")
                defer { try? FileManager.default.removeItem(at: file) }
                let heard = try await recognise(file: file, with: recognizer, vocabulary: vocabulary)
                // A recogniser fed room tone answers with a stray word or two ("thank you").
                if chunk.level < 0.02, heard.count <= 3 { continue }
                words += heard.map {
                    TimedWord(text: $0.text, startSeconds: $0.startSeconds + chunk.start, durationSeconds: $0.durationSeconds)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1
                firstError = firstError ?? error.localizedDescription
            }
        }
        progress?(1)
        let listened = audio.sources.map { "track \($0.track + 1) ch \($0.channel + 1)" }.sorted()
        return Transcription(segments: CaptionBuilder.segments(assetID: assetID, words: words),
                             silentSeconds: silent, failedStretches: failed, firstError: firstError,
                             listenedTo: listened)
    }

    private static func recognise(file: URL, with recognizer: SFSpeechRecognizer,
                                  vocabulary: [String]) async throws -> [TimedWord] {
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = vocabulary

        let state = RecognitionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        state.finish { continuation.resume(returning: result.bestTranscription.segments.map {
                            TimedWord(text: $0.substring, startSeconds: $0.timestamp, durationSeconds: $0.duration)
                        }) }
                    } else if let error {
                        // "No speech detected" is an answer, not a failure.
                        let code = (error as NSError).code
                        if code == 1110 || code == 203 {
                            state.finish { continuation.resume(returning: []) }
                        } else {
                            state.finish { continuation.resume(throwing: error) }
                        }
                    }
                }
                state.task = task
                // Recognition of a 45-second stretch takes seconds; a stuck request must not hang the queue.
                DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
                    state.finish {
                        task.cancel()
                        continuation.resume(throwing: AnalysisError.recognitionTimedOut)
                    }
                }
            }
        } onCancel: {
            state.task?.cancel()
        }
    }

    private final class RecognitionState: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var task: SFSpeechRecognitionTask?

        /// Runs `body` only the first time it is called.
        func finish(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }
}

/// Pulls a clip's sound out into a temporary file the sound classifier can read.
enum AudioExtractor {
    static func extract(from url: URL) async throws -> URL {
        let audio = try await SpeechAudio.open(url: url)
        return try audio.mixdownFile()
    }
}
#endif
