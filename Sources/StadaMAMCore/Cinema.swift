import Foundation
import GRDB

// Cinema language for everything the A.I. says about a clip, plus the rules a person uses to
// correct it. All of it is deterministic and unit-tested; the Vision / Speech calls live in
// StadaMAMAI.

// MARK: Label rules

/// A correction applied to every picture label: hide it, or call it something else.
public struct LabelRule: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "labelRule"

    public enum Action: String, Codable, Sendable { case hide, rename }

    public var id: String
    /// The label as the recogniser words it, lower case.
    public var match: String
    public var action: Action
    /// The new wording for `.rename`.
    public var replacement: String
    /// Rules the app ships with. People can edit or delete them like any other.
    public var isDefault: Bool

    public init(id: String = newID(), match: String, action: Action, replacement: String = "",
                isDefault: Bool = false) {
        self.id = id
        self.match = match.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.action = action
        self.replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isDefault = isDefault
    }
}

public enum LabelRules {
    /// Generic labels Apple's classifier produces that say nothing a cinematographer or editor
    /// would search for, and the cinema wording for the ones that do mean something.
    public static let defaults: [LabelRule] = {
        let hidden = ["structure", "material", "adult", "people", "machine", "container", "furniture",
                      "wood processed", "textile", "plant", "liquid", "cloth", "fabric", "rock", "blue sky",
                      "conifer", "projectile", "toy", "clothing", "footwear", "accessory", "bag"]
        let renamed: [(String, String)] = [
            ("indoor", "INT."), ("outdoor", "EXT."), ("daytime", "DAY"), ("night", "NIGHT"),
            ("sunset sunrise", "magic hour"), ("sky", "sky"), ("fire", "practical fire"),
            ("smoke", "atmosphere / smoke"), ("fog", "atmosphere / fog"), ("rain", "rain"),
            ("vehicle", "picture vehicle"), ("car", "picture car"), ("crowd", "crowd / background"),
            ("water", "water"), ("monitor", "monitor / playback"), ("screen", "monitor / playback"),
            ("audio", "sound equipment"), ("microphone", "boom / mic in frame"),
        ]
        return hidden.map { LabelRule(match: $0, action: .hide, isDefault: true) }
            + renamed.map { LabelRule(match: $0.0, action: .rename, replacement: $0.1, isDefault: true) }
    }()

