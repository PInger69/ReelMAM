import Foundation
import Testing
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import StadaMAMCore

private func clip(_ path: String, rate: FrameRate = .fps24, start: String = "00:00:00:00", duration: Int = 240,
                  reel: String? = nil, audio: Int = 2, width: Int = 3840, height: Int = 2160) -> Asset {
    let timecode = Timecode(start, rate: rate)!
    return Asset(sourcePath: path, width: width, height: height, frameRate: rate, durationFrames: duration,
                 startTimecodeFrames: timecode.frames, dropFrame: timecode.dropFrame, reelName: reel,
                 audioChannels: audio)
}

@Suite struct SequenceModelTests {
    let catalog: Catalog
    let a: Asset, b: Asset, c: Asset

    init() throws {
        catalog = try Catalog.inMemory()
        a = try catalog.save(clip("/Volumes/RAID/Day 1/A001_C001.mov", rate: .fps23_976, reel: "A001"))
        b = try catalog.save(clip("/Volumes/RAID/Day 1/A001_C002.mov", rate: .fps23_976, reel: "A001"))
        c = try catalog.save(clip("/Volumes/RAID/Day 2/B002_C001.mov", rate: .fps23_976, reel: "B002"))
    }

    private func order(_ sequence: CutSequence) throws -> [String] {
        try catalog.cuts(inSequence: sequence.id).map(\.assetID)
    }

    @Test func addInsertReorderTrimRemove() throws {
        let sequence = try catalog.createSequence(named: "Scene 12")
        #expect(sequence.frameRate == nil)
        try catalog.insertCut(inSequence: sequence.id, assetID: a.id, inFrame: 10, outFrame: 57)
        let second = try catalog.insertCut(inSequence: sequence.id, assetID: b.id, inFrame: 0, outFrame: 23)
        // The first cut gave the sequence its frame rate.
        #expect(try catalog.sequence(id: sequence.id)?.frameRate == .fps23_976)

        try catalog.insertCut(inSequence: sequence.id, assetID: c.id, inFrame: 5, outFrame: 9, at: 1)
        #expect(try order(sequence) == [a.id, c.id, b.id])
        #expect(try catalog.cuts(inSequence: sequence.id).map(\.position) == [0, 1, 2])

        try catalog.moveCut(id: second.id, to: 0)
        #expect(try order(sequence) == [b.id, a.id, c.id])
        try catalog.moveCut(id: second.id, to: 99)
        #expect(try order(sequence) == [a.id, c.id, b.id])

        // Trims stay inside the clip and never turn a cut inside out.
        #expect(try catalog.trimCut(id: second.id, inFrame: 12).inFrame == 12)
        #expect(try catalog.trimCut(id: second.id, outFrame: 5000).outFrame == 239)
        let flipped = try catalog.trimCut(id: second.id, outFrame: 3)
        #expect(flipped.inFrame == 12 && flipped.outFrame == 12)
        #expect(try catalog.trimCut(id: second.id, inFrame: -40, outFrame: 20).inFrame == 0)

        try catalog.removeCut(id: second.id)
        #expect(try order(sequence) == [a.id, c.id])
        #expect(try catalog.cuts(inSequence: sequence.id).map(\.position) == [0, 1])
        #expect(try catalog.cutCounts()[sequence.id] == 2)
    }

    @Test func renameDuplicateDelete() throws {
        let sequence = try catalog.createSequence(named: "Assembly")
        let cut = try catalog.insertCut(inSequence: sequence.id, assetID: a.id, inFrame: 0, outFrame: 47)
        try catalog.renameSequence(id: sequence.id, to: "Assembly v1")
        #expect(try catalog.sequence(id: sequence.id)?.name == "Assembly v1")

        let copy = try catalog.duplicateSequence(id: sequence.id)
        #expect(copy.name == "Assembly v1 copy")
        #expect(copy.frameRate == .fps23_976)
        // The copy is its own sequence: changing it leaves the original alone.
        let copied = try #require(try catalog.cuts(inSequence: copy.id).first)
        #expect(copied.id != cut.id && copied.outFrame == 47)
        try catalog.trimCut(id: copied.id, outFrame: 10)
        #expect(try catalog.cuts(inSequence: sequence.id).first?.outFrame == 47)

        try catalog.deleteSequence(id: sequence.id)
        #expect(try catalog.sequences().map(\.id) == [copy.id])
        #expect(try catalog.cuts(inSequence: sequence.id).isEmpty)
        #expect(throws: SequenceError.noSuchSequence) { try catalog.renameSequence(id: sequence.id, to: "x") }
    }

