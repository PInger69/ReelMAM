import Foundation
import GRDB

/// A full-text search result pointing at a moment in a clip.
public struct SearchHit: Hashable, Sendable {
    public enum Kind: String, Sendable { case asset, transcript, tag, marker, person }
    public var assetID: String
    public var kind: Kind
    /// Seconds from the start of the clip, when the hit is time-based.
    public var timeSeconds: Double?
    public var snippet: String
}

/// The SQLite-backed media catalog. One file holds assets, proxies, markers and all AI metadata.
public final class Catalog: Sendable {
    public let db: DatabaseQueue

    public init(path: String) throws {
        db = try DatabaseQueue(path: path)
        try Self.migrator.migrate(db)
    }

    private init(queue: DatabaseQueue) throws {
        db = queue
        try Self.migrator.migrate(db)
    }

    public static func inMemory() throws -> Catalog {
        try Catalog(queue: DatabaseQueue())
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "asset") { t in
                t.column("id", .text).primaryKey()
                t.column("sourcePath", .text).notNull().unique()
                t.column("fileName", .text).notNull().indexed()
                t.column("volumeName", .text)
                t.column("fileSize", .integer).notNull()
                t.column("bookmark", .blob)
                t.column("decodePath", .text).notNull()
                t.column("container", .text)
                t.column("videoCodec", .text)
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
                t.column("frameRateNum", .integer).notNull()
                t.column("frameRateDen", .integer).notNull()
                t.column("durationFrames", .integer).notNull()
                t.column("startTimecodeFrames", .integer).notNull()
                t.column("dropFrame", .boolean).notNull()
                t.column("reelName", .text)
                t.column("audioChannels", .integer).notNull()
                t.column("colorSpace", .text)
                t.column("capturedAt", .datetime)
                t.column("importedAt", .datetime).notNull()
                t.column("rating", .integer).notNull()
                t.column("notes", .text).notNull()
            }
            try db.create(table: "proxy") { t in
                t.column("id", .text).primaryKey()
                t.column("assetID", .text).notNull().indexed().references("asset", onDelete: .cascade)
                t.column("path", .text).notNull().unique()
                t.column("fileName", .text).notNull().indexed()
                t.column("preset", .text).notNull()
                t.column("status", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "marker") { t in
                t.column("id", .text).primaryKey()
                t.column("assetID", .text).notNull().indexed().references("asset", onDelete: .cascade)
                t.column("inFrame", .integer).notNull()
                t.column("outFrame", .integer)
                t.column("name", .text).notNull()
                t.column("note", .text).notNull()
                t.column("color", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "transcriptSegment") { t in
                t.column("id", .text).primaryKey()
                t.column("assetID", .text).notNull().indexed().references("asset", onDelete: .cascade)
                t.column("startSeconds", .double).notNull()
                t.column("endSeconds", .double).notNull()
                t.column("text", .text).notNull()
                t.column("speaker", .text)
            }
            try db.create(table: "sceneTag") { t in
                t.column("id", .text).primaryKey()
                t.column("assetID", .text).notNull().indexed().references("asset", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("label", .text).notNull().indexed()
                t.column("confidence", .double).notNull()
                t.column("startSeconds", .double).notNull()
                t.column("endSeconds", .double).notNull()
            }
            try db.create(table: "person") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text)
            }
            try db.create(table: "faceSighting") { t in
                t.column("id", .text).primaryKey()
                t.column("assetID", .text).notNull().indexed().references("asset", onDelete: .cascade)
                t.column("personID", .text).indexed().references("person", onDelete: .setNull)
                t.column("timeSeconds", .double).notNull()
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("width", .double).notNull()
                t.column("height", .double).notNull()
                t.column("embedding", .blob).notNull()
            }
            // One FTS5 index over everything searchable. Rebuilt per asset on write.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE searchIndex USING fts5(
                    assetID UNINDEXED, kind UNINDEXED, time UNINDEXED, text,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """)
        }
        migrator.registerMigration("v2-picture-format") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "formatName", .text).notNull().defaults(to: "")
                t.add(column: "scan", .text).notNull().defaults(to: ScanType.unknown.rawValue)
                t.add(column: "pixelAspectNum", .integer).notNull().defaults(to: 1)
                t.add(column: "pixelAspectDen", .integer).notNull().defaults(to: 1)
            }
        }
        migrator.registerMigration("v3-proxy-render-stats") { db in
            try db.alter(table: "proxy") { t in
                t.add(column: "pipeline", .text)
                t.add(column: "speed", .double)
            }
        }
        migrator.registerMigration("v4-proxy-verification") { db in
            try db.alter(table: "proxy") { t in
                t.add(column: "mismatch", .text)
            }
        }
        migrator.registerMigration("v5-source-fingerprint") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "fingerprint", .text)
            }
            try db.create(index: "asset_fingerprint", on: "asset", columns: ["fingerprint"])
        }
        migrator.registerMigration("v6-bins") { db in
            try db.create(table: "bin") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("parentID", .text).indexed().references("bin", onDelete: .cascade)
                t.column("smartQuery", .text)
                t.column("sortIndex", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "binItem") { t in
                t.column("binID", .text).notNull().references("bin", onDelete: .cascade)
                t.column("assetID", .text).notNull().indexed().references("asset", onDelete: .cascade)
                t.column("addedAt", .datetime).notNull()
                t.primaryKey(["binID", "assetID"])
            }
        }
        return migrator
    }

    // MARK: Assets

    /// Inserts or updates an asset. Re-importing the same path keeps the existing ID.
    @discardableResult
    public func save(_ asset: Asset) throws -> Asset {
        try db.write { db in
            var asset = asset
            // The same path, or the same content at a new path, is the same clip: keep its
            // identity so proxies, markers and A.I. metadata stay attached.
            var existing = try Asset.filter(Column("sourcePath") == asset.sourcePath).fetchOne(db)
            if existing == nil, let fingerprint = asset.fingerprint {
                existing = try Asset.filter(Column("fingerprint") == fingerprint).fetchAll(db)
                    .first { !FileManager.default.fileExists(atPath: $0.sourcePath) }
            }
            if let existing, existing.id != asset.id {
                asset.id = existing.id
                asset.importedAt = existing.importedAt
                asset.rating = existing.rating
                asset.notes = existing.notes
            }
            try asset.save(db)
            try Self.reindex(db, assetID: asset.id)
            return asset
        }
    }

    public func asset(id: String) throws -> Asset? {
        try db.read { try Asset.fetchOne($0, key: id) }
    }

    public func allAssets() throws -> [Asset] {
        try db.read { try Asset.order(Column("importedAt").desc, Column("fileName")).fetchAll($0) }
    }

    public func deleteAsset(id: String) throws {
        try db.write { db in
            _ = try Asset.deleteOne(db, key: id)
            try db.execute(sql: "DELETE FROM searchIndex WHERE assetID = ?", arguments: [id])
        }
    }

    // MARK: Proxies

    public func save(_ proxy: ProxyRecord) throws {
        try db.write { try proxy.save($0) }
    }

    public func assetIDsWithoutReadyProxy() throws -> Set<String> {
        try db.read {
            try String.fetchSet($0, sql: """
                SELECT id FROM asset WHERE id NOT IN (SELECT assetID FROM proxy WHERE status = ?)
                """, arguments: [ProxyStatus.ready.rawValue])
        }
    }

    public func proxies(forAsset assetID: String) throws -> [ProxyRecord] {
        try db.read { try ProxyRecord.filter(Column("assetID") == assetID).order(Column("createdAt").desc).fetchAll($0) }
    }

    // MARK: Markers

    public func save(_ marker: Marker) throws {
        try db.write { db in
            try marker.save(db)
            try Self.reindex(db, assetID: marker.assetID)
        }
    }

    public func deleteMarker(_ marker: Marker) throws {
        try db.write { db in
            _ = try marker.delete(db)
            try Self.reindex(db, assetID: marker.assetID)
        }
    }

    public func markers(forAsset assetID: String) throws -> [Marker] {
        try db.read { try Marker.filter(Column("assetID") == assetID).order(Column("inFrame")).fetchAll($0) }
    }

    // MARK: AI metadata

    public func replaceTranscript(assetID: String, with segments: [TranscriptSegment]) throws {
        try db.write { db in
            _ = try TranscriptSegment.filter(Column("assetID") == assetID).deleteAll(db)
            for segment in segments { try segment.insert(db) }
            try Self.reindex(db, assetID: assetID)
        }
    }

    public func transcript(forAsset assetID: String) throws -> [TranscriptSegment] {
        try db.read {
            try TranscriptSegment.filter(Column("assetID") == assetID).order(Column("startSeconds")).fetchAll($0)
        }
    }

    public func replaceTags(assetID: String, kinds: [TagKind], with tags: [SceneTag]) throws {
        try db.write { db in
            _ = try SceneTag.filter(Column("assetID") == assetID && kinds.map(\.rawValue).contains(Column("kind")))
                .deleteAll(db)
            for tag in tags { try tag.insert(db) }
            try Self.reindex(db, assetID: assetID)
        }
    }

    public func tags(forAsset assetID: String) throws -> [SceneTag] {
        try db.read { try SceneTag.filter(Column("assetID") == assetID).order(Column("startSeconds")).fetchAll($0) }
    }

    public func replaceFaces(assetID: String, with sightings: [FaceSighting]) throws {
        try db.write { db in
            _ = try FaceSighting.filter(Column("assetID") == assetID).deleteAll(db)
            for sighting in sightings { try sighting.insert(db) }
        }
    }

    public func faces(forAsset assetID: String) throws -> [FaceSighting] {
        try db.read { try FaceSighting.filter(Column("assetID") == assetID).order(Column("timeSeconds")).fetchAll($0) }
    }

    public func allFaces() throws -> [FaceSighting] {
        try db.read { try FaceSighting.fetchAll($0) }
    }

    public func people() throws -> [Person] {
        try db.read { try Person.order(Column("name")).fetchAll($0) }
    }

    /// Stores cluster assignments: each group of sighting IDs becomes (or joins) one person.
    public func assign(sightingIDs: [String], to person: Person) throws {
        try db.write { db in
            try person.save(db)
            _ = try FaceSighting.filter(sightingIDs.contains(Column("id")))
                .updateAll(db, Column("personID").set(to: person.id))
            let assetIDs = try String.fetchSet(db, FaceSighting.select(Column("assetID"))
                .filter(Column("personID") == person.id))
            for assetID in assetIDs { try Self.reindex(db, assetID: assetID) }
        }
    }

    public func rename(person: Person, to name: String) throws {
        var person = person
        person.name = name
        try assign(sightingIDs: [], to: person)
    }

    // MARK: Library facets

    public func assetIDsWithReadyProxy() throws -> Set<String> {
        try db.read {
            try String.fetchSet($0, sql: "SELECT DISTINCT assetID FROM proxy WHERE status = ?",
                                arguments: [ProxyStatus.ready.rawValue])
        }
    }

    public func assetIDsWithTranscript() throws -> Set<String> {
        try db.read { try String.fetchSet($0, sql: "SELECT DISTINCT assetID FROM transcriptSegment") }
    }

    public func assetIDs(forPerson personID: String) throws -> Set<String> {
        try db.read {
            try String.fetchSet($0, sql: "SELECT DISTINCT assetID FROM faceSighting WHERE personID = ?",
                                arguments: [personID])
        }
    }

    // MARK: Search

    /// Full-text search across file names, notes, transcripts, tags, markers and named people.
    /// Every word must match; the last word matches as a prefix so results update while typing.
    public func search(_ query: String, limit: Int = 200) throws -> [SearchHit] {
        let tokens = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let pattern = tokens.enumerated()
            .map { index, token in "\"\(token)\"" + (index == tokens.count - 1 ? "*" : "") }
            .joined(separator: " ")
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT assetID, kind, time, snippet(searchIndex, 3, '', '', '…', 16) AS snippet
                FROM searchIndex WHERE searchIndex MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [pattern, limit])
            return rows.compactMap { row in
                guard let kind = SearchHit.Kind(rawValue: row["kind"]) else { return nil }
                return SearchHit(assetID: row["assetID"], kind: kind, timeSeconds: row["time"], snippet: row["snippet"])
            }
        }
    }

    private static func reindex(_ db: Database, assetID: String) throws {
        try db.execute(sql: "DELETE FROM searchIndex WHERE assetID = ?", arguments: [assetID])
        guard let asset = try Asset.fetchOne(db, key: assetID) else { return }
        func add(_ kind: SearchHit.Kind, _ time: Double?, _ text: String) throws {
            guard !text.isEmpty else { return }
            try db.execute(sql: "INSERT INTO searchIndex (assetID, kind, time, text) VALUES (?, ?, ?, ?)",
                           arguments: [assetID, kind.rawValue, time, text])
        }
        try add(.asset, nil, [asset.fileName, asset.reelName ?? "", asset.notes, asset.formatName,
                              asset.pictureFormatName, asset.resolutionClass].joined(separator: " "))
        for segment in try TranscriptSegment.filter(Column("assetID") == assetID).fetchAll(db) {
            try add(.transcript, segment.startSeconds, segment.text)
        }
        for tag in try SceneTag.filter(Column("assetID") == assetID && Column("kind") != TagKind.shot.rawValue).fetchAll(db) {
            try add(.tag, tag.startSeconds, tag.label)
        }
        for marker in try Marker.filter(Column("assetID") == assetID).fetchAll(db) {
            try add(.marker, asset.frameRate.seconds(forFrames: marker.inFrame), "\(marker.name) \(marker.note)")
        }
        let people = try Row.fetchAll(db, sql: """
            SELECT person.name AS name, MIN(faceSighting.timeSeconds) AS time
            FROM faceSighting JOIN person ON person.id = faceSighting.personID
            WHERE faceSighting.assetID = ? AND person.name IS NOT NULL GROUP BY person.id
            """, arguments: [assetID])
        for row in people { try add(.person, row["time"], row["name"]) }
    }
}
