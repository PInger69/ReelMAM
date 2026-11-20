import Foundation
import StradaMAMCore

// MARK: Connection speed

/// How fast a source is connected to this Mac.
public struct LinkSpeed: Equatable, Hashable, Sendable {
    public var bitsPerSecond: Double
    /// What the connection is, e.g. "USB 3.2 Gen 2" or "Thunderbolt".
    public var name: String

    public init(bitsPerSecond: Double, name: String) {
        self.bitsPerSecond = bitsPerSecond
        self.name = name
    }

    /// Clips are copied off cards over 10 Gbps (USB 3.2 Gen 2) or faster.
    public static let recommendedBitsPerSecond: Double = 10e9

    public var isBelowRecommended: Bool { bitsPerSecond < Self.recommendedBitsPerSecond * 0.99 }

    /// A link never carries its nominal rate; this is what a long copy can expect.
    public var expectedBytesPerSecond: Double { bitsPerSecond / 8 * 0.75 }

    public var rate: String {
        bitsPerSecond >= 1e9
            ? (bitsPerSecond.truncatingRemainder(dividingBy: 1e9) == 0 ? "\(Int(bitsPerSecond / 1e9)) Gbps"
                                                                        : String(format: "%.1f Gbps", bitsPerSecond / 1e9))
            : "\(Int(bitsPerSecond / 1e6)) Mbps"
    }

    public var label: String { name + " · " + rate }

    /// The speed a USB device reports in the I/O Registry (`USBSpeed` / `Device Speed`).
    public static func usb(code: Int) -> LinkSpeed? {
        switch code {
        case 0: return LinkSpeed(bitsPerSecond: 1.5e6, name: "USB 1 Low Speed")
        case 1: return LinkSpeed(bitsPerSecond: 12e6, name: "USB 1 Full Speed")
        case 2: return LinkSpeed(bitsPerSecond: 480e6, name: "USB 2")
        case 3: return LinkSpeed(bitsPerSecond: 5e9, name: "USB 3.2 Gen 1")
        case 4: return LinkSpeed(bitsPerSecond: 10e9, name: "USB 3.2 Gen 2")
        case 5: return LinkSpeed(bitsPerSecond: 20e9, name: "USB 3.2 Gen 2x2")
        default: return nil
        }
    }

    /// A USB link given in bits per second (`UsbLinkSpeed`).
    public static func usb(bitsPerSecond: Double) -> LinkSpeed {
        let name: String
        switch bitsPerSecond {
        case ..<1e6: name = "USB 1"
        case ..<100e6: name = "USB 1 Full Speed"
        case ..<1e9: name = "USB 2"
        case ..<6e9: name = "USB 3.2 Gen 1"
        case ..<15e9: name = "USB 3.2 Gen 2"
        case ..<30e9: name = "USB 3.2 Gen 2x2"
        default: name = "USB4"
        }
        return LinkSpeed(bitsPerSecond: bitsPerSecond, name: name)
    }

    public static let thunderbolt = LinkSpeed(bitsPerSecond: 40e9, name: "Thunderbolt")
}

// MARK: What can be copied

/// Something clips are copied from: a card or drive, a folder, or an iPhone or camera on a cable.
public struct TransferSource: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A mounted volume or a folder.
        case folder(String)
        /// A device that does not mount, such as an iPhone; its clips are fetched by the app.
        case device
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// How it is connected, when that could be found out.
    public var link: LinkSpeed?
    /// True for a card in a reader or a drive on a cable, as opposed to an internal disk or a share.
    public var isExternal: Bool
    public var capacity: Int64?

    public init(id: String, name: String, kind: Kind, link: LinkSpeed? = nil, isExternal: Bool = false, capacity: Int64? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.link = link
        self.isExternal = isExternal
        self.capacity = capacity
    }

    public static func folder(_ path: String, name: String? = nil, link: LinkSpeed? = nil, isExternal: Bool = false,
                              capacity: Int64? = nil) -> TransferSource {
        let path = (path as NSString).standardizingPath
        return TransferSource(id: path, name: name ?? (path as NSString).lastPathComponent, kind: .folder(path),
                              link: link, isExternal: isExternal, capacity: capacity)
    }

    public var path: String? {
        if case .folder(let path) = kind { return path }
        return nil
    }
}

/// One clip found on a source, and what is known about it before anything is copied.
public struct TransferItem: Identifiable, Hashable, Sendable {
    public enum Origin: Hashable, Sendable {
        case file(String)
        /// A file on a device, by the name the device gives it.
        case device(String)
    }

