import AppKit
import Observation
import StadaMAMAI
import StadaMAMCore
import StadaMAMMedia

enum LibraryFilter: Hashable {
    case all
    case needsProxy
    case hasProxy
    case transcribed
    case offline
    case person(String)
    case bin(String)
    case volume(String)
}

struct Activity: Equatable {
    var title: String
    var progress: Double?
}

/// The outcome of asking "where is the source for this proxy / timeline?".
struct RecallReport: Identifiable {
    struct Row: Identifiable {
        let id = UUID()
        var name: String
        var asset: Asset?
        var detail: String
    }

    let id = UUID()
    var title: String
    var rows: [Row]
    /// Present when the input was a timeline that can be saved with source paths.
    var relinkedText: String?
    var suggestedFileName: String = "Relinked.xml"
}

@MainActor
@Observable
final class AppModel {
    let catalog: Catalog
    private(set) var library: MediaLibrary?
    /// Where new proxies are written and how they are named.
    var proxyNaming: ProxyNaming {
        didSet {
            UserDefaults.standard.set(proxyNaming.rawValue, forKey: "proxyNaming")
            library?.naming = proxyNaming
        }
    }
    /// Render a proxy for every clip as soon as it is imported.
    var makesProxiesOnImport: Bool {
        didSet { UserDefaults.standard.set(makesProxiesOnImport, forKey: "makesProxiesOnImport") }
    }
    /// The preset used for automatic and one-click proxies.
    var defaultPreset: ProxyPreset {
        didSet { UserDefaults.standard.set(defaultPreset.rawValue, forKey: "defaultPreset") }
    }
    /// Renders run a few at a time so the media engine is kept busy without being oversubscribed.
    let renderLimiter = JobLimiter(limit: MediaLibrary.recommendedConcurrentRenders)
    /// Analysis is heavy on the neural engine and memory; two clips at a time.
    private let analysisLimiter = JobLimiter(limit: 2)
    @ObservationIgnored private var thumbnailCache: [String: [String]] = [:]
    @ObservationIgnored private var thumbnailMisses: [String: Int] = [:]
    @ObservationIgnored private var lastReload = Date.distantPast
    @ObservationIgnored private var reloadScheduled = false
    @ObservationIgnored private var offlineCheckRunning = false
    @ObservationIgnored private var offlineCheckAgain = false

    var assets: [Asset] = []
    var people: [Person] = []
    var selectedID: String?
    var filter: LibraryFilter = .all {
        didSet { recomputeVisible() }
    }
    var searchText = "" {
        didSet { refreshSearch(); recomputeVisible() }
    }
    /// The clips on screen, worked out once per change rather than on every redraw: a feature's
    /// footage is hundreds of thousands of clips.
    private(set) var visibleAssets: [Asset] = []
    private(set) var visibleGroups: [LibraryGrouping.Group] = []
    /// "Importing 1,204 of 58,000" while a large import runs.
    private(set) var importProgress: (done: Int, total: Int)?
    /// How far a bulk analysis or proxy run has got.
    private(set) var queueProgress: (title: String, done: Int, total: Int)?
    private(set) var searchHits: [SearchHit] = []
    var activity: [String: Activity] = [:]
    var alert: String?
    var recall: RecallReport?
    /// Bumped whenever per-clip data changes, so open views reload.
    private(set) var revision = 0
    /// Set when a search hit or list row asks the player to jump.
    var pendingSeekSeconds: Double?

