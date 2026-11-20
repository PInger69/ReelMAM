import Foundation
import GRDB

/// A named cut: an ordered list of pieces of clips. Cuts only: no transitions, no effects, no
/// audio mixing. The finished cut is handed to a full editing app (see `EditorExport.timeline`).
public struct CutSequence: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sequence"
    public var id: String
    public var name: String
    /// The timeline's frame rate. Nil until the first cut is added, which sets it from that clip.
    public var frameRateNum: Int?
    public var frameRateDen: Int?
    public var dropFrame: Bool
    /// Where the timeline's timecode starts, written non-drop ("01:00:00:00").
    public var startTimecode: String
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: String = newID(), name: String, frameRate: FrameRate? = nil, dropFrame: Bool = false,
                startTimecode: String = "01:00:00:00", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.frameRateNum = frameRate?.numerator
        self.frameRateDen = frameRate?.denominator
        self.dropFrame = dropFrame
        self.startTimecode = startTimecode
        self.createdAt = createdAt
        self.modifiedAt = createdAt
    }

    public var frameRate: FrameRate? {
        get {
            guard let frameRateNum, let frameRateDen else { return nil }
            return FrameRate(frameRateNum, frameRateDen)
        }
        set {
            frameRateNum = newValue?.numerator
            frameRateDen = newValue?.denominator
        }
    }
}

/// One piece of a clip in a sequence. Frames are offsets from the first frame of the clip and the
/// out point is the last frame shown, the same convention as `Marker` subclips.
public struct SequenceCut: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sequenceCut"
    public var id: String
    public var sequenceID: String
    public var assetID: String
    /// Order within the sequence, 0 first.
    public var position: Int
    public var inFrame: Int
    public var outFrame: Int
    public var note: String

    public init(id: String = newID(), sequenceID: String, assetID: String, position: Int = 0,
                inFrame: Int, outFrame: Int, note: String = "") {
        self.id = id
        self.sequenceID = sequenceID
        self.assetID = assetID
        self.position = position
        self.inFrame = inFrame
        self.outFrame = max(outFrame, inFrame)
        self.note = note
    }

    /// Length in source frames.
    public var durationFrames: Int { outFrame - inFrame + 1 }
}

/// A cut with its clip and its place on the timeline, in timeline frames.
public struct PlacedCut: Identifiable, Hashable, Sendable {
    public var cut: SequenceCut
    public var asset: Asset
    /// First timeline frame of the cut, counted from the start of the sequence.
    public var recordStart: Int
    /// Length on the timeline. Equals the source length unless the clip's frame rate differs
    /// from the timeline's, in which case the cut keeps its real-time length.
    public var recordFrames: Int

    public var id: String { cut.id }
    public var recordEnd: Int { recordStart + recordFrames }
    public var sourceIn: Timecode { asset.timecode(atFrame: cut.inFrame) }
    /// Timecode of the frame after the last one shown, as editing apps and EDLs write an out point.
    public var sourceOutExclusive: Timecode { asset.timecode(atFrame: cut.outFrame + 1) }
    public var sourceSeconds: Double { asset.frameRate.seconds(forFrames: cut.durationFrames) }
}

/// A sequence with every cut resolved to its clip and laid out end to end.
public struct ResolvedSequence: Sendable {
    public var sequence: CutSequence
    public var frameRate: FrameRate
    public var dropFrame: Bool
    public var cuts: [PlacedCut]

    public init(sequence: CutSequence, cuts: [(SequenceCut, Asset)]) {
        self.sequence = sequence
        let rate = sequence.frameRate ?? cuts.first?.1.frameRate ?? .fps24
        frameRate = rate
        dropFrame = sequence.dropFrame && rate.supportsDropFrame
        // Lengths are added as exact fractions of a second, so mixed frame rates never drift.
        var elapsed = Fraction(0, 1)
        var placed: [PlacedCut] = []
        var cursor = 0
        for (cut, asset) in cuts {
            elapsed = elapsed + Fraction(cut.durationFrames * asset.frameRateDen, asset.frameRateNum)
            let end = max((elapsed * Fraction(rate.numerator, rate.denominator)).rounded, cursor + 1)
            placed.append(PlacedCut(cut: cut, asset: asset, recordStart: cursor, recordFrames: end - cursor))
            cursor = end
        }
        self.cuts = placed
    }