    /// Whether this clip has been copied before.
    public enum History: Hashable, Sendable {
        case new
        /// The same content is already in the destination, at this path. Nothing needs copying.
        case atDestination(String)
        /// Copied before, to this path, on this date when it is known; that copy is not in this destination.
        case copiedBefore(Date?, String)

        public var isNew: Bool { self == .new }
    }

    public var id: String
    public var sourceID: String
    public var sourceName: String
    public var origin: Origin
    /// Where it is on its source, from the source's top.
    public var relativePath: String
    public var size: Int64
    public var date: Date?
    /// Files that belong with the clip (Blackmagic `.sidecar`, RED `.RMD`, `.xmp`, `.cdl`), copied with it.
    public var sidecars: [String]
    /// Where the copy goes; nil when nothing is copied and proxies are made where the clip is.
    public var destinationPath: String?
    public var history: History
    /// Size plus a hash of both ends; nil for clips on a device, which cannot be read before fetching.
    public var fingerprint: String?

    public var name: String { (relativePath as NSString).lastPathComponent }

    public var sourcePath: String? {
        if case .file(let path) = origin { return path }
        return nil
    }
}

// MARK: Remembering what was copied

/// Every clip this Mac has copied: what it was, where it came from and where it went. Kept beside
/// the library, so a card put in again weeks later shows which clips are already safe.
public final class CopyHistory: @unchecked Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var fingerprint: String?
        public var name: String
        public var size: Int64
        public var source: String
        public var copiedTo: String
        public var date: Date
    }

    public let url: URL?
    private let lock = NSLock()
    private var records: [Record] = []

    /// Opens the history at `url`, or keeps one in memory only when `url` is nil.
    public init(url: URL?) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([Record].self, from: data)) ?? []
    }

    public var all: [Record] { lock.withLock { records } }

    /// The latest copy of this content; for a device clip, of a file with this name and size.
    public func lookup(fingerprint: String?, name: String, size: Int64) -> Record? {
        lock.withLock {
            if let fingerprint, let match = records.last(where: { $0.fingerprint == fingerprint }) { return match }
            guard fingerprint == nil else { return nil }
            return records.last { $0.fingerprint == nil && $0.size == size && $0.name.lowercased() == name.lowercased() }
        }
    }

    public func record(_ record: Record) {
        lock.withLock {
            records.append(record)
            save()
        }
    }

    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: Looking at sources

/// Lists the clips on each source and works out, for each, whether it has been copied before.
public enum TransferPlanner {
    /// Where a clip from this source is copied to: a folder named after the source, keeping the
    /// source's own layout, so two cards that both hold `A001_C001.mov` never collide.
    public static func destinationPath(sourceName: String, relativePath: String, destination: String) -> String {
        (destination as NSString).standardizingPath + "/" + SequencePackageExporter.safeFileName(sourceName) + "/" + relativePath
    }

