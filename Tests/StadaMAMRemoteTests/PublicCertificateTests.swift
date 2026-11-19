import CryptoKit
import Foundation
import Security
import Testing
@testable import StadaMAMCore
@testable import StadaMAMRemote

// MARK: A stand-in certificate authority

private func unbase64URL(_ text: String) -> Data? {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
}

private func openssl(_ arguments: [String]) throws {
    try ServerIdentity.run("/usr/bin/openssl", arguments)
}

/// Speaks the same protocol as Let's Encrypt, strictly: every request must be signed by the
/// account key with a nonce it handed out, and it really fetches the check over HTTP before
/// signing anything. Its certificates chain root → intermediate → server, like the real ones.
private final class FakeAuthority: @unchecked Sendable {
    let dir: String
    let base = "https://ca.test"
    let root: SecCertificate
    private let lock = NSLock()
    private var nonces: Set<String> = []
    private var accounts: [String: P256.Signing.PublicKey] = [:]
    private var thumbprints: [String: String] = [:]
    private var orders: [Int: (host: String, status: String, authorized: Bool, failure: String?)] = [:]
    private var _signedRequests = 0
    private var _rejectNextNonce = false
    /// Where the authority looks for the check: the Mac's plain-HTTP port.
    var challengePort: UInt16 = 0
    /// False behaves like a router that does not send port 80 to the Mac.
    var reachable = true
    var days = 90

    var issued: Int { lock.lock(); defer { lock.unlock() }; return orders.values.filter { $0.status == "valid" }.count }
    var accountCount: Int { lock.lock(); defer { lock.unlock() }; return accounts.count }
    var signedRequests: Int { lock.lock(); defer { lock.unlock() }; return _signedRequests }
    func rejectNextNonce() { lock.lock(); _rejectNextNonce = true; lock.unlock() }