    @Test func subclipsBecomeCutsAndDeletedClipsLeave() throws {
        let sequence = try catalog.createSequence(named: "Selects")
        let subclip = Marker(assetID: a.id, inFrame: 48, outFrame: 95, name: "Answer 1")
        let cut = try catalog.insertCut(inSequence: sequence.id, subclip: subclip)
        #expect(cut.inFrame == 48 && cut.outFrame == 95 && cut.note == "Answer 1" && cut.durationFrames == 48)
        try catalog.insertCut(inSequence: sequence.id, assetID: b.id, inFrame: 0, outFrame: 9)
        try catalog.deleteAsset(id: a.id)
        let resolved = try #require(try catalog.resolvedSequence(id: sequence.id))
        #expect(resolved.cuts.map(\.asset.id) == [b.id])
        #expect(resolved.cuts.first?.recordStart == 0)
    }

    @Test func layoutKeepsRealTimeAcrossFrameRates() throws {
        let ntsc = try catalog.save(clip("/Volumes/RAID/Day 3/C003.mov", rate: .fps29_97, start: "10:00:00;00", duration: 6000))
        let pal = try catalog.save(clip("/Volumes/RAID/Day 3/D004.mov", rate: .fps25))
        let film = try catalog.save(clip("/Volumes/RAID/Day 3/E005.mov", rate: .fps24))
        let sequence = try catalog.createSequence(named: "Mixed", frameRate: .fps24)
        try catalog.insertCut(inSequence: sequence.id, assetID: film.id, inFrame: 0, outFrame: 47)   // 2 s
        try catalog.insertCut(inSequence: sequence.id, assetID: ntsc.id, inFrame: 0, outFrame: 59)   // 2.002 s
        try catalog.insertCut(inSequence: sequence.id, assetID: pal.id, inFrame: 0, outFrame: 24)    // 1 s
        let resolved = try #require(try catalog.resolvedSequence(id: sequence.id))
        #expect(resolved.cuts.map(\.recordStart) == [0, 48, 96])
        #expect(resolved.cuts.map(\.recordFrames) == [48, 48, 24])
        #expect(resolved.totalFrames == 120)
        #expect(resolved.startTimecode.description == "01:00:00:00")
        #expect(resolved.recordTimecode(atFrame: 96).description == "01:00:04:00")
        #expect(resolved.cut(atFrame: 50)?.asset.id == ntsc.id)
        #expect(resolved.assets.map(\.id) == [film.id, ntsc.id, pal.id])
    }
}

@Suite struct SequenceExportTests {
    /// A 23.976 clip starting at 01:00:00:00 and a 29.97 drop-frame clip starting at 10:00:00;00.
    static let film = clip("/Volumes/RAID/Day 1/A001_C003.mov", rate: .fps23_976, start: "01:00:00:00",
                           duration: 2400, reel: "A001")
    static let ntsc = clip("/Volumes/RAID/Day 2/B002 & C001.mov", rate: .fps29_97, start: "10:00:00;00",
                           duration: 9000, reel: "B002", audio: 1, width: 1920, height: 1080)

    private func sequence(rate: FrameRate, drop: Bool = false, _ cuts: [(Asset, Int, Int)]) -> ResolvedSequence {
        let sequence = CutSequence(name: "Scene 12 <v2>", frameRate: rate, dropFrame: drop)
        return ResolvedSequence(sequence: sequence, cuts: cuts.map {
            (SequenceCut(sequenceID: sequence.id, assetID: $0.0.id, inFrame: $0.1, outFrame: $0.2), $0.0)
        })
    }

    private func isWellFormed(_ xml: String) -> Bool { XMLParser(data: Data(xml.utf8)).parse() }

    @Test func edlCarriesReelSourceAndRecordTimecode() {
        let film = Self.film
        let edl = EditorExport.timeline(sequence(rate: .fps23_976, [(film, 24, 71), (film, 240, 263)]), format: .edl)
        let lines = edl.split(separator: "\n").map(String.init)
        #expect(lines[0] == "TITLE: Scene 12 <v2>")
        #expect(lines[1] == "FCM: NON-DROP FRAME")
        #expect(lines[2] == "001 A001     AA/V  C        01:00:01:00 01:00:03:00 01:00:00:00 01:00:02:00")
        #expect(lines[3] == "* SOURCE FILE: /Volumes/RAID/Day 1/A001_C003.mov")
        #expect(lines[4] == "* FROM CLIP NAME: A001_C003.mov")
        #expect(lines[5] == "002 A001     AA/V  C        01:00:10:00 01:00:11:00 01:00:02:00 01:00:03:00")
        // The EDL reads back through source recall with the reel and file name intact.
        let references = TimelineDocument(text: edl)?.references ?? []
        #expect(references.first?.reelName == "A001" && references.first?.name == "A001_C003.mov")
    }

