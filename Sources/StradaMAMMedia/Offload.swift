import Foundation
import StradaMAMCore

/// Where clips are copied to before they are ingested: the offload of a camera card.
///
/// Each watched folder keeps its own name and layout under the destination, so two cards that
/// both hold `A001_C001.mov` never collide: `/Volumes/CARD_A/CLIPS/A001.mov` goes to
/// `<destination>/CARD_A/CLIPS/A001.mov`.
public struct OffloadPlan: Equatable, Sendable {
    public var sources: [String]
    public var destination: String

    public init(sources: [String], destination: String) {
        self.sources = sources.map { ($0 as NSString).standardizingPath }
        self.destination = (destination as NSString).standardizingPath
    }

    private func root(for source: String) -> String {
        destination + "/" + (source as NSString).lastPathComponent
    }

    /// Where a file from one of the watched folders is copied to; nil for a file outside them.
    public func destinationPath(for path: String) -> String? {
        // The longest matching folder wins, in case one watched folder is inside another.
        for source in sources.sorted(by: { $0.count > $1.count }) where path.hasPrefix(source + "/") {
            return root(for: source) + path.dropFirst(source.count)
        }
        return nil
    }

    /// The file on the card that a copy came from; nil for a file that is not one of our copies.
    public func sourcePath(forCopy path: String) -> String? {
        for source in sources.sorted(by: { $0.count > $1.count }) {
            let copied = root(for: source)
            if path.hasPrefix(copied + "/") { return source + path.dropFirst(copied.count) }
        }
        return nil
    }

    /// Why this plan cannot be used, if it cannot.
    public var problem: String? {
        for source in sources {
            if destination == source || destination.hasPrefix(source + "/") {
                return "The copy destination is inside \(source), which is being watched."
            }
            if source.hasPrefix(destination + "/") {
                return "\(source) is inside the copy destination."
            }
        }
        let names = sources.map { ($0 as NSString).lastPathComponent }
        if Set(names).count != names.count {
            return "Two watched folders have the same name, so their copies would be mixed together."
        }
        return nil
    }
}

/// Copies each clip off the card, checks the copy against the card, then ingests the copy —
/// so the catalogue points at storage that stays, not at a card that will be wiped.
///
/// A copy counts only once it has been read back and its checksum matches what was read from
/// the card. Files that belong with a clip (Blackmagic `.sidecar`, RED `.RMD`, `.xmp`, `.cdl`)
/// are copied with it. Every verified file is added to a checksum list beside the copies.
///
/// A clip that is already on storage is not copied again: if a file with the same content is
/// found in the destination, or is already catalogued somewhere that is still mounted, that file
/// is used and only its proxy is made. "The same content" is checked in full, not by name.
public struct OffloadingIngestWorker: IngestWorker {
    public var base: LibraryIngestWorker
    public var plan: OffloadPlan
    /// What this worker has copied and what it found already on storage.
    public let tally = OffloadTally()

    public init(base: LibraryIngestWorker, plan: OffloadPlan) {
        self.base = base
        self.plan = plan
    }

    public func process(path: String, report: @escaping @Sendable (String, Double?) -> Void) async throws -> IngestOutcome {
        guard let target = plan.destinationPath(for: path) else {
            return try await base.process(path: path, report: report)
        }
        report("Checking storage for this clip", nil)
        if let existing = await existingCopy(of: path, expectedAt: target) {
            if existing == target {
                // Our own earlier copy: make sure the files that belong with it came across too.
                try await copy(path, to: target, report: report)
            }
            tally.found(card: path, at: existing)
            var outcome = try await base.process(path: existing, report: report)
            if outcome.note == nil { outcome.note = "Already on storage, so it was not copied again." }
            return outcome
        }
        try await copy(path, to: target, report: report)
        tally.copied(path)
        return try await base.process(path: target, report: report)
    }

