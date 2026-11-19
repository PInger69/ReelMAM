import CryptoKit
import Foundation
import Network
import Security

/// Serves `RemoteAPI` over HTTP/1.1 with Network.framework.
///
/// Two ways to run it:
/// - behind a tunnel: bound to loopback only, plain HTTP; the tunnel agent on the same Mac
///   adds the public TLS certificate, and nothing else on the network can reach the port;
/// - direct: with a TLS identity (self-signed is fine, the invite carries its fingerprint).
public final class RemoteServer: @unchecked Sendable {
    /// Answers one request; the second argument says who is asking (their address).
    public typealias Handler = @Sendable (HTTPRequest, String) -> HTTPResponse

    private let handler: Handler
    private let requestedPort: UInt16
    private let loopbackOnly: Bool
    private var identity: SecIdentity?
    /// Certificates sent after the server's own, up to (not including) the authority's root.
    private var chain: [SecCertificate]
    private var boundPort: UInt16 = 0
    /// Read the caller's address from this header (a tunnel puts it there) instead of the
    /// socket. Only safe when the server is loopback-only behind that tunnel.
    private let forwardedForHeader: String?
    private let queue = DispatchQueue(label: "remote.server")
    private var listener: NWListener?
    private var live: [ObjectIdentifier: Session] = [:]
    public var maxConnections = 128

    public convenience init(api: RemoteAPI, port: UInt16 = 0, loopbackOnly: Bool = true, identity: SecIdentity? = nil,
                            certificateChain: [SecCertificate] = [], forwardedForHeader: String? = nil) {
        self.init(handler: { api.handle($0, peer: $1) }, port: port, loopbackOnly: loopbackOnly, identity: identity,
                  certificateChain: certificateChain, forwardedForHeader: forwardedForHeader)
    }

    public init(handler: @escaping Handler, port: UInt16 = 0, loopbackOnly: Bool = true, identity: SecIdentity? = nil,
                certificateChain: [SecCertificate] = [], forwardedForHeader: String? = nil) {
        self.handler = handler
        self.requestedPort = port
        self.loopbackOnly = loopbackOnly
        self.identity = identity
        self.chain = certificateChain
        self.forwardedForHeader = forwardedForHeader?.lowercased()
    }

    /// Starts listening and returns the port in use.
    public func start() async throws -> UInt16 {
        let port = try await listenWhenFree(on: requestedPort)
        boundPort = port
        return port
    }

    /// A port just let go of (sharing switched off and on, a certificate swapped) takes a
    /// moment to become free, so "in use" is retried briefly before it is believed.
    private func listenWhenFree(on port: UInt16) async throws -> UInt16 {
        var lastError: Error?
        for attempt in 0..<(port == 0 ? 1 : 20) {
            if attempt > 0 { try await Task.sleep(nanoseconds: 100_000_000) }
            do { return try await listen(on: port) } catch {
                lastError = error
                guard case NWError.posix(.EADDRINUSE) = error else { throw error }
            }
        }
        throw lastError ?? CocoaError(.featureUnsupported)
    }

    /// Switches to a new certificate (after a renewal) without cutting off anyone mid-download:
    /// connections already open keep the certificate they started with, new ones get this one.
    public func reload(identity: SecIdentity, certificateChain: [SecCertificate]) async throws {
        self.identity = identity
        self.chain = certificateChain
        let old = listener
        listener = nil
        old?.newConnectionHandler = nil
        old?.cancel()
        _ = try await listenWhenFree(on: boundPort)
    }

