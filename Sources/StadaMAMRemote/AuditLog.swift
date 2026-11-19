// Apple platforms only: this code is built on CryptoKit, Network and Security.
#if canImport(CryptoKit) && canImport(Network)
import CryptoKit
import Foundation
import GRDB

/// What happened. `request` is written before the response goes out; `transfer` when the
/// bytes have actually been sent (or the connection broke), pointing back at its request.
public enum AuditKind: String, Codable, Sendable {
    case request
    case transfer
    /// Someone presented a token that is wrong, revoked or expired.
    case signInFailed
    /// The owner invited, revoked or reset an editor.
    case admin
}

public struct AuditEvent: Sendable {
    public var kind: AuditKind
    public var grantID: String?
    public var editor: String?
    public var initials: String?
    public var method: String
    public var path: String
    public var query: String?
    public var status: Int
    public var bytes: Int64
    public var range: String?
    public var peer: String
    public var ref: Int64?
    public var detail: String?

    public init(kind: AuditKind, grantID: String? = nil, editor: String? = nil, initials: String? = nil,
                method: String, path: String, query: String? = nil, status: Int = 0, bytes: Int64 = 0,
                range: String? = nil, peer: String = "", ref: Int64? = nil, detail: String? = nil) {
        self.kind = kind; self.grantID = grantID; self.editor = editor; self.initials = initials
        self.method = method; self.path = path; self.query = query; self.status = status
        self.bytes = bytes; self.range = range; self.peer = peer; self.ref = ref; self.detail = detail
    }
}

/// One line of the log, as stored. `hash` seals this entry and, through `prevHash`, every
/// entry before it.
public struct AuditRecord: Codable, Hashable, Sendable, FetchableRecord {
    public var seq: Int64
    public var atMillis: Int64
    public var kind: AuditKind
    public var grantID: String?
    public var editor: String?
    public var initials: String?
    public var method: String
    public var path: String
    public var query: String?
    public var status: Int
    public var bytes: Int64
    public var range: String?
    public var peer: String
    public var ref: Int64?
    public var detail: String?
    public var prevHash: String
    public var hash: String

    public var at: Date { Date(timeIntervalSince1970: Double(atMillis) / 1000) }
}

/// A note of how far the log had got. Kept somewhere the log's own file cannot reach (an
/// email to the owner, a printout), it is what exposes a log that was cut short.
public struct AuditAnchor: Codable, Equatable, Sendable {
    public var seq: Int64
    public var hash: String
}

public struct AuditVerification: Equatable, Sendable {
    public var ok: Bool
    public var entries: Int
    public var firstBadSeq: Int64?
    public var problem: String?
}

/// The record of who did what.
///
/// - **Append-only:** database triggers refuse any update or delete of an entry.
/// - **Tamper-evident:** each entry carries an HMAC-SHA256 over its contents and the previous
///   entry's hash, keyed with a secret kept apart from the log file. Changing, removing or
///   inserting an entry, or rebuilding the chain without the key, makes `verify()` fail at the
///   first bad entry. Cutting entries off the end is caught against an `AuditAnchor`.
/// - **Durable:** its own database file in write-ahead mode with full sync, so an entry
///   survives a crash or power loss once `append` returns.
/// - **Fail-closed:** callers write the entry before they act; if it cannot be written, the
///   request is refused (see `RemoteAPI`).
///
/// What it cannot do: stop someone with both the file and the key from rewriting history. Keep
/// the key out of the file's backups and note an anchor now and then.
public final class AuditLog: @unchecked Sendable {
    public static let genesis = String(repeating: "0", count: 64)

    private let db: DatabaseQueue
    private let key: SymmetricKey
    /// Test hook: make every write fail, to prove callers fail closed.
    var failWrites = false

