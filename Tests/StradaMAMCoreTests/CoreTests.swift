import Foundation
import Testing
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import StradaMAMCore

@Suite struct TimecodeTests {
    @Test func nonDropRoundTrip() {
        let tc = Timecode("01:00:00:00", rate: .fps24)
        #expect(tc?.frames == 86400)
        #expect(tc?.description == "01:00:00:00")
        #expect(Timecode(frames: 86400 + 25, rate: .fps23_976).description == "01:00:01:01")
    }

    @Test func dropFrameKnownValues() {
        // 29.97 DF: one hour of real time is 107892 frames.
        #expect(Timecode("01:00:00;00", rate: .fps29_97)?.frames == 107892)
        #expect(Timecode(frames: 107892, rate: .fps29_97, dropFrame: true).description == "01:00:00;00")
        // Frames 0 and 1 are skipped at the start of each minute except every tenth.
        #expect(Timecode(frames: 1800, rate: .fps29_97, dropFrame: true).description == "00:01:00;02")
        #expect(Timecode(frames: 17982, rate: .fps29_97, dropFrame: true).description == "00:10:00;00")
    }

    @Test func dropFrameRoundTripsEveryFrame() {
        for frame in stride(from: 0, to: 250_000, by: 37) {
            let tc = Timecode(frames: frame, rate: .fps59_94, dropFrame: true)
            #expect(Timecode(tc.description, rate: .fps59_94)?.frames == frame)
        }
    }

    @Test func rejectsInvalid() {
        #expect(Timecode("01:00:00:24", rate: .fps24) == nil)
        #expect(Timecode("nonsense", rate: .fps24) == nil)
        #expect(FrameRate(string: "24000/1001") == .fps23_976)
        #expect(FrameRate(string: "29.97") == .fps29_97)
    }
}

private func makeAsset(_ path: String, start: Int = 0, duration: Int = 240, reel: String? = nil) -> Asset {
    Asset(sourcePath: path, width: 4096, height: 2160, frameRate: .fps24, durationFrames: duration,
          startTimecodeFrames: start, reelName: reel)
}

@Suite struct CatalogTests {
    @Test func reimportKeepsIdentityAndUserData() throws {
        let catalog = try Catalog.inMemory()
        var first = makeAsset("/Volumes/RAID/Day1/A001_C003.mov")
        first.rating = 4
        first = try catalog.save(first)
        let again = try catalog.save(makeAsset("/Volumes/RAID/Day1/A001_C003.mov"))
        #expect(again.id == first.id)
        #expect(again.rating == 4)
        #expect(again.volumeName == "RAID")
        #expect(try catalog.allAssets().count == 1)
    }

    @Test func relocatedClipTakesItsNewNameAndVolume() {
        let moved = makeAsset("/Volumes/RAID/Day1/A001.mov").relocated(to: "/Volumes/ARCHIVE/2026/take 3.mov")
        #expect(moved.fileName == "take 3.mov")
        #expect(moved.volumeName == "ARCHIVE")
        #expect(makeAsset("/Volumes/RAID/A.mov").relocated(to: "/Users/ed/A.mov").volumeName == nil)
    }

    @Test func searchAcrossNamesTranscriptsTagsAndMarkers() throws {
        let catalog = try Catalog.inMemory()
        let interview = try catalog.save(makeAsset("/Volumes/RAID/Interview_Mayor.mov"))
        let broll = try catalog.save(makeAsset("/Volumes/RAID/B001_C010.braw"))
        try catalog.replaceTranscript(assetID: interview.id, with: [
            TranscriptSegment(assetID: interview.id, startSeconds: 12, endSeconds: 15, text: "The harbour reopened in spring."),
        ])
        try catalog.replaceTags(assetID: broll.id, kinds: [.label], with: [
            SceneTag(assetID: broll.id, kind: .label, label: "harbour", confidence: 0.9, startSeconds: 3, endSeconds: 8),
        ])
        try catalog.save(Marker(assetID: broll.id, inFrame: 48, outFrame: 96, name: "Drone reveal"))

        let hits = try catalog.search("harb")
        #expect(Set(hits.map(\.assetID)) == [interview.id, broll.id])
        #expect(hits.first { $0.kind == .transcript }?.timeSeconds == 12)
        #expect(try catalog.search("drone reveal").first?.timeSeconds == 2)
        #expect(try catalog.search("mayor").first?.kind == .asset)
        #expect(try catalog.search("harbour spring").count == 1)
        #expect(try catalog.search("\"; DROP").isEmpty)

        try catalog.deleteAsset(id: broll.id)
        #expect(try catalog.search("harbour").map(\.assetID) == [interview.id])
        #expect(try catalog.markers(forAsset: broll.id).isEmpty)
    }

    @Test func namedPeopleBecomeSearchable() throws {
        let catalog = try Catalog.inMemory()
        let asset = try catalog.save(makeAsset("/Volumes/RAID/A.mov"))
        let face = FaceSighting(assetID: asset.id, timeSeconds: 4, x: 0, y: 0, width: 0.1, height: 0.1,
                                embedding: FaceSighting.data(from: [1, 0, 0]))
        try catalog.replaceFaces(assetID: asset.id, with: [face])
        try catalog.assign(sightingIDs: [face.id], to: Person(name: "Ada Lovelace"))
        let hit = try catalog.search("lovelace").first
        #expect(hit?.kind == .person)
        #expect(hit?.timeSeconds == 4)
        #expect(try catalog.faces(forAsset: asset.id).first?.vector == [1, 0, 0])
        let person = try #require(try catalog.people().first)
        #expect(try catalog.assetIDs(forPerson: person.id) == [asset.id])
        try catalog.replaceTranscript(assetID: asset.id, with: [
            TranscriptSegment(assetID: asset.id, startSeconds: 0, endSeconds: 1, text: "hi"),
        ])
        try catalog.save(ProxyRecord(assetID: asset.id, path: "/p/A.mov", preset: .h264_720, status: .ready))
        #expect(try catalog.assetIDsWithTranscript() == [asset.id])
        #expect(try catalog.assetIDsWithReadyProxy() == [asset.id])
    }
}