    @Test func dropFrameSourceAndTimeline() {
        // Frame 1800 of a 29.97 DF clip starting at 10:00:00;00 is 10:01:00;02.
        let edl = EditorExport.timeline(sequence(rate: .fps29_97, drop: true, [(Self.ntsc, 1800, 1859)]), format: .edl)
        #expect(edl.contains("FCM: DROP FRAME"))
        #expect(edl.contains("001 B002     B     C        10:01:00;02 10:01:02;02 01:00:00;00 01:00:02;00"))

        let xml = EditorExport.timeline(sequence(rate: .fps29_97, drop: true, [(Self.ntsc, 1800, 1859)]), format: .premiereXML)
        #expect(isWellFormed(xml))
        #expect(xml.contains("<string>10:00:00;00</string><frame>1078920</frame><displayformat>DF</displayformat><reel><name>B002</name></reel>"))
        #expect(xml.contains("<string>01:00:00;00</string><frame>107892</frame><displayformat>DF</displayformat>"))
        #expect(xml.contains("<in>1800</in><out>1860</out>"))
        #expect(xml.contains("<name>B002 &amp; C001.mov</name>"))

        let fcpxml = EditorExport.timeline(sequence(rate: .fps29_97, drop: true, [(Self.ntsc, 1800, 1859)]), format: .fcpxml)
        #expect(isWellFormed(fcpxml))
        #expect(fcpxml.contains("tcFormat=\"DF\""))
        // 01:00:00;00 is frame 107892, written as an exact fraction of a second.
        #expect(fcpxml.contains("tcStart=\"107999892/30000s\""))
    }

    @Test func fcpxmlIsATimelineLinkedToOriginals() {
        let film = Self.film
        let xml = EditorExport.timeline(sequence(rate: .fps23_976, [(film, 24, 71), (film, 240, 263)]), format: .fcpxml)
        #expect(isWellFormed(xml))
        #expect(xml.contains("<project name=\"Scene 12 &lt;v2&gt;\">"))
        #expect(xml.contains("name=\"FFVideoFormat3840x2160p2398\""))
        #expect(xml.contains("<sequence format=\"r1\" duration=\"72072/24000s\" tcStart=\"86486400/24000s\" tcFormat=\"NDF\""))
        // First cut: on the timeline at its start, from source 01:00:01:00, for 48 frames.
        #expect(xml.contains("offset=\"86486400/24000s\" start=\"86510424/24000s\" duration=\"48048/24000s\""))
        // Second cut follows it and starts ten seconds into the same clip.
        #expect(xml.contains("offset=\"86534448/24000s\" start=\"86726640/24000s\" duration=\"24024/24000s\""))
        // The clip is declared once, pointing at the camera original.
        #expect(xml.components(separatedBy: "<asset id=").count == 2)
        #expect(xml.contains("src=\"file:///Volumes/RAID/Day%201/A001_C003.mov\""))
        #expect(TimelineDocument(text: xml)?.references.first?.path == film.sourcePath)
    }

    @Test func premiereTimelineHasLinkedPictureAndSound() {
        let film = Self.film
        let xml = EditorExport.timeline(sequence(rate: .fps23_976, [(film, 24, 71), (film, 240, 263)]), format: .premiereXML)
        #expect(isWellFormed(xml))
        #expect(xml.contains("<sequence id=\"sequence-1\">"))
        #expect(xml.contains("<duration>72</duration>"))
        #expect(xml.contains("<start>0</start><end>48</end>"))
        #expect(xml.contains("<in>24</in><out>72</out>"))
        #expect(xml.contains("<start>48</start><end>72</end>"))
        #expect(xml.contains("<in>240</in><out>264</out>"))
        #expect(xml.contains("<pathurl>file://localhost/Volumes/RAID/Day%201/A001_C003.mov</pathurl>"))
        #expect(xml.contains("<timebase>24</timebase><ntsc>TRUE</ntsc>"))
        // Described in full once; every other use refers back to it.
        #expect(xml.components(separatedBy: "<file id=\"file-1\">").count == 2)
        #expect(xml.components(separatedBy: "<file id=\"file-1\"/>").count == 6)
        // Two audio channels: two audio tracks, each cut linked to its picture.
        #expect(xml.components(separatedBy: "<sourcetrack>").count == 5)
        #expect(xml.contains("<linkclipref>cut-2-a2</linkclipref><mediatype>audio</mediatype><trackindex>2</trackindex><clipindex>2</clipindex>"))
        let references = TimelineDocument(text: xml)?.references ?? []
        #expect(references.count == 1 && references.first?.path == film.sourcePath && references.first?.reelName == "A001")
    }

