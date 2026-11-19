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
    case person(String)
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

    private(set) var withProxy: Set<String> = []
    private(set) var withTranscript: Set<String> = []
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
        reload()
        // Demonstration launch: import a folder straight away and open the first clip.
        if let demoMedia = ProcessInfo.processInfo.environment["STADAMAM_DEMO_MEDIA"] {
            opensFirstClip = true
            importMedia(at: [demoMedia])
        }
    }

    private var opensFirstClip = false

    // MARK: Derived state

    var selectedAsset: Asset? { assets.first { $0.id == selectedID } }

    var visibleAssets: [Asset] {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let ranked = searchHits.map(\.assetID)
            let order = Dictionary(ranked.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
            return assets.filter { order[$0.id] != nil }.sorted { order[$0.id]! < order[$1.id]! }
        }
        switch filter {
        case .all: return assets
        case .needsProxy: return assets.filter { !withProxy.contains($0.id) }
        case .hasProxy: return assets.filter { withProxy.contains($0.id) }
        case .transcribed: return assets.filter { withTranscript.contains($0.id) }
        case .person: return assets.filter { personAssets.contains($0.id) }
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
            if case .person(let id) = filter { personAssets = try catalog.assetIDs(forPerson: id) }
            if let library {
                thumbnailPaths = Dictionary(uniqueKeysWithValues: assets.map {
                    ($0.id, library.thumbnails(forAssetID: $0.id))
                })
            }
            refreshSearch()
            if opensFirstClip, selectedID == nil { selectedID = assets.last?.id }
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
            try EditorExport.document(for: clips, target: target, media: media)
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
                    guard let relink = try library.relinkTimeline(text: text) else {
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

    /// Runs the picture pass (shots, labels, on-screen text, faces) and then speech-to-text.
    func analyze(_ asset: Asset) {
        guard let path = library?.playablePath(for: asset) else {
            alert = "\(asset.fileName) has no playable media yet. Generate a proxy first."
            return
        }
        let url = URL(fileURLWithPath: path)
        activity[asset.id] = Activity(title: "Analysing picture", progress: 0)
        Task {
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

                activity[asset.id] = Activity(title: "Transcribing speech")
                do {
                    let segments = try await Transcriber.transcribe(mediaURL: url, assetID: asset.id)
                    try catalog.replaceTranscript(assetID: asset.id, with: segments)
                } catch AnalysisError.noAudio {
                    // Silent clips simply have no transcript.
                }
            } catch {
                alert = "\(asset.fileName): \(error.localizedDescription)"
            }
            activity[asset.id] = nil
            reload()
        }
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