@Suite struct ProxyTests {
    @Test func namingKeepsSourceBaseName() {
        let asset = makeAsset("/Volumes/RAID/Day 1/A001_C003.braw")
        #expect(ProxyNaming.sameName.proxyPath(for: asset, root: "/Proxies") == "/Proxies/RAID/Day 1/A001_C003.mov")
        #expect(ProxyNaming.premiereSuffix.proxyPath(for: asset, root: "/Proxies") == "/Proxies/RAID/Day 1/A001_C003_Proxy.mov")
        #expect(ProxyNaming.matchKey(forFileName: "A001_C003_Proxy.mov") == "a001_c003")
        #expect(ProxyNaming.matchKey(forFileName: "A001_C003.BRAW") == "a001_c003")
    }

    @Test func presetHeights() {
        #expect(ProxyPreset.proResProxyHalf.height(forSourceHeight: 2160) == 1080)
        #expect(ProxyPreset.h264_720.height(forSourceHeight: 2160) == 720)
        #expect(ProxyPreset.h264_1080.height(forSourceHeight: 486) == 486)
        #expect(ProxyPreset.proResProxyHalf.height(forSourceHeight: 1082) == 540)
    }

    @Test func remotePresetStaysInTheBitrateBand() {
        let preset = ProxyPreset.remoteHEVC
        #expect(preset.height(forSourceHeight: 2160) == 1080)
        #expect(preset.height(forSourceHeight: 720) == 720)
        #expect(preset.videoBitrate(width: 1920, height: 1080) == 10_000_000)
        #expect(preset.videoBitrate(width: 3840, height: 2160) == 10_000_000)   // capped
        #expect((3_000_000...10_000_000).contains(preset.videoBitrate(width: 1280, height: 720)))
        #expect(preset.videoBitrate(width: 320, height: 180) == 3_000_000)
        #expect(ProxyPreset.remoteCompressesAudio(channelsInTrack: 1) && ProxyPreset.remoteCompressesAudio(channelsInTrack: 2))
        #expect(!ProxyPreset.remoteCompressesAudio(channelsInTrack: 6))
        #expect(ProxyPreset.allCases.contains(.remoteHEVC) && ProxyPreset(rawValue: "remoteHEVC") == .remoteHEVC)
    }

    @Test func remotePresetKeepsIdentityAndCompressesAudio() {
        let asset = makeAsset("/Volumes/RAID/A001.mov", start: 86400, reel: "A001")
        func args(_ pipeline: RenderPipeline) -> [String] {
            ProxyRenderPlan(asset: asset, preset: .remoteHEVC, outputPath: "/tmp/out.mov", pipeline: pipeline).ffmpegArguments
        }
        for pipeline in [RenderPipeline.software, .videoToolbox, .videoToolboxGPU] {
            let a = args(pipeline)
            #expect(a.contains("01:00:00:00") && a.contains("reel_name=A001"))
            #expect(a.contains("\(ProxyMetadataKey.assetID)=\(asset.id)"))
            #expect(a.contains("hvc1") && a.contains("aac") && !a.contains("pcm_s16le"))
            #expect(a.contains("10000000") && a.contains("12000000"))
        }
        #expect(args(.software).contains("libx265"))
        #expect(args(.videoToolbox).contains("hevc_videotoolbox"))
    }

    @Test func watermarkedCopyKeepsIdentityAndHidesTheMinisPaths() {
        let asset = makeAsset("/Volumes/RAID/Day 1/A001.mov", start: 86400, reel: "A001")
        func args(hardware: Bool) -> [String] {
            WatermarkRenderPlan(asset: asset, proxyPath: "/p/in.mov", overlayPath: "/t/o.png", outputPath: "/c/out.mov",
                                width: 1920, height: 1080, hardware: hardware).ffmpegArguments
        }
        for hardware in [true, false] {
            let a = args(hardware: hardware)
            #expect(a.contains("/t/o.png") && a.contains("01:00:00:00") && a.contains("reel_name=A001"))
            #expect(a.contains("\(ProxyMetadataKey.assetID)=\(asset.id)"))
            #expect(a.contains("\(WatermarkRenderPlan.metadataKey)=StradaXR"))
            #expect(a.contains("hvc1") && a.contains("aac") && a.contains("10000000"))
            #expect(!a.joined(separator: " ").contains("/Volumes/RAID"))
            #expect(a.contains("-map_metadata") && a[a.firstIndex(of: "-map_metadata")! + 1] == "-1")
        }
        #expect(args(hardware: true).contains("hevc_videotoolbox") && args(hardware: false).contains("libx265"))
        #expect(Watermark.text == "StradaXR")
    }

    @Test func ffmpegArgumentsCarryIdentity() {
        let asset = makeAsset("/Volumes/RAID/A001.mov", start: 86400, reel: "A001")
        let args = ProxyRenderPlan(asset: asset, preset: .h264_720, outputPath: "/tmp/out.mov", pipeline: .software).ffmpegArguments
        #expect(args.contains("01:00:00:00"))
        #expect(args.contains("reel_name=A001"))
        #expect(args.contains("-metadata:s:v:0"))
        #expect(args.contains("\(ProxyMetadataKey.assetID)=\(asset.id)"))
        #expect(args.contains("scale=-2:720"))
        #expect(args.last == "/tmp/out.mov")
    }