    /// Applies the rules to freshly made tags. Hidden labels disappear, renamed ones take the new
    /// wording (and merge when two labels end up with the same name). Only picture labels are touched.
    public static func apply(_ rules: [LabelRule], to tags: [SceneTag]) -> [SceneTag] {
        guard !rules.isEmpty else { return tags }
        let byMatch = Dictionary(rules.map { ($0.match, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [SceneTag] = []
        for var tag in tags {
            guard tag.kind == .label, !tag.userEdited, let rule = byMatch[tag.label.lowercased()] else {
                result.append(tag)
                continue
            }
            switch rule.action {
            case .hide: continue
            case .rename:
                guard !rule.replacement.isEmpty else { continue }
                tag.label = rule.replacement
                result.append(tag)
            }
        }
        return merged(result)
    }

    /// Joins same-label tags that touch or overlap into one.
    static func merged(_ tags: [SceneTag]) -> [SceneTag] {
        var out: [SceneTag] = []
        var open: [String: Int] = [:]   // label -> index in out
        for tag in tags.sorted(by: { ($0.startSeconds, $0.label) < ($1.startSeconds, $1.label) }) {
            guard tag.kind == .label, !tag.userEdited else { out.append(tag); continue }
            if let index = open[tag.label], tag.startSeconds <= out[index].endSeconds + 0.001 {
                out[index].endSeconds = max(out[index].endSeconds, tag.endSeconds)
                out[index].confidence = max(out[index].confidence, tag.confidence)
            } else {
                open[tag.label] = out.count
                out.append(tag)
            }
        }
        return out
    }
}

// MARK: Shot scale and headcount

public enum ShotScale: String, CaseIterable, Sendable {
    case extremeCloseUp = "extreme close-up"
    case closeUp = "close-up"
    case mediumCloseUp = "medium close-up"
    case mediumShot = "medium shot"
    case cowboy = "cowboy / medium wide"
    case wide = "wide shot"
    case extremeWide = "extreme wide / establishing"

    /// Shot size from the largest face in frame, as a fraction of the frame height — the way a
    /// camera operator describes it: a face filling the frame is a close-up, a speck is a wide.
    public static func classify(largestFaceHeight h: Double) -> ShotScale {
        switch h {
        case 0.55...: return .extremeCloseUp
        case 0.32..<0.55: return .closeUp
        case 0.20..<0.32: return .mediumCloseUp
        case 0.11..<0.20: return .mediumShot
        case 0.06..<0.11: return .cowboy
        default: return .wide
        }
    }

    /// With no faces but people in frame, size from the tallest body instead.
    public static func classify(tallestBodyHeight h: Double) -> ShotScale {
        switch h {
        case 0.9...: return .mediumShot
        case 0.55..<0.9: return .cowboy
        case 0.2..<0.55: return .wide
        default: return .extremeWide
        }
    }
}

public enum CinemaVocabulary {
    /// How many people are in frame, as a cinematographer would call the framing.
    public static func framing(headcount: Int) -> String? {
        switch headcount {
        case ...0: return nil
        case 1: return "single"
        case 2: return "two-shot"
        case 3: return "three-shot"
        case 4...6: return "group shot"
        default: return "crowd / background"
        }
    }

    /// Words the speech recogniser should expect on a film set, so slates and calls are heard right.
    public static let setVocabulary: [String] = [
        "slate", "scene", "take", "sticks", "mark", "speed", "rolling", "camera rolling", "sound rolling",
        "action", "cut", "back to one", "going again", "reset", "check the gate", "last looks",
        "pick-up", "pickup", "insert", "close-up", "wide", "master", "coverage", "second unit",
        "wild track", "room tone", "ADR", "foley", "boom", "lav", "first AC", "second AC",
        "DIT", "DP", "gaffer", "grip", "script supervisor", "continuity", "hot set",
    ]
}

// MARK: Slates

/// Pulls scene / take / roll out of a slate — spoken ("scene twelve A, take three") or read
/// from the board by text recognition ("SC 12A TK 3").
public enum SlateParser {
    private static let spoken: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Turns "twenty three" into "23" and leaves digits alone.
    static func normalise(_ text: String) -> String {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var out: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if let tens = spoken[word], tens >= 20, index + 1 < words.count,
               let ones = spoken[words[index + 1]], ones < 10 {
                out.append(String(tens + ones))
                index += 2
            } else if let value = spoken[word] {
                out.append(String(value))
                index += 1
            } else {
                out.append(word)
                index += 1
            }
        }
        return out.joined(separator: " ")
    }

    public struct Slate: Equatable, Sendable {
        public var scene: String?
        public var take: String?
        public var roll: String?

        public var label: String {
            [scene.map { "Scene \($0)" }, take.map { "Take \($0)" }, roll.map { "Roll \($0)" }]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }

    public static func parse(_ text: String) -> Slate? {
        let t = normalise(text)
        func grab(_ keys: String, valuePattern: String) -> String? {
            let pattern = "\\b(?:\(keys))\\s*(?:number|no|#)?\\s*(\(valuePattern))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let range = Range(match.range(at: 1), in: t) else { return nil }
            return String(t[range]).replacingOccurrences(of: " ", with: "").uppercased()
        }
        // "scene 12 a" and "scene 12A" both mean 12A; NATO-style letters are rare on a slate.
        let scene = grab("scene|sc|slate", valuePattern: "\\d{1,3}\\s?[a-z]?")
        let take = grab("take|tk", valuePattern: "\\d{1,3}")
        let roll = grab("roll|mag|reel", valuePattern: "[a-z]?\\d{1,3}[a-z]?")
        guard scene != nil || take != nil else { return nil }
        // A lone "take" in ordinary speech ("take it easy") has no number, so it never matches.
        return Slate(scene: scene, take: take, roll: roll)
    }

    /// Slate tags from the transcript and from text read off the picture.
    public static func tags(assetID: String, transcript: [TranscriptSegment], onScreenText: [SceneTag]) -> [SceneTag] {
        var tags: [SceneTag] = []
        var seen = Set<String>()
        for segment in transcript {
            guard let slate = parse(segment.text), seen.insert(slate.label).inserted else { continue }
            tags.append(SceneTag(assetID: assetID, kind: .slate, label: slate.label, confidence: 0.8,
                                 startSeconds: segment.startSeconds, endSeconds: segment.endSeconds))
        }
        for text in onScreenText where text.kind == .text {
            guard let slate = parse(text.label), slate.scene != nil, seen.insert(slate.label).inserted else { continue }
            tags.append(SceneTag(assetID: assetID, kind: .slate, label: slate.label, confidence: 0.9,
                                 startSeconds: text.startSeconds, endSeconds: text.endSeconds))
        }
        return tags
    }
}

// MARK: Audio chunking for speech recognition

/// Plans how to cut a long recording into pieces a speech recogniser handles reliably. Cuts
/// land in the quietest moment near the target length, so no word is split in half.
public enum SpeechChunker {
    public struct Chunk: Equatable, Sendable {
        public var start: Double
        public var end: Double
        /// Mean level of the chunk, 0...1; very low means silence or room tone.
        public var level: Double
    }

    /// - Parameters:
    ///   - levels: Loudness (RMS, 0...1) of consecutive windows `window` seconds long.
    ///   - target: Preferred chunk length in seconds.
    ///   - search: How far before the target length to look for a quiet place to cut.
    public static func plan(levels: [Double], window: Double, target: Double = 45, search: Double = 8) -> [Chunk] {
        guard !levels.isEmpty, window > 0 else { return [] }
        let total = Double(levels.count) * window
        var chunks: [Chunk] = []
        var start = 0.0
        while start < total - 0.001 {
            var end = min(start + target, total)
            if end < total {
                let lo = max(Int(((end - search) / window).rounded()), Int((start / window).rounded()) + 1)
                let hi = min(Int((end / window).rounded()), levels.count - 1)
                if lo < hi, let quietest = (lo...hi).min(by: { levels[$0] < levels[$1] }) {
                    end = Double(quietest) * window + window / 2
                }
            }
            end = min(max(end, start + window), total)
            let from = Int((start / window).rounded(.down)), to = max(Int((end / window).rounded(.up)), from + 1)
            let slice = levels[from..<min(to, levels.count)]
            chunks.append(Chunk(start: start, end: end, level: slice.reduce(0, +) / Double(max(slice.count, 1))))
            start = end
        }
        return chunks
    }

    /// Below this a chunk is silence or room tone. Recognisers invent words ("thank you") for such audio.
    public static let silenceLevel = 0.004
}
