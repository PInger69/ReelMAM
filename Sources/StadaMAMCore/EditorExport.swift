import Foundation

/// The editing applications clips can be handed to.
public enum EditorTarget: String, CaseIterable, Sendable {
    case finalCutPro
    case davinciResolve
    case premierePro

    public var displayName: String {
        switch self {
        case .finalCutPro: return "Final Cut Pro"
        case .davinciResolve: return "DaVinci Resolve"
        case .premierePro: return "Premiere Pro"
        }
    }

    /// Final Cut Pro and Resolve read FCPXML; Premiere Pro reads Final Cut Pro 7 XML.
    public var fileExtension: String { self == .premierePro ? "xml" : "fcpxml" }
}

/// Which files the editor should be pointed at.
public enum EditorMedia: String, CaseIterable, Sendable {
    /// The camera originals. Where the format allows (Final Cut Pro), each clip also carries
    /// its proxy, so the editor imports the two already linked.
    case sources
    /// The proxies only, for an editor who has no access to the originals. The finished edit
    /// is brought back through source recall.
    case proxies
}

/// One clip to hand over, with everything logged against it.
public struct EditorClip: Sendable {
    public var asset: Asset
    /// Path of a verified proxy, when there is one.
    public var proxyPath: String?
    public var markers: [Marker]

    public init(asset: Asset, proxyPath: String? = nil, markers: [Marker] = []) {
        self.asset = asset
        self.proxyPath = proxyPath
        self.markers = markers
    }
}

/// Writes clip lists the editing applications import: the clips arrive in a bin / event with
/// their timecode, reel name, markers and subclips, pointing at the right media.
public enum EditorExport {
    public static func document(for clips: [EditorClip], target: EditorTarget, media: EditorMedia,
                                collectionName: String = "StadaXR A.I. MAM") -> String {
        // In proxy mode only clips that actually have a proxy can be sent.
        let usable = media == .proxies ? clips.filter { $0.proxyPath != nil } : clips
        switch target {
        case .finalCutPro, .davinciResolve:
            return fcpxml(usable, media: media, collectionName: collectionName)
        case .premierePro:
            return xmeml(usable, media: media, collectionName: collectionName)
        }
    }

    // MARK: Shared helpers