    @Test func verifierReportsEveryDifference() {
        let source = makeAsset("/Volumes/RAID/A001.mov", start: 86400, duration: 240)
        var proxy = makeAsset("/Proxies/A001.mov", start: 86400, duration: 240)
        #expect(ProxyVerifier.mismatch(source: source, proxy: proxy) == nil)
        proxy.durationFrames = 239
        proxy.startTimecodeFrames = 0
        proxy.audioChannels = 2
        #expect(ProxyVerifier.mismatch(source: source, proxy: proxy)
            == "239 frames instead of 240; start timecode 00:00:00:00 instead of 01:00:00:00; 2 audio channels instead of 0")
        proxy = makeAsset("/Proxies/A001.mov", start: 86400, duration: 240)
        proxy.frameRateNum = 24000
        proxy.frameRateDen = 1001
        #expect(ProxyVerifier.mismatch(source: source, proxy: proxy) == "frame rate 23.976 instead of 24")
    }

    @Test func pipelinesBuildTheRightCommand() {
        var asset = makeAsset("/Volumes/RAID/A001.mov")  // 4096x2160
        func args(_ pipeline: RenderPipeline, _ preset: ProxyPreset = .proResProxyHalf) -> [String] {
            ProxyRenderPlan(asset: asset, preset: preset, outputPath: "/tmp/out.mov", pipeline: pipeline).ffmpegArguments
        }
        let gpu = args(.videoToolboxGPU)
        #expect(gpu.contains("videotoolbox_vld"))
        #expect(gpu.contains("scale_vt=w=2048:h=1080"))
        #expect(gpu.contains("prores_videotoolbox"))
        #expect(!gpu.contains("-pix_fmt"))
        // Hardware decode has to be requested before the input it applies to.
        #expect(gpu.firstIndex(of: "-hwaccel")! < gpu.firstIndex(of: "-i")!)

        let hybrid = args(.videoToolbox, .h264_1080)
        #expect(hybrid.contains("-hwaccel") && !hybrid.contains("videotoolbox_vld"))
        #expect(hybrid.contains("scale=-2:1080") && hybrid.contains("h264_videotoolbox"))

        let software = args(.software)
        #expect(!software.contains("-hwaccel"))
        #expect(software.contains("prores_ks"))

        asset.scan = .interlacedTopFirst
        #expect(!ProxyRenderPlan(asset: asset, preset: .h264_720, outputPath: "/o", pipeline: .videoToolboxGPU).isApplicable)
        #expect(args(.videoToolbox).contains("bwdif=mode=send_frame,scale=-2:1080"))
        #expect(ProxyNaming.besideSource.proxyPath(for: asset, root: "/Proxies") == "/Volumes/RAID/Proxy/A001.mov")
    }
}

/// Identity of a resolution. Assets are compared by ID because dates read back from SQLite
/// are rounded to milliseconds.
struct Found: Equatable {
    var id: String?
    var evidence: SourceResolution.Evidence?
    init(_ id: String?, _ evidence: SourceResolution.Evidence?) {
        self.id = id
        self.evidence = evidence
    }
}

func found(_ resolution: SourceResolution) -> Found { Found(resolution.asset?.id, resolution.evidence) }

@Suite struct ResolverTests {
    @Test func resolvesByEveryKindOfEvidence() throws {
        let catalog = try Catalog.inMemory()
        let a = try catalog.save(makeAsset("/Volumes/RAID/Day1/A001_C003.mov", start: 1000))
        let b = try catalog.save(makeAsset("/Volumes/RAID/Day2/A001_C003.mov", start: 5000))
        let c = try catalog.save(makeAsset("/Volumes/RAID/Day2/B002_C001.braw", reel: "B002"))
        try catalog.save(ProxyRecord(assetID: c.id, path: "/Proxies/RAID/Day2/B002_C001.mov", preset: .h264_720, status: .ready))
        let resolver = SourceResolver(catalog: catalog)

        // Embedded ID survives renaming.
        #expect(try found(resolver.resolve(MediaClue(path: "/tmp/renamed.mov", embeddedAssetID: b.id))) == Found(b.id, .embeddedID))
        #expect(try found(resolver.resolve(MediaClue(path: "/Proxies/RAID/Day2/B002_C001.mov"))) == Found(c.id, .proxyPath))
        // Proxy copied elsewhere: same file name.
        #expect(try found(resolver.resolve(MediaClue(path: "/Users/ed/Desktop/B002_C001.mov"))) == Found(c.id, .proxyFileName))
        #expect(try found(resolver.resolve(MediaClue(fileName: "b002_c001_Proxy.mp4"))) == Found(c.id, .fileName))
        // Duplicate camera names are separated by timecode.
        #expect(try found(resolver.resolve(MediaClue(fileName: "A001_C003_Proxy.mov", startTimecodeFrames: 5000))) == Found(b.id, .fileName))
        if case .ambiguous(let options) = try resolver.resolve(MediaClue(fileName: "A001_C003_Proxy.mov")) {
            #expect(Set(options.map(\.id)) == [a.id, b.id])
        } else {
            Issue.record("expected ambiguous")
        }
        #expect(try found(resolver.resolve(MediaClue(reelName: "b002"))) == Found(c.id, .reelName))
        #expect(try resolver.resolve(MediaClue(fileName: "A001_C0.mov")) == .notFound)
        #expect(try resolver.resolve(MediaClue(fileName: "unknown.mov")) == .notFound)
    }
}

@Suite struct TimelineTests {
    static let premiereXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="4"><sequence><name>Cut 1</name><media><video><track>
        <clipitem id="clipitem-1"><name>Interview</name><in>24</in><out>96</out>
          <file id="file-1"><name>A001_C003_Proxy.mov</name>
            <pathurl>file://localhost/Volumes/Proxies/Day%201/A001_C003_Proxy.mov</pathurl>
            <media><video><samplecharacteristics><width>1280</width></samplecharacteristics></video></media>
          </file></clipitem>
        <clipitem id="clipitem-2"><name>Again</name><file id="file-1"/></clipitem>
        </track></video></media></sequence></xmeml>
        """

    static let resolveFCPXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.10"><resources>
          <asset id="r2" name="B002_C001" start="0s" duration="10s">
            <media-rep kind="original-media" src="file:///Volumes/Proxies/B002_C001.mov"/>
          </asset>
        </resources><library/></fcpxml>
        """

    static let edl = """
        TITLE: Cut 1
        FCM: NON-DROP FRAME

        001  A001     V     C        01:00:01:00 01:00:04:00 00:00:00:00 00:00:03:00
        * FROM CLIP NAME: A001_C003_Proxy.mov
        002  AX       V     C        00:00:00:00 00:00:02:00 00:00:03:00 00:00:05:00
        * FROM CLIP NAME: B002_C001.mov
        """

