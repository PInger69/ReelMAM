import StradaMAMCore
import StradaMAMMedia
import SwiftUI

/// The ingest window, laid out like a two-pane copy tool: sources on the left, the destination
/// on the right, every clip found between them, and Scan and Copy in the toolbar.
struct IngestView: View {
    @Environment(IngestModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                SourcesPane()
                    .frame(maxWidth: .infinity)
                Divider()
                DestinationPane()
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 200)
            if !model.slowSources.isEmpty {
                Divider()
                SpeedWarning(sources: model.slowSources)
            }
            Divider()
            FilterBar()
            Divider()
            ClipTable()
            Divider()
            StatusBar()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .disabled(!model.canScan)
                .help("List the clips on the ticked sources and check which were copied before")
                if model.stage == .copying {
                    Button {
                        model.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(model.isStopping)
                    .help("Finish the clips being copied and start no more")
                } else {
                    Button {
                        model.copy()
                    } label: {
                        Label(model.destination == nil ? "Make Proxies" : "Copy", systemImage: "arrow.right.doc.on.clipboard")
                    }
                    .disabled(!model.canCopy)
                    .help(model.copyBlocker ?? "Copy the ticked clips, check each copy, then make proxies")
                }
            }
        }
        .toolbarRole(.editor)
        .labelStyle(.titleAndIcon)
    }
}

// MARK: Left: sources

private struct SourcesPane: View {
    @Environment(IngestModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sources").font(.headline)
                Spacer()
                Button("Add Folder…") { model.addFolder() }
                    .controlSize(.small)
                    .disabled(model.isBusy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if model.sources.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Connected", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("Connect a card reader, a drive or an unlocked iPhone, or add a folder.")
                }
            } else {
                List {
                    ForEach(model.sources) { source in
                        SourceRow(source: source)
                    }
                }
                .listStyle(.inset)
                .disabled(model.isBusy)
            }
        }
    }
}

private struct SourceRow: View {
    @Environment(IngestModel.self) private var model
    let source: TransferSource

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { model.isTicked(source) }, set: { model.setTicked(source, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let link = source.link {
                Label(link.label, systemImage: link.isBelowRecommended ? "exclamationmark.triangle.fill" : "bolt.horizontal.fill")
                    .font(.caption)
                    .foregroundStyle(link.isBelowRecommended ? Color.orange : Color.secondary)
                    .help(link.isBelowRecommended ? "Connected below 10 Gbps: copying will be slower than it should be." : "Connection speed")
            } else if source.isExternal {
                Text("Speed unknown").font(.caption).foregroundStyle(.secondary)
            }
            if model.isRemovable(source) {
                Button {
                    model.remove(source)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this folder from the sources")
            }
        }
    }

    private var icon: String {
        switch source.kind {
        case .device: return "iphone"
        case .folder: return source.isExternal ? (source.name.localizedCaseInsensitiveContains("card") ? "sdcard" : "externaldrive") : "folder"
        }
    }

    private var detail: String {
        switch source.kind {
        case .device: return "iPhone or camera on a cable"
        case .folder(let path):
            if let capacity = source.capacity { return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file) + " · " + path }
            return path
        }
    }
}

// MARK: Right: destination

