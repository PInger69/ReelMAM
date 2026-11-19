import Foundation

/// What a package export will copy: the camera originals a sequence uses, each once and whole.
public struct SequencePackagePlan: Sendable {
    public struct Item: Hashable, Sendable {
        public var asset: Asset
        /// Where the copy goes, relative to the package folder.
        public var relativePath: String
        public var bytes: Int64
        /// Files that belong with the original (Blackmagic `.sidecar`, RED `.RMD`, …), as
        /// source path and path inside the package.
        public var sidecars: [Sidecar]
    }

    public struct Sidecar: Hashable, Sendable {
        public var sourcePath: String
        public var relativePath: String
        public var bytes: Int64
    }

    public var items: [Item]
    /// Clips whose original cannot be reached right now. Nothing is exported while any is missing.
    public var missing: [Asset]

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes + $1.sidecars.reduce(0) { $0 + $1.bytes } } }

    /// Extensions of files that sit beside an original, share its name and must travel with it.
    public static let sidecarExtensions = ["sidecar", "rmd", "xmp", "cdl"]

    public static let mediaFolder = "Media"

    /// Where an original goes inside the package: its volume and folders are kept, so two cards
    /// that both hold `A001_C001.mov` never collide and the layout is recognisable.
    public static func relativePath(for sourcePath: String) -> String {
        var parts = sourcePath.split(separator: "/").map(String.init)
        if parts.first == "Volumes", parts.count > 1 { parts.removeFirst() } else { parts.insert("This Mac", at: 0) }
        return ([mediaFolder] + parts).joined(separator: "/")
    }

    /// - Parameter fileSize: the size of a file, or nil when it is not there. Injected for tests.
    public init(sequence: ResolvedSequence, fileSize: (String) -> Int64? = SequencePackagePlan.sizeOnDisk) {
        var items: [Item] = [], missing: [Asset] = []
        for asset in sequence.assets {
            guard let bytes = fileSize(asset.sourcePath) else { missing.append(asset); continue }
            let relative = Self.relativePath(for: asset.sourcePath)
            let base = (asset.sourcePath as NSString).deletingPathExtension
            let relativeBase = (relative as NSString).deletingPathExtension
            var sidecars: [Sidecar] = []
            for ext in Self.sidecarExtensions {
                for candidate in [ext, ext.uppercased()] {
                    let path = base + "." + candidate
                    guard path != asset.sourcePath, let size = fileSize(path),
                          !sidecars.contains(where: { $0.sourcePath.lowercased() == path.lowercased() }) else { continue }
                    sidecars.append(Sidecar(sourcePath: path, relativePath: relativeBase + "." + candidate, bytes: size))
                }
            }
            items.append(Item(asset: asset, relativePath: relative, bytes: bytes, sidecars: sidecars))
        }
        self.items = items
        self.missing = missing
    }

    public static func sizeOnDisk(_ path: String) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
    }
}

/// The record written into a package: what was copied, from where, and the checksum each copy
/// was verified against.
public struct PackageManifest: Codable, Equatable, Sendable {
    public struct Use: Codable, Equatable, Sendable {
        /// Timeline timecode where the cut starts.
        public var recordIn: String
        public var sourceIn: String
        /// Source timecode of the frame after the last one used.
        public var sourceOut: String
    }

    public struct File: Codable, Equatable, Sendable {
        /// Path inside the package.
        public var path: String
        /// Where the original was on the hub when the package was made.
        public var sourcePath: String
        public var bytes: Int64
        public var checksum: String
        /// False only if the copy was written but could not be confirmed; a package is not
        /// finished while any file is unverified.
        public var verified: Bool
        public var clipName: String?
        public var reel: String?
        public var startTimecode: String?
        public var frameRate: String?
        public var uses: [Use]

        public init(path: String, sourcePath: String, bytes: Int64, checksum: String, verified: Bool,
                    clipName: String? = nil, reel: String? = nil, startTimecode: String? = nil,
                    frameRate: String? = nil, uses: [Use] = []) {
            self.path = path
            self.sourcePath = sourcePath
            self.bytes = bytes
            self.checksum = checksum
            self.verified = verified
            self.clipName = clipName
            self.reel = reel
            self.startTimecode = startTimecode
            self.frameRate = frameRate
            self.uses = uses
        }
    }

    public var madeBy: String
    public var createdAt: Date
    public var sequenceName: String
    public var frameRate: String
    public var checksumAlgorithm: String
    public var timelineFiles: [String]
    public var files: [File]
    public var totalBytes: Int64

    public init(madeBy: String = "StradaXR A.I. MAM", createdAt: Date = Date(), sequence: ResolvedSequence,
                checksumAlgorithm: String, timelineFiles: [String], files: [File]) {
        self.madeBy = madeBy
        self.createdAt = createdAt
        sequenceName = sequence.sequence.name
        frameRate = "\(sequence.frameRate.numerator)/\(sequence.frameRate.denominator)"
        self.checksumAlgorithm = checksumAlgorithm
        self.timelineFiles = timelineFiles
        self.files = files
        totalBytes = files.reduce(0) { $0 + $1.bytes }
    }

    /// The manifest entry for an original, with every place the cut uses it.
    public static func file(for item: SequencePackagePlan.Item, in sequence: ResolvedSequence,
                            checksum: String, verified: Bool) -> File {
        let asset = item.asset
        let uses = sequence.cuts.filter { $0.asset.id == asset.id }.map { placed in
            Use(recordIn: sequence.recordTimecode(atFrame: placed.recordStart).description,
                sourceIn: placed.sourceIn.description, sourceOut: placed.sourceOutExclusive.description)
        }
        return File(path: item.relativePath, sourcePath: asset.sourcePath, bytes: item.bytes, checksum: checksum,
                    verified: verified, clipName: asset.fileName, reel: asset.reelName,
                    startTimecode: asset.startTimecode.description,
                    frameRate: "\(asset.frameRateNum)/\(asset.frameRateDen)", uses: uses)
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// One line per file in the form `shasum -a 256 -c` reads, so the package can be checked
    /// again on any computer without this app.
    public var checksumList: String {
        files.map { "\($0.checksum)  \($0.path)" }.joined(separator: "\n") + "\n"
    }
}
