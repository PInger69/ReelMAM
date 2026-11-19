import CryptoKit
import Foundation
import Security
import GRDB
import Testing
@testable import StadaMAMCore
@testable import StadaMAMRemote

// MARK: Fixture

/// A catalogue with one clip whose original is on a "RAID" and whose proxy is a real 1 MB file.
private struct Fixture {
    let root: URL
    let proxyRoot: String
    let catalog: Catalog
    let grants: GrantStore
    let api: RemoteAPI
    let audit: AuditLog
    let asset: Asset
    let proxy: ProxyRecord
    let proxyBytes: Data
    let token: String

    init(proxyStatus: ProxyStatus = .ready, watermark: WatermarkPolicy = .off, auditPath: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(UUID().uuidString)")
        let proxies = root.appendingPathComponent("Proxies/RAID/Day1")
        try FileManager.default.createDirectory(at: proxies, withIntermediateDirectories: true)
        proxyRoot = root.appendingPathComponent("Proxies").path
        proxyBytes = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
        let file = proxies.appendingPathComponent("A001_C003.mov")
        try proxyBytes.write(to: file)

        catalog = try Catalog.inMemory()
        var a = Asset(sourcePath: "/Volumes/RAID/Day1/A001_C003.mov", fileSize: 90_000_000_000,
                      width: 4096, height: 2160, durationFrames: 240, startTimecodeFrames: 86400,
                      reelName: "A001", audioChannels: 2)
        a.capturedAt = ISO8601DateFormatter().date(from: "2026-03-14T15:30:00Z")
        a.notes = "Hero walks in"
        asset = try catalog.save(a)
        proxy = ProxyRecord(assetID: asset.id, path: file.path, preset: .h264_720, status: proxyStatus)
        try catalog.save(proxy)
        try catalog.replaceTranscript(assetID: asset.id, with: [
            TranscriptSegment(assetID: asset.id, startSeconds: 1, endSeconds: 3, text: "We leave at dawn")])
        audit = try AuditLog(path: auditPath, key: SymmetricKey(data: Data(repeating: 7, count: 32)))
        grants = try GrantStore(audit: audit)
        token = try grants.invite(name: "Maya (editor)").token
        api = RemoteAPI(catalog: catalog, grants: grants, proxyRoots: [proxyRoot], watermark: watermark, audit: audit)
    }

    func get(_ path: String, query: [String: String] = [:], headers: [String: String] = [:],
             method: String = "GET", token: String? = nil, peer: String = "1.2.3.4") -> HTTPResponse {
        var h = headers
        if let t = token ?? self.token as String? { h["authorization"] = "Bearer \(t)" }
        return api.handle(HTTPRequest(method: method, path: path, query: query, headers: h), peer: peer)
    }

    func post(_ path: String, query: [String: String] = [:], token: String? = nil) -> HTTPResponse {
        api.handle(HTTPRequest(method: "POST", path: path, query: query,
                               headers: ["authorization": "Bearer \(token ?? self.token)", "x-stradaxr": "1"]), peer: "1.2.3.4")
    }

    func anonymous(_ path: String, peer: String = "9.9.9.9") -> HTTPResponse {
        api.handle(HTTPRequest(method: "GET", path: path, headers: [:]), peer: peer)
    }
}

private func body(_ response: HTTPResponse) -> Data {
    if case .data(let data) = response.body { return data }
    return Data()
}

private func fileBytes(_ response: HTTPResponse) throws -> Data {
    guard case .file(let path, let offset, let length) = response.body else { return Data() }
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    try handle.seek(toOffset: offset)
    return try handle.read(upToCount: Int(length)) ?? Data()
}

private let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()

/// Stands in for the renderer: hands back whatever state a test sets.
private final class FakeWatermarker: ProxyWatermarker, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: WatermarkState = .preparing
    private var _calls = 0
    var state: WatermarkState { get { lock.lock(); defer { lock.unlock() }; return _state } set { lock.lock(); _state = newValue; lock.unlock() } }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func state(for proxy: ProxyRecord, asset: Asset) -> WatermarkState {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        return _state
    }
}

// MARK: HTTP parsing

@Suite struct HTTPParsingTests {
    @Test func parsesRequestAndQuery() {
        let raw = Data("GET /v1/assets?q=dawn%20light&limit=5 HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer abc\r\nRange: bytes=0-9\r\n\r\n".utf8)
        guard case .request(let request, let used) = HTTPRequestParser.parse(raw) else { Issue.record("not parsed"); return }
        #expect(used == raw.count)
        #expect(request.path == "/v1/assets")
        #expect(request.query["q"] == "dawn light")
        #expect(request.bearerToken == "abc")
        #expect(request.headers["range"] == "bytes=0-9")
        #expect(request.keepAlive)
    }

    @Test func waitsForTheEndOfTheHeaders() {
        guard case .incomplete = HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) else {
            Issue.record("should be incomplete"); return
        }
    }

    @Test func rejectsBodiesAndGarbage() {
        for raw in ["POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcd", "GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
                    "nonsense\r\n\r\n", "GET nopath HTTP/1.1\r\n\r\n", "GET / HTTP/1.1\r\nbadheader\r\n\r\n"] {
            guard case .invalid(let status) = HTTPRequestParser.parse(Data(raw.utf8)) else { Issue.record("accepted: \(raw)"); continue }
            #expect(status == 400)
        }
        guard case .invalid(let status) = HTTPRequestParser.parse(Data(repeating: 65, count: 20_000)) else { Issue.record("no limit"); return }
        #expect(status == 431)
    }

    @Test func byteRanges() {
        #expect(ByteRange.parse(nil, size: 100) == .whole)
        #expect(ByteRange.parse("bytes=10-19", size: 100) == .partial(start: 10, end: 19))
        #expect(ByteRange.parse("bytes=90-", size: 100) == .partial(start: 90, end: 99))
        #expect(ByteRange.parse("bytes=-10", size: 100) == .partial(start: 90, end: 99))
        #expect(ByteRange.parse("bytes=50-5000", size: 100) == .partial(start: 50, end: 99))
        #expect(ByteRange.parse("bytes=100-", size: 100) == .unsatisfiable)
        #expect(ByteRange.parse("bytes=0-1,5-6", size: 100) == .whole)
        #expect(ByteRange.parse("items=0-1", size: 100) == .whole)
    }
}

