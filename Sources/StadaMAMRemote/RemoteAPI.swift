// Apple platforms only: this code is built on CryptoKit, Network and Security.
#if canImport(CryptoKit) && canImport(Network)
import Foundation
import GRDB
import StadaMAMCore

// MARK: Wire types

public struct RemoteProxyInfo: Codable, Equatable, Sendable {
    public var id: String
    public var fileName: String
    public var preset: String
    public var bytes: Int64
    public var etag: String
    /// Average bitrate in megabits per second, for planning a download.
    public var megabitsPerSecond: Double?
}

/// What an editor sees of a clip. Deliberately has no path, bookmark or fingerprint:
/// where the original lives on the mini is not the editor's business.
public struct RemoteAsset: Codable, Equatable, Sendable {
    public var id: String
    public var fileName: String
    public var reelName: String?
    public var volumeName: String?
    public var formatName: String
    public var width: Int
    public var height: Int
    public var frameRateNum: Int
    public var frameRateDen: Int
    public var durationFrames: Int
    public var durationSeconds: Double
    public var startTimecode: String
    public var startTimecodeFrames: Int
    public var dropFrame: Bool
    public var audioChannels: Int
    public var capturedAt: Date?
    public var rating: Int
    public var notes: String
    public var originalBytes: Int64
    public var proxy: RemoteProxyInfo?
}

public struct RemotePage: Codable, Sendable {
    public var total: Int
    public var offset: Int
    public var items: [RemoteAsset]
}

public struct RemoteAssetDetail: Codable, Sendable {
    public var asset: RemoteAsset
    public var markers: [Marker]
    public var transcript: [TranscriptSegment]
    public var tags: [SceneTag]
    public var binIDs: [String]
}

public struct RemoteBin: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var parentID: String?
    public var isSmart: Bool
    public var count: Int
}

public struct RemoteSearchHit: Codable, Equatable, Sendable {
    public var assetID: String
    public var kind: String
    public var timeSeconds: Double?
    public var snippet: String
}

public struct RemoteManifest: Codable, Sendable {
    public var totalBytes: Int64
    public var items: [Item]
    public struct Item: Codable, Equatable, Sendable {
        public var assetID: String
        public var fileName: String
        public var durationSeconds: Double
        public var proxy: RemoteProxyInfo
    }
}

public struct RemoteMe: Codable, Sendable {
    public var name: String
    /// Nil until the editor has chosen and locked their initials.
    public var initials: String?
}

/// Whether proxies leave the mini only with the editor's mark burned in. There is no default:
/// `.off` is for tests and trusted use, and says so at the call site.
public enum WatermarkPolicy: Sendable {
    case off
    case required(ProxyWatermarker)
}

public struct RemoteInfo: Codable, Sendable {
    public var name: String
    public var apiVersion: Int
    public var assetCount: Int
    public var editor: String
}

// MARK: Router

/// The read-only API editors talk to. Pure request-in, response-out, so it is tested without
/// a network and served unchanged by `RemoteServer`.
///
/// What it can reach: catalogue metadata, and proxy files that are registered in the
/// catalogue, finished, verified against their source, and inside a configured proxy folder.
/// There is no route that takes a file path, and nothing that returns an original.
public final class RemoteAPI: @unchecked Sendable {
    public static let apiVersion = 1

    public let catalog: Catalog
    public let grants: GrantStore
    public let serverName: String
    private let proxyRoots: [String]
    private let throttle = AuthThrottle()
    private let watermark: WatermarkPolicy
    public let audit: AuditLog
    /// Set when editors reach the server over HTTPS (any tunnel, relay or TLS mode), so the
    /// browser only ever sends its sign-in cookie over an encrypted connection.
    public var cookieSecure = false
    /// Pages and manifests are capped so one request cannot ask for the whole library.
    public var maxPage = 1000
    public var maxManifest = 20_000

    public init(catalog: Catalog, grants: GrantStore, proxyRoots: [String], watermark: WatermarkPolicy,
                audit: AuditLog, serverName: String = "StradaXR AI MAM") {
        self.watermark = watermark
        self.audit = audit
        self.catalog = catalog
        self.grants = grants
        self.serverName = serverName
        self.proxyRoots = proxyRoots.map { Self.canonical($0) }
    }

