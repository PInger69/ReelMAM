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
        var configuration = Configuration()
        // A catalogue of a whole feature's footage is large and written to while it is read:
        // write-ahead logging keeps the interface responsive during imports and analysis.
        // The MAM app, the ingest app and the ingest client can all have one library open at
        // once: a writer waits for another to finish rather than failing with "database is locked".
        configuration.busyMode = .timeout(15)
        configuration.prepareDatabase { db in
            try db.execute(sql: """
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = NORMAL;
                PRAGMA cache_size = -262144;
                PRAGMA mmap_size = 1073741824;
                PRAGMA temp_store = MEMORY;
                """)
        }
        db = try DatabaseQueue(path: path, configuration: configuration)
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
        migrator.registerMigration("v7-editable-tags-and-scale") { db in
            try db.alter(table: "sceneTag") { t in
                t.add(column: "userEdited", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "labelRule") { t in
                t.column("id", .text).primaryKey()
                t.column("match", .text).notNull().unique()
                t.column("action", .text).notNull()
                t.column("replacement", .text).notNull().defaults(to: "")
                t.column("isDefault", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "catalogSetting") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
            // Indexes for a library of hundreds of thousands of clips.
            try db.create(index: "asset_importedAt", on: "asset", columns: ["importedAt"])
            try db.create(index: "asset_volumeName", on: "asset", columns: ["volumeName"])
            try db.create(index: "asset_reelName", on: "asset", columns: ["reelName"])
            try db.create(index: "proxy_status", on: "proxy", columns: ["status", "assetID"])
            try db.create(index: "sceneTag_asset_kind", on: "sceneTag", columns: ["assetID", "kind"])
        }
        migrator.registerMigration("v8-sequences-and-looks") { db in
            try db.create(table: "sequence") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("frameRateNum", .integer)
                t.column("frameRateDen", .integer)
                t.column("dropFrame", .boolean).notNull()
                t.column("startTimecode", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
            }
            try db.create(table: "sequenceCut") { t in
                t.column("id", .text).primaryKey()
                t.column("sequenceID", .text).notNull().references("sequence", onDelete: .cascade)
                t.column("assetID", .text).notNull().indexed().references("asset", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("inFrame", .integer).notNull()
                t.column("outFrame", .integer).notNull()
                t.column("note", .text).notNull()
            }
            try db.create(index: "sequenceCut_order", on: "sequenceCut", columns: ["sequenceID", "position"])
            // The viewing look chosen for a clip. No row means "choose from the clip's metadata".
            try db.create(table: "clipLook") { t in
                t.column("assetID", .text).primaryKey().references("asset", onDelete: .cascade)
                t.column("mode", .text).notNull()
                t.column("conversion", .text)
                t.column("lutPath", .text)
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
            // Tags a person added or corrected survive re-analysis.
            _ = try SceneTag.filter(Column("assetID") == assetID && kinds.map(\.rawValue).contains(Column("kind"))
                                    && Column("userEdited") == false)
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

    /// A handful of already-grouped sightings for every person, enough to recognise them in a
    /// new clip without loading every face in the catalogue.
    public func faceReferences(perPerson limit: Int = 24) throws -> [FaceSighting] {
        try db.read { db in
            try FaceSighting.fetchAll(db, sql: """
                SELECT * FROM faceSighting WHERE id IN (
                    SELECT id FROM (
                        SELECT id, ROW_NUMBER() OVER (PARTITION BY personID ORDER BY timeSeconds) AS n
                        FROM faceSighting WHERE personID IS NOT NULL
                    ) WHERE n <= ?
                )
                """, arguments: [limit])
        }
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

    static func reindex(_ db: Database, assetID: String) throws {
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