    init() throws {
        dir = NSTemporaryDirectory() + "ca-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", dir + "/root.key", "-out", dir + "/root.pem",
                     "-days", "30", "-subj", "/CN=Test Root", "-addext", "basicConstraints=critical,CA:TRUE",
                     "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
        try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", dir + "/int.key", "-out", dir + "/int.csr",
                     "-subj", "/CN=Test Intermediate"])
        try "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
            .write(toFile: dir + "/int.cnf", atomically: true, encoding: .utf8)
        try openssl(["x509", "-req", "-in", dir + "/int.csr", "-CA", dir + "/root.pem", "-CAkey", dir + "/root.key",
                     "-CAcreateserial", "-out", dir + "/int.pem", "-days", "30", "-extfile", dir + "/int.cnf"])
        try openssl(["x509", "-in", dir + "/root.pem", "-outform", "DER", "-out", dir + "/root.der"])
        root = SecCertificateCreateWithData(nil, try Data(contentsOf: URL(fileURLWithPath: dir + "/root.der")) as CFData)!
    }

    var authority: PublicCertificate.Authority {
        PublicCertificate.Authority(directory: URL(string: base + "/dir")!, pollInterval: 0.05,
                                    transport: { [self] in try await answer($0) })
    }

    private func freshNonce() -> String {
        let nonce = UUID().uuidString
        lock.lock(); nonces.insert(nonce); lock.unlock()
        return nonce
    }

    private func reply(_ request: URLRequest, _ status: Int, _ object: Any?, headers: [String: String] = [:],
                       raw: Data? = nil) -> (Data, HTTPURLResponse) {
        var fields = headers
        fields["Replay-Nonce"] = freshNonce()
        let data = raw ?? object.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!)
    }

    private func problem(_ request: URLRequest, _ status: Int, _ type: String, _ detail: String) -> (Data, HTTPURLResponse) {
        reply(request, status, ["type": "urn:ietf:params:acme:error:\(type)", "detail": detail])
    }

    func answer(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        if path == "/dir" {
            return reply(request, 200, ["newNonce": base + "/nonce", "newAccount": base + "/account", "newOrder": base + "/order"])
        }
        if path == "/nonce" { return reply(request, 200, nil) }

        // Everything else must be a correctly signed request.
        guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Content-Type") == "application/jose+json",
              let body = request.httpBody,
              let jws = try JSONSerialization.jsonObject(with: body) as? [String: String],
              let protected = jws["protected"], let payloadText = jws["payload"], let signatureText = jws["signature"],
              let header = try unbase64URL(protected).flatMap({ try JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              header["alg"] as? String == "ES256", header["url"] as? String == request.url!.absoluteString,
              let nonce = header["nonce"] as? String, let signature = unbase64URL(signatureText) else {
            return problem(request, 400, "malformed", "not a signed request")
        }
        let (known, reject): (Bool, Bool) = locked {
            let known = nonces.remove(nonce) != nil
            let reject = _rejectNextNonce
            _rejectNextNonce = false
            return (known, reject)
        }
        guard known, !reject else { return problem(request, 400, "badNonce", "that nonce is not good") }

        var key: P256.Signing.PublicKey?
        var kid = header["kid"] as? String
        if let jwk = header["jwk"] as? [String: String], path == "/account",
           let x = jwk["x"].flatMap(unbase64URL), let y = jwk["y"].flatMap(unbase64URL) {
            key = try? P256.Signing.PublicKey(rawRepresentation: x + y)
            let canonical = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"\(jwk["x"]!)\",\"y\":\"\(jwk["y"]!)\"}"
            let print = Data(SHA256.hash(data: Data(canonical.utf8))).base64URL
            kid = locked {
                let kid = thumbprints.first { $0.value == print }?.key ?? base + "/account/\(accounts.count + 1)"
                thumbprints[kid] = print
                return kid
            }
        } else if let kid {
            key = locked { accounts[kid] }
        }
        guard let key, let kid, let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              key.isValidSignature(parsed, for: Data("\(protected).\(payloadText)".utf8)) else {
            return problem(request, 401, "unauthorized", "the signature does not match the account")
        }
        locked { _signedRequests += 1 }
        let payload = unbase64URL(payloadText).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let parts = path.split(separator: "/").map(String.init)
        let number = parts.count > 1 ? Int(parts[1]) ?? 0 : 0

        switch parts.first {
        case "account":
            guard payload?["termsOfServiceAgreed"] as? Bool == true else {
                return problem(request, 400, "userActionRequired", "the terms were not agreed")
            }
            let existed: Bool = locked { let existed = accounts[kid] != nil; accounts[kid] = key; return existed }
            return reply(request, existed ? 200 : 201, ["status": "valid"], headers: ["Location": kid])
        case "order" where number == 0:
            guard let host = ((payload?["identifiers"] as? [[String: String]])?.first)?["value"] else {
                return problem(request, 400, "malformed", "no name")
            }
            let id: Int = locked {
                let id = orders.count + 1
                orders[id] = (host, "pending", false, nil)
                return id
            }
            return reply(request, 201, order(id), headers: ["Location": base + "/order/\(id)"])
        case "order":
            return reply(request, 200, order(number))
        case "authz":
            return reply(request, 200, authorization(number))
        case "chall":
            let print = locked { thumbprints[kid] ?? "" }
            await check(number, expecting: "token-\(number).\(print)")
            return reply(request, 200, ["type": "http-01", "status": "processing", "url": base + "/chall/\(number)", "token": "token-\(number)"])
        case "finalize":
            guard locked({ orders[number]?.authorized }) == true else { return problem(request, 403, "orderNotReady", "not authorised") }
            guard let csr = (payload?["csr"] as? String).flatMap(unbase64URL) else { return problem(request, 400, "badCSR", "no request") }
            try sign(csr, order: number)
            return reply(request, 200, order(number))
        case "cert":
            let pem = try String(contentsOfFile: dir + "/leaf-\(number).pem", encoding: .utf8)
                + String(contentsOfFile: dir + "/int.pem", encoding: .utf8)
            return reply(request, 200, nil, raw: Data(pem.utf8))
        default:
            return problem(request, 404, "malformed", "no such address")
        }
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    private func order(_ id: Int) -> [String: Any] {
        let o = locked { orders[id]! }
        var object: [String: Any] = ["status": o.status == "pending" && o.authorized ? "ready" : o.status,
                                     "authorizations": [base + "/authz/\(id)"], "finalize": base + "/finalize/\(id)"]
        if o.status == "valid" { object["certificate"] = base + "/cert/\(id)" }
        return object
    }

    private func authorization(_ id: Int) -> [String: Any] {
        let o = locked { orders[id]! }
        var challenge: [String: Any] = ["type": "http-01", "url": base + "/chall/\(id)", "token": "token-\(id)"]
        if let failure = o.failure { challenge["error"] = ["detail": failure] }
        return ["status": o.failure != nil ? "invalid" : o.authorized ? "valid" : "pending",
                "identifier": ["type": "dns", "value": o.host],
                "challenges": [["type": "dns-01", "url": base + "/chall-dns/\(id)", "token": "x"], challenge]]
    }

    /// Fetches the check the way the real authority does, from the Mac's plain-HTTP port.
    private func check(_ id: Int, expecting: String) async {
        var failure: String?
        if !reachable {
            failure = "Timeout during connect (likely firewall problem)"
        } else {
            let url = URL(string: "http://127.0.0.1:\(challengePort)/.well-known/acme-challenge/token-\(id)")!
            let got = try? await URLSession(configuration: .ephemeral).data(from: url)
            if got.map({ String(decoding: $0.0, as: UTF8.self) }) != expecting { failure = "The key authorization file from the server did not match" }
        }
        locked {
            orders[id]?.authorized = failure == nil
            orders[id]?.failure = failure
        }
    }

    private func sign(_ csr: Data, order id: Int) throws {
        let host = locked { orders[id]!.host }
        try csr.write(to: URL(fileURLWithPath: dir + "/leaf-\(id).der"))
        try openssl(["req", "-inform", "DER", "-in", dir + "/leaf-\(id).der", "-out", dir + "/leaf-\(id).csr"])
        try "subjectAltName=DNS:\(host)\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n"
            .write(toFile: dir + "/leaf-\(id).cnf", atomically: true, encoding: .utf8)
        try openssl(["x509", "-req", "-in", dir + "/leaf-\(id).csr", "-CA", dir + "/int.pem", "-CAkey", dir + "/int.key",
                     "-set_serial", "\(1000 + id)", "-out", dir + "/leaf-\(id).pem", "-days", "\(days)",
                     "-extfile", dir + "/leaf-\(id).cnf"])
        locked { orders[id]?.status = "valid" }
    }
}

/// A browser that trusts only the stand-in authority's root, checks the name like a browser
/// does, and does not follow redirects. Remembers which certificate it was shown.
private final class BrowserLikeClient: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let root: SecCertificate
    let host: String
    private let lock = NSLock()
    private var _seen: String?
    var seenFingerprint: String? { lock.lock(); defer { lock.unlock() }; return _seen }

    init(root: SecCertificate, host: String) { self.root = root; self.host = host }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else { return completionHandler(.cancelAuthenticationChallenge, nil) }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetNetworkFetchAllowed(trust, false)
        guard SecTrustEvaluateWithError(trust, nil) else { return completionHandler(.cancelAuthenticationChallenge, nil) }
        if let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
            lock.lock(); _seen = PinnedCertificateDelegate.fingerprint(of: leaf); lock.unlock()
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func get(_ url: String, token: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: url)!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        return (data, response as! HTTPURLResponse)
    }
}