    private static func canonical(_ path: String) -> String {
        var resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if !resolved.hasSuffix("/") { resolved += "/" }
        return resolved
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private func json<T: Encodable>(_ value: T) -> HTTPResponse {
        guard let data = try? Self.encoder.encode(value) else { return .error(500, "encoding failed") }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json"),
                                                   ("Cache-Control", "private, no-store"),
                                                   ("X-Content-Type-Options", "nosniff")], body: .data(data))
    }

    // MARK: Entry point

    /// `peer` identifies the caller for throttling failed sign-ins (the tunnel's forwarded
    /// client address when there is one, the socket address otherwise).
    public func handle(_ request: HTTPRequest, peer: String, now: Date = Date()) -> HTTPResponse {
        // Read-only, apart from the few writes an editor's own session makes: locking their
        // initials and signing in or out of the browser app.
        let writes: Set<String> = ["/v1/me/initials", "/v1/session", "/v1/session/end"]
        let isWrite = request.method == "POST" && writes.contains(request.path)
        guard request.method == "GET" || request.method == "HEAD" || isWrite else {
            return .error(405, "read-only service", extra: [("Allow", "GET, HEAD")])
        }
        // A page on another website can make a browser send a POST, but cannot add this header
        // without the server's say-so, which it never gives. So no cross-site writes.
        if request.method == "POST", request.headers["x-stradaxr"] != "1" {
            return .error(400, "missing X-StradaXR header")
        }
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // The one unauthenticated route, for the tunnel's health check. Says nothing about the library.
        if parts == ["healthz"] {
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/plain")], body: .data(Data("ok".utf8)))
        }
        // The browser app itself: the same files for everyone, with no library data in them.
        if request.method != "POST", let page = WebApp.assets[request.path] {
            let data = Data(page.body.utf8)
            return HTTPResponse(status: 200, headers: [("Content-Type", page.contentType)] + WebApp.securityHeaders,
                                body: request.method == "HEAD" ? .headOnly(length: UInt64(data.count)) : .data(data))
        }
        if request.path == "/v1/session/end" {
            return HTTPResponse(status: 200, headers: [("Set-Cookie", sessionCookie("", maxAge: 0)),
                                                       ("Content-Type", "application/json")], body: .data(Data("{}".utf8)))
        }
        guard parts.first == "v1" else { return .error(404, "not found") }

        // Native clients send a bearer token; the browser app's page sends its cookie.
        let token = request.bearerToken ?? Self.cookie("sx", in: request.headers["cookie"])
        let grant: EditorGrant?
        do {
            grant = try token.flatMap { try grants.authenticate(token: $0, now: now) }
        } catch {
            return .error(503, "unavailable")
        }
        guard let grant else {
            if throttle.isBlocked(peer, now: now) {
                // Past the limit nothing more is written: a flood must not be able to fill the log.
                return .error(429, "too many failed attempts", extra: [("Retry-After", "300")])
            }
            throttle.recordFailure(peer, now: now)
            // A revoked or expired token still says whose it was.
            let known = try? token.flatMap { try grants.owner(ofToken: $0) }
            let why = known == nil ? (token == nil ? "no token" : "unknown token")
                : (known?.revokedAt != nil ? "revoked token" : "expired token")
            do {
                try audit.append(AuditEvent(kind: .signInFailed, grantID: known?.id, editor: known?.name,
                                            initials: known?.initials, method: request.method, path: request.path,
                                            status: 401, peer: peer, detail: why), at: now)
            } catch {
                return .error(503, "unavailable")
            }
            return .error(401, "invalid or revoked token", extra: [("WWW-Authenticate", "Bearer")])
        }

        var response: HTTPResponse
        do {
            response = try route(Array(parts.dropFirst()), request, grant: grant, token: token ?? "")
        } catch {
            response = .error(500, "internal error")
        }
        // Every authenticated request is written to the audit log *before* anything is sent.
        // If the entry cannot be stored, the request is refused rather than served unrecorded.
        let query = request.query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let seq: Int64
        do {
            seq = try audit.append(AuditEvent(kind: .request, grantID: grant.id, editor: grant.name, initials: grant.initials,
                                              method: request.method, path: request.path,
                                              query: query.isEmpty ? nil : query, status: response.status,
                                              bytes: Int64(response.body.length), range: request.headers["range"],
                                              peer: peer), at: now)
        } catch {
            return .error(503, "unavailable")
        }
        // And again when the bytes have really gone: how many, and whether the download finished.
        switch response.body {
        case .data, .file:
            let log = audit, editor = grant, status = response.status
            response.onFinish = { sent, completed in
                _ = try? log.append(AuditEvent(kind: .transfer, grantID: editor.id, editor: editor.name,
                                               initials: editor.initials, method: request.method, path: request.path,
                                               status: status, bytes: sent, peer: peer, ref: seq,
                                               detail: completed ? "complete" : "interrupted"))
            }
        default:
            break
        }
        return response
    }

    private func sessionCookie(_ token: String, maxAge: Int) -> String {
        "sx=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(maxAge)" + (cookieSecure ? "; Secure" : "")
    }

    static func cookie(_ name: String, in header: String?) -> String? {
        header?.split(separator: ";").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(name + "=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }

    private func route(_ parts: [String], _ request: HTTPRequest, grant: EditorGrant, token: String) throws -> HTTPResponse {
        switch parts {
        case ["session"]:
            // Trades the invite's token for a cookie the page's scripts cannot read, so the
            // browser can authenticate video playback and downloads too.
            guard request.method == "POST" else { return .error(405, "use POST", extra: [("Allow", "POST")]) }
            var response = json(RemoteMe(name: grant.name, initials: grant.initials))
            response.headers.append(("Set-Cookie", sessionCookie(token, maxAge: 30 * 86_400)))
            return response
        case ["me"]:
            return json(RemoteMe(name: grant.name, initials: grant.initials))
        case ["me", "initials"]:
            guard request.method == "POST" else { return .error(405, "use POST", extra: [("Allow", "POST")]) }
            switch try grants.lockInitials(id: grant.id, request.query["value"] ?? "") {
            case .locked, .alreadyLocked:
                let updated = try grants.grant(id: grant.id) ?? grant
                return json(RemoteMe(name: updated.name, initials: updated.initials))
            case .conflict:
                return .error(409, "initials are already locked; ask the owner to reset them")
            case .invalid:
                return .error(400, "initials must be 2 to 4 letters or digits")
            }
        case ["info"]:
            return json(RemoteInfo(name: serverName, apiVersion: Self.apiVersion,
                                   assetCount: try catalog.db.read { try Asset.fetchCount($0) },
                                   editor: grant.name))
        case ["assets"]:
            return try listAssets(request)
        case ["manifest"]:
            return try manifest(request)
        case ["bins"]:
            return try bins()
        case ["search"]:
            return try search(request)
        case let p where p.count == 2 && p[0] == "assets":
            return try assetDetail(id: p[1])
        case let p where p.count == 2 && p[0] == "proxies":
            return try serveProxy(id: p[1], request: request, grant: grant)
        default:
            return .error(404, "not found")
        }
    }

    // MARK: Catalogue

    private func bins() throws -> HTTPResponse {
        let counts = try catalog.binCounts()
        return json(try catalog.bins().map {
            RemoteBin(id: $0.id, name: $0.name, parentID: $0.parentID, isSmart: $0.isSmart, count: counts[$0.id] ?? 0)
        })
    }

    private func search(_ request: HTTPRequest) throws -> HTTPResponse {
        let limit = min(Int(request.query["limit"] ?? "") ?? 100, 500)
        let hits = try catalog.search(request.query["q"] ?? "", limit: max(limit, 1))
        return json(hits.map { RemoteSearchHit(assetID: $0.assetID, kind: $0.kind.rawValue,
                                               timeSeconds: $0.timeSeconds, snippet: $0.snippet) })
    }

    private func assetDetail(id: String) throws -> HTTPResponse {
        guard let asset = try catalog.asset(id: id) else { return .error(404, "not found") }
        let summary = try summaries(for: [asset])[0]
        return json(RemoteAssetDetail(asset: summary,
                                      markers: try catalog.markers(forAsset: id),
                                      transcript: try catalog.transcript(forAsset: id),
                                      tags: try catalog.tags(forAsset: id),
                                      binIDs: try catalog.binIDs(containing: id).sorted()))
    }

    private static let readyProxy = "status = 'ready' AND mismatch IS NULL"
    private static let shotDate = "COALESCE(capturedAt, importedAt)"

    /// The clips a listing or manifest asks for: by search (`q`, best match first), by bin,
    /// by shoot day (`day=YYYY-MM-DD`, with `utcOffset` in minutes, default UTC) and
    /// `hasProxy=1` for clips an editor can actually pull.
    private func matchingAssets(_ query: [String: String], offset: Int, limit: Int) throws -> (total: Int, assets: [Asset]) {
        var clauses: [String] = []
        var arguments: [DatabaseValueConvertible] = []
        if let day = query["day"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: (Int(query["utcOffset"] ?? "") ?? 0) * 60) ?? .gmt
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return (0, []) }
            clauses.append("\(Self.shotDate) >= ? AND \(Self.shotDate) < ?")
            arguments += [start, end]
        }
        if query["hasProxy"] == "1" {
            clauses.append("id IN (SELECT assetID FROM proxy WHERE \(Self.readyProxy))")
        }
        let condition = clauses.isEmpty ? "1" : clauses.map { "(\($0))" }.joined(separator: " AND ")
        let order = "\(Self.shotDate), fileName"

        // Search and bin choose which clips; the SQL conditions then narrow them.
        var chosen: [String]?
        if let q = query["q"], !q.isEmpty {
            var seen = Set<String>()
            chosen = try catalog.search(q, limit: 5000).map(\.assetID).filter { seen.insert($0).inserted }
        }
        if let bin = query["bin"] {
            let members = try catalog.assetIDs(inBin: bin)
            chosen = chosen.map { $0.filter(members.contains) } ?? members.sorted()
        }

        return try catalog.db.read { db in
            guard let chosen else {
                let total = try Asset.filter(sql: condition, arguments: StatementArguments(arguments)).fetchCount(db)
                let page = try Asset.filter(sql: condition, arguments: StatementArguments(arguments))
                    .order(sql: order).limit(limit, offset: offset).fetchAll(db)
                return (total, page)
            }
            var found: [String: Asset] = [:]
            for chunk in stride(from: 0, to: chosen.count, by: 500).map({ Array(chosen[$0..<min($0 + 500, chosen.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Asset.filter(sql: "id IN (\(marks)) AND \(condition)",
                                            arguments: StatementArguments(chunk + arguments)).fetchAll(db)
                for row in rows { found[row.id] = row }
            }
            var ordered = chosen.compactMap { found[$0] }
            // Without a search, show a bin in shooting order; with one, keep best match first.
            if query["q"]?.isEmpty ?? true {
                ordered.sort { ($0.capturedAt ?? $0.importedAt, $0.fileName) < ($1.capturedAt ?? $1.importedAt, $1.fileName) }
            }
            let page = Array(ordered.dropFirst(offset).prefix(limit))
            return (ordered.count, page)
        }
    }

    private func listAssets(_ request: HTTPRequest) throws -> HTTPResponse {
        let offset = max(Int(request.query["offset"] ?? "") ?? 0, 0)
        let limit = min(max(Int(request.query["limit"] ?? "") ?? 200, 1), maxPage)
        let (total, assets) = try matchingAssets(request.query, offset: offset, limit: limit)
        return json(RemotePage(total: total, offset: offset, items: try summaries(for: assets)))
    }

    private func manifest(_ request: HTTPRequest) throws -> HTTPResponse {
        var query = request.query
        query["hasProxy"] = "1"
        let (_, assets) = try matchingAssets(query, offset: 0, limit: maxManifest)
        let summaries = try summaries(for: assets)
        let items = summaries.compactMap { summary in
            summary.proxy.map { RemoteManifest.Item(assetID: summary.id, fileName: summary.fileName,
                                                    durationSeconds: summary.durationSeconds, proxy: $0) }
        }
        return json(RemoteManifest(totalBytes: items.reduce(0) { $0 + $1.proxy.bytes }, items: items))
    }

    // MARK: Proxies

    /// Smaller, more streamable presets first. The remote preset leads this list.
    private static func rank(_ preset: ProxyPreset) -> Int {
        switch preset {
        case .remoteHEVC: return 0
        case .h264_720: return 1
        case .h264_1080: return 2
        case .proResProxyHalf: return 3
        case .proResProxy1080: return 4
        }
    }

    private struct ServablePath {
        var path: String
        var size: UInt64
        var modified: Int
    }

    /// The file behind a proxy record, only if it is safe to hand out.
    private func servable(_ proxy: ProxyRecord) -> ServablePath? {
        guard proxy.status == .ready, proxy.mismatch == nil else { return nil }
        let resolved = URL(fileURLWithPath: proxy.path).resolvingSymlinksInPath().path
        guard proxyRoots.contains(where: { resolved.hasPrefix($0) }) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? UInt64 else { return nil }
        // Belt and braces: never a file the catalogue knows as a camera original.
        let isOriginal = (try? catalog.db.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM asset WHERE sourcePath IN (?, ?))",
                              arguments: [proxy.path, resolved])
        }) ?? true
        guard !isOriginal else { return nil }
        let modified = Int((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        return ServablePath(path: resolved, size: size, modified: modified)
    }

    private func etag(_ proxy: ProxyRecord, _ file: ServablePath) -> String {
        "\"\(proxy.id)-\(file.size)-\(file.modified)\""
    }

    private func summaries(for assets: [Asset]) throws -> [RemoteAsset] {
        let ids = assets.map(\.id)
        var byAsset: [String: [ProxyRecord]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            let records = try catalog.db.read {
                try ProxyRecord.filter(sql: "assetID IN (\(marks)) AND \(Self.readyProxy)",
                                       arguments: StatementArguments(chunk)).fetchAll($0)
            }
            for record in records { byAsset[record.assetID, default: []].append(record) }
        }
        return assets.map { asset in
            let best = (byAsset[asset.id] ?? [])
                .sorted { Self.rank($0.preset) < Self.rank($1.preset) }
                .lazy.compactMap { record in self.servable(record).map { (record, $0) } }
                .first
            let info = best.map { record, file in
                RemoteProxyInfo(id: record.id, fileName: record.fileName, preset: record.preset.rawValue,
                                bytes: Int64(file.size), etag: etag(record, file),
                                megabitsPerSecond: asset.durationSeconds > 0
                                    ? Double(file.size) * 8 / asset.durationSeconds / 1_000_000 : nil)
            }
            return RemoteAsset(id: asset.id, fileName: asset.fileName, reelName: asset.reelName,
                               volumeName: asset.volumeName, formatName: asset.formatName,
                               width: asset.width, height: asset.height,
                               frameRateNum: asset.frameRateNum, frameRateDen: asset.frameRateDen,
                               durationFrames: asset.durationFrames, durationSeconds: asset.durationSeconds,
                               startTimecode: asset.startTimecode.description, startTimecodeFrames: asset.startTimecodeFrames,
                               dropFrame: asset.dropFrame,
                               audioChannels: asset.audioChannels, capturedAt: asset.capturedAt,
                               rating: asset.rating, notes: asset.notes, originalBytes: asset.fileSize, proxy: info)
        }
    }

    private func serveProxy(id: String, request: HTTPRequest, grant: EditorGrant) throws -> HTTPResponse {
        guard let record = try catalog.db.read({ try ProxyRecord.fetchOne($0, key: id) }),
              let clean = servable(record) else { return .error(404, "not found") }
        var file = clean
        var tag = etag(record, clean)
        switch watermark {
        case .off:
            break
        case .required(let watermarker):
            // The clean proxy never leaves the mini: what goes out is the marked copy, and only
            // to an editor who has locked in their initials (so the audit trail can name them).
            guard grant.initials != nil else {
                return .error(428, "choose your initials first (POST /v1/me/initials)")
            }
            guard let asset = try catalog.asset(id: record.assetID) else { return .error(404, "not found") }
            switch watermarker.state(for: record, asset: asset) {
            case .preparing:
                return HTTPResponse(status: 202, headers: [("Content-Type", "application/json"), ("Retry-After", "10")],
                                    body: .data(Data(#"{"status":"preparing"}"#.utf8)))
            case .failed:
                return .error(503, "could not prepare your copy", extra: [("Retry-After", "60")])
            case .ready(let path):
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? UInt64 else { return .error(503, "could not prepare your copy") }
                file = ServablePath(path: path, size: size,
                                    modified: Int((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))
                tag = "\"\(record.id)-wm-\(size)-\(file.modified)\""
            }
        }
        let mime = record.fileName.lowercased().hasSuffix(".mp4") ? "video/mp4" : "video/quicktime"
        var headers: [(String, String)] = [
            ("Content-Type", mime), ("Accept-Ranges", "bytes"), ("ETag", tag),
            ("Cache-Control", "private, max-age=0"), ("X-Content-Type-Options", "nosniff"),
            ("Content-Disposition", "inline; filename=\"\(Self.safeName(record.fileName))\""),
        ]
        if request.headers["if-none-match"] == tag, request.headers["range"] == nil {
            return HTTPResponse(status: 304, headers: [("ETag", tag)])
        }
        // A resumed download whose file changed underneath it must start over, not splice.
        var range = ByteRange.parse(request.headers["range"], size: file.size)
        if let ifRange = request.headers["if-range"], ifRange != tag { range = .whole }
        let isHead = request.method == "HEAD"
        switch range {
        case .unsatisfiable:
            return HTTPResponse(status: 416, headers: [("Content-Range", "bytes */\(file.size)")])
        case .partial(let start, let end):
            let length = end - start + 1
            headers.append(("Content-Range", "bytes \(start)-\(end)/\(file.size)"))
            return HTTPResponse(status: 206, headers: headers,
                                body: isHead ? .headOnly(length: length) : .file(path: file.path, offset: start, length: length))
        case .whole:
            return HTTPResponse(status: 200, headers: headers,
                                body: isHead ? .headOnly(length: file.size) : .file(path: file.path, offset: 0, length: file.size))
        }
    }

    private static func safeName(_ name: String) -> String {
        String(name.unicodeScalars.map { $0.value < 32 || $0 == "\"" || $0 == "\\" || $0.value > 126 ? "_" : Character($0) })
    }
}
#endif
