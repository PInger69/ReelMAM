import Foundation

/// How the picture is scanned.
public enum ScanType: String, Codable, Sendable {
    case progressive
    case interlacedTopFirst
    case interlacedBottomFirst
    case unknown

    public var isInterlaced: Bool { self == .interlacedTopFirst || self == .interlacedBottomFirst }

    /// From ffprobe's `field_order` ("progressive", "tt", "bb", "tb", "bt").
    public init(ffprobeFieldOrder value: String?) {
        switch value {
        case "progressive": self = .progressive
        case "tt", "tb": self = .interlacedTopFirst
        case "bb", "bt": self = .interlacedBottomFirst
        default: self = .unknown
        }
    }
}

/// Describes a picture format in the terms people use for it. There is no upper limit on
/// size or frame rate anywhere in the app: these are labels, never restrictions.
public enum PictureFormat {
    /// "2160p23.976", "1080i59.94", "4320p24". Interlaced formats are named by field rate.
    public static func name(height: Int, frameRate: FrameRate, scan: ScanType) -> String {
        guard height > 0 else { return "Unknown" }
        let interlaced = scan.isInterlaced
        let rate = interlaced ? frameRate.fps * 2 : frameRate.fps
        return "\(height)\(interlaced ? "i" : "p")\(rateLabel(rate))"
    }

    public static func rateLabel(_ fps: Double) -> String {
        if abs(fps - fps.rounded()) < 0.0005 { return String(Int(fps.rounded())) }
        // Trim to the conventional precision: 23.976, 29.97, 59.94, 119.88.
        var text = String(format: "%.3f", fps)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    /// "SD", "HD", "UHD 4K", "DCI 4K", "6K", "UHD 8K", "8.6K", ... for any width.
    public static func resolutionClass(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "Unknown" }
        switch (width, height) {
        case (3840, 2160): return "UHD 4K"
        case (4096, 2160): return "DCI 4K"
        case (7680, 4320): return "UHD 8K"
        case (8192, 4320): return "DCI 8K"
        default: break
        }
        if width >= 3000 {
            let k = (Double(width) / 1000 * 10).rounded() / 10
            // Sensor rasters sit close to their marketed size (6144 is sold as 6K, 12288 as 12K),
            // but genuinely in-between sizes keep their decimal (4.6K, 8.6K).
            let nominal = k.rounded()
            let shown = abs(k - nominal) / nominal <= 0.03 ? nominal : k
            return (shown == shown.rounded() ? String(Int(shown)) : String(shown)) + "K"
        }
        if height >= 1080 || width >= 1920 { return width > 1920 ? "2K" : "HD" }
        if height >= 720 { return "HD" }
        return "SD"
    }

    public enum BroadcastStandard: String, Sendable, CaseIterable {
        case atsc1 = "ATSC 1.0"
        case atsc3 = "ATSC 3.0"
    }

    private static func matches(_ rate: FrameRate, _ rates: [FrameRate]) -> Bool {
        rates.contains { abs($0.fps - rate.fps) < 0.002 }
    }

    /// Which ATSC broadcast standards carry this picture format natively. Informational only.
    ///
    /// ATSC 1.0 follows A/53 Part 4 Table 6.2. ATSC 3.0 follows the video formats of A/341
    /// (progressive up to 3840×2160 and up to 120 fps, plus legacy interlaced HD and SD);
    /// check the current edition of the standard before relying on this for compliance.
    public static func broadcastStandards(width: Int, height: Int, frameRate: FrameRate,
                                          scan: ScanType) -> [BroadcastStandard] {
        let film: [FrameRate] = [.fps23_976, .fps24]
        let p30: [FrameRate] = film + [.fps29_97, .fps30]
        let p60: [FrameRate] = p30 + [.fps59_94, .fps60]
        let i30: [FrameRate] = [.fps29_97, .fps30]
        var result: [BroadcastStandard] = []

        let atsc1: Bool
        switch (width, height, scan.isInterlaced) {
        case (1920, 1080, false): atsc1 = matches(frameRate, p30)
        case (1920, 1080, true): atsc1 = matches(frameRate, i30)
        case (1280, 720, false): atsc1 = matches(frameRate, p60)
        case (704, 480, false), (640, 480, false): atsc1 = matches(frameRate, p60)
        case (704, 480, true), (640, 480, true): atsc1 = matches(frameRate, i30)
        default: atsc1 = false
        }
        if atsc1 { result.append(.atsc1) }

        let atsc3: Bool
        if scan.isInterlaced {
            let hd = height == 1080 && (width == 1920 || width == 1440)
                && matches(frameRate, [.fps25, .fps29_97, .fps30])
            let sd = (height == 480 && matches(frameRate, i30)) || (height == 576 && matches(frameRate, [.fps25]))
            atsc3 = hd || (sd && (width == 720 || width == 704))
        } else {
            atsc3 = width > 0 && width <= 3840 && height > 0 && height <= 2160
                && matches(frameRate, p60 + [.fps25, .fps50, FrameRate(100), FrameRate(120000, 1001), FrameRate(120)])
        }
        if atsc3 { result.append(.atsc3) }
        return result
    }
}

