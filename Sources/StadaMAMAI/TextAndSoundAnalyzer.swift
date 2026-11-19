#if canImport(NaturalLanguage) && canImport(SoundAnalysis) && canImport(AVFoundation)
import AVFoundation
import Foundation
import NaturalLanguage
import SoundAnalysis
import StadaMAMCore

/// Understanding of the words in a transcript, using Apple's on-device language models.
public enum TextAnalyzer {
    /// People, places and organisations named in the speech, each at the moment it is said.
    public static func entities(in segments: [TranscriptSegment], assetID: String) -> [SceneTag] {
        let wanted: Set<NLTag> = [.personalName, .placeName, .organizationName]
        let tagger = NLTagger(tagSchemes: [.nameType])
        var tags: [SceneTag] = []
        for segment in segments {
            let text = segment.text
            tagger.string = text
            var seen = Set<String>()
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
                if let tag, wanted.contains(tag) {
                    let name = String(text[range])
                    if seen.insert(name.lowercased()).inserted {
                        tags.append(SceneTag(assetID: assetID, kind: .entity, label: name, confidence: 1,
                                             startSeconds: segment.startSeconds, endSeconds: segment.endSeconds))
                    }
                }
                return true
            }
        }
        return tags
    }

    /// The language most of the text is in, as a BCP-47 code ("en", "fr").
    public static func dominantLanguage(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }
}

/// Classifies what is heard in a clip — speech, music, applause, traffic and several hundred
/// other sounds — with Apple's on-device sound classifier.
public enum SoundAnalyzer {
    public static func classify(mediaURL: URL, assetID: String, minimumConfidence: Double = 0.6) async throws -> [SceneTag] {
        let audioURL = try await AudioExtractor.extract(from: mediaURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let collector = Collector(minimumConfidence: minimumConfidence)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let analyzer = try SNAudioFileAnalyzer(url: audioURL)
        try analyzer.add(request, withObserver: collector)
        // Analysis is synchronous; keep it off the Swift concurrency threads.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                analyzer.analyze()
                continuation.resume()
            }
        }
        let samples = collector.samples
        let times = samples.map(\.timeSeconds).sorted()
        let steps = zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        let interval = steps.min() ?? 1.5
        return TagBuilder.ranges(assetID: assetID, kind: .sound, samples: samples, sampleInterval: interval)
    }

    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [FrameLabel] = []
        private let minimumConfidence: Double

        init(minimumConfidence: Double) {
            self.minimumConfidence = minimumConfidence
        }

        var samples: [FrameLabel] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult, let top = result.classifications.first,
                  top.confidence >= minimumConfidence else { return }
            let label = top.identifier.replacingOccurrences(of: "_", with: " ")
            lock.lock()
            stored.append(FrameLabel(label: label, confidence: top.confidence,
                                     timeSeconds: result.timeRange.start.seconds))
            lock.unlock()
        }
    }
}
#endif
