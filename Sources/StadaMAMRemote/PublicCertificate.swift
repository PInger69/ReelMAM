import CryptoKit
import Foundation
import Security

// A certificate browsers trust, got from Let's Encrypt (or any authority speaking the same
// ACME protocol, RFC 8555) and renewed without anyone doing anything.
//
// The authority checks that this Mac really answers for the name: it gives us a token, then
// fetches http://<name>/.well-known/acme-challenge/<token> from the internet and expects a
// reply only the holder of our account key could give. So port 80 of the public address has
// to reach this Mac while a certificate is being issued or renewed.

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// What the plain-HTTP port answers: the authority's checks, and for everything else a
/// redirect to the HTTPS address. It never serves the catalogue or a proxy.
public final class ChallengeResponder: @unchecked Sendable {
    public static let prefix = "/.well-known/acme-challenge/"
    private let lock = NSLock()
    private var answers: [String: String] = [:]
    private var host: String?

    public init() {}

    /// Where everything that is not a check is sent, as editors type it (may include a port).
    public var redirectHost: String? {
        get { lock.lock(); defer { lock.unlock() }; return host }
        set { lock.lock(); host = newValue; lock.unlock() }
    }

    func set(token: String, answer: String) { lock.lock(); answers[token] = answer; lock.unlock() }
    func remove(token: String) { lock.lock(); answers[token] = nil; lock.unlock() }
    private func answer(for token: String) -> String? { lock.lock(); defer { lock.unlock() }; return answers[token] }

    public func handle(_ request: HTTPRequest, peer: String) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else { return .error(405, "not allowed") }
        if request.path.hasPrefix(Self.prefix) {
            guard let answer = answer(for: String(request.path.dropFirst(Self.prefix.count))) else {
                return .error(404, "not found")
            }
            let data = Data(answer.utf8)
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/plain")],
                                body: request.method == "HEAD" ? .headOnly(length: UInt64(data.count)) : .data(data))
        }
        // The destination is the configured address, never the Host header a stranger sent.
        guard let host = redirectHost, !host.isEmpty else { return .error(404, "not found") }
        var components = URLComponents()
        components.scheme = "https"
        let parts = host.split(separator: ":", maxSplits: 1).map(String.init)
        components.host = parts.first
        if parts.count > 1 { components.port = Int(parts[1]) }
        components.path = request.path
        guard let url = components.url else { return .error(404, "not found") }
        return HTTPResponse(status: 301, headers: [("Location", url.absoluteString)])
    }
}

