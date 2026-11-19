import Foundation
import Testing
#if os(macOS)
import CoreGraphics
import ImageIO
#endif
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

    @Test func ingestReadsTechnicalMetadata() async throws {
        let library = try makeLibrary()
        let asset = try await library.importFile(at: try makeSource("A001_C003.mov"))
        #expect(asset.width == 640 && asset.height == 360)
        #expect(asset.frameRate == .fps29_97)
        #expect(asset.durationFrames == 60)
        #expect(asset.startTimecode.description == "01:00:00;00")
        #expect(asset.reelName == "A001")
        #expect(asset.audioChannels == 2)
        #expect(MediaLibrary.mediaFiles(at: root + "/Volumes") == [asset.sourcePath])
    }

    /// The remote preset through FFmpeg: HEVC, AAC, and still matches the source for relinking.
    @Test func remoteProxyThroughFFmpegKeepsIdentity() async throws {
        let library = try makeLibrary()
        let asset = try await library.importFile(at: try makeSource("R001_C001.mov"))
        let proxy = try await library.makeProxy(for: asset, preset: .remoteHEVC)
        #expect(proxy.mismatch == nil)
        let probe = try tools.probe(path: proxy.path)
        let seen = try #require(probe.asset(path: proxy.path))
        #expect(seen.videoCodec == "hevc")
        #expect(seen.startTimecode.description == "01:00:00;00")
        #expect(seen.reelName == "A001")
        #expect(seen.audioChannels == 2 && seen.durationFrames == 60)
        #expect(probe.embeddedAssetID == asset.id)
        #expect(try await library.source(forFileAt: proxy.path).asset?.id == asset.id)
    }

    #if os(macOS)
    /// The marked copy: made in the background, checked against the source, no server paths inside.
    @Test func watermarkRendererMakesAVerifiedMarkedCopy() async throws {
        let library = try makeLibrary()
        let asset = try await library.importFile(at: try makeSource("W001_C001.mov"))
        let proxy = try await library.makeProxy(for: asset, preset: .h264_720)
        let renderer = WatermarkRenderer(tools: tools, cacheRoot: root + "/WM")

        var state = renderer.state(for: proxy, asset: asset)
        for _ in 0..<200 where state == .preparing {
            try await Task.sleep(nanoseconds: 100_000_000)
            state = renderer.state(for: proxy, asset: asset)
        }
        guard case .ready(let path) = state else { Issue.record("not ready: \(state)"); return }
        #expect(path == root + "/WM/\(proxy.id).mov")
        let probe = try tools.probe(path: path)
        let seen = try #require(probe.asset(path: path))
        #expect(seen.videoCodec == "hevc" && seen.durationFrames == 60 && seen.audioChannels == 2)
        #expect(seen.startTimecode.description == "01:00:00;00" && seen.reelName == "A001")
        #expect(probe.embeddedAssetID == asset.id)
        #expect(ProxyVerifier.mismatch(source: asset, proxy: seen) == nil)
        // The mini's folder layout is not inside the file an editor receives.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(bytes.range(of: Data("Volumes/RAID".utf8)) == nil)
        #expect(bytes.range(of: Data("StradaXR".utf8)) != nil)
        // The mark really is in the picture: the copy differs from the clean proxy's frames.
        let marked = root + "/marked.png", clean = root + "/clean.png"
        try tools.run(tools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", path, "-frames:v", "1", marked])
        try tools.run(tools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", proxy.path, "-frames:v", "1", clean])
        #expect(try Data(contentsOf: URL(fileURLWithPath: marked)) != Data(contentsOf: URL(fileURLWithPath: clean)))
        // Asked again, it is the same finished file, not another render.
        #expect(renderer.state(for: proxy, asset: asset) == .ready(path: path))
    }

    /// Every visible pixel of the mark sits inside the lower-left quarter of the picture.
    @Test func theMarkIsInTheLowerLeftQuarter() throws {
        for (width, height) in [(1920, 1080), (640, 360), (1280, 720)] {
            let png = root + "/mark-\(width).png"
            try WatermarkImage.write(text: Watermark.text, width: width, height: height, to: png)
            let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == width && image.height == height)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var visible = 0
            for row in 0..<height {          // row 0 is the top of the picture
                for column in 0..<width where pixels[(row * width + column) * 4 + 3] > 0 {
                    visible += 1
                    #expect(column < width / 2 && row >= height / 2, "pixel at \(column),\(row) in \(width)x\(height)")
                }
            }
            #expect(visible > 200)
        }
    }
    #endif

    @Test func proxyKeepsIdentityAndSourceIsRecalledAfterRenaming() async throws {
        let library = try makeLibrary()
        let asset = try await library.importFile(at: try makeSource("A001_C003.mov"))
        let progress = ProgressBox()
        let proxy = try await library.makeProxy(for: asset, preset: .h264_720) { progress.set($0) }
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
        let recalled = try await library.source(forFileAt: moved)
        #expect(recalled.asset?.id == asset.id)
        #expect(recalled.evidence == .embeddedID)

        // One of our own proxies is never ingested as if it were a source.
        await #expect(throws: MediaError.isOwnProxy(assetID: asset.id)) { try await library.importFile(at: moved) }
        #expect(library.playablePath(for: asset) == proxy.path)
    }

    @Test func proResProxyAndThumbnails() async throws {
        let library = try makeLibrary()
        let asset = try await library.importFile(at: try makeSource("B001_C001.mov", timecode: "00:59:58;00"))
        let proxy = try await library.makeProxy(for: asset, preset: .proResProxyHalf)
        let probe = try tools.probe(path: proxy.path)
        #expect(probe.asset(path: proxy.path)?.videoCodec == "prores")
        #expect(probe.asset(path: proxy.path)?.height == 180)
        let thumbs = try await library.makeThumbnails(for: asset, count: 4)
        #expect(thumbs.count == 4)
        #expect(library.thumbnails(forAssetID: asset.id) == thumbs)
    }

    @Test func timelineCutOnProxiesRelinksToSources() async throws {
        let library = try makeLibrary()
        let asset = try await library.importFile(at: try makeSource("A001_C003.mov"))
        let proxy = try await library.makeProxy(for: asset, preset: .h264_720)
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
    @Test func fallsBackWhenAPipelineFails() async throws {
        var library = try makeLibrary()
        library.pipelines = [.videoToolboxGPU, .software]
        var asset = try await library.importFile(at: try makeSource("F001_C001.mov"))
        asset.scan = .interlacedTopFirst  // makes the GPU pipeline inapplicable ...
        let skipped = try await library.makeProxy(for: asset, preset: .h264_720)
        #expect(skipped.pipeline == .software)

        #if os(Linux)
        asset.scan = .progressive  // ... and here it is attempted, fails, and is recovered from.
        let recovered = try await library.makeProxy(for: asset, preset: .h264_720)
        #expect(recovered.status == .ready)
        #expect(recovered.pipeline == .software)
        #endif
        let stored = try #require(try library.catalog.proxies(forAsset: asset.id).first)
        #expect(stored.pipeline == .software)
        #expect((stored.speed ?? 0) > 0)
        #expect(try library.catalog.assetIDsWithoutReadyProxy().isEmpty)
    }

    #if os(macOS)
    /// The primary path on a Mac: Apple's frameworks only, checked independently with ffprobe.
    @Test func nativePipelineProducesInterchangeableProxies() async throws {
        let path = root + "/Volumes/RAID/Day 1/N001_C001.mov"
        try tools.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=24000/1001:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s24le", "-ac", "2",
            "-timecode", "01:00:00:00", "-metadata:s:v:0", "reel_name=N001", path,
        ])
        var library = try makeLibrary()
        library.pipelines = [.native]

        let asset = try await library.importFile(at: path)
        #expect(asset.formatName == "Apple ProRes 422 HQ")
        #expect(asset.decodePath == .avFoundation)
        #expect(asset.width == 3840 && asset.height == 2160)
        #expect(asset.frameRate == .fps23_976)
        #expect(asset.durationFrames == 24)
        #expect(asset.startTimecode.description == "01:00:00:00")
        #expect(asset.reelName == "N001")
        #expect(asset.audioChannels == 2)

        for preset in [ProxyPreset.proResProxyHalf, .h264_720, .remoteHEVC] {
            let proxy = try await library.makeProxy(for: asset, preset: preset)
            #expect(proxy.pipeline == .native)
            #expect(proxy.mismatch == nil)
            let probe = try tools.probe(path: proxy.path)
            let seen = try #require(probe.asset(path: proxy.path))
            #expect(seen.videoCodec == (preset.isProRes ? "prores" : preset.isHEVC ? "hevc" : "h264"))
            #expect(seen.height == preset.height(forSourceHeight: 2160))
            #expect(seen.frameRate == .fps23_976)
            #expect(seen.durationFrames == 24)
            #expect(seen.startTimecode.description == "01:00:00:00")
            #expect(seen.reelName == "N001")
            #expect(seen.audioChannels == 2)
            #expect(probe.embeddedAssetID == asset.id)
            let recalled = try await library.source(forFileAt: proxy.path)
            #expect(recalled.asset?.id == asset.id)
        }
        #expect(try await library.makeThumbnails(for: asset, count: 4).count == 4)
        await #expect(throws: MediaError.isOwnProxy(assetID: asset.id)) {
            try await library.importFile(at: library.naming.proxyPath(for: asset, root: library.proxyRoot))
        }
    }

    /// Without FFmpeg the app still ingests and proxies what Apple's frameworks can open.
    @Test func worksWithoutFFmpeg() async throws {
        let source = try makeSource("W001_C001.mov")
        let library = MediaLibrary(catalog: try Catalog.inMemory(), tools: nil, storageRoot: root + "/NoFFmpeg",
                                   pipelines: RenderPipeline.appleSilicon)
        let asset = try await library.importFile(at: source)
        #expect(asset.durationFrames == 60)
        let proxy = try await library.makeProxy(for: asset, preset: .h264_720)
        #expect(proxy.pipeline == .native)
        #expect(proxy.mismatch == nil)
    }
    #endif

    @Test func movedAndRenamedOriginalsAreFoundAgain() async throws {
        let library = try makeLibrary()
        let original = try makeSource("M001_C001.mov")
        let other = try makeSource("M001_C002.mov", timecode: "02:00:00;00")
        let asset = try await library.importFile(at: original)
        _ = try await library.importFile(at: other)
        try library.catalog.save(Marker(assetID: asset.id, inFrame: 10, name: "Keep me"))
        let proxy = try await library.makeProxy(for: asset, preset: .h264_720)
        #expect(try library.offlineAssets().isEmpty)

        // The drive is reorganised: the clip is renamed and moved to another folder.
        let archive = root + "/Volumes/ARCHIVE/2026/Reel 1"
        try FileManager.default.createDirectory(atPath: archive, withIntermediateDirectories: true)
        let moved = archive + "/interview_take3.mov"
        try FileManager.default.moveItem(atPath: original, toPath: moved)
        #expect(try library.offlineAssets().map(\.id) == [asset.id])

        let found = try library.locateMissingSources(under: root + "/Volumes/ARCHIVE")
        #expect(found.map(\.id) == [asset.id])
        let relocated = try #require(try library.catalog.asset(id: asset.id))
        #expect(relocated.sourcePath == moved)
        #expect(relocated.fileName == "interview_take3.mov")
        #expect(try library.offlineAssets().isEmpty)
        // Everything attached to the clip is still attached, and the proxy still leads to it.
        #expect(try library.catalog.markers(forAsset: asset.id).map(\.name) == ["Keep me"])
        #expect(try await library.source(forFileAt: proxy.path).asset?.sourcePath == moved)
        #expect(try library.catalog.allAssets().count == 2)
    }

    @Test func identicalCopiesKeepTheirOwnIdentityWhenOneMoves() async throws {
        let library = try makeLibrary()
        let first = try makeSource("D001_C001.mov")
        let second = root + "/Volumes/RAID/Day 1/D001_C001 copy.mov"
        try FileManager.default.copyItem(atPath: first, toPath: second)
        let a = try await library.importFile(at: first)
        let b = try await library.importFile(at: second)
        #expect(a.id != b.id)
        // One copy moves into a folder elsewhere; the search covers both copies.
        let moved = root + "/Volumes/RAID/Moved"
        try FileManager.default.createDirectory(atPath: moved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: second, toPath: moved + "/renamed.mov")
        let found = try library.locateMissingSources(under: root + "/Volumes/RAID")
        #expect(found.map(\.id) == [b.id])
        #expect(try library.catalog.asset(id: a.id)?.sourcePath == first)
        #expect(try library.catalog.asset(id: b.id)?.sourcePath == moved + "/renamed.mov")
        #expect(try library.offlineAssets().isEmpty)
    }

    @Test func clipsCataloguedWithoutAFingerprintGetOne() async throws {
        let library = try makeLibrary()
        var asset = try await library.importFile(at: try makeSource("K001_C001.mov"))
        asset.fingerprint = nil
        try library.catalog.save(asset)
        var gone = Asset(sourcePath: root + "/Volumes/RAID/not-here.mov")
        gone = try library.catalog.save(gone)
        #expect(try library.backfillFingerprints() == 1)
        #expect(try library.catalog.asset(id: asset.id)?.fingerprint != nil)
        #expect(try library.catalog.asset(id: gone.id)?.fingerprint == nil)
        #expect(try library.backfillFingerprints() == 0)
    }

    @Test func shareMountedUnderAnotherNameIsPickedUp() async throws {
        let library = try makeLibrary()
        let volumes = root + "/Volumes"
        let asset = try await library.importFile(at: try makeSource("S001_C001.mov"))
        // The share comes back as "RAID-1", as macOS does when the old mount point is taken.
        try FileManager.default.moveItem(atPath: volumes + "/RAID", toPath: volumes + "/RAID-1")
        try FileManager.default.createDirectory(atPath: volumes + "/Other/Day 1", withIntermediateDirectories: true)
        #expect(try library.offlineAssets().count == 1)
        let found = try library.remapRemountedVolumes(volumesRoot: volumes)
        #expect(found.map(\.id) == [asset.id])
        #expect(try library.catalog.asset(id: asset.id)?.sourcePath == volumes + "/RAID-1/Day 1/S001_C001.mov")
        #expect(try library.offlineAssets().isEmpty)
        #expect(try library.remapRemountedVolumes(volumesRoot: volumes).isEmpty)
    }

    @Test func timelineFromAWindowsEditorResolves() async throws {
        let library = try makeLibrary()
        let asset = try await library.importFile(at: try makeSource("T001_C001.mov"))
        let mappings = [PathMapping(macPrefix: root + "/Volumes/RAID", editorPrefix: "Z:\\Media")]
        let xml = EditorExport.document(for: [EditorClip(asset: asset)], target: .premierePro, media: .sources,
                                        pathMappings: mappings)
        #expect(xml.contains("file://localhost/Z%3A/Media/Day%201/T001_C001.mov"))
        let relink = try #require(try library.relinkTimeline(text: xml, pathMappings: mappings))
        #expect(relink.resolutions.first?.resolution.evidence == .sourcePath)
        #expect(relink.relinkedText.contains(asset.sourcePath.replacingOccurrences(of: " ", with: "%20")))
    }

    @Test func reimportingAMovedOriginalKeepsItsIdentity() async throws {
        let library = try makeLibrary()
        let original = try makeSource("R001_C001.mov")
        let asset = try await library.importFile(at: original)
        let moved = root + "/Volumes/RAID/Day 1/renamed.mov"
        try FileManager.default.moveItem(atPath: original, toPath: moved)
        let again = try await library.importFile(at: moved)
        #expect(again.id == asset.id)
        #expect(try library.catalog.allAssets().count == 1)
        // A genuine copy alongside a present original is a separate clip.
        let copy = root + "/Volumes/RAID/Day 1/copy.mov"
        try FileManager.default.copyItem(atPath: moved, toPath: copy)
        #expect(try await library.importFile(at: copy).id != asset.id)
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

    @Test func cameraRAWIsIdentifiedAndCataloguedWithoutADecoder() async throws {
        let library = try makeLibrary()
        for (name, expected, path) in [("C001.braw", "Blackmagic RAW", DecodePath.blackmagicRAW),
                                       ("A001C002_240101XY.mxf", "Camera RAW (MXF)", .unsupported),
                                       ("A001_C001.R3D", "REDCODE RAW", .unsupported),
                                       ("B001.ari", "ARRIRAW", .unsupported)] {
            let file = root + "/Volumes/RAID/Day 1/" + name
            _ = FileManager.default.createFile(atPath: file, contents: Data([0, 1, 2]))
            let asset = try await library.importFile(at: file)
            #expect(asset.formatName == expected)
            #expect(asset.decodePath == path)
            await #expect(throws: MediaError.decoderUnavailable(expected)) {
                try await library.makeProxy(for: asset, preset: .h264_720)
            }
        }
        #expect(try library.catalog.search("redcode").count == 1)
        #expect(MediaLibrary.mediaFiles(at: root + "/Volumes").count == 4)
    }

    /// Renders a short clip in a given raster / rate / codec and checks it survives ingest and proxying.
    private func roundTrip(_ name: String, size: String, rate: String, codec: [String], seconds: String = "0.5",
                           filter: String? = nil, timecode: String? = "01:00:00:00") async throws -> (Asset, Asset) {
        let path = root + "/Volumes/RAID/Day 1/" + name
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                    "-i", "testsrc2=size=\(size):rate=\(rate):duration=\(seconds)"]
        if let filter { args += ["-vf", filter] }
        args += codec
        if let timecode { args += ["-timecode", timecode] }
        try tools.run(tools.ffmpeg, args + [path])
        let library = try makeLibrary()
        let asset = try await library.importFile(at: path)
        let proxy = try await library.makeProxy(for: asset, preset: .h264_1080)
        let proxyAsset = try #require(try tools.probe(path: proxy.path).asset(path: proxy.path))
        #expect(proxyAsset.frameRate == asset.frameRate)
        #expect(proxyAsset.durationFrames == asset.durationFrames)
        #expect(proxyAsset.startTimecode.description == asset.startTimecode.description)
        #expect(proxyAsset.scan == .progressive)
        #expect(proxy.mismatch == nil)
        return (asset, proxyAsset)
    }

    private let proRes = ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le"]

    @Test func uhd24pAndUHD23976p() async throws {
        let (film, filmProxy) = try await roundTrip("UHD_2398.mov", size: "3840x2160", rate: "24000/1001", codec: proRes)
        #expect(film.pictureFormatName == "2160p23.976")
        #expect(film.resolutionClass == "UHD 4K")
        #expect(film.formatName == "Apple ProRes 422 HQ")
        #expect(film.durationFrames == 12)
        #expect(film.broadcastStandards == [.atsc3])
        #expect(filmProxy.height == 1080 && filmProxy.width == 1920)

        let (true24, _) = try await roundTrip("UHD_24.mov", size: "3840x2160", rate: "24", codec: proRes)
        #expect(true24.pictureFormatName == "2160p24")
        #expect(true24.frameRate == .fps24)

        let (dci, _) = try await roundTrip("DCI_24.mov", size: "4096x2160", rate: "24", codec: proRes)
        #expect(dci.resolutionClass == "DCI 4K")
        #expect(dci.broadcastStandards.isEmpty)
    }

    @Test func eightKAndLargerAreNotRestricted() async throws {
        let fast = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
        let (uhd8k, proxy) = try await roundTrip("8K.mov", size: "7680x4320", rate: "24000/1001", codec: fast, seconds: "0.25")
        #expect(uhd8k.width == 7680 && uhd8k.height == 4320)
        #expect(uhd8k.resolutionClass == "UHD 8K")
        #expect(uhd8k.pictureFormatName == "4320p23.976")
        #expect(proxy.height == 1080)

        // Sony VENICE 2 full-frame 3:2 raster.
        let (venice, _) = try await roundTrip("8K6.mov", size: "8640x5760", rate: "24", codec: fast, seconds: "0.25")
        #expect(venice.resolutionClass == "8.6K")
        #expect(venice.pictureFormatName == "5760p24")
    }

    @Test func atscInterlacedAndAnamorphicFormats() async throws {
        let mpeg2i = ["-c:v", "mpeg2video", "-flags", "+ildct+ilme", "-b:v", "12M"]
        let (hd, _) = try await roundTrip("1080i.ts", size: "1920x1080", rate: "60000/1001", codec: mpeg2i,
                                          filter: "tinterlace=interleave_top,setfield=tff", timecode: nil)
        #expect(hd.scan == .interlacedTopFirst)
        #expect(hd.frameRate == .fps29_97)
        #expect(hd.pictureFormatName == "1080i59.94")
        #expect(hd.broadcastStandards == [.atsc1, .atsc3])

        let (sd, _) = try await roundTrip("480i.mpg", size: "704x480", rate: "60000/1001", codec: mpeg2i,
                                          filter: "tinterlace=interleave_bottom,setfield=bff,setsar=10/11", timecode: nil)
        #expect(sd.scan == .interlacedBottomFirst)
        #expect(sd.pictureFormatName == "480i59.94")
        #expect(sd.pixelAspectNum == 10 && sd.pixelAspectDen == 11)
        #expect(sd.displayWidth == 640)
        #expect(sd.resolutionClass == "SD")
        #expect(sd.broadcastStandards.contains(.atsc1))

        let (p720, _) = try await roundTrip("720p.ts", size: "1280x720", rate: "60000/1001",
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