    public var totalFrames: Int { cuts.last?.recordEnd ?? 0 }
    public var durationSeconds: Double { frameRate.seconds(forFrames: totalFrames) }

    /// Timeline timecode of the first frame.
    public var startTimecode: Timecode {
        let text = dropFrame ? sequence.startTimecode.replacingLastSeparator(with: ";") : sequence.startTimecode
        return Timecode(text, rate: frameRate) ?? Timecode(frames: frameRate.nominal * 3600, rate: frameRate, dropFrame: dropFrame)
    }

    public func recordTimecode(atFrame frame: Int) -> Timecode { startTimecode.advanced(by: frame) }

    /// The clips used, once each, in order of first use.
    public var assets: [Asset] {
        var seen = Set<String>()
        return cuts.map(\.asset).filter { seen.insert($0.id).inserted }
    }

    /// The cut under a timeline frame.
    public func cut(atFrame frame: Int) -> PlacedCut? {
        cuts.first { frame >= $0.recordStart && frame < $0.recordEnd } ?? (frame >= totalFrames ? cuts.last : nil)
    }
}

/// An exact fraction, for adding up clip lengths at different frame rates.
struct Fraction {
    var numerator: Int
    var denominator: Int

    init(_ numerator: Int, _ denominator: Int) {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }
        let divisor = max(gcd(numerator, denominator), 1)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    static func + (a: Fraction, b: Fraction) -> Fraction {
        Fraction(a.numerator * b.denominator + b.numerator * a.denominator, a.denominator * b.denominator)
    }

    static func * (a: Fraction, b: Fraction) -> Fraction {
        Fraction(a.numerator * b.numerator, a.denominator * b.denominator)
    }

    /// Nearest whole number, halves rounding up.
    var rounded: Int { (2 * numerator + denominator) / (2 * denominator) }
}

extension String {
    fileprivate func replacingLastSeparator(with separator: Character) -> String {
        guard let index = lastIndex(where: { $0 == ":" || $0 == ";" }) else { return self }
        var copy = self
        copy.replaceSubrange(index...index, with: String(separator))
        return copy
    }
}

public enum SequenceError: Error, LocalizedError, Equatable {
    case noSuchSequence
    case noSuchCut
    case noSuchClip

    public var errorDescription: String? {
        switch self {
        case .noSuchSequence: return "That sequence no longer exists."
        case .noSuchCut: return "That cut is no longer in the sequence."
        case .noSuchClip: return "That clip is no longer in the catalogue."
        }
    }
}

extension Catalog {
    // MARK: Sequences

    public func sequences() throws -> [CutSequence] {
        try db.read { try CutSequence.order(Column("createdAt"), Column("name")).fetchAll($0) }
    }

    public func sequence(id: String) throws -> CutSequence? {
        try db.read { try CutSequence.fetchOne($0, key: id) }
    }

    @discardableResult
    public func createSequence(named name: String, frameRate: FrameRate? = nil, dropFrame: Bool = false) throws -> CutSequence {
        let sequence = CutSequence(name: name, frameRate: frameRate, dropFrame: dropFrame)
        try db.write { try sequence.insert($0) }
        return sequence
    }

    public func renameSequence(id: String, to name: String) throws {
        try db.write { db in
            guard var sequence = try CutSequence.fetchOne(db, key: id) else { throw SequenceError.noSuchSequence }
            sequence.name = name
            sequence.modifiedAt = Date()
            try sequence.update(db)
        }
    }

