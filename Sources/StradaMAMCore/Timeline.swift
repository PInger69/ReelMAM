import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A media file referenced by an exported timeline (Premiere XML, Resolve FCPXML, or an EDL).
public struct TimelineMediaReference: Hashable, Sendable {
    public var name: String?
    /// The URL string exactly as written in the file, used for rewriting.
    public var rawURL: String?
    public var path: String?
    public var reelName: String?

    public var clue: MediaClue {
        MediaClue(path: path, fileName: path == nil ? name : nil, reelName: reelName)
    }
}

public enum TimelineFormat: String, Sendable {
    /// Final Cut Pro 7 XML — what Premiere Pro exports and Resolve can import/export.
    case xmeml
    /// FCPXML — exported by DaVinci Resolve and Final Cut Pro.
    case fcpxml
    /// CMX 3600 EDL.
    case edl
}

/// Reads the media a timeline points at, so an edit cut on proxies can be traced to sources.
public struct TimelineDocument: Sendable {
    public var format: TimelineFormat
    public var text: String
    public var references: [TimelineMediaReference]

    public init?(text: String) {
        self.text = text
        let head = text.prefix(2000)
        if head.contains("<xmeml") {
            format = .xmeml
        } else if head.contains("<fcpxml") {
            format = .fcpxml
        } else if text.contains("TITLE:") || EDLParser.looksLikeEDL(text) {
            format = .edl
        } else {
            return nil
        }
        switch format {
        case .edl:
            references = EDLParser.references(in: text)
        case .xmeml, .fcpxml:
            let collector = XMLReferenceCollector()
            let parser = XMLParser(data: Data(text.utf8))
            parser.delegate = collector
            _ = parser.parse()
            references = collector.references
        }
        var seen = Set<TimelineMediaReference>()
        references = references.filter { seen.insert($0).inserted }
    }

    /// Returns the timeline with every resolved proxy URL swapped for its source file URL.
    /// EDLs carry no paths, so they are returned unchanged.
    public func relinked(using resolve: (TimelineMediaReference) -> Asset?) -> String {
        guard format != .edl else { return text }
        var output = text
        for reference in references {
            guard let raw = reference.rawURL, let asset = resolve(reference) else { continue }
            let prefix = raw.hasPrefix("file://localhost/") ? "file://localhost" : "file://"
            let encoded = asset.sourcePath.split(separator: "/", omittingEmptySubsequences: false)
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                .joined(separator: "/")
            output = output.replacingOccurrences(of: raw.xmlEscaped, with: (prefix + encoded).xmlEscaped)
        }
        return output
    }

    static func path(fromURLString string: String) -> String? {
        guard string.hasPrefix("file:") else { return string.hasPrefix("/") ? string : nil }
        var rest = String(string.dropFirst("file:".count))
        if rest.hasPrefix("//") {
            rest.removeFirst(2)
            // Drop the authority ("localhost" or empty).
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            rest = String(rest[slash...])
        }
        return rest.removingPercentEncoding ?? rest
    }
}

private final class XMLReferenceCollector: NSObject, XMLParserDelegate {
    var references: [TimelineMediaReference] = []
    private var stack: [String] = []
    private var text = ""
    private var current: TimelineMediaReference?
    private var currentDepth = 0

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append(name)
        text = ""
        switch name {
        case "file" where current == nil:  // xmeml
            current = TimelineMediaReference()
            currentDepth = stack.count
        case "asset" where current == nil:  // fcpxml
            current = TimelineMediaReference(name: attributes["name"])
            currentDepth = stack.count
            if let src = attributes["src"] { setURL(src) }
        case "media-rep" where current != nil:
            if let src = attributes["src"], attributes["kind"] != "proxy-media" { setURL(src) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if current != nil {
            // Only direct children of <file> describe the file itself.
            if stack.count == currentDepth + 1 {
                if name == "name" { current?.name = value }
                if name == "pathurl" { setURL(value) }
            }
            if name == "reel" || (name == "name" && stack.dropLast().last == "reel"), !value.isEmpty {
                current?.reelName = value
            }
            if stack.count == currentDepth {
                if let reference = current, reference.name != nil || reference.path != nil {
                    references.append(reference)
                }
                current = nil
            }
        }
        stack.removeLast()
        text = ""
    }

    private func setURL(_ string: String) {
        current?.rawURL = string
        current?.path = TimelineDocument.path(fromURLString: string)
    }
}

enum EDLParser {
    private static func isTimecode(_ token: Substring) -> Bool {
        token.count == 11 && token.filter({ $0 == ":" || $0 == ";" }).count == 3
    }

    private static func eventReel(_ line: Substring) -> String? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 8, Int(tokens[0]) != nil, tokens.suffix(4).allSatisfy(isTimecode) else { return nil }
        return String(tokens[1])
    }

    static func looksLikeEDL(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).prefix(50).contains { eventReel($0) != nil }
    }

    static func references(in text: String) -> [TimelineMediaReference] {
        var references: [TimelineMediaReference] = []
        var openEvent = false
        for line in text.split(whereSeparator: \.isNewline) {
            if let reel = eventReel(line) {
                // AX / BL are auxiliary and black placeholders, not real reels.
                let isReal = !["AX", "BL", "GEN"].contains(reel.uppercased())
                references.append(TimelineMediaReference(reelName: isReal ? reel : nil))
                openEvent = true
                continue
            }
            guard openEvent, line.hasPrefix("*") else { continue }
            for marker in ["FROM CLIP NAME:", "SOURCE FILE:"] {
                guard let range = line.range(of: marker) else { continue }
                let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { references[references.count - 1].name = value }
            }
        }
        return references.filter { $0.name != nil || $0.reelName != nil }
    }
}

extension String {
    fileprivate var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
    }
}