    @Test func mixedFrameRatesKeepEachClipsOwnTimecode() {
        // A 29.97 drop-frame clip cut into a 23.976 timeline after a 23.976 clip.
        let mixed = sequence(rate: .fps23_976, [(Self.film, 0, 23), (Self.ntsc, 1800, 1829)])
        #expect(mixed.cuts.map(\.recordFrames) == [24, 24])

        let edl = EditorExport.timeline(mixed, format: .edl)
        #expect(edl.contains("002 B002     B     C        10:01:00;02 10:01:01;02 01:00:01:00 01:00:02:00"))

        let xml = EditorExport.timeline(mixed, format: .premiereXML)
        #expect(isWellFormed(xml))
        // The clip keeps its own rate; its place on the timeline is in timeline frames.
        let packed = xml.filter { !$0.isWhitespace }
        #expect(packed.contains("<rate><timebase>30</timebase><ntsc>TRUE</ntsc></rate><start>24</start><end>48</end><in>1800</in><out>1830</out>"))

        let fcpxml = EditorExport.timeline(mixed, format: .fcpxml)
        #expect(isWellFormed(fcpxml))
        // Source time in the clip's rate (1001/30000), length in the timeline's (1001/24000).
        #expect(fcpxml.contains("start=\"1081800720/30000s\" duration=\"24024/24000s\""))
        #expect(fcpxml.contains("frameDuration=\"1001/30000s\" width=\"1920\" height=\"1080\""))
    }

    @Test func reelNamesAndPathOverrides() {
        var longReel = Self.film
        longReel.reelName = "A001C003_230101_R1AB"
        #expect(EditorExport.edlReel(for: longReel) == "A001C003_230101_R1AB")
        #expect(EditorExport.edlReel(for: longReel, strict: true) == "A001C003")
        var noReel = Self.ntsc
        noReel.reelName = nil
        #expect(EditorExport.edlReel(for: noReel) == "B002_&_C001")
        #expect(EditorExport.edlReel(for: noReel, strict: true) == "B002C001")

        // A package points the timeline at its own copies; an editor elsewhere sees mapped paths.
        let cut = sequence(rate: .fps23_976, [(Self.film, 0, 23)])
        let packaged = EditorExport.timeline(cut, format: .premiereXML, options: TimelineExportOptions(
            mediaPaths: [Self.film.id: "/Volumes/Shuttle/Scene 12/Media/RAID/Day 1/A001_C003.mov"]))
        #expect(packaged.contains("file://localhost/Volumes/Shuttle/Scene%2012/Media/RAID/Day%201/A001_C003.mov"))
        let mapped = EditorExport.timeline(cut, format: .fcpxml, options: TimelineExportOptions(
            pathMappings: [PathMapping(macPrefix: "/Volumes/RAID", editorPrefix: "Z:\\RAID")]))
        #expect(mapped.contains("src=\"file:///Z%3A/RAID/Day%201/A001_C003.mov\""))
    }

