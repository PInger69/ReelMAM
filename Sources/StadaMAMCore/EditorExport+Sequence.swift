import Foundation

/// The timeline files a sequence can be written as.
public enum SequenceTimelineFormat: String, CaseIterable, Sendable {
    /// FCPXML: Final Cut Pro and DaVinci Resolve.
    case fcpxml
    /// Final Cut Pro 7 XML: Premiere Pro (Resolve reads it too).
    case premiereXML
    /// CMX 3600 edit decision list: read by every editing and finishing tool.
    case edl

    public var displayName: String {
        switch self {
        case .fcpxml: return "FCPXML (Final Cut Pro, DaVinci Resolve)"
        case .premiereXML: return "XML (Premiere Pro)"
        case .edl: return "EDL (CMX 3600)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .fcpxml: return "fcpxml"
        case .premiereXML: return "xml"
        case .edl: return "edl"
        }
    }
}

public struct TimelineExportOptions: Sendable {
    /// Where the editor's computer sees this Mac's storage, when it is another machine.
    public var pathMappings: [PathMapping]
    /// Media paths to write instead of the catalogued originals, by asset ID. A package export
    /// uses this to point the timeline at the copies it made.
    public var mediaPaths: [String: String]
    /// Cut EDL reel names to the eight capital letters and digits of strict CMX 3600. Off by
    /// default: long camera reel names are what relinking matches on, and current tools read them.
    public var strictEDLReels: Bool

    public init(pathMappings: [PathMapping] = [], mediaPaths: [String: String] = [:], strictEDLReels: Bool = false) {
        self.pathMappings = pathMappings
        self.mediaPaths = mediaPaths
        self.strictEDLReels = strictEDLReels
    }
}

extension EditorExport {
    /// Writes a sequence as a real timeline: every cut in order with its source in and out, so the
    /// editing app opens the same cut, linked to the camera originals by file path, reel name and
    /// source timecode.
    public static func timeline(_ sequence: ResolvedSequence, format: SequenceTimelineFormat,
                                options: TimelineExportOptions = TimelineExportOptions()) -> String {
        var sequence = sequence
        sequence.cuts = sequence.cuts.map { placed in
            var placed = placed
            let path = options.mediaPaths[placed.asset.id] ?? placed.asset.sourcePath
            placed.asset.sourcePath = PathMapping.toEditor(path, using: options.pathMappings)
            return placed
        }
        switch format {
        case .fcpxml: return fcpxmlTimeline(sequence)
        case .premiereXML: return xmemlTimeline(sequence)
        case .edl: return edlTimeline(sequence, strictReels: options.strictEDLReels)
        }
    }

    /// The reel an EDL event names: the clip's reel, or its file name without extension when the
    /// camera wrote none.
    public static func edlReel(for asset: Asset, strict: Bool = false) -> String {
        let raw = asset.reelName.flatMap { $0.isEmpty ? nil : $0 } ?? baseName(asset)
        let joined = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: "_")
        guard strict else { return joined.isEmpty ? "AX" : joined }
        let plain = String(joined.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        return plain.isEmpty ? "AX" : plain
    }

    // MARK: FCPXML

