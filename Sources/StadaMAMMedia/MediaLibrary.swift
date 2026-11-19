import Foundation
import StadaMAMCore

/// Ingest, proxy generation and source recall — the operations the app drives.
/// All methods block; call them off the main thread.
public struct MediaLibrary: Sendable {
    public let catalog: Catalog
    public let tools: FFmpegTools
    /// Folder that holds generated proxies and thumbnails.
    public var storageRoot: String
    public var naming: ProxyNaming
    /// Render pipelines to try, fastest first. A pipeline that fails for a format is skipped
    /// for later clips of that format.
    public var pipelines: [RenderPipeline]
    private let pipelineMemory = PipelineMemory()

    public init(catalog: Catalog, tools: FFmpegTools, storageRoot: String,
                naming: ProxyNaming = .sameName, pipelines: [RenderPipeline]) {
        self.catalog = catalog
        self.tools = tools
        self.storageRoot = storageRoot
        self.naming = naming
        self.pipelines = pipelines.isEmpty ? [.software] : pipelines
    }

    /// How many proxies to render at once. Hardware encoders are shared between jobs, so this
    /// is deliberately modest; it is a starting point to tune against measured speed.
    public static var recommendedConcurrentRenders: Int {
        switch ProcessInfo.processInfo.activeProcessorCount {
        case ...8: return 2
        case ...12: return 3
        default: return 4
        }
    }

    public var proxyRoot: String { storageRoot + "/Proxies" }

    public func thumbnailDirectory(forAssetID id: String) -> String { storageRoot + "/Thumbnails/" + id }

    // MARK: Ingest

