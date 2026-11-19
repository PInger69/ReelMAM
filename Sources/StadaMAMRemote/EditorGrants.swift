import CryptoKit
import Foundation
import GRDB

/// One invited editor. The token itself is shown once, at invite time, and never stored:
/// only its SHA-256 is kept, so a copy of this file cannot be used to get in.
public struct EditorGrant: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "editorGrant"
    public var id: String
    public var name: String
    public var tokenHash: String
    public var createdAt: Date
    public var expiresAt: Date?
    public var revokedAt: Date?
    public var lastSeenAt: Date?
    /// The editor's initials, chosen at first sign-on and then locked. They identify the editor in the audit trail.
    public var initials: String?

    /// Two to four letters or digits, upper-cased; nil if it is anything else.
    public static func normalizedInitials(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard (2...4).contains(value.count),
              value.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else { return nil }
        return value
    }

    public func isValid(at date: Date) -> Bool {
        revokedAt == nil && (expiresAt.map { $0 > date } ?? true)
    }
}

/// Invited editors and their revocable tokens. Kept in its own small database so remote
/// access state never mixes with the catalogue the editors are allowed to read.
public final class GrantStore: Sendable {
    private let db: DatabaseQueue
    private let audit: AuditLog?

    /// With an audit log, inviting, revoking and resetting are recorded in it.
    public init(path: String? = nil, audit: AuditLog? = nil) throws {
        self.audit = audit
        db = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "editorGrant") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("tokenHash", .text).notNull().unique()
                t.column("createdAt", .datetime).notNull()
                t.column("expiresAt", .datetime)
                t.column("revokedAt", .datetime)
                t.column("lastSeenAt", .datetime)
            }
        }
        migrator.registerMigration("v2-initials-and-audit") { db in
            try db.alter(table: "editorGrant") { t in t.add(column: "initials", .text) }
        }
        try migrator.migrate(db)
    }

    public enum InitialsResult: Equatable, Sendable {
        case locked(String)
        case alreadyLocked(String)
        /// A different value is already locked; only the owner can reset it.
        case conflict(existing: String)
        case invalid
    }

    /// Locks an editor's initials. The first value sticks: asking again for the same
    /// value succeeds, for another one is refused.
    public func lockInitials(id: String, _ raw: String) throws -> InitialsResult {
        guard let value = EditorGrant.normalizedInitials(raw) else { return .invalid }
        return try db.write { db in
            guard var grant = try EditorGrant.fetchOne(db, key: id) else { return .invalid }
            if let existing = grant.initials { return existing == value ? .alreadyLocked(value) : .conflict(existing: existing) }
            grant.initials = value
            try grant.update(db)
            return .locked(value)
        }
    }

    /// Owner-only: clears an editor's initials so they can choose again (for a typo, say).
    public func resetInitials(id: String) throws {
        let before = try grant(id: id)
        try db.write { try $0.execute(sql: "UPDATE editorGrant SET initials = NULL WHERE id = ?", arguments: [id]) }
        try audit?.append(AuditEvent(kind: .admin, grantID: id, editor: before?.name, initials: before?.initials,
                                     method: "ADMIN", path: "reset-initials",
                                     detail: "was \(before?.initials ?? "unset")"))
    }

    public func grant(id: String) throws -> EditorGrant? {
        try db.read { try EditorGrant.fetchOne($0, key: id) }
    }


    /// 256 random bits, URL-safe, with a prefix so a leaked token is recognisable in a scan.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no secure random bytes")
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "sxr_" + encoded
    }

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Creates an editor and returns the one and only copy of their token.
    public func invite(name: String, expiresAt: Date? = nil, now: Date = Date()) throws -> (grant: EditorGrant, token: String) {
        let token = Self.makeToken()
        let grant = EditorGrant(id: newGrantID(), name: name, tokenHash: Self.hash(token),
                                createdAt: now, expiresAt: expiresAt)
        try db.write { try grant.insert($0) }
        try audit?.append(AuditEvent(kind: .admin, grantID: grant.id, editor: name, method: "ADMIN", path: "invite",
                                     detail: expiresAt.map { "expires \($0)" }), at: now)
        return (grant, token)
    }

    /// The editor a token belongs to, if it is known, not revoked and not expired.
    public func authenticate(token: String, now: Date = Date()) throws -> EditorGrant? {
        let hash = Self.hash(token)
        return try db.write { db in
            guard var grant = try EditorGrant.filter(Column("tokenHash") == hash).fetchOne(db),
                  grant.isValid(at: now) else { return nil }
            // One write a minute at most, however busy the editor's downloads are.
            if grant.lastSeenAt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
                grant.lastSeenAt = now
                try grant.update(db)
            }
            return grant
        }
    }

    /// Who a token belongs to even if it has been revoked or has expired, so a refused sign-in
    /// can still be attributed.
    public func owner(ofToken token: String) throws -> EditorGrant? {
        let hash = Self.hash(token)
        return try db.read { try EditorGrant.filter(Column("tokenHash") == hash).fetchOne($0) }
    }

    public func revoke(id: String, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE editorGrant SET revokedAt = ? WHERE id = ? AND revokedAt IS NULL",
                           arguments: [now, id])
        }
        let grant = try self.grant(id: id)
        try audit?.append(AuditEvent(kind: .admin, grantID: id, editor: grant?.name, initials: grant?.initials,
                                     method: "ADMIN", path: "revoke"), at: now)
    }

    public func all() throws -> [EditorGrant] {
        try db.read { try EditorGrant.order(Column("createdAt")).fetchAll($0) }
    }

    private func newGrantID() -> String { UUID().uuidString }
}

