import Foundation
import StadaMAMCore

/// How editors reach this Mac.
public enum RemoteTransport: String, Codable, CaseIterable, Sendable {
    /// A tunnel agent on this Mac (Cloudflare Tunnel style) forwards to a plain local port and
    /// adds the public certificate itself.
    case tunnel
    /// A relay passes editors' encrypted connections straight through to this Mac, which
    /// answers with its own certificate (pinned by the invite). The relay cannot read anything.
    case relayPassthrough
    /// Editors connect to this Mac directly, with its own certificate.
    case direct

    public var usesTLS: Bool { self != .tunnel }
    public var loopbackOnly: Bool { self != .direct }
}

/// Where this Mac's certificate comes from, when it (not a tunnel) is what editors see.
public enum CertificateSource: Equatable, Sendable {
    /// Made on this Mac. Editors' browsers warn about it; a native app pins it from the invite.
    case selfSigned
    /// Issued by Let's Encrypt and renewed automatically, so browsers open the address without
    /// a warning. Needs a domain name pointed at this Mac and port 80 reaching it. The owner
    /// has to agree to Let's Encrypt's terms themself; nothing is requested until they have.
    case letsEncrypt(contact: String?, agreedToTerms: Bool)
}

public struct RemoteConfig: Equatable, Sendable {
    public var transport: RemoteTransport
    public var certificate: CertificateSource = .selfSigned
    /// The plain-HTTP port on this Mac that answers Let's Encrypt's checks. The public port 80
    /// has to arrive here.
    public var challengePort: UInt16 = 80
    /// The address editors use, as typed in the invite (may include a port).
    public var publicHost: String
    public var port: UInt16
    /// Folders proxies may be served from.
    public var proxyRoots: [String]
    /// Protects the certificate file; kept in the keychain by the app.
    public var certificatePassphrase: String

    public init(transport: RemoteTransport, publicHost: String, port: UInt16 = 0, proxyRoots: [String],
                certificatePassphrase: String) {
        self.transport = transport
        self.publicHost = publicHost
        self.port = port
        self.proxyRoots = proxyRoots
        self.certificatePassphrase = certificatePassphrase
    }

    /// The host name without a port, for the certificate.
    var hostName: String {
        publicHost.split(separator: ":").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

public struct EditorSummary: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case active, revoked, expired, waitingForInitials }
    public var id: String
    public var name: String
    public var initials: String?
    public var status: Status
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var bytesPulled: Int64
}

public struct RemoteRunning: Equatable, Sendable {
    public var port: UInt16
    public var transport: RemoteTransport
    public var fingerprint: String?
    /// True when the certificate is one browsers trust.
    public var publiclyTrusted = false
    public var certificateExpires: Date?
    /// The plain-HTTP port answering certificate checks, when there is one.
    public var challengePort: UInt16?
}

/// Everything the owner's screen drives: the editors, the audit trail, and the server.
/// The app's settings tab is a thin layer over this, so it is tested without a window.
public final class RemoteHub: @unchecked Sendable {
    public let grants: GrantStore
    public let audit: AuditLog
    private let catalog: Catalog
    private let directory: String
    private let watermarker: ProxyWatermarker
    private var server: RemoteServer?
    private var challengeServer: RemoteServer?
    private let responder = ChallengeResponder()
    private var renewal: Task<Void, Never>?
    private var config: RemoteConfig?
    private var publicIdentity: ServerIdentity?
    private let lock = NSLock()
    public private(set) var running: RemoteRunning?
    /// Why the last automatic renewal failed, if it did. The old certificate stays in use.
    public private(set) var renewalProblem: String?
    /// How to reach the certificate authority; tests point it at a stand-in.
    public var authority = PublicCertificate.Authority()
    /// How often a running hub looks at whether its certificate is due.
    public var renewalCheckInterval: TimeInterval = 6 * 3600

    /// `directory` keeps the editors, the audit log, its key and the certificate. The audit log
    /// and its key are separate files on purpose: the key is what makes the log tamper-evident.
    public init(directory: String, catalog: Catalog, watermarker: ProxyWatermarker) throws {
        self.directory = directory
        self.catalog = catalog
        self.watermarker = watermarker
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = try AuditLog.loadOrCreateKey(at: directory + "/audit.key")
        audit = try AuditLog(path: directory + "/audit.sqlite", key: key)
        grants = try GrantStore(path: directory + "/editors.sqlite", audit: audit)
    }

    // MARK: Server

    @discardableResult
    public func start(_ config: RemoteConfig) async throws -> RemoteRunning {
        stop()
        do { return try await begin(config) } catch { stop(); throw error }
    }

