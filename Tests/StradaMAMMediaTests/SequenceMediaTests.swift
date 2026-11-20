import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#endif
#if os(macOS)
import AVFoundation
import CoreVideo
#endif
import StradaMAMCore
@testable import StradaMAMMedia

private func temporaryFolder() throws -> String {
    let path = NSTemporaryDirectory() + "stradamam-sequence-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func resolved(_ name: String, rate: FrameRate = .fps24, _ cuts: [(Asset, Int, Int)]) -> ResolvedSequence {
    let sequence = CutSequence(name: name, frameRate: rate)
    return ResolvedSequence(sequence: sequence, cuts: cuts.map {
        (SequenceCut(sequenceID: sequence.id, assetID: $0.0.id, inFrame: $0.1, outFrame: $0.2), $0.0)
    })
}

/// The package export, on ordinary files standing in for camera originals.
@Suite struct SequencePackageExportTests {
    let root: String
    let a: Asset, b: Asset

    init() throws {
        root = try temporaryFolder()
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/Volumes/RAID/Day 1", withIntermediateDirectories: true)
        // Larger than one copy chunk, so the copy loop goes round more than once.
        var big = Data(count: 9 << 20)
        big.withUnsafeMutableBytes { bytes in
            for index in stride(from: 0, to: bytes.count, by: 4093) { bytes[index] = UInt8(truncatingIfNeeded: index / 4093) }
        }
        let pathA = root + "/Volumes/RAID/Day 1/A001_C003.braw", pathB = root + "/Volumes/RAID/Day 1/A001_C004.mov"
        try big.write(to: URL(fileURLWithPath: pathA))
        try Data("grade".utf8).write(to: URL(fileURLWithPath: root + "/Volumes/RAID/Day 1/A001_C003.sidecar"))
        try Data("second clip".utf8).write(to: URL(fileURLWithPath: pathB))
        a = Asset(sourcePath: pathA, frameRate: .fps24, durationFrames: 240, startTimecodeFrames: 86400, reelName: "A001")
        b = Asset(sourcePath: pathB, frameRate: .fps24, durationFrames: 240, reelName: "A001")
    }

    @Test func packageHoldsTimelinesOriginalsAndAManifestThatChecksOut() throws {
        let sequence = resolved("Scene 12: v2", [(a, 24, 71), (b, 0, 23), (a, 100, 123)])
        let out = try temporaryFolder()
        let seen = Progress()
        let result = try SequencePackageExporter.export(sequence, into: out) { seen.record($0.fraction) }
        #expect(result.folder == out + "/Scene 12- v2 package")

        let fm = FileManager.default
        let relative = String((root + "/Volumes/RAID/Day 1").dropFirst())
        let copyA = result.folder + "/Media/This Mac/" + relative + "/A001_C003.braw"
        #expect(fm.contentsEqual(atPath: a.sourcePath, andPath: copyA))
        #expect(fm.fileExists(atPath: result.folder + "/Media/This Mac/" + relative + "/A001_C003.sidecar"))
        #expect(fm.fileExists(atPath: result.folder + "/Media/This Mac/" + relative + "/A001_C004.mov"))
        // The checksum list is named after the algorithm, which is SHA-256 on a Mac.
        let checksums = "checksums." + SequencePackageExporter.checksumAlgorithm
        for name in ["Scene 12- v2.fcpxml", "Scene 12- v2.xml", "Scene 12- v2.edl", "manifest.json", checksums] {
            #expect(fm.fileExists(atPath: result.folder + "/" + name), "missing \(name)")
        }

        // Each original once, with a checksum that an independent hash of the source agrees with.
        let manifest = result.manifest
        #expect(manifest.files.count == 3 && manifest.files.allSatisfy(\.verified))
        let entry = try #require(manifest.files.first { $0.clipName == "A001_C003.braw" })
        #expect(entry.bytes == 9 << 20 && entry.reel == "A001" && entry.startTimecode == "01:00:00:00")
        #expect(entry.uses.map(\.sourceIn) == ["01:00:01:00", "01:00:04:04"])
        #if canImport(CryptoKit)
        let expected = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: a.sourcePath)))
            .map { String(format: "%02x", $0) }.joined()
        #expect(entry.checksum == expected)
        #endif
        #expect(seen.last == 1 && seen.neverWentBack)

        // The timelines point at the copies in the package, not at the hub's storage.
        let xml = try String(contentsOfFile: result.folder + "/Scene 12- v2.xml", encoding: .utf8)
        let references = TimelineDocument(text: xml)?.references ?? []
        #expect(Set(references.compactMap(\.path)) == [copyA, result.folder + "/Media/This Mac/" + relative + "/A001_C004.mov"])
        let edl = try String(contentsOfFile: result.folder + "/Scene 12- v2.edl", encoding: .utf8)
        #expect(edl.contains("01:00:01:00 01:00:03:00 01:00:00:00 01:00:02:00"))

        // The package can be checked again later; a damaged copy is found.
        #expect(try SequencePackageExporter.verify(packageAt: result.folder).isEmpty)
        let handle = try #require(FileHandle(forWritingAtPath: copyA))
        try handle.seek(toOffset: 5 << 20)
        try handle.write(contentsOf: Data([0xFF, 0xFE]))
        try handle.close()
        #expect(try SequencePackageExporter.verify(packageAt: result.folder) == [entry.path])

        // Exporting again never writes over the first package.
        #expect(try SequencePackageExporter.export(sequence, into: out, formats: [.edl]).folder == out + "/Scene 12- v2 package 2")
    }

    @Test func nothingIsWrittenWhenAnOriginalIsMissing() throws {
        let gone = Asset(sourcePath: root + "/Volumes/Offline/Z009.mov", durationFrames: 100)
        let out = try temporaryFolder()
        #expect(throws: PackageError.missingOriginals([gone.sourcePath])) {
            try SequencePackageExporter.export(resolved("Cut", [(a, 0, 9), (gone, 0, 9)]), into: out)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out).isEmpty)
        #expect(throws: PackageError.emptySequence) { try SequencePackageExporter.export(resolved("Empty", []), into: out) }
    }
}

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func record(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var last: Double? { values.last }
    var neverWentBack: Bool { zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } }
}

