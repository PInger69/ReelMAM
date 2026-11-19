import Foundation

public enum ProxyPreset: String, Codable, CaseIterable, Sendable {
    case proResProxyHalf
    case proResProxy1080
    case h264_1080
    case h264_720

    public var displayName: String {
        switch self {
        case .proResProxyHalf: return "ProRes Proxy – half resolution"
        case .proResProxy1080: return "ProRes Proxy – 1080p"
        case .h264_1080: return "H.264 – 1080p"
        case .h264_720: return "H.264 – 720p"
        }
    }

    public var isProRes: Bool { self == .proResProxyHalf || self == .proResProxy1080 }

    /// Output height for a given source height (always even).
    public func height(forSourceHeight source: Int) -> Int {
        let target: Int
        switch self {
        case .proResProxyHalf: target = source / 2
        case .proResProxy1080, .h264_1080: target = min(source, 1080)
        case .h264_720: target = min(source, 720)
        }
        return max(2, target - target % 2)
    }
}

/// Where proxies go and what they are called.
///
/// Both NLEs relink on file name + timecode + duration, so the proxy always keeps the
/// source's base name:
/// - `.sameName` — `<root>/<volume>/<source folders>/A001_C003.mov`. DaVinci Resolve's
///   "Link Proxy Media" and Premiere's "Attach Proxies" both accept this.
/// - `.premiereSuffix` — same, but `A001_C003_Proxy.mov`, the Premiere ingest convention.
public enum ProxyNaming: String, Codable, Sendable {
    case sameName
    case premiereSuffix

    public static let suffix = "_Proxy"

    public func proxyPath(for asset: Asset, root: String) -> String {
        let source = asset.sourcePath as NSString
        var folders = (source.deletingLastPathComponent as String).split(separator: "/").map(String.init)
        if folders.first == "Volumes" { folders.removeFirst() }
        let base = (asset.fileName as NSString).deletingPathExtension + (self == .premiereSuffix ? Self.suffix : "")
        return ([root] + folders + [base + ".mov"]).joined(separator: "/")
            .replacingOccurrences(of: "//", with: "/")
    }

    /// Reduces any proxy or source file name to the key they share: lowercased base name
    /// with the extension and common proxy suffixes removed.
    public static func matchKey(forFileName fileName: String) -> String {
        var base = ((fileName as NSString).deletingPathExtension).lowercased()
        for suffix in ["_proxy", "-proxy", " proxy", "_prx", "_low", "_lowres"] where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
            break
        }
        return base
    }
}

/// Metadata keys written into every proxy so it can always be traced back to its source,
/// even after it has been renamed, moved, or passed through an NLE.
public enum ProxyMetadataKey {
    public static let assetID = "com.stadaxr.mam.asset-id"
    public static let sourcePath = "com.stadaxr.mam.source-path"
}

/// Builds the FFmpeg invocation that renders a proxy.
public struct ProxyRenderPlan: Sendable {
    public var asset: Asset
    public var preset: ProxyPreset
    public var outputPath: String
    /// Use VideoToolbox hardware encoders (macOS). Off on other platforms and in tests.
    public var hardware: Bool

    public init(asset: Asset, preset: ProxyPreset, outputPath: String, hardware: Bool) {
        self.asset = asset
        self.preset = preset
        self.outputPath = outputPath
        self.hardware = hardware
    }

    public var ffmpegArguments: [String] {
        let height = preset.height(forSourceHeight: asset.height)
        var args = ["-hide_banner", "-nostdin", "-y", "-i", asset.sourcePath,
                    "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
                    // Interlaced sources are deinterlaced one frame per frame, so the proxy keeps the
                    // source's frame count and timecode.
                    "-vf", (asset.scan.isInterlaced ? "bwdif=mode=send_frame," : "") + "scale=-2:\(height)"]
        if preset.isProRes {
            args += hardware
                ? ["-c:v", "prores_videotoolbox", "-profile:v", "proxy"]
                : ["-c:v", "prores_ks", "-profile:v", "0", "-pix_fmt", "yuv422p10le"]
            args += ["-c:a", "pcm_s16le"]
        } else {
            args += hardware
                ? ["-c:v", "h264_videotoolbox", "-b:v", height > 720 ? "8M" : "4M", "-pix_fmt", "yuv420p"]
                : ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p"]
            // All-intra-ish GOP keeps scrubbing responsive in the NLE.
            args += ["-g", "\(max(asset.frameRate.nominal / 2, 1))", "-c:a", "aac", "-b:a", "192k"]
        }
        // Matching start timecode and reel name are what Premiere / Resolve relink on.
        args += ["-timecode", asset.startTimecode.description]
        // The reel name lives on the video stream; the MOV muxer copies it into the timecode track.
        if let reel = asset.reelName, !reel.isEmpty { args += ["-metadata:s:v:0", "reel_name=\(reel)"] }
        args += ["-metadata", "\(ProxyMetadataKey.assetID)=\(asset.id)",
                 "-metadata", "\(ProxyMetadataKey.sourcePath)=\(asset.sourcePath)",
                 "-movflags", "+use_metadata_tags", "-f", "mov", outputPath]
        return args
    }
}
