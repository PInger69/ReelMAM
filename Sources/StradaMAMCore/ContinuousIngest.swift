import Foundation
import GRDB

// Logic behind continuous ingest: which files are new, when a file has stopped growing, and
// the queue of work that survives a quit or a reboot. No UI, no FFmpeg; the engine in
// StradaMAMMedia drives these types and the app only shows them.

/// A folder, volume or mounted share the app keeps an eye on.
public struct WatchFolder: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var path: String
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, path: String, isEnabled: Bool = true) {
        self.id = id
        self.path = path
        self.isEnabled = isEnabled
    }

    public var displayName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// What a file looked like when it was last seen. Two equal stamps a while apart mean nobody is writing to it.
public struct FileStamp: Codable, Hashable, Sendable {
    public var size: Int64
    /// Modification time in seconds since 1970.
    public var modified: Double

    public init(size: Int64, modified: Double) {
        self.size = size
        self.modified = modified
    }
}

// MARK: Which files count

/// Decides which files a scan looks at.
public struct IngestFilter: Sendable {
    /// Folders the app writes to itself (proxies, thumbnails, marked copies). Nothing under them is ingested.
    public var ignoredRoots: [String]
    /// Folder names to skip anywhere, e.g. `Proxy` when proxies are written beside their sources.
    public var ignoredFolderNames: Set<String>

    public init(ignoredRoots: [String] = [], ignoredFolderNames: Set<String> = []) {
        self.ignoredRoots = ignoredRoots.map { Self.normalized($0) }
        self.ignoredFolderNames = ignoredFolderNames
    }

    private static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Extensions a camera card or a copy tool leaves behind while a file is still being written.
    private static let temporaryExtensions: Set<String> = ["part", "partial", "tmp", "temp", "crdownload", "download", "filepart", "copying"]

    /// Hidden files, macOS resource forks (`._name`), `.DS_Store` and anything still marked partial or temporary.
    public static func isIgnoredFileName(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let lower = name.lowercased()
        if lower.contains(".partial") { return true }
        return temporaryExtensions.contains((lower as NSString).pathExtension)
    }

    public func isIgnoredFolder(path: String, name: String) -> Bool {
        if name.hasPrefix(".") || ignoredFolderNames.contains(name) { return true }
        return isInsideIgnoredRoot(path)
    }

    public func isInsideIgnoredRoot(_ path: String) -> Bool {
        let p = Self.normalized(path)
        return ignoredRoots.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// True for a file the app should consider importing.
    public func accepts(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !Self.isIgnoredFileName(name),
              FormatIdentity.importableExtensions.contains((name as NSString).pathExtension.lowercased()),
              !isInsideIgnoredRoot(path) else { return false }
        return !(path as NSString).deletingLastPathComponent.split(separator: "/").contains { ignoredFolderNames.contains(String($0)) }
    }
}

// MARK: Looking at a folder

public enum FolderScanner {
    public enum Result: Sendable {
        /// The folder could not be read: unmounted, disconnected or gone. Not an error to report.
        case unreachable
        case files([String: FileStamp])
    }

    /// Every importable file under a folder with its size and modification time.
    public static func scan(_ root: String, filter: IngestFilter) -> Result {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? FileManager.default.contentsOfDirectory(atPath: root)) != nil else { return .unreachable }
        if filter.isInsideIgnoredRoot(root) { return .files([:]) }
        // Paths are built from the folder as given, the way `MediaLibrary.mediaFiles` does, so they
        // match what the catalogue stores even when the folder is reached through a symlink.
        guard let walker = FileManager.default.enumerator(atPath: root) else { return .unreachable }
        var found: [String: FileStamp] = [:]
        while let relative = walker.nextObject() as? String {
            let path = root + "/" + relative
            let name = (relative as NSString).lastPathComponent
            let attributes = walker.fileAttributes
            if attributes?[.type] as? FileAttributeType == .typeDirectory {
                if filter.isIgnoredFolder(path: path, name: name) { walker.skipDescendants() }
                continue
            }
            guard filter.accepts(path: path) else { continue }
            found[path] = FileStamp(size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                                    modified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        }
        return .files(found)
    }