private func freePort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    return UInt16(bigEndian: address.sin_port)
}

private struct NoMark: ProxyWatermarker {
    func state(for proxy: ProxyRecord, asset: Asset) -> WatermarkState { .preparing }
}

// MARK: Tests

@Suite struct ChallengeResponderTests {
    @Test func answersOnlyTheChecksAndSendsEverythingElseToHTTPS() {
        let responder = ChallengeResponder()
        responder.redirectHost = "mam.example.com"
        responder.set(token: "abc", answer: "abc.thumb")
        let check = responder.handle(HTTPRequest(method: "GET", path: "/.well-known/acme-challenge/abc"), peer: "1.1.1.1")
        guard case .data(let data) = check.body else { Issue.record("no body"); return }
        #expect(check.status == 200 && String(decoding: data, as: UTF8.self) == "abc.thumb")
        #expect(responder.handle(HTTPRequest(method: "GET", path: "/.well-known/acme-challenge/other"), peer: "1.1.1.1").status == 404)
        responder.remove(token: "abc")
        #expect(responder.handle(HTTPRequest(method: "GET", path: "/.well-known/acme-challenge/abc"), peer: "1.1.1.1").status == 404)

        // Anything else goes to the configured address, whatever Host header a stranger sends.
        let elsewhere = responder.handle(HTTPRequest(method: "GET", path: "/join", headers: ["host": "evil.example"]), peer: "1.1.1.1")
        #expect(elsewhere.status == 301 && elsewhere.header("Location") == "https://mam.example.com/join")
        #expect(responder.handle(HTTPRequest(method: "GET", path: "/v1/assets"), peer: "1.1.1.1").header("Location") == "https://mam.example.com/v1/assets")
        #expect(responder.handle(HTTPRequest(method: "POST", path: "/v1/session"), peer: "1.1.1.1").status == 405)
        responder.redirectHost = "mam.example.com:8443"
        #expect(responder.handle(HTTPRequest(method: "GET", path: "/"), peer: "1.1.1.1").header("Location") == "https://mam.example.com:8443/")
    }
}

