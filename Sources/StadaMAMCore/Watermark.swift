import Foundation

/// The mark on every remote proxy: the production's name, in the lower-left quarter of the
/// picture. It is the same for every editor. Who pulled what is the audit trail's job.
public enum Watermark {
    public static let text = "StradaXR"
}

public enum WatermarkState: Sendable, Equatable {
    case ready(path: String)
    /// Being rendered; ask again shortly.
    case preparing
    case failed(String)
}

/// Produces the marked copy of a proxy. The server hands out only these copies, never the
/// clean proxy, so the mark cannot be skipped.
public protocol ProxyWatermarker: Sendable {
    /// The marked copy of `proxy`, started in the background if it does not exist yet.
    func state(for proxy: ProxyRecord, asset: Asset) -> WatermarkState
}

/// Builds the FFmpeg run that turns a proxy into its watermarked remote copy. The overlay
/// is a transparent image the size of the picture, so any FFmpeg works (none needs `drawtext`).
///
/// The copy is a remote-preset proxy in its own right: HEVC at the remote bitrate, AAC audio,
/// and the source's start timecode, reel name and asset ID. The mini's folder layout
/// (`sourcePath`) is left out, because this file goes to someone else's computer.
public struct WatermarkRenderPlan: Sendable {
    public var asset: Asset
    public var proxyPath: String
    public var overlayPath: String
    public var outputPath: String
    public var width: Int
    public var height: Int
    public var hardware: Bool

    public init(asset: Asset, proxyPath: String, overlayPath: String, outputPath: String,
                width: Int, height: Int, hardware: Bool) {
        self.asset = asset
        self.proxyPath = proxyPath
        self.overlayPath = overlayPath
        self.outputPath = outputPath
        self.width = width
        self.height = height
        self.hardware = hardware
    }

    public static let metadataKey = "com.stadaxr.mam.watermark"

    public var ffmpegArguments: [String] {
        let rate = ProxyPreset.remoteHEVC.videoBitrate(width: width, height: height)
        let peak = ProxyPreset.remotePeakBitrate
        let gop = "\(max(asset.frameRate.nominal / 2, 1))"
        var args = ["-hide_banner", "-nostdin", "-y", "-i", proxyPath, "-i", overlayPath,
                    "-filter_complex", "[0:v:0][1:v:0]overlay=0:0:format=auto,format=yuv420p[v]",
                    "-map", "[v]", "-map", "0:a?", "-map_metadata", "-1"]
        args += hardware
            ? ["-c:v", "hevc_videotoolbox", "-b:v", "\(rate)", "-maxrate", "\(peak)", "-allow_sw", "1"]
            : ["-c:v", "libx265", "-preset", "veryfast", "-b:v", "\(rate)", "-maxrate", "\(peak)",
               "-bufsize", "\(peak * 2)", "-x265-params", "bframes=0:keyint=\(gop):min-keyint=\(gop):log-level=error"]
        args += ["-tag:v", "hvc1", "-g", gop]
        args += asset.audioChannels <= 8 ? ["-c:a", "aac", "-b:a", "128k"] : ["-c:a", "pcm_s16le"]
        args += ["-timecode", asset.startTimecode.description]
        if let reel = asset.reelName, !reel.isEmpty { args += ["-metadata:s:v:0", "reel_name=\(reel)"] }
        args += ["-metadata", "\(ProxyMetadataKey.assetID)=\(asset.id)",
                 "-metadata", "\(Self.metadataKey)=\(Watermark.text)",
                 "-movflags", "+use_metadata_tags", "-f", "mov", outputPath]
        return args
    }
}