    private func begin(_ config: RemoteConfig) async throws -> RemoteRunning {
        guard !config.proxyRoots.isEmpty else { throw HubError.noProxyFolder }
        var identity: ServerIdentity?
        var challengePort: UInt16?
        var trusted = false
        if config.transport.usesTLS {
            guard !config.hostName.isEmpty else { throw HubError.noPublicAddress }
            if case .letsEncrypt(let contact, let agreed) = config.certificate {
                guard agreed else { throw HubError.termsNotAgreed }
                guard Self.isDomainName(config.hostName) else { throw HubError.needsDomainName }
                responder.redirectHost = config.publicHost.trimmingCharacters(in: .whitespaces)
                let checks = RemoteServer(handler: { [responder] in responder.handle($0, peer: $1) },
                                          port: config.challengePort, loopbackOnly: config.transport.loopbackOnly)
                do { challengePort = try await checks.start() } catch {
                    throw HubError.challengePortUnavailable(config.challengePort, error.localizedDescription)
                }
                locked { challengeServer = checks }
                identity = try await currentOrNewPublicIdentity(config, contact: contact)
                trusted = true
            } else {
                identity = try loadIdentity(config)
            }
        }
        let api = RemoteAPI(catalog: catalog, grants: grants, proxyRoots: config.proxyRoots,
                            watermark: .required(watermarker), audit: audit)
        // Every mode is reached over HTTPS by editors, so the browser's cookie is HTTPS-only.
        api.cookieSecure = true
        let server = RemoteServer(api: api, port: config.port, loopbackOnly: config.transport.loopbackOnly,
                                  identity: identity?.identity, certificateChain: identity?.chain ?? [],
                                  forwardedForHeader: config.transport == .tunnel ? "cf-connecting-ip" : nil)
        let port = try await server.start()
        let info = RemoteRunning(port: port, transport: config.transport,
                                 fingerprint: trusted ? nil : identity?.fingerprint,
                                 publiclyTrusted: trusted, certificateExpires: trusted ? identity?.expires : nil,
                                 challengePort: challengePort)
        remember(server, info, config, trusted ? identity : nil)
        if trusted { watchRenewal() }
        return info
    }

    private func remember(_ server: RemoteServer, _ info: RemoteRunning, _ config: RemoteConfig, _ identity: ServerIdentity?) {
        lock.lock(); self.server = server; running = info; self.config = config; publicIdentity = identity; lock.unlock()
    }