@Suite(.serialized) struct PublicCertificateTests {
    private func checks(_ responder: ChallengeResponder) async throws -> (RemoteServer, UInt16) {
        let server = RemoteServer(handler: { responder.handle($0, peer: $1) })
        return (server, try await server.start())
    }

    @Test func getsStoresAndReusesATrustedCertificate() async throws {
        let ca = try FakeAuthority()
        let responder = ChallengeResponder()
        let (server, port) = try await checks(responder)
        defer { server.stop() }
        ca.challengePort = port
        let dir = NSTemporaryDirectory() + "pub-\(UUID().uuidString)"

        ca.rejectNextNonce()   // the authority may refuse a nonce at any time; the request is retried
        let identity = try await PublicCertificate.issue(in: dir, passphrase: "pw", host: "MAM.test", contact: "owner@example.com",
                                                         authority: ca.authority, responder: responder)
        #expect(ca.issued == 1 && identity.chain.count == 1)   // the intermediate travels with it
        let expires = try #require(identity.expires)
        #expect(abs(expires.timeIntervalSinceNow - 90 * 86_400) < 3600)
        #expect(!PublicCertificate.isDue(identity))
        #expect(PublicCertificate.isDue(identity, now: Date().addingTimeInterval(61 * 86_400)))
        #expect(!PublicCertificate.isDue(identity, now: Date().addingTimeInterval(59 * 86_400)))

        // Kept on disk for the next start, for this name only, until it runs out.
        #expect(PublicCertificate.load(in: dir, passphrase: "pw", host: "mam.test")?.fingerprint == identity.fingerprint)
        #expect(PublicCertificate.load(in: dir, passphrase: "pw", host: "other.test") == nil)
        #expect(PublicCertificate.load(in: dir, passphrase: "wrong", host: "mam.test") == nil)
        #expect(PublicCertificate.load(in: dir, passphrase: "pw", host: "mam.test", now: Date().addingTimeInterval(91 * 86_400)) == nil)

        // Nothing sensitive is left lying about, and the files are private.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
        #expect(files == ["account.key", "host", "identity.p12"])
        for file in ["account.key", "identity.p12"] {
            #expect(try FileManager.default.attributesOfItem(atPath: dir + "/" + file)[.posixPermissions] as? Int == 0o600)
        }

        // A renewal uses the same account and replaces the certificate.
        let renewed = try await PublicCertificate.issue(in: dir, passphrase: "pw", host: "mam.test", contact: nil,
                                                        authority: ca.authority, responder: responder)
        #expect(ca.issued == 2 && ca.accountCount == 1 && renewed.fingerprint != identity.fingerprint)
        #expect(PublicCertificate.load(in: dir, passphrase: "pw", host: "mam.test")?.fingerprint == renewed.fingerprint)
    }