/// Talks to the certificate authority.
public final class ACMEClient: @unchecked Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let letsEncrypt = URL(string: "https://acme-v02.api.letsencrypt.org/directory")!
    /// Issues certificates browsers do not trust, with generous limits: for trying the setup.
    public static let letsEncryptStaging = URL(string: "https://acme-staging-v02.api.letsencrypt.org/directory")!

    public enum Failure: Error, LocalizedError, Equatable {
        case authority(String)
        case notReachable(host: String, detail: String)
        case noHTTPCheckOffered
        case tookTooLong(String)
        case unexpectedAnswer(String)

        public var errorDescription: String? {
            switch self {
            case .authority(let detail): return "The certificate authority refused: \(detail)"
            case .notReachable(let host, let detail):
                return "The certificate authority could not reach this Mac at http://\(host) on port 80, so it would not issue a certificate. Check that \(host) points at your public address and that your router sends port 80 to this Mac. It said: \(detail)"
            case .noHTTPCheckOffered: return "The certificate authority did not offer a check this Mac can answer."
            case .tookTooLong(let what): return "The certificate authority took too long \(what)."
            case .unexpectedAnswer(let what): return "The certificate authority gave an answer that could not be understood (\(what))."
            }
        }
    }

    private let directoryURL: URL
    private let key: P256.Signing.PrivateKey
    private let transport: Transport
    private let pollInterval: TimeInterval
    private var nonce: String?
    private var accountURL: String?

    public init(directory: URL, accountKey: P256.Signing.PrivateKey, pollInterval: TimeInterval = 2,
                transport: Transport? = nil) {
        directoryURL = directory
        key = accountKey
        self.pollInterval = pollInterval
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.unexpectedAnswer("not HTTP") }
            return (data, http)
        }
    }

    /// The account key as the authority identifies it.
    private var jwk: [String: String] {
        let raw = key.publicKey.rawRepresentation
        return ["crv": "P-256", "kty": "EC", "x": raw.prefix(32).base64URL, "y": raw.suffix(32).base64URL]
    }

    /// RFC 7638: the hash of the key's canonical form, which is what a check's answer is built from.
    var thumbprint: String {
        let j = jwk
        let canonical = "{\"crv\":\"\(j["crv"]!)\",\"kty\":\"\(j["kty"]!)\",\"x\":\"\(j["x"]!)\",\"y\":\"\(j["y"]!)\"}"
        return Data(SHA256.hash(data: Data(canonical.utf8))).base64URL
    }

    /// Gets a certificate for `host`. `csr` is the request in DER form; the result is the
    /// certificate followed by the authority's intermediates, as PEM.
    public func certificate(for host: String, contact: String?, csr: Data, responder: ChallengeResponder) async throws -> String {
        let (listing, _) = try await transport(URLRequest(url: directoryURL))
        guard let directory = try? JSONSerialization.jsonObject(with: listing) as? [String: Any],
              let newNonce = (directory["newNonce"] as? String).flatMap(URL.init(string:)),
              let newAccount = (directory["newAccount"] as? String).flatMap(URL.init(string:)),
              let newOrder = (directory["newOrder"] as? String).flatMap(URL.init(string:)) else {
            throw Failure.unexpectedAnswer("directory")
        }
        var nonceRequest = URLRequest(url: newNonce)
        nonceRequest.httpMethod = "HEAD"
        nonce = try await transport(nonceRequest).1.value(forHTTPHeaderField: "Replay-Nonce")

        var registration: [String: Any] = ["termsOfServiceAgreed": true]
        if let contact = contact?.trimmingCharacters(in: .whitespaces), !contact.isEmpty {
            registration["contact"] = ["mailto:\(contact)"]
        }
        let account = try await post(newAccount, registration)
        guard let location = account.1.value(forHTTPHeaderField: "Location") else { throw Failure.unexpectedAnswer("account") }
        accountURL = location

        let placed = try await post(newOrder, ["identifiers": [["type": "dns", "value": host]]])
        guard let orderURL = placed.1.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)),
              let order = try? JSONSerialization.jsonObject(with: placed.0) as? [String: Any],
              let authorizations = order["authorizations"] as? [String],
              let finalize = (order["finalize"] as? String).flatMap(URL.init(string:)) else {
            throw Failure.unexpectedAnswer("order")
        }

        for address in authorizations {
            guard let url = URL(string: address) else { throw Failure.unexpectedAnswer("authorization") }
            try await prove(host: host, authorization: url, responder: responder)
        }

        _ = try await post(finalize, ["csr": csr.base64URL])
        let finished = try await poll(orderURL, until: "the certificate was ready") { object in
            switch object["status"] as? String {
            case "valid": return true
            case "invalid": throw Failure.authority(Self.detail(in: object) ?? "the order was rejected")
            default: return false
            }
        }
        guard let download = (finished["certificate"] as? String).flatMap(URL.init(string:)) else {
            throw Failure.unexpectedAnswer("certificate address")
        }
        let pem = String(decoding: try await post(download, nil).0, as: UTF8.self)
        guard pem.contains("BEGIN CERTIFICATE") else { throw Failure.unexpectedAnswer("certificate") }
        return pem
    }

    private func prove(host: String, authorization: URL, responder: ChallengeResponder) async throws {
        let data = try await post(authorization, nil).0
        guard let authz = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unexpectedAnswer("authorization")
        }
        if authz["status"] as? String == "valid" { return }
        guard let challenges = authz["challenges"] as? [[String: Any]],
              let challenge = challenges.first(where: { $0["type"] as? String == "http-01" }),
              let token = challenge["token"] as? String,
              let url = (challenge["url"] as? String).flatMap(URL.init(string:)) else {
            throw Failure.noHTTPCheckOffered
        }
        responder.set(token: token, answer: token + "." + thumbprint)
        defer { responder.remove(token: token) }
        _ = try await post(url, [:])
        _ = try await poll(authorization, until: "checking that this Mac answers for \(host)") { object in
            switch object["status"] as? String {
            case "valid": return true
            case "invalid", "revoked", "deactivated", "expired":
                let failed = (object["challenges"] as? [[String: Any]])?.compactMap { Self.detail(in: $0) }.first
                throw Failure.notReachable(host: host, detail: failed ?? "no reason given")
            default: return false
            }
        }
    }

    private static func detail(in object: [String: Any]) -> String? {
        (object["error"] as? [String: Any])?["detail"] as? String
    }

    private func poll(_ url: URL, until what: String,
                      done: ([String: Any]) throws -> Bool) async throws -> [String: Any] {
        for attempt in 0..<60 {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000)) }
            let data = try await post(url, nil).0
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.unexpectedAnswer("status")
            }
            if try done(object) { return object }
        }
        throw Failure.tookTooLong(what)
    }

    /// A signed request. `payload` nil reads the address (the protocol has no plain GET for these).
    private func post(_ url: URL, _ payload: [String: Any]?, retrying: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard let nonce else { throw Failure.unexpectedAnswer("no nonce") }
        var header: [String: Any] = ["alg": "ES256", "nonce": nonce, "url": url.absoluteString]
        if let accountURL { header["kid"] = accountURL } else { header["jwk"] = jwk }
        let protected = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]).base64URL
        let body = try payload.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]).base64URL } ?? ""
        let signature = try key.signature(for: Data("\(protected).\(body)".utf8)).rawRepresentation.base64URL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/jose+json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["protected": protected, "payload": body, "signature": signature])
        let (data, response) = try await transport(request)
        self.nonce = response.value(forHTTPHeaderField: "Replay-Nonce")
        guard response.statusCode < 400 else {
            let problem = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            // The authority may throw away a nonce at any time; it sends a fresh one to try again with.
            if !retrying, self.nonce != nil, (problem?["type"] as? String)?.hasSuffix(":badNonce") == true {
                return try await post(url, payload, retrying: true)
            }
            throw Failure.authority(problem?["detail"] as? String ?? "error \(response.statusCode)")
        }
        return (data, response)
    }
}