    public static func stamp(of path: String) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) != .typeDirectory else { return nil }
        return FileStamp(size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                         modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }
}

// MARK: Telling new from known

public enum ScanDiff {
    /// Files in a listing that still need to be ingested: not catalogued at their current size
    /// and not already in the queue (waiting, working, done, failed or skipped) at that size.
    /// A file whose size differs from the catalogued or queued one has changed and comes back.
    public static func candidates(listing: [String: FileStamp], catalogued: [String: Int64],
                                  queued: [String: Int64]) -> [String: FileStamp] {
        listing.filter { path, stamp in
            if catalogued[path] == stamp.size { return false }
            if queued[path] == stamp.size { return false }
            return true
        }
    }
}

/// Holds back files that are still being written. A file is stable once its size and
/// modification time have not changed for `period`.
public struct StabilityTracker: Sendable {
    public var period: TimeInterval
    private struct Entry: Sendable { var stamp: FileStamp; var since: Date }
    private var entries: [String: Entry] = [:]

    public init(period: TimeInterval = 30) { self.period = period }

    /// How many files are being watched for the end of a copy.
    public var waitingCount: Int { entries.count }
    public var waitingPaths: [String] { Array(entries.keys) }

    /// Records the current state of every file that is a candidate. Files that are no longer
    /// listed are forgotten. Returns the ones that have been unchanged for the whole period; they
    /// are removed from the tracker, so each is returned once.
    public mutating func observe(_ files: [String: FileStamp], now: Date) -> [String] {
        entries = entries.filter { files[$0.key] != nil }
        var stable: [String] = []
        for (path, stamp) in files {
            if let entry = entries[path], entry.stamp == stamp {
                if now.timeIntervalSince(entry.since) >= period {
                    stable.append(path)
                    entries[path] = nil
                }
            } else {
                entries[path] = Entry(stamp: stamp, since: now)
            }
        }
        return stable.sorted()
    }

    /// Looks again at only the files already being waited on (a cheap check between full scans).
    public mutating func recheck(now: Date, stampOf: (String) -> FileStamp?) -> [String] {
        var current: [String: FileStamp] = [:]
        for path in entries.keys { if let stamp = stampOf(path) { current[path] = stamp } }
        return observe(current, now: now)
    }

    public mutating func forget(_ path: String) { entries[path] = nil }
    public mutating func removeAll() { entries.removeAll() }
}

// MARK: The queue

public enum IngestState: String, Codable, Sendable {
    case waiting, working, done, failed
    /// Looked at and deliberately left alone, e.g. one of the app's own proxies.
    case skipped
}

