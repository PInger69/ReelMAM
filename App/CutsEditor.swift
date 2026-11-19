import AppKit
import CoreMedia
import Observation
import StadaMAMCore
import StadaMAMMedia
import UniformTypeIdentifiers

/// The cuts editor: the list of sequences, the one that is open, and the viewing look. Sequences
/// live in the catalogue; this is the app's view of them.
@MainActor
@Observable
final class CutsModel {
    private(set) var sequences: [CutSequence] = []
    private(set) var cutCounts: [String: Int] = [:]
    /// The sequence that marked ranges are added to, laid out and ready to play.
    private(set) var open: ResolvedSequence?
    /// True while the detail area shows the sequence rather than a clip.
    var showsEditor = false
    var selectedCutID: String?
    /// Bumped whenever the open sequence, or how it should look, changes.
    private(set) var revision = 0
    /// Show log footage through its Rec.709 look. Off shows every clip as it is in the file.
    var looksEnabled: Bool {
        didSet {
            UserDefaults.standard.set(looksEnabled, forKey: "viewingLooksEnabled")
            revision += 1
        }
    }
    /// Show timecode and the frame-by-frame controls. Off by default: the plain view needs none of it.
    var fineTune: Bool {
        didSet { UserDefaults.standard.set(fineTune, forKey: "cutsFineTune") }
    }
    /// What can be undone in the open sequence.
    private(set) var history = SequenceHistory()
    /// How far a package export has got, while one runs.
    private(set) var packageProgress: PackageProgress?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var tables: [ViewingLook: ColorLUT] = [:]
    @ObservationIgnored private var packageTask: Task<Void, Never>?
    @ObservationIgnored private var checkedColour: Set<String> = []

    init() {
        looksEnabled = UserDefaults.standard.object(forKey: "viewingLooksEnabled") as? Bool ?? true
        fineTune = UserDefaults.standard.bool(forKey: "cutsFineTune")
    }

    /// Called once the app has opened its catalogue.
    func attach(_ model: AppModel) {
        guard app == nil else { return }
        app = model
        reload()
        if let last = UserDefaults.standard.string(forKey: "openSequence"), sequences.contains(where: { $0.id == last }) {
            open(id: last, showEditor: false)
        }
    }

    private var catalog: Catalog? { app?.catalog }

    /// Reads the sequences again. Clips can be removed from the catalogue behind the editor's back.
    func reload() {
        guard let catalog else { return }
        do {
            sequences = try catalog.sequences()
            cutCounts = try catalog.cutCounts()
            if let id = open?.sequence.id {
                open = try catalog.resolvedSequence(id: id)
                if open == nil { showsEditor = false }
                if let selected = selectedCutID, open?.cuts.contains(where: { $0.id == selected }) != true { selectedCutID = nil }
            }
            revision += 1
        } catch {
            app?.alert = error.localizedDescription
        }
    }

    private func perform(_ work: (Catalog) throws -> Void) {
        guard let catalog else { return }
        do {
            try work(catalog)
        } catch {
            app?.alert = error.localizedDescription
        }
        reload()
    }

    /// Makes a change to the open sequence's cuts that can be undone. `name` says what it was.
    private func change(_ name: String, _ work: (Catalog) throws -> Void) {
        guard let catalog, let id = open?.sequence.id else { return }
        do {
            let before = try catalog.snapshot(ofSequence: id)
            try work(catalog)
            history.record(name, before: before, after: try catalog.snapshot(ofSequence: id))
        } catch {
            app?.alert = error.localizedDescription
        }
        reload()
    }

    func undo() {
        guard let catalog, let id = open?.sequence.id else { return }
        do {
            if let state = history.undo(current: try catalog.snapshot(ofSequence: id)) { try catalog.restore(state) }
        } catch {
            app?.alert = error.localizedDescription
        }
        reload()
    }

    func redo() {
        guard let catalog, let id = open?.sequence.id else { return }
        do {
            if let state = history.redo(current: try catalog.snapshot(ofSequence: id)) { try catalog.restore(state) }
        } catch {
            app?.alert = error.localizedDescription
        }
        reload()
    }

    // MARK: Sequences

    func open(id: String, showEditor: Bool = true) {
        guard let catalog else { return }
        if id != open?.sequence.id { history = SequenceHistory() }
        open = try? catalog.resolvedSequence(id: id)
        selectedCutID = nil
        showsEditor = showEditor && open != nil
        UserDefaults.standard.set(open?.sequence.id, forKey: "openSequence")
        revision += 1
    }