// MARK: Tokens and invites

@Suite struct GrantTests {
    @Test func tokenIsNeverStored() throws {
        let store = try GrantStore()
        let (grant, token) = try store.invite(name: "Maya")
        #expect(token.hasPrefix("sxr_") && token.count > 40)
        #expect(grant.tokenHash == GrantStore.hash(token) && grant.tokenHash != token)
        #expect(try store.authenticate(token: token)?.id == grant.id)
        #expect(try store.authenticate(token: token + "x") == nil)
    }

    @Test func revokeAndExpiry() throws {
        let store = try GrantStore()
        let (a, tokenA) = try store.invite(name: "A")
        let now = Date()
        let (_, tokenB) = try store.invite(name: "B", expiresAt: now.addingTimeInterval(60), now: now)
        #expect(try store.authenticate(token: tokenB, now: now.addingTimeInterval(30)) != nil)
        #expect(try store.authenticate(token: tokenB, now: now.addingTimeInterval(61)) == nil)
        try store.revoke(id: a.id)
        #expect(try store.authenticate(token: tokenA) == nil)
        #expect(try store.all().count == 2)
    }

    @Test func inviteLinkRoundTrips() throws {
        let link = InviteLink(host: "mam.example.com", token: "sxr_abc-_", certificateFingerprint: "ab12")
        #expect(InviteLink(url: link.url) == link)
        #expect(InviteLink(url: URL(string: "https://evil.example/join?host=a&token=b")!) == nil)
        #expect(InviteLink(url: URL(string: "stradaxr://join?host=a")!) == nil)
    }
}

// MARK: The API, without a network

@Suite struct RemoteAPITests {
    @Test func everyRouteNeedsAValidToken() throws {
        let f = try Fixture()
        for path in ["/v1/info", "/v1/assets", "/v1/bins", "/v1/search", "/v1/manifest",
                     "/v1/assets/\(f.asset.id)", "/v1/proxies/\(f.proxy.id)"] {
            #expect(f.anonymous(path).status == 401, "\(path)")
            #expect(f.get(path, token: "sxr_wrong").status == 401, "\(path)")
        }
        #expect(f.anonymous("/healthz").status == 200)
        #expect(f.anonymous("/elsewhere").status == 404)
        #expect(f.get("/v1/info").status == 200)
    }

    @Test func revokingStopsAccessAtOnce() throws {
        let f = try Fixture()
        #expect(f.get("/v1/info").status == 200)
        try f.grants.revoke(id: try f.grants.all()[0].id)
        #expect(f.get("/v1/info").status == 401)
        #expect(f.get("/v1/proxies/\(f.proxy.id)").status == 401)
    }

    @Test func readOnly() throws {
        let f = try Fixture()
        for method in ["POST", "PUT", "DELETE", "PATCH"] {
            #expect(f.get("/v1/assets", method: method).status == 405)
        }
    }