private struct DestinationPane: View {
    @Environment(IngestModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Text("Destination").font(.headline)
            HStack {
                Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(.secondary)
                Text(model.destination ?? "None chosen: proxies are made where the clips are")
                    .foregroundStyle(model.destination == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.destination ?? "")
                Spacer()
                if model.destination != nil {
                    Button { model.destination = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Copy nothing. Make proxies of the clips where they are.")
                }
                Button("Choose…") { model.chooseDestination() }
            }
            Text(destinationNote).font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Toggle("Make proxies", isOn: $model.makesProxies)
                Picker("Format", selection: $model.preset) {
                    ForEach(ProxyPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .disabled(!model.makesProxies)
                .fixedSize()
            }
            HStack {
                Text("Library").foregroundStyle(.secondary)
                Text(model.libraryFolder ?? "StradaXR A.I. MAM on this Mac")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if model.libraryFolder != nil {
                    Button { model.libraryFolder = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Use the library of StradaXR A.I. MAM on this Mac.")
                }
                Button("Choose…") { model.chooseLibrary() }
                    .controlSize(.small)
            }
            .font(.callout)
        }
        .padding(12)
        .disabled(model.isBusy)
    }

    private var destinationNote: String {
        guard model.destination != nil else {
            return "Choose a folder on the NAS or a local drive to copy clips into. Each source gets a folder of its own name."
        }
        if let free = model.freeSpace {
            return ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free. Each source gets a folder of its own name. Every copy is read back and checked before it counts."
        }
        return "Each source gets a folder of its own name. Every copy is read back and checked before it counts."
    }
}

private struct SpeedWarning: View {
    let sources: [TransferSource]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private var message: String {
        let names = sources.map { "\($0.name) (\($0.link?.rate ?? ""))" }.joined(separator: ", ")
        return "\(names) \(sources.count == 1 ? "is" : "are") connected below 10 Gbps, so copying will be slow. Use a 10 Gbps USB-C cable and a USB-C port on the Mac, not a hub."
    }
}

// MARK: Middle: the clips

private struct FilterBar: View {
    @Environment(IngestModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Toggle(isOn: $model.filter.new) {
                Label("New \(model.count(\.new))", systemImage: "plus.circle")
            }
            .help("Clips not copied before")
            Toggle(isOn: $model.filter.copiedBefore) {
                Label("Copied Before \(model.count(\.copiedBefore))", systemImage: "clock.arrow.circlepath")
            }
            .help("Clips copied before to somewhere other than this destination")
            Toggle(isOn: $model.filter.atDestination) {
                Label("Already at Destination \(model.count(\.atDestination))", systemImage: "checkmark.circle")
            }
            .help("Clips whose content is already in the destination. Ticking one makes its proxy without copying it again.")
            Spacer()
            Button("Tick New") { model.chooseNew() }
            Button("Tick All") { model.chooseAllVisible() }
            Button("Tick None") { model.chooseNone() }
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .disabled(model.isBusy || model.items.isEmpty)
    }
}

private struct ClipTable: View {
    @Environment(IngestModel.self) private var model
    @State private var highlighted: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\TransferItem.relativePath)]

