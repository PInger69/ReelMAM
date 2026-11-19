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
    private let renderLimiter = JobLimiter(limit: MediaLibrary.recommendedConcurrentRenders)

    var assets: [Asset] = []
    var people: [Person] = []
    var selectedID: String?
    var filter: LibraryFilter = .all
    var searchText = "" {
        didSet { refreshSearch() }
    }
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
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "librarySort") }
    }
    var grouping: LibraryGrouping {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: "libraryGrouping") }
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
    private(set) var thumbnailPaths: [String: [String]] = [:]

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
        alert = startupProblem
        // Shares that were remounted under another name are picked up now and whenever a volume appears.
        _ = try? library?.remapRemountedVolumes()
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

    /// The clips on screen: search results in relevance order, otherwise the current
    /// selection in the chosen sort order.
    var visibleAssets: [Asset] {
        isSearching ? filteredAssets : sort.sorted(filteredAssets)
    }

    var visibleGroups: [LibraryGrouping.Group] {
        (isSearching ? LibraryGrouping.none : grouping).groups(visibleAssets)
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
            offline = Set(assets.filter { !FileManager.default.fileExists(atPath: $0.sourcePath) }.map(\.id))
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
            if let library {
                thumbnailPaths = Dictionary(uniqueKeysWithValues: assets.map {
                    ($0.id, library.thumbnails(forAssetID: $0.id))
                })
            }
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
        } catch {
            alert = error.localizedDescription
        }
    }

    func select(filter newFilter: LibraryFilter) {
        filter = newFilter
        reload()
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
            var failures: [String] = []
            for file in paths.flatMap({ MediaLibrary.mediaFiles(at: $0) }) {
                do {
                    let asset = try await library.importFile(at: file)
                    await self.setActivity(asset.id, Activity(title: "Thumbnails"))
                    _ = try? await library.makeThumbnails(for: asset)
                    await self.setActivity(asset.id, nil)
                    await self.makeProxyAfterImport(asset)
                } catch MediaError.isOwnProxy {
                    continue
                } catch {
                    failures.append("\((file as NSString).lastPathComponent): \(error.localizedDescription)")
                }
                await self.reload()
            }
            if !failures.isEmpty {
                let shown = failures.prefix(8).joined(separator: "\n")
                await self.show("Some files could not be imported:\n\(shown)")
            }
        }
    }

    private func makeProxyAfterImport(_ asset: Asset) {
        guard makesProxiesOnImport, asset.decodePath.canRender, !withProxy.contains(asset.id) else { return }
        makeProxy(for: asset, preset: defaultPreset)
    }

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

    /// Queues a proxy for every clip that can be rendered and does not have one yet.
    func makeMissingProxies(preset: ProxyPreset) {
        let missing = (try? catalog.assetIDsWithoutReadyProxy()) ?? []
        for asset in assets where missing.contains(asset.id) && asset.decodePath.canRender {
            makeProxy(for: asset, preset: preset)
        }
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
        panel.nameFieldStringValue = "StadaXR clips for \(target.displayName).\(target.fileExtension)"
        panel.message = "Import this file into \(target.displayName)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try EditorExport.document(for: clips, target: target, media: media,
                                      collectionName: currentBin?.name ?? "StadaXR A.I. MAM",
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
                        alert = "\(timeline.lastPathComponent) is not a timeline StadaXR A.I. MAM can read."
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

    /// Runs every analysis pass on a clip: picture (shots, scenes, objects, animals, people
    /// in frame, on-screen text, faces), sound, speech-to-text, names in the speech, and then
    /// any external A.I. hooks. Each pass is independent, so one failing does not lose the rest.
    func analyze(_ asset: Asset) {
        guard let path = library?.playablePath(for: asset) else {
            alert = "\(asset.fileName) has no playable media yet. Generate a proxy first."
            return
        }
        guard activity[asset.id] == nil else { return }
        let url = URL(fileURLWithPath: path)
        activity[asset.id] = Activity(title: "Analysing picture", progress: 0)
        Task {
            var problems: [String] = []
            do {
                let visual = try await VisionAnalyzer.analyze(mediaURL: url, asset: asset) { fraction in
                    Task { @MainActor in
                        self.activity[asset.id] = Activity(title: "Analysing picture", progress: fraction)
                    }
                }
                try catalog.replaceTags(assetID: asset.id, kinds: [.shot, .label, .text], with: visual.tags)
                try catalog.replaceFaces(assetID: asset.id, with: visual.faces)
                try groupFaces()
                reload()
            } catch {
                problems.append("Picture: \(error.localizedDescription)")
            }

            if asset.audioChannels > 0 {
                activity[asset.id] = Activity(title: "Listening for sounds")
                do {
                    let sounds = try await SoundAnalyzer.classify(mediaURL: url, assetID: asset.id)
                    try catalog.replaceTags(assetID: asset.id, kinds: [.sound], with: sounds)
                } catch {
                    problems.append("Sound: \(error.localizedDescription)")
                }

                activity[asset.id] = Activity(title: "Transcribing speech")
                do {
                    let segments = try await Transcriber.transcribe(mediaURL: url, assetID: asset.id)
                    try catalog.replaceTranscript(assetID: asset.id, with: segments)
                    try catalog.replaceTags(assetID: asset.id, kinds: [.entity],
                                            with: TextAnalyzer.entities(in: segments, assetID: asset.id))
                } catch AnalysisError.noAudio {
                    // Silent clips simply have no transcript.
                } catch {
                    problems.append("Speech: \(error.localizedDescription)")
                }
                reload()
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
            reload()
            if !problems.isEmpty {
                alert = "\(asset.fileName) was analysed with some parts missing:\n" + problems.joined(separator: "\n")
            }
        }
    }

    /// Analyses every clip on screen that has playable media.
    func analyzeVisible() {
        for asset in visibleAssets where library?.playablePath(for: asset) != nil { analyze(asset) }
    }

    /// Groups every unassigned face in the catalog into people, joining existing people where they match.
    private func groupFaces() throws {
        let known = Dictionary(uniqueKeysWithValues: try catalog.people().map { ($0.id, $0) })
        for (personID, sightingIDs) in FaceClusterer.cluster(try catalog.allFaces()) {
            try catalog.assign(sightingIDs: sightingIDs, to: known[personID] ?? Person(id: personID))
        }
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
