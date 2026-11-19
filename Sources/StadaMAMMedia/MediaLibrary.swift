import Foundation
import StadaMAMCore

/// Ingest, proxy generation and source recall — the operations the app drives.
///
/// On a Mac everything Apple's frameworks can open goes through `NativeMedia`. FFmpeg is
/// optional: when it is installed it handles the remaining formats, and when it is not,
/// those formats are still catalogued.
public struct MediaLibrary: Sendable {
    public let catalog: Catalog
    /// Present only when FFmpeg is installed.
    public let tools: FFmpegTools?
    /// Folder that holds generated proxies and thumbnails.
    public var storageRoot: String
    public var naming: ProxyNaming
    /// Render pipelines to try, fastest first. A pipeline that fails for a format is skipped
    /// for later clips of that format.
    public var pipelines: [RenderPipeline]
    private let pipelineMemory = PipelineMemory()

    public init(catalog: Catalog, tools: FFmpegTools?, storageRoot: String,
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

    /// Overrides where proxies are written, e.g. a large volume; thumbnails stay in `storageRoot`.
    public var proxyFolder: String?
    public var proxyRoot: String { proxyFolder ?? storageRoot + "/Proxies" }

    public func thumbnailDirectory(forAssetID id: String) -> String { storageRoot + "/Thumbnails/" + id }

    // MARK: Probing

    private struct ProbeResult {
        var asset: Asset?
        var embeddedAssetID: String?
        var vendorHint: String?
    }

    /// Reads a file's technical metadata natively where possible, otherwise through FFmpeg.
    private func probe(path: String) async -> ProbeResult {
        #if os(macOS)
        if NativeMedia.canOpen(path: path), let native = try? await NativeMedia.probe(path: path) {
            var embeddedID = native.embeddedAssetID
            // Proxies written by FFmpeg store the ID where only FFmpeg's reader finds it.
            if embeddedID == nil, let tools {
                embeddedID = try? await Self.offload { try tools.probe(path: path).embeddedAssetID }
            }
            return ProbeResult(asset: native.asset, embeddedAssetID: embeddedID)
        }
        #endif
        guard let tools, let probe = try? await Self.offload({ try tools.probe(path: path) }) else {
            return ProbeResult()
        }
        return ProbeResult(asset: probe.asset(path: path), embeddedAssetID: probe.embeddedAssetID,
                           vendorHint: probe.vendorHint)
    }

    /// Runs blocking work (an FFmpeg process) off the Swift concurrency thread pool.
    private static func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

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
    public func importFile(at path: String) async throws -> Asset {
        let ext = (path as NSString).pathExtension
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        let probed = await probe(path: path)
        if let id = probed.embeddedAssetID { throw MediaError.isOwnProxy(assetID: id) }
        let fingerprint = SourceFingerprint.compute(path: path)
        if var asset = probed.asset {
            if asset.fileSize == 0 { asset.fileSize = size }
            asset.fingerprint = fingerprint
            return try catalog.save(asset)
        }
        // The container could not be read at all, or exposes no picture stream.
        guard FormatIdentity.importableExtensions.contains(ext.lowercased()) else { throw MediaError.noVideoStream(path) }
        let identity = FormatIdentity.identify(fileExtension: ext, canDecode: false, vendor: probed.vendorHint)
        var asset = Asset(sourcePath: path, fileSize: size, decodePath: identity.decodePath,
                          container: ext.lowercased(), formatName: identity.name, scan: .unknown)
        asset.fingerprint = fingerprint
        return try catalog.save(asset)
    }

    // MARK: Missing originals

    /// Gives a fingerprint to every reachable original that does not have one yet — clips
    /// catalogued before fingerprints existed, or while their volume was slow to respond —
    /// so they can still be found after a later move. Returns how many were added.
    @discardableResult
    public func backfillFingerprints() throws -> Int {
        var added = 0
        for var asset in try catalog.allAssets() where asset.fingerprint == nil {
            guard let fingerprint = SourceFingerprint.compute(path: asset.sourcePath) else { continue }
            asset.fingerprint = fingerprint
            try catalog.save(asset)
            added += 1
        }
        return added
    }

    /// Clips whose original file is not where the catalog says it is.
    public func offlineAssets() throws -> [Asset] {
        try catalog.allAssets().filter { !FileManager.default.fileExists(atPath: $0.sourcePath) }
    }

    /// Re-finds originals whose volume is mounted again under a different name — common with
    /// SMB and other network shares (`/Volumes/Media` one day, `/Volumes/Media-1` the next).
    /// The same relative path is tried on every mounted volume and confirmed by content.
    @discardableResult
    public func remapRemountedVolumes(volumesRoot: String = "/Volumes") throws -> [Asset] {
        let missing = try offlineAssets()
        guard !missing.isEmpty else { return [] }
        let mounted = ((try? FileManager.default.contentsOfDirectory(atPath: volumesRoot)) ?? [])
            .filter { !$0.hasPrefix(".") }
        var found: [Asset] = []
        for asset in missing {
            let candidates = VolumeRemapper.candidates(for: asset.sourcePath, volumesRoot: volumesRoot,
                                                       mountedVolumes: mounted)
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                // Without a stored fingerprint, fall back to an exact size match.
                let size = ((try? FileManager.default.attributesOfItem(atPath: candidate))?[.size] as? NSNumber)?.int64Value
                let same = asset.fingerprint.map { $0 == SourceFingerprint.compute(path: candidate) } ?? (size == asset.fileSize)
                guard same else { continue }
                found.append(try catalog.save(asset.relocated(to: candidate)))
                break
            }
        }
        return found
    }

