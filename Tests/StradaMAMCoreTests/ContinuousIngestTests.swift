import Foundation
import Testing
@testable import StradaMAMCore

struct ContinuousIngestTests {
    // MARK: Filter

    @Test func filterSkipsHiddenPartialAndOwnFolders() {
        let filter = IngestFilter(ignoredRoots: ["/Library/Proxies/"], ignoredFolderNames: ["Proxy"])
        #expect(filter.accepts(path: "/Volumes/RAID/Day 1/A001_C003.mov"))
        #expect(filter.accepts(path: "/Volumes/RAID/Day 1/A001_C003.MXF"))
        #expect(!filter.accepts(path: "/Volumes/RAID/Day 1/.DS_Store"))
        #expect(!filter.accepts(path: "/Volumes/RAID/Day 1/._A001_C003.mov"))
        #expect(!filter.accepts(path: "/Volumes/RAID/Day 1/A001_C003.mov.partial"))
        #expect(!filter.accepts(path: "/Volumes/RAID/Day 1/A001_C003.partial.mov"))
        #expect(!filter.accepts(path: "/Volumes/RAID/Day 1/A001_C003.mov.part"))
        #expect(!filter.accepts(path: "/Volumes/RAID/Day 1/notes.txt"))
        #expect(!filter.accepts(path: "/Library/Proxies/RAID/A001_C003.mov"))
        #expect(!filter.accepts(path: "/Volumes/RAID/Day 1/Proxy/A001_C003.mov"))
        #expect(filter.accepts(path: "/Library/ProxiesOther/A001_C003.mov"))
    }

    // MARK: Stability

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func fileIsTakenOnlyAfterItStopsChanging() {
        var tracker = StabilityTracker(period: 30)
        let stamp = FileStamp(size: 100, modified: 5)
        #expect(tracker.observe(["/a.mov": stamp], now: t0).isEmpty)
        #expect(tracker.observe(["/a.mov": stamp], now: t0.addingTimeInterval(29)).isEmpty)
        #expect(tracker.observe(["/a.mov": stamp], now: t0.addingTimeInterval(30)) == ["/a.mov"])
        // Returned once: the tracker lets go of it.
        #expect(tracker.waitingCount == 0)
    }

    @Test func growingFileStartsTheWaitOver() {
        var tracker = StabilityTracker(period: 30)
        _ = tracker.observe(["/a.mov": FileStamp(size: 100, modified: 5)], now: t0)
        // Still copying: size grew, then only the modification time moved.
        #expect(tracker.observe(["/a.mov": FileStamp(size: 200, modified: 6)], now: t0.addingTimeInterval(25)).isEmpty)
        #expect(tracker.observe(["/a.mov": FileStamp(size: 200, modified: 6)], now: t0.addingTimeInterval(50)).isEmpty)
        #expect(tracker.observe(["/a.mov": FileStamp(size: 200, modified: 7)], now: t0.addingTimeInterval(56)).isEmpty)
        #expect(tracker.observe(["/a.mov": FileStamp(size: 200, modified: 7)], now: t0.addingTimeInterval(86)) == ["/a.mov"])
    }

    @Test func vanishedFilesAreForgotten() {
        var tracker = StabilityTracker(period: 30)
        _ = tracker.observe(["/a.mov": FileStamp(size: 1, modified: 1), "/b.mov": FileStamp(size: 1, modified: 1)], now: t0)
        #expect(tracker.waitingCount == 2)
        _ = tracker.observe(["/b.mov": FileStamp(size: 1, modified: 1)], now: t0.addingTimeInterval(5))
        #expect(tracker.waitingPaths == ["/b.mov"])
    }

    @Test func recheckLooksOnlyAtPendingFiles() {
        var tracker = StabilityTracker(period: 10)
        _ = tracker.observe(["/a.mov": FileStamp(size: 1, modified: 1)], now: t0)
        let stable = tracker.recheck(now: t0.addingTimeInterval(10)) { _ in FileStamp(size: 1, modified: 1) }
        #expect(stable == ["/a.mov"])
        var other = StabilityTracker(period: 10)
        _ = other.observe(["/a.mov": FileStamp(size: 1, modified: 1)], now: t0)
        #expect(other.recheck(now: t0.addingTimeInterval(20)) { _ in nil }.isEmpty)
        #expect(other.waitingCount == 0)
    }