    @Test func parsesPremiereXML() throws {
        let doc = try #require(TimelineDocument(text: Self.premiereXML))
        #expect(doc.format == .xmeml)
        #expect(doc.references.count == 1)
        #expect(doc.references[0].name == "A001_C003_Proxy.mov")
        #expect(doc.references[0].path == "/Volumes/Proxies/Day 1/A001_C003_Proxy.mov")
    }

    @Test func parsesFCPXMLAndEDL() throws {
        let fcp = try #require(TimelineDocument(text: Self.resolveFCPXML))
        #expect(fcp.format == .fcpxml)
        #expect(fcp.references.map(\.path) == ["/Volumes/Proxies/B002_C001.mov"])

        let edl = try #require(TimelineDocument(text: Self.edl))
        #expect(edl.format == .edl)
        #expect(edl.references.map(\.name) == ["A001_C003_Proxy.mov", "B002_C001.mov"])
        #expect(edl.references.map(\.reelName) == ["A001", nil])
        #expect(TimelineDocument(text: "just some notes") == nil)
    }

    @Test func relinksProxyTimelineToSources() throws {
        let catalog = try Catalog.inMemory()
        let source = try catalog.save(makeAsset("/Volumes/RAID/Day 1/A001_C003.braw"))
        let resolver = SourceResolver(catalog: catalog)
        let doc = try #require(TimelineDocument(text: Self.premiereXML))
        let output = doc.relinked { try? resolver.resolve($0.clue).asset }
        #expect(output.contains("<pathurl>file://localhost/Volumes/RAID/Day%201/A001_C003.braw</pathurl>"))
        #expect(!output.contains("Proxies"))
        #expect(TimelineDocument(text: output)?.references.first?.path == source.sourcePath)
    }
}

@Suite struct AnalysisTests {
    @Test func captionsBreakOnPausesAndSentences() {
        let words = [
            TimedWord(text: "Hello", startSeconds: 0, durationSeconds: 0.4),
            TimedWord(text: "there.", startSeconds: 0.5, durationSeconds: 0.4),
            TimedWord(text: "Next", startSeconds: 1.0, durationSeconds: 0.3),
            TimedWord(text: "line", startSeconds: 1.4, durationSeconds: 0.3),
            TimedWord(text: "later", startSeconds: 5.0, durationSeconds: 0.5),
        ]
        let segments = CaptionBuilder.segments(assetID: "a", words: words)
        #expect(segments.map(\.text) == ["Hello there.", "Next line", "later"])
        let srt = CaptionBuilder.srt(segments)
        #expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:00,900\nHello there.\n\n2\n"))
        #expect(CaptionBuilder.webVTT(segments).contains("00:00:05.000 --> 00:00:05.500\nlater"))
    }

    @Test func labelsMergeIntoRanges() {
        let samples = [0.0, 2, 4, 20].map { FrameLabel(label: "beach", confidence: $0 == 2 ? 0.9 : 0.5, timeSeconds: $0) }
            + [FrameLabel(label: "dog", confidence: 0.7, timeSeconds: 2)]
        let tags = TagBuilder.ranges(assetID: "a", kind: .label, samples: samples, sampleInterval: 2)
        #expect(tags.map(\.label) == ["beach", "dog", "beach"])
        #expect(tags[0].startSeconds == 0 && tags[0].endSeconds == 6 && tags[0].confidence == 0.9)
        #expect(tags[2].startSeconds == 20)
    }

    @Test func shotsSplitOnLargeJumps() {
        let shots = TagBuilder.shots(assetID: "a", sampleTimes: [0, 1, 2, 3, 4], distances: [0.1, 0.1, 2.0, 0.1],
                                     durationSeconds: 5)
        #expect(shots.map(\.startSeconds) == [0, 3])
        #expect(shots.map(\.endSeconds) == [3, 5])
    }

    @Test func facesClusterAndJoinKnownPeople() {
        func face(_ id: String, _ vector: [Float], person: String? = nil) -> FaceSighting {
            FaceSighting(id: id, assetID: "a", personID: person, timeSeconds: 0, x: 0, y: 0, width: 1, height: 1,
                         embedding: FaceSighting.data(from: vector))
        }
        let result = FaceClusterer.cluster([
            face("known", [1, 0, 0], person: "ada"),
            face("f1", [0.98, 0.05, 0]),
            face("f2", [0, 1, 0]),
            face("f3", [0.02, 0.97, 0.01]),
        ])
        #expect(result["ada"] == ["f1"])
        #expect(result.count == 2)
        #expect(result.values.contains(["f2", "f3"]))
    }
}

@Suite struct FormatTests {
    @Test func everyATSCFrameRateHasValidTimecode() throws {
        let rates: [FrameRate] = [.fps23_976, .fps24, .fps25, .fps29_97, .fps30, .fps50, .fps59_94, .fps60,
                                  FrameRate(100), FrameRate(120000, 1001), FrameRate(120)]
        for rate in rates {
            let oneHour = Timecode("01:00:00:00", rate: rate)
            #expect(oneHour?.frames == rate.nominal * 3600)
            #expect(oneHour?.description == "01:00:00:00")
            if rate.supportsDropFrame {
                // In drop-frame, one hour of timecode is one hour of real time (to the frame).
                let drop = try #require(Timecode("01:00:00;00", rate: rate))
                #expect(abs(rate.seconds(forFrames: drop.frames) - 3600) < 0.01)
                #expect(drop.description == "01:00:00;00")
            }
        }
        let dropCapable = rates.filter(\.supportsDropFrame)
        #expect(dropCapable == [.fps29_97, .fps59_94, FrameRate(120000, 1001)])
        #expect(FrameRate(fps: 119.88) == FrameRate(120000, 1001))
        #expect(FrameRate.normalized(2400, 100) == .fps24)
        #expect(FrameRate.normalized(2997, 100) == .fps29_97)
        #expect(FrameRate.normalized(24000, 1001) == .fps23_976)
        #expect(FrameRate.normalized(25, 2) == FrameRate(25, 2))
    }

