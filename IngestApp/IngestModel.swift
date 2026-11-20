import AppKit
import Observation
import StradaMAMCore
import StradaMAMMedia

/// What the ingest window shows and does: the sources on the left, the destination on the right,
/// the clips found between them, and the copy.
@MainActor
@Observable
final class IngestModel {
    enum Stage: Equatable {
        case idle
        case scanning(String)
        case listed
        case copying
        case finished
    }

    /// Which clips the list shows, by what is known about them.
    struct Filter: Equatable {
        var new = true
        var copiedBefore = true
        var atDestination = true
    }

    // MARK: Choices, remembered between launches

    var destination: String? {
        didSet { defaults.set(destination, forKey: "destination"); if destination != oldValue { listIsStale = true } }
    }
    var libraryFolder: String? { didSet { defaults.set(libraryFolder, forKey: "library") } }
    var makesProxies = true { didSet { defaults.set(makesProxies, forKey: "makesProxies") } }
    var preset: ProxyPreset = .proResProxyHalf { didSet { defaults.set(preset.rawValue, forKey: "preset") } }
    /// Folders added by hand: a share, a folder on a drive.
    private(set) var folders: [String] = [] { didSet { defaults.set(folders, forKey: "folders") } }
    /// Sources the user unticked. Everything else that is connected is scanned.
    private var unticked: Set<String> = [] { didSet { defaults.set(Array(unticked), forKey: "unticked") } }

    // MARK: What was found

    private(set) var volumes: [TransferSource] = []
    private(set) var items: [TransferItem] = []
    /// Clips ticked to copy.
    var chosen: Set<String> = []
    var filter = Filter()
    private(set) var stage: Stage = .idle
    /// True when a source or the destination changed since the list was made.
    private(set) var listIsStale = false
    private(set) var problems: [String] = []
    private(set) var progress: TransferRunner.Progress?
    private(set) var isStopping = false
    /// Whether the last copy made proxies, so finished clips say what was done to them.
    private(set) var lastRunMadeProxies = false

    let phones = PhoneCameras()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var runner: TransferRunner?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var phoneLinks: [String: LinkSpeed?] = [:]