    @Test func failedSignInsAreThrottledButValidTokensAreNot() throws {
        let f = try Fixture()
        for _ in 0..<10 { #expect(f.anonymous("/v1/info", peer: "6.6.6.6").status == 401) }
        #expect(f.anonymous("/v1/info", peer: "6.6.6.6").status == 429)
        // The same address, now with a good token, still gets in.
        #expect(f.get("/v1/info", peer: "6.6.6.6").status == 200)
        #expect(f.anonymous("/v1/info", peer: "7.7.7.7").status == 401)
    }

    @Test func listsClipsWithoutRevealingWhereOriginalsLive() throws {
        let f = try Fixture()
        let response = f.get("/v1/assets")
        let page = try decoder.decode(RemotePage.self, from: body(response))
        #expect(page.total == 1)
        let item = page.items[0]
        #expect(item.fileName == "A001_C003.mov" && item.reelName == "A001" && item.startTimecode == "01:00:00:00")
        #expect(item.proxy?.bytes == 1_000_000 && item.proxy?.preset == "h264_720")
        let text = String(decoding: body(response), as: UTF8.self)
        #expect(!text.contains("/Volumes") && !text.contains("sourcePath") && !text.contains("bookmark"))
        let detail = String(decoding: body(f.get("/v1/assets/\(f.asset.id)")), as: UTF8.self)
        #expect(!detail.contains("/Volumes") && detail.contains("We leave at dawn"))
        #expect(!detail.contains("embedding"))
    }

    @Test func searchBinsAndDayFilters() throws {
        let f = try Fixture()
        let hits = try decoder.decode([RemoteSearchHit].self, from: body(f.get("/v1/search", query: ["q": "dawn"])))
        #expect(hits.first?.assetID == f.asset.id && hits.first?.kind == "transcript")

        let bin = Bin(name: "Day 1")
        try f.catalog.save(bin)
        try f.catalog.add(assetIDs: [f.asset.id], toBin: bin.id)
        let bins = try decoder.decode([RemoteBin].self, from: body(f.get("/v1/bins")))
        #expect(bins.map(\.name) == ["Day 1"] && bins[0].count == 1)

        func total(_ query: [String: String]) throws -> Int {
            try decoder.decode(RemotePage.self, from: body(f.get("/v1/assets", query: query))).total
        }
        #expect(try total(["bin": bin.id]) == 1)
        #expect(try total(["q": "dawn", "bin": bin.id]) == 1)
        #expect(try total(["q": "nothing-matches-this"]) == 0)
        #expect(try total(["day": "2026-03-14"]) == 1)
        #expect(try total(["day": "2026-03-15"]) == 0)
        #expect(try total(["day": "2026-03-14", "utcOffset": "600"]) == 0)   // 01:30 next day at UTC+10
        #expect(try total(["day": "garbage"]) == 0)
        #expect(try total(["hasProxy": "1"]) == 1)
    }

    @Test func manifestListsWhatABinWouldDownload() throws {
        let f = try Fixture()
        let bin = Bin(name: "Day 1")
        try f.catalog.save(bin)
        try f.catalog.add(assetIDs: [f.asset.id], toBin: bin.id)
        let manifest = try decoder.decode(RemoteManifest.self, from: body(f.get("/v1/manifest", query: ["bin": bin.id])))
        #expect(manifest.totalBytes == 1_000_000)
        #expect(manifest.items.map(\.proxy.id) == [f.proxy.id])
    }

    @Test func servesWholeFileRangesAndResume() throws {
        let f = try Fixture()
        let path = "/v1/proxies/\(f.proxy.id)"
        let whole = f.get(path)
        #expect(whole.status == 200 && whole.header("Accept-Ranges") == "bytes" && whole.body.length == 1_000_000)
        #expect(try fileBytes(whole) == f.proxyBytes)

        let part = f.get(path, headers: ["range": "bytes=100-199"])
        #expect(part.status == 206 && part.header("Content-Range") == "bytes 100-199/1000000")
        #expect(try fileBytes(part) == f.proxyBytes[100...199])

        // A download that stopped at byte 400000 resumes from there.
        let resumed = f.get(path, headers: ["range": "bytes=400000-"])
        #expect(try fileBytes(resumed) == f.proxyBytes[400_000...])

        #expect(f.get(path, headers: ["range": "bytes=2000000-"]).status == 416)

        let etag = try #require(whole.header("ETag"))
        #expect(f.get(path, headers: ["if-none-match": etag]).status == 304)
        // If the file changed since the first part was fetched, a resume must start over.
        let changed = f.get(path, headers: ["range": "bytes=400000-", "if-range": "\"stale\""])
        #expect(changed.status == 200 && changed.body.length == 1_000_000)
        let same = f.get(path, headers: ["range": "bytes=400000-", "if-range": etag])
        #expect(same.status == 206)

        let head = f.get(path, method: "HEAD")
        #expect(head.status == 200 && head.body.length == 1_000_000)
        if case .headOnly = head.body {} else { Issue.record("HEAD must not carry a body") }
    }

    @Test func neverServesAnythingButAFinishedProxyInsideTheProxyFolder() throws {
        let f = try Fixture()
        // A record pointing at a camera original, and one pointing outside the proxy folder.
        let original = f.root.appendingPathComponent("Proxies/original.mov")
        try Data("original".utf8).write(to: original)
        let asRecord = try f.catalog.save(Asset(sourcePath: original.path, fileSize: 8))
        let sneaky = ProxyRecord(assetID: asRecord.id, path: original.path, preset: .h264_720, status: .ready)
        try f.catalog.save(sneaky)
        #expect(f.get("/v1/proxies/\(sneaky.id)").status == 404)

        let outside = f.root.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outside)
        let escape = ProxyRecord(assetID: f.asset.id, path: outside.path, preset: .h264_720, status: .ready)
        try f.catalog.save(escape)
        #expect(f.get("/v1/proxies/\(escape.id)").status == 404)

        // A symlink inside the folder that leads outside it.
        let link = f.root.appendingPathComponent("Proxies/link.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linked = ProxyRecord(assetID: f.asset.id, path: link.path, preset: .h264_720, status: .ready)
        try f.catalog.save(linked)
        #expect(f.get("/v1/proxies/\(linked.id)").status == 404)

        // Not finished, or flagged as not matching its source.
        let copy = f.root.appendingPathComponent("Proxies/copy.mov")
        try f.proxyBytes.write(to: copy)
        var rendering = ProxyRecord(assetID: f.asset.id, path: copy.path, preset: .h264_1080, status: .rendering)
        try f.catalog.save(rendering)
        #expect(f.get("/v1/proxies/\(rendering.id)").status == 404)
        rendering.status = .ready
        rendering.mismatch = "24 frames instead of 25"
        try f.catalog.save(rendering)
        #expect(f.get("/v1/proxies/\(rendering.id)").status == 404)
        rendering.mismatch = nil
        try f.catalog.save(rendering)
        #expect(f.get("/v1/proxies/\(rendering.id)").status == 200)

        #expect(f.get("/v1/proxies/does-not-exist").status == 404)
        #expect(f.get("/v1/proxies/..%2F..%2Fetc%2Fpasswd").status == 404)
    }

    @Test func clipsWithoutAReadyProxyShowNoDownload() throws {
        let f = try Fixture(proxyStatus: .rendering)
        let page = try decoder.decode(RemotePage.self, from: body(f.get("/v1/assets")))
        #expect(page.total == 1 && page.items[0].proxy == nil)
        let ready = try decoder.decode(RemotePage.self, from: body(f.get("/v1/assets", query: ["hasProxy": "1"])))
        #expect(ready.total == 0)
    }
}

// MARK: The browser app

@Suite struct BrowserAppTests {
    @Test func theAppIsServedToAnyoneAndHoldsNoLibraryData() throws {
        let f = try Fixture()
        for path in ["/", "/join", "/app.js", "/app.css"] {
            let response = f.anonymous(path)
            #expect(response.status == 200, "\(path)")
            #expect(response.header("Content-Security-Policy")?.contains("default-src 'none'") == true)
            #expect(response.header("X-Frame-Options") == "DENY" && response.header("Referrer-Policy") == "no-referrer")
        }
        let html = String(decoding: body(f.anonymous("/")), as: UTF8.self)
        #expect(html.contains("/app.js") && html.contains("/app.css") && !html.contains("A001_C003"))
        #expect(f.api.handle(HTTPRequest(method: "HEAD", path: "/app.js"), peer: "x").status == 200)
        #expect(f.anonymous("/nope").status == 404)
    }

    @Test func thePageNeverBuildsHTMLFromLibraryDataOrLoadsAnythingElse() throws {
        let f = try Fixture()
        let script = String(decoding: body(f.anonymous("/app.js")), as: UTF8.self)
        for banned in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function", "http://", "https://"] {
            #expect(!script.contains(banned), "\(banned) must not appear in the page script")
        }
        let css = String(decoding: body(f.anonymous("/app.css")), as: UTF8.self)
        #expect(!css.contains("@import") && !css.contains("url(http"))
    }

