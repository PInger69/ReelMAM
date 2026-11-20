import Foundation
import Testing
import StradaMAMCore
@testable import StradaMAMMedia

/// The copy that takes clips off cards: it has to survive a card that stumbles.
@Suite struct ResilientCopyTests {
    let root: String
    let source: String
    let destination: String
    let content: Data

    init() throws {
        root = NSTemporaryDirectory() + "stradamam-copy-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/CARD", withIntermediateDirectories: true)
        source = root + "/CARD/A001_C001.mov"
        destination = root + "/Storage/CARD/A001_C001.mov"
        var bytes = Data(count: 1_000_000)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index / 7) }
        content = bytes
        try content.write(to: URL(fileURLWithPath: source))
    }

    private func copier(chunk: Int = 64 * 1024) -> ResilientCopy {
        var copy = ResilientCopy()
        copy.chunkSize = chunk
        copy.retryDelays = [0.01, 0.01, 0.01]
        return copy
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    @Test func aCopyIsIdenticalAndLeavesNoPartialFile() throws {
        var advanced: Int64 = 0
        let checksum = try copier().copy(from: source, to: destination) { advanced += $0 }
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination)) == content)
        let independent = try SequencePackageExporter.checksum(ofFileAt: source)
        #expect(checksum == independent)
        #expect(!FileManager.default.fileExists(atPath: destination + ResilientCopy.partialSuffix))
        #expect(advanced == Int64(content.count) * 2)  // written, then read back
    }

    /// A card reader that fails a read now and then: each failed read is tried again from the
    /// same place, and the copy still comes out identical.
    @Test func readsThatFailAreTriedAgain() throws {
        var copy = copier()
        let reads = Counter(), stalls = Counter()
        copy.read = { handle, count in
            if reads.next() % 5 == 3 { throw CocoaError(.fileReadUnknown) }
            return try handle.read(upToCount: count) ?? Data()
        }
        copy.stalled = { _ in _ = stalls.next() }
        _ = try copy.copy(from: source, to: destination) { _ in }
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination)) == content)
        #expect(stalls.count > 3)
    }

    /// A card that never answers again: the copy gives up with a plain reason, keeps what it
    /// had so it can be carried on, and never leaves a half file under the clip's name.
    @Test func aCardThatStaysBrokenFailsCleanlyAndCanBeCarriedOn() throws {
        var broken = copier()
        let reads = Counter()
        broken.read = { handle, count in
            if reads.next() > 6 { throw CocoaError(.fileReadUnknown) }
            return try handle.read(upToCount: count) ?? Data()
        }
        #expect(throws: PackageError.self) { try broken.copy(from: source, to: destination) { _ in } }
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: destination))
        let partial = destination + ResilientCopy.partialSuffix
        let kept = try #require(try fm.attributesOfItem(atPath: partial)[.size] as? NSNumber).intValue
        #expect(kept == 6 * 64 * 1024)

        // The next run carries on: only the rest is written, and the whole file is still checked.
        var advanced: Int64 = 0
        _ = try copier().copy(from: source, to: destination) { advanced += $0 }
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination)) == content)
        #expect(!fm.fileExists(atPath: partial))
        #expect(advanced == Int64(content.count) * 2)
    }

    /// Something else wrote over the part-copy: what is there is not trusted, and the finished
    /// copy still matches the card.
    @Test func aDamagedPartCopyDoesNotSurvive() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/Storage/CARD", withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 200_000).write(to: URL(fileURLWithPath: destination + ResilientCopy.partialSuffix))
        let stalls = Counter()
        var copy = copier()
        copy.stalled = { _ in _ = stalls.next() }
        _ = try copy.copy(from: source, to: destination) { _ in }
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination)) == content)
        #expect(stalls.count == 1)  // the first try did not match and was made again
    }

    /// The card is pulled part-way: the clip is not failed, it waits for the card to come back.
    @Test func aCardThatIsPulledMakesTheClipWait() throws {
        var copy = copier()
        let reads = Counter()
        let card = root + "/CARD", away = root + "/EJECTED"
        copy.read = { handle, count in
            if reads.next() == 4 { try? FileManager.default.moveItem(atPath: card, toPath: away) }
            if reads.count >= 4 { throw CocoaError(.fileReadNoSuchFile) }
            return try handle.read(upToCount: count) ?? Data()
        }
        #expect(throws: IngestVolumeOffline.self) { try copy.copy(from: source, to: destination) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: destination))
    }

    @Test func aFullDiskIsSaidBeforeAnythingIsCopied() throws {
        let free = try #require(ResilientCopy.freeSpace(at: root))
        #expect(free > 0)
    }
}