public struct IngestItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var path: String
    public var folderID: String?
    public var size: Int64
    public var state: IngestState
    /// What it is doing now, e.g. "Rendering remote proxy".
    public var stage: String?
    public var progress: Double?
    /// Why it failed, or why it was skipped.
    public var reason: String?
    /// Set when the volume holding the file is not available. The item waits for it to come back.
    public var isWaitingForVolume: Bool
    public var attempts: Int
    public var addedAt: Date
    public var finishedAt: Date?
    public var assetID: String?

    public init(id: String = UUID().uuidString, path: String, folderID: String? = nil, size: Int64,
                addedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.folderID = folderID
        self.size = size
        self.state = .waiting
        self.isWaitingForVolume = false
        self.attempts = 0
        self.addedAt = addedAt
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

public struct IngestCounts: Equatable, Sendable {
    public var waiting = 0
    public var waitingForVolume = 0
    public var working = 0
    public var failed = 0
    public var doneToday = 0
    public var failedToday = 0
    public var skipped = 0
    public init() {}
}

/// What has been seen, what is waiting, what is being made and what failed. Codable so it is
/// written to disk and read back on launch. Lookups by id and path are indexed, because a new
/// card offload can put tens of thousands of clips in the queue at once.
public struct IngestQueue: Codable, Sendable {
    public private(set) var items: [IngestItem] = []
    private var idIndex: [String: Int] = [:]
    private var pathIndex: [String: Int] = [:]
    /// Everything before this position is finished, so the next waiting item is not before it.
    private var cursor = 0

    public init() {}

    private enum CodingKeys: String, CodingKey { case items }

    public init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: CodingKeys.self).decode([IngestItem].self, forKey: .items)
        reindex()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
    }

    private mutating func reindex() {
        idIndex.removeAll(keepingCapacity: true)
        pathIndex.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() {
            idIndex[item.id] = index
            pathIndex[item.path] = index
        }
        cursor = 0
    }

    public func item(id: String) -> IngestItem? { idIndex[id].map { items[$0] } }
    public func item(path: String) -> IngestItem? { pathIndex[path].map { items[$0] } }

    /// Size recorded for every path in the queue, for `ScanDiff`. Skipped, failed, waiting and done all count.
    public var sizesByPath: [String: Int64] {
        Dictionary(items.map { ($0.path, $0.size) }, uniquingKeysWith: { _, last in last })
    }

    /// Adds a file. A path that is already waiting or working is left alone; one that finished,
    /// failed or was skipped, or is asked for again, starts over.
    @discardableResult
    public mutating func enqueue(path: String, size: Int64, folderID: String?, now: Date = Date()) -> IngestItem? {
        if let index = pathIndex[path] {
            switch items[index].state {
            case .waiting, .working:
                items[index].size = size
                return nil
            case .done, .failed, .skipped:
                items.remove(at: index)
                reindex()
            }
        }
        let item = IngestItem(path: path, folderID: folderID, size: size, addedAt: now)
        items.append(item)
        idIndex[item.id] = items.count - 1
        pathIndex[path] = items.count - 1
        return item
    }

    /// The oldest waiting item whose volume is available.
    public mutating func nextWaiting() -> IngestItem? {
        while cursor < items.count {
            let item = items[cursor]
            if item.state == .waiting && !item.isWaitingForVolume { return item }
            // Items waiting for a volume stay candidates; finished and running ones are passed for good.
            if item.state == .waiting { break }
            cursor += 1
        }
        guard cursor < items.count else { return nil }
        return items[cursor...].first { $0.state == .waiting && !$0.isWaitingForVolume }
    }

    private mutating func update(_ id: String, _ change: (inout IngestItem) -> Void) {
        guard let index = idIndex[id] else { return }
        change(&items[index])
        if index < cursor { cursor = index }
    }

    public mutating func start(_ id: String, stage: String = "Importing") {
        update(id) {
            $0.state = .working
            $0.stage = stage
            $0.progress = nil
            $0.reason = nil
            $0.attempts += 1
        }
    }

    public mutating func setStage(_ id: String, stage: String, progress: Double?) {
        update(id) { $0.stage = stage; $0.progress = progress }
    }

    public mutating func complete(_ id: String, assetID: String?, note: String? = nil, now: Date = Date()) {
        update(id) {
            $0.state = .done
            $0.stage = nil
            $0.progress = nil
            $0.reason = note
            $0.assetID = assetID
            $0.isWaitingForVolume = false
            $0.finishedAt = now
        }
    }

    public mutating func fail(_ id: String, reason: String, now: Date = Date()) {
        update(id) {
            $0.state = .failed
            $0.stage = nil
            $0.progress = nil
            $0.reason = reason
            $0.finishedAt = now
        }
    }

    public mutating func skip(_ id: String, reason: String, now: Date = Date()) {
        update(id) {
            $0.state = .skipped
            $0.stage = nil
            $0.progress = nil
            $0.reason = reason
            $0.finishedAt = now
        }
    }

    /// Puts an item back to wait for its volume. Not a failure and not counted as an attempt.
    public mutating func holdForVolume(_ id: String) {
        update(id) {
            $0.state = .waiting
            $0.isWaitingForVolume = true
            $0.stage = nil
            $0.progress = nil
            if $0.attempts > 0 { $0.attempts -= 1 }
        }
    }

    public mutating func releaseHeld(where available: (IngestItem) -> Bool) {
        for index in items.indices where items[index].isWaitingForVolume && available(items[index]) {
            items[index].isWaitingForVolume = false
        }
    }

    public mutating func retry(_ id: String) {
        update(id) {
            guard $0.state == .failed else { return }
            $0.state = .waiting
            $0.reason = nil
            $0.finishedAt = nil
        }
    }

    public mutating func retryAllFailed() {
        for item in items where item.state == .failed { retry(item.id) }
    }

    public mutating func remove(_ id: String) {
        items.removeAll { $0.id == id }
        reindex()
    }

    /// Forgets a folder's waiting, skipped and finished items (failed ones stay until dealt with).
    public mutating func remove(folderID: String) {
        items.removeAll { $0.folderID == folderID && $0.state != .failed && $0.state != .working }
        reindex()
    }

    /// After a quit or a crash nothing is really being made: whatever was working waits again.
    public mutating func recoverAfterRestart() {
        for index in items.indices where items[index].state == .working {
            items[index].state = .waiting
            items[index].stage = nil
            items[index].progress = nil
        }
        cursor = 0
    }

    /// Finished items older than `days` are dropped; the catalogue remembers those files.
    /// Failed and skipped items stay until retried or removed.
    public mutating func prune(olderThanDays days: Int = 3, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let before = items.count
        items.removeAll { $0.state == .done && ($0.finishedAt ?? now) < cutoff }
        if items.count != before { reindex() }
    }

    public func counts(now: Date = Date(), calendar: Calendar = .current) -> IngestCounts {
        let startOfDay = calendar.startOfDay(for: now)
        var counts = IngestCounts()
        for item in items {
            switch item.state {
            case .waiting:
                if item.isWaitingForVolume { counts.waitingForVolume += 1 } else { counts.waiting += 1 }
            case .working: counts.working += 1
            case .done: if let at = item.finishedAt, at >= startOfDay { counts.doneToday += 1 }
            case .failed:
                counts.failed += 1
                if let at = item.finishedAt, at >= startOfDay { counts.failedToday += 1 }
            case .skipped: counts.skipped += 1
            }
        }
        return counts
    }
}

