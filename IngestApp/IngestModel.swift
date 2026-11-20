import AppKit
import Observation
import StradaMAMCore
import StradaMAMMedia

/// What the ingest window shows and does: where clips come from, where originals live, and one
/// pass that copies what is missing from storage and makes a proxy of every clip.
@MainActor
@Observable
final class IngestModel {
    struct Volume: Identifiable, Hashable {
        var path: String
        var name: String
        /// A card in a reader, or a drive on a cable: what ingest is usually pointed at.
        var isExternal: Bool
        var size: Int64?
        var id: String { path }

        var label: String {
            guard let size, size > 0 else { return name }
            return name + " (" + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) + ")"
        }
    }

    // The choices are remembered between launches.
    var source: String? { didSet { defaults.set(source, forKey: "source"); if source != nil { chosenCameras = [] } } }
    /// iPhones and cameras chosen as the source in place of a folder.
    private(set) var chosenCameras: [PhoneCameras.Camera] = []
    let phones = PhoneCameras()
    /// What is happening while clips are fetched from an iPhone, before the pass starts.
    private(set) var fetching: String?
    var storage: String? { didSet { defaults.set(storage, forKey: "storage") } }
    var libraryFolder: String? { didSet { defaults.set(libraryFolder, forKey: "library") } }
    var preset: ProxyPreset = .proResProxyHalf { didSet { defaults.set(preset.rawValue, forKey: "preset") } }

    private(set) var volumes: [Volume] = []
    private(set) var view: IngestEngine.View?
    private(set) var copied = 0
    private(set) var alreadyOnStorage = 0
    private(set) var isRunning = false
    private(set) var isStopping = false
    private(set) var summary: IngestClient.Summary?
    private(set) var problem: String?

    private let defaults = UserDefaults.standard
    private var session: IngestClient.Session?
    private var passTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []

    init() {
        source = defaults.string(forKey: "source")
        storage = defaults.string(forKey: "storage")
        libraryFolder = defaults.string(forKey: "library")
        if let saved = defaults.string(forKey: "preset"), let preset = ProxyPreset(rawValue: saved) { self.preset = preset }
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            })
        }
        // For screenshots and unattended runs: the folders given in the environment are used and the pass starts.
        let environment = ProcessInfo.processInfo.environment
        if let demoSource = environment["STRADAXR_INGEST_SOURCE"] {
            source = demoSource
            storage = environment["STRADAXR_INGEST_STORAGE"]
            libraryFolder = environment["STRADAXR_INGEST_LIBRARY"]
            start()
        }
    }

    // MARK: Choices

    /// Why the pass cannot start, if it cannot.
    var blocker: String? {
        if !chosenCameras.isEmpty {
            let gone = chosenCameras.filter { !phones.cameras.contains($0) }
            return gone.isEmpty ? nil : "\(gone.map(\.name).joined(separator: ", ")) is not connected."
        }
        guard let source else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isFolder), isFolder.boolValue else {
            return "\(source) is not available. Mount it or choose another source."
        }
        if let storage { return OffloadPlan(sources: [source], destination: storage).problem }
        return nil
    }

    var canStart: Bool { (source != nil || !chosenCameras.isEmpty) && blocker == nil && !isRunning }

    /// The source as the window shows it.
    var sourceLabel: String? {
        chosenCameras.isEmpty ? source : chosenCameras.map(\.name).joined(separator: ", ")
    }

    func choose(cameras: [PhoneCameras.Camera]) {
        source = nil
        chosenCameras = cameras
    }

    /// Where clips fetched from iPhones are kept: the storage folder, or this Mac's Movies folder.
    private var phoneOriginals: String {
        storage ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StradaXR Ingest/Originals").path
    }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                      .volumeIsLocalKey, .volumeTotalCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let local = values?.volumeIsLocal ?? true
            let external = local && ((values?.volumeIsInternal == false) || values?.volumeIsEjectable == true
                                     || values?.volumeIsRemovable == true)
            return Volume(path: url.path, name: values?.volumeName ?? url.lastPathComponent, isExternal: external,
                          size: values?.volumeTotalCapacity.map(Int64.init))
        }
    }

    func chooseSource() {
        if let folder = chooseFolder(prompt: "Choose", message: "Choose the card, drive or folder to ingest. Nothing on it is changed.") {
            source = folder
        }
    }

    func chooseStorage() {
        if let folder = chooseFolder(prompt: "Choose", message: "Choose where originals are kept: a folder on the NAS or on a local drive.") {
            storage = folder
        }
    }

    func chooseLibrary() {
        if let folder = chooseFolder(prompt: "Choose", message: "Choose the library folder to add clips and proxies to.") {
            libraryFolder = folder
        }
    }

    private func chooseFolder(prompt: String, message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    // MARK: The pass

    func start() {
        guard canStart else { return }
        var options = IngestClient.Options()
        options.libraryFolder = libraryFolder
        options.presets = [preset]
        options.once = true
        options.quiet = true
        let cameras = chosenCameras
        let originals = phoneOriginals
        if let source, cameras.isEmpty {
            options.folders = [(source as NSString).standardizingPath]
            options.copyDestination = storage
        }
        isRunning = true
        isStopping = false
        summary = nil
        problem = nil
        view = nil
        copied = 0
        alreadyOnStorage = 0
        // Copying and rendering a card can take hours: the Mac must not sleep part-way.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Copying footage and making proxies")
        passTask = Task { [weak self] in
            guard let self else { return }
            do {
                // iPhones first: their clips are fetched onto storage, each phone in a folder of its own name.
                var fetched = 0, alreadyThere = 0
                for camera in cameras {
                    let folder = originals + "/" + SequencePackageExporter.safeFileName(camera.name)
                    let result = try await self.phones.fetchVideos(from: camera, into: folder) { [weak self] message in
                        self?.fetching = message
                    }
                    fetched += result.fetched
                    alreadyThere += result.alreadyThere
                    options.folders.append(folder)
                }
                self.fetching = nil
                let ready = options
                var summary = try await Task.detached(priority: .userInitiated) {
                    try await IngestClient.runOnce(ready, log: { _ in }, onChange: { view in
                        Task { @MainActor in self.update(view) }
                    }, started: { session in
                        Task { @MainActor in self.session = session }
                    })
                }.value
                if !cameras.isEmpty {
                    summary.copied = fetched
                    summary.alreadyOnStorage = alreadyThere
                }
                self.finish(summary: summary, error: nil)
            } catch {
                self.fetching = nil
                self.finish(summary: nil, error: error is CancellationError ? nil : error)
            }
        }
    }

    /// Clips being worked on are finished; nothing new is started.
    func stop() {
        guard isRunning else { return }
        isStopping = true
        if let session {
            Task { await session.engine.setPaused(true) }
        } else {
            // Still fetching from an iPhone: the clip being fetched is finished and no more are asked for.
            passTask?.cancel()
        }
    }

    private func update(_ view: IngestEngine.View) {
        self.view = view
        // The last update can arrive after the pass has finished and its totals are final.
        guard let tally = session?.tally else { return }
        copied = tally.copied
        alreadyOnStorage = tally.alreadyOnStorage
    }

    private func finish(summary: IngestClient.Summary?, error: Error?) {
        if let summary {
            self.summary = summary
            copied = summary.copied
            alreadyOnStorage = summary.alreadyOnStorage
        }
        if let error { problem = error.localizedDescription }
        isRunning = false
        isStopping = false
        session = nil
        passTask = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
