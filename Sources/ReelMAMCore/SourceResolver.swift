import Foundation
import GRDB

/// Everything known about a file that might be a proxy (or a reference to one in a timeline).
public struct MediaClue: Hashable, Sendable {
    public var path: String?
    public var fileName: String?
    public var reelName: String?
    /// Asset ID read from the proxy's embedded metadata.
    public var embeddedAssetID: String?
    public var startTimecodeFrames: Int?
    public var durationFrames: Int?

    public init(path: String? = nil, fileName: String? = nil, reelName: String? = nil,
                embeddedAssetID: String? = nil, startTimecodeFrames: Int? = nil, durationFrames: Int? = nil) {
        self.path = path
        self.fileName = fileName ?? path.map { ($0 as NSString).lastPathComponent }
        self.reelName = reelName
        self.embeddedAssetID = embeddedAssetID
        self.startTimecodeFrames = startTimecodeFrames
        self.durationFrames = durationFrames
    }
}

public enum SourceResolution: Hashable, Sendable {
    public enum Evidence: String, Sendable {
        case embeddedID, proxyPath, sourcePath, proxyFileName, fileName, reelName
    }
    case found(Asset, Evidence)
    /// Several sources share the name and nothing else narrowed it down.
    case ambiguous([Asset])
    case notFound

    public var asset: Asset? {
        if case .found(let asset, _) = self { return asset }
        return nil
    }

    public var evidence: Evidence? {
        if case .found(_, let evidence) = self { return evidence }
        return nil
    }
}

/// Finds the high-resolution source behind a proxy, no matter where the proxy has been.
///
/// Evidence is tried strongest first: the asset ID embedded in the proxy file, the catalogued
/// proxy path, then file-name matching disambiguated by start timecode and duration.
public struct SourceResolver: Sendable {
    public let catalog: Catalog

    public init(catalog: Catalog) {
        self.catalog = catalog
    }

    public func resolve(_ clue: MediaClue) throws -> SourceResolution {
        try catalog.db.read { db in
            if let id = clue.embeddedAssetID, let asset = try Asset.fetchOne(db, key: id) {
                return .found(asset, .embeddedID)
            }
            if let path = clue.path {
                if let proxy = try ProxyRecord.filter(Column("path") == path).fetchOne(db),
                   let asset = try Asset.fetchOne(db, key: proxy.assetID) {
                    return .found(asset, .proxyPath)
                }
                if let asset = try Asset.filter(Column("sourcePath") == path).fetchOne(db) {
                    return .found(asset, .sourcePath)
                }
            }
            if let fileName = clue.fileName {
                let proxies = try ProxyRecord.filter(Column("fileName").collating(.nocase) == fileName).fetchAll(db)
                let owners = Set(proxies.map(\.assetID))
                if owners.count == 1, let asset = try Asset.fetchOne(db, key: owners.first!) {
                    return .found(asset, .proxyFileName)
                }
                let key = ProxyNaming.matchKey(forFileName: fileName)
                let candidates = try Asset.filter(Column("fileName").like("\(key.likeEscaped)%", escape: "\\"))
                    .fetchAll(db)
                    .filter { ProxyNaming.matchKey(forFileName: $0.fileName) == key }
                if let resolution = narrow(candidates, with: clue, evidence: .fileName) { return resolution }
            }
            if let reel = clue.reelName, !reel.isEmpty {
                let candidates = try Asset.filter(Column("reelName").collating(.nocase) == reel).fetchAll(db)
                if let resolution = narrow(candidates, with: clue, evidence: .reelName) { return resolution }
            }
            return .notFound
        }
    }

    private func narrow(_ candidates: [Asset], with clue: MediaClue,
                        evidence: SourceResolution.Evidence) -> SourceResolution? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return .found(candidates[0], evidence) }
        var narrowed = candidates
        if let start = clue.startTimecodeFrames {
            let matching = narrowed.filter { $0.startTimecodeFrames == start }
            if !matching.isEmpty { narrowed = matching }
        }
        if let duration = clue.durationFrames {
            let matching = narrowed.filter { abs($0.durationFrames - duration) <= 1 }
            if !matching.isEmpty { narrowed = matching }
        }
        return narrowed.count == 1 ? .found(narrowed[0], evidence) : .ambiguous(narrowed)
    }
}

extension String {
    fileprivate var likeEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
