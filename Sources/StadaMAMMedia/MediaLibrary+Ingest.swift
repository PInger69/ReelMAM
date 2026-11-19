import Foundation
import StadaMAMCore

/// The pieces of `MediaLibrary` that continuous ingest uses.
extension MediaLibrary {
    /// True when the clip already has a finished proxy of `preset` that was checked against its
    /// source and whose file is still there. The remote server serves only such proxies.
    public func hasVerifiedProxy(for asset: Asset, preset: ProxyPreset) -> Bool {
        let records = (try? catalog.proxies(forAsset: asset.id)) ?? []
        return records.contains {
            $0.preset == preset && $0.status == .ready && $0.mismatch == nil
                && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Paths, among `paths`, of catalogued clips that can be rendered but lack a verified proxy
    /// of one of `presets`. Answers from two queries however many paths there are.
    public func pathsNeedingProxies(among paths: [String], presets: [ProxyPreset]) -> [String] {
        guard !paths.isEmpty, !presets.isEmpty else { return [] }
        let wanted = Set(paths)
        let have = (try? catalog.verifiedProxyKeys()) ?? []
        guard let assets = try? catalog.allAssets() else { return [] }
        return assets.filter { asset in
            wanted.contains(asset.sourcePath) && asset.decodePath.canRender
                && presets.contains { !have.contains(asset.id + "|" + $0.rawValue) }
        }.map(\.sourcePath)
    }
}

/// Everything the ingest engine needs from the library, so it can be tested without FFmpeg.
public protocol IngestWorker: Sendable {
    /// Imports the file, then makes whatever proxies are wanted. `report` gives the current stage and progress.
    func process(path: String, report: @escaping @Sendable (String, Double?) -> Void) async throws -> IngestOutcome
    /// Size of every catalogued file by path.
    func cataloguedSizes() throws -> [String: Int64]
    /// Catalogued clips among `paths` that still lack a wanted proxy.
    func pathsNeedingProxies(among paths: [String]) -> [String]
    /// What the scanner should leave out right now (the app's own proxy and copy folders).
    func filter() -> IngestFilter
}

public struct IngestOutcome: Sendable {
    public var assetID: String?
    /// Worth showing beside a finished clip, e.g. that its format cannot be rendered.
    public var note: String?
    public init(assetID: String? = nil, note: String? = nil) {
        self.assetID = assetID
        self.note = note
    }
}

/// Imports a file and renders its proxies with a `MediaLibrary`: the editors' proxy in the
/// chosen preset and the remote one, sharing the app's render limit.
public struct LibraryIngestWorker: IngestWorker {
    /// Asked for every clip: the app changes the proxy folder and naming while it runs.
    public var libraryProvider: @Sendable () -> MediaLibrary
    public var library: MediaLibrary { libraryProvider() }
    public var limiter: JobLimiter
    /// Read for every clip, so a changed setting applies to the next one.
    public var presets: @Sendable () -> [ProxyPreset]
    public var extraIgnoredRoots: @Sendable () -> [String]

    public init(library: MediaLibrary, limiter: JobLimiter,
                presets: @escaping @Sendable () -> [ProxyPreset],
                extraIgnoredRoots: @escaping @Sendable () -> [String] = { [] }) {
        self.init(libraryProvider: { library }, limiter: limiter, presets: presets, extraIgnoredRoots: extraIgnoredRoots)
    }

    public init(libraryProvider: @escaping @Sendable () -> MediaLibrary, limiter: JobLimiter,
                presets: @escaping @Sendable () -> [ProxyPreset],
                extraIgnoredRoots: @escaping @Sendable () -> [String] = { [] }) {
        self.libraryProvider = libraryProvider
        self.limiter = limiter
        self.presets = presets
        self.extraIgnoredRoots = extraIgnoredRoots
    }

    public func process(path: String, report: @escaping @Sendable (String, Double?) -> Void) async throws -> IngestOutcome {
        report("Importing", nil)
        let asset: Asset
        do {
            asset = try await library.importFile(at: path)
        } catch MediaError.isOwnProxy {
            throw IngestSkipped("One of this app's own proxies.")
        }
        if library.thumbnails(forAssetID: asset.id).isEmpty {
            report("Making thumbnails", nil)
            _ = try? await library.makeThumbnails(for: asset)
        }
        let wanted = presets()
        guard !wanted.isEmpty else { return IngestOutcome(assetID: asset.id) }
        guard asset.decodePath.canRender else {
            return IngestOutcome(assetID: asset.id, note: "Catalogued; \(asset.formatName) cannot be rendered into a proxy here.")
        }
        for preset in wanted where !library.hasVerifiedProxy(for: asset, preset: preset) {
            let label = preset.isForRemoteViewing ? "remote proxy" : "proxy"
            report("Waiting to render \(label)", nil)
            await limiter.acquire()
            report("Rendering \(label)", 0)
            let record: ProxyRecord
            do {
                record = try await library.makeProxy(for: asset, preset: preset) { report("Rendering \(label)", $0) }
            } catch {
                await limiter.release()
                throw error
            }
            await limiter.release()
            if let mismatch = record.mismatch {
                throw IngestProblem("The \(label) does not match its source (\(mismatch)).")
            }
        }
        return IngestOutcome(assetID: asset.id)
    }

    public func cataloguedSizes() throws -> [String: Int64] { try library.catalog.knownFileSizes() }

    public func pathsNeedingProxies(among paths: [String]) -> [String] {
        library.pathsNeedingProxies(among: paths, presets: presets())
    }

    public func filter() -> IngestFilter {
        IngestFilter(ignoredRoots: [library.proxyRoot, library.storageRoot] + extraIgnoredRoots(),
                     ignoredFolderNames: library.naming == .besideSource ? ["Proxy"] : [])
    }
}

public struct IngestProblem: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