#if os(macOS)
/// Playing a sequence and showing a look, on clips made with FFmpeg.
@Suite(.enabled(if: FFmpegTools.locate() != nil))
struct SequencePlaybackAndLookTests {
    let tools = FFmpegTools.locate()!
    let root: String

    init() throws { root = try temporaryFolder() }

    /// A clip of one flat colour, 24 fps, with a tone.
    private func makeClip(_ name: String, color: String, seconds: Int = 2, extra: [String] = []) async throws -> Asset {
        let path = root + "/" + name
        try await tools.runOffPool(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=\(color):size=320x180:rate=24:duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "1", "-crf", "10",
            "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
        ] + extra + ["-c:a", "aac", path])
        return Asset(sourcePath: path, width: 320, height: 180, frameRate: .fps24, durationFrames: seconds * 24, audioChannels: 1)
    }

    /// The colour in the middle of the first frame at `seconds`, as 0...255 red, green, blue.
    private func pixel(of asset: AVAsset, at seconds: Double = 0.25, through composition: AVVideoComposition? = nil) async throws -> [Int] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), duration: CMTime(value: 1, timescale: 4))
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // Asked for through the loader that listens once: this runs after a video composition
        // has been built for the same asset, when AVFoundation can answer a track request twice.
        let tracks = try await asset.loadTracksOnce(withMediaType: .video)
        let output: AVAssetReaderOutput
        if let composition {
            let composed = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: settings)
            composed.videoComposition = composition
            output = composed
        } else {
            output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: settings)
        }
        reader.add(output)
        #expect(reader.startReading())
        // The read blocks until the frame has been through the look, and the look is applied on
        // Swift's own thread pool. Waiting here on one of that pool's threads stalled the whole
        // run once every thread was waiting, so the wait happens on a thread of its own.
        nonisolated(unsafe) let reading = output
        let next: CMSampleBuffer? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: reading.copyNextSampleBuffer())
            }
        }
        let sample = try #require(next, "no frame: \(String(describing: reader.error))")
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let row = CVPixelBufferGetHeight(buffer) / 2, column = CVPixelBufferGetWidth(buffer) / 2
        let bytes = base.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer) + column * 4).assumingMemoryBound(to: UInt8.self)
        reader.cancelReading()
        return [Int(bytes[2]), Int(bytes[1]), Int(bytes[0])]
    }

    private func close(_ a: [Int], _ b: [Int], within tolerance: Int = 6) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @Test func aLookChangesThePictureOnScreenAndNothingElse() async throws {
        let clip = try await makeClip("grey.mp4", color: "0x406080")
        let before = try Data(contentsOf: URL(fileURLWithPath: clip.sourcePath))
        let asset = AVURLAsset(url: URL(fileURLWithPath: clip.sourcePath))
        let plain = try await pixel(of: asset)
        #expect(close(plain, [0x40, 0x60, 0x80]), "source reads as \(plain)")

        // A table that changes nothing leaves the picture as it was.
        let same = try await pixel(of: asset, through: ViewingLookRenderer.videoComposition(for: asset, lut: .identity()))
        #expect(close(same, plain), "identity gave \(same), source \(plain)")

        // A table that inverts the picture inverts it.
        let invert = ColorLUT(title: "Invert", size: 17) { (1 - $0, 1 - $1, 1 - $2) }
        let inverted = try await pixel(of: asset, through: ViewingLookRenderer.videoComposition(for: asset, lut: invert))
        #expect(close(inverted, plain.map { 255 - $0 }), "invert gave \(inverted), source \(plain)")

        // A 65-step table (the usual .cube size) is brought within what Core Image takes.
        let large = ColorLUT(title: "Invert 65", size: 65) { (1 - $0, 1 - $1, 1 - $2) }
        let viaLarge = try await pixel(of: asset, through: ViewingLookRenderer.videoComposition(for: asset, lut: large))
        #expect(close(viaLarge, inverted))

        #expect(try Data(contentsOf: URL(fileURLWithPath: clip.sourcePath)) == before)
    }

    /// A clip tagged the way log footage is (wide primaries, no standard transfer curve) must
    /// reach the table with its own code values, not after a colour conversion by the system.
    @Test func wideGamutFootageReachesTheTableUnconverted() async throws {
        let clip = try await makeClip("wide.mp4", color: "0xA04020", extra: ["-bsf:v", "h264_metadata=colour_primaries=9:transfer_characteristics=2:matrix_coefficients=1"])
        let asset = AVURLAsset(url: URL(fileURLWithPath: clip.sourcePath))
        let description = await ViewingLookRenderer.colorDescription(path: clip.sourcePath)
        #expect(description?.contains("2020") == true, "tags read as \(description ?? "nil")")
        let plain = try await pixel(of: asset)
        let same = try await pixel(of: asset, through: ViewingLookRenderer.videoComposition(for: asset, lut: .identity()))
        #expect(close(same, plain), "identity gave \(same), source \(plain)")

        // A mid-grey Apple Log 2 frame through the built-in conversion comes out as the table says
        // for the values that were really in the frame, and lands mid-range.
        let level = Int((midGreyAppleLog * 255).rounded())
        let grey = try await makeClip("loggrey.mp4", color: String(format: "0x%02X%02X%02X", level, level, level))
        let greyAsset = AVURLAsset(url: URL(fileURLWithPath: grey.sourcePath))
        let decoded = try await pixel(of: greyAsset)
        let table = ColorLUT(conversion: .appleLog2)
        let shown = try await pixel(of: greyAsset, through: ViewingLookRenderer.videoComposition(for: greyAsset, lut: table))
        let expected = table.sample(Double(decoded[0]) / 255, Double(decoded[1]) / 255, Double(decoded[2]) / 255)
        #expect(close(shown, [expected.0, expected.1, expected.2].map { Int(($0 * 255).rounded()) }, within: 4),
                "decoded \(decoded), shown \(shown), table says \(expected)")
        #expect(shown[1] > 100 && shown[1] < 130)
    }

    @Test func sequencePlaysItsCutsInOrder() async throws {
        let red = try await makeClip("red.mp4", color: "0xC02020"), blue = try await makeClip("blue.mp4", color: "0x2020C0")
        let raw = Asset(sourcePath: root + "/A001.braw", decodePath: .blackmagicRAW, frameRate: .fps24, durationFrames: 240)
        let sequence = resolved("Cut", [(red, 12, 35), (raw, 0, 23), (blue, 0, 23), (red, 0, 11)])
        let playback = try await SequencePlayback.build(sequence) { $0.decodePath == .blackmagicRAW ? nil : $0.sourcePath }

        #expect(playback.segments.map { $0.duration.seconds } == [1, 1, 1, 0.5])
        #expect(playback.segments.map(\.hasPicture) == [true, false, true, true])
        #expect(abs(playback.duration.seconds - 3.5) < 0.001)
        #expect(abs(try await playback.composition.load(.duration).seconds - 3.5) < 0.05)

        // The picture at each point is the right clip's.
        let first = try await pixel(of: playback.composition, at: 0.5)
        let third = try await pixel(of: playback.composition, at: 2.5)
        let last = try await pixel(of: playback.composition, at: 3.2)
        #expect(first[0] > first[2] + 60, "first cut reads \(first)")
        #expect(third[2] > third[0] + 60, "third cut reads \(third)")
        #expect(last[0] > last[2] + 60, "last cut reads \(last)")

        // A time maps back to its cut and source frame.
        let at = try #require(playback.position(at: CMTime(seconds: 0.5, preferredTimescale: 600), in: sequence))
        #expect(at.index == 0 && at.sourceFrame == 24)
        let later = try #require(playback.position(at: CMTime(seconds: 3.25, preferredTimescale: 600), in: sequence))
        #expect(later.index == 3 && later.sourceFrame == 6)

        // A look per cut: the blue cut inverted, the others left alone.
        let invert = ColorLUT(title: "Invert", size: 9) { (1 - $0, 1 - $1, 1 - $2) }
        let composition = try await ViewingLookRenderer.videoComposition(
            for: playback.composition, looks: [(playback.segments[2].range, invert)])
        let untouched = try await pixel(of: playback.composition, at: 0.5, through: composition)
        let changed = try await pixel(of: playback.composition, at: 2.5, through: composition)
        #expect(close(untouched, first, within: 8), "first cut through the look reads \(untouched), was \(first)")
        #expect(close(changed, third.map { 255 - $0 }, within: 8), "inverted cut reads \(changed), was \(third)")
    }
}

/// Apple Log code value of 18 % grey (see `ViewingLookTests` in the core tests).
private let midGreyAppleLog = 0.4882
#endif
