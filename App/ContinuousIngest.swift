import AppKit
import Foundation
import Observation
import ServiceManagement
import StadaMAMCore
import StadaMAMMedia

/// Drives the Watch Folders tab. Lives for the whole run of the app, so folders are watched and
/// proxies are made with every window closed. All decisions are made by `IngestEngine`.
@MainActor @Observable
final class ContinuousIngestModel {
    /// Master switch for watching and automatic ingest.
    var isOn: Bool {
        didSet { UserDefaults.standard.set(isOn, forKey: "ingestOn"); applyOn() }
    }
    /// Make the proxy in the chosen format (General › Proxy format) for every new clip.
    var makesLocalProxy: Bool {
        didSet { UserDefaults.standard.set(makesLocalProxy, forKey: "ingestLocalProxy") }
    }
    /// Make the remote proxy editors on other computers pull.
    var makesRemoteProxy: Bool {
        didSet { UserDefaults.standard.set(makesRemoteProxy, forKey: "ingestRemoteProxy") }
    }
    /// Seconds a file must stay unchanged before it is taken.
    var stabilitySeconds: Int {
        didSet {
            UserDefaults.standard.set(stabilitySeconds, forKey: "ingestStabilitySeconds")
            let value = Double(stabilitySeconds)
            Task { await engine?.updateSettings { $0.stabilitySeconds = value } }
        }
    }
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    var problem: String?
    private(set) var view: IngestEngine.View?
    private(set) var unavailableReason: String? = "Starting…"

    private var engine: IngestEngine?
    private weak var appModel: AppModel?
    private var activity: NSObjectProtocol?
    @ObservationIgnored private var lastLibraryReload = Date.distantPast
    @ObservationIgnored private var libraryBox = LibraryBox()
    @ObservationIgnored private var libraryTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        isOn = defaults.object(forKey: "ingestOn") as? Bool ?? true
        makesLocalProxy = defaults.object(forKey: "ingestLocalProxy") as? Bool ?? true
        makesRemoteProxy = defaults.object(forKey: "ingestRemoteProxy") as? Bool ?? true
        stabilitySeconds = defaults.object(forKey: "ingestStabilitySeconds") as? Int ?? 30
    }

    /// Called once the app has opened its catalogue. Scans every folder at once, which catches
    /// whatever landed while the app was closed.
    func attach(_ model: AppModel) {
        guard engine == nil else { return }
        guard let library = model.library else {
            unavailableReason = "The library could not be opened, so nothing can be watched."
            return
        }
        appModel = model
        libraryBox.set(library)
        let box = libraryBox
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StadaXR MAM")
        let worker = LibraryIngestWorker(
            libraryProvider: { box.get() }, limiter: model.renderLimiter,
            presets: { Self.wantedPresets() },
            extraIgnoredRoots: { [support.appendingPathComponent("Remote").path] })
        var settings = IngestEngine.Settings()
        settings.stabilitySeconds = Double(stabilitySeconds)
        let store = IngestStore(url: support.appendingPathComponent("Ingest/ingest.json"))
        engine = IngestEngine(
            store: store, worker: worker, settings: settings,
            onChange: { [weak self] view in Task { @MainActor in self?.received(view) } },
            onLibraryChange: { [weak self] in Task { @MainActor in self?.libraryChanged() } })
        unavailableReason = nil
        // The app changes proxy folder and naming while it runs; the worker follows within seconds.
        libraryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let library = self?.appModel?.library { self?.libraryBox.set(library) }
            }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Give the share a moment to finish mounting, and the library a moment to re-find moved originals.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await self?.engine?.volumesChanged()
                }
            }
        }
        Task { if let engine { received(await engine.view()) } }
        applyOn()
    }

    /// Read from preferences whenever a clip starts, so a change applies to the next one.
    nonisolated private static func wantedPresets() -> [ProxyPreset] {
        let defaults = UserDefaults.standard
        var presets: [ProxyPreset] = []
        if defaults.object(forKey: "ingestLocalProxy") as? Bool ?? true {
            presets.append(defaults.string(forKey: "defaultPreset").flatMap(ProxyPreset.init(rawValue:)) ?? .proResProxyHalf)
        }
        if defaults.object(forKey: "ingestRemoteProxy") as? Bool ?? true, !presets.contains(.remoteHEVC) {
            presets.append(.remoteHEVC)
        }
        return presets
    }

    private func applyOn() {
        guard let engine else { return }
        Task {
            if isOn { await engine.start() } else { await engine.stop() }
        }
    }

    private func received(_ new: IngestEngine.View) {
        view = new
        let busy = new.counts.working + new.counts.waiting > 0
        // An unattended Mac mini must not nap with a card offload still to process.
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Making proxies for new footage")
        } else if !busy, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    private func libraryChanged() {
        guard Date().timeIntervalSince(lastLibraryReload) > 2 else { return }
        lastLibraryReload = Date()
        appModel?.reload()
    }

    // MARK: Folders

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Choose folders, drives or mounted network shares. New footage that lands in them is imported and given proxies."
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task { for path in paths { await engine?.addFolder(path: path) } }
    }

    func remove(_ folder: WatchFolder) { Task { await engine?.removeFolder(id: folder.id) } }
    func set(_ folder: WatchFolder, enabled: Bool) { Task { await engine?.setFolder(id: folder.id, enabled: enabled) } }
    func retry(_ item: IngestItem) { Task { await engine?.retry(item.id) } }
    func retryAllFailed() { Task { await engine?.retryAllFailed() } }
    func dismiss(_ item: IngestItem) { Task { await engine?.dismiss(item.id) } }
    func scanNow() { Task { await engine?.scanAll(now: Date()) } }

    func revealInFinder(_ item: IngestItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    // MARK: Launch at login

    func setLaunchesAtLogin(_ on: Bool) {
        problem = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            problem = "Could not change launch at login: \(error.localizedDescription)"
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        if on, SMAppService.mainApp.status == .requiresApproval {
            problem = "Allow StradaXR A.I. MAM under System Settings › General › Login Items."
        }
    }
}

/// The library the worker uses, kept current by the model; a struct cannot be shared by reference.
final class LibraryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var library: MediaLibrary?

    func set(_ new: MediaLibrary) { lock.lock(); library = new; lock.unlock() }
    func get() -> MediaLibrary { lock.lock(); defer { lock.unlock() }; return library! }
}
