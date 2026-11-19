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

    public var errorDescription: String? {
        switch self {
        case .speechNotAuthorized: return "Speech recognition is not authorised. Enable it in System Settings › Privacy & Security."
        case .speechUnavailable: return "Speech recognition is not available for this language on this Mac."
        case .audioExportFailed: return "The clip's audio could not be read."
        case .noAudio: return "This clip has no audio to transcribe."
        }
    }
}

/// Speech-to-text using Apple's recogniser, kept on-device whenever the Mac supports it.
public enum Transcriber {
    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// Transcribes a clip into caption-sized, time-coded segments.
    public static func transcribe(mediaURL: URL, assetID: String,
                                  locale: Locale = .current) async throws -> [TranscriptSegment] {
        guard await requestAuthorization() else { throw AnalysisError.speechNotAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { throw AnalysisError.speechUnavailable }

        let audioURL = try await extractAudio(from: mediaURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true

        let words: [TimedWord] = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.segments.map {
                        TimedWord(text: $0.substring, startSeconds: $0.timestamp, durationSeconds: $0.duration)
                    })
                } else if let error {
                    finished = true
                    continuation.resume(throwing: error)
                }
            }
        }
        return CaptionBuilder.segments(assetID: assetID, words: words)
    }

    private static func extractAudio(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw AnalysisError.noAudio }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AnalysisError.audioExportFailed
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("stadamam-audio-\(UUID().uuidString).m4a")
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else { throw export.error ?? AnalysisError.audioExportFailed }
        return output
    }
}
#endif