    @Test func atsc1TableIsComplete() {
        func atsc1(_ w: Int, _ h: Int, _ rate: FrameRate, _ scan: ScanType = .progressive) -> Bool {
            PictureFormat.broadcastStandards(width: w, height: h, frameRate: rate, scan: scan).contains(.atsc1)
        }
        let film: [FrameRate] = [.fps23_976, .fps24, .fps29_97, .fps30]
        let fast: [FrameRate] = [.fps59_94, .fps60]
        // The rates each raster carries, exactly as in A/53 Table 6.2.
        let all = film + fast
        #expect(all.filter { atsc1(1920, 1080, $0) } == film)
        #expect(all.filter { atsc1(1920, 1080, $0, .interlacedTopFirst) } == [.fps29_97, .fps30])
        #expect(all.filter { atsc1(1280, 720, $0) } == all)
        #expect(all.filter { atsc1(704, 480, $0) } == all)
        #expect(all.filter { atsc1(640, 480, $0) } == all)
        #expect(all.filter { atsc1(704, 480, $0, .interlacedBottomFirst) } == [.fps29_97, .fps30])
        #expect(!atsc1(3840, 2160, .fps24))
        #expect(!atsc1(1920, 1080, .fps25))
    }

    @Test func namesAndClassesHaveNoCeiling() {
        #expect(PictureFormat.name(height: 2160, frameRate: .fps23_976, scan: .progressive) == "2160p23.976")
        #expect(PictureFormat.name(height: 1080, frameRate: .fps29_97, scan: .interlacedTopFirst) == "1080i59.94")
        #expect(PictureFormat.name(height: 1080, frameRate: .fps25, scan: .interlacedTopFirst) == "1080i50")
        #expect(PictureFormat.name(height: 4320, frameRate: FrameRate(120000, 1001), scan: .progressive) == "4320p119.88")
        let classes = [(720, 480, "SD"), (1280, 720, "HD"), (1920, 1080, "HD"), (2048, 1080, "2K"),
                       (3840, 2160, "UHD 4K"), (4096, 2160, "DCI 4K"), (4608, 3164, "4.6K"), (5952, 3968, "6K"),
                       (6144, 3456, "6K"), (7680, 4320, "UHD 8K"), (8192, 4320, "DCI 8K"), (8640, 5760, "8.6K"),
                       (12288, 6480, "12K"), (17280, 8640, "17K"), (4480, 3096, "4.5K"), (3424, 2202, "3.4K")]
        for (w, h, expected) in classes {
            #expect(PictureFormat.resolutionClass(width: w, height: h) == expected)
        }
    }

    @Test func identifiesCameraFormats() {
        func id(_ ext: String, _ codec: String? = nil, tag: String? = nil, vendor: String? = nil) -> FormatIdentity {
            FormatIdentity.identify(fileExtension: ext, codec: codec, codecTag: tag, canDecode: codec != nil, vendor: vendor)
        }
        #expect(id("mxf", vendor: "Sony MPC-3628") == FormatIdentity(name: "Sony X-OCN / RAW", decodePath: .unsupported))
        // Sony 8K recorded as XAVC is ordinary HEVC / H.264 and decodes normally.
        #expect(id("mxf", "h264", vendor: "Sony") == FormatIdentity(name: "H.264 / AVC", decodePath: .ffmpeg))
        #expect(id("mp4", "hevc", vendor: "Sony") == FormatIdentity(name: "H.265 / HEVC", decodePath: .avFoundation))
        #expect(id("mxf", vendor: "ARRI") == FormatIdentity(name: "ARRIRAW (MXF)", decodePath: .unsupported))
        #expect(id("braw").decodePath == .blackmagicRAW)
        #expect(id("R3D").name == "REDCODE RAW")
        #expect(id("crm").name == "Canon Cinema RAW Light")
        #expect(id("mov", "prores", tag: "apch") == FormatIdentity(name: "Apple ProRes 422 HQ", decodePath: .avFoundation))
        #expect(id("mov", tag: "aprn") == FormatIdentity(name: "Apple ProRes RAW", decodePath: .avFoundation))
        #expect(id("mxf", "dnxhd") == FormatIdentity(name: "Avid DNxHD / DNxHR", decodePath: .ffmpeg))
        #expect(id("mov", "somethingnew").decodePath == .ffmpeg)
    }
}

@Suite struct SpellingCorrectionTests {
    @Test func aLibraryUnderTheOldNameKeepsBeingUsed() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory() + "stradamam-names-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Nothing there yet: a new library gets the corrected name.
        #expect(AppNames.libraryFolder(in: parent).lastPathComponent == "StradaXR MAM")
        // One from before the correction is used where it is.
        try fm.createDirectory(at: parent.appendingPathComponent("StadaXR MAM"), withIntermediateDirectories: true)
        #expect(AppNames.libraryFolder(in: parent).lastPathComponent == "StadaXR MAM")
        // Once a library exists under the corrected name, that one wins.
        try fm.createDirectory(at: parent.appendingPathComponent("StradaXR MAM"), withIntermediateDirectories: true)
        #expect(AppNames.libraryFolder(in: parent).lastPathComponent == "StradaXR MAM")
    }

    @Test func proxiesStampedWithTheOldKeyAreStillRecognised() throws {
        func probe(_ key: String) throws -> FFProbeResult {
            try FFProbeResult(json: Data("""
                {"streams":[{"codec_type":"video","codec_name":"h264","width":1280,"height":720,"r_frame_rate":"24/1"}],
                 "format":{"duration":"1","tags":{"\(key)":"ABC-123"}}}
                """.utf8))
        }
        #expect(try probe("com.stradaxr.mam.asset-id").embeddedAssetID == "ABC-123")
        #expect(try probe("com.stadaxr.mam.asset-id").embeddedAssetID == "ABC-123")
        #expect(try probe("com.example.other").embeddedAssetID == nil)
        #expect(ProxyMetadataKey.assetID == "com.stradaxr.mam.asset-id")
    }
}