    @Test func aMacTheAuthorityCannotReachGetsAPlainExplanationAndKeepsItsOldCertificate() async throws {
        let ca = try FakeAuthority()
        let responder = ChallengeResponder()
        let (server, port) = try await checks(responder)
        defer { server.stop() }
        ca.challengePort = port
        let dir = NSTemporaryDirectory() + "pub-\(UUID().uuidString)"
        let good = try await PublicCertificate.issue(in: dir, passphrase: "pw", host: "mam.test", contact: nil,
                                                     authority: ca.authority, responder: responder)
        #expect(PublicCertificate.retryAllowedAt(in: dir) == nil)

        ca.reachable = false
        do {
            _ = try await PublicCertificate.issue(in: dir, passphrase: "pw", host: "mam.test", contact: nil,
                                                  authority: ca.authority, responder: responder)
            Issue.record("should have failed")
        } catch let failure as ACMEClient.Failure {
            guard case .notReachable(let host, let detail) = failure else { Issue.record("wrong failure \(failure)"); return }
            #expect(host == "mam.test" && detail.contains("firewall"))
            let message = try #require(failure.errorDescription)
            #expect(message.contains("port 80") && message.contains("router"))
        }
        #expect(PublicCertificate.load(in: dir, passphrase: "pw", host: "mam.test")?.fingerprint == good.fingerprint)
        let retry = try #require(PublicCertificate.retryAllowedAt(in: dir))
        #expect(retry > Date().addingTimeInterval(600))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["account.key", "host", "identity.p12", "last-failure"])
    }
}