/// Everything continuous ingest keeps on disk.
public struct IngestSnapshot: Codable, Sendable {
    public var folders: [WatchFolder] = []
    public var queue = IngestQueue()
    public init() {}
}

/// Reads and writes the snapshot as JSON, atomically, so a power cut never leaves half a file.
public struct IngestStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> IngestSnapshot {
        guard let data = try? Data(contentsOf: url) else { return IngestSnapshot() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if var snapshot = try? decoder.decode(IngestSnapshot.self, from: data) {
            snapshot.queue.recoverAfterRestart()
            return snapshot
        }
        // Unreadable: keep it for inspection and start clean rather than refusing to run.
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("damaged"))
        return IngestSnapshot()
    }

    public func save(_ snapshot: IngestSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}

/// Thrown by a worker for a file that should be left alone without counting as a failure.
public struct IngestSkipped: Error, LocalizedError, Sendable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// Thrown when the file's volume is not available; the item waits for it instead of failing.
public struct IngestVolumeOffline: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "The volume is not available." }
}

extension Catalog {
    /// `assetID|preset` for every finished proxy that matched its source when it was checked.
    public func verifiedProxyKeys() throws -> Set<String> {
        try db.read { db in
            var keys = Set<String>()
            let rows = try Row.fetchCursor(db, sql: "SELECT assetID, preset FROM proxy WHERE status = ? AND mismatch IS NULL",
                                           arguments: [ProxyStatus.ready.rawValue])
            while let row = try rows.next() { keys.insert((row["assetID"] as String) + "|" + (row["preset"] as String)) }
            return keys
        }
    }
}
