import StradaMAMCore
import StradaMAMMedia
import SwiftUI

/// The ingest window: choose where clips come from and where originals live, then start.
struct IngestView: View {
    @Environment(IngestModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Form {
                Section("Source") {
                    LabeledContent("Card or folder") {
                        HStack {
                            path(model.sourceLabel, placeholder: "None chosen")
                            Menu("Choose") {
                                let external = model.volumes.filter(\.isExternal)
                                let others = model.volumes.filter { !$0.isExternal }
                                let cameras = model.phones.cameras
                                Section("Cards and External Drives") {
                                    ForEach(external) { volume in
                                        Button(volume.label) { model.source = volume.path }
                                    }
                                    if external.isEmpty { Text("None connected") }
                                }
                                Section("iPhones and Cameras") {
                                    ForEach(cameras) { camera in
                                        Button(camera.name) { model.choose(cameras: [camera]) }
                                    }
                                    if cameras.count > 1 {
                                        Button("All \(cameras.count) Connected") { model.choose(cameras: cameras) }
                                    }
                                    if cameras.isEmpty { Text("None connected") }
                                }
                                Section("Other Volumes") {
                                    ForEach(others) { volume in
                                        Button(volume.label) { model.source = volume.path }
                                    }
                                }
                                Divider()
                                Button("Other Folder…") { model.chooseSource() }
                            }
                            .fixedSize()
                        }
                    }
                    Text("A card in a reader, a drive, an iPhone on a cable, a network share or any folder. Nothing on it is changed. An iPhone has to be unlocked and trusted with this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .disabled(model.isRunning)

                Section("Originals") {
                    LabeledContent("Storage") {
                        HStack {
                            path(model.storage, placeholder: "Leave clips where they are")
                            if model.storage != nil {
                                Button { model.storage = nil } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless)
                                    .help("Do not copy. Make proxies of the clips where they are.")
                            }
                            Button("Choose…") { model.chooseStorage() }
                        }
                    }
                    Text(model.storage == nil
                         ? (model.chosenCameras.isEmpty
                            ? "No clips are copied. Each clip is catalogued where it is and given a proxy. Choose this when the source is already your NAS or local storage."
                            : "Clips from an iPhone cannot stay on the phone: they are fetched into Movies › StradaXR Ingest › Originals on this Mac. Choose a storage folder to put them there instead.")
                         : "A clip that is already anywhere in this folder is not copied again: it only gets a proxy. A clip that is not there is copied, the copy is checked against the source, and then it gets a proxy.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .disabled(model.isRunning)

                Section("Proxies") {
                    Picker("Format", selection: $model.preset) {
                        ForEach(ProxyPreset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    LabeledContent("Library") {
                        HStack {
                            path(model.libraryFolder, placeholder: "StradaXR A.I. MAM on this Mac")
                            if model.libraryFolder != nil {
                                Button { model.libraryFolder = nil } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless)
                                    .help("Use the library of StradaXR A.I. MAM on this Mac.")
                            }
                            Button("Choose…") { model.chooseLibrary() }
                        }
                    }
                    Text("Every proxy keeps its clip's name, timecode and reel, and is checked against its original before it counts as done.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .disabled(model.isRunning)

                if model.view != nil || model.summary != nil {
                    progress
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(statusIsProblem ? Color.red : Color.secondary)
                    .lineLimit(2)
                Spacer()
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.stop() }
                        .disabled(model.isStopping)
                        .help("Finish the clips being worked on and start no more.")
                } else {
                    Button("Start") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canStart)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder private var progress: some View {
        let counts = model.view?.counts ?? IngestCounts()
        Section("Progress") {
            HStack(spacing: 24) {
                IngestCount(value: model.summary?.ingested ?? counts.doneToday, label: "done")
                IngestCount(value: model.copied, label: "copied")
                IngestCount(value: model.alreadyOnStorage, label: "already on storage")
                IngestCount(value: counts.working, label: "working")
                IngestCount(value: counts.waiting + counts.waitingForVolume, label: "waiting")
                IngestCount(value: counts.failed, label: "failed")
            }
        }
        if let view = model.view {
            Section("Clips") {
                if view.working.isEmpty && view.waiting.isEmpty && view.failed.isEmpty && view.recentlyDone.isEmpty {
                    Text(model.isRunning ? "Looking for clips…" : "No new clips were found.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(view.working) { item in
                    IngestItemRow(item: item, detail: item.stage ?? "Working", progress: item.progress)
                }
                ForEach(view.failed) { item in
                    IngestItemRow(item: item, detail: item.reason ?? "Failed", isProblem: true)
                }
                ForEach(view.waiting) { item in
                    IngestItemRow(item: item, detail: item.isWaitingForVolume ? "Waiting for its volume" : "Waiting")
                }
                if counts.waiting + counts.waitingForVolume > view.waiting.count {
                    Text("and \(counts.waiting + counts.waitingForVolume - view.waiting.count) more waiting")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(view.recentlyDone) { item in
                    IngestItemRow(item: item, detail: item.reason ?? "Done")
                }
            }
        }
    }

    private func path(_ value: String?, placeholder: String) -> some View {
        Text(value ?? placeholder)
            .foregroundStyle(value == nil ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(value ?? "")
    }

    private var statusIsProblem: Bool {
        model.problem != nil || model.blocker != nil || !(model.summary?.failures.isEmpty ?? true)
    }

    private var status: String {
        if let problem = model.problem { return problem }
        if model.isStopping && model.isRunning { return "Stopping after the clips being worked on." }
        if let fetching = model.fetching { return fetching }
        if model.isRunning { return "Working. The Mac stays awake until this is finished." }
        if let summary = model.summary {
            let waiting = (model.view?.counts.waiting ?? 0) + (model.view?.counts.waitingForVolume ?? 0)
            let text = IngestClient.describe(summary).split(separator: "\n").first.map(String.init) ?? ""
            return waiting > 0 ? "Stopped. \(text) \(waiting) not started." : text
        }
        if let blocker = model.blocker { return blocker }
        return model.sourceLabel == nil ? "Choose a source to begin." : "Ready."
    }
}