/// What a file is, worked out from its extension and whatever a probe could read —
/// including camera RAW formats that no bundled decoder can open yet.
public struct FormatIdentity: Hashable, Sendable {
    /// Human-readable essence name: "Apple ProRes 422 HQ", "Sony X-OCN / RAW", "Blackmagic RAW".
    public var name: String
    public var decodePath: DecodePath

    public init(name: String, decodePath: DecodePath) {
        self.name = name
        self.decodePath = decodePath
    }

    /// Camera RAW and other formats recognised by extension alone.
    private static let byExtension: [String: FormatIdentity] = [
        "braw": .init(name: "Blackmagic RAW", decodePath: .blackmagicRAW),
        "r3d": .init(name: "REDCODE RAW", decodePath: .unsupported),
        "ari": .init(name: "ARRIRAW", decodePath: .unsupported),
        "arx": .init(name: "ARRIRAW (HDE)", decodePath: .unsupported),
        "crm": .init(name: "Canon Cinema RAW Light", decodePath: .unsupported),
        "rmf": .init(name: "Canon Cinema RAW", decodePath: .unsupported),
        "nev": .init(name: "Nikon N-RAW", decodePath: .unsupported),
        "cine": .init(name: "Phantom Cine RAW", decodePath: .unsupported),
        "dng": .init(name: "CinemaDNG", decodePath: .unsupported),
    ]

    private static let codecNames: [String: String] = [
        "prores": "Apple ProRes", "prores_raw": "Apple ProRes RAW", "h264": "H.264 / AVC",
        "hevc": "H.265 / HEVC", "dnxhd": "Avid DNxHD / DNxHR", "mpeg2video": "MPEG-2",
        "mpeg4": "MPEG-4", "jpeg2000": "JPEG 2000", "cfhd": "GoPro CineForm", "dvvideo": "DV",
        "av1": "AV1", "vp9": "VP9", "rawvideo": "Uncompressed", "v210": "Uncompressed 10-bit",
        "mjpeg": "Motion JPEG", "vc1": "VC-1", "r3d": "REDCODE RAW",
    ]

    private static let proResProfiles: [String: String] = [
        "apco": "422 Proxy", "apcs": "422 LT", "apcn": "422", "apch": "422 HQ",
        "ap4h": "4444", "ap4x": "4444 XQ",
    ]

    /// Every extension the app will catalogue.
    public static let importableExtensions: Set<String> = Set(byExtension.keys).union([
        "mov", "mp4", "m4v", "qt", "mxf", "mkv", "avi", "webm", "mts", "m2ts", "ts", "mpg", "mpeg",
        "wmv", "flv", "dv", "3gp", "ogv", "vob", "m2v", "y4m",
    ])

    /// - Parameters:
    ///   - codec: ffprobe `codec_name` of the video stream, if a probe succeeded.
    ///   - codecTag: ffprobe `codec_tag_string` (the FourCC).
    ///   - canDecode: whether the prober has a decoder for the stream.
    ///   - vendor: container-level maker hints (MXF `company_name` / `product_name`, QuickTime make).
    public static func identify(fileExtension: String, codec: String? = nil, codecTag: String? = nil,
                                canDecode: Bool = true, vendor: String? = nil) -> FormatIdentity {
        let ext = fileExtension.lowercased()
        if let known = byExtension[ext] { return known }
        let vendor = (vendor ?? "").lowercased()
        let tag = (codecTag ?? "").lowercased()

        if let codec, canDecode, let base = codecNames[codec] {
            var name = base
            if codec == "prores", let profile = proResProfiles[tag] { name += " " + profile }
            if codec == "prores_raw" || tag == "aprn" || tag == "aprh" {
                // ProRes RAW decodes through VideoToolbox, not FFmpeg.
                return FormatIdentity(name: tag == "aprh" ? "Apple ProRes RAW HQ" : "Apple ProRes RAW",
                                      decodePath: .avFoundation)
            }
            let native = ["mov", "mp4", "m4v", "qt"].contains(ext)
                && ["prores", "h264", "hevc", "mjpeg", "dvvideo"].contains(codec)
            return FormatIdentity(name: name, decodePath: native ? .avFoundation : .ffmpeg)
        }
        if tag == "aprn" || tag == "aprh" {
            return FormatIdentity(name: tag == "aprh" ? "Apple ProRes RAW HQ" : "Apple ProRes RAW",
                                  decodePath: .avFoundation)
        }
        // An MXF whose picture essence has no decoder is a camera RAW wrapper.
        if ext == "mxf", !canDecode || codec == nil {
            if vendor.contains("sony") { return FormatIdentity(name: "Sony X-OCN / RAW", decodePath: .unsupported) }
            if vendor.contains("arri") { return FormatIdentity(name: "ARRIRAW (MXF)", decodePath: .unsupported) }
            if vendor.contains("canon") { return FormatIdentity(name: "Canon RAW (MXF)", decodePath: .unsupported) }
            return FormatIdentity(name: "Camera RAW (MXF)", decodePath: .unsupported)
        }
        if let codec, canDecode {
            return FormatIdentity(name: codec.uppercased(), decodePath: .ffmpeg)
        }
        return FormatIdentity(name: codec.map { "Unrecognised (\($0))" } ?? "Unrecognised essence",
                              decodePath: .unsupported)
    }
}