    /// A file on storage with exactly the content of the card file, if there is one.
    private func existingCopy(of source: String, expectedAt target: String) async -> String? {
        let plan = self.plan, tally = self.tally
        let catalogued = (try? base.cataloguedSizes()) ?? [:]
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // Reading whole files blocks, so it has a thread of its own.
            DispatchQueue.global(qos: .userInitiated).async {
                let size = Self.size(of: source)
                guard size > 0 else { return continuation.resume(returning: nil) }
                var candidates = [target]
                candidates += catalogued.filter { $0.value == size }.map(\.key).sorted()
                candidates += tally.filesOnStorage(under: plan.destination)[size] ?? []
                let onCard: (String) -> Bool = { path in plan.sources.contains { path == $0 || path.hasPrefix($0 + "/") } }
                var seen: Set<String> = []
                var fingerprint: String?, checksum: String?
                for candidate in candidates where seen.insert(candidate).inserted && !onCard(candidate) {
                    guard FileManager.default.fileExists(atPath: candidate), Self.size(of: candidate) == size else { continue }
                    // A quick look at both ends first; the full read only for a likely match.
                    if fingerprint == nil { fingerprint = SourceFingerprint.compute(path: source) }
                    guard let fingerprint, SourceFingerprint.compute(path: candidate) == fingerprint else { continue }
                    if checksum == nil { checksum = try? SequencePackageExporter.checksum(ofFileAt: source) }
                    guard let checksum, (try? SequencePackageExporter.checksum(ofFileAt: candidate)) == checksum else { continue }
                    return continuation.resume(returning: candidate)
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private func copy(_ source: String, to target: String,
                      report: @escaping @Sendable (String, Double?) -> Void) async throws {
        var files = [(source, target)]
        let stem = (source as NSString).deletingPathExtension, targetStem = (target as NSString).deletingPathExtension
        for ext in SequencePackagePlan.sidecarExtensions {
            for candidate in [ext, ext.uppercased()] where FileManager.default.fileExists(atPath: stem + "." + candidate) {
                if !files.contains(where: { $0.0.lowercased() == (stem + "." + candidate).lowercased() }) {
                    files.append((stem + "." + candidate, targetStem + "." + candidate))
                }
            }
        }
        let plan = self.plan
        let work = files
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // File copying blocks, so it has a thread of its own.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let total = work.reduce(Int64(0)) { $0 + Self.size(of: $1.0) } * 2  // written, then read back
                    var done: Int64 = 0
                    for (from, to) in work {
                        if Self.isVerifiedCopy(of: from, at: to) {
                            done += Self.size(of: from) * 2
                            continue
                        }
                        let checksum = try SequencePackageExporter.copyAndVerify(from: from, to: to) { bytes in
                            done += bytes
                            report("Copying", total > 0 ? min(Double(done) / Double(total), 1) : nil)
                        }
                        Self.record(checksum, for: to, plan: plan)
                    }
                })
            }
        }
    }

    private static func size(of path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// True when the destination already holds a copy with the card file's size and checksum,
    /// e.g. after a run that was interrupted between copying and cataloguing.
    private static func isVerifiedCopy(of source: String, at target: String) -> Bool {
        guard FileManager.default.fileExists(atPath: target), size(of: source) == size(of: target),
              let original = try? SequencePackageExporter.checksum(ofFileAt: source),
              let copy = try? SequencePackageExporter.checksum(ofFileAt: target) else { return false }
        return original == copy
    }

    private static let listLock = NSLock()

    /// Adds a line to `checksums.<algorithm>` at the top of the card's copy, in the usual
    /// "checksum  relative/path" form that `shasum -c` reads.
    private static func record(_ checksum: String, for copy: String, plan: OffloadPlan) {
        guard let source = plan.sourcePath(forCopy: copy), let cardRoot = plan.destinationPath(for: source),
              let folder = plan.sources.first(where: { source.hasPrefix($0 + "/") }) else { return }
        let top = String(cardRoot.dropLast(source.count - folder.count))
        let relative = String(copy.dropFirst(top.count + 1))
        let line = Data("\(checksum)  \(relative)\n".utf8)
        let list = top + "/checksums." + SequencePackageExporter.checksumAlgorithm
        listLock.lock()
        defer { listLock.unlock() }
        if let handle = FileHandle(forWritingAtPath: list) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: URL(fileURLWithPath: list))
        }
    }

    /// The engine asks what is already catalogued so it does not take a card file twice. The
    /// catalogue knows the copies, so each is reported under its card path as well.
    public func cataloguedSizes() throws -> [String: Int64] {
        var sizes = try base.cataloguedSizes()
        for (path, size) in sizes {
            if let source = plan.sourcePath(forCopy: path) { sizes[source] = size }
        }
        // Card files whose content was found elsewhere on storage count as catalogued too.
        for (card, existing) in tally.matches {
            if let size = sizes[existing] { sizes[card] = size }
        }
        return sizes
    }

    public func pathsNeedingProxies(among paths: [String]) -> [String] {
        var cardPath: [String: String] = [:]
        let matches = tally.matches
        for path in paths { cardPath[matches[path] ?? plan.destinationPath(for: path) ?? path] = path }
        return base.pathsNeedingProxies(among: Array(cardPath.keys)).compactMap { cardPath[$0] }
    }

    public func filter() -> IngestFilter {
        var filter = base.filter()
        filter.ignoredRoots.append(plan.destination)
        return filter
    }
}

/// Counts what an offload copied and what it found already on storage, and remembers which
/// file on storage stands for which file on the card.
public final class OffloadTally: @unchecked Sendable {
    private let lock = NSLock()
    private var copiedPaths: Set<String> = []
    private var found: [String: String] = [:]
    private var index: [Int64: [String]]?

    public init() {}

    public var copied: Int { lock.withLock { copiedPaths.count } }
    public var alreadyOnStorage: Int { lock.withLock { found.count } }
    /// Card path to the file on storage that holds the same content.
    public var matches: [String: String] { lock.withLock { found } }

    func copied(_ card: String) { lock.withLock { _ = copiedPaths.insert(card) } }
    func found(card: String, at path: String) { lock.withLock { found[card] = path } }

    /// Every file under the destination by size, listed once: the shortlist for finding a clip
    /// that was copied by hand into a folder of another name.
    func filesOnStorage(under folder: String) -> [Int64: [String]] {
        lock.lock()
        defer { lock.unlock() }
        if let index { return index }
        var built: [Int64: [String]] = [:]
        // Paths are built from the folder as it was given: a file URL can come back with another
        // spelling of the same place (/private/var for /var), and the catalogue must not hold both.
        if let walker = FileManager.default.enumerator(atPath: folder) {
            for case let relative as String in walker {
                if (relative as NSString).lastPathComponent.hasPrefix(".") {
                    walker.skipDescendants()
                    continue
                }
                guard walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                      let size = (walker.fileAttributes?[.size] as? NSNumber)?.int64Value, size > 0 else { continue }
                built[size, default: []].append(folder + "/" + relative)
            }
        }
        index = built
        return built
    }
}