    private static func fcpxmlTimeline(_ sequence: ResolvedSequence) -> String {
        var resources: [String] = []
        var formatIDs: [String: String] = [:]
        var assetIDs: [String: String] = [:]
        var nextID = 1
        func newID() -> String {
            defer { nextID += 1 }
            return "r\(nextID)"
        }
        func formatID(width: Int, height: Int, rate: FrameRate, name: String?) -> String {
            let key = "\(width)x\(height)@\(rate.numerator)/\(rate.denominator)"
            if let existing = formatIDs[key] { return existing }
            let id = newID()
            formatIDs[key] = id
            let nameAttribute = name.map { " name=\"\($0)\"" } ?? ""
            resources.append("""
                        <format id="\(id)"\(nameAttribute) frameDuration="\(time(1, rate))" width="\(width)" height="\(height)"/>
                """)
            return id
        }

        // The timeline takes its raster from the first clip and its rate from the sequence.
        var shape = sequence.cuts.first?.asset ?? Asset(sourcePath: "/", width: 1920, height: 1080)
        if shape.width == 0 || shape.height == 0 { (shape.width, shape.height) = (1920, 1080) }
        shape.frameRateNum = sequence.frameRate.numerator
        shape.frameRateDen = sequence.frameRate.denominator
        let sequenceFormat = formatID(width: shape.width, height: shape.height, rate: sequence.frameRate,
                                      name: formatName(shape))

        let start = sequence.startTimecode.frames
        var spine: [String] = []
        for placed in sequence.cuts {
            let asset = placed.asset
            let clipFormat = formatID(width: asset.width, height: asset.height, rate: asset.frameRate,
                                      name: formatName(asset))
            let name = escape(baseName(asset))
            let assetID: String
            if let existing = assetIDs[asset.id] {
                assetID = existing
            } else {
                assetID = newID()
                assetIDs[asset.id] = assetID
                let audio = asset.audioChannels > 0
                    ? " hasAudio=\"1\" audioSources=\"1\" audioChannels=\"\(asset.audioChannels)\"" : ""
                resources.append("""
                            <asset id="\(assetID)" name="\(name)" start="\(time(asset.startTimecodeFrames, asset.frameRate))" duration="\(time(asset.durationFrames, asset.frameRate))" hasVideo="1" format="\(clipFormat)"\(audio)>
                                <media-rep kind="original-media" src="\(escape(fileURL(asset.sourcePath, localhost: false)))"/>
                            </asset>
                    """)
            }
            // `offset` is where the cut sits on the timeline, `start` where it begins in the source.
            let note = placed.cut.note.isEmpty ? "" : "\n                        <note>\(escape(placed.cut.note))</note>\n                    "
            let open = "<asset-clip ref=\"\(assetID)\" name=\"\(name)\" offset=\"\(time(start + placed.recordStart, sequence.frameRate))\" start=\"\(time(asset.startTimecodeFrames + placed.cut.inFrame, asset.frameRate))\" duration=\"\(time(placed.recordFrames, sequence.frameRate))\" format=\"\(clipFormat)\" tcFormat=\"\(asset.dropFrame ? "DF" : "NDF")\""
            spine.append("                    " + (note.isEmpty ? "\(open)/>" : "\(open)>\(note)</asset-clip>"))
        }

        let title = escape(sequence.sequence.name)
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.9">
                <resources>
            \(resources.joined(separator: "\n"))
                </resources>
                <library>
                    <event name="\(title)">
                        <project name="\(title)">
                            <sequence format="\(sequenceFormat)" duration="\(time(sequence.totalFrames, sequence.frameRate))" tcStart="\(time(start, sequence.frameRate))" tcFormat="\(sequence.dropFrame ? "DF" : "NDF")" audioLayout="stereo" audioRate="48k">
                                <spine>
            \(spine.joined(separator: "\n"))
                                </spine>
                            </sequence>
                        </project>
                    </event>
                </library>
            </fcpxml>

            """
    }

    // MARK: Final Cut Pro 7 XML (Premiere Pro)

    private static func xmemlTimeline(_ sequence: ResolvedSequence) -> String {
        let rate = rateXML(sequence.frameRate)
        var fileIDs: [String: String] = [:]
        /// The full description of a file the first time it is used, a reference after that.
        func fileXML(_ asset: Asset) -> String {
            if let id = fileIDs[asset.id] { return "<file id=\"\(id)\"/>" }
            let id = "file-\(fileIDs.count + 1)"
            fileIDs[asset.id] = id
            let clipRate = rateXML(asset.frameRate)
            let reel = asset.reelName.map { "<reel><name>\(escape($0))</name></reel>" } ?? ""
            let audio = asset.audioChannels > 0
                ? "<audio><channelcount>\(asset.audioChannels)</channelcount></audio>" : ""
            return """
                <file id="\(id)">
                                            <name>\(escape((asset.sourcePath as NSString).lastPathComponent))</name>
                                            <pathurl>\(escape(fileURL(asset.sourcePath, localhost: true)))</pathurl>
                                            \(clipRate)
                                            <duration>\(asset.durationFrames)</duration>
                                            <timecode>\(clipRate)<string>\(asset.startTimecode)</string><frame>\(asset.startTimecodeFrames)</frame><displayformat>\(asset.dropFrame ? "DF" : "NDF")</displayformat>\(reel)</timecode>
                                            <media><video><samplecharacteristics><width>\(asset.width)</width><height>\(asset.height)</height></samplecharacteristics></video>\(audio)</media>
                                        </file>
                """
        }

        // One audio track per channel; a cut appears on as many as its clip has channels.
        let audioTrackCount = sequence.cuts.map(\.asset.audioChannels).max() ?? 0
        var audioIndex = [[Int?]](repeating: [], count: audioTrackCount)
        for track in 0..<audioTrackCount {
            var count = 0
            audioIndex[track] = sequence.cuts.map { placed in
                guard placed.asset.audioChannels > track else { return nil }
                count += 1
                return count
            }
        }
        /// Ties a cut's picture and sound together so they move as one in the editing app.
        func links(_ cutIndex: Int, _ placed: PlacedCut) -> String {
            var lines = ["<link><linkclipref>cut-\(cutIndex + 1)-v</linkclipref><mediatype>video</mediatype><trackindex>1</trackindex><clipindex>\(cutIndex + 1)</clipindex></link>"]
            for track in 0..<min(placed.asset.audioChannels, audioTrackCount) {
                lines.append("<link><linkclipref>cut-\(cutIndex + 1)-a\(track + 1)</linkclipref><mediatype>audio</mediatype><trackindex>\(track + 1)</trackindex><clipindex>\(audioIndex[track][cutIndex] ?? 1)</clipindex></link>")
            }
            return lines.count > 1 ? lines.joined(separator: "\n                            ") : ""
        }
        func clipItem(_ cutIndex: Int, _ placed: PlacedCut, id: String, extra: String) -> String {
            let asset = placed.asset
            let comment = placed.cut.note.isEmpty ? "" : "<comments><mastercomment1>\(escape(placed.cut.note))</mastercomment1></comments>"
            return """
                                <clipitem id="\(id)">
                                    <name>\(escape(baseName(asset)))</name>
                                    <duration>\(asset.durationFrames)</duration>
                                    \(rateXML(asset.frameRate))
                                    <start>\(placed.recordStart)</start><end>\(placed.recordEnd)</end>
                                    <in>\(placed.cut.inFrame)</in><out>\(placed.cut.outFrame + 1)</out>
                                    \(fileXML(asset))
                                    \(extra)
                                    \(links(cutIndex, placed))
                                    \(comment)
                                </clipitem>
                """
        }

        let video = sequence.cuts.enumerated().map { index, placed in
            clipItem(index, placed, id: "cut-\(index + 1)-v", extra: "")
        }
        let audioTracks = (0..<audioTrackCount).map { track in
            let items = sequence.cuts.enumerated().compactMap { index, placed -> String? in
                guard placed.asset.audioChannels > track else { return nil }
                return clipItem(index, placed, id: "cut-\(index + 1)-a\(track + 1)",
                                extra: "<sourcetrack><mediatype>audio</mediatype><trackindex>\(track + 1)</trackindex></sourcetrack>")
            }
            return "                    <track>\n\(items.joined(separator: "\n"))\n                    </track>"
        }

        let shape = sequence.cuts.first?.asset
        let width = (shape?.width ?? 0) > 0 ? shape!.width : 1920, height = (shape?.height ?? 0) > 0 ? shape!.height : 1080
        let start = sequence.startTimecode
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE xmeml>
            <xmeml version="4">
                <sequence id="sequence-1">
                    <name>\(escape(sequence.sequence.name))</name>
                    <duration>\(sequence.totalFrames)</duration>
                    \(rate)
                    <timecode>\(rate)<string>\(start)</string><frame>\(start.frames)</frame><displayformat>\(sequence.dropFrame ? "DF" : "NDF")</displayformat></timecode>
                    <media>
                        <video>
                            <format><samplecharacteristics>\(rate)<width>\(width)</width><height>\(height)</height><pixelaspectratio>square</pixelaspectratio></samplecharacteristics></format>
                            <track>
            \(video.joined(separator: "\n"))
                            </track>
                        </video>
                        <audio>
            \(audioTracks.joined(separator: "\n"))
                        </audio>
                    </media>
                </sequence>
            </xmeml>

            """
    }

