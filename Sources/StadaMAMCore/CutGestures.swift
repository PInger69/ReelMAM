import Foundation
import GRDB

/// The rules behind the simple ways of building a cut: holding a button while a clip plays,
/// picking sentences from the dialogue, and dragging the edge of a card. Kept here, away from the
/// screen, so they can be tested and so the browser app can follow the same rules.

/// Hold to keep: what plays while the button is held becomes a cut.
public enum HoldToKeep {
    /// A press that keeps less than this much of the clip adds nothing. It is treated as a tap,
    /// which plays or pauses. This stops a slip of the finger adding a cut of a frame or two.
    public static let minimumSeconds = 0.5

    /// The stretch of a clip kept by a press, in clip frames (the last frame included), or nil
    /// when the press was too short to count.
    /// - Parameters:
    ///   - pressFrame: the frame showing when the button went down.
    ///   - releaseFrame: the frame showing when it came up.
    public static func range(pressFrame: Int, releaseFrame: Int, in asset: Asset) -> ClosedRange<Int>? {
        let last = asset.durationFrames > 0 ? asset.durationFrames - 1 : Int.max
        let start = min(max(pressFrame, 0), last), end = min(max(releaseFrame, 0), last)
        let needed = Int((minimumSeconds * asset.frameRate.fps).rounded(.up))
        guard end - start + 1 >= needed else { return nil }
        return start...end
    }
}

/// Pick by the words: sentences chosen from a clip's dialogue become a cut.
public enum WordsPick {
    /// Room left before the first word and after the last, so neither is clipped.
    public static let paddingSeconds = 0.25

    /// The stretch of a clip covering the chosen sentences, in clip frames (last frame included).
    /// The padding never reaches into a neighbouring sentence that was not chosen, so the cut does
    /// not start on the tail of someone else's line. Nil when nothing is chosen.
    /// - Parameters:
    ///   - chosen: IDs of the chosen sentences.
    ///   - transcript: every sentence of the clip.
    public static func range(chosen: Set<String>, transcript: [TranscriptSegment], in asset: Asset) -> ClosedRange<Int>? {
        let ordered = transcript.sorted { $0.startSeconds < $1.startSeconds }
        let picked = ordered.filter { chosen.contains($0.id) }
        guard let first = picked.first else { return nil }
        let start = first.startSeconds
        let end = picked.map(\.endSeconds).max() ?? first.endSeconds
        // The nearest speech on each side that is not part of the choice.
        let before = ordered.filter { !chosen.contains($0.id) && $0.endSeconds <= start }.map(\.endSeconds).max()
        let after = ordered.filter { !chosen.contains($0.id) && $0.startSeconds >= end }.map(\.startSeconds).min()
        let from = max(start - paddingSeconds, before ?? 0, 0)
        let to = min(end + paddingSeconds, after ?? .greatestFiniteMagnitude)

        let rate = asset.frameRate
        let last = asset.durationFrames > 0 ? asset.durationFrames - 1 : Int.max
        let inFrame = min(max(Int((from * rate.fps).rounded(.down)), 0), last)
        let outFrame = min(max(Int((to * rate.fps).rounded(.up)) - 1, inFrame), last)
        return inFrame...outFrame
    }

    /// The sentences from one to another, inclusive, for choosing a run with a shift-click.
    public static func run(from a: String, to b: String, in transcript: [TranscriptSegment]) -> Set<String> {
        let ordered = transcript.sorted { $0.startSeconds < $1.startSeconds }.map(\.id)
        guard let i = ordered.firstIndex(of: a), let j = ordered.firstIndex(of: b) else { return [b] }
        return Set(ordered[min(i, j)...max(i, j)])
    }
}

/// Dragging the left or right edge of a card to make a cut shorter or longer.
public enum EdgeTrim {
    public enum Edge: Sendable { case start, end }

    /// A cut is never dragged shorter than this (unless it already is).
    public static let minimumSeconds = 0.25