/// What an editor receives: a link that opens the app in Remote mode, already signed in.
/// `fp` is the SHA-256 of the mini's certificate when it serves TLS itself, so the editor's
/// app can pin it; behind a tunnel the public certificate is used and `fp` is absent.
public struct InviteLink: Equatable, Sendable {
    public var host: String
    public var token: String
    public var certificateFingerprint: String?

    public init(host: String, token: String, certificateFingerprint: String? = nil) {
        self.host = host
        self.token = token
        self.certificateFingerprint = certificateFingerprint
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "stradaxr"
        components.host = "join"
        var items = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "token", value: token)]
        if let fp = certificateFingerprint { items.append(URLQueryItem(name: "fp", value: fp)) }
        components.queryItems = items
        return components.url!
    }

    /// The link for the browser app. The token is after the `#`, which a browser never sends to
    /// the server, so it cannot end up in a log. The page trades it for a cookie and removes it.
    public var webURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        let parts = host.split(separator: ":", maxSplits: 1).map(String.init)
        components.host = parts.first
        if parts.count > 1 { components.port = Int(parts[1]) }
        components.path = "/join"
        components.fragment = token
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == "stradaxr", url.host == "join",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty,
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else { return nil }
        self.init(host: host, token: token, certificateFingerprint: items.first { $0.name == "fp" }?.value)
    }
}

/// Failed sign-ins slow down; valid tokens are never affected, so a stranger hammering the
/// tunnel cannot lock editors out.
final class AuthThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: [Date]] = [:]
    let limit: Int
    let window: TimeInterval

    init(limit: Int = 10, window: TimeInterval = 300) {
        self.limit = limit
        self.window = window
    }

    func isBlocked(_ key: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let recent = (failures[key] ?? []).filter { now.timeIntervalSince($0) < window }
        failures[key] = recent
        return recent.count >= limit
    }

    func recordFailure(_ key: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        failures[key, default: []].append(now)
        if failures.count > 10_000 { failures = failures.filter { !$0.value.isEmpty && now.timeIntervalSince($0.value.last!) < window } }
    }
}
