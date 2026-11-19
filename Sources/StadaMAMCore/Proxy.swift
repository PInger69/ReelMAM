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
/// - `.besideSource` — `<source folder>/Proxy/A001_C003.mov`, the folder DaVinci Resolve
///   looks in to link proxies by itself. Needs write access to the source volume.
public enum ProxyNaming: String, Codable, CaseIterable, Sendable {
    case sameName
    case premiereSuffix
    case besideSource

    public var displayName: String {
        switch self {
        case .sameName: return "Proxy library, same file name"
        case .premiereSuffix: return "Proxy library, “_Proxy” suffix (Premiere convention)"
        case .besideSource: return "“Proxy” folder beside each source (Resolve auto-link)"
        }
    }

    public static let suffix = "_Proxy"

    public func proxyPath(for asset: Asset, root: String) -> String {
        let source = asset.sourcePath as NSString
        if self == .besideSource {
            let name = (asset.fileName as NSString).deletingPathExtension + ".mov"
            return (source.deletingLastPathComponent as String) + "/Proxy/" + name
        }
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

/// Where the work of rendering a proxy happens. Listed fastest first.
public enum RenderPipeline: String, Codable, CaseIterable, Sendable {
    /// Apple Silicon media engine end to end: hardware decode, scaling on the GPU and hardware
    /// encode, with frames never leaving video memory.
    case videoToolboxGPU
    /// Hardware decode and hardware encode, with scaling (and deinterlacing) on the CPU.
    case videoToolbox
    /// Everything on the CPU. Works everywhere and for every decodable format.
    case software

    public var displayName: String {
        switch self {
        case .videoToolboxGPU: return "Apple media engine (GPU)"
        case .videoToolbox: return "Apple media engine"
        case .software: return "Software"
        }
    }

    /// Preference order on a Mac: try the fastest path, fall back when a format needs it.
    public static let appleSilicon: [RenderPipeline] = [.videoToolboxGPU, .videoToolbox, .software]
}

/// Builds the FFmpeg invocation that renders a proxy.
public struct ProxyRenderPlan: Sendable {
    public var asset: Asset
    public var preset: ProxyPreset
    public var outputPath: String
    public var pipeline: RenderPipeline

    public init(asset: Asset, preset: ProxyPreset, outputPath: String, pipeline: RenderPipeline) {
        self.asset = asset
        self.preset = preset
        self.outputPath = outputPath
        self.pipeline = pipeline
    }

    /// The GPU pipeline cannot deinterlace, so interlaced sources skip it.
    public var isApplicable: Bool { pipeline != .videoToolboxGPU || !asset.scan.isInterlaced }

    public var outputHeight: Int { preset.height(forSourceHeight: asset.height) }

    /// Output width that keeps the stored raster's shape (pixel aspect ratio is carried, not baked in).
    public var outputWidth: Int {
        guard asset.height > 0 else { return 2 }
        let width = Int((Double(asset.width) * Double(outputHeight) / Double(asset.height)).rounded())
        return max(2, width - width % 2)
    }

    public var ffmpegArguments: [String] {
        let height = outputHeight
        var args = ["-hide_banner", "-nostdin", "-y"]
        switch pipeline {
        case .videoToolboxGPU:
            // Decoded frames stay in VideoToolbox surfaces all the way to the encoder.
            args += ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"]
        case .videoToolbox:
            args += ["-hwaccel", "videotoolbox"]
        case .software:
            break
        }
        args += ["-i", asset.sourcePath, "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0"]

        if pipeline == .videoToolboxGPU {
            args += ["-vf", "scale_vt=w=\(outputWidth):h=\(height)"]
        } else {
            // Interlaced sources are deinterlaced one frame per frame, so the proxy keeps the
            // source's frame count and timecode.
            args += ["-vf", (asset.scan.isInterlaced ? "bwdif=mode=send_frame," : "") + "scale=-2:\(height)"]
        }

        let hardware = pipeline != .software
        // Software pixel formats only apply when frames are in system memory.
        let cpuFrames = pipeline != .videoToolboxGPU
        if preset.isProRes {
            args += hardware
                ? ["-c:v", "prores_videotoolbox", "-profile:v", "proxy"]
                : ["-c:v", "prores_ks", "-profile:v", "0"]
            if pipeline == .software { args += ["-pix_fmt", "yuv422p10le"] }
            args += ["-c:a", "pcm_s16le"]
        } else {
            args += hardware
                ? ["-c:v", "h264_videotoolbox", "-b:v", height > 720 ? "8M" : "4M", "-allow_sw", "1"]
                : ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"]
            if cpuFrames { args += ["-pix_fmt", "yuv420p"] }
            // A short GOP keeps scrubbing responsive in the NLE.
            args += ["-g", "\(max(asset.frameRate.nominal / 2, 1))", "-c:a", "aac", "-b:a", "192k"]
        }
        // Matching start timecode and reel name are what Premiere / Resolve / Final Cut relink on.
        args += ["-timecode", asset.startTimecode.description]
        // The reel name lives on the video stream; the MOV muxer copies it into the timecode track.
        if let reel = asset.reelName, !reel.isEmpty { args += ["-metadata:s:v:0", "reel_name=\(reel)"] }
        args += ["-metadata", "\(ProxyMetadataKey.assetID)=\(asset.id)",
                 "-metadata", "\(ProxyMetadataKey.sourcePath)=\(asset.sourcePath)",
                 "-movflags", "+use_metadata_tags", "-f", "mov", outputPath]
        return args
    }
}