    /// The cut's range after one edge is moved by `seconds` (negative is earlier). The edge stops
    /// at the ends of the clip and before it would meet the other edge.
    public static func range(of cut: SequenceCut, in asset: Asset, moving edge: Edge, bySeconds seconds: Double) -> ClosedRange<Int> {
        let delta = Int((seconds * asset.frameRate.fps).rounded())
        let last = asset.durationFrames > 0 ? asset.durationFrames - 1 : Int.max
        let shortest = min(max(Int((minimumSeconds * asset.frameRate.fps).rounded()), 1), cut.durationFrames)
        switch edge {
        case .start:
            let start = min(max(cut.inFrame + delta, 0), cut.outFrame - shortest + 1)
            return start...cut.outFrame
        case .end:
            let end = max(min(cut.outFrame + delta, last), cut.inFrame + shortest - 1)
            return cut.inFrame...end
        }
    }
}

/// Lengths said the way people say them: "24 seconds", "1 minute 5 seconds".
public enum PlainLength {
    public static func text(seconds: Double) -> String {
        guard seconds >= 0.5 else { return "under a second" }
        let total = Int(seconds.rounded())
        let minutes = total / 60, rest = total % 60
        let minuteText = "\(minutes) minute\(minutes == 1 ? "" : "s")"
        let secondText = "\(rest) second\(rest == 1 ? "" : "s")"
        if minutes == 0 { return secondText }
        return rest == 0 ? minuteText : "\(minuteText) \(secondText)"
    }
}

/// The cuts of a sequence at one moment, for undo.
public struct SequenceSnapshot: Equatable, Sendable {
    public var sequenceID: String
    public var cuts: [SequenceCut]
}

/// What can be undone and redone in the open sequence. Every change records the state before it.
public struct SequenceHistory: Sendable {
    public struct Step: Equatable, Sendable {
        /// What the change was, in plain words: "Remove", "Move", "Add".
        public var name: String
        public var snapshot: SequenceSnapshot
    }

    public static let limit = 100
    public private(set) var undoSteps: [Step] = []
    public private(set) var redoSteps: [Step] = []

    public init() {}

    public var undoName: String? { undoSteps.last?.name }
    public var redoName: String? { redoSteps.last?.name }

    /// Call with the state before a change. A change that altered nothing is not recorded.
    public mutating func record(_ name: String, before: SequenceSnapshot, after: SequenceSnapshot) {
        guard before != after else { return }
        undoSteps.append(Step(name: name, snapshot: before))
        if undoSteps.count > Self.limit { undoSteps.removeFirst() }
        redoSteps.removeAll()
    }

    /// Takes back the last change: returns the state to restore, given the state now.
    public mutating func undo(current: SequenceSnapshot) -> SequenceSnapshot? {
        guard let step = undoSteps.popLast() else { return nil }
        redoSteps.append(Step(name: step.name, snapshot: current))
        return step.snapshot
    }

    public mutating func redo(current: SequenceSnapshot) -> SequenceSnapshot? {
        guard let step = redoSteps.popLast() else { return nil }
        undoSteps.append(Step(name: step.name, snapshot: current))
        return step.snapshot
    }
}

extension Catalog {
    public func snapshot(ofSequence sequenceID: String) throws -> SequenceSnapshot {
        SequenceSnapshot(sequenceID: sequenceID, cuts: try cuts(inSequence: sequenceID))
    }

    /// Puts a sequence's cuts back as they were. A cut whose clip has since left the catalogue is
    /// left out.
    public func restore(_ snapshot: SequenceSnapshot) throws {
        try db.write { db in
            guard try CutSequence.fetchOne(db, key: snapshot.sequenceID) != nil else { throw SequenceError.noSuchSequence }
            _ = try SequenceCut.filter(Column("sequenceID") == snapshot.sequenceID).deleteAll(db)
            var position = 0
            for var cut in snapshot.cuts where try Asset.exists(db, key: cut.assetID) {
                cut.position = position
                position += 1
                try cut.insert(db)
            }
            try db.execute(sql: "UPDATE sequence SET modifiedAt = ? WHERE id = ?", arguments: [Date(), snapshot.sequenceID])
        }
    }
}