    /// Every importable media file under a folder (or the file itself), skipping hidden files.
    public static func mediaFiles(at path: String) -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
        func isMedia(_ p: String) -> Bool {
            FormatIdentity.importableExtensions.contains((p as NSString).pathExtension.lowercased())
        }
        guard isDirectory.boolValue else { return isMedia(path) ? [path] : [] }
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return [] }
        var files: [String] = []
        for case let relative as String in enumerator {
            let name = (relative as NSString).lastPathComponent
            if name.hasPrefix(".") { continue }
            if isMedia(relative) { files.append(path + "/" + relative) }
        }
        return files.sorted()
    }

    /// Probes a file and adds it to the catalog. Re-importing a known path updates it in place.
    ///
    /// Nothing is rejected for its size, frame rate or codec. A file whose essence cannot be
    /// decoded (camera RAW such as Blackmagic RAW, Sony X-OCN, ARRIRAW, REDCODE) is still
    /// identified and catalogued with whatever the container reveals.
    @discardableResult
    public func importFile(at path: String) throws -> Asset {
        let ext = (path as NSString).pathExtension
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        let probe = try? tools.probe(path: path)
        if let id = probe?.embeddedAssetID { throw MediaError.isOwnProxy(assetID: id) }
        if var asset = probe?.asset(path: path) {
            if asset.fileSize == 0 { asset.fileSize = size }
            return try catalog.save(asset)
        }
        // The container could not be read at all, or exposes no picture stream.
        let identity = FormatIdentity.identify(fileExtension: ext, canDecode: false, vendor: probe?.vendorHint)
        guard FormatIdentity.importableExtensions.contains(ext.lowercased()) else { throw MediaError.noVideoStream(path) }
        return try catalog.save(Asset(sourcePath: path, fileSize: size, decodePath: identity.decodePath,
                                      container: ext.lowercased(), formatName: identity.name, scan: .unknown))
    }

    // MARK: Proxies

    /// Renders a proxy that carries the source's timecode, reel name and catalog ID.
    ///
    /// Tries each pipeline in order and falls back when one cannot handle the clip, so a proxy
    /// is always produced when the format is decodable at all. The record notes which pipeline
    /// was used and how fast it ran.
    @discardableResult
    public func makeProxy(for asset: Asset, preset: ProxyPreset,
                          progress: (@Sendable (Double) -> Void)? = nil) throws -> ProxyRecord {
        guard asset.decodePath.canRender else { throw MediaError.decoderUnavailable(asset.formatName) }
        let path = naming.proxyPath(for: asset, root: proxyRoot)
        var record = try catalog.proxies(forAsset: asset.id).first { $0.path == path }
            ?? ProxyRecord(assetID: asset.id, path: path, preset: preset)
        record.preset = preset
        record.status = .rendering
        try catalog.save(record)

        let formatKey = "\(asset.videoCodec ?? "?")|\(asset.container ?? "?")|\(preset.rawValue)"
        let candidates = pipelines
            .map { ProxyRenderPlan(asset: asset, preset: preset, outputPath: path, pipeline: $0) }
            .filter { $0.isApplicable && !pipelineMemory.hasFailed($0.pipeline, for: formatKey) }
        var lastError: Error = MediaError.ffmpegFailed("no render pipeline available")
        for plan in candidates {
            let started = Date()
            do {
                try tools.render(plan, progress: progress)
                let elapsed = max(Date().timeIntervalSince(started), 0.001)
                // Read the finished file back and confirm it is interchangeable with its source.
                let rendered = try tools.probe(path: path).asset(path: path)
                record.mismatch = rendered.map { ProxyVerifier.mismatch(source: asset, proxy: $0) }
                    ?? "the rendered file has no picture"
                record.status = .ready
                record.pipeline = plan.pipeline
                record.speed = asset.durationSeconds > 0 ? asset.durationSeconds / elapsed : nil
                try catalog.save(record)
                return record
            } catch {
                lastError = error
                pipelineMemory.markFailed(plan.pipeline, for: formatKey)
            }
        }
        record.status = .failed
        try? catalog.save(record)
        throw lastError
    }

    /// The best file to play or analyse: a ready proxy if there is one, else the source.
    public func playablePath(for asset: Asset) -> String? {
        let fm = FileManager.default
        if let proxy = try? catalog.proxies(forAsset: asset.id).first(where: { $0.status == .ready && fm.fileExists(atPath: $0.path) }) {
            return proxy.path
        }
        return asset.decodePath == .avFoundation && fm.fileExists(atPath: asset.sourcePath) ? asset.sourcePath : nil
    }

    @discardableResult
    public func makeThumbnails(for asset: Asset, count: Int = 12) throws -> [String] {
        let media = playablePath(for: asset) ?? asset.sourcePath
        guard asset.decodePath.canRender || media != asset.sourcePath else {
            throw MediaError.decoderUnavailable(asset.formatName)
        }
        return try tools.writeThumbnails(mediaPath: media, durationSeconds: asset.durationSeconds, count: count,
                                         to: thumbnailDirectory(forAssetID: asset.id))
    }

    public func thumbnails(forAssetID id: String) -> [String] {
        let directory = thumbnailDirectory(forAssetID: id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".jpg") }.sorted().map { directory + "/" + $0 }
    }

    // MARK: Source recall

    /// Given any media file — typically a proxy that has been through Premiere or Resolve —
    /// finds the high-resolution source it stands for.
    public func source(forFileAt path: String) throws -> SourceResolution {
        var clue = MediaClue(path: path)
        if let probe = try? tools.probe(path: path) {
            clue.embeddedAssetID = probe.embeddedAssetID
            if let found = probe.asset(path: path) {
                clue.startTimecodeFrames = found.startTimecodeFrames
                clue.durationFrames = found.durationFrames
                clue.reelName = found.reelName
            }
        }
        return try SourceResolver(catalog: catalog).resolve(clue)
    }

    public struct TimelineRelink: Sendable {
        public var document: TimelineDocument
        public var resolutions: [(reference: TimelineMediaReference, resolution: SourceResolution)]
        /// The timeline with proxy paths replaced by source paths, ready for online / conform.
        public var relinkedText: String
        public var unresolvedCount: Int { resolutions.filter { $0.resolution.asset == nil }.count }
    }

    /// Reads a Premiere XML, Resolve FCPXML or EDL and maps every clip back to its source.
    public func relinkTimeline(text: String) throws -> TimelineRelink? {
        guard let document = TimelineDocument(text: text) else { return nil }
        let resolver = SourceResolver(catalog: catalog)
        var byReference: [TimelineMediaReference: SourceResolution] = [:]
        for reference in document.references {
            byReference[reference] = try resolver.resolve(reference.clue)
        }
        return TimelineRelink(
            document: document,
            resolutions: document.references.map { ($0, byReference[$0] ?? .notFound) },
            relinkedText: document.relinked { byReference[$0]?.asset })
    }
}

/// Remembers which pipelines failed for which formats, so a batch does not retry them per clip.
private final class PipelineMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var failed: Set<String> = []

    func hasFailed(_ pipeline: RenderPipeline, for format: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed.contains(pipeline.rawValue + "|" + format)
    }

    func markFailed(_ pipeline: RenderPipeline, for format: String) {
        lock.lock()
        failed.insert(pipeline.rawValue + "|" + format)
        lock.unlock()
    }
}

/// Limits how many jobs run at once; waiting jobs start in the order they asked.
public actor JobLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        available = max(limit, 1)
    }

    public func acquire() async {
        if available > 0 {
            available -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    public func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