@Suite(.serialized) struct TrustedCertificateHubTests {
    private func makeHub(_ ca: FakeAuthority) throws -> (RemoteHub, RemoteConfig) {
        let root = NSTemporaryDirectory() + "hubpub-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/Proxies", withIntermediateDirectories: true)
        let hub = try RemoteHub(directory: root + "/hub", catalog: try Catalog.inMemory(), watermarker: NoMark())
        hub.authority = ca.authority
        ca.challengePort = freePort()
        var config = RemoteConfig(transport: .direct, publicHost: "mam.test", proxyRoots: [root + "/Proxies"],
                                  certificatePassphrase: "pw")
        config.certificate = .letsEncrypt(contact: "owner@example.com", agreedToTerms: true)
        config.challengePort = ca.challengePort
        return (hub, config)
    }

    @Test func servesBrowsersATrustedCertificateAndRenewsItWithoutStopping() async throws {
        let ca = try FakeAuthority()
        let (hub, config) = try makeHub(ca)
        let running = try await hub.start(config)
        defer { hub.stop() }
        #expect(running.publiclyTrusted && running.fingerprint == nil && running.challengePort == ca.challengePort)
        #expect(running.certificateExpires != nil && ca.issued == 1)

        // A browser that trusts only the authority's root, checking the name, gets in: the
        // intermediate certificate is sent along, which a browser will not go and fetch.
        let browser = BrowserLikeClient(root: ca.root, host: "mam.test")
        let (grant, link) = try hub.invite(name: "Maya", expiresInDays: nil, config: config)
        #expect(link.certificateFingerprint == nil && link.webURL.absoluteString.hasPrefix("https://mam.test/join#"))
        let (_, ok) = try await browser.get("https://127.0.0.1:\(running.port)/v1/info", token: link.token)
        #expect(ok.statusCode == 200)
        let first = try #require(browser.seenFingerprint)
        // The same certificate does not pass for another name.
        await #expect(throws: (any Error).self) {
            _ = try await BrowserLikeClient(root: ca.root, host: "other.test").get("https://127.0.0.1:\(running.port)/healthz")
        }

        // The plain port only redirects: no catalogue, even with a valid token.
        let (_, plain) = try await browser.get("http://127.0.0.1:\(ca.challengePort)/v1/info", token: link.token)
        #expect(plain.statusCode == 301 && plain.value(forHTTPHeaderField: "Location") == "https://mam.test/v1/info")

        // Not due yet: nothing is asked of the authority.
        #expect(try await hub.renewCertificateIfDue() == false && ca.issued == 1)
        // Two thirds through its life it is renewed, and new connections see the new one.
        #expect(try await hub.renewCertificateIfDue(now: Date().addingTimeInterval(61 * 86_400)))
        #expect(ca.issued == 2)
        let (_, after) = try await browser.get("https://127.0.0.1:\(running.port)/v1/info", token: link.token)
        #expect(after.statusCode == 200 && browser.seenFingerprint != first)
        #expect(hub.running?.port == running.port)

        // A restart reuses the certificate on disk instead of asking for another.
        hub.stop()
        let again = try await hub.start(config)
        #expect(ca.issued == 2 && again.publiclyTrusted)
        let (_, restarted) = try await browser.get("https://127.0.0.1:\(again.port)/healthz")
        #expect(restarted.statusCode == 200)

        let trail = try hub.audit.entries(limit: 20).filter { $0.path == "certificate" }
        #expect(trail.count == 2 && trail.allSatisfy { $0.detail?.contains("issued for mam.test") == true })
        _ = grant
    }

    @Test func aFailedRenewalKeepsServingAndWaitsBeforeTryingAgain() async throws {
        let ca = try FakeAuthority()
        let (hub, config) = try makeHub(ca)
        let running = try await hub.start(config)
        defer { hub.stop() }
        let browser = BrowserLikeClient(root: ca.root, host: "mam.test")
        _ = try await browser.get("https://127.0.0.1:\(running.port)/healthz")
        let first = browser.seenFingerprint

        ca.reachable = false
        let later = Date().addingTimeInterval(61 * 86_400)
        await #expect(throws: ACMEClient.Failure.self) { _ = try await hub.renewCertificateIfDue(now: later) }
        #expect(hub.renewalProblem?.contains("port 80") == true)
        let (_, still) = try await browser.get("https://127.0.0.1:\(running.port)/healthz")
        #expect(still.statusCode == 200 && browser.seenFingerprint == first)

        // Straight away again: refused here, without spending one of the authority's few tries.
        ca.reachable = true
        let asked = ca.signedRequests
        do {
            _ = try await hub.renewCertificateIfDue(now: later.addingTimeInterval(60))
            Issue.record("should have waited")
        } catch let error as RemoteHub.HubError {
            guard case .triedRecently = error else { Issue.record("wrong error"); return }
        }
        #expect(ca.signedRequests == asked)
        // After the pause it goes through.
        #expect(try await hub.renewCertificateIfDue(now: later.addingTimeInterval(13 * 60)))
        #expect(hub.renewalProblem == nil && ca.issued == 2)
    }

    @Test func nothingIsRequestedWithoutTheOwnersAgreementOrARealName() async throws {
        let ca = try FakeAuthority()
        let (hub, config) = try makeHub(ca)
        var unagreed = config
        unagreed.certificate = .letsEncrypt(contact: nil, agreedToTerms: false)
        do { _ = try await hub.start(unagreed); Issue.record("started") } catch let error as RemoteHub.HubError {
            guard case .termsNotAgreed = error else { Issue.record("wrong error"); return }
        }
        var numeric = config
        numeric.publicHost = "203.0.113.7"
        do { _ = try await hub.start(numeric); Issue.record("started") } catch let error as RemoteHub.HubError {
            guard case .needsDomainName = error else { Issue.record("wrong error"); return }
        }
        #expect(ca.signedRequests == 0 && hub.running == nil)

        // A start that fails at the authority leaves nothing listening.
        ca.reachable = false
        await #expect(throws: ACMEClient.Failure.self) { _ = try await hub.start(config) }
        #expect(hub.running == nil)
        await #expect(throws: (any Error).self) {
            _ = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(ca.challengePort)/")!)
        }
    }
}
