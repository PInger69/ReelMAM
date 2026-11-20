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
        var id: String { path }
    }

    // The choices are remembered between launches.
    var source: String? { didSet { defaults.set(source, forKey: "source") } }
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
        guard let source else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isFolder), isFolder.boolValue else {
            return "\(source) is not available. Mount it or choose another source."
        }
        if let storage { return OffloadPlan(sources: [source], destination: storage).problem }
        return nil
    }

    var canStart: Bool { source != nil && blocker == nil && !isRunning }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.map { url in
            Volume(path: url.path, name: (try? url.resourceValues(forKeys: Set(keys)))?.volumeName ?? url.lastPathComponent)
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
        guard let source, canStart else { return }
        var options = IngestClient.Options()
        options.folders = [(source as NSString).standardizingPath]
        options.copyDestination = storage
        options.libraryFolder = libraryFolder
        options.presets = [preset]
        options.once = true
        options.quiet = true
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
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let summary = try await IngestClient.runOnce(options, log: { _ in }, onChange: { view in
                    Task { @MainActor in self?.update(view) }
                }, started: { session in
                    Task { @MainActor in self?.session = session }
                })
                await self?.finish(summary: summary, error: nil)
            } catch {
                await self?.finish(summary: nil, error: error)
            }
        }
    }

    /// Clips being worked on are finished; nothing new is started.
    func stop() {
        guard isRunning, let session else { return }
        isStopping = true
        Task { await session.engine.setPaused(true) }
    }

    private func update(_ view: IngestEngine.View) {
        self.view = view
        copied = session?.tally?.copied ?? 0
        alreadyOnStorage = session?.tally?.alreadyOnStorage ?? 0
    }

    private func finish(summary: IngestClient.Summary?, error: Error?) {
        if let summary {
            self.summary = summary
            copied = summary.copied
            alreadyOnStorage = summary.alreadyOnStorage
        }
        if let error { problem = error.localizedDescription }
        isRunning = false
        session = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
