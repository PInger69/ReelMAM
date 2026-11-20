import Foundation
import GRDB

/// A bin: a named place to gather clips. Bins nest. A bin with a `smartQuery` fills itself
/// with whatever matches that search, and stays up to date as clips are added or analysed.
public struct Bin: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "bin"
    public var id: String
    public var name: String
    public var parentID: String?
    /// Search text for a smart bin; nil for an ordinary bin that holds what is put in it.
    public var smartQuery: String?
    public var sortIndex: Int
    public var createdAt: Date

    public init(id: String = newID(), name: String, parentID: String? = nil, smartQuery: String? = nil,
                sortIndex: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.smartQuery = smartQuery
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }

    public var isSmart: Bool { smartQuery != nil }
}

/// A bin with its nested bins, ready to show as an outline.
public struct BinNode: Identifiable, Hashable, Sendable {
    public var bin: Bin
    public var children: [BinNode]?
    public var id: String { bin.id }

    /// Arranges a flat list of bins into a tree, ordered by position then name.
    public static func tree(from bins: [Bin]) -> [BinNode] {
        let byParent = Dictionary(grouping: bins, by: { $0.parentID ?? "" })
        let known = Set(bins.map(\.id))
        func nodes(under parent: String) -> [BinNode] {
            (byParent[parent] ?? [])
                .sorted { ($0.sortIndex, $0.name.lowercased()) < ($1.sortIndex, $1.name.lowercased()) }
                .map { bin in
                    let children = nodes(under: bin.id)
                    return BinNode(bin: bin, children: children.isEmpty ? nil : children)
                }
        }
        // A bin whose parent has gone missing is shown at the top level rather than lost.
        let orphans = bins.filter { $0.parentID.map { !known.contains($0) } ?? false }
            .map { BinNode(bin: $0, children: nil) }
        return nodes(under: "") + orphans
    }
}

extension Catalog {
    public func bins() throws -> [Bin] {
        try db.read { try Bin.fetchAll($0) }
    }

    public func save(_ bin: Bin) throws {
        try db.write { try bin.save($0) }
    }

    /// Deletes a bin and the bins inside it. The clips themselves are untouched.
    public func deleteBin(id: String) throws {
        try db.write { _ = try Bin.deleteOne($0, key: id) }
    }

    public func add(assetIDs: [String], toBin binID: String) throws {
        try db.write { db in
            for assetID in assetIDs {
                try db.execute(sql: "INSERT OR IGNORE INTO binItem (binID, assetID, addedAt) VALUES (?, ?, ?)",
                               arguments: [binID, assetID, Date()])
            }
        }
    }

    public func remove(assetIDs: [String], fromBin binID: String) throws {
        try db.write { db in
            for assetID in assetIDs {
                try db.execute(sql: "DELETE FROM binItem WHERE binID = ? AND assetID = ?", arguments: [binID, assetID])
            }
        }
    }

    /// The clips a bin shows: for a smart bin, everything matching its search; otherwise the
    /// clips placed in it and in the bins nested inside it.
    public func assetIDs(inBin binID: String) throws -> Set<String> {
        let all = try bins()
        guard let bin = all.first(where: { $0.id == binID }) else { return [] }
        if let query = bin.smartQuery {
            return Set(try search(query, limit: 5000).map(\.assetID))
        }
        var ids = [binID]
        var frontier = [binID]
        while !frontier.isEmpty {
            let children = all.filter { $0.parentID.map(frontier.contains) ?? false }.map(\.id)
            ids += children
            frontier = children
        }
        var result = try db.read { db in
            try String.fetchSet(db, sql: "SELECT assetID FROM binItem WHERE binID IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                                arguments: StatementArguments(ids))
        }
        // Smart bins nested inside contribute their matches too.
        for nested in all where ids.contains(nested.id) && nested.id != binID {
            if let query = nested.smartQuery { result.formUnion(try search(query, limit: 5000).map(\.assetID)) }
        }
        return result
    }

    /// How many clips each bin shows, for the sidebar.
    public func binCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for bin in try bins() { counts[bin.id] = try assetIDs(inBin: bin.id).count }
        return counts
    }

    /// The ordinary bins a clip has been placed in.
    public func binIDs(containing assetID: String) throws -> Set<String> {
        try db.read { try String.fetchSet($0, sql: "SELECT binID FROM binItem WHERE assetID = ?", arguments: [assetID]) }
    }
}

// MARK: Sorting and grouping

public enum LibrarySort: String, CaseIterable, Codable, Sendable {
    case imported, name, captured, duration, rating, size

    public var displayName: String {
        switch self {
        case .imported: return "Date Imported"
        case .name: return "Name"
        case .captured: return "Date Shot"
        case .duration: return "Duration"
        case .rating: return "Rating"
        case .size: return "Size"
        }
    }

    public func sorted(_ assets: [Asset]) -> [Asset] {
        func byName(_ a: Asset, _ b: Asset) -> Bool {
            a.fileName.compare(b.fileName, options: [.caseInsensitive, .numeric]) == .orderedAscending
        }
        switch self {
        case .name: return assets.sorted(by: byName)
        case .imported: return assets.sorted { $0.importedAt == $1.importedAt ? byName($0, $1) : $0.importedAt > $1.importedAt }
        case .captured:
            return assets.sorted {
                let a = $0.capturedAt ?? .distantPast, b = $1.capturedAt ?? .distantPast
                return a == b ? byName($0, $1) : a > b
            }
        case .duration: return assets.sorted { $0.durationSeconds == $1.durationSeconds ? byName($0, $1) : $0.durationSeconds > $1.durationSeconds }
        case .rating: return assets.sorted { $0.rating == $1.rating ? byName($0, $1) : $0.rating > $1.rating }
        case .size: return assets.sorted { $0.fileSize == $1.fileSize ? byName($0, $1) : $0.fileSize > $1.fileSize }
        }
    }
}