    /// Changes the timeline's frame rate and timecode style. The cuts are untouched.
    public func setSequenceFrameRate(id: String, to rate: FrameRate, dropFrame: Bool) throws {
        try db.write { db in
            guard var sequence = try CutSequence.fetchOne(db, key: id) else { throw SequenceError.noSuchSequence }
            sequence.frameRate = rate
            sequence.dropFrame = dropFrame && rate.supportsDropFrame
            sequence.modifiedAt = Date()
            try sequence.update(db)
        }
    }

    /// Deletes a sequence and its cuts. The clips themselves are untouched.
    public func deleteSequence(id: String) throws {
        try db.write { _ = try CutSequence.deleteOne($0, key: id) }
    }

    /// Copies a sequence with all its cuts, so a version can be kept before changing it.
    @discardableResult
    public func duplicateSequence(id: String, named name: String? = nil) throws -> CutSequence {
        try db.write { db in
            guard let original = try CutSequence.fetchOne(db, key: id) else { throw SequenceError.noSuchSequence }
            var copy = CutSequence(name: name ?? original.name + " copy", frameRate: original.frameRate,
                                   dropFrame: original.dropFrame, startTimecode: original.startTimecode)
            copy.modifiedAt = Date()
            try copy.insert(db)
            for cut in try Self.orderedCuts(db, sequenceID: id) {
                try SequenceCut(sequenceID: copy.id, assetID: cut.assetID, position: cut.position,
                                inFrame: cut.inFrame, outFrame: cut.outFrame, note: cut.note).insert(db)
            }
            return copy
        }
    }

    // MARK: Cuts

    public func cuts(inSequence sequenceID: String) throws -> [SequenceCut] {
        try db.read { try Self.orderedCuts($0, sequenceID: sequenceID) }
    }

    /// Adds a piece of a clip at `index` (at the end when nil). The range is kept inside the clip.
    /// The first cut gives a sequence its frame rate if it has none yet.
    @discardableResult
    public func insertCut(inSequence sequenceID: String, assetID: String, inFrame: Int, outFrame: Int,
                          at index: Int? = nil, note: String = "") throws -> SequenceCut {
        try db.write { db in
            guard var sequence = try CutSequence.fetchOne(db, key: sequenceID) else { throw SequenceError.noSuchSequence }
            guard let asset = try Asset.fetchOne(db, key: assetID) else { throw SequenceError.noSuchClip }
            let range = Self.clamped(inFrame: inFrame, outFrame: outFrame, to: asset)
            let cut = SequenceCut(sequenceID: sequenceID, assetID: assetID, inFrame: range.0, outFrame: range.1, note: note)
            var ids = try Self.orderedCuts(db, sequenceID: sequenceID).map(\.id)
            ids.insert(cut.id, at: min(max(index ?? ids.count, 0), ids.count))
            try cut.insert(db)
            try Self.renumber(db, ids: ids)
            if sequence.frameRate == nil {
                sequence.frameRate = asset.frameRate
                sequence.dropFrame = asset.dropFrame
            }
            sequence.modifiedAt = Date()
            try sequence.update(db)
            return try SequenceCut.fetchOne(db, key: cut.id) ?? cut
        }
    }

    /// Adds a saved subclip (a marker with an out point) to a sequence.
    @discardableResult
    public func insertCut(inSequence sequenceID: String, subclip: Marker, at index: Int? = nil) throws -> SequenceCut {
        try insertCut(inSequence: sequenceID, assetID: subclip.assetID, inFrame: subclip.inFrame,
                      outFrame: subclip.outFrame ?? subclip.inFrame, at: index, note: subclip.name)
    }