    @Test func emptySequenceStillExports() {
        let empty = sequence(rate: .fps24, [])
        for format in SequenceTimelineFormat.allCases {
            let text = EditorExport.timeline(empty, format: format)
            #expect(!text.isEmpty)
            if format != .edl { #expect(isWellFormed(text)) }
        }
    }
}

@Suite struct SequencePackageTests {
    @Test func planCopiesEachOriginalOnceWithItsSidecars() {
        let a = clip("/Volumes/RAID/Day 1/A001_C003.braw", reel: "A001")
        let b = clip("/Users/me/Movies/pickup.mov")
        let gone = clip("/Volumes/Offline/Z009.mov")
        let sequence = CutSequence(name: "Scene 12", frameRate: .fps24)
        let resolved = ResolvedSequence(sequence: sequence, cuts: [(a, 0, 23), (b, 0, 23), (a, 48, 71), (gone, 0, 9)].map {
            (SequenceCut(sequenceID: sequence.id, assetID: $0.0.id, inFrame: $0.1, outFrame: $0.2), $0.0)
        })
        let sizes: [String: Int64] = [a.sourcePath: 5_000, "/Volumes/RAID/Day 1/A001_C003.sidecar": 40, b.sourcePath: 700]
        let plan = SequencePackagePlan(sequence: resolved) { sizes[$0] }
        #expect(plan.items.map(\.relativePath) == ["Media/RAID/Day 1/A001_C003.braw", "Media/This Mac/Users/me/Movies/pickup.mov"])
        #expect(plan.items[0].sidecars.map(\.relativePath) == ["Media/RAID/Day 1/A001_C003.sidecar"])
        #expect(plan.missing.map(\.id) == [gone.id])
        #expect(plan.totalBytes == 5_740)

        let entry = PackageManifest.file(for: plan.items[0], in: resolved, checksum: "abc", verified: true)
        #expect(entry.uses.map(\.recordIn) == ["01:00:00:00", "01:00:02:00"])
        #expect(entry.uses.map(\.sourceIn) == ["00:00:00:00", "00:00:02:00"])
        #expect(entry.uses.map(\.sourceOut) == ["00:00:01:00", "00:00:03:00"])
        #expect(entry.reel == "A001")
    }

    @Test func manifestRoundTripsAndListsChecksums() throws {
        let a = clip("/Volumes/RAID/Day 1/A001_C003.mov")
        let sequence = CutSequence(name: "Scene 12", frameRate: .fps23_976)
        let resolved = ResolvedSequence(sequence: sequence, cuts: [(SequenceCut(sequenceID: sequence.id, assetID: a.id, inFrame: 0, outFrame: 9), a)])
        let plan = SequencePackagePlan(sequence: resolved) { _ in 1234 }
        let manifest = PackageManifest(createdAt: Date(timeIntervalSince1970: 1_800_000_000), sequence: resolved,
                                       checksumAlgorithm: "sha256", timelineFiles: ["Scene 12.fcpxml"],
                                       files: [PackageManifest.file(for: plan.items[0], in: resolved, checksum: "ab12", verified: true)])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(PackageManifest.self, from: manifest.json()) == manifest)
        #expect(manifest.totalBytes == 1234 && manifest.frameRate == "24000/1001")
        #expect(manifest.checksumList == "ab12  Media/RAID/Day 1/A001_C003.mov\n")
    }
}

@Suite struct ViewingLookTests {
    @Test func chosenFromWhatTheFileDeclares() throws {
        #expect(LookConversion.detect(colorSpace: "ITU_R_2020/-/ITU_R_2020/com.apple.rec2020.apple-log") == .appleLog)
        #expect(LookConversion.detect(colorSpace: "-/-/ITU_R_2020/com.apple.apple-wide-gamut.apple-log") == .appleLog2)
        #expect(LookConversion.detect(colorSpace: "bt709") == nil)
        #expect(LookConversion.detect(colorSpace: nil) == nil)

        let catalog = try Catalog.inMemory()
        var asset = clip("/Volumes/RAID/iphone.mov")
        asset.colorSpace = "-/-/ITU_R_2020/com.apple.apple-wide-gamut.apple-log"
        asset = try catalog.save(asset)
        #expect(try catalog.viewingLook(for: asset) == .conversion(.appleLog2))
        // A choice made by hand wins, and can be undone.
        try catalog.setClipLook(.lut(path: "/Looks/Show LUT.cube"), forAsset: asset.id)
        #expect(try catalog.viewingLook(for: asset) == .lut(path: "/Looks/Show LUT.cube"))
        #expect(try catalog.viewingLook(for: asset).displayName == "Show LUT")
        #expect(try catalog.lutPathsInUse() == ["/Looks/Show LUT.cube"])
        try catalog.setClipLook(ViewingLook.none, forAsset: asset.id)
        #expect(try catalog.viewingLook(for: asset) == ViewingLook.none)
        try catalog.setClipLook(nil, forAsset: asset.id)
        #expect(try catalog.viewingLook(for: asset) == .conversion(.appleLog2))
    }