/// The publicly trusted certificate on disk: reading it, deciding when it is due, getting a new one.
public enum PublicCertificate {
    /// How to reach the authority. Tests point this at a stand-in.
    public struct Authority: Sendable {
        public var directory: URL
        public var pollInterval: TimeInterval
        public var transport: ACMEClient.Transport?

        public init(directory: URL = ACMEClient.letsEncrypt, pollInterval: TimeInterval = 2,
                    transport: ACMEClient.Transport? = nil) {
            self.directory = directory
            self.pollInterval = pollInterval
            self.transport = transport
        }
    }

    /// The certificate kept in `directory`, if it is for `host` and has not run out.
    public static func load(in directory: String, passphrase: String, host: String, now: Date = Date()) -> ServerIdentity? {
        guard (try? String(contentsOfFile: directory + "/host", encoding: .utf8)) == host.lowercased(),
              let identity = try? ServerIdentity.load(directory + "/identity.p12", passphrase: passphrase),
              let expires = identity.expires, expires > now else { return nil }
        return identity
    }

    /// Due once two thirds of its life has gone, which leaves weeks to notice a renewal that keeps failing.
    public static func isDue(_ identity: ServerIdentity, now: Date = Date()) -> Bool {
        guard let expires = identity.expires else { return true }
        let issued = ServerIdentity.validFrom(identity.certificate) ?? expires.addingTimeInterval(-90 * 86_400)
        return expires.timeIntervalSince(now) < expires.timeIntervalSince(issued) / 3
    }

    /// The authority allows only a handful of failed checks an hour for one name, so after a
    /// failure the next try waits.
    public static let pauseAfterFailure: TimeInterval = 12 * 60

    public static func retryAllowedAt(in directory: String) -> Date? {
        guard let text = try? String(contentsOfFile: directory + "/last-failure", encoding: .utf8),
              let seconds = Double(text) else { return nil }
        return Date(timeIntervalSince1970: seconds).addingTimeInterval(pauseAfterFailure)
    }

    /// Gets a new certificate for `host` and stores it, replacing the old one only once the new
    /// one is known to be good.
    public static func issue(in directory: String, passphrase: String, host: String, contact: String?,
                             authority: Authority, responder: ChallengeResponder, now: Date = Date()) async throws -> ServerIdentity {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let openssl = "/usr/bin/openssl"
        guard fm.isExecutableFile(atPath: openssl) else { throw ServerIdentity.Failure.openSSLMissing }
        let host = host.lowercased()
        let key = directory + "/new-key.pem", request = directory + "/new-request.der"
        let chain = directory + "/new-chain.pem", fresh = directory + "/new-identity.p12"
        defer { for path in [key, request, chain, fresh] { try? fm.removeItem(atPath: path) } }

        do {
            try ServerIdentity.run(openssl, ["genrsa", "-out", key, "2048"])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key)
            try ServerIdentity.run(openssl, ["req", "-new", "-key", key, "-subj", "/CN=\(host)",
                                             "-addext", "subjectAltName=DNS:\(host)", "-outform", "DER", "-out", request])
            let client = ACMEClient(directory: authority.directory, accountKey: try accountKey(in: directory),
                                    pollInterval: authority.pollInterval, transport: authority.transport)
            let pem = try await client.certificate(for: host, contact: contact,
                                                   csr: try Data(contentsOf: URL(fileURLWithPath: request)), responder: responder)
            try pem.write(toFile: chain, atomically: true, encoding: .utf8)
            try ServerIdentity.run(openssl, ["pkcs12", "-export", "-inkey", key, "-in", chain, "-out", fresh,
                                             "-passout", "pass:\(passphrase)"])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fresh)
            let identity = try ServerIdentity.load(fresh, passphrase: passphrase)
            guard let expires = identity.expires, expires > now else {
                throw ACMEClient.Failure.unexpectedAnswer("a certificate that has already run out")
            }
            _ = try fm.replaceItemAt(URL(fileURLWithPath: directory + "/identity.p12"), withItemAt: URL(fileURLWithPath: fresh))
            try host.write(toFile: directory + "/host", atomically: true, encoding: .utf8)
            try? fm.removeItem(atPath: directory + "/last-failure")
            return identity
        } catch {
            try? String(now.timeIntervalSince1970).write(toFile: directory + "/last-failure", atomically: true, encoding: .utf8)
            throw error
        }
    }

    /// The key that identifies this Mac to the authority. Made once and kept.
    static func accountKey(in directory: String) throws -> P256.Signing.PrivateKey {
        let path = directory + "/account.key"
        if let data = FileManager.default.contents(atPath: path), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        try key.rawRepresentation.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return key
    }
}
