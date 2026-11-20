import Foundation
import Testing
import StradaMAMCore
@testable import StradaMAMMedia

@Suite struct LinkSpeedTests {
    @Test func usbSpeedsReadPlainlyAndSlowLinksAreFlagged() throws {
        let gen2 = try #require(LinkSpeed.usb(code: 4))
        #expect(gen2.label == "USB 3.2 Gen 2 · 10 Gbps")
        #expect(!gen2.isBelowRecommended)
        let gen1 = try #require(LinkSpeed.usb(code: 3))
        #expect(gen1.label == "USB 3.2 Gen 1 · 5 Gbps" && gen1.isBelowRecommended)
        #expect(LinkSpeed.usb(code: 2)?.label == "USB 2 · 480 Mbps")
        #expect(LinkSpeed.usb(bitsPerSecond: 10e9).name == "USB 3.2 Gen 2")
        #expect(LinkSpeed.usb(bitsPerSecond: 20e9).label == "USB 3.2 Gen 2x2 · 20 Gbps")
        #expect(!LinkSpeed.thunderbolt.isBelowRecommended)
        #expect(LinkSpeed.usb(code: 9) == nil)
    }

    @Test func theEstimateFollowsTheSlowestSource() {
        let fast = TransferSource(id: "A", name: "A", kind: .device, link: LinkSpeed.usb(code: 4))
        let slow = TransferSource(id: "B", name: "B", kind: .device, link: LinkSpeed.usb(code: 2))
        func item(_ source: String, _ size: Int64) -> TransferItem {
            TransferItem(id: source + UUID().uuidString, sourceID: source, sourceName: source, origin: .device("x"),
                         relativePath: "x.mov", size: size, date: nil, sidecars: [], destinationPath: "/d/x.mov",
                         history: .new, fingerprint: nil)
        }
        let gigabytes: Int64 = 100_000_000_000
        // 100 GB over 10 Gbps at 75%: about 107 s, plus 50 s to read the copy back.
        let seconds = TransferEstimate.seconds(for: [item("A", gigabytes)], sources: [fast, slow])!
        #expect(abs(seconds - (gigabytes.asDouble / (10e9 / 8 * 0.75) + gigabytes.asDouble / 2e9)) < 1)
        // The same over USB 2 takes far longer, and both run at once: the slower one sets the time.
        let both = TransferEstimate.seconds(for: [item("A", gigabytes), item("B", gigabytes)], sources: [fast, slow])!
        #expect(both > 2000)
        let unknown = TransferSource(id: "C", name: "C", kind: .device)
        #expect(TransferEstimate.seconds(for: [item("C", 1)], sources: [unknown]) == nil)
        #expect(TransferEstimate.describe(30) == "under a minute")
        #expect(TransferEstimate.describe(4 * 60 + 10) == "about 5 min")
        #expect(TransferEstimate.describe(80 * 60) == "about 1 h 20 min")
    }
}

private extension Int64 {
    var asDouble: Double { Double(self) }
}