@Suite struct FFProbeTests {
    @Test func buildsAssetFromProbeJSON() throws {
        let json = """
            {"streams":[
              {"codec_type":"video","codec_name":"prores","width":3840,"height":2160,"r_frame_rate":"30000/1001",
               "nb_frames":"300","color_space":"bt709","tags":{"timecode":"01:00:00;00"}},
              {"codec_type":"audio","codec_name":"pcm_s24le","channels":2},
              {"codec_type":"data","tags":{"timecode":"01:00:00;00"}}],
             "format":{"format_name":"mov,mp4","duration":"10.01","size":"123456",
              "tags":{"com.stradaxr.mam.asset-id":"ABC","creation_time":"2026-03-01T10:00:00.000000Z"}}}
            """
        let probe = try FFProbeResult(json: Data(json.utf8))
        let asset = try #require(probe.asset(path: "/Volumes/RAID/clip.mov"))
        #expect(asset.frameRate == .fps29_97)
        #expect(asset.durationFrames == 300)
        #expect(asset.dropFrame)
        #expect(asset.startTimecode.description == "01:00:00;00")
        #expect(asset.audioChannels == 2)
        #expect(asset.capturedAt != nil)
        #expect(probe.embeddedAssetID == "ABC")
    }
}

@Suite struct EditorExportTests {
    private func clips() -> [EditorClip] {
        var a = makeAsset("/Volumes/RAID/Day 1/A001_C003.mov", start: 86400, duration: 240, reel: "A001")
        a.width = 3840
        a.audioChannels = 2
        let b = makeAsset("/Volumes/RAID/Day 1/B002 & C001.braw", start: 0, duration: 120)
        return [
            EditorClip(asset: a, proxyPath: "/Proxies/RAID/Day 1/A001_C003.mov", markers: [
                Marker(assetID: a.id, inFrame: 24, name: "Smile <best>", note: "use this"),
                Marker(assetID: a.id, inFrame: 48, outFrame: 95, name: "Answer 1"),
            ]),
            EditorClip(asset: b),
        ]
    }

    private func isWellFormed(_ xml: String) -> Bool {
        XMLParser(data: Data(xml.utf8)).parse()
    }

    @Test func finalCutDocumentLinksOriginalAndProxy() throws {
        let xml = EditorExport.document(for: clips(), target: .finalCutPro, media: .sources)
        #expect(isWellFormed(xml))
        #expect(xml.contains("<fcpxml version=\"1.9\">"))
        #expect(xml.contains("name=\"FFVideoFormat3840x2160p24\" frameDuration=\"1/24s\" width=\"3840\" height=\"2160\""))
        #expect(xml.contains("kind=\"original-media\" src=\"file:///Volumes/RAID/Day%201/A001_C003.mov\""))
        #expect(xml.contains("kind=\"proxy-media\" src=\"file:///Proxies/RAID/Day%201/A001_C003.mov\""))
        // Start is the source timecode (01:00:00:00 at 24 fps), so the clip keeps its timecode.
        #expect(xml.contains("start=\"86400/24s\" duration=\"240/24s\""))
        #expect(xml.contains("<marker start=\"86424/24s\" duration=\"1/24s\" value=\"Smile &lt;best&gt;\" note=\"use this\"/>"))
        #expect(xml.contains("<keyword start=\"86448/24s\" duration=\"48/24s\" value=\"Answer 1\"/>"))
        #expect(xml.contains("B002%20&amp;%20C001.braw"))
        // Our own reader sees the originals, not the proxies.
        let doc = try #require(TimelineDocument(text: xml))
        #expect(doc.references.map(\.path) == ["/Volumes/RAID/Day 1/A001_C003.mov", "/Volumes/RAID/Day 1/B002 & C001.braw"])
    }

    @Test func fractionalRatesStayExact() {
        var asset = makeAsset("/Volumes/RAID/A.mov", start: 86400, duration: 24)
        asset.frameRateNum = 24000
        asset.frameRateDen = 1001
        #expect(EditorExport.time(86400, asset.frameRate) == "86486400/24000s")
        let xml = EditorExport.document(for: [EditorClip(asset: asset)], target: .davinciResolve, media: .sources)
        #expect(xml.contains("frameDuration=\"1001/24000s\""))
        #expect(xml.contains("tcFormat=\"NDF\""))
    }

    @Test func premiereDocumentCarriesTimecodeMarkersAndSubclips() throws {
        let xml = EditorExport.document(for: clips(), target: .premierePro, media: .sources)
        #expect(isWellFormed(xml))
        #expect(xml.contains("<pathurl>file://localhost/Volumes/RAID/Day%201/A001_C003.mov</pathurl>"))
        #expect(xml.contains("<string>01:00:00:00</string><frame>86400</frame><displayformat>NDF</displayformat><reel><name>A001</name></reel>"))
        #expect(xml.contains("<timebase>24</timebase><ntsc>FALSE</ntsc>"))
        #expect(xml.contains("<marker><name>Smile &lt;best&gt;</name><comment>use this</comment><in>24</in><out>-1</out></marker>"))
        #expect(xml.contains("<name>Answer 1</name>"))
        #expect(xml.contains("<in>48</in><out>96</out>"))
        #expect(xml.contains("<file id=\"file-1\"/>"))
        let doc = try #require(TimelineDocument(text: xml))
        #expect(doc.format == .xmeml)
        #expect(doc.references.count == 2)
    }

