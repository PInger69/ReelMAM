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
    /// Use VideoToolbox encoders. True on macOS; false keeps tests portable.
    public var hardwareEncoding: Bool

    public init(catalog: Catalog, tools: FFmpegTools, storageRoot: String,
                naming: ProxyNaming = .sameName, hardwareEncoding: Bool) {
        self.catalog = catalog
        self.tools = tools
        self.storageRoot = storageRoot
        self.naming = naming
        self.hardwareEncoding = hardwareEncoding
    }

    public var proxyRoot: String { storageRoot + "/Proxies" }

    public func thumbnailDirectory(forAssetID id: String) -> String { storageRoot + "/Thumbnails/" + id }

    // MARK: Ingest

    /// Every importable media file under a folder (or the file itself), skipping hidden files.
    public static func mediaFiles(at path: String) -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
        func isMedia(_ p: String) -> Bool { DecodePath.forFile(extension: (p as NSString).pathExtension) != nil }
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
    @discardableResult
    public func importFile(at path: String) throws -> Asset {
        let ext = (path as NSString).pathExtension
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        if DecodePath.forFile(extension: ext) == .blackmagicRAW {
            // FFmpeg cannot read BRAW. Catalogue the file so it is searchable and relinkable;
            // technical metadata and proxies arrive with the Blackmagic RAW SDK bridge.
            return try catalog.save(Asset(sourcePath: path, fileSize: size, decodePath: .blackmagicRAW, container: "braw"))
        }
        let probe = try tools.probe(path: path)
        if let id = probe.embeddedAssetID { throw MediaError.isOwnProxy(assetID: id) }
        guard var asset = probe.asset(path: path) else { throw MediaError.noVideoStream(path) }
        if asset.fileSize == 0 { asset.fileSize = size }
        return try catalog.save(asset)
    }

    // MARK: Proxies

    /// Renders a proxy that carries the source's timecode, reel name and catalog ID.
    @discardableResult
    public func makeProxy(for asset: Asset, preset: ProxyPreset,
                          progress: (@Sendable (Double) -> Void)? = nil) throws -> ProxyRecord {
        guard asset.decodePath != .blackmagicRAW else { throw MediaError.blackmagicRAWSDKRequired }
        let path = naming.proxyPath(for: asset, root: proxyRoot)
        var record = try catalog.proxies(forAsset: asset.id).first { $0.path == path }
            ?? ProxyRecord(assetID: asset.id, path: path, preset: preset)
        record.preset = preset
        record.status = .rendering
        try catalog.save(record)
        do {
            try tools.render(ProxyRenderPlan(asset: asset, preset: preset, outputPath: path,
                                             hardware: hardwareEncoding), progress: progress)
            record.status = .ready
            try catalog.save(record)
            return record
        } catch {
            record.status = .failed
            try? catalog.save(record)
            throw error
        }
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
        guard asset.decodePath != .blackmagicRAW || media != asset.sourcePath else {
            throw MediaError.blackmagicRAWSDKRequired
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