    var body: some View {
        let rows = model.visibleItems.sorted(using: sortOrder)
        Table(rows, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: Binding(get: { model.chosen.contains(item.id) },
                                         set: { model.setChosen(highlighted.contains(item.id) ? highlighted : [item.id], $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(model.isBusy)
            }
            .width(22)
            TableColumn("Name", value: \.relativePath) { item in
                Label(item.relativePath, systemImage: "film")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.sourcePath ?? item.name)
            }
            .width(min: 180, ideal: 300)
            TableColumn("Source", value: \.sourceName) { item in
                Text(item.sourceName).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
            TableColumn("Size", value: \.size) { item in
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Date", value: \.sortDate) { item in
                Text(item.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
            }
            .width(min: 90, ideal: 140)
            TableColumn("Status") { item in
                StatusCell(item: item, phase: model.phase(of: item))
            }
            .width(min: 160, ideal: 240)
            TableColumn("Copies to") { item in
                Text(item.destinationPath.map(shortened) ?? "Stays where it is")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.destinationPath ?? "")
            }
            .width(min: 120, ideal: 240)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Tick") { model.setChosen(ids, true) }
            Button("Untick") { model.setChosen(ids, false) }
            Divider()
            if let item = model.items.first(where: { ids.first == $0.id }) {
                if let path = item.sourcePath { Button("Show Original in Finder") { model.reveal(path) } }
                if case .atDestination(let path) = item.history { Button("Show Copy in Finder") { model.reveal(path) } }
                if case .copiedBefore(_, let path) = item.history { Button("Show Earlier Copy in Finder") { model.reveal(path) } }
            }
        }
        .overlay {
            if model.items.isEmpty {
                switch model.stage {
                case .scanning(let what):
                    ProgressView(what + "…")
                default:
                    ContentUnavailableView {
                        Label("No Clips Listed", systemImage: "film.stack")
                    } description: {
                        Text(model.problems.first ?? "Tick the sources to copy from and press Scan.")
                    }
                }
            } else if model.visibleItems.isEmpty {
                ContentUnavailableView("No Clips Shown", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Turn on a filter above to see more."))
            }
        }
    }

    private func shortened(_ path: String) -> String {
        guard let destination = model.destination, path.hasPrefix(destination + "/") else { return path }
        return String(path.dropFirst(destination.count + 1))
    }
}

private struct StatusCell: View {
    let item: TransferItem
    let phase: TransferRunner.Phase?

    var body: some View {
        switch phase {
        case .some(.copying(let fraction)):
            progress("Copying", fraction)
        case .some(.checking(let fraction)):
            progress("Checking copy", fraction)
        case .some(.processing(let stage, let fraction)):
            if let fraction { progress(stage, fraction) } else { label(stage, "gearshape", .secondary) }
        case .some(.done(let note)):
            label(note ?? (item.copiesSomething ? "Copied and checked" : "Done"), "checkmark.circle.fill", .green)
        case .some(.failed(let reason)):
            label(reason, "xmark.octagon.fill", .red)
        case .some(.waiting):
            label("Waiting", "clock", .secondary)
        case .none:
            history
        }
    }

    @ViewBuilder private var history: some View {
        switch item.history {
        case .new:
            label("New", "plus.circle", .secondary)
        case .atDestination:
            label("Already at destination", "checkmark.circle", .secondary)
        case .copiedBefore(let date, _):
            label("Copied before" + (date.map { ", " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""),
                  "clock.arrow.circlepath", .orange)
        }
    }

    private func label(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text(text).lineLimit(1).help(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private func progress(_ text: String, _ fraction: Double) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: fraction).frame(width: 60).controlSize(.small)
            Text(text).lineLimit(1)
        }
    }
}

// MARK: Bottom: totals and progress

private struct StatusBar: View {
    @Environment(IngestModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            switch model.stage {
            case .copying:
                copying
            case .finished:
                finished
            default:
                totals
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var totals: some View {
        if model.items.isEmpty {
            Text(model.problems.first ?? "\(model.tickedSources.count) of \(model.sources.count) sources ticked.")
                .foregroundStyle(model.problems.isEmpty ? Color.secondary : Color.red)
        } else {
            Text("\(model.chosen.count) of \(model.items.count) clips ticked · " + size(model.chosenBytes) + " to copy")
            if let estimate = model.estimate {
                Text("· " + TransferEstimate.describe(estimate)).foregroundStyle(.secondary)
                    .help("From the connection speed of each source, with every copy read back once to check it. The time is measured once copying starts.")
            } else if model.chosenBytes > 0 {
                Text("· time shown once copying starts").foregroundStyle(.secondary)
                    .help("The connection speed of a source is not known, so the time is measured once copying starts.")
            }
            Spacer()
            if let blocker = model.copyBlocker {
                Text(blocker).foregroundStyle(model.lacksSpace ? Color.red : Color.secondary)
            } else if let problem = model.problems.first {
                Text(problem).foregroundStyle(.red).lineLimit(1)
            }
        }
        if model.items.isEmpty { Spacer() }
    }

    @ViewBuilder private var copying: some View {
        let progress = model.progress
        ProgressView(value: progress?.fraction ?? 0).frame(width: 180)
        Text(progressText(progress))
            .monospacedDigit()
        Spacer()
        Text(model.isStopping ? "Stopping after the clips being copied." : (progress?.current ?? ""))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder private var finished: some View {
        let progress = model.progress
        let failed = progress?.failed ?? 0
        Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(failed == 0 ? Color.green : Color.orange)
        Text("\(progress?.done ?? 0) done" + (failed > 0 ? ", \(failed) failed. The failed clips are ticked: press Copy to try them again." : ". Every copy was read back and matches its source."))
        Spacer()
    }

    private func progressText(_ progress: TransferRunner.Progress?) -> String {
        guard let progress else { return "Starting…" }
        var parts = ["\(progress.done) of \(progress.phases.count) clips"]
        if let rate = progress.bytesPerSecond { parts.append(size(Int64(rate)) + "/s") }
        if let left = progress.secondsLeft { parts.append(TransferEstimate.describe(left).replacingOccurrences(of: "about ", with: "about ") + " left") }
        return parts.joined(separator: " · ")
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

extension TransferItem {
    var sortDate: Date { date ?? .distantPast }
}