    @discardableResult
    func newSequence() -> CutSequence? {
        guard let catalog else { return nil }
        let taken = Set(sequences.map(\.name))
        var number = sequences.count + 1
        while taken.contains("Sequence \(number)") { number += 1 }
        do {
            let sequence = try catalog.createSequence(named: "Sequence \(number)")
            reload()
            open(id: sequence.id)
            return sequence
        } catch {
            app?.alert = error.localizedDescription
            return nil
        }
    }

    func rename(_ sequence: CutSequence, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        perform { try $0.renameSequence(id: sequence.id, to: trimmed) }
    }

    func duplicate(_ sequence: CutSequence) {
        guard let catalog else { return }
        do {
            let copy = try catalog.duplicateSequence(id: sequence.id)
            reload()
            open(id: copy.id)
        } catch {
            app?.alert = error.localizedDescription
        }
    }

    func delete(_ sequence: CutSequence) {
        if open?.sequence.id == sequence.id {
            open = nil
            showsEditor = false
            UserDefaults.standard.removeObject(forKey: "openSequence")
        }
        perform { try $0.deleteSequence(id: sequence.id) }
    }

    func setFrameRate(_ rate: FrameRate, dropFrame: Bool) {
        guard let id = open?.sequence.id else { return }
        perform { try $0.setSequenceFrameRate(id: id, to: rate, dropFrame: dropFrame) }
    }

    // MARK: Cuts

    /// Adds a range of a clip to the open sequence, after the selected cut or at the end. With no
    /// sequence open, a new one is started.
    func add(_ asset: Asset, inFrame: Int?, outFrame: Int?) {
        if open == nil, newSequence() == nil { return }
        guard let open else { return }
        showsEditor = false
        let index = selectedCutID.flatMap { id in open.cuts.firstIndex { $0.id == id } }.map { $0 + 1 }
        var added: String?
        change("Add") {
            added = try $0.insertCut(inSequence: open.sequence.id, assetID: asset.id, inFrame: inFrame ?? 0,
                                     outFrame: outFrame ?? max(asset.durationFrames - 1, 0), at: index).id
        }
        if let added { selectedCutID = added }
    }

    /// Adds a stretch of a clip to the open sequence: at the end, or before the cut at `index`.
    /// This is what holding Keep and choosing words do. Returns the new cut's length in seconds.
    @discardableResult
    func keep(_ asset: Asset, frames: ClosedRange<Int>, at index: Int? = nil) -> Double? {
        guard let id = open?.sequence.id else { return nil }
        var added: SequenceCut?
        change("Add") {
            added = try $0.insertCut(inSequence: id, assetID: asset.id, inFrame: frames.lowerBound,
                                     outFrame: frames.upperBound, at: index)
        }
        guard let added else { return nil }
        selectedCutID = added.id
        return asset.frameRate.seconds(forFrames: added.durationFrames)
    }

    /// Sets both ends of a cut at once, as one step to undo. Used when a card's edge is let go.
    func setRange(_ cutID: String, to frames: ClosedRange<Int>, name: String) {
        change(name) { _ = try $0.trimCut(id: cutID, inFrame: frames.lowerBound, outFrame: frames.upperBound) }
    }

    func move(_ cutID: String, to index: Int) {
        change("Move") { try $0.moveCut(id: cutID, to: index) }
    }

    func move(_ cutID: String, by offset: Int) {
        guard let index = open?.cuts.firstIndex(where: { $0.id == cutID }) else { return }
        move(cutID, to: index + offset)
    }

    func trim(_ cutID: String, inFrame: Int? = nil, outFrame: Int? = nil) {
        change("Trim") { _ = try $0.trimCut(id: cutID, inFrame: inFrame, outFrame: outFrame) }
    }

    func remove(_ cutID: String) {
        if selectedCutID == cutID { selectedCutID = nil }
        change("Remove") { try $0.removeCut(id: cutID) }
    }

    // MARK: Viewing look

    /// The look a clip is shown through when looks are on.
    func look(for asset: Asset) -> ViewingLook {
        (try? catalog?.viewingLook(for: asset)) ?? .none
    }

    /// The choice made by hand for a clip, or nil while it follows the clip's metadata.
    func chosenLook(for asset: Asset) -> ViewingLook? {
        (try? catalog?.clipLook(forAsset: asset.id))?.look
    }

    func setLook(_ look: ViewingLook?, for asset: Asset) {
        perform { try $0.setClipLook(look, forAsset: asset.id) }
    }