    /// Every clip on a folder source, with its sidecars.
    public static func scan(_ source: TransferSource, destination: String?, history: CopyHistory?, catalog: Catalog?,
                            storage: StorageIndex?) -> [TransferItem] {
        guard let root = source.path else { return [] }
        var filter = IngestFilter()
        if let destination { filter.ignoredRoots.append(destination) }
        guard case .files(let files) = FolderScanner.scan(root, filter: filter) else { return [] }
        return files.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
            let relative = String(path.dropFirst(root.count + 1))
            let stamp = files[path]!
            var item = TransferItem(id: source.id + "/" + relative, sourceID: source.id, sourceName: source.name,
                                    origin: .file(path), relativePath: relative, size: stamp.size,
                                    date: stamp.modified > 0 ? Date(timeIntervalSince1970: stamp.modified) : nil,
                                    sidecars: sidecars(of: path),
                                    destinationPath: destination.map { destinationPath(sourceName: source.name, relativePath: relative, destination: $0) },
                                    history: .new, fingerprint: SourceFingerprint.compute(path: path))
            item.history = status(of: item, history: history, catalog: catalog, storage: storage)
            return item
        }
    }

    /// The clips on a device, from the list the device gives.
    public static func deviceItems(_ source: TransferSource, files: [(name: String, size: Int64, date: Date?)],
                                   destination: String?, history: CopyHistory?) -> [TransferItem] {
        files.map { file in
            var item = TransferItem(id: source.id + "/" + file.name, sourceID: source.id, sourceName: source.name,
                                    origin: .device(file.name), relativePath: file.name, size: file.size, date: file.date,
                                    sidecars: [],
                                    destinationPath: destination.map { destinationPath(sourceName: source.name, relativePath: file.name, destination: $0) },
                                    history: .new, fingerprint: nil)
            if let target = item.destinationPath, size(of: target) == file.size {
                item.history = .atDestination(target)
            } else if let record = history?.lookup(fingerprint: nil, name: file.name, size: file.size) {
                item.history = .copiedBefore(record.date, record.copiedTo)
            }
            return item
        }
    }

    private static func status(of item: TransferItem, history: CopyHistory?, catalog: Catalog?, storage: StorageIndex?) -> TransferItem.History {
        guard let fingerprint = item.fingerprint else { return .new }
        // Already in the destination: where it would go, or anywhere else in it under any name.
        var candidates: [String] = []
        if let target = item.destinationPath { candidates.append(target) }
        candidates += storage?.files(ofSize: item.size) ?? []
        for candidate in candidates where size(of: candidate) == item.size {
            if SourceFingerprint.compute(path: candidate) == fingerprint { return .atDestination(candidate) }
        }
        if let record = history?.lookup(fingerprint: fingerprint, name: item.name, size: item.size) {
            return .copiedBefore(record.date, record.copiedTo)
        }
        // Catalogued from somewhere other than this source, e.g. copied by hand and imported.
        if let source = item.sourcePath,
           let asset = (try? catalog?.assets(withFingerprint: fingerprint))?.first(where: { $0.sourcePath != source }) {
            return .copiedBefore(nil, asset.sourcePath)
        }
        return .new
    }

    static func sidecars(of path: String) -> [String] {
        let stem = (path as NSString).deletingPathExtension
        var found: [String] = []
        for ext in SequencePackagePlan.sidecarExtensions {
            for candidate in [ext, ext.uppercased()] where FileManager.default.fileExists(atPath: stem + "." + candidate) {
                if !found.contains(where: { $0.lowercased() == (stem + "." + candidate).lowercased() }) {
                    found.append(stem + "." + candidate)
                }
            }
        }
        return found
    }

    static func size(of path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? -1
    }
}

/// Every file in a destination folder by size: the shortlist for finding a clip that is already
/// there under another name or in another folder.
public final class StorageIndex: @unchecked Sendable {
    private let bySize: [Int64: [String]]

    public init(folder: String) {
        var built: [Int64: [String]] = [:]
        let folder = (folder as NSString).standardizingPath
        if let walker = FileManager.default.enumerator(atPath: folder) {
            for case let relative as String in walker {
                if (relative as NSString).lastPathComponent.hasPrefix(".") {
                    walker.skipDescendants()
                    continue
                }
                if relative.hasSuffix(ResilientCopy.partialSuffix) { continue }
                guard walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                      let size = (walker.fileAttributes?[.size] as? NSNumber)?.int64Value, size > 0 else { continue }
                built[size, default: []].append(folder + "/" + relative)
            }
        }
        bySize = built
    }

    public func files(ofSize size: Int64) -> [String] { bySize[size] ?? [] }
}

// MARK: How long it takes

public enum TransferEstimate {
    /// Assumed read speed of the destination when each copy is read back to check it.
    public static let checkBytesPerSecond: Double = 2e9

    /// Seconds to copy and check these clips, with each source copying at once over its own link.
    /// Nil when a source's connection speed is not known.
    public static func seconds(for items: [TransferItem], sources: [TransferSource]) -> TimeInterval? {
        guard !items.isEmpty else { return 0 }
        var longest: TimeInterval = 0
        for (sourceID, clips) in Dictionary(grouping: items, by: \.sourceID) {
            guard let link = sources.first(where: { $0.id == sourceID })?.link else { return nil }
            longest = max(longest, Double(clips.reduce(Int64(0)) { $0 + $1.size }) / link.expectedBytesPerSecond)
        }
        let total = Double(items.reduce(Int64(0)) { $0 + $1.size })
        return longest + total / checkBytesPerSecond
    }

    /// "about 1 h 20 min", "about 4 min", "under a minute".
    public static func describe(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "under a minute" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "about \(minutes) min" }
        return "about \(minutes / 60) h \(minutes % 60) min"
    }
}

// MARK: Copying

