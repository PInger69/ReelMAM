import StradaMAMCore
import StradaMAMMedia
import SwiftUI

/// Settings › Watch Folders: the folders that feed the library by themselves, and what is being
/// made from them right now.
struct WatchFoldersView: View {
    @Environment(AppModel.self) private var model
    @Environment(ContinuousIngestModel.self) private var ingest

    var body: some View {
        @Bindable var ingest = ingest
        ScrollView {
            Form {
                Section("Watch folders") {
                    Toggle("Import new footage and make proxies automatically", isOn: $ingest.isOn)
                        .disabled(ingest.unavailableReason != nil)
                    if let reason = ingest.unavailableReason {
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    }
                    Text("New clips that land in these folders are catalogued and given proxies with nobody clicking Import. A clip is taken only once it has stopped growing, so a card still copying is left alone. Anything that arrived while the app was closed is picked up when it opens.")
                        .font(.callout).foregroundStyle(.secondary)
                    let folders = ingest.view?.folders ?? []
                    if folders.isEmpty {
                        Text("No folders yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(folders) { folder in
                        HStack {
                            Toggle("Watch", isOn: Binding(get: { folder.isEnabled }, set: { ingest.set(folder, enabled: $0) }))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.path).lineLimit(1).truncationMode(.middle)
                                Text(statusText(for: folder)).font(.caption).foregroundStyle(statusIsProblem(folder) ? Color.orange : Color.secondary)
                            }
                            Spacer()
                            Button {
                                ingest.remove(folder)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop watching this folder. Clips already catalogued stay.")
                        }
                    }
                    HStack {
                        Button("Add Folder…") { ingest.addFolders() }
                        Button("Scan Now") { ingest.scanNow() }
                            .disabled(ingest.view?.folders.isEmpty ?? true)
                    }
                    Text("Drives and mounted network shares work too. A share that is not mounted is not an error: it is checked again when it appears. Network shares are scanned about once a minute.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Section("Proxies for new clips") {
                    Toggle("Proxy for editors here (\(model.defaultPreset.displayName))", isOn: $ingest.makesLocalProxy)
                    Toggle("Remote proxy for editors on other computers (\(ProxyPreset.remoteHEVC.displayName))", isOn: $ingest.makesRemoteProxy)
                    Text("Editors on other computers see only clips that have a finished remote proxy, so leave it on while Remote Sharing is in use. A clip that already has a checked proxy of a format is never rendered again. Renders share the same limit as proxies made by hand.")
                        .font(.callout).foregroundStyle(.secondary)
                    Stepper(value: $ingest.stabilitySeconds, in: 5...600, step: 5) {
                        Text("Wait until a file has stopped changing for \(ingest.stabilitySeconds) seconds")
                    }
                    Toggle("Open this app when I log in", isOn: Binding(get: { ingest.launchesAtLogin }, set: { ingest.setLaunchesAtLogin($0) }))
                    if let problem = ingest.problem { Text(problem).font(.callout).foregroundStyle(.red) }
                    Text("For a Mac that runs unattended: the app picks up where it left off after a restart, and keeps the Mac awake while there is footage to process.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                if let view = ingest.view {
                    Section("Today") {
                        HStack(spacing: 24) {
                            count(view.counts.doneToday, "done")
                            count(view.counts.working, "rendering")
                            count(view.counts.waiting + view.counts.waitingForVolume, "waiting")
                            count(view.stabilizing, "still copying")
                            count(view.counts.failed, "failed")
                        }
                        if view.counts.waitingForVolume > 0 {
                            Text("\(view.counts.waitingForVolume) waiting for a volume to be mounted.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }

                    Section("Queue") {
                        if view.working.isEmpty && view.waiting.isEmpty && view.failed.isEmpty && view.recentlyDone.isEmpty {
                            Text("Nothing in the queue.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(view.working) { item in
                            ItemRow(item: item, detail: item.stage ?? "Working", progress: item.progress)
                        }
                        ForEach(view.failed) { item in
                            ItemRow(item: item, detail: item.reason ?? "Failed", isProblem: true) {
                                Button("Retry") { ingest.retry(item) }.controlSize(.small)
                                Button { ingest.dismiss(item) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .help("Remove from the list. The next scan will find the file again.")
                            }
                        }
                        ForEach(view.waiting) { item in
                            ItemRow(item: item, detail: item.isWaitingForVolume ? "Waiting for its volume" : "Waiting")
                        }
                        if view.counts.waiting + view.counts.waitingForVolume > view.waiting.count {
                            Text("and \(view.counts.waiting + view.counts.waitingForVolume - view.waiting.count) more waiting")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(view.recentlyDone) { item in
                            ItemRow(item: item, detail: item.reason ?? "Done")
                        }
                        if view.counts.failed > 1 {
                            Button("Retry All Failed") { ingest.retryAllFailed() }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func count(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(value)").font(.title2.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statusText(for folder: WatchFolder) -> String {
        guard folder.isEnabled else { return "Off" }
        switch ingest.view?.status[folder.id] ?? .idle {
        case .idle: return "Waiting for the first scan"
        case .scanning: return "Scanning…"
        case .watching(let last): return "Watching · last scan " + last.formatted(.relative(presentation: .named))
        case .offline: return "Not available. Checked again when it is mounted."
        }
    }

    private func statusIsProblem(_ folder: WatchFolder) -> Bool {
        folder.isEnabled && ingest.view?.status[folder.id] == .offline
    }
}

private struct ItemRow<Actions: View>: View {
    let item: IngestItem
    let detail: String
    var progress: Double?
    var isProblem = false
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(isProblem ? Color.red : Color.secondary)
                    .lineLimit(2)
                if let progress { ProgressView(value: progress).controlSize(.small) }
            }
            Spacer()
            actions
        }
    }
}

private extension ItemRow where Actions == EmptyView {
    init(item: IngestItem, detail: String, progress: Double? = nil, isProblem: Bool = false) {
        self.init(item: item, detail: detail, progress: progress, isProblem: isProblem) { EmptyView() }
    }
}