    @Test func proxyOnlyHandoverComesBackToSources() throws {
        let catalog = try Catalog.inMemory()
        let source = try catalog.save(makeAsset("/Volumes/RAID/Day 1/A001_C003.mov", start: 86400))
        try catalog.save(ProxyRecord(assetID: source.id, path: "/Proxies/A001_C003.mov", preset: .h264_720, status: .ready))
        let noProxy = try catalog.save(makeAsset("/Volumes/RAID/Day 1/Z009.mov"))
        let clips = [EditorClip(asset: source, proxyPath: "/Proxies/A001_C003.mov"), EditorClip(asset: noProxy)]
        let resolver = SourceResolver(catalog: catalog)

        for target in EditorTarget.allCases {
            let handed = EditorExport.document(for: clips, target: target, media: .proxies)
            // Clips without a proxy are left out, and nothing points at a source.
            #expect(!handed.contains("Z009"))
            #expect(!handed.contains("/Volumes/RAID"))
            let doc = try #require(TimelineDocument(text: handed))
            #expect(doc.references.map(\.path) == ["/Proxies/A001_C003.mov"])
            let back = doc.relinked { try? resolver.resolve($0.clue).asset }
            #expect(back.contains("/Volumes/RAID/Day%201/A001_C003.mov"))
            #expect(!back.contains("/Proxies/"))
        }
    }
}

@Suite struct BinTests {
    @Test func binsNestAndSmartBinsFillThemselves() throws {
        let catalog = try Catalog.inMemory()
        let a = try catalog.save(makeAsset("/Volumes/RAID/Day1/A001_C001.mov"))
        let b = try catalog.save(makeAsset("/Volumes/RAID/Day1/A001_C002.mov"))
        let c = try catalog.save(makeAsset("/Volumes/RAID/Day2/Interview_Mayor.mov"))

        let project = Bin(name: "Harbour Film")
        let selects = Bin(name: "Selects", parentID: project.id)
        let interviews = Bin(name: "Interviews", parentID: project.id, smartQuery: "interview")
        for bin in [project, selects, interviews] { try catalog.save(bin) }
        try catalog.add(assetIDs: [a.id], toBin: project.id)
        try catalog.add(assetIDs: [b.id, b.id], toBin: selects.id)

        #expect(try catalog.assetIDs(inBin: selects.id) == [b.id])
        #expect(try catalog.assetIDs(inBin: interviews.id) == [c.id])
        // A bin shows its own clips plus everything in the bins inside it, smart ones included.
        #expect(try catalog.assetIDs(inBin: project.id) == [a.id, b.id, c.id])
        #expect(try catalog.binCounts() == [project.id: 3, selects.id: 1, interviews.id: 1])
        #expect(try catalog.binIDs(containing: b.id) == [selects.id])

        // The smart bin picks up later work without being touched.
        try catalog.replaceTranscript(assetID: a.id, with: [
            TranscriptSegment(assetID: a.id, startSeconds: 0, endSeconds: 2, text: "This interview is rolling"),
        ])
        #expect(try catalog.assetIDs(inBin: interviews.id) == [a.id, c.id])

        let tree = BinNode.tree(from: try catalog.bins())
        #expect(tree.map(\.bin.name) == ["Harbour Film"])
        #expect(tree[0].children?.map(\.bin.name) == ["Interviews", "Selects"])

        try catalog.remove(assetIDs: [b.id], fromBin: selects.id)
        #expect(try catalog.assetIDs(inBin: selects.id).isEmpty)
        // Deleting a bin removes its nested bins but never the clips.
        try catalog.deleteBin(id: project.id)
        #expect(try catalog.bins().isEmpty)
        #expect(try catalog.allAssets().count == 3)
        // Deleting a clip removes it from its bins.
        let keep = Bin(name: "Keep")
        try catalog.save(keep)
        try catalog.add(assetIDs: [a.id], toBin: keep.id)
        try catalog.deleteAsset(id: a.id)
        #expect(try catalog.assetIDs(inBin: keep.id).isEmpty)
    }

    @Test func sortingAndGrouping() {
        var a = makeAsset("/Volumes/RAID/Day1/clip10.mov", duration: 100, reel: "A001")
        var b = makeAsset("/Volumes/RAID/Day1/clip2.mov", duration: 300, reel: "A001")
        var c = makeAsset("/Volumes/NAS/Day2/Clip1.mov", duration: 200)
        a.rating = 5
        b.capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        c.capturedAt = Date(timeIntervalSince1970: 1_800_090_000)
        c.fileSize = 9
        let all = [a, b, c]
        #expect(LibrarySort.name.sorted(all).map(\.fileName) == ["Clip1.mov", "clip2.mov", "clip10.mov"])
        #expect(LibrarySort.duration.sorted(all).map(\.fileName) == ["clip2.mov", "Clip1.mov", "clip10.mov"])
        #expect(LibrarySort.rating.sorted(all).first?.fileName == "clip10.mov")
        #expect(LibrarySort.captured.sorted(all).map(\.fileName) == ["Clip1.mov", "clip2.mov", "clip10.mov"])
        #expect(LibrarySort.size.sorted(all).first?.fileName == "Clip1.mov")

        let byVolume = LibraryGrouping.volume.groups(LibrarySort.name.sorted(all))
        #expect(byVolume.map(\.title) == ["NAS", "RAID"])
        #expect(byVolume[1].assets.map(\.fileName) == ["clip2.mov", "clip10.mov"])
        #expect(LibraryGrouping.reel.groups(all).map(\.title) == ["A001", "No reel"])
        #expect(LibraryGrouping.folder.groups(all).map(\.title) == ["/Volumes/NAS/Day2", "/Volumes/RAID/Day1"])
        #expect(LibraryGrouping.none.groups(all).count == 1)
        #expect(LibraryGrouping.none.groups([]).isEmpty)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(LibraryGrouping.day.groups(LibrarySort.captured.sorted(all), calendar: utc).map(\.title)
            == ["2027-01-16", "2027-01-15", "Unknown date"])
    }
}

@Suite struct NetworkPathTests {
    let mappings = [
        PathMapping(macPrefix: "/Volumes/Media", editorPrefix: "Z:\\Media"),
        PathMapping(macPrefix: "/Volumes/Media/Proxies/", editorPrefix: "/mnt/proxies"),
        PathMapping(macPrefix: "/Volumes/NAS", editorPrefix: "\\\\server\\nas"),
    ]