/// Copying cards with the planner and the runner, without proxies: plain files stand in for clips.
@Suite struct TransferTests {
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "stradamam-transfer-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/CARD/CLIPS", withIntermediateDirectories: true)
    }

    private func write(_ path: String, seed: UInt8, size: Int = 300_000) throws {
        var data = Data(count: size)
        for index in data.indices { data[index] = UInt8(truncatingIfNeeded: index &* 7) &+ seed }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    @Test func aScanSaysWhichClipsAreNewAndWhichAreAlreadySafe() throws {
        let card = root + "/CARD", storage = root + "/Storage"
        for (index, name) in ["A001_C001.mov", "A001_C002.mov", "A001_C003.mov", "A001_C004.mov"].enumerated() {
            try write(card + "/CLIPS/" + name, seed: UInt8(index))
        }
        _ = FileManager.default.createFile(atPath: card + "/CLIPS/A001_C001.sidecar", contents: Data("grade".utf8))
        _ = FileManager.default.createFile(atPath: card + "/CLIPS/notes.txt", contents: Data("not a clip".utf8))
        let source = TransferSource.folder(card, name: "cam 01")
        // C001 is already where it would go; C002 was dragged into storage under another name.
        try write(storage + "/cam 01/CLIPS/A001_C001.mov", seed: 0)
        try write(storage + "/Day 1/interview.mov", seed: 1)
        // C003 was copied before, to a drive that is not this destination.
        let history = CopyHistory(url: nil)
        let c003 = try #require(SourceFingerprint.compute(path: card + "/CLIPS/A001_C003.mov"))
        let then = Date(timeIntervalSince1970: 1_790_000_000)
        history.record(.init(fingerprint: c003, name: "A001_C003.mov", size: 300_000, source: "cam 01",
                             copiedTo: "/Volumes/Shuttle/A001_C003.mov", date: then))

        let items = TransferPlanner.scan(source, destination: storage, history: history, catalog: nil,
                                         storage: StorageIndex(folder: storage))
        #expect(items.map(\.name) == ["A001_C001.mov", "A001_C002.mov", "A001_C003.mov", "A001_C004.mov"])
        #expect(items[0].history == .atDestination(storage + "/cam 01/CLIPS/A001_C001.mov"))
        #expect(items[1].history == .atDestination(storage + "/Day 1/interview.mov"))
        #expect(items[2].history == .copiedBefore(then, "/Volumes/Shuttle/A001_C003.mov"))
        #expect(items[3].history == .new)
        #expect(items[3].destinationPath == storage + "/cam 01/CLIPS/A001_C004.mov")
        #expect(items[0].sidecars == [card + "/CLIPS/A001_C001.sidecar"])
        #expect(items.allSatisfy { $0.sourceName == "cam 01" })
    }

    @Test func onlyTheChosenClipsAreCopiedAndTheCopiesAreRemembered() async throws {
        let card = root + "/CARD", storage = root + "/Storage"
        for (index, name) in ["A001_C001.mov", "A001_C002.mov", "A001_C003.mov"].enumerated() {
            try write(card + "/CLIPS/" + name, seed: UInt8(index))
        }
        _ = FileManager.default.createFile(atPath: card + "/CLIPS/A001_C001.sidecar", contents: Data("grade".utf8))
        let source = TransferSource.folder(card, name: "cam 02")
        let history = CopyHistory(url: URL(fileURLWithPath: root + "/Library/Copy History.json"))
        let items = TransferPlanner.scan(source, destination: storage, history: history, catalog: nil, storage: StorageIndex(folder: storage))
        let chosen = items.filter { $0.name != "A001_C002.mov" }

        let last = Box<TransferRunner.Progress?>(nil)
        let runner = TransferRunner(items: chosen, history: history, worker: nil) { last.value = $0 }
        let result = await runner.run()
        #expect(result.failed == 0 && result.done == 2)
        #expect(result.fraction == 1)
        #expect(last.value?.done == 2)

        let fm = FileManager.default
        for name in ["A001_C001.mov", "A001_C003.mov", "A001_C001.sidecar"] {
            #expect(fm.contentsEqual(atPath: card + "/CLIPS/" + name, andPath: storage + "/cam 02/CLIPS/" + name), "\(name)")
        }
        #expect(!fm.fileExists(atPath: storage + "/cam 02/CLIPS/A001_C002.mov"))

        // The history is on disk, and a second look at the card says what is already safe.
        let reopened = CopyHistory(url: URL(fileURLWithPath: root + "/Library/Copy History.json"))
        #expect(reopened.all.count == 2)
        let again = TransferPlanner.scan(source, destination: storage, history: reopened, catalog: nil, storage: StorageIndex(folder: storage))
        #expect(again.map(\.history.isNew) == [false, true, false])
        // Copied to this destination, so it shows as there rather than only as copied before.
        #expect(again[0].history == .atDestination(storage + "/cam 02/CLIPS/A001_C001.mov"))
        // Somewhere else entirely: the history still knows it was copied.
        let elsewhere = TransferPlanner.scan(source, destination: root + "/Other", history: reopened, catalog: nil,
                                             storage: StorageIndex(folder: root + "/Other"))
        guard case .copiedBefore(let date, let path) = elsewhere[2].history else {
            Issue.record("C003 should be known as copied before"); return
        }
        #expect(date != nil && path == storage + "/cam 02/CLIPS/A001_C003.mov")
    }

    /// One clip cannot be copied: it is marked with the reason and the others still copy.
    @Test func oneClipFailingDoesNotStopTheRest() async throws {
        let card = root + "/CARD", storage = root + "/Storage"
        for (index, name) in ["A001_C001.mov", "A001_C002.mov", "A001_C003.mov"].enumerated() {
            try write(card + "/CLIPS/" + name, seed: UInt8(index))
        }
        let source = TransferSource.folder(card, name: "cam 03")
        let items = TransferPlanner.scan(source, destination: storage, history: nil, catalog: nil, storage: nil)
        try FileManager.default.removeItem(atPath: card + "/CLIPS/A001_C002.mov")
        var copier = ResilientCopy()
        copier.retryDelays = [0.01]
        let result = await TransferRunner(items: items, history: nil, worker: nil, copier: copier) { _ in }.run()
        #expect(result.done == 2 && result.failed == 1)
        guard case .failed(let reason) = result.phases[items[1].id] else { Issue.record("C002 should fail"); return }
        #expect(reason.contains("A001_C002.mov"))
        #expect(FileManager.default.fileExists(atPath: storage + "/cam 03/CLIPS/A001_C003.mov"))
    }

    /// Several cards and a phone in one run: each lands in its own folder.
    @Test func severalSourcesCopyTogether() async throws {
        let storage = root + "/Storage"
        try write(root + "/CARD/A.mov", seed: 1)
        try write(root + "/CARD2/A.mov", seed: 2)
        let first = TransferSource.folder(root + "/CARD", name: "cam 01")
        let second = TransferSource.folder(root + "/CARD2", name: "cam 02")
        let phone = TransferSource(id: "iphone-3", name: "cam 03", kind: .device)
        let phoneClip = Data(repeating: 9, count: 123_456)
        var items = TransferPlanner.scan(first, destination: storage, history: nil, catalog: nil, storage: nil)
        items += TransferPlanner.scan(second, destination: storage, history: nil, catalog: nil, storage: nil)
        items += TransferPlanner.deviceItems(phone, files: [(name: "IMG_0001.MOV", size: Int64(phoneClip.count), date: nil)],
                                             destination: storage, history: nil)
        let history = CopyHistory(url: nil)
        let result = await TransferRunner(items: items, history: history, worker: nil, fetch: { item, path, progress in
            #expect(item.name == "IMG_0001.MOV")
            progress(0.5)
            try phoneClip.write(to: URL(fileURLWithPath: path))
            progress(1)
        }) { _ in }.run()
        #expect(result.done == 3 && result.failed == 0)
        let fm = FileManager.default
        #expect(fm.contentsEqual(atPath: root + "/CARD/A.mov", andPath: storage + "/cam 01/A.mov"))
        #expect(fm.contentsEqual(atPath: root + "/CARD2/A.mov", andPath: storage + "/cam 02/A.mov"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: storage + "/cam 03/IMG_0001.MOV")) == phoneClip)
        // The phone clip, put in again, is known by its name and size.
        let again = TransferPlanner.deviceItems(phone, files: [(name: "IMG_0001.MOV", size: Int64(phoneClip.count), date: nil)],
                                                destination: root + "/Elsewhere", history: history)
        #expect(!again[0].history.isNew)
    }

    /// A phone that hands over less than it said: the partial clip is removed and the clip fails.
    @Test func anIncompleteFetchIsNotKept() async throws {
        let phone = TransferSource(id: "iphone", name: "cam 01", kind: .device)
        let items = TransferPlanner.deviceItems(phone, files: [(name: "IMG_0002.MOV", size: 1000, date: nil)],
                                                destination: root + "/Storage", history: nil)
        let result = await TransferRunner(items: items, history: nil, worker: nil, fetch: { _, path, _ in
            try Data(count: 400).write(to: URL(fileURLWithPath: path))
        }) { _ in }.run()
        #expect(result.failed == 1)
        #expect(!FileManager.default.fileExists(atPath: root + "/Storage/cam 01/IMG_0002.MOV"))
    }
}

