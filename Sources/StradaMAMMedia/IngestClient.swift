import Foundation
import StradaMAMCore

/// The ingest client: a headless program that watches folders, catalogues what arrives and
/// renders proxies, writing into a library the MAM app reads.
///
/// It is the same ingest engine the app runs, without a window: files are taken only once they
/// have stopped changing, every proxy is checked against its source, and work resumes where it
/// stopped after a restart.
public enum IngestClient {
    public struct Options: Equatable, Sendable {
        /// Folders to ingest from: camera cards, drives, network shares.
        public var folders: [String] = []
        /// Folder holding `Catalog.sqlite`, `Proxies` and `Thumbnails`. Nil means the MAM app's
        /// own library on this Mac.
        public var libraryFolder: String?
        /// Copy each clip here first, verify the copy, and ingest the copy instead of the card.
        public var copyDestination: String?
        public var presets: [ProxyPreset] = [.proResProxyHalf]
        public var naming: ProxyNaming = .sameName
        /// Ingest what is there now, then exit, instead of watching.
        public var once = false
        /// Seconds a file must be unchanged before it is taken. Nil means the default: 30 when
        /// watching, none for a single pass.
        public var stabilitySeconds: Double?
        /// Seconds between looks at each folder while watching. Folders on this Mac's own disks
        /// are also noticed the moment they change; network shares rely on these looks.
        public var scanInterval: Double = 15
        /// Clips worked on at once. Nil means a number suited to this machine.
        public var parallel: Int?
        public var quiet = false

        public init() {}
    }

    public enum Parsed: Equatable, Sendable {
        case run(Options)
        case help
        case failure(String)
    }

    public static let presetNames: [(name: String, preset: ProxyPreset)] = [
        ("prores-half", .proResProxyHalf), ("prores-1080", .proResProxy1080),
        ("h264-1080", .h264_1080), ("h264-720", .h264_720), ("remote-hevc", .remoteHEVC),
    ]

    public static let usage = """
        stradaxr-ingest — watch folders, catalogue clips and render proxies for StradaXR A.I. MAM

        USAGE
          stradaxr-ingest [options] <folder> [<folder> ...]

        OPTIONS
          --library <folder>   Library to write into (Catalog.sqlite, Proxies, Thumbnails).
                               Default: the MAM app's own library on this Mac.
          --copy-to <folder>   Offload first: copy each clip here, check the copy against the
                               card, and catalogue the copy, so the card can be wiped.
          --preset <name>      Proxy to render; repeat for several. One of:
                               prores-half (default), prores-1080, h264-1080, h264-720, remote-hevc
          --no-proxies         Catalogue only.
          --naming <style>     same (default), suffix (adds _Proxy), beside (a Proxy folder
                               next to each original).
          --once               Ingest what is there now, then exit.
          --stability <secs>   How long a file must be unchanged before it is taken.
                               Default 30 when watching; none with --once.
          --scan-interval <s>  How often each folder is looked at while watching. Default 15.
          --parallel <n>       Clips to work on at once.
          --quiet              Print problems and the final summary only.
          --help               Show this.

        EXIT STATUS
          0 everything ingested, 1 some clips failed, 2 the command line was not understood.
        """