    @Test func theInviteTokenBecomesACookieTheScriptCannotRead() throws {
        let f = try Fixture()
        f.api.cookieSecure = true
        var request = HTTPRequest(method: "POST", path: "/v1/session", headers: ["authorization": "Bearer \(f.token)", "x-stradaxr": "1"])
        var response = f.api.handle(request, peer: "1.2.3.4")
        #expect(response.status == 200)
        let cookie = try #require(response.header("Set-Cookie"))
        #expect(cookie.hasPrefix("sx=\(f.token);") && cookie.contains("HttpOnly") && cookie.contains("SameSite=Strict") && cookie.contains("Secure"))
        #expect(!String(decoding: body(response), as: UTF8.self).contains(f.token))

        // The cookie then does what the bearer token does, including for a proxy the page plays.
        func viaCookie(_ path: String, _ value: String? = nil) -> HTTPResponse {
            f.api.handle(HTTPRequest(method: "GET", path: path, headers: ["cookie": "other=1; sx=\(value ?? f.token); theme=dark"]), peer: "1.2.3.4")
        }
        #expect(viaCookie("/v1/info").status == 200)
        #expect(viaCookie("/v1/proxies/\(f.proxy.id)").status == 200)
        #expect(viaCookie("/v1/info", "sxr_wrong").status == 401)

        // Signing out clears it, and works even when the cookie is already gone.
        request.path = "/v1/session/end"
        response = f.api.handle(request, peer: "1.2.3.4")
        #expect(response.status == 200 && response.header("Set-Cookie")?.contains("Max-Age=0") == true)
        // Revoking still stops the cookie.
        try f.grants.revoke(id: try f.grants.all()[0].id)
        #expect(viaCookie("/v1/info").status == 401)
        // The token is nowhere in the audit trail.
        #expect(!String(decoding: try f.audit.exportJSONLines(), as: UTF8.self).contains(f.token))
    }

    @Test func writesNeedTheCustomHeaderSoOtherSitesCannotMakeThem() throws {
        let f = try Fixture()
        for path in ["/v1/me/initials", "/v1/session", "/v1/session/end"] {
            let crossSite = f.api.handle(HTTPRequest(method: "POST", path: path, query: ["value": "MR"],
                                                      headers: ["authorization": "Bearer \(f.token)"]), peer: "1.2.3.4")
            #expect(crossSite.status == 400, "\(path)")
        }
        #expect(try decoder.decode(RemoteMe.self, from: body(f.get("/v1/me"))).initials == nil)
    }

    @Test func browserInviteLinkKeepsTheTokenOutOfWhatTheServerSees() {
        let link = InviteLink(host: "mam.example.com", token: "sxr_abc-_", certificateFingerprint: "ab")
        #expect(link.webURL.absoluteString == "https://mam.example.com/join#sxr_abc-_")
        #expect(link.webURL.query == nil && link.webURL.path == "/join")
        #expect(InviteLink(host: "mam.example.com:8443", token: "t").webURL.absoluteString == "https://mam.example.com:8443/join#t")
    }

    @Test func listingCarriesWhatThePlayerNeedsForTimecode() throws {
        let f = try Fixture()
        let item = try decoder.decode(RemotePage.self, from: body(f.get("/v1/assets"))).items[0]
        #expect(item.startTimecodeFrames == 86400 && item.frameRateNum > 0 && item.frameRateDen > 0)
    }
}

// MARK: Watermarks and initials

@Suite struct WatermarkTests {
    @Test func initialsLockOnFirstSignOn() throws {
        let f = try Fixture()
        #expect(try decoder.decode(RemoteMe.self, from: body(f.get("/v1/me"))).initials == nil)
        #expect(f.post("/v1/me/initials", query: ["value": "M"]).status == 400)
        #expect(f.post("/v1/me/initials", query: ["value": "toolong"]).status == 400)
        #expect(f.post("/v1/me/initials", query: ["value": "M R"]).status == 400)
        #expect(f.post("/v1/me/initials").status == 400)
        #expect(try decoder.decode(RemoteMe.self, from: body(f.post("/v1/me/initials", query: ["value": "mr"]))).initials == "MR")
        #expect(f.post("/v1/me/initials", query: ["value": "MR"]).status == 200)    // same value is fine
        #expect(f.post("/v1/me/initials", query: ["value": "XY"]).status == 409)    // cannot change it
        try f.grants.resetInitials(id: try f.grants.all()[0].id)                    // only the owner can
        #expect(f.post("/v1/me/initials", query: ["value": "XY"]).status == 200)
        #expect(f.get("/v1/assets", method: "POST").status == 405)
        let anonymous = f.api.handle(HTTPRequest(method: "POST", path: "/v1/me/initials", query: ["value": "ZZ"], headers: ["x-stradaxr": "1"]), peer: "5.5.5.5")
        #expect(anonymous.status == 401)
    }