/// Copies the chosen clips, checks every copy, remembers what was copied, and hands each copy to
/// the library for a proxy while the next clip is copying.
public actor TransferRunner {
    public enum Phase: Equatable, Sendable {
        case waiting
        case copying(Double)
        case checking(Double)
        /// What the library is doing with it: "Importing", "Rendering proxy"…
        case processing(String, Double?)
        case done(String?)
        case failed(String)

        public var isFinished: Bool {
            switch self {
            case .done, .failed: return true
            default: return false
            }
        }
    }

    public struct Progress: Sendable {
        public var phases: [String: Phase] = [:]
        public var bytesTotal: Int64 = 0
        /// Copy and check together: each clip counts twice, once written and once read back.
        public var workDone: Int64 = 0
        public var bytesPerSecond: Double?
        public var secondsLeft: TimeInterval?
        public var current: String?

        public var fraction: Double { bytesTotal > 0 ? min(Double(workDone) / Double(bytesTotal * 2), 1) : 0 }
        public var failed: Int { phases.values.filter { if case .failed = $0 { return true } else { return false } }.count }
        public var done: Int { phases.values.filter { if case .done = $0 { return true } else { return false } }.count }
    }

    /// Fetches a clip from a device to a path. `progress` takes the fraction fetched.
    public typealias DeviceFetch = @Sendable (TransferItem, String, @escaping @Sendable (Double) -> Void) async throws -> Void

    private let items: [TransferItem]
    private let history: CopyHistory?
    private let worker: IngestWorker?
    private let fetch: DeviceFetch?
    private let onProgress: @Sendable (Progress) -> Void
    private var copier: ResilientCopy
    private var progress = Progress()
    private var started = Date()
    private var cancelled = false
    private var lastPublished = Date.distantPast

    /// - Parameters:
    ///   - worker: imports each copy and makes its proxies; nil to copy only.
    ///   - fetch: how clips on a device are fetched.
    public init(items: [TransferItem], history: CopyHistory?, worker: IngestWorker?, copier: ResilientCopy = ResilientCopy(),
                fetch: DeviceFetch? = nil, onProgress: @escaping @Sendable (Progress) -> Void) {
        self.items = items
        self.history = history
        self.worker = worker
        self.copier = copier
        self.fetch = fetch
        self.onProgress = onProgress
        progress.bytesTotal = items.filter { $0.copiesSomething }.reduce(0) { $0 + $1.size }
        for item in items { progress.phases[item.id] = .waiting }
    }

    /// Clips being copied are finished; nothing more is started.
    public func cancel() { cancelled = true }

    /// Copies everything, one clip at a time per source and every source at once, and returns when
    /// every copy and every proxy is finished.
    public func run() async -> Progress {
        started = Date()
        publish(force: true)
        let bySource = Dictionary(grouping: items, by: \.sourceID)
        await withTaskGroup(of: Void.self) { group in
            for (_, clips) in bySource {
                group.addTask {
                    await withTaskGroup(of: Void.self) { proxies in
                        for item in clips {
                            guard await !self.isCancelled else { break }
                            guard let path = await self.copy(item) else { continue }
                            // The proxy is made while the next clip copies.
                            proxies.addTask { await self.process(item, at: path) }
                        }
                    }
                }
            }
        }
        for item in items where progress.phases[item.id] == .waiting {
            progress.phases[item.id] = .failed("Stopped before it was copied.")
        }
        progress.current = nil
        progress.secondsLeft = nil
        publish(force: true)
        return progress
    }

    private var isCancelled: Bool { cancelled }

    /// Copies one clip, or finds it is already there. Returns the path the library takes it from.
    private func copy(_ item: TransferItem) async -> String? {
        if case .atDestination(let existing) = item.history { return existing }
        guard let target = item.destinationPath else {
            // Nothing is copied: proxies are made where the clip is.
            return item.sourcePath
        }
        progress.current = item.name
        set(item, .copying(0))
        let size = max(item.size, 1)
        do {
            switch item.origin {
            case .file(let source):
                var copier = self.copier
                let id = item.id
                copier.stalled = { [weak self] message in
                    Task { await self?.note(id, message) }
                }
                let files = [(source, target)] + item.sidecars.map { sidecar in
                    (sidecar, (target as NSString).deletingPathExtension + "." + (sidecar as NSString).pathExtension)
                }
                for (from, to) in files {
                    let isClip = from == source
                    let fileCopier = copier
                    _ = try await runOffPool {
                        var itemDone: Int64 = 0
                        return try fileCopier.copy(from: from, to: to) { bytes in
                            guard isClip else { return }
                            itemDone += bytes
                            let done = itemDone
                            Task { await self.advance(id, bytes: bytes, done: done, size: size) }
                        }
                    }
                }
            case .device:
                guard let fetch else { throw PackageError.cannotWrite("Clips on \(item.sourceName) cannot be fetched here.") }
                let id = item.id
                try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try await fetch(item, target) { fraction in
                    let bytes = Int64(Double(size) * fraction)
                    Task { await self.advanceFetch(id, to: bytes, size: size) }
                }
                guard TransferPlanner.size(of: target) == item.size else {
                    try? FileManager.default.removeItem(atPath: target)
                    throw PackageError.cannotWrite("\(item.name) arrived incomplete from \(item.sourceName) and was removed.")
                }
                advanceFetch(id, to: item.size, size: size)
                set(item, .checking(0))
                // A fetched clip is read back once, so a copy that cannot be read is caught now.
                _ = try await runOffPool { try SequencePackageExporter.checksum(ofFileAt: target) }
                progress.workDone += item.size
            }
        } catch is IngestVolumeOffline {
            set(item, .failed("\(item.sourceName) was disconnected. Connect it again and copy the failed clips."))
            return nil
        } catch {
            set(item, .failed(error.localizedDescription))
            return nil
        }
        history?.record(.init(fingerprint: item.fingerprint, name: item.name, size: item.size, source: item.sourceName,
                              copiedTo: target, date: Date()))
        return target
    }

    private func process(_ item: TransferItem, at path: String) async {
        guard let worker else {
            set(item, .done(item.copiesSomething ? nil : "Already in the destination."))
            return
        }
        set(item, .processing("Adding to library", nil))
        let id = item.id
        do {
            let outcome = try await worker.process(path: path) { stage, fraction in
                Task { await self.stage(id, stage, fraction) }
            }
            var note = outcome.note
            if note == nil, !item.copiesSomething, item.destinationPath != nil { note = "Already in the destination, not copied again." }
            set(item, .done(note))
        } catch let skipped as IngestSkipped {
            set(item, .done(skipped.reason))
        } catch {
            set(item, .failed("Copied and checked, but " + error.localizedDescription.prefix(1).lowercased()
                              + error.localizedDescription.dropFirst()))
        }
    }

    // MARK: Progress

    private func set(_ item: TransferItem, _ phase: Phase) {
        progress.phases[item.id] = phase
        publish(force: phase.isFinished)
    }

    private func note(_ id: String, _ message: String) {
        progress.current = message
        publish(force: true)
    }

    private func stage(_ id: String, _ stage: String, _ fraction: Double?) {
        guard progress.phases[id]?.isFinished == false else { return }
        progress.phases[id] = .processing(stage, fraction)
        publish()
    }

    private func advance(_ id: String, bytes: Int64, done: Int64, size: Int64) {
        progress.workDone += bytes
        // Updates can arrive late; one never takes a clip back from a later stage.
        if isCopyingOrChecking(id) {
            progress.phases[id] = done <= size ? .copying(Double(done) / Double(size)) : .checking(Double(done - size) / Double(size))
        }
        publish()
    }

    private func isCopyingOrChecking(_ id: String) -> Bool {
        switch progress.phases[id] {
        case .copying, .checking: return true
        default: return false
        }
    }

    private var fetched: [String: Int64] = [:]

    private func advanceFetch(_ id: String, to bytes: Int64, size: Int64) {
        let before = fetched[id] ?? 0
        guard bytes > before else { return }
        fetched[id] = bytes
        progress.workDone += bytes - before
        if isCopyingOrChecking(id) { progress.phases[id] = .copying(Double(bytes) / Double(size)) }
        publish()
    }

    private func publish(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublished) > 0.25 else { return }
        lastPublished = now
        let elapsed = now.timeIntervalSince(started)
        if elapsed > 2, progress.workDone > 0 {
            let rate = Double(progress.workDone) / elapsed
            progress.bytesPerSecond = rate / 2  // work counts each byte twice
            let left = Double(progress.bytesTotal * 2 - progress.workDone)
            progress.secondsLeft = max(left / rate, 0)
        }
        onProgress(progress)
    }

    private func runOffPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            // Copying blocks, so it has a thread of its own rather than one of Swift's few shared ones.
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }
}

extension TransferItem {
    /// True when running it copies bytes, not just makes a proxy of something already in place.
    public var copiesSomething: Bool {
        if case .atDestination = history { return false }
        return destinationPath != nil
    }
}
