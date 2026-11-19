// Apple platforms only: this code is built on CryptoKit, Network and Security.
#if canImport(CryptoKit) && canImport(Network)
import Foundation
import Security

/// The mini's own TLS certificate, for the modes where it (not a tunnel) is what editors see.
/// Self-signed: editors do not trust it through the system, they pin its fingerprint from the
/// invite link, which is stronger than a certificate authority for a single known server.
public struct ServerIdentity: @unchecked Sendable {
    public var identity: SecIdentity
    public var certificate: SecCertificate
    /// SHA-256 of the certificate, lower-case hex: what goes in the invite as `fp`.
    public var fingerprint: String
    /// The certificates between this one and the authority's root, sent to browsers with it.
    /// Empty for a self-signed certificate.
    public var chain: [SecCertificate] = []
    /// When the certificate stops being valid.
    public var expires: Date?

    public enum Failure: Error, LocalizedError {
        case openSSLMissing
        case generationFailed(String)
        case importFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .openSSLMissing: return "macOS's openssl tool was not found, so a certificate could not be made."
            case .generationFailed(let why): return "The certificate could not be made: \(why)"
            case .importFailed(let status): return "The certificate could not be read (error \(status))."
            }
        }
    }

    /// Reads the certificate in `directory`, making one the first time (and again when it has
    /// expired or no longer covers `hostnames`). `passphrase` protects the file; keep it in the keychain.
    public static func loadOrCreate(in directory: String, passphrase: String, hostnames: [String]) throws -> ServerIdentity {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let p12 = directory + "/identity.p12"
        let names = (hostnames + ["localhost"]).map { $0.lowercased() }
        let namesFile = directory + "/identity.hosts"
        let known = (try? String(contentsOfFile: namesFile, encoding: .utf8)).map { Set($0.split(separator: "\n").map(String.init)) }
        if fm.fileExists(atPath: p12), let known, Set(names).isSubset(of: known),
           let existing = try? load(p12, passphrase: passphrase) { return existing }

        let key = directory + "/key.pem", cert = directory + "/cert.pem"
        defer { try? fm.removeItem(atPath: key); try? fm.removeItem(atPath: cert) }
        let openssl = "/usr/bin/openssl"
        guard fm.isExecutableFile(atPath: openssl) else { throw Failure.openSSLMissing }
        let san = names.map { host -> String in
            host.allSatisfy { $0.isNumber || $0 == "." } ? "IP:\(host)" : "DNS:\(host)"
        }.joined(separator: ",")
        try run(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                          "-days", "3650", "-subj", "/CN=\(names.first ?? "localhost")", "-addext", "subjectAltName=\(san)"])
        try run(openssl, ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12, "-passout", "pass:\(passphrase)"])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12)
        try names.joined(separator: "\n").write(toFile: namesFile, atomically: true, encoding: .utf8)
        return try load(p12, passphrase: passphrase)
    }

    static func load(_ path: String, passphrase: String) throws -> ServerIdentity {
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        // Keep the key in memory only: no keychain prompt, nothing left in the keychain, and it
        // works where no keychain is available (a locked screen, a background session).
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        let status = SecPKCS12Import(try Data(contentsOf: URL(fileURLWithPath: path)) as CFData,
                                     options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let any = first[kSecImportItemIdentity as String] else { throw Failure.importFailed(status) }
        let identity = any as! SecIdentity
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        guard let certificate else { throw Failure.importFailed(errSecInternalError) }
        let all = first[kSecImportItemCertChain as String] as? [SecCertificate] ?? []
        return ServerIdentity(identity: identity, certificate: certificate,
                              fingerprint: PinnedCertificateDelegate.fingerprint(of: certificate),
                              chain: Array(all.dropFirst()), expires: expiry(of: certificate))
    }

    static func expiry(of certificate: SecCertificate) -> Date? { date(kSecOIDX509V1ValidityNotAfter as String, in: certificate) }
    static func validFrom(_ certificate: SecCertificate) -> Date? { date(kSecOIDX509V1ValidityNotBefore as String, in: certificate) }

    private static func date(_ oid: String, in certificate: SecCertificate) -> Date? {
        guard let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [String: Any],
              let entry = values[oid] as? [String: Any],
              let seconds = entry[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.generationFailed(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
#endif