    @Test func onlyTheMarkedCopyIsEverServed() throws {
        let fake = FakeWatermarker()
        let f = try Fixture(watermark: .required(fake))
        let path = "/v1/proxies/\(f.proxy.id)"
        #expect(f.get(path).status == 428)
        #expect(fake.calls == 0)
        #expect(f.post("/v1/me/initials", query: ["value": "MR"]).status == 200)

        let waiting = f.get(path)
        #expect(waiting.status == 202 && waiting.header("Retry-After") != nil)
        #expect(f.get(path, method: "HEAD").status == 202)
        fake.state = .failed("encoder crashed")
        #expect(f.get(path).status == 503)
        fake.state = .ready(path: f.root.appendingPathComponent("does-not-exist.mov").path)
        #expect(f.get(path).status == 503)

        let marked = f.root.appendingPathComponent("cache-marked.mov")
        let markedBytes = Data((0..<250_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try markedBytes.write(to: marked)
        fake.state = .ready(path: marked.path)
        let whole = f.get(path)
        #expect(whole.status == 200 && whole.body.length == 250_000)
        #expect(try fileBytes(whole) == markedBytes)
        #expect(try fileBytes(whole) != f.proxyBytes)
        let part = f.get(path, headers: ["range": "bytes=1000-1999"])
        #expect(part.status == 206 && part.header("Content-Range") == "bytes 1000-1999/250000")
        #expect(try fileBytes(part) == markedBytes[1000...1999])
        // It is one shared copy, so every editor gets the same validator.
        let other = try f.grants.invite(name: "Sam")
        _ = f.post("/v1/me/initials", query: ["value": "SB"], token: other.token)
        #expect(f.get(path, token: other.token).header("ETag") == whole.header("ETag"))
    }

    @Test func requiredPolicyWithoutAnInitialsLockServesNothing() throws {
        let f = try Fixture(watermark: .required(FakeWatermarker()))
        #expect(f.get("/v1/proxies/\(f.proxy.id)").status == 428)
        #expect(f.get("/v1/proxies/\(f.proxy.id)", headers: ["range": "bytes=0-9"]).status == 428)
    }
}

// MARK: The audit trail

@Suite struct AuditTests {
    private func tempPath() -> String { NSTemporaryDirectory() + "audit-\(UUID().uuidString).sqlite" }
    private let key = SymmetricKey(data: Data(repeating: 7, count: 32))

    @Test func everyRequestIsRecordedWithWhoWhatAndHowMuch() throws {
        let f = try Fixture()
        _ = f.post("/v1/me/initials", query: ["value": "MR"])
        _ = f.get("/v1/search", query: ["q": "dawn", "limit": "5"])
        _ = f.get("/v1/proxies/\(f.proxy.id)", headers: ["range": "bytes=0-99"])
        _ = f.get("/v1/proxies/missing")
        let log = try f.audit.entries(kind: .request, newestFirst: false)
        #expect(log.map(\.path) == ["/v1/me/initials", "/v1/search", "/v1/proxies/\(f.proxy.id)", "/v1/proxies/missing"])
        let editorID = try f.grants.all()[0].id
        let download = log[2]
        #expect(download.status == 206 && download.bytes == 100 && download.range == "bytes=0-99")
        #expect(download.grantID == editorID && download.editor == "Maya (editor)" && download.initials == "MR")
        #expect(log[1].query == "limit=5&q=dawn")
        #expect(log[3].status == 404)
        #expect(log.allSatisfy { $0.peer == "1.2.3.4" })
        #expect(try f.audit.verify().ok)
    }

    @Test func failedSignInsAreRecordedAndAttributedWhenTheTokenIsKnown() throws {
        let f = try Fixture()
        #expect(f.anonymous("/v1/info").status == 401)
        #expect(f.get("/v1/info", token: "sxr_guess").status == 401)
        try f.grants.revoke(id: try f.grants.all()[0].id)
        #expect(f.get("/v1/info").status == 401)
        let failures = try f.audit.entries(kind: .signInFailed, newestFirst: false)
        #expect(failures.map(\.detail) == ["no token", "unknown token", "revoked token"])
        #expect(failures[2].editor == "Maya (editor)" && failures[2].grantID != nil)
        #expect(failures[1].grantID == nil)
        // The token itself is never written down.
        let dump = String(decoding: try f.audit.exportJSONLines(), as: UTF8.self)
        #expect(!dump.contains(f.token) && !dump.contains("sxr_guess"))
        // Past the throttle limit nothing more is written, so a flood cannot fill the log.
        for _ in 0..<50 { _ = f.anonymous("/v1/info", peer: "6.6.6.6") }
        #expect(try f.audit.entries(kind: .signInFailed, limit: 1000).count < 20)
    }

    @Test func ownerActionsAreRecorded() throws {
        let f = try Fixture()
        let editor = try f.grants.invite(name: "Sam")
        try f.grants.resetInitials(id: editor.grant.id)
        try f.grants.revoke(id: editor.grant.id)
        let admin = try f.audit.entries(kind: .admin, newestFirst: false)
        #expect(admin.map(\.path) == ["invite", "invite", "reset-initials", "revoke"])
        #expect(admin[3].grantID == editor.grant.id && admin[3].editor == "Sam")
    }

    @Test func nothingIsServedThatCannotBeRecorded() throws {
        let f = try Fixture()
        f.audit.failWrites = true
        let proxy = f.get("/v1/proxies/\(f.proxy.id)")
        #expect(proxy.status == 503)
        if case .file = proxy.body { Issue.record("a file was offered without a record") }
        #expect(f.get("/v1/assets").status == 503)
        #expect(f.anonymous("/v1/info").status == 503)
        f.audit.failWrites = false
        #expect(f.get("/v1/info").status == 200)
    }

    @Test func entriesCannotBeChangedOrRemovedThroughTheDatabase() throws {
        let path = tempPath()
        let f = try Fixture(auditPath: path)
        _ = f.get("/v1/info")
        let direct = try DatabaseQueueForTests.open(path)
        #expect(throws: (any Error).self) { try direct.execute("UPDATE auditEntry SET status = 200") }
        #expect(throws: (any Error).self) { try direct.execute("DELETE FROM auditEntry") }
        #expect(try f.audit.verify().ok)
    }

    @Test func tamperingIsDetectedEvenWithTheTriggersRemoved() throws {
        let path = tempPath()
        let f = try Fixture(auditPath: path)
        for i in 0..<5 { _ = f.get("/v1/assets", query: ["offset": "\(i)"]) }
        let anchor = try #require(try f.audit.anchor())
        #expect(anchor.seq == 6)    // the editor's invite, then five requests
        #expect(try f.audit.verify(against: anchor).ok)

        let direct = try DatabaseQueueForTests.open(path)
        try direct.execute("DROP TRIGGER auditEntry_no_update; DROP TRIGGER auditEntry_no_delete;")

        // 1. Rewriting an entry.
        try direct.execute("UPDATE auditEntry SET path = '/v1/something-else' WHERE seq = 4")
        var result = try f.audit.verify()
        #expect(!result.ok && result.firstBadSeq == 4)
        try direct.execute("UPDATE auditEntry SET path = '/v1/assets' WHERE seq = 4")
        #expect(try f.audit.verify().ok)

        // 2. Removing an entry from the middle.
        try direct.execute("CREATE TABLE keep AS SELECT * FROM auditEntry WHERE seq = 5; DELETE FROM auditEntry WHERE seq = 5")
        result = try f.audit.verify()
        #expect(!result.ok && result.firstBadSeq == 5)
        try direct.execute("INSERT INTO auditEntry SELECT * FROM keep; DROP TABLE keep")
        #expect(try f.audit.verify().ok)

        // 3. Cutting entries off the end is caught against the anchor noted earlier.
        try direct.execute("DELETE FROM auditEntry WHERE seq > 4")
        #expect(try f.audit.verify().ok)    // a shorter log is still a valid chain on its own...
        result = try f.audit.verify(against: anchor)
        #expect(!result.ok && result.problem?.contains("stops at 4") == true)
    }

    @Test func aChainRebuiltWithoutTheKeyDoesNotVerify() throws {
        let path = tempPath()
        let original = try AuditLog(path: path, key: key)
        for i in 0..<3 { try original.append(AuditEvent(kind: .request, method: "GET", path: "/v1/\(i)")) }
        #expect(try original.verify().ok)
        // Someone who knows the file but not the key checks it with a different key: nothing matches.
        let stranger = try AuditLog(path: path, key: SymmetricKey(data: Data(repeating: 9, count: 32)))
        let result = try stranger.verify()
        #expect(!result.ok && result.firstBadSeq == 1)
    }

    @Test func survivesReopeningAndExports() throws {
        let path = tempPath()
        let first = try AuditLog(path: path, key: key)
        try first.append(AuditEvent(kind: .request, grantID: "g", editor: "Maya", method: "GET", path: "/v1/info", status: 200))
        let anchor = try #require(try first.anchor())
        let second = try AuditLog(path: path, key: key)      // as after a restart
        try second.append(AuditEvent(kind: .request, grantID: "g", editor: "Maya", method: "GET", path: "/v1/bins", status: 200))
        #expect(try second.verify(against: anchor).ok && (try second.verify().entries) == 2)
        let lines = String(decoding: try second.exportJSONLines(), as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 2 && lines[0].contains("/v1/info") && lines[1].contains("/v1/bins"))
        let keyPath = NSTemporaryDirectory() + "auditkey-\(UUID().uuidString)"
        let made = try AuditLog.loadOrCreateKey(at: keyPath)
        #expect(made == (try AuditLog.loadOrCreateKey(at: keyPath)))
        let mode = try FileManager.default.attributesOfItem(atPath: keyPath)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func sequenceNumbersStayUniqueUnderConcurrentWrites() async throws {
        let log = try AuditLog(path: tempPath(), key: key)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { _ = try? log.append(AuditEvent(kind: .request, method: "GET", path: "/\(i)")) }
            }
        }
        let result = try log.verify()
        #expect(result.ok && result.entries == 200)
    }
}

/// Opens the audit file the way someone with access to it could, bypassing the app.
private enum DatabaseQueueForTests {
    final class Handle {
        let queue: DatabaseQueue
        init(_ path: String) throws { queue = try DatabaseQueue(path: path) }
        func execute(_ sql: String) throws { try queue.write { try $0.execute(sql: sql) } }
    }
    static func open(_ path: String) throws -> Handle { try Handle(path) }
}

// MARK: The real server

private func session(delegate: URLSessionDelegate? = nil) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
}

