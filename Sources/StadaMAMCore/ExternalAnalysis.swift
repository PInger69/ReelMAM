import Foundation

/// A service outside the app that can add to a clip's analysis. After the on-device pass, the
/// app sends the hook a description of the clip — its transcript and tags, never the media —
/// and merges what comes back.
public struct AnalysisHook: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// HTTPS address that receives a POST with an `ExternalAnalysisRequest` as JSON.
    public var url: String
    public var isEnabled: Bool

    public init(id: String = newID(), name: String = "", url: String = "", isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
    }
}

/// What a hook receives.
public struct ExternalAnalysisRequest: Codable, Sendable, Equatable {
    public struct Clip: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var durationSeconds: Double
        public var frameRate: Double
        public var width: Int
        public var height: Int
        public var format: String
        public var reel: String?
        public var notes: String
    }

    public struct Segment: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var text: String
    }

    public struct Tag: Codable, Sendable, Equatable {
        public var kind: String
        public var label: String
        public var start: Double
        public var end: Double
        public var confidence: Double?
    }

    public var version: Int
    public var clip: Clip
    public var transcript: [Segment]
    public var tags: [Tag]

    public init(asset: Asset, transcript: [TranscriptSegment], tags: [SceneTag]) {
        version = 1
        clip = Clip(id: asset.id, name: asset.fileName, durationSeconds: asset.durationSeconds,
                    frameRate: asset.frameRate.fps, width: asset.width, height: asset.height,
                    format: asset.formatName, reel: asset.reelName, notes: asset.notes)
        self.transcript = transcript.map { Segment(start: $0.startSeconds, end: $0.endSeconds, text: $0.text) }
        self.tags = tags.filter { $0.kind != .external && $0.kind != .summary }.map {
            Tag(kind: $0.kind.rawValue, label: $0.label, start: $0.startSeconds, end: $0.endSeconds,
                confidence: $0.confidence)
        }
    }
}

/// What a hook may send back. Every field is optional.
public struct ExternalAnalysisResponse: Codable, Sendable, Equatable {
    /// A description of the clip; shown in the inspector and searchable.
    public var summary: String?
    /// Extra time-ranged tags. `kind` is ignored: they are stored as external tags.
    public var tags: [ExternalAnalysisRequest.Tag]?

    public init(summary: String? = nil, tags: [ExternalAnalysisRequest.Tag]? = nil) {
        self.summary = summary
        self.tags = tags
    }

    /// Converts a response into catalog tags, clamped to the clip and with empty entries dropped.
    public func sceneTags(for asset: Asset) -> [SceneTag] {
        let duration = max(asset.durationSeconds, 0)
        var result: [SceneTag] = []
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            result.append(SceneTag(assetID: asset.id, kind: .summary, label: summary, confidence: 1,
                                   startSeconds: 0, endSeconds: duration))
        }
        for tag in tags ?? [] {
            let label = tag.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let start = min(max(tag.start, 0), duration)
            let end = min(max(tag.end, start), duration)
            result.append(SceneTag(assetID: asset.id, kind: .external, label: label,
                                   confidence: min(max(tag.confidence ?? 1, 0), 1),
                                   startSeconds: start, endSeconds: end))
        }
        return result
    }
}