    // MARK: Scan diff

    @Test func scanDiffFindsNewAndChangedFilesOnly() {
        let listing = [
            "/known.mov": FileStamp(size: 10, modified: 1),
            "/new.mov": FileStamp(size: 20, modified: 1),
            "/grown.mov": FileStamp(size: 31, modified: 2),
            "/failed.mov": FileStamp(size: 40, modified: 1),
            "/failedThenChanged.mov": FileStamp(size: 51, modified: 1),
        ]
        let candidates = ScanDiff.candidates(
            listing: listing,
            catalogued: ["/known.mov": 10, "/grown.mov": 30],
            queued: ["/failed.mov": 40, "/failedThenChanged.mov": 50])
        #expect(Set(candidates.keys) == ["/new.mov", "/grown.mov", "/failedThenChanged.mov"])
    }

    // MARK: Queue

    @Test func queueRunsItemsInOrderAndCountsToday() {
        var queue = IngestQueue()
        let a = queue.enqueue(path: "/a.mov", size: 1, folderID: "f", now: t0)!
        let b = queue.enqueue(path: "/b.mov", size: 1, folderID: "f", now: t0)!
        #expect(queue.enqueue(path: "/a.mov", size: 1, folderID: "f") == nil)
        #expect(queue.nextWaiting()?.id == a.id)
        queue.start(a.id)
        #expect(queue.nextWaiting()?.id == b.id)
        queue.complete(a.id, assetID: "asset", now: t0)
        queue.start(b.id)
        queue.fail(b.id, reason: "No decoder", now: t0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let counts = queue.counts(now: t0.addingTimeInterval(60), calendar: calendar)
        #expect(counts.doneToday == 1 && counts.failed == 1 && counts.failedToday == 1 && counts.waiting == 0)
        let tomorrow = queue.counts(now: t0.addingTimeInterval(86_400 * 2), calendar: calendar)
        #expect(tomorrow.doneToday == 0 && tomorrow.failed == 1)
    }

    @Test func failedItemKeepsItsReasonUntilRetried() {
        var queue = IngestQueue()
        let item = queue.enqueue(path: "/a.mov", size: 1, folderID: nil)!
        queue.start(item.id)
        queue.fail(item.id, reason: "Disk full")
        #expect(queue.item(id: item.id)?.reason == "Disk full")
        #expect(queue.nextWaiting() == nil)
        queue.retry(item.id)
        #expect(queue.item(id: item.id)?.state == .waiting && queue.item(id: item.id)?.reason == nil)
        #expect(queue.nextWaiting()?.id == item.id)
    }

    @Test func offlineVolumeWaitsInsteadOfFailing() {
        var queue = IngestQueue()
        let a = queue.enqueue(path: "/Volumes/Share/a.mov", size: 1, folderID: nil)!
        queue.enqueue(path: "/b.mov", size: 1, folderID: nil)
        queue.start(a.id)
        queue.holdForVolume(a.id)
        #expect(queue.item(id: a.id)?.attempts == 0)
        #expect(queue.nextWaiting()?.path == "/b.mov")
        var counts = queue.counts()
        #expect(counts.waitingForVolume == 1 && counts.failed == 0)
        queue.releaseHeld { _ in true }
        #expect(queue.nextWaiting()?.id == a.id)
        counts = queue.counts()
        #expect(counts.waitingForVolume == 0 && counts.waiting == 2)
    }

    @Test func runningItemsWaitAgainAfterARestart() throws {
        var queue = IngestQueue()
        let a = queue.enqueue(path: "/a.mov", size: 1, folderID: nil)!
        queue.start(a.id, stage: "Rendering proxy")
        queue.recoverAfterRestart()
        #expect(queue.item(id: a.id)?.state == .waiting)
        #expect(queue.nextWaiting()?.id == a.id)
    }

    @Test func finishedItemsAreRequeuedWhenAskedForAgainAndPrunedLater() {
        var queue = IngestQueue()
        let a = queue.enqueue(path: "/a.mov", size: 1, folderID: nil, now: t0)!
        queue.start(a.id)
        queue.complete(a.id, assetID: "x", now: t0)
        #expect(queue.enqueue(path: "/a.mov", size: 2, folderID: nil, now: t0) != nil)
        #expect(queue.items.count == 1 && queue.item(path: "/a.mov")?.state == .waiting)
        let b = queue.enqueue(path: "/b.mov", size: 1, folderID: nil, now: t0)!
        queue.start(b.id)
        queue.complete(b.id, assetID: "y", now: t0)
        queue.prune(olderThanDays: 3, now: t0.addingTimeInterval(86_400 * 4))
        #expect(queue.item(path: "/b.mov") == nil && queue.item(path: "/a.mov") != nil)
    }

    @Test func indexesSurviveRemovalAndCoding() throws {
        var queue = IngestQueue()
        for index in 0..<50 { queue.enqueue(path: "/clip\(index).mov", size: Int64(index), folderID: index.isMultiple(of: 2) ? "even" : "odd") }
        queue.remove(folderID: "even")
        #expect(queue.items.count == 25 && queue.item(path: "/clip1.mov")?.size == 1 && queue.item(path: "/clip0.mov") == nil)
        let data = try JSONEncoder().encode(queue)
        var decoded = try JSONDecoder().decode(IngestQueue.self, from: data)
        #expect(decoded.items == queue.items)
        #expect(decoded.item(path: "/clip49.mov")?.size == 49)
        #expect(decoded.nextWaiting()?.path == "/clip1.mov")
    }

    // MARK: Store

    private func tempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stradamam-ingest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func storeSurvivesARestart() throws {
        let dir = try tempDirectory()
        let store = IngestStore(url: dir.appendingPathComponent("state/ingest.json"))
        var snapshot = IngestSnapshot()
        snapshot.folders = [WatchFolder(id: "f1", path: "/Volumes/RAID", isEnabled: false)]
        let a = snapshot.queue.enqueue(path: "/Volumes/RAID/a.mov", size: 7, folderID: "f1")!
        snapshot.queue.start(a.id)
        let b = snapshot.queue.enqueue(path: "/Volumes/RAID/b.mov", size: 8, folderID: "f1")!
        snapshot.queue.start(b.id)
        snapshot.queue.fail(b.id, reason: "Corrupt file")
        try store.save(snapshot)
        let loaded = store.load()
        #expect(loaded.folders == snapshot.folders)
        #expect(loaded.queue.item(id: a.id)?.state == .waiting)
        #expect(loaded.queue.item(id: b.id)?.state == .failed && loaded.queue.item(id: b.id)?.reason == "Corrupt file")
    }

    @Test func unreadableStateStartsCleanAndIsKept() throws {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("ingest.json")
        try Data("not json".utf8).write(to: url)
        #expect(IngestStore(url: url).load().folders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path + ".damaged"))
    }

    // MARK: Scanner

    @Test func scannerListsOnlyWantedFilesAndReportsMissingFolders() throws {
        let dir = try tempDirectory()
        let fm = FileManager.default
        for folder in ["Day 1", "Proxies/RAID", "Proxy"] { try fm.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true) }
        for file in ["Day 1/A001.mov", "Day 1/A002.mov.partial", "Day 1/.DS_Store", "Day 1/._A001.mov", "Day 1/notes.txt",
                     "Proxies/RAID/A001.mov", "Proxy/A001.mov"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(file))
        }
        let filter = IngestFilter(ignoredRoots: [dir.path + "/Proxies"], ignoredFolderNames: ["Proxy"])
        guard case .files(let found) = FolderScanner.scan(dir.path, filter: filter) else { Issue.record("unreachable"); return }
        #expect(found.keys.map { ($0 as NSString).lastPathComponent }.sorted() == ["A001.mov"])
        #expect(found.values.first?.size == 1)
        if case .files = FolderScanner.scan(dir.path + "/Nowhere", filter: filter) { Issue.record("should be unreachable") }
    }
}