private func request(_ url: String, token: String?, range: String? = nil, method: String = "GET") -> URLRequest {
    var r = URLRequest(url: URL(string: url)!)
    r.httpMethod = method
    if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let range { r.setValue(range, forHTTPHeaderField: "Range") }
    return r
}

@Suite struct RemoteServerTests {
    @Test func downloadsAProxyInTwoResumedParts() async throws {
        let f = try Fixture()
        let server = RemoteServer(api: f.api)
        let port = try await server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        let urlSession = session()

        let (_, denied) = try await urlSession.data(for: request("\(base)/v1/info", token: nil))
        #expect((denied as? HTTPURLResponse)?.statusCode == 401)

        let (infoData, info) = try await urlSession.data(for: request("\(base)/v1/info", token: f.token))
        #expect((info as? HTTPURLResponse)?.statusCode == 200)
        #expect(try decoder.decode(RemoteInfo.self, from: infoData).editor == "Maya (editor)")

        // First 300 000 bytes, then "reconnect" and ask for the rest.
        let (first, r1) = try await urlSession.data(for: request("\(base)/v1/proxies/\(f.proxy.id)", token: f.token, range: "bytes=0-299999"))
        #expect((r1 as? HTTPURLResponse)?.statusCode == 206)
        let (rest, r2) = try await urlSession.data(for: request("\(base)/v1/proxies/\(f.proxy.id)", token: f.token, range: "bytes=300000-"))
        #expect((r2 as? HTTPURLResponse)?.statusCode == 206)
        #expect(first + rest == f.proxyBytes)

        let (whole, r3) = try await urlSession.data(for: request("\(base)/v1/proxies/\(f.proxy.id)", token: f.token))
        #expect((r3 as? HTTPURLResponse)?.statusCode == 200 && whole == f.proxyBytes)

        let (_, head) = try await urlSession.data(for: request("\(base)/v1/proxies/\(f.proxy.id)", token: f.token, method: "HEAD"))
        #expect((head as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "1000000")

        // The audit trail has the request and, once the bytes had gone, what was really sent.
        let transfers = try f.audit.entries(kind: .transfer, newestFirst: false)
        #expect(transfers.contains { $0.bytes == 1_000_000 && $0.detail == "complete" })
        #expect(transfers.contains { $0.bytes == 300_000 && $0.detail == "complete" })
        #expect(try f.audit.verify().ok)

        // Revoked mid-session: the very next request fails.
        try f.grants.revoke(id: try f.grants.all()[0].id)
        let (_, after) = try await urlSession.data(for: request("\(base)/v1/proxies/\(f.proxy.id)", token: f.token))
        #expect((after as? HTTPURLResponse)?.statusCode == 401)
    }

