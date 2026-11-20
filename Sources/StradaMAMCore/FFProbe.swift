import Foundation

/// Decodes `ffprobe -print_format json -show_format -show_streams` output.
public struct FFProbeResult: Decodable, Sendable {
    public struct Stream: Decodable, Sendable {
        public var codec_type: String?
        public var codec_name: String?
        public var codec_tag_string: String?
        public var field_order: String?
        public var sample_aspect_ratio: String?
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
    public var embeddedAssetID: String? { tag(ProxyMetadataKey.assetID) ?? tag(ProxyMetadataKey.legacyAssetID) }
    public var embeddedSourcePath: String? { tag(ProxyMetadataKey.sourcePath) ?? tag(ProxyMetadataKey.legacySourcePath) }
    public var timecodeString: String? { tag("timecode") }

    /// The picture stream, ignoring cover art and thumbnails.
    public var videoStream: Stream? {
        streams.first { $0.codec_type == "video" && ($0.width ?? 0) > 0 }
            ?? streams.first { $0.codec_type == "video" }
    }

    /// Maker hints from the container (MXF company / product name, QuickTime make and model).
    public var vendorHint: String {
        ["company_name", "product_name", "make", "com.apple.quicktime.make", "com.apple.quicktime.model"]
            .compactMap { tag($0) }.joined(separator: " ")
    }

    /// Builds a catalog asset from the probe. Returns nil when the file has no video stream.
    /// Any picture size and frame rate is accepted.
    public func asset(path: String) -> Asset? {
        guard let video = videoStream else { return nil }
        let scan = ScanType(ffprobeFieldOrder: video.field_order)
        let rates = [video.r_frame_rate, video.avg_frame_rate]
            .compactMap { $0 }.filter { $0 != "0/0" }.compactMap(FrameRate.init(string:))
        var rate = rates.first ?? .fps24
        // Some interlaced streams report their field rate as the frame rate; the average is the truth.
        if scan.isInterlaced, rates.count == 2, abs(rates[0].fps - rates[1].fps * 2) < 0.01 { rate = rates[1] }
        let seconds = Double(video.duration ?? "") ?? Double(format.duration ?? "") ?? 0
        let frames = Int(video.nb_frames ?? "") ?? rate.frames(forSeconds: seconds)
        let timecode = timecodeString.flatMap { Timecode($0, rate: rate) }
        let ext = (path as NSString).pathExtension
        let codec = video.codec_name.flatMap { ["none", "unknown", ""].contains($0) ? nil : $0 }
        let identity = FormatIdentity.identify(fileExtension: ext, codec: codec, codecTag: video.codec_tag_string,
                                               canDecode: codec != nil, vendor: vendorHint)
        let aspect = (video.sample_aspect_ratio ?? "1:1").split(separator: ":").compactMap { Int($0) }
        return Asset(
            sourcePath: path,
            fileSize: Int64(format.size ?? "") ?? 0,
            decodePath: identity.decodePath,
            container: ext.lowercased(),
            videoCodec: codec,
            width: video.width ?? 0,
            height: video.height ?? 0,
            frameRate: rate,
            durationFrames: frames,
            startTimecodeFrames: timecode?.frames ?? 0,
            dropFrame: timecode?.dropFrame ?? false,
            reelName: tag("reel_name"),
            audioChannels: streams.filter { $0.codec_type == "audio" }.compactMap(\.channels).reduce(0, +),
            colorSpace: video.color_space,
            formatName: identity.name,
            scan: scan,
            pixelAspect: aspect.count == 2 && aspect[0] > 0 && aspect[1] > 0 ? (aspect[0], aspect[1]) : (1, 1),
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