    /// Asks for a `.cube` file and uses it for a clip.
    func chooseLUT(for asset: Asset) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube")].compactMap { $0 }
        panel.prompt = "Use LUT"
        panel.message = "Choose a 3D .cube LUT to view \(asset.fileName) through. The clip itself is not changed."
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        do {
            tables[.lut(path: path)] = try ColorLUT(cubeFileAtPath: path)
            setLook(.lut(path: path), for: asset)
        } catch {
            app?.alert = error.localizedDescription
        }
    }

    var lutsInUse: [String] { (try? catalog?.lutPathsInUse()) ?? [] }

    /// The table for a clip's look, or nil when it is shown as it is. A LUT file that has gone
    /// missing is reported once and the clip is shown without it.
    func table(for asset: Asset) -> ColorLUT? {
        guard looksEnabled else { return nil }
        let look = look(for: asset)
        if let cached = tables[look] { return cached }
        do {
            let table = try ViewingLookRenderer.table(for: look)
            tables[look] = table
            return table
        } catch {
            tables[look] = ColorLUT.identity()
            app?.alert = "\(look.displayName): \(error.localizedDescription)"
            return nil
        }
    }

    /// Identifies a clip's look for the player, so it reloads only when the look changes.
    func lookKey(for asset: Asset) -> String {
        looksEnabled ? "\(asset.id) \(look(for: asset))" : "\(asset.id) off"
    }

    /// Clips catalogued before colour tags were read get theirs read now, from the original, so
    /// the look can be chosen from them. Does nothing while the original is offline.
    func readColourTagsIfNeeded(_ asset: Asset) {
        guard asset.colorSpace == nil, asset.decodePath == .avFoundation, !checkedColour.contains(asset.id),
              FileManager.default.fileExists(atPath: asset.sourcePath) else { return }
        checkedColour.insert(asset.id)
        Task {
            var updated = asset
            updated.colorSpace = await ViewingLookRenderer.colorDescription(path: asset.sourcePath) ?? "untagged"
            _ = try? catalog?.save(updated)
            app?.reload()
        }
    }

    // MARK: Export

    private func options() -> TimelineExportOptions {
        guard let app, app.editorIsOnAnotherComputer else { return TimelineExportOptions() }
        return TimelineExportOptions(pathMappings: app.pathMappings)
    }

    /// Writes the open sequence as a timeline file that links to the camera originals.
    func exportTimeline(_ format: SequenceTimelineFormat) {
        guard let open, !open.cuts.isEmpty else {
            app?.alert = "The sequence has no cuts to export."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SequencePackageExporter.safeFileName(open.sequence.name) + "." + format.fileExtension
        panel.message = "A timeline of \(open.sequence.name), linked to the camera originals."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try EditorExport.timeline(open, format: format, options: options()).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            app?.alert = error.localizedDescription
        }
    }

    /// Copies the originals the open sequence uses, with its timelines and a manifest, to a folder
    /// on this Mac or a disk attached to it.
    func exportPackage() {
        guard let open, !open.cuts.isEmpty, packageTask == nil else {
            if packageTask == nil { app?.alert = "The sequence has no cuts to package." }
            return
        }
        let plan = SequencePackagePlan(sequence: open)
        guard plan.missing.isEmpty else {
            app?.alert = PackageError.missingOriginals(plan.missing.map(\.sourcePath)).localizedDescription
            return
        }
        let size = ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Package"
        panel.message = "Choose where to put the package: \(plan.items.count) camera original\(plan.items.count == 1 ? "" : "s") copied whole (\(size)), the timelines and a manifest."
        guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
        packageProgress = PackageProgress(fileName: "", bytesDone: 0, bytesTotal: max(plan.totalBytes * 2, 1))
        packageTask = Task.detached(priority: .userInitiated) {
            let outcome = Result { try SequencePackageExporter.export(open, into: folder) { progress in
                Task { @MainActor in self.showProgress(progress) }
            } }
            await self.finishPackage(outcome)
        }
    }

    func cancelPackage() {
        packageTask?.cancel()
    }

    private func showProgress(_ progress: PackageProgress) {
        if packageTask != nil { packageProgress = progress }
    }

    private func finishPackage(_ outcome: Result<PackageResult, Error>) {
        packageTask = nil
        packageProgress = nil
        switch outcome {
        case .success(let result):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.folder + "/manifest.json")])
            let count = result.manifest.files.count
            app?.alert = "Package exported. \(count) file\(count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: result.manifest.totalBytes, countStyle: .file)), each copy read back and matched to its original."
        case .failure(let error):
            app?.alert = error is CancellationError ? "The package export was stopped. The unfinished folder can be deleted."
                                                    : error.localizedDescription
        }
    }
}