    @Test func aDownloadThatIsCutOffIsRecordedAsInterrupted() async throws {
        let f = try Fixture()
        // A big proxy, so the server is still sending when the client walks away.
        let big = f.root.appendingPathComponent("Proxies/big.mov")
        try Data(count: 60_000_000).write(to: big)
        let record = ProxyRecord(assetID: f.asset.id, path: big.path, preset: .h264_1080, status: .ready)
        try f.catalog.save(record)
        let server = RemoteServer(api: f.api)
        let port = try await server.start()
        defer { server.stop() }
        let client = session()
        let (bytes, _) = try await client.bytes(for: request("http://127.0.0.1:\(port)/v1/proxies/\(record.id)", token: f.token))
        var got = 0
        for try await _ in bytes { got += 1; if got >= 1000 { break } }
        client.invalidateAndCancel()      // the editor's connection drops
        var entry: AuditRecord?
        for _ in 0..<100 where entry == nil {
            entry = try f.audit.entries(kind: .transfer).first { $0.detail == "interrupted" }
            if entry == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        let interrupted = try #require(entry)
        #expect(interrupted.bytes < 60_000_000 && interrupted.path == "/v1/proxies/\(record.id)")
        #expect(interrupted.ref != nil)
        #expect(try f.audit.verify().ok)
    }

    @Test func refusesWritesAndMalformedRequests() async throws {
        let f = try Fixture()
        let server = RemoteServer(api: f.api)
        let port = try await server.start()
        defer { server.stop() }
        var post = request("http://127.0.0.1:\(port)/v1/assets", token: f.token)
        post.httpMethod = "POST"
        post.httpBody = Data("x".utf8)
        let (_, response) = try await session().data(for: post)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
    }

    /// Direct mode: the mini serves TLS itself with a self-signed certificate, and the
    /// editor's app trusts only the fingerprint from the invite.
    @Test func servesTLSToAPinnedClientOnly() async throws {
        let (identity, certificate) = try makeSelfSignedIdentity()
        let f = try Fixture()
        let server = RemoteServer(api: f.api, identity: identity)
        let port = try await server.start()
        defer { server.stop() }
        let url = "https://localhost:\(port)/v1/info"

        let pinned = session(delegate: PinnedCertificateDelegate(fingerprint: PinnedCertificateDelegate.fingerprint(of: certificate)))
        let (_, ok) = try await pinned.data(for: request(url, token: f.token))
        #expect((ok as? HTTPURLResponse)?.statusCode == 200)

        let wrongPin = session(delegate: PinnedCertificateDelegate(fingerprint: String(repeating: "0", count: 64)))
        await #expect(throws: (any Error).self) { _ = try await wrongPin.data(for: request(url, token: f.token)) }
        // Without a pin the self-signed certificate is not trusted.
        await #expect(throws: (any Error).self) { _ = try await session().data(for: request(url, token: f.token)) }
    }
}

/// A throwaway certificate through the same code the app uses.
private func makeSelfSignedIdentity() throws -> (SecIdentity, SecCertificate) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID().uuidString)").path
    let made = try ServerIdentity.loadOrCreate(in: dir, passphrase: "test", hostnames: ["localhost"])
    return (made.identity, made.certificate)
}

@Suite struct ServerIdentityTests {
    @Test func isMadeOnceAndReusedWhileItCoversTheNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("id-\(UUID().uuidString)").path
        let first = try ServerIdentity.loadOrCreate(in: dir, passphrase: "pw", hostnames: ["mam.example.com"])
        let again = try ServerIdentity.loadOrCreate(in: dir, passphrase: "pw", hostnames: ["mam.example.com"])
        #expect(first.fingerprint == again.fingerprint && first.fingerprint.count == 64)
        // A new public name needs a new certificate, so a new fingerprint (editors are re-invited).
        let renamed = try ServerIdentity.loadOrCreate(in: dir, passphrase: "pw", hostnames: ["other.example.com"])
        #expect(renamed.fingerprint != first.fingerprint)
        let mode = try FileManager.default.attributesOfItem(atPath: dir + "/identity.p12")[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(!FileManager.default.fileExists(atPath: dir + "/key.pem"))   // the loose private key is not left behind
        // A lost passphrase means a new certificate, not a stuck server.
        let recovered = try ServerIdentity.loadOrCreate(in: dir, passphrase: "different", hostnames: ["other.example.com"])
        #expect(recovered.fingerprint != renamed.fingerprint)
    }
}

// MARK: The owner's controller

@Suite struct RemoteHubTests {
    private func makeHub(_ fake: FakeWatermarker = FakeWatermarker()) throws -> (RemoteHub, Fixture, String) {
        let f = try Fixture()
        let dir = NSTemporaryDirectory() + "hub-\(UUID().uuidString)"
        return (try RemoteHub(directory: dir, catalog: f.catalog, watermarker: fake), f, dir)
    }

