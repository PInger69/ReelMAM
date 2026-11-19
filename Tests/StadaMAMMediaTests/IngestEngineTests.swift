import Foundation
import Testing
import StadaMAMCore
@testable import StadaMAMMedia

/// A stand-in for the library: records what it was asked to ingest, so the engine's
/// decisions can be tested without FFmpeg or a catalogue.
final class FakeWorker: IngestWorker, @unchecked Sendable {
    private let lock = NSLock()
    private var _processed: [String] = []
    private var _active = 0
    private var _maxActive = 0
    var catalogued: [String: Int64] = [:]
    var needingProxies: Set<String> = []
    var failures: [String: Error] = [:]
    var delay: UInt64 = 0
    var ignoredRoots: [String] = []

    var processed: [String] { lock.lock(); defer { lock.unlock() }; return _processed }
    var maxActive: Int { lock.lock(); defer { lock.unlock() }; return _maxActive }
    func clearFailure(_ path: String) { lock.lock(); failures[path] = nil; lock.unlock() }

    private func begin(_ path: String) -> Error? {
        lock.lock(); defer { lock.unlock() }
        _active += 1
        _maxActive = max(_maxActive, _active)
        return failures[path]
    }

    private func end(_ path: String, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        _active -= 1
        if !failed {
            _processed.append(path)
            needingProxies.remove(path)
        }
    }

    func process(path: String, report: @escaping @Sendable (String, Double?) -> Void) async throws -> IngestOutcome {
        let failure = begin(path)
        report("Rendering proxy", 0.5)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        end(path, failed: failure != nil)
        if let failure { throw failure }
        return IngestOutcome(assetID: "asset-" + (path as NSString).lastPathComponent)
    }

    func cataloguedSizes() throws -> [String: Int64] { catalogued }
    func pathsNeedingProxies(among paths: [String]) -> [String] { paths.filter { needingProxies.contains($0) } }
    func filter() -> IngestFilter { IngestFilter(ignoredRoots: ignoredRoots, ignoredFolderNames: ["Proxy"]) }
}

struct BoomError: LocalizedError { var errorDescription: String? { "boom" } }