    init() {
        destination = defaults.string(forKey: "destination")
        libraryFolder = defaults.string(forKey: "library")
        if defaults.object(forKey: "makesProxies") != nil { makesProxies = defaults.bool(forKey: "makesProxies") }
        if let saved = defaults.string(forKey: "preset"), let preset = ProxyPreset(rawValue: saved) { self.preset = preset }
        folders = defaults.stringArray(forKey: "folders") ?? []
        unticked = Set(defaults.stringArray(forKey: "unticked") ?? [])
        listIsStale = false
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            })
        }
        // For screenshots and unattended runs: a folder, a destination and a library from the
        // environment; the list is made at once, and the copy starts after the given seconds.
        let environment = ProcessInfo.processInfo.environment
        if let folder = environment["STRADAXR_INGEST_SOURCE"] {
            folders = [folder]
            unticked = []
            destination = environment["STRADAXR_INGEST_STORAGE"]
            libraryFolder = environment["STRADAXR_INGEST_LIBRARY"]
            Task {
                await scan()
                if let delay = environment["STRADAXR_INGEST_START_AFTER"].flatMap(Double.init) {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    copy()
                }
            }
        }
    }

    // MARK: Sources

    /// Everything that can be copied from: cards and drives, iPhones, and folders added by hand.
    var sources: [TransferSource] {
        let phoneSources = phones.cameras.map { camera in
            TransferSource(id: "camera:" + camera.id, name: camera.name, kind: .device,
                           link: phoneLink(camera), isExternal: true)
        }
        let folderSources = folders.map { TransferSource.folder($0, link: LinkSpeedProbe.forVolume(at: $0)) }
        return volumes + phoneSources + folderSources
    }

    func isTicked(_ source: TransferSource) -> Bool { !unticked.contains(source.id) }

    func setTicked(_ source: TransferSource, _ ticked: Bool) {
        if ticked { unticked.remove(source.id) } else { unticked.insert(source.id) }
        listIsStale = true
    }

    var tickedSources: [TransferSource] { sources.filter(isTicked) }

    /// Ticked sources connected below 10 Gbps.
    var slowSources: [TransferSource] { tickedSources.filter { $0.link?.isBelowRecommended == true } }

    func isRemovable(_ source: TransferSource) -> Bool { source.path.map(folders.contains) ?? false }

    func remove(_ source: TransferSource) {
        guard let path = source.path else { return }
        folders.removeAll { $0 == path }
        listIsStale = true
    }

    private func phoneLink(_ camera: PhoneCameras.Camera) -> LinkSpeed? {
        if let known = phoneLinks[camera.id] { return known }
        let link = LinkSpeedProbe.forUSBLocation(camera.locationID)
        phoneLinks[camera.id] = link
        return link
    }

    /// Cards in a reader and drives on a cable, with how each is connected.
    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                      .volumeIsLocalKey, .volumeTotalCapacityKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsRootFileSystem != true,
                  values.volumeIsLocal != false else { return nil }
            let external = values.volumeIsInternal == false || values.volumeIsEjectable == true || values.volumeIsRemovable == true
            guard external else { return nil }
            return TransferSource.folder(url.path, name: values.volumeName ?? url.lastPathComponent,
                                         link: LinkSpeedProbe.forVolume(at: url.path), isExternal: true,
                                         capacity: values.volumeTotalCapacity.map(Int64.init))
        }
        phoneLinks = [:]
    }

    func addFolder() {
        guard let folder = chooseFolder(message: "Choose a folder to copy clips from: a card's folder, a drive or a network share.") else { return }
        if !folders.contains(folder) { folders.append(folder) }
        unticked.remove(TransferSource.folder(folder).id)
        listIsStale = true
    }

    func chooseDestination() {
        if let folder = chooseFolder(message: "Choose where clips are copied to, on the NAS or a local drive. Each source gets a folder of its own name inside it.") {
            destination = folder
        }
    }

    func chooseLibrary() {
        if let folder = chooseFolder(message: "Choose the library folder to add clips and proxies to.") { libraryFolder = folder }
    }

    private func chooseFolder(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    // MARK: The list

    var visibleItems: [TransferItem] {
        items.filter { item in
            switch item.history {
            case .new: return filter.new
            case .copiedBefore: return filter.copiedBefore
            case .atDestination: return filter.atDestination
            }
        }
    }

    func count(_ kind: KeyPath<Filter, Bool>) -> Int {
        items.filter { item in
            switch item.history {
            case .new: return kind == \Filter.new
            case .copiedBefore: return kind == \Filter.copiedBefore
            case .atDestination: return kind == \Filter.atDestination
            }
        }.count
    }

    var chosenItems: [TransferItem] { items.filter { chosen.contains($0.id) } }
    var chosenBytes: Int64 { chosenItems.filter(\.copiesSomething).reduce(0) { $0 + $1.size } }

    func chooseAllVisible() { chosen.formUnion(visibleItems.map(\.id)) }
    func chooseNone() { chosen.subtract(visibleItems.map(\.id)) }
    func chooseNew() { chosen = Set(items.filter(\.history.isNew).map(\.id)) }

    func setChosen(_ ids: Set<String>, _ value: Bool) {
        if value { chosen.formUnion(ids) } else { chosen.subtract(ids) }
    }

    /// Seconds the chosen clips take to copy and check, from the speed of each source's link.
    var estimate: TimeInterval? {
        TransferEstimate.seconds(for: chosenItems.filter(\.copiesSomething), sources: sources)
    }

    var freeSpace: Int64? {
        guard let destination else { return nil }
        return ((try? FileManager.default.attributesOfFileSystem(forPath: destination))?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    var lacksSpace: Bool { (freeSpace.map { chosenBytes > $0 }) ?? false }

    var isBusy: Bool {
        switch stage {
        case .scanning, .copying: return true
        default: return false
        }
    }

    var canScan: Bool { !isBusy && !tickedSources.isEmpty }

    /// Why Copy cannot be pressed, if it cannot.
    var copyBlocker: String? {
        if chosen.isEmpty { return items.isEmpty ? nil : "Tick the clips to copy." }
        if destination == nil {
            if chosenItems.contains(where: { $0.sourcePath == nil }) { return "Choose a destination: clips on an iPhone have to be copied somewhere." }
            if !makesProxies { return "Choose a destination, or turn on proxies to make them where the clips are." }
        }
        if lacksSpace { return "The destination does not have room for the chosen clips." }
        if listIsStale { return "Sources or the destination changed. Scan again first." }
        return nil
    }

    var canCopy: Bool { !isBusy && !chosen.isEmpty && copyBlocker == nil }

    // MARK: Scanning

    private func openLibrary() throws -> (library: MediaLibrary, worker: LibraryIngestWorker, history: CopyHistory) {
        var options = IngestClient.Options()
        options.libraryFolder = libraryFolder
        options.presets = makesProxies ? [preset] : []
        return try IngestClient.openLibrary(options)
    }

    func scan() async {
        guard canScan else { return }
        stage = .scanning("Looking at the sources")
        problems = []
        progress = nil
        let opened: (library: MediaLibrary, worker: LibraryIngestWorker, history: CopyHistory)
        do {
            opened = try openLibrary()
        } catch {
            problems = ["The library could not be opened: \(error.localizedDescription)"]
            stage = items.isEmpty ? .idle : .listed
            return
        }
        let destination = self.destination
        let storage: StorageIndex? = destination.map { folder in StorageIndex(folder: folder) }
        var found: [TransferItem] = []
        for source in tickedSources {
            stage = .scanning("Looking at \(source.name)")
            switch source.kind {
            case .folder:
                let catalog = opened.library.catalog, history = opened.history
                found += await Task.detached(priority: .userInitiated) {
                    TransferPlanner.scan(source, destination: destination, history: history, catalog: catalog, storage: storage)
                }.value
            case .device:
                let cameraID = String(source.id.dropFirst("camera:".count))
                do {
                    let clips = try await phones.clips(on: cameraID)
                    found += TransferPlanner.deviceItems(source, files: clips.map { (name: $0.name, size: $0.size, date: $0.date) },
                                                         destination: destination, history: opened.history)
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
        }
        items = found
        chosen = Set(found.filter(\.history.isNew).map(\.id))
        listIsStale = false
        stage = .listed
    }

    // MARK: Copying

    func copy() {
        guard canCopy else { return }
        let opened: (library: MediaLibrary, worker: LibraryIngestWorker, history: CopyHistory)
        do {
            opened = try openLibrary()
        } catch {
            problems = ["The library could not be opened: \(error.localizedDescription)"]
            return
        }
        let clips = items.filter { chosen.contains($0.id) }
        lastRunMadeProxies = makesProxies
        stage = .copying
        isStopping = false
        problems = []
        // Copying and rendering a card can take hours: the Mac must not sleep part-way.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Copying footage and making proxies")
        let phones = self.phones
        let runner = TransferRunner(items: clips, history: opened.history, worker: opened.worker, fetch: { item, path, progress in
            guard case .device(let name) = item.origin else { return }
            try await phones.fetch(cameraID: String(item.sourceID.dropFirst("camera:".count)), clip: name, to: path, progress: progress)
        }, onProgress: { [weak self] progress in
            Task { @MainActor in self?.progress = progress }
        })
        self.runner = runner
        Task {
            let result = await runner.run()
            self.progress = result
            self.runner = nil
            self.stage = .finished
            self.isStopping = false
            if let activity = self.activity { ProcessInfo.processInfo.endActivity(activity) }
            self.activity = nil
            // What failed stays ticked, so Copy runs just those again.
            self.chosen = Set(result.phases.compactMap { id, phase in
                if case .failed = phase { return id } else { return nil }
            })
            _ = NSApp.requestUserAttention(.informationalRequest)
        }
    }

    /// Clips being copied are finished; nothing more is started.
    func stop() {
        guard let runner else { return }
        isStopping = true
        Task { await runner.cancel() }
    }

    func phase(of item: TransferItem) -> TransferRunner.Phase? { progress?.phases[item.id] }
}