    @Test func invitesAnEditorWhoCanThenSignIn() async throws {
        let (hub, f, _) = try makeHub()
        let config = RemoteConfig(transport: .tunnel, publicHost: "mam.example.com", proxyRoots: [f.proxyRoot],
                                  certificatePassphrase: "pw")
        let running = try await hub.start(config)
        defer { hub.stop() }
        #expect(running.fingerprint == nil && running.transport == .tunnel && running.port > 0)

        let (grant, link) = try hub.invite(name: "  Maya  ", expiresInDays: 30, config: config)
        #expect(grant.name == "Maya" && link.host == "mam.example.com" && link.certificateFingerprint == nil)
        #expect(grant.expiresAt != nil)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(running.port)/v1/info")!)
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session().data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        var summary = try #require(try hub.editors().first { $0.id == grant.id })
        #expect(summary.status == .waitingForInitials && summary.initials == nil)
        _ = try hub.grants.lockInitials(id: grant.id, "MR")
        summary = try #require(try hub.editors().first { $0.id == grant.id })
        #expect(summary.status == .active && summary.initials == "MR")
        try hub.grants.revoke(id: grant.id)
        #expect(try hub.editors().first { $0.id == grant.id }?.status == .revoked)
        let (_, after) = try await session().data(for: request)
        #expect((after as? HTTPURLResponse)?.statusCode == 401)
        #expect(throws: (any Error).self) { _ = try hub.invite(name: "   ", expiresInDays: nil, config: config) }
        #expect(throws: (any Error).self) {
            _ = try hub.invite(name: "X", expiresInDays: nil, config: RemoteConfig(transport: .tunnel, publicHost: " ", proxyRoots: [f.proxyRoot], certificatePassphrase: "pw"))
        }
    }

    @Test func relayModeServesTLSAndThePinIsInTheInvite() async throws {
        let (hub, f, _) = try makeHub()
        let config = RemoteConfig(transport: .relayPassthrough, publicHost: "localhost", proxyRoots: [f.proxyRoot],
                                  certificatePassphrase: "pw")
        let running = try await hub.start(config)
        defer { hub.stop() }
        let (_, link) = try hub.invite(name: "Sam", expiresInDays: nil, config: config)
        let pin = try #require(link.certificateFingerprint)
        #expect(pin == running.fingerprint && InviteLink(url: link.url)?.certificateFingerprint == pin)
        var request = URLRequest(url: URL(string: "https://localhost:\(running.port)/v1/info")!)
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        let (_, ok) = try await session(delegate: PinnedCertificateDelegate(fingerprint: pin)).data(for: request)
        #expect((ok as? HTTPURLResponse)?.statusCode == 200)
        // The certificate is kept: the same one comes back after a restart.
        hub.stop()
        let again = try await hub.start(config)
        #expect(again.fingerprint == pin)
    }

    @Test func refusesToStartWithoutWhatItNeeds() async throws {
        let (hub, f, _) = try makeHub()
        await #expect(throws: (any Error).self) {
            _ = try await hub.start(RemoteConfig(transport: .tunnel, publicHost: "x", proxyRoots: [], certificatePassphrase: "pw"))
        }
        await #expect(throws: (any Error).self) {
            _ = try await hub.start(RemoteConfig(transport: .direct, publicHost: "", proxyRoots: [f.proxyRoot], certificatePassphrase: "pw"))
        }
        #expect(hub.running == nil)
    }

    @Test func verifyReportsIntactAndTamperedLogs() async throws {
        let (hub, f, dir) = try makeHub()
        let config = RemoteConfig(transport: .tunnel, publicHost: "mam.example.com", proxyRoots: [f.proxyRoot], certificatePassphrase: "pw")
        _ = try hub.invite(name: "Maya", expiresInDays: nil, config: config)
        let first = try hub.verifyAudit(against: nil)
        #expect(first.ok && first.entries == 1 && first.anchor != nil && first.message.contains("anchor"))
        #expect(try hub.verifyAudit(against: first.anchor).ok)
        // Someone alters the file behind the app's back.
        let direct = try DatabaseQueueForTests.open(dir + "/audit.sqlite")
        try direct.execute("DROP TRIGGER auditEntry_no_update; UPDATE auditEntry SET editor = 'Someone else'")
        let broken = try hub.verifyAudit(against: first.anchor)
        #expect(!broken.ok && broken.message.contains("tampered"))
        let export = URL(fileURLWithPath: NSTemporaryDirectory() + "audit-\(UUID().uuidString).jsonl")
        try hub.exportAudit(to: export)
        #expect(try String(contentsOf: export, encoding: .utf8).contains("invite"))
    }
}

// MARK: Demo (not a test: set STRADAXR_DEMO=<seconds> to serve a sample library for trying the browser app)

@Suite struct DemoServer {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STRADAXR_DEMO"] != nil))
    func serveASampleLibrary() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["STRADAXR_DEMO"] ?? "") ?? 300
        let f = try Fixture(watermark: .off)
        // A real, playable HEVC proxy (testsrc2 with a mark-style box in the lower-left quarter).
        let clip = f.root.appendingPathComponent("Proxies/RAID/Day1/A001_C003.mov")
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        let tools = try #require(ffmpeg)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tools)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24:duration=30",
                       "-f", "lavfi", "-i", "sine=frequency=330:duration=30", "-vf", "drawtext=text=x:fontsize=1,format=yuv420p",
                       "-c:v", "libx265", "-preset", "veryfast", "-tag:v", "hvc1", "-c:a", "aac", "-timecode", "01:00:00:00", clip.path]
        // drawtext may be missing in this FFmpeg build; retry without it.
        try? p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let q = Process()
            q.executableURL = URL(fileURLWithPath: tools)
            q.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24:duration=30",
                           "-f", "lavfi", "-i", "sine=frequency=330:duration=30", "-pix_fmt", "yuv420p",
                           "-c:v", "libx265", "-preset", "veryfast", "-tag:v", "hvc1", "-c:a", "aac", "-timecode", "01:00:00:00", clip.path]
            try q.run(); q.waitUntilExit()
        }
        var a = f.asset
        a.durationFrames = 720; a.width = 3840; a.height = 2160; a.formatName = "Apple ProRes 422 HQ"
        _ = try f.catalog.save(a)
        try f.catalog.replaceTranscript(assetID: a.id, with: [
            TranscriptSegment(assetID: a.id, startSeconds: 2, endSeconds: 5, text: "We leave at dawn, before they wake."),
            TranscriptSegment(assetID: a.id, startSeconds: 9, endSeconds: 12, text: "Bring the map. We will not come back this way."),
        ])
        try f.catalog.save(Marker(assetID: a.id, inFrame: 120, name: "Best take", note: "Hold this one"))
        for (i, name) in ["A001_C004.mov", "A002_C001.mov", "B001_C002.mov"].enumerated() {
            var extra = Asset(sourcePath: "/Volumes/RAID/Day1/\(name)", fileSize: 70_000_000_000 + Int64(i), width: 4096, height: 2160,
                              durationFrames: 480 + i * 100, startTimecodeFrames: 90000 + i * 5000, reelName: "A00\(i + 1)", audioChannels: 4)
            extra.capturedAt = ISO8601DateFormatter().date(from: "2026-03-14T1\(i):00:00Z")
            extra.notes = ["Wide of the valley", "Close on the map", "Campfire coverage"][i]
            try f.catalog.save(extra)
        }
        let day1 = Bin(name: "Day 1"), valley = Bin(name: "Valley", parentID: day1.id)
        try f.catalog.save(day1); try f.catalog.save(valley)
        try f.catalog.add(assetIDs: [a.id], toBin: day1.id)
        let fake = FakeWatermarker()
        fake.state = .ready(path: clip.path)
        let api = RemoteAPI(catalog: f.catalog, grants: f.grants, proxyRoots: [f.proxyRoot], watermark: .required(fake), audit: f.audit)
        let server = RemoteServer(api: api, port: 8787)
        let port = try await server.start()
        let link = InviteLink(host: "127.0.0.1:\(port)", token: f.token)
        try "http://127.0.0.1:\(port)/join#\(f.token)\n".write(toFile: ProcessInfo.processInfo.environment["STRADAXR_DEMO_LINK"] ?? "/tmp/stradaxr-demo-link.txt", atomically: true, encoding: .utf8)
        _ = link
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        server.stop()
    }
}
