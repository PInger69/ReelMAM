import Foundation
import Testing
@testable import StadaMAMCore

@Suite struct CutGestureTests {
    /// Ten seconds at 24 frames a second.
    let asset = Asset(sourcePath: "/Volumes/RAID/A001_C001.mov", frameRate: .fps24, durationFrames: 240)

    @Test func holdingKeepsWhatPlayedAndATapKeepsNothing() {
        // Held from one second in to three and a half seconds in.
        #expect(HoldToKeep.range(pressFrame: 24, releaseFrame: 83, in: asset) == 24...83)
        // Exactly half a second counts; anything shorter is a tap and adds no cut.
        #expect(HoldToKeep.range(pressFrame: 24, releaseFrame: 35, in: asset) == 24...35)
        #expect(HoldToKeep.range(pressFrame: 24, releaseFrame: 34, in: asset) == nil)
        #expect(HoldToKeep.range(pressFrame: 24, releaseFrame: 24, in: asset) == nil)
        // Held past the end of the clip: kept up to its last frame.
        #expect(HoldToKeep.range(pressFrame: 200, releaseFrame: 999, in: asset) == 200...239)
        // Released earlier than pressed (the clip was dragged back): nothing.
        #expect(HoldToKeep.range(pressFrame: 100, releaseFrame: 40, in: asset) == nil)
        // The rule follows the clip's frame rate: half a second of 59.94 is 30 frames.
        let fast = Asset(sourcePath: "/x.mov", frameRate: .fps59_94, durationFrames: 600)
        #expect(HoldToKeep.range(pressFrame: 0, releaseFrame: 28, in: fast) == nil)
        #expect(HoldToKeep.range(pressFrame: 0, releaseFrame: 29, in: fast) == 0...29)
    }

    @Test func chosenSentencesBecomeACutWithRoomAroundTheWords() {
        func line(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
            TranscriptSegment(assetID: asset.id, startSeconds: start, endSeconds: end, text: text)
        }
        let a = line(1.0, 2.0, "We met in the spring."), b = line(2.1, 3.5, "It rained all week.")
        let c = line(5.0, 6.0, "Then the sun came out."), d = line(9.5, 9.95, "The end.")
        let all = [c, a, d, b]

        // One sentence standing alone gets a quarter of a second each side: 4.75 s to 6.25 s.
        #expect(WordsPick.range(chosen: [c.id], transcript: all, in: asset) == 114...149)
        // A sentence hard against its neighbour starts where the neighbour stops, not on its tail.
        #expect(WordsPick.range(chosen: [b.id], transcript: all, in: asset) == 48...89)
        // A run of sentences is one cut from the first word to the last.
        #expect(WordsPick.range(chosen: [a.id, b.id], transcript: all, in: asset) == 18...89)
        // Padding stops at the ends of the clip.
        #expect(WordsPick.range(chosen: [d.id], transcript: all, in: asset) == 222...239)
        let opening = line(0.1, 0.8, "Hello.")
        #expect(WordsPick.range(chosen: [opening.id], transcript: [opening], in: asset) == 0...25)
        #expect(WordsPick.range(chosen: [], transcript: all, in: asset) == nil)

        // Shift-click chooses everything between two sentences, whichever was clicked first.
        #expect(WordsPick.run(from: c.id, to: a.id, in: all) == [a.id, b.id, c.id])
        #expect(WordsPick.run(from: a.id, to: a.id, in: all) == [a.id])
    }

    @Test func draggingAnEdgeStopsAtItsLimits() {
        let cut = SequenceCut(sequenceID: "s", assetID: asset.id, inFrame: 48, outFrame: 119)
        // The end, a second later and a second earlier.
        #expect(EdgeTrim.range(of: cut, in: asset, moving: .end, bySeconds: 1) == 48...143)
        #expect(EdgeTrim.range(of: cut, in: asset, moving: .end, bySeconds: -1) == 48...95)
        // The start, earlier (longer) and later (shorter).
        #expect(EdgeTrim.range(of: cut, in: asset, moving: .start, bySeconds: -1) == 24...119)
        #expect(EdgeTrim.range(of: cut, in: asset, moving: .start, bySeconds: 0.5) == 60...119)
        // Neither edge leaves the clip.
        #expect(EdgeTrim.range(of: cut, in: asset, moving: .start, bySeconds: -60) == 0...119)
        #expect(EdgeTrim.range(of: cut, in: asset, moving: .end, bySeconds: 60) == 48...239)
        // Dragged all the way in, a quarter of a second is left rather than nothing.
        #expect(EdgeTrim.range(of: cut, in: asset, moving: .end, bySeconds: -60) == 48...53)
        #expect(EdgeTrim.range(of: cut, in: asset, moving: .start, bySeconds: 60) == 114...119)
        // A cut already shorter than that (made with fine tune) is not forced longer.
        let tiny = SequenceCut(sequenceID: "s", assetID: asset.id, inFrame: 10, outFrame: 11)
        #expect(EdgeTrim.range(of: tiny, in: asset, moving: .end, bySeconds: -5) == 10...11)
    }

