import Foundation
import StradaMAMCore

/// Watches folders and turns every new, finished clip into catalogue entries and proxies,
/// with nobody clicking Import.
///
/// - Local folders are watched with FSEvents (plus a slow safety scan); mounted shares are scanned
///   on a timer, because events from a network share cannot be trusted.
/// - A file is taken only once its size and modification time have not changed for the
///   stability period, so a card offload still copying is left alone.
/// - The queue is written to disk, so a quit, a crash or a reboot loses nothing; a scan on start
///   picks up whatever landed while the app was closed. A folder that is not mounted is retried
///   when it appears and is never reported as a failure.
public actor IngestEngine {
    public struct Settings: Sendable {
        /// How long size and modification time must stay unchanged before a file is ingested.
        public var stabilitySeconds: TimeInterval = 30
        /// How often mounted shares are scanned.
        public var shareScanInterval: TimeInterval = 60
        /// How often local folders are scanned as a safety net behind FSEvents.
        public var localScanInterval: TimeInterval = 600
        /// Clips imported at once. Renders are limited separately by the render limiter.
        public var maxParallel = 3
        /// How often the loop wakes to check pending files and folders that are due.
        public var tick: TimeInterval = 5
        /// Use FSEvents on folders on local disks. Off only in tests, which drive scans by hand.
        public var watchesLocalFolders = true
        public init() {}
    }

    public enum FolderStatus: Equatable, Sendable {
        case idle
        case scanning
        case watching(lastScan: Date)
        /// Not mounted or not reachable; retried when volumes change and on every scan.
        case offline
    }

    /// What the screen shows. Long lists are cut to what fits: the counts are always complete.
    public struct View: Sendable {
        public var isRunning: Bool
        public var folders: [WatchFolder]
        public var status: [String: FolderStatus]
        public var working: [IngestItem]
        public var waiting: [IngestItem]
        public var failed: [IngestItem]
        public var recentlyDone: [IngestItem]
        public var counts: IngestCounts
        /// Files seen but not yet old enough to take, e.g. a copy still running.
        public var stabilizing: Int
    }

    private var snapshot: IngestSnapshot
    private let store: IngestStore?
    private let worker: IngestWorker
    public private(set) var settings: Settings
    private let onChange: @Sendable (View) -> Void
    private let onLibraryChange: @Sendable () -> Void

    private var trackers: [String: StabilityTracker] = [:]
    private var status: [String: FolderStatus] = [:]
    private var lastScan: [String: Date] = [:]
    private var watchers: [String: FolderWatcher] = [:]
    private var scanning: Set<String> = []
    private var running = false
    private var paused = false
    private var inFlight = 0
    private var loop: Task<Void, Never>?
    private var dirty = false
    private var lastSave = Date.distantPast
    private var lastPublish = Date.distantPast
    private var publishScheduled = false

    public init(store: IngestStore?, worker: IngestWorker, settings: Settings = Settings(),
                onChange: @escaping @Sendable (View) -> Void = { _ in },
                onLibraryChange: @escaping @Sendable () -> Void = {}) {
        self.store = store
        self.snapshot = store?.load() ?? IngestSnapshot()
        self.worker = worker
        self.settings = settings
        self.onChange = onChange
        self.onLibraryChange = onLibraryChange
    }

    // MARK: Running

    /// Starts watching and scans every folder at once, which catches whatever arrived while the app was closed.
    public func start(runsLoop: Bool = true) {
        guard !running else { return }
        running = true
        syncWatchers()
        pump()
        publish(force: true)
        guard runsLoop else { return }
        loop = Task { [weak self] in
            await self?.scanAll(now: Date())
            while !Task.isCancelled {
                let wait = await self?.settings.tick ?? 5
                try? await Task.sleep(nanoseconds: UInt64(max(wait, 0.05) * 1_000_000_000))
                await self?.tick(now: Date())
            }
        }
    }

    public func stop() {
        running = false
        loop?.cancel()
        loop = nil
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        flush()
        publish(force: true)
    }

    /// Stops starting new clips; the ones being made carry on.
    public func setPaused(_ value: Bool) {
        paused = value
        if !value { pump() }
        publish(force: true)
    }

    public func updateSettings(_ change: (inout Settings) -> Void) {
        change(&settings)
        for key in trackers.keys { trackers[key]?.period = settings.stabilitySeconds }
    }

    // MARK: Folders

    public var folders: [WatchFolder] { snapshot.folders }

    @discardableResult
    public func addFolder(path: String) -> WatchFolder? {
        let clean = (path as NSString).standardizingPath
        guard !snapshot.folders.contains(where: { $0.path == clean }) else { return nil }
        let folder = WatchFolder(path: clean)
        snapshot.folders.append(folder)
        changed()
        syncWatchers()
        if running { Task { await self.scan(folder.id, now: Date()) } }
        return folder
    }

    public func removeFolder(id: String) {
        snapshot.folders.removeAll { $0.id == id }
        snapshot.queue.remove(folderID: id)
        trackers[id] = nil
        status[id] = nil
        syncWatchers()
        changed()
    }

    public func setFolder(id: String, enabled: Bool) {
        guard let index = snapshot.folders.firstIndex(where: { $0.id == id }) else { return }
        snapshot.folders[index].isEnabled = enabled
        if !enabled { trackers[id] = nil; status[id] = .idle }
        syncWatchers()
        changed()
        if enabled, running { Task { await self.scan(id, now: Date()) } }
    }

    private func syncWatchers() {
        guard running, settings.watchesLocalFolders else { return }
        let wanted = Set(snapshot.folders.filter(\.isEnabled).map(\.id))
        for id in watchers.keys where !wanted.contains(id) {
            watchers[id]?.stop()
            watchers[id] = nil
        }
        for folder in snapshot.folders where folder.isEnabled && watchers[folder.id] == nil {
            guard FolderWatcher.isLocalVolume(folder.path), FileManager.default.fileExists(atPath: folder.path) else { continue }
            let id = folder.id
            let watcher = FolderWatcher(path: folder.path) { [weak self] in
                Task { await self?.folderEvent(id) }
            }
            watcher.start()
            watchers[id] = watcher
        }
    }

    /// FSEvents fired: look again soon, but not once per file of a large copy.
    private func folderEvent(_ id: String) {
        guard running, !scanning.contains(id) else { return }
        if let last = lastScan[id], Date().timeIntervalSince(last) < min(5, settings.tick) { return }
        Task { await self.scan(id, now: Date()) }
    }

    /// A volume mounted or unmounted: retry folders that were offline and waiting clips.
    public func volumesChanged() {
        syncWatchers()
        snapshot.queue.releaseHeld { FileManager.default.fileExists(atPath: $0.path) }
        for folder in snapshot.folders where folder.isEnabled && status[folder.id] == .offline {
            let id = folder.id
            Task { await self.scan(id, now: Date()) }
        }
        pump()
        changed()
    }

    // MARK: Scanning

    public func scanAll(now: Date) async {
        for folder in snapshot.folders where folder.isEnabled { await scan(folder.id, now: now) }
    }

    /// Looks at a folder once: finds new and changed files, holds back unfinished ones and
    /// queues the ones that have been still for the stability period.
    public func scan(_ id: String, now: Date) async {
        guard let folder = snapshot.folders.first(where: { $0.id == id }), folder.isEnabled,
              !scanning.contains(id) else { return }
        scanning.insert(id)
        status[id] = .scanning
        publish()
        let filter = worker.filter()
        let worker = self.worker
        let queued = snapshot.queue.sizesByPath
        // Finished clips may be looked at again for a missing proxy; anything else in the queue is already handled.
        let handled = Set(snapshot.queue.items.filter { $0.state != .done }.map(\.path))
        let outcome = await Task.detached(priority: .utility) { () -> (FolderScanner.Result, [String: Int64], [String]) in
            let result = FolderScanner.scan(folder.path, filter: filter)
            guard case .files(let listing) = result else { return (result, [:], []) }
            let known = (try? worker.cataloguedSizes()) ?? [:]
            // Catalogued clips in this folder that still lack a wanted proxy (e.g. the remote one).
            let sameAsCatalogue = listing.filter { known[$0.key] == $0.value.size && !handled.contains($0.key) }.map(\.key)
            return (result, known, worker.pathsNeedingProxies(among: sameAsCatalogue))
        }.value
        scanning.remove(id)
        lastScan[id] = now
        guard case .files(let listing) = outcome.0 else {
            status[id] = .offline
            publish()
            return
        }
        status[id] = .watching(lastScan: now)
        var tracker = trackers[id] ?? StabilityTracker(period: settings.stabilitySeconds)
        tracker.period = settings.stabilitySeconds
        let candidates = ScanDiff.candidates(listing: listing, catalogued: outcome.1, queued: snapshot.queue.sizesByPath)
        for path in tracker.observe(candidates, now: now) {
            snapshot.queue.enqueue(path: path, size: candidates[path]?.size ?? 0, folderID: id, now: now)
        }
        trackers[id] = tracker
        for path in outcome.2 {
            if let item = snapshot.queue.item(path: path), item.state != .done { continue }
            if let size = listing[path]?.size { snapshot.queue.enqueue(path: path, size: size, folderID: id, now: now) }
        }
        changed()
        pump()
    }

    /// One turn of the loop: re-check files still being copied, release clips whose volume is back,
    /// scan folders that are due, and start work.
    public func tick(now: Date) async {
        guard running else { return }
        for id in Array(trackers.keys) {
            guard var tracker = trackers[id], tracker.waitingCount > 0 else { continue }
            let stable = tracker.recheck(now: now) { FolderScanner.stamp(of: $0) }
            trackers[id] = tracker
            for path in stable {
                guard let stamp = FolderScanner.stamp(of: path) else { continue }
                snapshot.queue.enqueue(path: path, size: stamp.size, folderID: id, now: now)
            }
            if !stable.isEmpty { changed() }
        }
        snapshot.queue.releaseHeld { FileManager.default.fileExists(atPath: $0.path) }
        for folder in snapshot.folders where folder.isEnabled {
            let local = watchers[folder.id] != nil
            let interval = local ? settings.localScanInterval : settings.shareScanInterval
            if let last = lastScan[folder.id], now.timeIntervalSince(last) < interval { continue }
            await scan(folder.id, now: now)
        }
        snapshot.queue.prune(now: now)
        pump()
        saveIfDue()
        publish()
    }

    // MARK: Queue

    public func retry(_ id: String) {
        snapshot.queue.retry(id)
        changed()
        pump()
    }

    public func retryAllFailed() {
        snapshot.queue.retryAllFailed()
        changed()
        pump()
    }

    /// Takes a finished, skipped or failed entry off the list. A failed file will be seen again by the next scan.
    public func dismiss(_ id: String) {
        snapshot.queue.remove(id)
        changed()
    }

    private func pump() {
        guard running, !paused else { return }
        while inFlight < settings.maxParallel, let item = snapshot.queue.nextWaiting() {
            snapshot.queue.start(item.id)
            inFlight += 1
            changed()
            Task {
                await self.run(item)
                await self.finishedOne()
            }
        }
    }

    private func finishedOne() {
        inFlight -= 1
        changed()
        onLibraryChange()
        pump()
    }

    private func run(_ item: IngestItem) async {
        guard FileManager.default.fileExists(atPath: item.path) else {
            finishMissing(item)
            return
        }
        let id = item.id
        do {
            let outcome = try await worker.process(path: item.path) { [weak self] stage, progress in
                Task { await self?.report(id, stage: stage, progress: progress) }
            }
            snapshot.queue.complete(id, assetID: outcome.assetID, note: outcome.note)
        } catch let skipped as IngestSkipped {
            snapshot.queue.skip(id, reason: skipped.reason)
        } catch is IngestVolumeOffline {
            snapshot.queue.holdForVolume(id)
        } catch {
            if FileManager.default.fileExists(atPath: item.path) {
                snapshot.queue.fail(id, reason: error.localizedDescription)
            } else {
                finishMissing(item)
            }
        }
    }

    /// The file is not there. If its watched folder is not there either the volume is away and
    /// the clip waits for it; otherwise the file was moved or deleted before it could be taken.
    private func finishMissing(_ item: IngestItem) {
        let folder = snapshot.folders.first { $0.id == item.folderID }
        let root = folder?.path ?? item.path.split(separator: "/").prefix(2).map { "/" + $0 }.joined()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue,
           (try? FileManager.default.contentsOfDirectory(atPath: root)) != nil {
            snapshot.queue.skip(item.id, reason: "The file was moved or deleted before it could be imported.")
        } else {
            snapshot.queue.holdForVolume(item.id)
        }
    }

    private func report(_ id: String, stage: String, progress: Double?) {
        guard snapshot.queue.item(id: id)?.state == .working else { return }
        snapshot.queue.setStage(id, stage: stage, progress: progress)
        publish()
    }

    // MARK: Waiting for idle (tests, and a clean quit)

    /// Returns when nothing is being made and nothing runnable is waiting.
    public func waitUntilIdle(timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if inFlight == 0, paused || snapshot.queue.nextWaiting() == nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    public var queue: IngestQueue { snapshot.queue }

    // MARK: Saving and publishing

    private func changed() {
        dirty = true
        saveIfDue()
        publish()
    }

    private func saveIfDue() {
        guard dirty, Date().timeIntervalSince(lastSave) >= 2 else { return }
        flush()
    }

    /// Writes the queue to disk now.
    public func flush() {
        guard dirty else { return }
        dirty = false
        lastSave = Date()
        try? store?.save(snapshot)
    }

    private func publish(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastPublish) < 0.4 {
            // Keep the last change from being lost to the rate limit.
            guard !publishScheduled else { return }
            publishScheduled = true
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                self.publishScheduled = false
                self.publish(force: true)
            }
            return
        }
        lastPublish = now
        onChange(makeView(now: now))
    }

    public func view(now: Date = Date()) -> View { makeView(now: now) }

    private func makeView(now: Date) -> View {
        var working: [IngestItem] = [], waiting: [IngestItem] = [], failed: [IngestItem] = [], done: [IngestItem] = []
        for item in snapshot.queue.items {
            switch item.state {
            case .working: working.append(item)
            case .waiting: if waiting.count < 100 { waiting.append(item) }
            case .failed: failed.append(item)
            case .done: done.append(item)
            case .skipped: break
            }
        }
        return View(isRunning: running && !paused, folders: snapshot.folders, status: status,
                    working: working, waiting: waiting, failed: failed,
                    recentlyDone: Array(done.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }.prefix(30)),
                    counts: snapshot.queue.counts(now: now),
                    stabilizing: trackers.values.reduce(0) { $0 + $1.waitingCount })
    }
}