/// With proxies: real clips, copied and then rendered, and clips already on storage only proxied.
@Suite(.enabled(if: FFmpegTools.locate() != nil))
struct TransferProxyTests {
    let tools = FFmpegTools.locate()!
    let root = NSTemporaryDirectory() + "stradamam-transfer-proxy-" + UUID().uuidString

    private func makeClip(_ path: String, timecode: String) async throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try await tools.runOffPool(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24", "-t", "1",
            "-c:v", "mpeg4", "-q:v", "5", "-timecode", timecode, path,
        ])
    }

    @Test func copiesAreProxiedAndClipsAlreadyThereAreOnlyProxied() async throws {
        let card = root + "/CARD", storage = root + "/Storage"
        try await makeClip(card + "/A001_C001.mov", timecode: "01:00:00:00")
        try await makeClip(card + "/A001_C002.mov", timecode: "01:00:10:00")
        try FileManager.default.createDirectory(atPath: storage + "/by hand", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: card + "/A001_C002.mov", toPath: storage + "/by hand/take 2.mov")

        var options = IngestClient.Options()
        options.libraryFolder = root + "/Library"
        options.presets = [.h264_720]
        let opened = try IngestClient.openLibrary(options, tools: tools)
        let source = TransferSource.folder(card, name: "cam 01")
        let items = TransferPlanner.scan(source, destination: storage, history: opened.history,
                                         catalog: opened.library.catalog, storage: StorageIndex(folder: storage))
        #expect(items.map(\.history.isNew) == [true, false])
        let result = await TransferRunner(items: items, history: opened.history, worker: opened.worker) { _ in }.run()
        #expect(result.done == 2 && result.failed == 0, "\(result.phases)")

        let assets = try opened.library.catalog.allAssets()
        #expect(Set(assets.map(\.sourcePath)) == [storage + "/cam 01/A001_C001.mov", storage + "/by hand/take 2.mov"])
        for asset in assets {
            let proxy = try #require(try opened.library.catalog.proxies(forAsset: asset.id).first)
            #expect(proxy.status == .ready && proxy.mismatch == nil)
        }
        // Copy only: the clip is copied and catalogued, and no proxy is rendered.
        options.presets = []
        options.libraryFolder = root + "/Library2"
        let plain = try IngestClient.openLibrary(options, tools: tools)
        try await makeClip(card + "/A001_C003.mov", timecode: "01:00:20:00")
        let third = TransferPlanner.scan(source, destination: storage, history: plain.history, catalog: nil,
                                         storage: StorageIndex(folder: storage)).filter { $0.name == "A001_C003.mov" }
        let copyOnly = await TransferRunner(items: third, history: plain.history, worker: plain.worker) { _ in }.run()
        #expect(copyOnly.done == 1)
        let asset = try #require(try plain.library.catalog.allAssets().first)
        #expect(try plain.library.catalog.proxies(forAsset: asset.id).isEmpty)
    }
}