    @Test func lengthsReadPlainly() {
        #expect(PlainLength.text(seconds: 24.2) == "24 seconds")
        #expect(PlainLength.text(seconds: 1) == "1 second")
        #expect(PlainLength.text(seconds: 0.2) == "under a second")
        #expect(PlainLength.text(seconds: 60) == "1 minute")
        #expect(PlainLength.text(seconds: 65) == "1 minute 5 seconds")
        #expect(PlainLength.text(seconds: 121) == "2 minutes 1 second")
    }

    @Test func everyChangeCanBeUndoneAndRedone() throws {
        let catalog = try Catalog.inMemory()
        let a = try catalog.save(asset)
        let b = try catalog.save(Asset(sourcePath: "/Volumes/RAID/A001_C002.mov", frameRate: .fps24, durationFrames: 240))
        let sequence = try catalog.createSequence(named: "Cut")
        var history = SequenceHistory()
        func order() throws -> [String] { try catalog.cuts(inSequence: sequence.id).map(\.assetID) }
        func change(_ name: String, _ work: () throws -> Void) throws {
            let before = try catalog.snapshot(ofSequence: sequence.id)
            try work()
            history.record(name, before: before, after: try catalog.snapshot(ofSequence: sequence.id))
        }
        func undo() throws { if let state = history.undo(current: try catalog.snapshot(ofSequence: sequence.id)) { try catalog.restore(state) } }
        func redo() throws { if let state = history.redo(current: try catalog.snapshot(ofSequence: sequence.id)) { try catalog.restore(state) } }

        try change("Add") { try catalog.insertCut(inSequence: sequence.id, assetID: a.id, inFrame: 0, outFrame: 47) }
        try change("Add") { try catalog.insertCut(inSequence: sequence.id, assetID: b.id, inFrame: 24, outFrame: 71) }
        let second = try #require(try catalog.cuts(inSequence: sequence.id).last)
        try change("Move") { try catalog.moveCut(id: second.id, to: 0) }
        try change("Shorter") { try catalog.trimCut(id: second.id, outFrame: 47) }
        try change("Remove") { try catalog.removeCut(id: second.id) }
        #expect(try order() == [a.id])
        #expect(history.undoName == "Remove")

        // Undo brings the removed cut back in its place, with its trim and its identity.
        try undo()
        #expect(try order() == [b.id, a.id])
        #expect(try catalog.cuts(inSequence: sequence.id).first == SequenceCut(id: second.id, sequenceID: sequence.id, assetID: b.id, position: 0, inFrame: 24, outFrame: 47))
        try undo()
        #expect(try catalog.cuts(inSequence: sequence.id).first?.outFrame == 71)
        try undo()
        #expect(try order() == [a.id, b.id])
        #expect(history.redoName == "Move")
        try redo()
        #expect(try order() == [b.id, a.id])
        // A new change after an undo clears what could be redone.
        try change("Remove") { try catalog.removeCut(id: second.id) }
        #expect(history.redoName == nil)
        // A change that altered nothing leaves no step behind.
        let steps = history.undoSteps.count
        try change("Move") { try catalog.moveCut(id: try #require(try catalog.cuts(inSequence: sequence.id).first).id, to: 0) }
        #expect(history.undoSteps.count == steps)
        // All the way back to empty.
        while history.undoName != nil { try undo() }
        #expect(try order().isEmpty)

        // A cut whose clip has since been deleted is left out when an older state comes back.
        try redo(); try redo()
        #expect(try order() == [a.id, b.id])
        let both = try catalog.snapshot(ofSequence: sequence.id)
        try catalog.deleteAsset(id: b.id)
        try catalog.restore(both)
        #expect(try order() == [a.id])
    }
}