    @Test func appleLogCurveMatchesThePublishedValues() {
        // Mid-grey (18 %) sits at about 0.488 in Apple Log; black at about 0.15.
        #expect(abs(ColorMath.linearToAppleLog(0.18) - 0.4882) < 0.0005)
        #expect(abs(ColorMath.linearToAppleLog(0) - 0.1505) < 0.0005)
        for value in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(abs(ColorMath.linearToAppleLog(ColorMath.appleLogToLinear(value)) - value) < 1e-9)
        }
        // Each row of an RGB-to-RGB matrix sums to one: white stays white.
        for row in ColorMath.matrix(from: ColorMath.appleWideGamut, to: ColorMath.rec709) {
            #expect(abs(row.reduce(0, +) - 1) < 1e-9)
        }
        // The Rec.2020 to Rec.709 matrix is a published one (ITU-R BT.2087).
        let m = ColorMath.matrix(from: ColorMath.rec2020, to: ColorMath.rec709)
        #expect(abs(m[0][0] - 1.6605) < 0.001 && abs(m[0][1] + 0.5876) < 0.001 && abs(m[2][2] - 1.1187) < 0.001)
    }

    @Test func conversionsGiveANormalPicture() {
        for conversion in LookConversion.allCases {
            let lut = ColorLUT(conversion: conversion)
            #expect(lut.size == 33 && lut.values.count == 33 * 33 * 33 * 3)
            #expect(lut.values.allSatisfy { $0 >= 0 && $0 <= 1 })
            let grey = ColorMath.linearToAppleLog(0.18)
            let out = lut.sample(grey, grey, grey)
            // Grey stays grey and lands in the middle of the video range.
            #expect(abs(out.0 - out.1) < 0.002 && abs(out.1 - out.2) < 0.002)
            #expect(out.1 > 0.40 && out.1 < 0.50)
            // Brighter in, brighter out, all the way up: highlights roll off rather than clip early.
            var last = -1.0
            for step in 0...20 {
                let level = lut.sample(Double(step) / 20, Double(step) / 20, Double(step) / 20).1
                #expect(level >= last)
                last = level
            }
            let black = ColorMath.linearToAppleLog(0)
            // Black sits between two steps of the table, so it reads a little above zero.
            #expect(lut.sample(black, black, black).1 < 0.08)
            #expect(lut.sample(1, 1, 1).1 > 0.95)
        }
        // A saturated red in the wide camera gamut is still red, and inside the video range.
        let red = ColorLUT(conversion: .appleLog2).sample(0.6, 0.2, 0.2)
        #expect(red.0 > red.1 && red.0 > red.2 && red.1 >= 0 && red.2 >= 0)
    }

    @Test func readsCubeFiles() throws {
        let text = """
            # A look that swaps red and blue
            TITLE "Swap"
            LUT_3D_SIZE 2
            DOMAIN_MIN 0.0 0.0 0.0
            DOMAIN_MAX 1.0 1.0 1.0

            0 0 0
            0 0 1
            0 1 0
            0 1 1
            1 0 0
            1 0 1
            1 1 0
            1 1 1
            """
        let lut = try ColorLUT(cubeText: text)
        #expect(lut.title == "Swap" && lut.size == 2)
        let out = lut.sample(0.25, 0.5, 1)
        #expect(abs(out.0 - 1) < 1e-6 && abs(out.1 - 0.5) < 1e-6 && abs(out.2 - 0.25) < 1e-6)
        // Written out and read back, it is the same table.
        #expect(try ColorLUT(cubeText: lut.cubeText) == lut)

        // A table over a wider input range is brought to 0...1.
        let wide = try ColorLUT(cubeText: text.replacingOccurrences(of: "DOMAIN_MAX 1.0 1.0 1.0", with: "DOMAIN_MAX 2.0 2.0 2.0"))
        #expect(abs(wide.sample(1, 0, 0).2 - 0.5) < 1e-6)

        #expect(throws: LUTError.notA3DLUT) { try ColorLUT(cubeText: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n") }
        #expect(throws: LUTError.wrongEntryCount(expected: 8, found: 2)) {
            try ColorLUT(cubeText: "LUT_3D_SIZE 2\n0 0 0\n1 1 1\n")
        }
        let identity = ColorLUT.identity()
        let same = identity.sample(0.3, 0.6, 0.9)
        #expect(abs(same.0 - 0.3) < 1e-6 && abs(same.1 - 0.6) < 1e-6 && abs(same.2 - 0.9) < 1e-6)
    }
}