    public init(path: String? = nil, key: SymmetricKey) throws {
        self.key = key
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            if path != nil { try db.execute(sql: "PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL;") }
        }
        db = try path.map { try DatabaseQueue(path: $0, configuration: configuration) } ?? DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "auditEntry") { t in
                t.column("seq", .integer).primaryKey()
                t.column("atMillis", .integer).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("grantID", .text).indexed()
                t.column("editor", .text)
                t.column("initials", .text)
                t.column("method", .text).notNull()
                t.column("path", .text).notNull()
                t.column("query", .text)
                t.column("status", .integer).notNull()
                t.column("bytes", .integer).notNull()
                t.column("range", .text)
                t.column("peer", .text).notNull()
                t.column("ref", .integer)
                t.column("detail", .text)
                t.column("prevHash", .text).notNull()
                t.column("hash", .text).notNull()
            }
            try db.execute(sql: """
                CREATE TRIGGER auditEntry_no_update BEFORE UPDATE ON auditEntry
                BEGIN SELECT RAISE(ABORT, 'the audit log is append-only'); END;
                CREATE TRIGGER auditEntry_no_delete BEFORE DELETE ON auditEntry
                BEGIN SELECT RAISE(ABORT, 'the audit log is append-only'); END;
                """)
        }
        try migrator.migrate(db)
    }

    /// Loads the signing key from a file, making it (32 random bytes, owner-only) the first time.
    public static func loadOrCreateKey(at path: String) throws -> SymmetricKey {
        let url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url), data.count == 32 { return SymmetricKey(data: data) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return key
    }

    // MARK: Writing

    /// Adds an entry and returns its sequence number. Throws if it could not be stored.
    @discardableResult
    public func append(_ event: AuditEvent, at date: Date = Date()) throws -> Int64 {
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return try db.write { db in
            let last = try Row.fetchOne(db, sql: "SELECT seq, hash FROM auditEntry ORDER BY seq DESC LIMIT 1")
            var record = AuditRecord(seq: (last?["seq"] as Int64? ?? 0) + 1, atMillis: millis, kind: event.kind,
                                     grantID: event.grantID, editor: event.editor, initials: event.initials,
                                     method: event.method, path: event.path, query: event.query,
                                     status: event.status, bytes: event.bytes, range: event.range, peer: event.peer,
                                     ref: event.ref, detail: event.detail,
                                     prevHash: last?["hash"] as String? ?? Self.genesis, hash: "")
            record.hash = seal(record)
            try db.execute(sql: """
                INSERT INTO auditEntry (seq, atMillis, kind, grantID, editor, initials, method, path, query,
                                        status, bytes, range, peer, ref, detail, prevHash, hash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [record.seq, record.atMillis, record.kind.rawValue, record.grantID, record.editor,
                                 record.initials, record.method, record.path, record.query, record.status,
                                 record.bytes, record.range, record.peer, record.ref, record.detail,
                                 record.prevHash, record.hash])
            return record.seq
        }
    }

    /// Every field, length-prefixed so no value can run into the next, in a fixed order.
    private func canonical(_ r: AuditRecord) -> String {
        func field(_ value: String?) -> String { value.map { "\($0.utf8.count):\($0)" } ?? "~" }
        return [String(r.seq), String(r.atMillis), r.kind.rawValue, field(r.grantID), field(r.editor), field(r.initials),
                field(r.method), field(r.path), field(r.query), String(r.status), String(r.bytes), field(r.range),
                field(r.peer), r.ref.map(String.init) ?? "~", field(r.detail)].joined(separator: "|")
    }

    private func seal(_ r: AuditRecord) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data((r.prevHash + "|" + canonical(r)).utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Reading

    public func entries(grantID: String? = nil, kind: AuditKind? = nil, since: Date? = nil,
                        limit: Int = 500, newestFirst: Bool = true) throws -> [AuditRecord] {
        var clauses: [String] = []
        var arguments: [DatabaseValueConvertible] = []
        if let grantID { clauses.append("grantID = ?"); arguments.append(grantID) }
        if let kind { clauses.append("kind = ?"); arguments.append(kind.rawValue) }
        if let since { clauses.append("atMillis >= ?"); arguments.append(Int64(since.timeIntervalSince1970 * 1000)) }
        let condition = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try db.read {
            try AuditRecord.fetchAll($0, sql: "SELECT * FROM auditEntry \(condition) ORDER BY seq \(newestFirst ? "DESC" : "ASC") LIMIT ?",
                                     arguments: StatementArguments(arguments + [limit]))
        }
    }

    /// Bytes each editor has actually pulled (from the `transfer` entries), by editor id.
    public func bytesSentByEditor() throws -> [String: Int64] {
        try db.read { db in
            var totals: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT grantID, SUM(bytes) AS total FROM auditEntry WHERE kind = 'transfer' AND grantID IS NOT NULL GROUP BY grantID") {
                totals[row["grantID"]] = row["total"]
            }
            return totals
        }
    }

    public func count() throws -> Int { try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM auditEntry") ?? 0 } }

    public func anchor() throws -> AuditAnchor? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT seq, hash FROM auditEntry ORDER BY seq DESC LIMIT 1")
                .map { AuditAnchor(seq: $0["seq"], hash: $0["hash"]) }
        }
    }

    /// Re-computes the whole chain. Pass an earlier anchor to also prove nothing before it was
    /// removed and the log did not stop short of it.
    public func verify(against anchor: AuditAnchor? = nil) throws -> AuditVerification {
        try db.read { db in
            var expected: Int64 = 1
            var previous = Self.genesis
            var count = 0
            var anchorHashSeen: String?
            let cursor = try AuditRecord.fetchCursor(db, sql: "SELECT * FROM auditEntry ORDER BY seq")
            while let record = try cursor.next() {
                func bad(_ why: String, at seq: Int64? = nil) -> AuditVerification {
                    AuditVerification(ok: false, entries: count, firstBadSeq: seq ?? record.seq, problem: why)
                }
                if record.seq != expected { return bad("entry \(expected) is missing", at: expected) }
                if record.prevHash != previous { return bad("entry \(record.seq) does not follow the one before it") }
                if seal(record) != record.hash { return bad("entry \(record.seq) was changed") }
                if record.seq == anchor?.seq { anchorHashSeen = record.hash }
                previous = record.hash
                expected += 1
                count += 1
            }
            if let anchor {
                if Int64(count) < anchor.seq {
                    return AuditVerification(ok: false, entries: count, firstBadSeq: Int64(count) + 1,
                                             problem: "the log stops at \(count) but was noted at \(anchor.seq)")
                }
                if anchorHashSeen != anchor.hash {
                    return AuditVerification(ok: false, entries: count, firstBadSeq: anchor.seq,
                                             problem: "entry \(anchor.seq) is not the one that was noted")
                }
            }
            return AuditVerification(ok: true, entries: count, firstBadSeq: nil, problem: nil)
        }
    }

    /// The whole log, one JSON object per line, oldest first, for the owner or an auditor.
    public func exportJSONLines() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for record in try entries(limit: Int.max, newestFirst: false) {
            out.append(try encoder.encode(record))
            out.append(0x0A)
        }
        return out
    }
}
#endif
