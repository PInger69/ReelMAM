import Foundation

/// Decodes `ffprobe -print_format json -show_format -show_streams` output.
public struct FFProbeResult: Decodable, Sendable {
    public struct Stream: Decodable, Sendable {
        public var codec_type: String?
        public var codec_name: String?
        public var width: Int?
        public var height: Int?
        public var r_frame_rate: String?
        public var avg_frame_rate: String?
        public var nb_frames: String?
        public var duration: String?
        public var channels: Int?
        public var color_space: String?
        public var tags: [String: String]?
    }

    public struct Format: Decodable, Sendable {
        public var format_name: String?
        public var duration: String?
        public var size: String?
        public var tags: [String: String]?
    }

    public var streams: [Stream]
    public var format: Format

    public static let arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams"]

    public init(json: Data) throws {
        self = try JSONDecoder().decode(FFProbeResult.self, from: json)
    }

    private func tag(_ key: String) -> String? {
        let all = [format.tags] + streams.map(\.tags)
        for tags in all {
            if let value = tags?.first(where: { $0.key.lowercased() == key })?.value, !value.isEmpty { return value }
        }
        return nil
    }

    /// The catalog asset ID embedded in a proxy, if this file is one of ours.
    public var embeddedAssetID: String? { tag(ProxyMetadataKey.assetID) }
    public var embeddedSourcePath: String? { tag(ProxyMetadataKey.sourcePath) }
    public var timecodeString: String? { tag("timecode") }

    /// Builds a catalog asset from the probe. Returns nil when the file has no video stream.
    public func asset(path: String) -> Asset? {
        guard let video = streams.first(where: { $0.codec_type == "video" }) else { return nil }
        let rate = [video.r_frame_rate, video.avg_frame_rate]
            .compactMap { $0 }.filter { $0 != "0/0" }.compactMap(FrameRate.init(string:)).first ?? .fps24
        let seconds = Double(video.duration ?? "") ?? Double(format.duration ?? "") ?? 0
        let frames = Int(video.nb_frames ?? "") ?? rate.frames(forSeconds: seconds)
        let timecode = timecodeString.flatMap { Timecode($0, rate: rate) }
        let ext = (path as NSString).pathExtension
        return Asset(
            sourcePath: path,
            fileSize: Int64(format.size ?? "") ?? 0,
            decodePath: DecodePath.forFile(extension: ext) ?? .ffmpeg,
            container: ext.lowercased(),
            videoCodec: video.codec_name,
            width: video.width ?? 0,
            height: video.height ?? 0,
            frameRate: rate,
            durationFrames: frames,
            startTimecodeFrames: timecode?.frames ?? 0,
            dropFrame: timecode?.dropFrame ?? false,
            reelName: tag("reel_name"),
            audioChannels: streams.filter { $0.codec_type == "audio" }.compactMap(\.channels).reduce(0, +),
            colorSpace: video.color_space,
            capturedAt: tag("creation_time").flatMap { ISO8601DateFormatter.flexible.date(from: $0) }
        )
    }
}

extension ISO8601DateFormatter {
    fileprivate static var flexible: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
