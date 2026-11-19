import Foundation

// Pure post-processing for AI output. The Vision / Speech calls live in StadaMAMAI;
// everything here is deterministic and unit-tested.

/// One recognised word with timing, as produced by a speech recogniser.
public struct TimedWord: Hashable, Sendable {
    public var text: String
    public var startSeconds: Double
    public var durationSeconds: Double

    public init(text: String, startSeconds: Double, durationSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }
}

public enum CaptionBuilder {
    /// Groups words into caption-sized segments, breaking on pauses, sentence ends and length.
    public static func segments(assetID: String, words: [TimedWord], maxCharacters: Int = 84,
                                maxSeconds: Double = 6, pauseSeconds: Double = 0.8) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [TimedWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(TranscriptSegment(
                assetID: assetID, startSeconds: first.startSeconds,
                endSeconds: last.startSeconds + last.durationSeconds,
                text: current.map(\.text).joined(separator: " ")))
            current = []
        }
        for word in words {
            if let first = current.first, let last = current.last {
                let gap = word.startSeconds - (last.startSeconds + last.durationSeconds)
                let length = current.reduce(0) { $0 + $1.text.count + 1 } + word.text.count
                let span = word.startSeconds + word.durationSeconds - first.startSeconds
                let sentenceEnded = last.text.last.map { ".?!".contains($0) } ?? false
                if gap > pauseSeconds || length > maxCharacters || span > maxSeconds || sentenceEnded { flush() }
            }
            current.append(word)
        }
        flush()
        return segments
    }

    public static func srt(_ segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(stamp(segment.startSeconds, ",")) --> \(stamp(segment.endSeconds, ","))\n\(segment.text)\n"
        }.joined(separator: "\n")
    }

    public static func webVTT(_ segments: [TranscriptSegment]) -> String {
        "WEBVTT\n\n" + segments.map { segment in
            "\(stamp(segment.startSeconds, ".")) --> \(stamp(segment.endSeconds, "."))\n\(segment.text)\n"
        }.joined(separator: "\n")
    }

    private static func stamp(_ seconds: Double, _ separator: String) -> String {
        let ms = Int((max(seconds, 0) * 1000).rounded())
        func pad(_ value: Int, _ width: Int) -> String {
            let s = String(value)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return "\(pad(ms / 3_600_000, 2)):\(pad(ms / 60_000 % 60, 2)):\(pad(ms / 1000 % 60, 2))\(separator)\(pad(ms % 1000, 3))"
    }
}

/// A label seen on one sampled frame.
public struct FrameLabel: Hashable, Sendable {
    public var label: String
    public var confidence: Double
    public var timeSeconds: Double

    public init(label: String, confidence: Double, timeSeconds: Double) {
        self.label = label
        self.confidence = confidence
        self.timeSeconds = timeSeconds
    }
}

public enum TagBuilder {
    /// Merges per-frame labels into time ranges: consecutive samples carrying the same label
    /// (no more than `maxGap` apart) become one tag with the peak confidence.
    public static func ranges(assetID: String, kind: TagKind, samples: [FrameLabel],
                              sampleInterval: Double, maxGap: Double? = nil) -> [SceneTag] {
        let gap = maxGap ?? sampleInterval * 1.5
        var tags: [SceneTag] = []
        for (_, group) in Dictionary(grouping: samples, by: \.label) {
            var open: SceneTag?
            for sample in group.sorted(by: { $0.timeSeconds < $1.timeSeconds }) {
                if var tag = open, sample.timeSeconds - (tag.endSeconds - sampleInterval) <= gap {
                    tag.endSeconds = sample.timeSeconds + sampleInterval
                    tag.confidence = max(tag.confidence, sample.confidence)
                    open = tag
                } else {
                    if let tag = open { tags.append(tag) }
                    open = SceneTag(assetID: assetID, kind: kind, label: sample.label, confidence: sample.confidence,
                                    startSeconds: sample.timeSeconds, endSeconds: sample.timeSeconds + sampleInterval)
                }
            }
            if let tag = open { tags.append(tag) }
        }
        return tags.sorted { ($0.startSeconds, $0.label) < ($1.startSeconds, $1.label) }
    }

    /// Turns frame-to-frame visual distances into shot ranges. A cut is declared where the
    /// distance jumps well above the clip's typical frame-to-frame change.
    public static func shots(assetID: String, sampleTimes: [Double], distances: [Double],
                             durationSeconds: Double, sensitivity: Double = 3) -> [SceneTag] {
        guard !sampleTimes.isEmpty, distances.count == sampleTimes.count - 1 else { return [] }
        let sorted = distances.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let threshold = max(median * sensitivity, 0.0001)
        var cuts: [Double] = [0]
        for (index, distance) in distances.enumerated() where distance > threshold {
            cuts.append(sampleTimes[index + 1])
        }
        cuts.append(durationSeconds)
        return zip(cuts, cuts.dropFirst()).enumerated().compactMap { index, range in
            range.1 > range.0
                ? SceneTag(assetID: assetID, kind: .shot, label: "Shot \(index + 1)", confidence: 1,
                           startSeconds: range.0, endSeconds: range.1)
                : nil
        }
    }
}

public enum FaceClusterer {
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denominator = (na * nb).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    /// Greedy centroid clustering. Sightings already assigned to a person seed that person's
    /// cluster, so naming someone once carries over to every later clip.
    /// Returns personID -> sighting IDs for sightings that were unassigned.
    public static func cluster(_ sightings: [FaceSighting], threshold: Float = 0.82) -> [String: [String]] {
        struct Cluster {
            var personID: String
            var sum: [Float]
            var count: Float
            var centroid: [Float] { sum.map { $0 / count } }
        }
        var clusters: [Cluster] = []
        func add(_ vector: [Float], to index: Int) {
            for i in vector.indices where i < clusters[index].sum.count { clusters[index].sum[i] += vector[i] }
            clusters[index].count += 1
        }
        for sighting in sightings {
            guard let personID = sighting.personID else { continue }
            if let index = clusters.firstIndex(where: { $0.personID == personID }) {
                add(sighting.vector, to: index)
            } else {
                clusters.append(Cluster(personID: personID, sum: sighting.vector, count: 1))
            }
        }
        var assignments: [String: [String]] = [:]
        for sighting in sightings where sighting.personID == nil {
            let vector = sighting.vector
            guard !vector.isEmpty else { continue }
            var best: (index: Int, similarity: Float)?
            for (index, cluster) in clusters.enumerated() {
                let similarity = cosineSimilarity(vector, cluster.centroid)
                if similarity >= threshold, similarity > (best?.similarity ?? -1) { best = (index, similarity) }
            }
            let index: Int
            if let best {
                index = best.index
                add(vector, to: index)
            } else {
                clusters.append(Cluster(personID: newID(), sum: vector, count: 1))
                index = clusters.count - 1
            }
            assignments[clusters[index].personID, default: []].append(sighting.id)
        }
        return assignments
    }
}
