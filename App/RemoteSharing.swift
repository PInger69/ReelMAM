import AppKit
import Foundation
import Observation
import StadaMAMCore
import StadaMAMMedia
import StadaMAMRemote

/// Drives the Remote Sharing tab: whether the proxy server is on, the editors who may connect,
/// and the audit trail. Lives for the whole run of the app, so sharing carries on with the
/// Settings window closed. All the work is done by `RemoteHub`.
@MainActor @Observable
final class RemoteSharingModel {
    enum Status: Equatable {
        case off
        case starting
        case on(RemoteRunning)
        case failed(String)
    }

    struct Invite: Equatable {
        var name: String
        var link: String
    }

    var transport: RemoteTransport {
        didSet { UserDefaults.standard.set(transport.rawValue, forKey: "remoteTransport"); restartIfSharing() }
    }
    /// What editors type or click: the public address of the tunnel, relay or this Mac.
    var publicHost: String {
        didSet { UserDefaults.standard.set(publicHost, forKey: "remotePublicHost") }
    }
    var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "remotePort") }
    }
    /// Ask Let's Encrypt for a certificate browsers trust, instead of using one made here.
    var trustedCertificate: Bool {
        didSet { UserDefaults.standard.set(trustedCertificate, forKey: "remoteTrustedCertificate") }
    }
    /// The owner's own agreement to Let's Encrypt's terms. Nothing is requested without it.
    var agreedToCertificateTerms: Bool {
        didSet { UserDefaults.standard.set(agreedToCertificateTerms, forKey: "remoteCertificateTermsAgreed") }
    }
    /// Where Let's Encrypt writes if a certificate is about to run out. Optional.
    var certificateContact: String {
        didSet { UserDefaults.standard.set(certificateContact, forKey: "remoteCertificateContact") }
    }
    /// The port on this Mac that the public port 80 arrives at.
    var challengePort: Int {
        didSet { UserDefaults.standard.set(challengePort, forKey: "remoteChallengePort") }
    }
    /// Why the last automatic renewal failed, if it did.
    private(set) var renewalProblem: String?
    private(set) var wantsSharing: Bool {
        didSet { UserDefaults.standard.set(wantsSharing, forKey: "remoteSharing") }
    }
    private(set) var status: Status = .off
    private(set) var editors: [EditorSummary] = []
    private(set) var recent: [AuditRecord] = []
    private(set) var entryCount = 0
    private(set) var report: RemoteHub.AuditReport?
    var lastInvite: Invite?
    /// Something that stopped an action, shown beside the control that caused it.
    var problem: String?
    /// Nil until the app has a catalogue and a way to make marked copies.
    private(set) var unavailableReason: String? = "Starting…"

    private var hub: RemoteHub?
    private weak var appModel: AppModel?
    private var notedAnchor: AuditAnchor?
    private static let passphraseAccount = "remote-certificate"

    init() {
        let defaults = UserDefaults.standard
        transport = defaults.string(forKey: "remoteTransport").flatMap(RemoteTransport.init(rawValue:)) ?? .relayPassthrough
        publicHost = defaults.string(forKey: "remotePublicHost") ?? ""
        port = defaults.object(forKey: "remotePort") as? Int ?? 8443
        trustedCertificate = defaults.bool(forKey: "remoteTrustedCertificate")
        agreedToCertificateTerms = defaults.bool(forKey: "remoteCertificateTermsAgreed")
        certificateContact = defaults.string(forKey: "remoteCertificateContact") ?? ""
        challengePort = defaults.object(forKey: "remoteChallengePort") as? Int ?? 80
        wantsSharing = defaults.bool(forKey: "remoteSharing")
        notedAnchor = defaults.data(forKey: "remoteNotedAnchor").flatMap { try? JSONDecoder().decode(AuditAnchor.self, from: $0) }
    }

    var isSharing: Bool {
        if case .on = status { return true }
        return false
    }

    /// The folder proxies are served from: wherever new proxies are written.
    var proxyFolder: String? { appModel?.library?.proxyRoot }

    // MARK: Setting up

    /// Called once the app has opened its catalogue. Picks sharing back up if it was on.
    func attach(_ model: AppModel) {
        guard hub == nil else { return }
        appModel = model
        guard let library = model.library, let tools = library.tools else {
            unavailableReason = "Sharing needs FFmpeg, which puts the StradaXR mark on each editor's proxies. Install it (brew install ffmpeg) and reopen the app."
            return
        }
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StadaXR MAM/Remote")
            let renderer = WatermarkRenderer(tools: tools, cacheRoot: support.appendingPathComponent("Marked Copies").path)
            hub = try RemoteHub(directory: support.path, catalog: model.catalog, watermarker: renderer)
            unavailableReason = nil
            refresh()
            if wantsSharing { start() }
        } catch {
            unavailableReason = "Remote sharing could not open its records: \(error.localizedDescription)"
        }
    }

    private func config() -> RemoteConfig? {
        guard let root = proxyFolder else { return nil }
        var passphrase = Keychain.token(for: Self.passphraseAccount) ?? ""
        if passphrase.isEmpty {
            passphrase = UUID().uuidString + UUID().uuidString
            Keychain.setToken(passphrase, for: Self.passphraseAccount)
        }
        var config = RemoteConfig(transport: transport, publicHost: publicHost, port: UInt16(clamping: port),
                                  proxyRoots: [root], certificatePassphrase: passphrase)
        if trustedCertificate, transport.usesTLS {
            config.certificate = .letsEncrypt(contact: certificateContact, agreedToTerms: agreedToCertificateTerms)
            config.challengePort = UInt16(clamping: challengePort)
        }
        return config
    }

    // MARK: Sharing

    func setSharing(_ on: Bool) {
        wantsSharing = on
        on ? start() : stop()
    }

    private func restartIfSharing() {
        if wantsSharing, hub != nil { start() }
    }

    func start() {
        guard let hub, let config = config() else { return }
        problem = nil
        status = .starting
        Task {
            do {
                status = .on(try await hub.start(config))
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        hub?.stop()
        status = .off
    }

    // MARK: Editors

    func invite(name: String, days: Int?) {
        guard let hub, let config = config() else { return }
        do {
            let (grant, link) = try hub.invite(name: name, expiresInDays: days, config: config)
            lastInvite = Invite(name: grant.name, link: link.webURL.absoluteString)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        refresh()
    }

    func revoke(_ editor: EditorSummary) {
        do { try hub?.grants.revoke(id: editor.id) } catch { problem = error.localizedDescription }
        refresh()
    }

    func resetInitials(_ editor: EditorSummary) {
        do { try hub?.grants.resetInitials(id: editor.id) } catch { problem = error.localizedDescription }
        refresh()
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Audit trail

    func refresh() {
        guard let hub else { return }
        editors = (try? hub.editors()) ?? editors
        recent = (try? hub.audit.entries(limit: 40)) ?? recent
        entryCount = (try? hub.audit.count()) ?? entryCount
        // A renewal changes the certificate's date while sharing stays on.
        if case .on = status, let running = hub.running { status = .on(running) }
        renewalProblem = hub.renewalProblem
    }

    func verify() {
        guard let hub else { return }
        do {
            report = try hub.verifyAudit(against: notedAnchor)
        } catch {
            report = RemoteHub.AuditReport(entries: 0, ok: false, message: error.localizedDescription, anchor: nil)
        }
        refresh()
    }

    /// The anchor text to keep somewhere the log cannot reach, and remembered here so the next
    /// verification checks that nothing before it has gone.
    func noteAnchor() {
        guard let anchor = report?.anchor ?? (try? hub?.audit.anchor()) ?? nil else { return }
        notedAnchor = anchor
        UserDefaults.standard.set(try? JSONEncoder().encode(anchor), forKey: "remoteNotedAnchor")
        copy("StradaXR audit log: entry \(anchor.seq), seal \(anchor.hash)")
    }

    var notedAnchorText: String? { notedAnchor.map { "entry \($0.seq)" } }

    func export() {
        guard let hub else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "StradaXR audit log.jsonl"
        panel.message = "One line per entry, oldest first."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try hub.exportAudit(to: url) } catch { problem = error.localizedDescription }
    }
}

extension RemoteTransport {
    var displayName: String {
        switch self {
        case .relayPassthrough: return "Through a relay that passes the connection straight through"
        case .tunnel: return "Through a tunnel that adds its own certificate (Cloudflare Tunnel)"
        case .direct: return "Directly to this Mac"
        }
    }

    var explanation: String {
        switch self {
        case .relayPassthrough:
            return "This Mac makes the connection out to your relay server, which hands editors' encrypted traffic to it untouched, so the relay cannot read anything. Browsers will warn about this Mac's own certificate, so editors in a browser need a certificate their browser trusts installed on the relay path first. Nothing listens beyond this Mac itself."
        case .tunnel:
            return "A tunnel program on this Mac forwards a public address to a plain local port and supplies the certificate editors' browsers trust. The tunnel company sees the traffic. Check that its terms allow carrying this much video before relying on it. This is the setting that works with a browser today."
        case .direct:
            return "Editors connect straight to this Mac over your own internet line, and nobody else carries the video. It needs a domain name pointed at your public address and your router sending port 443 to this Mac. Turn on the trusted certificate below so browsers open it without a warning."
        }
    }
}