    public static func parse(_ arguments: [String]) -> Parsed {
        var options = Options()
        var presets: [ProxyPreset] = []
        var noProxies = false
        var index = 0
        func value(for flag: String) -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                return .help
            case "--once":
                options.once = true
            case "--quiet":
                options.quiet = true
            case "--no-proxies":
                noProxies = true
            case "--library":
                guard let folder = value(for: argument) else { return .failure("--library needs a folder.") }
                options.libraryFolder = (folder as NSString).standardizingPath
            case "--copy-to":
                guard let folder = value(for: argument) else { return .failure("--copy-to needs a folder.") }
                options.copyDestination = (folder as NSString).standardizingPath
            case "--preset":
                guard let name = value(for: argument),
                      let preset = presetNames.first(where: { $0.name == name })?.preset else {
                    return .failure("--preset needs one of: " + presetNames.map(\.name).joined(separator: ", ") + ".")
                }
                if !presets.contains(preset) { presets.append(preset) }
            case "--naming":
                switch value(for: argument) {
                case "same": options.naming = .sameName
                case "suffix": options.naming = .premiereSuffix
                case "beside": options.naming = .besideSource
                default: return .failure("--naming needs one of: same, suffix, beside.")
                }
            case "--stability":
                guard let seconds = value(for: argument).flatMap(Double.init), seconds >= 0 else {
                    return .failure("--stability needs a number of seconds.")
                }
                options.stabilitySeconds = seconds
            case "--scan-interval":
                guard let seconds = value(for: argument).flatMap(Double.init), seconds >= 1 else {
                    return .failure("--scan-interval needs a number of seconds, 1 or more.")
                }
                options.scanInterval = seconds
            case "--parallel":
                guard let count = value(for: argument).flatMap(Int.init), count >= 1 else {
                    return .failure("--parallel needs a whole number, 1 or more.")
                }
                options.parallel = count
            default:
                if argument.hasPrefix("-") { return .failure("Unknown option \(argument).") }
                let folder = (argument as NSString).standardizingPath
                if !options.folders.contains(folder) { options.folders.append(folder) }
            }
            index += 1
        }
        if noProxies, !presets.isEmpty { return .failure("--no-proxies cannot be combined with --preset.") }
        options.presets = noProxies ? [] : (presets.isEmpty ? [.proResProxyHalf] : presets)
        guard !options.folders.isEmpty else { return .failure("Give at least one folder to ingest from.") }
        if let destination = options.copyDestination,
           let problem = OffloadPlan(sources: options.folders, destination: destination).problem {
            return .failure(problem)
        }
        return .run(options)
    }

    // MARK: Library locations

    public struct Locations: Equatable, Sendable {
        public var catalogPath: String
        public var storageRoot: String
        /// Where the client keeps its own queue, so it resumes after a restart.
        public var statePath: String
    }

    /// Where the catalog, the proxies and the client's own state live for these options.
    /// With `--library` everything is inside that one folder, so it can sit on shared storage.
    public static func locations(for options: Options) -> Locations? {
        if let folder = options.libraryFolder {
            return Locations(catalogPath: folder + "/Catalog.sqlite", storageRoot: folder,
                             statePath: folder + "/IngestClient.json")
        }
        #if os(macOS)
        // The same places the MAM app uses, so the two share one library on a single Mac.
        let fm = FileManager.default
        let support = AppNames.libraryFolder(in: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        let storage = AppNames.libraryFolder(in: fm.urls(for: .moviesDirectory, in: .userDomainMask)[0])
        return Locations(catalogPath: support.appendingPathComponent("Catalog.sqlite").path,
                         storageRoot: storage.path,
                         statePath: support.appendingPathComponent("Ingest/client.json").path)
        #else
        return nil
        #endif
    }

    // MARK: Running

    public struct Summary: Equatable, Sendable {
        public var ingested = 0
        public var skipped = 0
        /// Of the clips ingested, how many were copied to storage by this run.
        public var copied = 0
        /// Of the clips ingested, how many were already on storage and only needed a proxy.
        public var alreadyOnStorage = 0
        public var failures: [Failure] = []

        public struct Failure: Equatable, Sendable {
            public var path: String
            public var reason: String
        }

        public var exitStatus: Int32 { failures.isEmpty ? 0 : 1 }
    }

    public enum ClientError: Error, LocalizedError, Equatable {
        case noLibrary
        case missingFolder(String)

        public var errorDescription: String? {
            switch self {
            case .noLibrary: return "Say where the library is with --library <folder>."
            case .missingFolder(let path): return "\(path) is not a folder."
            }
        }
    }

    /// A running client: the engine plus what is needed to report on it and stop it cleanly.
    public struct Session: Sendable {
        public let engine: IngestEngine
        public let library: MediaLibrary
        /// When this run began. Clips finished by an earlier run are not counted again.
        public let startedAt: Date
        /// Set when clips are copied to storage first.
        public let tally: OffloadTally?

        public func summary() async -> Summary {
            var summary = Summary()
            summary.copied = tally?.copied ?? 0
            summary.alreadyOnStorage = tally?.alreadyOnStorage ?? 0
            for item in await engine.queue.items {
                let thisRun = (item.finishedAt ?? .distantFuture) >= startedAt
                switch item.state {
                case .done: if thisRun { summary.ingested += 1 }
                case .skipped: if thisRun { summary.skipped += 1 }
                case .failed:
                    summary.failures.append(.init(path: item.path, reason: item.reason ?? "Unknown problem"))
                case .waiting, .working: break
                }
            }
            return summary
        }
    }

    /// The library these options point at, a worker that imports into it and renders proxies,
    /// and the history of what has been copied into it.
    public static func openLibrary(_ options: Options, tools: FFmpegTools? = FFmpegTools.locate())
        throws -> (library: MediaLibrary, worker: LibraryIngestWorker, history: CopyHistory) {
        guard let places = locations(for: options) else { throw ClientError.noLibrary }
        let fm = FileManager.default
        let folder = (places.catalogPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: places.storageRoot, withIntermediateDirectories: true)
        let catalog = try Catalog(path: places.catalogPath)
        let library = MediaLibrary(catalog: catalog, tools: tools, storageRoot: places.storageRoot,
                                   naming: options.naming, pipelines: RenderPipeline.appleSilicon)
        let presets = options.presets
        let worker = LibraryIngestWorker(library: library,
                                         limiter: JobLimiter(limit: options.parallel ?? MediaLibrary.recommendedConcurrentRenders),
                                         presets: { presets })
        let history = CopyHistory(url: URL(fileURLWithPath: folder + "/Copy History.json"))
        return (library, worker, history)
    }

    /// Opens the library and prepares the engine. Nothing is scanned until it is started.
    public static func makeSession(_ options: Options, tools: FFmpegTools? = FFmpegTools.locate(),
                                   log: @escaping @Sendable (String) -> Void,
                                   onChange: (@Sendable (IngestEngine.View) -> Void)? = nil) throws -> Session {
        guard let places = locations(for: options) else { throw ClientError.noLibrary }
        let fm = FileManager.default
        try fm.createDirectory(atPath: (places.catalogPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try fm.createDirectory(atPath: places.storageRoot, withIntermediateDirectories: true)
        let catalog = try Catalog(path: places.catalogPath)
        let library = MediaLibrary(catalog: catalog, tools: tools, storageRoot: places.storageRoot,
                                   naming: options.naming, pipelines: RenderPipeline.appleSilicon)
        let parallel = options.parallel ?? MediaLibrary.recommendedConcurrentRenders
        let presets = options.presets
        let libraryWorker = LibraryIngestWorker(library: library, limiter: JobLimiter(limit: parallel), presets: { presets })
        let worker: IngestWorker
        var tally: OffloadTally?
        if let destination = options.copyDestination {
            try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
            let offload = OffloadingIngestWorker(base: libraryWorker,
                                                 plan: OffloadPlan(sources: options.folders, destination: destination))
            tally = offload.tally
            worker = offload
        } else {
            worker = libraryWorker
        }

        var settings = IngestEngine.Settings()
        settings.stabilitySeconds = options.stabilitySeconds ?? (options.once ? 0 : 30)
        settings.maxParallel = parallel
        settings.watchesLocalFolders = !options.once
        // A client exists to pick new clips up promptly, on shares as well as local disks.
        settings.shareScanInterval = options.scanInterval
        settings.localScanInterval = min(settings.localScanInterval, max(options.scanInterval, 60))
        settings.tick = min(settings.tick, max(options.scanInterval / 3, 1))
        let startedAt = Date()
        let reporter = Reporter(quiet: options.quiet, since: startedAt, log: log)
        // A single pass keeps no queue of its own: what is done is in the catalog.
        let store = options.once ? nil : IngestStore(url: URL(fileURLWithPath: places.statePath))
        let engine = IngestEngine(store: store, worker: worker, settings: settings,
                                  onChange: { reporter.report($0); onChange?($0) })
        return Session(engine: engine, library: library, startedAt: startedAt, tally: tally)
    }

    /// Ingests what is in the folders now and returns when it is all done.
    public static func runOnce(_ options: Options, tools: FFmpegTools? = FFmpegTools.locate(),
                               log: @escaping @Sendable (String) -> Void = { print($0) },
                               onChange: (@Sendable (IngestEngine.View) -> Void)? = nil,
                               started: (@Sendable (Session) -> Void)? = nil) async throws -> Summary {
        for folder in options.folders {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue
            else { throw ClientError.missingFolder(folder) }
        }
        let session = try makeSession(options, tools: tools, log: log, onChange: onChange)
        started?(session)
        let engine = session.engine
        var ids: [String] = []
        for folder in options.folders {
            if let added = await engine.addFolder(path: folder) { ids.append(added.id) }
        }
        await engine.start(runsLoop: false)
        // Two looks, the second after the stability period: a file is taken only when both agree.
        let wait = options.stabilitySeconds ?? 0
        let first = Date()
        for id in ids { await engine.scan(id, now: first) }
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        for id in ids { await engine.scan(id, now: first.addingTimeInterval(wait + 1)) }
        await engine.waitUntilIdle(timeout: 60 * 60 * 24 * 7)
        let summary = await session.summary()
        await engine.stop()
        return summary
    }

    /// Starts watching the folders. The caller keeps the process alive and stops the engine to quit.
    public static func startWatching(_ options: Options, tools: FFmpegTools? = FFmpegTools.locate(),
                                     log: @escaping @Sendable (String) -> Void = { print($0) }) async throws -> Session {
        let session = try makeSession(options, tools: tools, log: log)
        let wanted = Set(options.folders)
        // The folders on the command line are the folders watched: ones from an earlier run go.
        for folder in await session.engine.folders where !wanted.contains(folder.path) {
            await session.engine.removeFolder(id: folder.id)
        }
        for folder in options.folders { _ = await session.engine.addFolder(path: folder) }
        await session.engine.start()
        return session
    }

    public static func describe(_ summary: Summary) -> String {
        var lines = ["\(summary.ingested) clip\(summary.ingested == 1 ? "" : "s") ingested"
            + (summary.skipped > 0 ? ", \(summary.skipped) skipped" : "")
            + (summary.failures.isEmpty ? "." : ", \(summary.failures.count) failed:")]
        if summary.alreadyOnStorage > 0 {
            lines.insert("\(summary.alreadyOnStorage) already on storage and not copied again, \(summary.copied) copied.", at: 1)
        }
        for failure in summary.failures {
            lines.append("  \((failure.path as NSString).lastPathComponent): \(failure.reason)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Turns the engine's state into one line per event: a clip starting a stage, finishing, or failing.
private final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private let quiet: Bool
    /// Clips finished before this are from an earlier run and are not announced again.
    private let since: Date
    private let log: @Sendable (String) -> Void
    private var stages: [String: String] = [:]
    private var finished: Set<String> = []
    private var reportedFailures: Set<String> = []

    init(quiet: Bool, since: Date, log: @escaping @Sendable (String) -> Void) {
        self.quiet = quiet
        self.since = since
        self.log = log
    }

    func report(_ view: IngestEngine.View) {
        var lines: [String] = []
        lock.lock()
        if !quiet {
            for item in view.working {
                guard let stage = item.stage, stages[item.id] != stage else { continue }
                stages[item.id] = stage
                lines.append("  \(name(item)): \(stage)")
            }
        }
        for item in view.recentlyDone where finished.insert(item.id).inserted {
            stages[item.id] = nil
            guard (item.finishedAt ?? .distantFuture) >= since else { continue }
            if item.state == .skipped {
                if !quiet { lines.append("– \(name(item)): skipped. \(item.reason ?? "")") }
            } else if !quiet {
                lines.append("✓ \(name(item))")
            }
        }
        // A clip that fails again after a retry is reported again.
        for item in view.failed where reportedFailures.insert("\(item.id)#\(item.attempts)").inserted {
            stages[item.id] = nil
            lines.append("✗ \(name(item)): \(item.reason ?? "failed")")
        }
        lock.unlock()
        lines.forEach(log)
    }

    private func name(_ item: IngestItem) -> String { (item.path as NSString).lastPathComponent }
}