    private(set) var bins: [Bin] = []
    private(set) var binCounts: [String: Int] = [:]
    private var binAssets: Set<String> = []
    /// Volumes (drives and network shares) that hold catalogued clips, with clip counts.
    private(set) var volumes: [(name: String, count: Int)] = []
    var sort: LibrarySort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "librarySort"); recomputeVisible() }
    }
    var grouping: LibraryGrouping {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: "libraryGrouping"); recomputeVisible() }
    }
    /// Corrections to the picture labels (hidden or reworded), kept in the catalogue.
    private(set) var labelRules: [LabelRule] = []
    /// How sure the picture recogniser must be before a label is kept.
    var labelThreshold: Double {
        didSet { UserDefaults.standard.set(labelThreshold, forKey: "labelThreshold") }
    }
    /// The language spoken on set; empty means this Mac's language.
    var dialogueLanguage: String {
        didSet { UserDefaults.standard.set(dialogueLanguage, forKey: "dialogueLanguage") }
    }
    /// Character, place and crew names the dialogue pass should expect, one per line.
    var dialogueVocabulary: String {
        didSet { UserDefaults.standard.set(dialogueVocabulary, forKey: "dialogueVocabulary") }
    }
    /// Where proxies are written; empty means the default folder. Point it at a large volume.
    var proxyFolder: String {
        didSet {
            UserDefaults.standard.set(proxyFolder, forKey: "proxyFolder")
            library?.proxyFolder = proxyFolder.isEmpty ? nil : proxyFolder
        }
    }
    /// Where an editor on another computer sees this Mac's storage.
    var pathMappings: [PathMapping] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(pathMappings), forKey: "pathMappings") }
    }
    /// External A.I. services that receive each clip's transcript and tags after analysis.
    var analysisHooks: [AnalysisHook] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(analysisHooks), forKey: "analysisHooks") }
    }
    /// Write editor files with the other computer's paths (see `pathMappings`).
    var editorIsOnAnotherComputer: Bool {
        didSet { UserDefaults.standard.set(editorIsOnAnotherComputer, forKey: "editorIsOnAnotherComputer") }
    }

    private(set) var withProxy: Set<String> = []
    private(set) var withTranscript: Set<String> = []
    /// Clips whose original is not currently reachable (moved, renamed, or volume not mounted).
    private(set) var offline: Set<String> = []
    private(set) var personAssets: Set<String> = []

    /// Contact-sheet frames for a clip, looked up when the card is first shown rather than for
    /// every clip on every refresh.
    func thumbnails(for asset: Asset) -> [String] {
        if let cached = thumbnailCache[asset.id] { return cached }
        if thumbnailMisses[asset.id] == revision { return [] }
        let found = library?.thumbnails(forAssetID: asset.id) ?? []
        if found.isEmpty { thumbnailMisses[asset.id] = revision } else { thumbnailCache[asset.id] = found }
        return found
    }

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StadaXR MAM")
        let storage = fm.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("StadaXR MAM")
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? fm.createDirectory(at: storage, withIntermediateDirectories: true)

        let naming = UserDefaults.standard.string(forKey: "proxyNaming").flatMap(ProxyNaming.init(rawValue:)) ?? .sameName
        proxyNaming = naming
        let defaults = UserDefaults.standard
        sort = defaults.string(forKey: "librarySort").flatMap(LibrarySort.init(rawValue:)) ?? .imported
        grouping = defaults.string(forKey: "libraryGrouping").flatMap(LibraryGrouping.init(rawValue:)) ?? .none
        pathMappings = defaults.data(forKey: "pathMappings")
            .flatMap { try? JSONDecoder().decode([PathMapping].self, from: $0) } ?? []
        editorIsOnAnotherComputer = defaults.bool(forKey: "editorIsOnAnotherComputer")
        analysisHooks = defaults.data(forKey: "analysisHooks")
            .flatMap { try? JSONDecoder().decode([AnalysisHook].self, from: $0) } ?? []
        makesProxiesOnImport = UserDefaults.standard.object(forKey: "makesProxiesOnImport") as? Bool ?? true
        defaultPreset = UserDefaults.standard.string(forKey: "defaultPreset").flatMap(ProxyPreset.init(rawValue:))
            ?? .proResProxyHalf
        labelThreshold = defaults.object(forKey: "labelThreshold") as? Double ?? 0.35
        dialogueLanguage = defaults.string(forKey: "dialogueLanguage") ?? ""
        dialogueVocabulary = defaults.string(forKey: "dialogueVocabulary") ?? ""
        proxyFolder = defaults.string(forKey: "proxyFolder") ?? ""
        var startupProblem: String?
        do {
            catalog = try Catalog(path: support.appendingPathComponent("Catalog.sqlite").path)
        } catch {
            // Keep the app usable; nothing will persist until the catalog can be opened.
            catalog = try! Catalog.inMemory()
            startupProblem = "The catalog could not be opened, so this session will not be saved. \(error.localizedDescription)"
        }
        // Apple's frameworks do the work; FFmpeg is used only if it happens to be installed,
        // and only for formats those frameworks cannot open.
        library = MediaLibrary(catalog: catalog, tools: FFmpegTools.locate(), storageRoot: storage.path,
                               naming: naming, pipelines: RenderPipeline.appleSilicon)
        library?.proxyFolder = proxyFolder.isEmpty ? nil : proxyFolder
        alert = startupProblem
        try? catalog.installDefaultLabelRulesIfNeeded()
        // Shares that were remounted under another name are picked up now and whenever a volume appears.
        _ = try? library?.remapRemountedVolumes()
        // Unnamed people with no faces left (from re-runs before grouping was fixed) are cleared.
        _ = try? catalog.deleteEmptyPeople()
        reload()
        // Clips catalogued before fingerprints existed get one now, off the main thread.
        if let library {
            Task.detached(priority: .utility) { _ = try? library.backfillFingerprints() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.volumesChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.volumesChanged() }
        }
        // Demonstration launch: import a folder straight away and open the first clip.
        if let demoMedia = ProcessInfo.processInfo.environment["STADAMAM_DEMO_MEDIA"] {
            opensFirstClip = true
            importMedia(at: [demoMedia])
            // Fit the window to the screen so the whole interface is visible in a screenshot.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let screen = NSScreen.main { NSApp.windows.first?.setFrame(screen.visibleFrame, display: true) }
            }
        }
    }

    private var opensFirstClip = false

    // MARK: Derived state

    var selectedAsset: Asset? { assets.first { $0.id == selectedID } }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var isSearchingNow: Bool { isSearching }

    private func recomputeVisible() {
        let shown = isSearching ? filteredAssets : sort.sorted(filteredAssets)
        visibleAssets = shown
        visibleGroups = (isSearching ? LibraryGrouping.none : grouping).groups(shown)
    }

    var binTree: [BinNode] { BinNode.tree(from: bins) }

    var currentBin: Bin? {
        if case .bin(let id) = filter { return bins.first { $0.id == id } }
        return nil
    }

    private var filteredAssets: [Asset] {
        if isSearching {
            let ranked = searchHits.map(\.assetID)
            let order = Dictionary(ranked.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
            return assets.filter { order[$0.id] != nil }.sorted { order[$0.id]! < order[$1.id]! }
        }
        switch filter {
        case .all: return assets
        case .needsProxy: return assets.filter { !withProxy.contains($0.id) }
        case .hasProxy: return assets.filter { withProxy.contains($0.id) }
        case .transcribed: return assets.filter { withTranscript.contains($0.id) }
        case .offline: return assets.filter { offline.contains($0.id) }
        case .person: return assets.filter { personAssets.contains($0.id) }
        case .bin: return assets.filter { binAssets.contains($0.id) }
        case .volume(let name): return assets.filter { ($0.volumeName ?? "This Mac") == name }
        }
    }

    func bestHit(for assetID: String) -> SearchHit? {
        searchHits.first { $0.assetID == assetID }
    }

    func hasProxy(_ asset: Asset) -> Bool { withProxy.contains(asset.id) }

    func reload() {
        do {
            assets = try catalog.allAssets()
            people = try catalog.people()
            withProxy = try catalog.assetIDsWithReadyProxy()
            withTranscript = try catalog.assetIDsWithTranscript()
            scheduleOfflineCheck()
            if offline.isEmpty, filter == .offline { filter = .all }
            if case .person(let id) = filter { personAssets = try catalog.assetIDs(forPerson: id) }
            bins = try catalog.bins()
            binCounts = try catalog.binCounts()
            if case .bin(let id) = filter {
                if bins.contains(where: { $0.id == id }) {
                    binAssets = try catalog.assetIDs(inBin: id)
                } else {
                    filter = .all
                }
            }
            volumes = Dictionary(grouping: assets, by: { $0.volumeName ?? "This Mac" })
                .map { (name: $0.key, count: $0.value.count) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            labelRules = (try? catalog.labelRules()) ?? []
            refreshSearch()
            if opensFirstClip, selectedID == nil { selectedID = assets.last?.id }
            // Demonstration launch: show what bins look like once there is something to put in them.
            if opensFirstClip, bins.isEmpty, assets.count >= 4 {
                let selects = Bin(name: "Selects"), day = Bin(name: "Day 1", parentID: selects.id)
                try catalog.save(selects)
                try catalog.save(day)
                try catalog.add(assetIDs: Array(assets.prefix(2).map(\.id)), toBin: day.id)
                try catalog.save(Bin(name: "UHD 4K", smartQuery: "UHD 4K", sortIndex: 1))
                bins = try catalog.bins()
                binCounts = try catalog.binCounts()
            }
            revision += 1
            recomputeVisible()
            lastReload = Date()
        } catch {
            alert = error.localizedDescription
        }
    }

    /// Reloads at most about once every two seconds, for long runs that finish thousands of clips.
    private func reloadSoon() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        let wait = max(0, 2 - Date().timeIntervalSince(lastReload))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            reloadScheduled = false
            reload()
        }
    }

    /// Works out which originals are unreachable, off the main thread. A volume that is not
    /// mounted takes one look, not one look per clip; a mounted one is checked clip by clip
    /// in the background so a slow network share never freezes the interface.
    private func scheduleOfflineCheck() {
        if offlineCheckRunning { offlineCheckAgain = true; return }
        offlineCheckRunning = true
        let snapshot = assets.map { ($0.id, $0.sourcePath, $0.volumeName) }
        Task.detached(priority: .utility) {
            let mounted = Set((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [])
            var missing = Set<String>()
            for (id, path, volume) in snapshot {
                if let volume, !mounted.contains(volume) { missing.insert(id); continue }
                if !FileManager.default.fileExists(atPath: path) { missing.insert(id) }
            }
            await self.finishOfflineCheck(missing)
        }
    }

    private func finishOfflineCheck(_ missing: Set<String>) {
        offlineCheckRunning = false
        if offline != missing { offline = missing }
        if offline.isEmpty, filter == .offline { filter = .all }
        if offlineCheckAgain {
            offlineCheckAgain = false
            scheduleOfflineCheck()
        }
    }

    func select(filter newFilter: LibraryFilter) {
        filter = newFilter
        reload()
    }

    // MARK: Picture labels

    private func tagsChanged() {
        revision += 1
        refreshSearch()
        recomputeVisible()
    }

    /// Renames one tag on one clip. The change is kept through re-analysis.
    func rename(_ tag: SceneTag, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tag.label else { return }
        var edited = tag
        edited.label = trimmed
        do { try catalog.saveEdited(edited); tagsChanged() } catch { alert = error.localizedDescription }
    }

    func delete(_ tag: SceneTag) {
        do { try catalog.deleteTag(tag); tagsChanged() } catch { alert = error.localizedDescription }
    }

    /// Adds a tag of your own at a moment in a clip, e.g. "NG", "best take", "lens flare".
    func addTag(_ label: String, to asset: Asset, atSeconds seconds: Double) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tag = SceneTag(assetID: asset.id, kind: .label, label: trimmed, confidence: 1,
                           startSeconds: seconds, endSeconds: min(seconds + 2, max(asset.durationSeconds, seconds + 2)),
                           userEdited: true)
        do { try catalog.saveEdited(tag); tagsChanged() } catch { alert = error.localizedDescription }
    }

    /// Never produce this label again, and remove it from every clip already analysed.
    func hideEverywhere(_ label: String) {
        addRule(LabelRule(match: label, action: .hide))
    }

    /// Always use this wording, and reword it in every clip already analysed.
    func renameEverywhere(_ label: String, to replacement: String) {
        addRule(LabelRule(match: label, action: .rename, replacement: replacement))
    }

    func addRule(_ rule: LabelRule) {
        guard !rule.match.isEmpty, rule.action == .hide || !rule.replacement.isEmpty else { return }
        var rule = rule
        if let existing = labelRules.first(where: { $0.match == rule.match }) { rule.id = existing.id }
        do {
            try catalog.save(rule)
            let changed = try catalog.apply(rule)
            labelRules = try catalog.labelRules()
            tagsChanged()
            if changed > 0 { alert = nil }
        } catch { alert = error.localizedDescription }
    }

    func deleteRule(_ rule: LabelRule) {
        do { try catalog.deleteRule(rule); labelRules = try catalog.labelRules() } catch { alert = error.localizedDescription }
    }

    /// The labels the picture analysis has produced so far, most common first.
    func labelCounts() -> [(label: String, count: Int)] {
        (try? catalog.labelCounts()) ?? []
    }

    private func refreshSearch() {
        searchHits = (try? catalog.search(searchText)) ?? []
    }

    private func volumesChanged() {
        _ = try? library?.remapRemountedVolumes()
        reload()
    }

    // MARK: Bins

    /// Creates a bin (inside `parent` when given) and returns it so it can be named.
    @discardableResult
    func newBin(named name: String = "New Bin", inside parent: Bin? = nil, smartQuery: String? = nil) -> Bin {
        let bin = Bin(name: name, parentID: parent?.id, smartQuery: smartQuery, sortIndex: bins.count)
        perform { try catalog.save(bin) }
        return bin
    }

    func rename(_ bin: Bin, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var updated = bin
        updated.name = trimmed
        perform { try catalog.save(updated) }
    }

    func delete(_ bin: Bin) {
        perform { try catalog.deleteBin(id: bin.id) }
    }

    func add(_ asset: Asset, to bin: Bin) {
        perform { try catalog.add(assetIDs: [asset.id], toBin: bin.id) }
    }

    /// Adds dragged clips (identified by their source files) to a bin.
    func add(paths: [String], to bin: Bin) {
        let ids = assets.filter { paths.contains($0.sourcePath) }.map(\.id)
        guard !ids.isEmpty, !bin.isSmart else { return }
        perform { try catalog.add(assetIDs: ids, toBin: bin.id) }
    }

    func remove(_ asset: Asset, from bin: Bin) {
        perform { try catalog.remove(assetIDs: [asset.id], fromBin: bin.id) }
    }

    /// Saves the current search as a smart bin that keeps itself up to date.
    func saveSearchAsSmartBin() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let bin = newBin(named: query, smartQuery: query)
        searchText = ""
        select(filter: .bin(bin.id))
    }

    // MARK: Import

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose clips or folders to catalogue. Files stay where they are."
        guard panel.runModal() == .OK else { return }
        importMedia(at: panel.urls.map(\.path))
    }

    func importMedia(at paths: [String]) {
        guard let library else {
            alert = MediaError.ffmpegNotFound.localizedDescription
            return
        }
        Task.detached(priority: .userInitiated) {
            // Clips already catalogued at the same size are skipped, so an interrupted import of a
            // huge folder simply carries on where it stopped.
            let known = (try? library.catalog.knownFileSizes()) ?? [:]
            let found = paths.flatMap { MediaLibrary.mediaFiles(at: $0) }
            let files = found.filter { file in
                guard let size = known[file] else { return true }
                let onDisk = ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? NSNumber)?.int64Value
                return onDisk != size
            }
            guard !files.isEmpty else {
                await self.show(found.isEmpty ? "No media files were found there."
                                              : "All \(found.count) clips are already in the catalogue.")
                return
            }
            await self.setImportProgress((0, files.count))
            let failures = FailureLog()
            let counter = ImportCounter()
            // A few clips at a time: probing and fingerprinting mostly wait on storage.
            await withTaskGroup(of: Void.self) { group in
                var iterator = files.makeIterator()
                func next() -> String? { iterator.next() }
                for _ in 0..<4 {
                    guard let first = next() else { break }
                    group.addTask { await self.importOne(first, library: library, failures: failures) }
                }
                while await group.next() != nil {
                    let done = await counter.increment()
                    await self.setImportProgress((done, files.count))
                    await self.reloadSoon()
                    if let file = next() {
                        group.addTask { await self.importOne(file, library: library, failures: failures) }
                    }
                }
            }
            await self.setImportProgress(nil)
            await self.reload()
            let problems = await failures.all
            if !problems.isEmpty {
                let shown = problems.prefix(8).joined(separator: "\n")
                await self.show("\(problems.count) file\(problems.count == 1 ? "" : "s") could not be imported:\n\(shown)")
            }
        }
    }

    private func importOne(_ file: String, library: MediaLibrary, failures: FailureLog) async {
        do {
            let asset = try await library.importFile(at: file)
            _ = try? await library.makeThumbnails(for: asset)
            await makeProxyAfterImport(asset)
        } catch MediaError.isOwnProxy {
            return
        } catch {
            await failures.add("\((file as NSString).lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func setImportProgress(_ value: (done: Int, total: Int)?) { importProgress = value }

    private func makeProxyAfterImport(_ asset: Asset) {
        guard makesProxiesOnImport, asset.decodePath.canRender, !withProxy.contains(asset.id) else { return }
        makeProxy(for: asset, preset: defaultPreset)
    }

    private func setQueueProgress(_ value: (title: String, done: Int, total: Int)?) { queueProgress = value }

    // MARK: Missing originals

    /// Asks for a folder or volume and re-finds originals that were moved or renamed.
    func presentLocateMissingPanel() {
        guard let library else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Search"
        panel.message = "Choose the folder or volume to search for missing originals. They are matched by content, so renamed files are found too."
        guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
        let missing = offline.count
        Task.detached(priority: .userInitiated) {
            do {
                let found = try library.locateMissingSources(under: folder)
                await self.reload()
                await self.show("Found \(found.count) of \(missing) missing original\(missing == 1 ? "" : "s").")
            } catch {
                await self.show(error.localizedDescription)
            }
        }
    }

    private func setActivity(_ assetID: String, _ value: Activity?) {
        activity[assetID] = value
    }

    private func show(_ message: String) {
        alert = message
    }

    // MARK: Proxies

    func makeProxy(for asset: Asset, preset: ProxyPreset) {
        guard let library else {
            alert = MediaError.ffmpegNotFound.localizedDescription
            return
        }
        guard activity[asset.id] == nil else { return }
        activity[asset.id] = Activity(title: "Queued for proxy")
        let limiter = renderLimiter
        Task.detached(priority: .userInitiated) {
            await limiter.acquire()
            await self.setActivity(asset.id, Activity(title: "Rendering proxy", progress: 0))
            do {
                try await library.makeProxy(for: asset, preset: preset) { fraction in
                    Task { @MainActor in
                        self.activity[asset.id] = Activity(title: "Rendering proxy", progress: fraction)
                    }
                }
                if library.thumbnails(forAssetID: asset.id).isEmpty { _ = try? await library.makeThumbnails(for: asset) }
            } catch {
                await self.show("\(asset.fileName): \(error.localizedDescription)")
            }
            await limiter.release()
            await self.setActivity(asset.id, nil)
            await self.reload()
        }
    }

    /// Renders a proxy for every clip that can be rendered and does not have one yet. Clips are
    /// handed out a few at a time, so 100,000 clips do not become 100,000 waiting jobs.
    func makeMissingProxies(preset: ProxyPreset) {
        let missing = (try? catalog.assetIDsWithoutReadyProxy()) ?? []
        let targets = assets.filter { missing.contains($0.id) && $0.decodePath.canRender }
        guard !targets.isEmpty else { return }
        let limiter = renderLimiter
        Task.detached(priority: .userInitiated) {
            await self.setQueueProgress(("Making proxies", 0, targets.count))
            var finished = 0
            await withTaskGroup(of: Void.self) { group in
                for asset in targets {
                    await limiter.acquire()
                    guard await self.beginRendering(asset), let library = await self.library else {
                        await limiter.release()
                        continue
                    }
                    group.addTask {
                        do {
                            try await library.makeProxy(for: asset, preset: preset) { fraction in
                                Task { @MainActor in
                                    self.activity[asset.id] = Activity(title: "Rendering proxy", progress: fraction)
                                }
                            }
                            if library.thumbnails(forAssetID: asset.id).isEmpty {
                                _ = try? await library.makeThumbnails(for: asset)
                            }
                        } catch {
                            await self.show("\(asset.fileName): \(error.localizedDescription)")
                        }
                        await limiter.release()
                        await self.setActivity(asset.id, nil)
                        await self.reloadSoon()
                    }
                    finished += 1
                    await self.setQueueProgress(("Making proxies", finished, targets.count))
                }
            }
            await self.setQueueProgress(nil)
            await self.reload()
        }
    }

    private func beginRendering(_ asset: Asset) -> Bool {
        guard library != nil, activity[asset.id] == nil else { return false }
        activity[asset.id] = Activity(title: "Rendering proxy", progress: 0)
        return true
    }

    func revealInFinder(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            alert = "\((path as NSString).lastPathComponent) is offline. Reconnect its volume and try again."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Send to editor

    /// Writes the clips currently shown — with their markers and subclips — as a file the
    /// chosen editing app imports, then reveals it in Finder.
    func sendToEditor(_ target: EditorTarget, media: EditorMedia) {
        let clips = visibleAssets.map { asset in
            // Only proxies that were verified against their source are handed to an editor.
            let proxy = ((try? catalog.proxies(forAsset: asset.id)) ?? [])
                .first { $0.status == .ready && $0.mismatch == nil && FileManager.default.fileExists(atPath: $0.path) }
            return EditorClip(asset: asset, proxyPath: proxy?.path,
                              markers: (try? catalog.markers(forAsset: asset.id)) ?? [])
        }
        let sendable = media == .proxies ? clips.filter { $0.proxyPath != nil } : clips
        guard !sendable.isEmpty else {
            alert = media == .proxies
                ? "None of the clips shown has a verified proxy yet. Make proxies first."
                : "There are no clips to send."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "StradaXR clips for \(target.displayName).\(target.fileExtension)"
        panel.message = "Import this file into \(target.displayName)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try EditorExport.document(for: clips, target: target, media: media,
                                      collectionName: currentBin?.name ?? "StradaXR A.I. MAM",
                                      pathMappings: editorIsOnAnotherComputer ? pathMappings : [])
                .write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            let skipped = clips.count - sendable.count
            if skipped > 0 {
                alert = "\(skipped) clip\(skipped == 1 ? " was" : "s were") left out because \(skipped == 1 ? "it has" : "they have") no verified proxy yet."
            }
        } catch {
            alert = error.localizedDescription
        }
    }

    // MARK: Source recall

    func presentRecallPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Find Source"
        panel.message = "Choose proxy files, or a timeline exported from Premiere Pro (XML) or DaVinci Resolve (FCPXML, XML, EDL)."
        guard panel.runModal() == .OK else { return }
        recallSources(for: panel.urls)
    }

    func recallSources(for urls: [URL]) {
        guard let library else { return }
        let timelineExtensions: Set<String> = ["xml", "fcpxml", "edl"]
        Task {
            do {
                if let timeline = urls.first(where: { timelineExtensions.contains($0.pathExtension.lowercased()) }) {
                    let text = try String(contentsOf: timeline, encoding: .utf8)
                    guard let relink = try library.relinkTimeline(text: text, pathMappings: pathMappings) else {
                        alert = "\(timeline.lastPathComponent) is not a timeline StradaXR A.I. MAM can read."
                        return
                    }
                    let rows = relink.resolutions.map { reference, resolution in
                        RecallReport.Row(name: reference.name ?? reference.path ?? reference.reelName ?? "Clip",
                                         asset: resolution.asset, detail: Self.describe(resolution))
                    }
                    let base = timeline.deletingPathExtension().lastPathComponent
                    recall = RecallReport(
                        title: "\(timeline.lastPathComponent) — \(rows.count - relink.unresolvedCount) of \(rows.count) clips matched",
                        rows: rows,
                        relinkedText: relink.document.format == .edl ? nil : relink.relinkedText,
                        suggestedFileName: "\(base) (sources).\(timeline.pathExtension)")
                } else {
                    var rows: [RecallReport.Row] = []
                    for url in urls {
                        let resolution = try await library.source(forFileAt: url.path)
                        rows.append(RecallReport.Row(name: url.lastPathComponent, asset: resolution.asset,
                                                     detail: Self.describe(resolution)))
                    }
                    recall = RecallReport(title: "Sources for \(rows.count) file\(rows.count == 1 ? "" : "s")", rows: rows)
                    if let only = rows.first?.asset, rows.count == 1 { selectedID = only.id }
                }
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    private static func describe(_ resolution: SourceResolution) -> String {
        switch resolution {
        case .found(let asset, let evidence):
            let how: String
            switch evidence {
            case .embeddedID: how = "embedded ID"
            case .proxyPath, .proxyFileName: how = "known proxy"
            case .sourcePath: how = "already the source"
            case .fileName: how = "file name"
            case .reelName: how = "reel name"
            }
            return "\(asset.sourcePath)  ·  matched by \(how)"
        case .ambiguous(let candidates):
            return "\(candidates.count) possible sources: " + candidates.map(\.sourcePath).joined(separator: ", ")
        case .notFound:
            return "No source in the catalog"
        }
    }

    func saveRelinkedTimeline(_ report: RecallReport) {
        guard let text = report.relinkedText else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = report.suggestedFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alert = error.localizedDescription
        }
    }

    // MARK: Markers and notes

    func addMarker(to asset: Asset, inFrame: Int, outFrame: Int?) {
        let count = ((try? catalog.markers(forAsset: asset.id)) ?? []).filter { $0.isSubclip == (outFrame != nil) }.count
        let name = outFrame == nil ? "Marker \(count + 1)" : "Subclip \(count + 1)"
        perform { try catalog.save(Marker(assetID: asset.id, inFrame: inFrame, outFrame: outFrame, name: name)) }
    }

    func update(_ marker: Marker) {
        perform { try catalog.save(marker) }
    }

    func delete(_ marker: Marker) {
        perform { try catalog.deleteMarker(marker) }
    }

    func update(_ asset: Asset) {
        perform { try catalog.save(asset) }
    }

    func rename(_ person: Person, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        perform { try catalog.rename(person: person, to: trimmed) }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            reload()
        } catch {
            alert = error.localizedDescription
        }
    }

    // MARK: AI

    /// Runs every analysis pass on a clip: picture (shots, framing and shot size, scenes, objects,
    /// animals, on-screen text, faces), sound, dialogue, slates and names in the dialogue, and then
    /// any external A.I. hooks. Each pass is independent, so one failing does not lose the rest.
    /// Clips wait their turn, two at a time.
    func analyze(_ asset: Asset) {
        guard library?.playablePath(for: asset) != nil else {
            alert = "\(asset.fileName) has no playable media yet. Generate a proxy first."
            return
        }
        guard activity[asset.id] == nil else { return }
        activity[asset.id] = Activity(title: "Waiting to analyse")
        let limiter = analysisLimiter
        Task {
            await limiter.acquire()
            await runAnalysis(asset)
            await limiter.release()
        }
    }

    private func runAnalysis(_ asset: Asset) async {
        guard let path = library?.playablePath(for: asset) else { activity[asset.id] = nil; return }
        let url = URL(fileURLWithPath: path)
        activity[asset.id] = Activity(title: "Analysing picture", progress: 0)
        var problems: [String] = []
        let rules = labelRules
        let threshold = labelThreshold
        do {
            let visual = try await VisionAnalyzer.analyze(mediaURL: url, asset: asset, labelThreshold: threshold,
                                                          rules: rules) { fraction in
                Task { @MainActor in
                    self.activity[asset.id] = Activity(title: "Analysing picture", progress: fraction)
                }
            }
            try catalog.replaceTags(assetID: asset.id, kinds: [.shot, .label, .text], with: visual.tags)
            try catalog.replaceAndGroupFaces(assetID: asset.id, with: visual.faces)
        } catch {
            problems.append("Picture: \(error.localizedDescription)")
        }

        if asset.audioChannels > 0 {
            activity[asset.id] = Activity(title: "Listening for sounds")
            do {
                let sounds = try await SoundAnalyzer.classify(mediaURL: url, assetID: asset.id)
                try catalog.replaceTags(assetID: asset.id, kinds: [.sound], with: sounds)
            } catch AnalysisError.noAudio {
            } catch {
                problems.append("Sound: \(error.localizedDescription)")
            }

            activity[asset.id] = Activity(title: "Transcribing dialogue", progress: 0)
            do {
                let names = people.compactMap(\.name)
                let extra = dialogueVocabulary.split(whereSeparator: { $0 == "\n" || $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } + names
                let locale = dialogueLanguage.isEmpty ? Locale.current : Locale(identifier: dialogueLanguage)
                let result = try await Transcriber.transcribe(mediaURL: url, assetID: asset.id, locale: locale,
                                                              extraVocabulary: extra) { fraction in
                    Task { @MainActor in
                        self.activity[asset.id] = Activity(title: "Transcribing dialogue", progress: fraction)
                    }
                }
                try catalog.replaceTranscript(assetID: asset.id, with: result.segments)
                try catalog.replaceTags(assetID: asset.id, kinds: [.entity],
                                        with: TextAnalyzer.entities(in: result.segments, assetID: asset.id))
                let onScreen = try catalog.tags(forAsset: asset.id).filter { $0.kind == .text }
                try catalog.replaceTags(assetID: asset.id, kinds: [.slate],
                                        with: SlateParser.tags(assetID: asset.id, transcript: result.segments,
                                                               onScreenText: onScreen))
                if let warning = result.warning { problems.append("Dialogue: \(warning)") }
            } catch AnalysisError.noAudio {
                // Silent clips simply have no dialogue.
            } catch {
                problems.append("Dialogue: \(error.localizedDescription)")
            }
        }

        for hook in analysisHooks where hook.isEnabled && !hook.url.isEmpty {
            activity[asset.id] = Activity(title: "Asking \(hook.name.isEmpty ? "external A.I." : hook.name)")
            do {
                let body = ExternalAnalysisRequest(
                    asset: asset, transcript: try catalog.transcript(forAsset: asset.id),
                    tags: try catalog.tags(forAsset: asset.id))
                let reply = try await ExternalAnalysisClient.send(hook: hook, token: Keychain.token(for: hook.id),
                                                                 body: body)
                try catalog.replaceTags(assetID: asset.id, kinds: [.external, .summary],
                                        with: reply.sceneTags(for: asset))
            } catch {
                problems.append("\(hook.name.isEmpty ? "External A.I." : hook.name): \(error.localizedDescription)")
            }
        }

        activity[asset.id] = nil
        reloadSoon()
        if !problems.isEmpty {
            alert = "\(asset.fileName) was analysed with some parts missing:\n" + problems.joined(separator: "\n")
        }
    }

    /// Analyses every clip on screen that has playable media, two at a time.
    func analyzeVisible() {
        let targets = visibleAssets.filter { library?.playablePath(for: $0) != nil && activity[$0.id] == nil }
        guard !targets.isEmpty else { return }
        for asset in targets { activity[asset.id] = Activity(title: "Waiting to analyse") }
        let limiter = analysisLimiter
        Task {
            queueProgress = ("Analysing", 0, targets.count)
            var finished = 0
            await withTaskGroup(of: Void.self) { group in
                for asset in targets {
                    await limiter.acquire()
                    group.addTask {
                        await self.runAnalysis(asset)
                        await limiter.release()
                    }
                    finished += 1
                    queueProgress = ("Analysing", finished, targets.count)
                }
            }
            queueProgress = nil
        }
    }

    /// One-off clean-up of unnamed people with no sightings (left behind by earlier re-runs).
    func removeEmptyPeople() {
        perform { try catalog.deleteEmptyPeople() }
    }

    func exportCaptions(for asset: Asset, webVTT: Bool) {
        guard let segments = try? catalog.transcript(forAsset: asset.id), !segments.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (asset.fileName as NSString).deletingPathExtension + (webVTT ? ".vtt" : ".srt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = webVTT ? CaptionBuilder.webVTT(segments) : CaptionBuilder.srt(segments)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alert = error.localizedDescription
        }
    }
}

/// Collects import failures from concurrent tasks.
actor FailureLog {
    private(set) var all: [String] = []
    func add(_ message: String) { all.append(message) }
}

actor ImportCounter {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