    /// Moves a cut to a new place in its sequence; `index` is its position once moved.
    public func moveCut(id: String, to index: Int) throws {
        try db.write { db in
            guard let cut = try SequenceCut.fetchOne(db, key: id) else { throw SequenceError.noSuchCut }
            var ids = try Self.orderedCuts(db, sequenceID: cut.sequenceID).map(\.id).filter { $0 != id }
            ids.insert(id, at: min(max(index, 0), ids.count))
            try Self.renumber(db, ids: ids)
            try Self.touch(db, sequenceID: cut.sequenceID)
        }
    }

    /// Changes a cut's in and out points (source frames). The range is kept inside the clip.
    @discardableResult
    public func trimCut(id: String, inFrame: Int? = nil, outFrame: Int? = nil) throws -> SequenceCut {
        try db.write { db in
            guard var cut = try SequenceCut.fetchOne(db, key: id) else { throw SequenceError.noSuchCut }
            guard let asset = try Asset.fetchOne(db, key: cut.assetID) else { throw SequenceError.noSuchClip }
            // Moving one end past the other stops one frame short of it rather than flipping the cut.
            var start = inFrame ?? cut.inFrame, end = outFrame ?? cut.outFrame
            if inFrame != nil, outFrame == nil { start = min(start, end) }
            if outFrame != nil, inFrame == nil { end = max(end, start) }
            (cut.inFrame, cut.outFrame) = Self.clamped(inFrame: start, outFrame: end, to: asset)
            try cut.update(db)
            try Self.touch(db, sequenceID: cut.sequenceID)
            return cut
        }
    }

    public func setCutNote(id: String, to note: String) throws {
        try db.write { db in
            guard var cut = try SequenceCut.fetchOne(db, key: id) else { throw SequenceError.noSuchCut }
            cut.note = note
            try cut.update(db)
        }
    }

    public func removeCut(id: String) throws {
        try db.write { db in
            guard let cut = try SequenceCut.fetchOne(db, key: id) else { return }
            _ = try cut.delete(db)
            try Self.renumber(db, ids: try Self.orderedCuts(db, sequenceID: cut.sequenceID).map(\.id))
            try Self.touch(db, sequenceID: cut.sequenceID)
        }
    }

    /// How many cuts each sequence holds, for the sidebar.
    public func cutCounts() throws -> [String: Int] {
        try db.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT sequenceID, COUNT(*) AS n FROM sequenceCut GROUP BY sequenceID") {
                counts[row["sequenceID"]] = row["n"]
            }
            return counts
        }
    }

    /// A sequence with its clips, laid out end to end, ready to play or export.
    public func resolvedSequence(id: String) throws -> ResolvedSequence? {
        try db.read { db in
            guard let sequence = try CutSequence.fetchOne(db, key: id) else { return nil }
            let cuts = try Self.orderedCuts(db, sequenceID: id)
            let assets = try Asset.fetchAll(db, keys: Array(Set(cuts.map(\.assetID))))
            let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            return ResolvedSequence(sequence: sequence, cuts: cuts.compactMap { cut in byID[cut.assetID].map { (cut, $0) } })
        }
    }

    // MARK: Helpers

    private static func orderedCuts(_ db: Database, sequenceID: String) throws -> [SequenceCut] {
        try SequenceCut.filter(Column("sequenceID") == sequenceID).order(Column("position"), Column("id")).fetchAll(db)
    }

    private static func renumber(_ db: Database, ids: [String]) throws {
        for (position, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE sequenceCut SET position = ? WHERE id = ?", arguments: [position, id])
        }
    }

    private static func touch(_ db: Database, sequenceID: String) throws {
        try db.execute(sql: "UPDATE sequence SET modifiedAt = ? WHERE id = ?", arguments: [Date(), sequenceID])
    }

    private static func clamped(inFrame: Int, outFrame: Int, to asset: Asset) -> (Int, Int) {
        // A clip whose length is unknown (camera RAW that could not be read) is not limited.
        let last = asset.durationFrames > 0 ? asset.durationFrames - 1 : Int.max
        let start = min(max(inFrame, 0), last)
        return (start, min(max(outFrame, start), last))
    }
}