public enum LibraryGrouping: String, CaseIterable, Codable, Sendable {
    case none, volume, folder, reel, day, format

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .volume: return "Volume"
        case .folder: return "Folder"
        case .reel: return "Reel"
        case .day: return "Day Shot"
        case .format: return "Format"
        }
    }

    public struct Group: Identifiable, Sendable {
        public var title: String
        public var assets: [Asset]
        public var id: String { title }
    }

    /// Splits clips (already in display order) into titled groups, keeping that order inside each.
    public func groups(_ assets: [Asset], calendar: Calendar = .current) -> [Group] {
        guard self != .none else { return assets.isEmpty ? [] : [Group(title: "", assets: assets)] }
        var order: [String] = []
        var buckets: [String: [Asset]] = [:]
        for asset in assets {
            let key = title(for: asset, calendar: calendar)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(asset)
        }
        let titles = self == .day ? order : order.sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending }
        return titles.map { Group(title: $0, assets: buckets[$0] ?? []) }
    }

    private func title(for asset: Asset, calendar: Calendar) -> String {
        switch self {
        case .none: return ""
        case .volume: return asset.volumeName ?? "This Mac"
        case .folder: return (asset.sourcePath as NSString).deletingLastPathComponent
        case .reel: return asset.reelName ?? "No reel"
        case .format:
            return [asset.resolutionClass, asset.height > 0 ? asset.pictureFormatName : nil, asset.formatName]
                .compactMap { $0 }.filter { !$0.isEmpty && $0 != "Unknown" }.joined(separator: " · ")
        case .day:
            guard let date = asset.capturedAt else { return "Unknown date" }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
    }
}

// MARK: Paths on other computers

/// The same storage seen from two computers: a Mac path prefix and where an editor's
/// computer mounts it (a Windows drive letter, a Linux mount point, or another Mac path).
public struct PathMapping: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// As seen on this Mac, e.g. `/Volumes/Media`.
    public var macPrefix: String
    /// As seen by the editor, e.g. `Z:\Media`, `/mnt/media` or `\\server\media`.
    public var editorPrefix: String

    public init(id: String = newID(), macPrefix: String, editorPrefix: String) {
        self.id = id
        self.macPrefix = macPrefix
        self.editorPrefix = editorPrefix
    }

    private static func trimmed(_ prefix: String) -> String {
        var value = prefix.trimmingCharacters(in: .whitespaces)
        while value.count > 1, value.hasSuffix("/") || value.hasSuffix("\\") { value.removeLast() }
        return value
    }

    /// The editor's prefix as a forward-slash path usable in a file URL:
    /// `Z:\Media` → `/Z:/Media`, `\\server\share` → `//server/share`.
    var editorURLPrefix: String {
        let slashed = Self.trimmed(editorPrefix).replacingOccurrences(of: "\\", with: "/")
        if slashed.count >= 2, slashed[slashed.index(after: slashed.startIndex)] == ":" { return "/" + slashed }
        return slashed
    }

    /// Rewrites a path on this Mac to where the editor's computer sees it.
    public static func toEditor(_ macPath: String, using mappings: [PathMapping]) -> String {
        for mapping in mappings.sorted(by: { $0.macPrefix.count > $1.macPrefix.count }) {
            let prefix = trimmed(mapping.macPrefix)
            guard !prefix.isEmpty, macPath == prefix || macPath.hasPrefix(prefix + "/") else { continue }
            return mapping.editorURLPrefix + macPath.dropFirst(prefix.count)
        }
        return macPath
    }

    /// Rewrites a path from the editor's computer (as read from a timeline) to this Mac.
    public static func toMac(_ editorPath: String, using mappings: [PathMapping]) -> String {
        let normalized = editorPath.replacingOccurrences(of: "\\", with: "/")
        for mapping in mappings.sorted(by: { $0.editorPrefix.count > $1.editorPrefix.count }) {
            let prefix = mapping.editorURLPrefix
            guard !prefix.isEmpty else { continue }
            for candidate in [prefix, String(prefix.dropFirst(prefix.hasPrefix("/") && prefix.contains(":") ? 1 : 0))] {
                if normalized.lowercased() == candidate.lowercased()
                    || normalized.lowercased().hasPrefix(candidate.lowercased() + "/") {
                    return trimmed(mapping.macPrefix) + normalized.dropFirst(candidate.count)
                }
            }
        }
        return editorPath
    }
}

/// Finds where a network or external volume's files are now, when the volume has been
/// mounted under a different name (`/Volumes/Media-1`) or on a different mount point.
public enum VolumeRemapper {
    /// For a path under `<volumesRoot>/<volume>/…`, the same relative path on every other
    /// mounted volume.
    public static func candidates(for path: String, volumesRoot: String, mountedVolumes: [String]) -> [String] {
        let root = volumesRoot.hasSuffix("/") ? String(volumesRoot.dropLast()) : volumesRoot
        guard path.hasPrefix(root + "/") else { return [] }
        let parts = path.dropFirst(root.count + 1).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return [] }
        let volume = String(parts[0]), relative = String(parts[1])
        // Volumes whose name resembles the original (Media, Media-1, Media 2) are tried first.
        let others = mountedVolumes.filter { $0 != volume }.sorted { a, b in
            let aLike = a.hasPrefix(volume) || volume.hasPrefix(a), bLike = b.hasPrefix(volume) || volume.hasPrefix(b)
            return aLike == bLike ? a < b : aLike
        }
        return others.map { "\(root)/\($0)/\(relative)" }
    }
}