    @Test func macPathsBecomeEditorPaths() {
        #expect(PathMapping.toEditor("/Volumes/Media/Day 1/A001.mov", using: mappings) == "/Z:/Media/Day 1/A001.mov")
        // The most specific mapping wins.
        #expect(PathMapping.toEditor("/Volumes/Media/Proxies/A001.mov", using: mappings) == "/mnt/proxies/A001.mov")
        #expect(PathMapping.toEditor("/Volumes/NAS/x.mov", using: mappings) == "//server/nas/x.mov")
        #expect(PathMapping.toEditor("/Volumes/MediaOther/x.mov", using: mappings) == "/Volumes/MediaOther/x.mov")
    }

    @Test func editorPathsComeBackToTheMac() {
        #expect(PathMapping.toMac("/Z:/Media/Day 1/A001.mov", using: mappings) == "/Volumes/Media/Day 1/A001.mov")
        #expect(PathMapping.toMac("z:\\media\\Day 1\\A001.mov", using: mappings) == "/Volumes/Media/Day 1/A001.mov")
        #expect(PathMapping.toMac("/mnt/proxies/A001.mov", using: mappings) == "/Volumes/Media/Proxies/A001.mov")
        #expect(PathMapping.toMac("//server/nas/x.mov", using: mappings) == "/Volumes/NAS/x.mov")
        #expect(PathMapping.toMac("/somewhere/else.mov", using: mappings) == "/somewhere/else.mov")
    }

    @Test func exportsForAWindowsEditorUseItsDriveLetters() throws {
        let asset = makeAsset("/Volumes/Media/Day 1/A001_C003.mov", start: 86400)
        let clip = EditorClip(asset: asset, proxyPath: "/Volumes/Media/Proxies/A001_C003.mov")
        let premiere = EditorExport.document(for: [clip], target: .premierePro, media: .sources, pathMappings: mappings)
        #expect(premiere.contains("<pathurl>file://localhost/Z%3A/Media/Day%201/A001_C003.mov</pathurl>"))
        let resolve = EditorExport.document(for: [clip], target: .davinciResolve, media: .proxies, pathMappings: mappings)
        #expect(resolve.contains("src=\"file:///mnt/proxies/A001_C003.mov\""))
        // And a timeline written on that Windows machine is understood on the way back.
        let doc = try #require(TimelineDocument(text: premiere))
        #expect(doc.references.first?.path.map { PathMapping.toMac($0, using: mappings) } == asset.sourcePath)
    }

    @Test func remountedVolumeCandidates() {
        let candidates = VolumeRemapper.candidates(for: "/Volumes/Media/Day 1/A001.mov", volumesRoot: "/Volumes",
                                                   mountedVolumes: ["Macintosh HD", "Media-1", "Backup", "Media"])
        #expect(candidates == ["/Volumes/Media-1/Day 1/A001.mov", "/Volumes/Backup/Day 1/A001.mov",
                               "/Volumes/Macintosh HD/Day 1/A001.mov"])
        #expect(VolumeRemapper.candidates(for: "/Users/ed/A001.mov", volumesRoot: "/Volumes", mountedVolumes: ["Media"]).isEmpty)
    }
}

@Suite struct FaceRegroupingTests {
    private func faces(_ asset: String, _ vectors: [[Float]]) -> [FaceSighting] {
        vectors.enumerated().map { i, v in
            FaceSighting(assetID: asset, timeSeconds: Double(i), x: 0, y: 0, width: 1, height: 1,
                         embedding: FaceSighting.data(from: v))
        }
    }

    @Test func rerunningSameFacesKeepsPeople() throws {
        let catalog = try Catalog.inMemory()
        let asset = try catalog.save(makeAsset("/Volumes/RAID/A.mov"))
        let vectors: [[Float]] = [[1, 0, 0], [0, 1, 0]]
        try catalog.replaceAndGroupFaces(assetID: asset.id, with: faces(asset.id, vectors))
        let first = Set(try catalog.people().map(\.id))
        #expect(first.count == 2)
        for _ in 0..<3 {
            try catalog.replaceAndGroupFaces(assetID: asset.id, with: faces(asset.id, vectors))
        }
        #expect(Set(try catalog.people().map(\.id)) == first)
        #expect(Set(try catalog.faces(forAsset: asset.id).compactMap(\.personID)) == first)
    }

    @Test func namedPersonSurvivesReanalysisOfTheirOnlyClip() throws {
        let catalog = try Catalog.inMemory()
        let asset = try catalog.save(makeAsset("/Volumes/RAID/A.mov"))
        try catalog.replaceAndGroupFaces(assetID: asset.id, with: faces(asset.id, [[1, 0, 0]]))
        let person = try #require(try catalog.people().first)
        try catalog.rename(person: person, to: "Ada")
        try catalog.replaceAndGroupFaces(assetID: asset.id, with: faces(asset.id, [[0.99, 0.05, 0]]))
        let people = try catalog.people()
        #expect(people.count == 1)
        #expect(people.first?.id == person.id)
        #expect(people.first?.name == "Ada")
        #expect(try catalog.faces(forAsset: asset.id).first?.personID == person.id)
    }

    @Test func emptyUnnamedPeopleAreRemovedNamedKept() throws {
        let catalog = try Catalog.inMemory()
        let asset = try catalog.save(makeAsset("/Volumes/RAID/A.mov"))
        let face = faces(asset.id, [[1, 0, 0]])[0]
        try catalog.replaceFaces(assetID: asset.id, with: [face])
        let used = Person(name: nil)
        try catalog.assign(sightingIDs: [face.id], to: used)
        try catalog.assign(sightingIDs: [], to: Person(name: nil))
        try catalog.assign(sightingIDs: [], to: Person(name: "  "))
        let named = Person(name: "Grace")
        try catalog.assign(sightingIDs: [], to: named)
        #expect(try catalog.deleteEmptyPeople() == 2)
        #expect(Set(try catalog.people().map(\.id)) == [used.id, named.id])
    }
}