    public func stop() {
        lock.lock()
        let old = server, checks = challengeServer, task = renewal
        server = nil; challengeServer = nil; renewal = nil; running = nil; config = nil; publicIdentity = nil
        lock.unlock()
        task?.cancel()
        old?.stop()
        checks?.stop()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: Certificate

    private var publicDirectory: String { directory + "/public-certificate" }

    static func isDomainName(_ host: String) -> Bool {
        host.contains(".") && !host.allSatisfy { $0.isNumber || $0 == "." } && !host.contains(":")
            && host.lowercased() != "localhost"
    }

    private func currentOrNewPublicIdentity(_ config: RemoteConfig, contact: String?) async throws -> ServerIdentity {
        if let existing = PublicCertificate.load(in: publicDirectory, passphrase: config.certificatePassphrase, host: config.hostName) {
            return existing
        }
        return try await issue(config, contact: contact)
    }

    private func issue(_ config: RemoteConfig, contact: String?, now: Date = Date()) async throws -> ServerIdentity {
        if let wait = PublicCertificate.retryAllowedAt(in: publicDirectory), wait > now {
            throw HubError.triedRecently(wait)
        }
        do {
            let identity = try await PublicCertificate.issue(in: publicDirectory, passphrase: config.certificatePassphrase,
                                                             host: config.hostName, contact: contact, authority: authority,
                                                             responder: responder, now: now)
            _ = try? audit.append(AuditEvent(kind: .admin, method: "ADMIN", path: "certificate",
                                             detail: "issued for \(config.hostName)" + (identity.expires.map { ", runs out \($0)" } ?? "")))
            return identity
        } catch {
            _ = try? audit.append(AuditEvent(kind: .admin, method: "ADMIN", path: "certificate",
                                             detail: "failed for \(config.hostName): \(error.localizedDescription)"))
            throw error
        }
    }

    /// Gets and switches to a new certificate if the one in use is due. Returns whether it did.
    /// Connections already open are not cut off. A failure leaves the old certificate serving.
    @discardableResult
    public func renewCertificateIfDue(now: Date = Date()) async throws -> Bool {
        let (config, identity, server) = locked { (self.config, publicIdentity, self.server) }
        guard let config, let identity, let server,
              case .letsEncrypt(let contact, true) = config.certificate,
              PublicCertificate.isDue(identity, now: now) else { return false }
        do {
            let fresh = try await issue(config, contact: contact, now: now)
            try await server.reload(identity: fresh.identity, certificateChain: fresh.chain)
            locked {
                if self.server === server {
                    publicIdentity = fresh
                    running?.certificateExpires = fresh.expires
                }
                renewalProblem = nil
            }
            return true
        } catch {
            locked { renewalProblem = error.localizedDescription }
            throw error
        }
    }

    private func watchRenewal() {
        let interval = renewalCheckInterval
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                _ = try? await self.renewCertificateIfDue()
            }
        }
        lock.lock(); renewal = task; lock.unlock()
    }

    public enum HubError: Error, LocalizedError {
        case noProxyFolder, noPublicAddress, termsNotAgreed, needsDomainName
        case challengePortUnavailable(UInt16, String)
        case triedRecently(Date)
        public var errorDescription: String? {
            switch self {
            case .termsNotAgreed: return "Agree to the Let's Encrypt terms before a certificate can be requested."
            case .needsDomainName: return "A trusted certificate needs a domain name, such as mam.example.com, not a number address."
            case .challengePortUnavailable(let port, let why):
                return "Port \(port) on this Mac, which answers the certificate checks, could not be opened: \(why)"
            case .triedRecently(let until):
                return "The last certificate request failed. Certificate authorities allow only a few failed tries an hour, so the next one waits until \(until.formatted(date: .omitted, time: .shortened)). Fix the address or router in the meantime."
            case .noProxyFolder: return "There is no proxy folder to share."
            case .noPublicAddress: return "Enter the address editors will use before sharing with this setting."
            }
        }
    }

    private func loadIdentity(_ config: RemoteConfig) throws -> ServerIdentity {
        try ServerIdentity.loadOrCreate(in: directory + "/certificate", passphrase: config.certificatePassphrase,
                                        hostnames: [config.hostName])
    }

    // MARK: Editors

    /// Invites an editor and returns the link to send them, which is the only time their token is shown.
    public func invite(name: String, expiresInDays: Int?, config: RemoteConfig) throws -> (EditorGrant, InviteLink) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CocoaError(.userCancelled) }
        guard !config.hostName.isEmpty else { throw HubError.noPublicAddress }
        // A pin only makes sense for the certificate made here; a trusted one changes at every renewal.
        let fingerprint = config.transport.usesTLS && config.certificate == .selfSigned ? try loadIdentity(config).fingerprint : nil
        let expires = expiresInDays.map { Date().addingTimeInterval(Double($0) * 86_400) }
        let (grant, token) = try grants.invite(name: trimmed, expiresAt: expires)
        return (grant, InviteLink(host: config.publicHost.trimmingCharacters(in: .whitespaces), token: token,
                                  certificateFingerprint: fingerprint))
    }

    public func editors(now: Date = Date()) throws -> [EditorSummary] {
        let pulled = try audit.bytesSentByEditor()
        return try grants.all().map { grant in
            let status: EditorSummary.Status = grant.revokedAt != nil ? .revoked
                : (grant.expiresAt.map { $0 <= now } ?? false) ? .expired
                : grant.initials == nil ? .waitingForInitials : .active
            return EditorSummary(id: grant.id, name: grant.name, initials: grant.initials, status: status,
                                 createdAt: grant.createdAt, lastSeenAt: grant.lastSeenAt,
                                 bytesPulled: pulled[grant.id] ?? 0)
        }
    }

    // MARK: Audit trail

    public struct AuditReport: Equatable, Sendable {
        public var entries: Int
        public var ok: Bool
        public var message: String
        /// What to note somewhere safe, to catch a log that is later cut short.
        public var anchor: AuditAnchor?

        public init(entries: Int, ok: Bool, message: String, anchor: AuditAnchor?) {
            self.entries = entries; self.ok = ok; self.message = message; self.anchor = anchor
        }
    }

    /// Checks the whole chain, against the anchor the owner noted earlier if there is one.
    public func verifyAudit(against noted: AuditAnchor?) throws -> AuditReport {
        let result = try audit.verify(against: noted)
        let anchor = try audit.anchor()
        if result.ok {
            return AuditReport(entries: result.entries, ok: true,
                               message: noted == nil
                               ? "The log is intact (\(result.entries) entries). Note the anchor below somewhere safe so a log cut short can be caught."
                               : "The log is intact (\(result.entries) entries) and nothing before your noted anchor is missing.",
                               anchor: anchor)
        }
        return AuditReport(entries: result.entries, ok: false,
                           message: "The log has been tampered with or damaged: \(result.problem ?? "unknown problem"). Keep this Mac's files as they are and do not rely on entries from \(result.firstBadSeq.map { "number \($0)" } ?? "that point") onward.",
                           anchor: anchor)
    }

    public func exportAudit(to url: URL) throws {
        try audit.exportJSONLines().write(to: url, options: .atomic)
    }
}