    private func listen(on port: UInt16) async throws -> UInt16 {
        let parameters: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            let local = chain.isEmpty ? sec_identity_create(identity)
                : sec_identity_create_with_certificates(identity, chain as CFArray)
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local!)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = NWParameters.tcp
        }
        parameters.allowLocalEndpointReuse = true
        if loopbackOnly { parameters.requiredInterfaceType = .loopback }
        let listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    listener.cancel()
                    if once.fire() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        return bound
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.sync {
            for session in live.values { session.close() }
            live.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        queue.async { [self] in
            guard self.live.count < self.maxConnections else { connection.cancel(); return }
            let session = Session(connection: connection, handler: self.handler, forwardedFor: self.forwardedForHeader)
            let key = ObjectIdentifier(session)
            self.live[key] = session
            session.onClose = { [weak self] in self?.queue.async { self?.live[key] = nil } }
            session.start()
        }
    }

    fileprivate final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    // MARK: One connection

    private final class Session: @unchecked Sendable {
        let connection: NWConnection
        let handler: Handler
        let forwardedFor: String?
        let queue = DispatchQueue(label: "remote.session")
        var onClose: (() -> Void)?
        private var buffer = Data()
        private var closed = false
        private var idle: DispatchWorkItem?
        static let chunk = 512 * 1024
        static let idleSeconds = 60.0

        init(connection: NWConnection, handler: @escaping Handler, forwardedFor: String?) {
            self.connection = connection
            self.handler = handler
            self.forwardedFor = forwardedFor
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
            connection.start(queue: queue)
            receive()
        }

        func close() {
            queue.async {
                guard !self.closed else { return }
                self.closed = true
                self.idle?.cancel()
                self.connection.cancel()
                self.onClose?()
            }
        }

        private func armIdle() {
            idle?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.close() }
            idle = item
            queue.asyncAfter(deadline: .now() + Self.idleSeconds, execute: item)
        }

        private func receive() {
            armIdle()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { return }
                if let data { self.buffer.append(data) }
                if error != nil { return self.close() }
                switch HTTPRequestParser.parse(self.buffer) {
                case .incomplete:
                    isComplete ? self.close() : self.receive()
                case .invalid(let status):
                    self.respond(.error(status, "bad request"), keepAlive: false)
                case .request(let request, let consumed):
                    self.buffer.removeFirst(consumed)
                    self.idle?.cancel()
                    let peer = self.peerKey(for: request)
                    DispatchQueue.global(qos: .userInitiated).async {
                        let response = self.handler(request, peer)
                        self.queue.async { self.respond(response, keepAlive: request.keepAlive) }
                    }
                }
            }
        }

        private func peerKey(for request: HTTPRequest) -> String {
            if let header = forwardedFor, let value = request.headers[header] {
                return String(value.split(separator: ",").first ?? "").trimmingCharacters(in: .whitespaces)
            }
            if case let .hostPort(host, _) = connection.endpoint { return "\(host)" }
            return "unknown"
        }

        private func respond(_ response: HTTPResponse, keepAlive: Bool) {
            guard !closed else { response.onFinish?(0, false); return }
            let head = response.serializedHead(keepAlive: keepAlive)
            // Reports the outcome to the audit trail exactly once, whichever way the send ends.
            let report = RemoteServer.Once()
            let finish: (Int64, Bool) -> Void = { sent, completed in
                if report.fire() { response.onFinish?(sent, completed) }
            }
            switch response.body {
            case .none, .headOnly:
                send(head, failed: { finish(0, false) }) { self.finish(keepAlive: keepAlive) }
            case .data(let data):
                send(head + data, failed: { finish(0, false) }) {
                    finish(Int64(data.count), true)
                    self.finish(keepAlive: keepAlive)
                }
            case .file(let path, let offset, let length):
                guard let handle = FileHandle(forReadingAtPath: path) else {
                    finish(0, false)
                    return respond(.error(404, "not found"), keepAlive: false)
                }
                send(head, failed: { finish(0, false); try? handle.close() }) {
                    self.stream(handle, from: offset, remaining: length, finish: finish) { self.finish(keepAlive: keepAlive) }
                }
            }
        }

        private func send(_ data: Data, failed: @escaping () -> Void, then next: @escaping () -> Void) {
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return failed() }
                if error == nil { next() } else { failed(); self.close() }
            })
        }

        /// Reads and sends one chunk at a time, waiting for the socket each time, so a slow
        /// editor connection never makes the mini buffer a whole file in memory.
        private func stream(_ handle: FileHandle, from offset: UInt64, remaining: UInt64,
                            finish: @escaping (Int64, Bool) -> Void, done: @escaping () -> Void) {
            DispatchQueue.global(qos: .utility).async {
                var position = offset
                var left = remaining
                var sent: Int64 = 0
                func abort() { try? handle.close(); finish(sent, false); self.close() }
                func pump() {
                    guard left > 0 else {
                        try? handle.close()
                        finish(sent, true)
                        return self.queue.async(execute: done)
                    }
                    let want = Int(min(UInt64(Self.chunk), left))
                    let data: Data? = try? {
                        try handle.seek(toOffset: position)
                        return try handle.read(upToCount: want)
                    }()
                    // A file that shrank mid-download cannot honour its Content-Length: drop the connection.
                    guard let data, !data.isEmpty else { return abort() }
                    position += UInt64(data.count)
                    left -= UInt64(data.count)
                    self.connection.send(content: data, completion: .contentProcessed { error in
                        if error != nil { return abort() }
                        sent += Int64(data.count)
                        DispatchQueue.global(qos: .utility).async(execute: pump)
                    })
                }
                pump()
            }
        }

        private func finish(keepAlive: Bool) {
            guard !closed else { return }
            if keepAlive { receive() } else { close() }
        }
    }
}

// MARK: Client-side certificate pinning

/// Lets an editor's app trust the mini's self-signed certificate, and only that one, by the
/// fingerprint carried in the invite link.
public final class PinnedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let fingerprint: String

    public init(fingerprint: String) { self.fingerprint = fingerprint.lowercased() }

    public static func fingerprint(of certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              Self.fingerprint(of: leaf) == fingerprint else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