struct IngestEngineTests {
    let root: String
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    init() throws {
        root = NSTemporaryDirectory() + "stadamam-engine-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/Cards", withIntermediateDirectories: true)
    }

    private func write(_ name: String, bytes: Int = 10) throws -> String {
        let path = root + "/Cards/" + name
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func makeEngine(_ worker: FakeWorker, store: IngestStore? = nil, parallel: Int = 3) async -> (IngestEngine, WatchFolder) {
        var settings = IngestEngine.Settings()
        settings.stabilitySeconds = 30
        settings.maxParallel = parallel
        settings.watchesLocalFolders = false
        let engine = IngestEngine(store: store, worker: worker, settings: settings)
        let existing = await engine.folders.first
        let folder: WatchFolder
        if let existing { folder = existing } else { folder = await engine.addFolder(path: root + "/Cards")! }
        await engine.start(runsLoop: false)
        return (engine, folder)
    }

    @Test func newFileIsIngestedOnlyOnceItHasStoppedChanging() async throws {
        let worker = FakeWorker()
        let (engine, folder) = await makeEngine(worker)
        let path = try write("A001.mov")
        await engine.scan(folder.id, now: t0)
        await engine.scan(folder.id, now: t0.addingTimeInterval(20))
        await engine.waitUntilIdle()
        #expect(worker.processed.isEmpty)
        #expect(await engine.view().stabilizing == 1)
        await engine.scan(folder.id, now: t0.addingTimeInterval(31))
        await engine.waitUntilIdle()
        #expect(worker.processed == [path])
        #expect(await engine.view().counts.doneToday == 1)
        // Scanning again neither re-queues nor re-processes it.
        await engine.scan(folder.id, now: t0.addingTimeInterval(120))
        await engine.waitUntilIdle()
        #expect(worker.processed == [path])
    }

    @Test func fileStillBeingCopiedIsLeftAlone() async throws {
        let worker = FakeWorker()
        let (engine, folder) = await makeEngine(worker)
        let path = try write("A001.mov", bytes: 10)
        await engine.scan(folder.id, now: t0)
        // The copy carries on.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 500))
        try handle.close()
        await engine.scan(folder.id, now: t0.addingTimeInterval(31))
        await engine.waitUntilIdle()
        #expect(worker.processed.isEmpty)
        await engine.scan(folder.id, now: t0.addingTimeInterval(62))
        await engine.waitUntilIdle()
        #expect(worker.processed == [path])
    }

    @Test func catalogueAndOwnFilesAreNotIngested() async throws {
        let worker = FakeWorker()
        let (engine, folder) = await makeEngine(worker)
        let known = try write("Known.mov", bytes: 10)
        _ = try write("A002.mov.partial")
        _ = try write(".DS_Store")
        _ = try write("._A003.mov")
        _ = try write("Proxy/A004.mov")
        let changed = try write("Changed.mov", bytes: 20)
        worker.catalogued = [known: 10, changed: 10]
        await engine.scan(folder.id, now: t0)
        await engine.scan(folder.id, now: t0.addingTimeInterval(31))
        await engine.waitUntilIdle()
        #expect(worker.processed == [changed])
    }

    @Test func clipsMissingAProxyAreQueuedWithoutBeingImportedAgain() async throws {
        let worker = FakeWorker()
        let (engine, folder) = await makeEngine(worker)
        let path = try write("Old.mov", bytes: 10)
        worker.catalogued = [path: 10]
        worker.needingProxies = [path]
        await engine.scan(folder.id, now: t0)
        await engine.waitUntilIdle()
        #expect(worker.processed == [path])
        // Now it has its proxies: nothing more is made.
        await engine.scan(folder.id, now: t0.addingTimeInterval(60))
        await engine.waitUntilIdle()
        #expect(worker.processed == [path])
    }

    @Test func failureKeepsItsReasonAndRetryWorks() async throws {
        let worker = FakeWorker()
        let (engine, folder) = await makeEngine(worker)
        let path = try write("Bad.mov")
        worker.failures[path] = BoomError()
        await engine.scan(folder.id, now: t0)
        await engine.scan(folder.id, now: t0.addingTimeInterval(31))
        await engine.waitUntilIdle()
        let failed = try #require(await engine.view().failed.first)
        #expect(failed.reason == "boom" && failed.path == path)
        // The same file is not retried by later scans.
        await engine.scan(folder.id, now: t0.addingTimeInterval(100))
        await engine.waitUntilIdle()
        #expect(worker.processed.isEmpty && worker.maxActive == 1)
        worker.clearFailure(path)
        await engine.retry(failed.id)
        await engine.waitUntilIdle()
        #expect(worker.processed == [path])
        #expect(await engine.view().counts.failed == 0)
    }

    @Test func rendersNeverRunMoreThanTheLimit() async throws {
        let worker = FakeWorker()
        worker.delay = 30_000_000
        let (engine, folder) = await makeEngine(worker, parallel: 2)
        for index in 0..<8 { _ = try write("C\(index).mov") }
        await engine.scan(folder.id, now: t0)
        await engine.scan(folder.id, now: t0.addingTimeInterval(31))
        await engine.waitUntilIdle()
        #expect(worker.processed.count == 8)
        #expect(worker.maxActive == 2)
    }

    @Test func offlineFolderIsNotAFailureAndIsPickedUpWhenItAppears() async throws {
        let worker = FakeWorker()
        let share = root + "/Volumes/Share"
        var settings = IngestEngine.Settings()
        settings.watchesLocalFolders = false
        let engine = IngestEngine(store: nil, worker: worker, settings: settings)
        let folder = try #require(await engine.addFolder(path: share))
        await engine.start(runsLoop: false)
        await engine.scan(folder.id, now: t0)
        var view = await engine.view()
        #expect(view.status[folder.id] == .offline && view.counts.failed == 0)
        try FileManager.default.createDirectory(atPath: share, withIntermediateDirectories: true)
        let path = share + "/A001.mov"
        try Data(count: 5).write(to: URL(fileURLWithPath: path))
        await engine.volumesChanged()
        try await Task.sleep(nanoseconds: 200_000_000)
        // volumesChanged already looked once, in real time; two more looks span the stability period.
        await engine.scan(folder.id, now: Date().addingTimeInterval(1))
        await engine.scan(folder.id, now: Date().addingTimeInterval(60))
        await engine.waitUntilIdle()
        view = await engine.view()
        #expect(worker.processed == [path])
        if case .watching = view.status[folder.id] {} else { Issue.record("should be watching") }
    }

    @Test func clipWhoseVolumeDropsMidWayWaitsForItAndIsNotCountedAsFailed() async throws {
        final class Flaky: IngestWorker, @unchecked Sendable {
            var calls = 0
            func process(path: String, report: @escaping @Sendable (String, Double?) -> Void) async throws -> IngestOutcome {
                calls += 1
                if calls == 1 { throw IngestVolumeOffline() }
                return IngestOutcome(assetID: "a")
            }
            func cataloguedSizes() throws -> [String: Int64] { [:] }
            func pathsNeedingProxies(among paths: [String]) -> [String] { [] }
            func filter() -> IngestFilter { IngestFilter() }
        }
        let worker = Flaky()
        var settings = IngestEngine.Settings()
        settings.watchesLocalFolders = false
        let engine = IngestEngine(store: nil, worker: worker, settings: settings)
        let folder = try #require(await engine.addFolder(path: root + "/Cards"))
        _ = try write("A001.mov")
        await engine.start(runsLoop: false)
        await engine.scan(folder.id, now: t0)
        await engine.scan(folder.id, now: t0.addingTimeInterval(31))
        await engine.waitUntilIdle()
        var counts = await engine.view().counts
        #expect(counts.waitingForVolume == 1 && counts.failed == 0 && worker.calls == 1)
        // The file is reachable again when volumes change, and the clip carries on by itself.
        await engine.volumesChanged()
        await engine.waitUntilIdle()
        counts = await engine.view().counts
        #expect(worker.calls == 2 && counts.doneToday == 1 && counts.waitingForVolume == 0)
    }

    @Test func queueSurvivesQuittingAndPicksUpWhereItStopped() async throws {
        let storeURL = URL(fileURLWithPath: root + "/state/ingest.json")
        let store = IngestStore(url: storeURL)
        let first = FakeWorker()
        let (engine, folder) = await makeEngine(first, store: store)
        let a = try write("A001.mov"), b = try write("A002.mov")
        await engine.setPaused(true)
        await engine.scan(folder.id, now: t0)
        await engine.scan(folder.id, now: t0.addingTimeInterval(31))
        #expect(await engine.view().counts.waiting == 2)
        await engine.stop()

        // "Reboot": a new engine reads the same file and carries on without a rescan finding anything new.
        let second = FakeWorker()
        let (resumed, resumedFolder) = await makeEngine(second, store: store)
        #expect(resumedFolder.id == folder.id)
        await resumed.waitUntilIdle()
        #expect(Set(second.processed) == [a, b])
        #expect(first.processed.isEmpty)
    }

    @Test func removedAndDisabledFoldersAreNotScanned() async throws {
        let worker = FakeWorker()
        let (engine, folder) = await makeEngine(worker)
        _ = try write("A001.mov")
        await engine.setFolder(id: folder.id, enabled: false)
        await engine.scan(folder.id, now: t0)
        await engine.scan(folder.id, now: t0.addingTimeInterval(31))
        await engine.waitUntilIdle()
        #expect(worker.processed.isEmpty)
        await engine.removeFolder(id: folder.id)
        #expect(await engine.folders.isEmpty)
    }

    #if os(macOS)
    @Test func localFolderEventsAreDelivered() async throws {
        let box = EventBox()
        let watcher = FolderWatcher(path: root + "/Cards") { box.fire() }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = try write("Fresh.mov")
        for _ in 0..<50 where !box.fired { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(box.fired)
    }
    #endif
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func fire() { lock.lock(); value = true; lock.unlock() }
}
