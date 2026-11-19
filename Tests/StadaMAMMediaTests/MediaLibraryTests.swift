import Foundation
import Testing
import StadaMAMCore
@testable import StadaMAMMedia

/// End-to-end against real FFmpeg: ingest, proxy, and recall of the source from the proxy.
/// Skipped automatically on machines without FFmpeg.
@Suite(.enabled(if: FFmpegTools.locate() != nil))
struct MediaLibraryTests {
    let tools = FFmpegTools.locate()!
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "stadamam-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/Volumes/RAID/Day 1", withIntermediateDirectories: true)
    }

    /// A 2-second 29.97 DF test clip with timecode, reel name and stereo audio.
    private func makeSource(_ name: String, timecode: String = "01:00:00;00") throws -> String {
        let path = root + "/Volumes/RAID/Day 1/" + name
        try tools.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30000/1001:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:v", "mpeg4", "-q:v", "5", "-c:a", "pcm_s16le", "-ac", "2",
            "-timecode", timecode, "-metadata:s:v:0", "reel_name=A001", path,
        ])
        return path
    }

    private func makeLibrary() throws -> MediaLibrary {
        MediaLibrary(catalog: try Catalog.inMemory(), tools: tools, storageRoot: root + "/Library",
                     pipelines: [.software])
    }

    @Test func ingestReadsTechnicalMetadata() throws {
        let library = try makeLibrary()
        let asset = try library.importFile(at: try makeSource("A001_C003.mov"))
        #expect(asset.width == 640 && asset.height == 360)
        #expect(asset.frameRate == .fps29_97)
        #expect(asset.durationFrames == 60)
        #expect(asset.startTimecode.description == "01:00:00;00")
        #expect(asset.reelName == "A001")
        #expect(asset.audioChannels == 2)
        #expect(MediaLibrary.mediaFiles(at: root + "/Volumes") == [asset.sourcePath])
    }

    @Test func proxyKeepsIdentityAndSourceIsRecalledAfterRenaming() throws {
        let library = try makeLibrary()
        let asset = try library.importFile(at: try makeSource("A001_C003.mov"))
        let progress = ProgressBox()
        let proxy = try library.makeProxy(for: asset, preset: .h264_720) { progress.set($0) }
        #expect(proxy.status == .ready)
        #expect(proxy.mismatch == nil)
        #expect(proxy.fileName == "A001_C003.mov")
        #expect(progress.value > 0)

        // The proxy carries what Premiere and Resolve relink on.
        let probe = try tools.probe(path: proxy.path)
        let proxyAsset = try #require(probe.asset(path: proxy.path))
        #expect(proxyAsset.startTimecode.description == "01:00:00;00")
        #expect(proxyAsset.durationFrames == asset.durationFrames)
        #expect(proxyAsset.frameRate == asset.frameRate)
        #expect(proxyAsset.reelName == "A001")
        #expect(proxyAsset.audioChannels == 2)
        #expect(probe.embeddedAssetID == asset.id)

        // Rename and move it, as happens once it has been handed to an editor.
        let moved = root + "/handed-to-editor.mov"
        try FileManager.default.copyItem(atPath: proxy.path, toPath: moved)
        let recalled = try library.source(forFileAt: moved)
        #expect(recalled.asset?.id == asset.id)
        #expect(recalled.evidence == .embeddedID)

        // One of our own proxies is never ingested as if it were a source.
        #expect(throws: MediaError.isOwnProxy(assetID: asset.id)) { try library.importFile(at: moved) }
        #expect(library.playablePath(for: asset) == proxy.path)
    }

    @Test func proResProxyAndThumbnails() throws {
        let library = try makeLibrary()
        let asset = try library.importFile(at: try makeSource("B001_C001.mov", timecode: "00:59:58;00"))
        let proxy = try library.makeProxy(for: asset, preset: .proResProxyHalf)
        let probe = try tools.probe(path: proxy.path)
        #expect(probe.asset(path: proxy.path)?.videoCodec == "prores")
        #expect(probe.asset(path: proxy.path)?.height == 180)
        let thumbs = try library.makeThumbnails(for: asset, count: 4)
        #expect(thumbs.count == 4)
        #expect(library.thumbnails(forAssetID: asset.id) == thumbs)
    }

    @Test func timelineCutOnProxiesRelinksToSources() throws {
        let library = try makeLibrary()
        let asset = try library.importFile(at: try makeSource("A001_C003.mov"))
        let proxy = try library.makeProxy(for: asset, preset: .h264_720)
        let xml = """
            <?xml version="1.0"?><xmeml version="4"><sequence><media><video><track><clipitem>
            <file id="f1"><name>A001_C003.mov</name><pathurl>file://localhost\(proxy.path.replacingOccurrences(of: " ", with: "%20"))</pathurl></file>
            </clipitem><clipitem><file id="f2"><name>missing.mov</name><pathurl>file:///nowhere/missing.mov</pathurl></file>
            </clipitem></track></video></media></sequence></xmeml>
            """
        let relink = try #require(try library.relinkTimeline(text: xml))
        #expect(relink.resolutions.count == 2)
        #expect(relink.unresolvedCount == 1)
        #expect(relink.relinkedText.contains(asset.sourcePath.replacingOccurrences(of: " ", with: "%20")))
        #expect(!relink.relinkedText.contains("/Library/Proxies/"))
    }

    /// A pipeline that cannot run here (there is no VideoToolbox on the CI Linux machine, and a
    /// bogus decoder stands in for it on a Mac) must fall through to one that can.
    @Test func fallsBackWhenAPipelineFails() throws {
        var library = try makeLibrary()
        library.pipelines = [.videoToolboxGPU, .software]
        var asset = try library.importFile(at: try makeSource("F001_C001.mov"))
        asset.scan = .interlacedTopFirst  // makes the GPU pipeline inapplicable ...
        let skipped = try library.makeProxy(for: asset, preset: .h264_720)
        #expect(skipped.pipeline == .software)

        #if os(Linux)
        asset.scan = .progressive  // ... and here it is attempted, fails, and is recovered from.
        let recovered = try library.makeProxy(for: asset, preset: .h264_720)
        #expect(recovered.status == .ready)
        #expect(recovered.pipeline == .software)
        #endif
        let stored = try #require(try library.catalog.proxies(forAsset: asset.id).first)
        #expect(stored.pipeline == .software)
        #expect((stored.speed ?? 0) > 0)
        #expect(try library.catalog.assetIDsWithoutReadyProxy().isEmpty)
    }

    @Test func limiterRunsJobsInTurn() async {
        let limiter = JobLimiter(limit: 2)
        let running = ProgressBox(), peak = ProgressBox()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await limiter.acquire()
                    peak.set(running.add(1))
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    _ = running.add(-1)
                    await limiter.release()
                }
            }
        }
        #expect(peak.value == 2)
    }

    @Test func cameraRAWIsIdentifiedAndCataloguedWithoutADecoder() throws {
        let library = try makeLibrary()
        for (name, expected, path) in [("C001.braw", "Blackmagic RAW", DecodePath.blackmagicRAW),
                                       ("A001C002_240101XY.mxf", "Camera RAW (MXF)", .unsupported),
                                       ("A001_C001.R3D", "REDCODE RAW", .unsupported),
                                       ("B001.ari", "ARRIRAW", .unsupported)] {
            let file = root + "/Volumes/RAID/Day 1/" + name
            _ = FileManager.default.createFile(atPath: file, contents: Data([0, 1, 2]))
            let asset = try library.importFile(at: file)
            #expect(asset.formatName == expected)
            #expect(asset.decodePath == path)
            #expect(throws: MediaError.decoderUnavailable(expected)) {
                try library.makeProxy(for: asset, preset: .h264_720)
            }
        }
        #expect(try library.catalog.search("redcode").count == 1)
        #expect(MediaLibrary.mediaFiles(at: root + "/Volumes").count == 4)
    }

    /// Renders a short clip in a given raster / rate / codec and checks it survives ingest and proxying.
    private func roundTrip(_ name: String, size: String, rate: String, codec: [String], seconds: String = "0.5",
                           filter: String? = nil, timecode: String? = "01:00:00:00") throws -> (Asset, Asset) {
        let path = root + "/Volumes/RAID/Day 1/" + name
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                    "-i", "testsrc2=size=\(size):rate=\(rate):duration=\(seconds)"]
        if let filter { args += ["-vf", filter] }
        args += codec
        if let timecode { args += ["-timecode", timecode] }
        try tools.run(tools.ffmpeg, args + [path])
        let library = try makeLibrary()
        let asset = try library.importFile(at: path)
        let proxy = try library.makeProxy(for: asset, preset: .h264_1080)
        let proxyAsset = try #require(try tools.probe(path: proxy.path).asset(path: proxy.path))
        #expect(proxyAsset.frameRate == asset.frameRate)
        #expect(proxyAsset.durationFrames == asset.durationFrames)
        #expect(proxyAsset.startTimecode.description == asset.startTimecode.description)
        #expect(proxyAsset.scan == .progressive)
        #expect(proxy.mismatch == nil)
        return (asset, proxyAsset)
    }

    private let proRes = ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le"]

    @Test func uhd24pAndUHD23976p() throws {
        let (film, filmProxy) = try roundTrip("UHD_2398.mov", size: "3840x2160", rate: "24000/1001", codec: proRes)
        #expect(film.pictureFormatName == "2160p23.976")
        #expect(film.resolutionClass == "UHD 4K")
        #expect(film.formatName == "Apple ProRes 422 HQ")
        #expect(film.durationFrames == 12)
        #expect(film.broadcastStandards == [.atsc3])
        #expect(filmProxy.height == 1080 && filmProxy.width == 1920)

        let (true24, _) = try roundTrip("UHD_24.mov", size: "3840x2160", rate: "24", codec: proRes)
        #expect(true24.pictureFormatName == "2160p24")
        #expect(true24.frameRate == .fps24)

        let (dci, _) = try roundTrip("DCI_24.mov", size: "4096x2160", rate: "24", codec: proRes)
        #expect(dci.resolutionClass == "DCI 4K")
        #expect(dci.broadcastStandards.isEmpty)
    }

    @Test func eightKAndLargerAreNotRestricted() throws {
        let fast = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
        let (uhd8k, proxy) = try roundTrip("8K.mov", size: "7680x4320", rate: "24000/1001", codec: fast, seconds: "0.25")
        #expect(uhd8k.width == 7680 && uhd8k.height == 4320)
        #expect(uhd8k.resolutionClass == "UHD 8K")
        #expect(uhd8k.pictureFormatName == "4320p23.976")
        #expect(proxy.height == 1080)

        // Sony VENICE 2 full-frame 3:2 raster.
        let (venice, _) = try roundTrip("8K6.mov", size: "8640x5760", rate: "24", codec: fast, seconds: "0.25")
        #expect(venice.resolutionClass == "8.6K")
        #expect(venice.pictureFormatName == "5760p24")
    }

    @Test func atscInterlacedAndAnamorphicFormats() throws {
        let mpeg2i = ["-c:v", "mpeg2video", "-flags", "+ildct+ilme", "-b:v", "12M"]
        let (hd, _) = try roundTrip("1080i.ts", size: "1920x1080", rate: "60000/1001", codec: mpeg2i + ["-top", "1"],
                                    filter: "tinterlace=interleave_top", timecode: nil)
        #expect(hd.scan == .interlacedTopFirst)
        #expect(hd.frameRate == .fps29_97)
        #expect(hd.pictureFormatName == "1080i59.94")
        #expect(hd.broadcastStandards == [.atsc1, .atsc3])

        let (sd, _) = try roundTrip("480i.mpg", size: "704x480", rate: "60000/1001", codec: mpeg2i + ["-top", "0"],
                                    filter: "tinterlace=interleave_bottom,setsar=10/11", timecode: nil)
        #expect(sd.scan == .interlacedBottomFirst)
        #expect(sd.pictureFormatName == "480i59.94")
        #expect(sd.pixelAspectNum == 10 && sd.pixelAspectDen == 11)
        #expect(sd.displayWidth == 640)
        #expect(sd.resolutionClass == "SD")
        #expect(sd.broadcastStandards.contains(.atsc1))

        let (p720, _) = try roundTrip("720p.ts", size: "1280x720", rate: "60000/1001",
                                      codec: ["-c:v", "libx264", "-preset", "ultrafast"], timecode: nil)
        #expect(p720.pictureFormatName == "720p59.94")
        #expect(p720.broadcastStandards == [.atsc1, .atsc3])
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0.0
    var value: Double { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ v: Double) { lock.lock(); stored = max(stored, v); lock.unlock() }
    func add(_ v: Double) -> Double { lock.lock(); defer { lock.unlock() }; stored += v; return stored }
}