    /// Looks under a folder for originals that have moved or been renamed and points their
    /// clips at the new location. Matching is by content, so the name does not matter.
    /// Returns the clips that were found.
    @discardableResult
    public func locateMissingSources(under folder: String) throws -> [Asset] {
        let missing = try offlineAssets().filter { $0.fingerprint != nil }
        guard !missing.isEmpty else { return [] }
        var bySize: [Int64: [Asset]] = [:]
        for asset in missing {
            if let size = asset.fingerprint.flatMap(SourceFingerprint.size(of:)) { bySize[size, default: []].append(asset) }
        }
        var found: [Asset] = []
        var claimed = Set<String>()
        // A file that already belongs to another clip (an identical copy imported separately)
        // is not a candidate: matching it would hand the wrong clip's identity over.
        let owned = Set(try catalog.allAssets().map(\.sourcePath))
        for file in Self.mediaFiles(at: folder) where !owned.contains(file) {
            let size = ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? NSNumber)?.int64Value ?? -1
            // Only files of exactly the right size are worth hashing.
            guard let candidates = bySize[size], let fingerprint = SourceFingerprint.compute(path: file),
                  let match = candidates.first(where: { $0.fingerprint == fingerprint && !claimed.contains($0.id) })
            else { continue }
            claimed.insert(match.id)
            found.append(try catalog.save(match.relocated(to: file)))
        }
        return found
    }

    // MARK: Proxies

    /// Renders a proxy that carries the source's timecode, reel name and catalog ID.
    ///
    /// Tries each pipeline in order and falls back when one cannot handle the clip, so a proxy
    /// is always produced when the format is decodable at all. The finished file is read back
    /// and compared with its source; the record notes the pipeline, its speed and any mismatch.
    @discardableResult
    public func makeProxy(for asset: Asset, preset: ProxyPreset,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> ProxyRecord {
        guard asset.decodePath.canRender else { throw MediaError.decoderUnavailable(asset.formatName) }
        let path = naming.proxyPath(for: asset, root: proxyRoot, preset: preset)
        var record = try catalog.proxies(forAsset: asset.id).first { $0.path == path }
            ?? ProxyRecord(assetID: asset.id, path: path, preset: preset)
        record.preset = preset
        record.status = .rendering
        try catalog.save(record)

        let formatKey = "\(asset.videoCodec ?? "?")|\(asset.container ?? "?")|\(preset.rawValue)"
        let candidates = pipelines
            .map { ProxyRenderPlan(asset: asset, preset: preset, outputPath: path, pipeline: $0) }
            .filter { $0.isApplicable && isAvailable($0.pipeline) && !pipelineMemory.hasFailed($0.pipeline, for: formatKey) }
        var lastError: Error = candidates.isEmpty && tools == nil
            ? MediaError.ffmpegNotFound
            : MediaError.ffmpegFailed("no render pipeline available")
        for plan in candidates {
            let started = Date()
            do {
                try await render(plan, progress: progress)
                let elapsed = max(Date().timeIntervalSince(started), 0.001)
                // Read the finished file back and confirm it is interchangeable with its source.
                let rendered = await probe(path: path).asset
                record.mismatch = rendered.map { ProxyVerifier.mismatch(source: asset, proxy: $0) }
                    ?? "the rendered file could not be read back"
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

    private func isAvailable(_ pipeline: RenderPipeline) -> Bool {
        if pipeline.usesFFmpeg { return tools != nil }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    private func render(_ plan: ProxyRenderPlan, progress: (@Sendable (Double) -> Void)?) async throws {
        if plan.pipeline == .native {
            #if os(macOS)
            // Write under a temporary name so a half-written proxy is never mistaken for a finished one.
            var partial = plan
            partial.outputPath = plan.outputPath + ".partial.mov"
            do {
                try await NativeMedia.renderProxy(partial, progress: progress)
                try? FileManager.default.removeItem(atPath: plan.outputPath)
                try FileManager.default.moveItem(atPath: partial.outputPath, toPath: plan.outputPath)
            } catch {
                try? FileManager.default.removeItem(atPath: partial.outputPath)
                throw error
            }
            return
            #else
            throw MediaError.ffmpegFailed("the native pipeline needs macOS")
            #endif
        }
        guard let tools else { throw MediaError.ffmpegNotFound }
        try await Self.offload { try tools.render(plan, progress: progress) }
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
    public func makeThumbnails(for asset: Asset, count: Int = 12) async throws -> [String] {
        let directory = thumbnailDirectory(forAssetID: asset.id)
        #if os(macOS)
        if let playable = playablePath(for: asset) {
            let paths = try await NativeMedia.writeThumbnails(
                mediaPath: playable, durationSeconds: asset.durationSeconds, count: count, to: directory)
            if !paths.isEmpty { return paths }
        }
        #endif
        let media = playablePath(for: asset) ?? asset.sourcePath
        guard asset.decodePath.canRender || media != asset.sourcePath else {
            throw MediaError.decoderUnavailable(asset.formatName)
        }
        guard let tools else { throw MediaError.ffmpegNotFound }
        let duration = asset.durationSeconds
        return try await Self.offload {
            try tools.writeThumbnails(mediaPath: media, durationSeconds: duration, count: count, to: directory)
        }
    }

    public func thumbnails(forAssetID id: String) -> [String] {
        let directory = thumbnailDirectory(forAssetID: id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".jpg") }.sorted().map { directory + "/" + $0 }
    }

    // MARK: Source recall

    /// Given any media file — typically a proxy that has been through Premiere, Resolve or
    /// Final Cut — finds the high-resolution source it stands for.
    public func source(forFileAt path: String) async throws -> SourceResolution {
        var clue = MediaClue(path: path)
        let probed = await probe(path: path)
        clue.embeddedAssetID = probed.embeddedAssetID
        if let found = probed.asset {
            clue.startTimecodeFrames = found.startTimecodeFrames
            clue.durationFrames = found.durationFrames
            clue.reelName = found.reelName
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

    /// Reads a Premiere XML, Resolve / Final Cut FCPXML or EDL and maps every clip back to its source.
    /// - Parameter pathMappings: translates paths written on the editor's computer (Windows
    ///   drive letters, Linux mount points) back to this Mac before matching.
    public func relinkTimeline(text: String, pathMappings: [PathMapping] = []) throws -> TimelineRelink? {
        guard let document = TimelineDocument(text: text) else { return nil }
        let resolver = SourceResolver(catalog: catalog)
        var byReference: [TimelineMediaReference: SourceResolution] = [:]
        for reference in document.references {
            var clue = reference.clue
            if let path = clue.path {
                clue.path = PathMapping.toMac(path, using: pathMappings)
                // File names are taken from the last component whichever slash the editor's computer uses.
                clue.fileName = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
            }
            byReference[reference] = try resolver.resolve(clue)
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
