import StradaMAMCore
import StradaMAMRemote
import SwiftUI

/// Where the owner lets editors on other computers see the catalogue and pull proxies: who may
/// connect, how they reach this Mac, and the record of what they did.
struct RemoteSharingView: View {
    @Environment(AppModel.self) private var model
    @Environment(RemoteSharingModel.self) private var remote
    @State private var inviting = false
    @State private var revoking: EditorSummary?

    var body: some View {
        @Bindable var remote = remote
        ScrollView {
            Form {
                Section("Sharing") {
                    Toggle("Share proxies with editors", isOn: Binding(get: { remote.wantsSharingOrOn }, set: { remote.setSharing($0) }))
                        .disabled(remote.unavailableReason != nil || (!remote.isSharing && remote.publicHost.trimmingCharacters(in: .whitespaces).isEmpty && remote.transport != .tunnel))
                    statusLine
                    Text("Editors see the catalogue and play or download proxies, nothing else. Camera originals never leave this Mac, and every proxy they get has the StradaXR mark on it.")
                        .font(.callout).foregroundStyle(.secondary)
                    Picker("Editors reach this Mac", selection: $remote.transport) {
                        ForEach(RemoteTransport.allCases, id: \.self) { transport in
                            Text(transport.displayName).tag(transport)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text(remote.transport.explanation).font(.callout).foregroundStyle(.secondary)
                    TextField("Address editors use", text: $remote.publicHost, prompt: Text("mam.example.com"))
                    TextField("Port on this Mac", value: $remote.port, format: .number.grouping(.never))
                        .frame(maxWidth: 220)
                    if remote.transport.usesTLS {
                        Toggle("Get a certificate browsers trust, from Let's Encrypt", isOn: $remote.trustedCertificate)
                        if remote.trustedCertificate {
                            Text("This Mac asks Let's Encrypt for a free certificate for the address above and renews it by itself. Let's Encrypt checks the address by connecting to it on port 80, so your router has to send port 80 to this Mac as well, and keep doing so for renewals. That port answers the checks and nothing else.")
                                .font(.callout).foregroundStyle(.secondary)
                            TextField("Port on this Mac for the checks", value: $remote.challengePort, format: .number.grouping(.never))
                                .frame(maxWidth: 320)
                            TextField("Email for expiry warnings", text: $remote.certificateContact, prompt: Text("Optional"))
                            Toggle("I agree to the Let's Encrypt Subscriber Agreement", isOn: $remote.agreedToCertificateTerms)
                            Link("Read the agreement", destination: URL(string: "https://letsencrypt.org/repository/")!)
                                .font(.callout)
                            if let problem = remote.renewalProblem {
                                Text("The certificate could not be renewed and the current one is still in use. \(problem)")
                                    .font(.callout).foregroundStyle(.red)
                            }
                        } else {
                            Text("Without it this Mac uses a certificate it makes itself, which browsers warn about.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Text("Changes here take effect the next time sharing is switched on.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Proxies are served from")
                        Text(remote.proxyFolder ?? "—").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }
                    Text("Change the folder in Dialogue & Storage. Proxies kept beside their originals are not shared.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Section("Editors") {
                    if remote.editors.isEmpty {
                        Text("No editors yet. Invite one to get a link they open in the app to connect.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(remote.editors) { editor in
                        EditorRow(editor: editor, reset: { remote.resetInitials(editor) }, revoke: { revoking = editor })
                    }
                    HStack {
                        Button("Invite Editor…") { inviting = true }
                        if let problem = remote.problem { Text(problem).font(.callout).foregroundStyle(.red) }
                    }
                    Text("Each editor chooses their initials the first time they connect and cannot change them. Revoking someone stops their next request.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Section("Audit trail") {
                    Text("Every sign-in, search, play and download is recorded with the editor's name and initials, and what was actually sent. Entries cannot be changed or removed without it showing.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text("\(remote.entryCount) entries").monospacedDigit()
                        Spacer()
                        Button("Verify") { remote.verify() }
                        Button("Export…") { remote.export() }
                        Button("Copy Anchor") { remote.noteAnchor() }
                            .help("Copies a short note of how far the log has got. Keep it somewhere safe, such as an email to yourself; verifying later then catches a log that was cut short.")
                    }
                    if let report = remote.report {
                        Text(report.message).font(.callout)
                            .foregroundStyle(report.ok ? Color.secondary : Color.red)
                    }
                    if let noted = remote.notedAnchorText {
                        Text("Checked against your noted anchor at \(noted).").font(.caption).foregroundStyle(.secondary)
                    }
                    List {
                        ForEach(remote.recent, id: \.seq) { entry in
                            HStack {
                                Text(entry.at, format: .dateTime.month().day().hour().minute().second())
                                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                                Text(entry.editor ?? "Unknown").frame(width: 110, alignment: .leading)
                                Text(AuditWording.describe(entry)).lineLimit(1)
                                Spacer()
                            }
                            .font(.callout)
                        }
                    }
                    .frame(minHeight: 150)
                }
            }
            .padding(20)
        }
        .onAppear { remote.refresh() }
        .sheet(isPresented: $inviting) { InviteEditorSheet().environment(remote) }
        .confirmationDialog("Revoke \(revoking?.name ?? "this editor")?", isPresented: Binding(get: { revoking != nil },
                                                                                             set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible) {
            Button("Revoke", role: .destructive) { if let editor = revoking { remote.revoke(editor) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They lose access at once. Their entries stay in the audit trail.")
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch remote.status {
        case .off:
            Text(remote.unavailableReason ?? "Off").font(.callout).foregroundStyle(.secondary)
        case .starting:
            Text("Starting…").font(.callout).foregroundStyle(.secondary)
        case .on(let running):
            Text("On, listening on port \(running.port) of this Mac. " + Self.pointing(running) + Self.certificate(running))
                .font(.callout).foregroundStyle(.secondary)
        case .failed(let why):
            Text(why).font(.callout).foregroundStyle(.red)
        }
    }
}

private extension RemoteSharingView {
    static func pointing(_ running: RemoteRunning) -> String {
        switch running.transport {
        case .tunnel: return "Point your tunnel at http://127.0.0.1:\(running.port)."
        case .relayPassthrough: return "Point your relay at 127.0.0.1:\(running.port)."
        case .direct:
            return "Your router should send port 443 to port \(running.port) of this Mac"
                + (running.challengePort.map { " and port 80 to port \($0)." } ?? ".")
        }
    }

    static func certificate(_ running: RemoteRunning) -> String {
        guard running.publiclyTrusted else { return "" }
        return " Browsers trust its certificate" + (running.certificateExpires.map {
            ", which renews by itself before \($0.formatted(date: .abbreviated, time: .omitted))."
        } ?? ".")
    }
}

private extension RemoteSharingModel {
    /// The switch shows what the owner asked for until the server has answered.
    var wantsSharingOrOn: Bool { isSharing || { if case .starting = status { return true } else { return false } }() }
}

/// What an audit entry says in plain words.
enum AuditWording {
    static func describe(_ entry: AuditRecord) -> String {
        switch entry.kind {
        case .signInFailed: return "Refused sign-in (\(entry.detail ?? "no reason given"))"
        case .admin:
            switch entry.path {
            case "invite": return "Invited"
            case "revoke": return "Revoked"
            case "certificate": return entry.detail?.hasPrefix("issued") == true ? "Got a new certificate" : "Could not get a certificate"
            default: return "Initials reset"
            }
        case .transfer:
            let size = ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)
            return entry.detail == "complete" ? "Finished a download, \(size)" : "Download stopped after \(size)"
        case .request:
            if entry.path.hasPrefix("/v1/proxies/") { return entry.status == 202 ? "Waiting for a proxy to be prepared" : "Asked for a proxy" }
            if entry.path.hasPrefix("/v1/search") { return "Searched" }
            if entry.path == "/v1/me/initials" { return "Chose initials" }
            if entry.path.hasPrefix("/v1/manifest") { return "Listed a day's proxies" }
            return "Browsed the catalogue"
        }
    }
}

private struct EditorRow: View {
    let editor: EditorSummary
    let reset: () -> Void
    let revoke: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(editor.name)
                    if let initials = editor.initials { Text(initials).font(.callout.monospaced()).foregroundStyle(.secondary) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if editor.initials != nil && editor.status != .revoked { Button("Reset Initials", action: reset).controlSize(.small) }
            if editor.status != .revoked { Button("Revoke", action: revoke).controlSize(.small) }
        }
    }

    private var detail: String {
        var parts: [String] = []
        switch editor.status {
        case .active: parts.append("Connected before" + (editor.lastSeenAt == nil ? " — never" : ""))
        case .waitingForInitials: parts.append("Has not chosen initials yet")
        case .revoked: parts.append("Revoked")
        case .expired: parts.append("Invite expired")
        }
        if let seen = editor.lastSeenAt { parts.append("last seen " + seen.formatted(.relative(presentation: .named))) }
        parts.append("pulled " + ByteCountFormatter.string(fromByteCount: editor.bytesPulled, countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

/// Makes an invite and shows its link once.
private struct InviteEditorSheet: View {
    @Environment(RemoteSharingModel.self) private var remote
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var days = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let invite = remote.lastInvite {
                Text("Invite for \(invite.name)").font(.headline)
                Text(invite.link)
                    .font(.callout.monospaced()).textSelection(.enabled).lineLimit(4)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Text("This link is the editor's key and is shown only now. Editors open it in their browser; send it privately, such as in a message to them. If it leaks, revoke the editor and invite them again.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Copy Link") { remote.copy(invite.link) }
                    Button("Done") { remote.lastInvite = nil; dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Invite Editor").font(.headline)
                TextField("Name", text: $name, prompt: Text("Who is this for?"))
                Picker("Invite lasts", selection: $days) {
                    Text("Until revoked").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                if let problem = remote.problem { Text(problem).font(.callout).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { remote.problem = nil; dismiss() }
                    Button("Create Invite") { remote.invite(name: name, days: days == 0 ? nil : days) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