    static func fileURL(_ path: String, localhost: Bool) -> String {
        let encoded = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return (localhost ? "file://localhost" : "file://") + encoded
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func baseName(_ asset: Asset) -> String {
        (asset.fileName as NSString).deletingPathExtension
    }

    // MARK: FCPXML (Final Cut Pro, DaVinci Resolve)

    /// A frame count as an FCPXML rational time, exact at any frame rate.
    static func time(_ frames: Int, _ rate: FrameRate) -> String {
        "\(frames * rate.denominator)/\(rate.numerator)s"
    }

    /// Final Cut's own name for a standard raster and rate, when it has one.
    static func formatName(_ asset: Asset) -> String? {
        let rates: [(FrameRate, String)] = [(.fps23_976, "2398"), (.fps24, "24"), (.fps25, "25"), (.fps29_97, "2997"),
                                            (.fps30, "30"), (.fps50, "50"), (.fps59_94, "5994"), (.fps60, "60")]
        guard let rate = rates.first(where: { $0.0 == asset.frameRate })?.1 else { return nil }
        switch (asset.width, asset.height) {
        case (1280, 720): return "FFVideoFormat720p\(rate)"
        case (1920, 1080): return "FFVideoFormat1080p\(rate)"
        case (3840, 2160): return "FFVideoFormat3840x2160p\(rate)"
        case (4096, 2160): return "FFVideoFormat4096x2160p\(rate)"
        default: return nil
        }
    }

    private static func fcpxml(_ clips: [EditorClip], media: EditorMedia, collectionName: String) -> String {
        var resources: [String] = []
        var eventItems: [String] = []
        var formatIDs: [String: String] = [:]
        var nextID = 1
        func newID() -> String {
            defer { nextID += 1 }
            return "r\(nextID)"
        }

        for clip in clips {
            let asset = clip.asset
            let formatKey = "\(asset.width)x\(asset.height)@\(asset.frameRateNum)/\(asset.frameRateDen)"
            let formatID: String
            if let existing = formatIDs[formatKey] {
                formatID = existing
            } else {
                formatID = newID()
                formatIDs[formatKey] = formatID
                let name = formatName(asset).map { " name=\"\($0)\"" } ?? ""
                resources.append("""
                        <format id="\(formatID)"\(name) frameDuration="\(time(1, asset.frameRate))" width="\(asset.width)" height="\(asset.height)"/>
                    """)
            }
            let assetID = newID()
            let name = escape(baseName(asset))
            let start = time(asset.startTimecodeFrames, asset.frameRate)
            let duration = time(asset.durationFrames, asset.frameRate)
            let audio = asset.audioChannels > 0
                ? " hasAudio=\"1\" audioSources=\"1\" audioChannels=\"\(asset.audioChannels)\"" : ""
            var reps: [String] = []
            switch media {
            case .sources:
                reps.append("<media-rep kind=\"original-media\" src=\"\(escape(fileURL(asset.sourcePath, localhost: false)))\"/>")
                if let proxy = clip.proxyPath {
                    reps.append("<media-rep kind=\"proxy-media\" src=\"\(escape(fileURL(proxy, localhost: false)))\"/>")
                }
            case .proxies:
                reps.append("<media-rep kind=\"original-media\" src=\"\(escape(fileURL(clip.proxyPath ?? asset.sourcePath, localhost: false)))\"/>")
            }
            resources.append("""
                    <asset id="\(assetID)" name="\(name)" start="\(start)" duration="\(duration)" hasVideo="1" format="\(formatID)"\(audio)>
                        \(reps.joined(separator: "\n            "))
                    </asset>
                """)

            var notes: [String] = []
            for marker in clip.markers {
                let at = time(asset.startTimecodeFrames + marker.inFrame, asset.frameRate)
                let label = escape(marker.name.isEmpty ? "Marker" : marker.name)
                if let out = marker.outFrame {
                    // A marked range travels as a keyword range, which Final Cut shows as a subclip.
                    let length = time(max(out - marker.inFrame + 1, 1), asset.frameRate)
                    notes.append("<keyword start=\"\(at)\" duration=\"\(length)\" value=\"\(label)\"/>")
                } else {
                    let note = marker.note.isEmpty ? "" : " note=\"\(escape(marker.note))\""
                    notes.append("<marker start=\"\(at)\" duration=\"\(time(1, asset.frameRate))\" value=\"\(label)\"\(note)/>")
                }
            }
            let tcFormat = asset.dropFrame ? "DF" : "NDF"
            let open = "<asset-clip ref=\"\(assetID)\" name=\"\(name)\" start=\"\(start)\" duration=\"\(duration)\" format=\"\(formatID)\" tcFormat=\"\(tcFormat)\""
            eventItems.append(notes.isEmpty
                ? "            \(open)/>"
                : "            \(open)>\n                \(notes.joined(separator: "\n                "))\n            </asset-clip>")
        }

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.9">
                <resources>
            \(resources.joined(separator: "\n"))
                </resources>
                <library>
                    <event name="\(escape(collectionName))">
            \(eventItems.joined(separator: "\n"))
                    </event>
                </library>
            </fcpxml>

            """
    }

    // MARK: Final Cut Pro 7 XML (Premiere Pro)

    private static func rateXML(_ rate: FrameRate) -> String {
        "<rate><timebase>\(rate.nominal)</timebase><ntsc>\(rate.denominator == 1001 ? "TRUE" : "FALSE")</ntsc></rate>"
    }

    private static func xmeml(_ clips: [EditorClip], media: EditorMedia, collectionName: String) -> String {
        var items: [String] = []
        for (index, clip) in clips.enumerated() {
            let asset = clip.asset
            let path = media == .proxies ? (clip.proxyPath ?? asset.sourcePath) : asset.sourcePath
            let fileID = "file-\(index + 1)"
            let rate = rateXML(asset.frameRate)
            let reel = asset.reelName.map { "<reel><name>\(escape($0))</name></reel>" } ?? ""
            let audio = asset.audioChannels > 0
                ? "<audio><channelcount>\(asset.audioChannels)</channelcount></audio>" : ""
            let file = """
                <file id="\(fileID)">
                                        <name>\(escape((path as NSString).lastPathComponent))</name>
                                        <pathurl>\(escape(fileURL(path, localhost: true)))</pathurl>
                                        \(rate)
                                        <duration>\(asset.durationFrames)</duration>
                                        <timecode>\(rate)<string>\(asset.startTimecode)</string><frame>\(asset.startTimecodeFrames)</frame><displayformat>\(asset.dropFrame ? "DF" : "NDF")</displayformat>\(reel)</timecode>
                                        <media><video><samplecharacteristics><width>\(asset.width)</width><height>\(asset.height)</height></samplecharacteristics></video>\(audio)</media>
                                    </file>
                """
            func clipXML(id: String, name: String, inFrame: Int?, outFrame: Int?, fileXML: String, markers: [Marker]) -> String {
                let range = inFrame.map { "<in>\($0)</in><out>\(outFrame ?? asset.durationFrames)</out>" } ?? ""
                let markerXML = markers.map { marker in
                    "<marker><name>\(escape(marker.name))</name><comment>\(escape(marker.note))</comment><in>\(marker.inFrame)</in><out>-1</out></marker>"
                }.joined(separator: "\n                    ")
                return """
                            <clip id="\(id)">
                                <name>\(escape(name))</name>
                                <duration>\(asset.durationFrames)</duration>
                                \(rate)
                                \(range)
                                <media><video><track><clipitem id="\(id)-item">
                                    <name>\(escape(name))</name>
                                    \(fileXML)
                                </clipitem></track></video></media>
                                \(markerXML)
                            </clip>
                    """
            }
            let points = clip.markers.filter { !$0.isSubclip }
            items.append(clipXML(id: "clip-\(index + 1)", name: baseName(asset), inFrame: nil, outFrame: nil,
                                 fileXML: file, markers: points))
            // Each marked range becomes its own subclip of the same file (out point is exclusive).
            for (subIndex, sub) in clip.markers.filter(\.isSubclip).enumerated() {
                let name = sub.name.isEmpty ? "\(baseName(asset)) Subclip \(subIndex + 1)" : sub.name
                items.append(clipXML(id: "clip-\(index + 1)-sub-\(subIndex + 1)", name: name, inFrame: sub.inFrame,
                                     outFrame: (sub.outFrame ?? sub.inFrame) + 1, fileXML: "<file id=\"\(fileID)\"/>",
                                     markers: []))
            }
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE xmeml>
            <xmeml version="4">
                <bin>
                    <name>\(escape(collectionName))</name>
                    <children>
            \(items.joined(separator: "\n"))
                    </children>
                </bin>
            </xmeml>

            """
    }
}