    // MARK: CMX 3600 EDL

    private static func edlTimeline(_ sequence: ResolvedSequence, strictReels: Bool) -> String {
        // An EDL title is one line of plain capitals in the strict format; tools accept mixed case.
        let title = sequence.sequence.name.split(whereSeparator: \.isNewline).joined(separator: " ")
        var lines = ["TITLE: \(title)", "FCM: \(sequence.dropFrame ? "DROP FRAME" : "NON-DROP FRAME")", ""]
        for (index, placed) in sequence.cuts.enumerated() {
            let asset = placed.asset
            let reel = edlReel(for: asset, strict: strictReels)
            // V = picture only, B = picture and one audio channel, AA/V = picture and two.
            let track = asset.audioChannels >= 2 ? "AA/V" : asset.audioChannels == 1 ? "B" : "V"
            let number = String(format: "%03d", index + 1)
            let event = [number, reel.padding(toLength: max(reel.count, 8), withPad: " ", startingAt: 0),
                         track.padding(toLength: 5, withPad: " ", startingAt: 0), "C       ",
                         placed.sourceIn.description, placed.sourceOutExclusive.description,
                         sequence.recordTimecode(atFrame: placed.recordStart).description,
                         sequence.recordTimecode(atFrame: placed.recordEnd).description]
            lines.append(event.joined(separator: " "))
            // The clip name comes last: source recall reads the last of these two as the name.
            lines.append("* SOURCE FILE: \(asset.sourcePath)")
            lines.append("* FROM CLIP NAME: \(asset.fileName)")
            if !placed.cut.note.isEmpty {
                lines.append("* COMMENT: \(placed.cut.note.split(whereSeparator: \.isNewline).joined(separator: " "))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
