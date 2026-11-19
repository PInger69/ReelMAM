import Foundation
import StadaMAMCore

public enum MediaError: Error, LocalizedError, Equatable {
    case ffmpegNotFound
    case ffmpegFailed(String)
    case noVideoStream(String)
    case decoderUnavailable(String)
    case isOwnProxy(assetID: String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "FFmpeg was not found. Install it with “brew install ffmpeg”."
        case .ffmpegFailed(let message):
            return "FFmpeg failed: \(message)"
        case .noVideoStream(let path):
            return "No video stream in \((path as NSString).lastPathComponent)."
        case .decoderUnavailable(let format):
            return "\(format.isEmpty ? "This format" : format) is catalogued, but decoding it needs the camera maker's SDK, which is not installed yet."
        case .isOwnProxy:
            return "This file is a StadaXR A.I. MAM proxy, not a source."
        }
    }
}

/// Thin wrapper around the ffmpeg / ffprobe executables.
public struct FFmpegTools: Sendable {
    public var ffmpeg: String
    public var ffprobe: String

    public init(ffmpeg: String, ffprobe: String) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    /// Looks in the app bundle first, then the usual Homebrew and system locations.
    public static func locate(extraSearchPaths: [String] = []) -> FFmpegTools? {
        var directories = extraSearchPaths
        if let resources = Bundle.main.resourcePath { directories.append(resources) }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let fm = FileManager.default
        for directory in directories {
            let ffmpeg = directory + "/ffmpeg", ffprobe = directory + "/ffprobe"
            if fm.isExecutableFile(atPath: ffmpeg), fm.isExecutableFile(atPath: ffprobe) {
                return FFmpegTools(ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
        }
        return nil
    }

    /// Runs a tool to completion. `onOutputLine` receives stdout line by line while it runs.
    @discardableResult
    func run(_ executable: String, _ arguments: [String],
             onOutputLine: (@Sendable (String) -> Void)? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Drain both pipes concurrently so a chatty tool can never block on a full pipe.
        let group = DispatchGroup()
        let errorBox = DataBox()
        DispatchQueue.global().async(group: group) {
            errorBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        var output = Data()
        var pending = Data()
        while true {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
            guard let onOutputLine else { continue }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                onOutputLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorBox.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MediaError.ffmpegFailed(message.isEmpty ? "exit code \(process.terminationStatus)" : message)
        }
        return output
    }

    public func probe(path: String) throws -> FFProbeResult {
        try FFProbeResult(json: run(ffprobe, FFProbeResult.arguments + [path]))
    }

    /// Renders a proxy. Writes to a temporary name and moves into place only on success,
    /// so a half-written proxy is never mistaken for a finished one.
    public func render(_ plan: ProxyRenderPlan, progress: (@Sendable (Double) -> Void)? = nil) throws {
        let fm = FileManager.default
        let directory = (plan.outputPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var partial = plan
        partial.outputPath = plan.outputPath + ".partial"
        let totalMicroseconds = max(plan.asset.durationSeconds * 1_000_000, 1)
        var arguments = partial.ffmpegArguments
        arguments.insert(contentsOf: ["-loglevel", "error", "-progress", "pipe:1"], at: 0)
        do {
            try run(ffmpeg, arguments) { line in
                guard let progress, line.hasPrefix("out_time_us="),
                      let value = Double(line.dropFirst("out_time_us=".count)) else { return }
                progress(min(max(value / totalMicroseconds, 0), 1))
            }
            if fm.fileExists(atPath: plan.outputPath) { try fm.removeItem(atPath: plan.outputPath) }
            try fm.moveItem(atPath: partial.outputPath, toPath: plan.outputPath)
        } catch {
            try? fm.removeItem(atPath: partial.outputPath)
            throw error
        }
    }

    /// Extracts evenly spaced JPEG frames for the poster and hover-scrub strip.
    /// Returns the paths written, in time order.
    @discardableResult
    public func writeThumbnails(mediaPath: String, durationSeconds: Double, count: Int,
                                height: Int = 270, to directory: String) throws -> [String] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var paths: [String] = []
        for index in 0..<max(count, 1) {
            // Sample the middle of each slice so the first thumbnail is not a black lead-in frame.
            let time = durationSeconds * (Double(index) + 0.5) / Double(max(count, 1))
            let path = directory + "/" + String(format: "%03d.jpg", index)
            try run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
                             "-ss", String(format: "%.3f", time), "-i", mediaPath,
                             "-frames:v", "1", "-vf", "scale=-2:\(height)", "-q:v", "4", path])
            if FileManager.default.fileExists(atPath: path) { paths.append(path) }
        }
        return paths
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
