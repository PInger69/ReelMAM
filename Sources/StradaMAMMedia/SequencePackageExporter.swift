import Foundation
import StradaMAMCore
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum PackageError: Error, LocalizedError, Equatable {
    case emptySequence
    case missingOriginals([String])
    case notEnoughSpace(needed: Int64, free: Int64)
    case copyDoesNotMatch(String)
    case cannotWrite(String)

    public var errorDescription: String? {
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        switch self {
        case .emptySequence:
            return "The sequence has no cuts to package."
        case .missingOriginals(let names):
            let shown = names.prefix(8).joined(separator: "\n")
            return "\(names.count) original\(names.count == 1 ? " is" : "s are") not reachable, so nothing was packaged. Reconnect the storage and try again:\n\(shown)"
        case .notEnoughSpace(let needed, let free):
            return "The package needs \(size(needed)) and that disk has \(size(free)) free."
        case .copyDoesNotMatch(let name):
            return "The copy of \(name) did not match the original when it was read back, so it was removed. The disk may be faulty."
        case .cannotWrite(let why):
            return "The package could not be written: \(why)"
        }
    }
}

public struct PackageProgress: Sendable {
    public var fileName: String
    public var bytesDone: Int64
    public var bytesTotal: Int64

    public init(fileName: String, bytesDone: Int64, bytesTotal: Int64) {
        self.fileName = fileName
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }

    /// Each file is written, then read back to check it; both count toward the total.
    public var fraction: Double { bytesTotal > 0 ? min(Double(bytesDone) / Double(bytesTotal), 1) : 1 }
}

public struct PackageResult: Sendable {
    public var folder: String
    public var manifest: PackageManifest
}

/// Writes a sequence as a folder for a full editing app: the timeline files, the camera
/// originals the cut uses (copied whole and checked), and a manifest.
///
/// This only ever copies to a folder on this Mac or a disk attached to it. Nothing here opens a
/// network connection.
public enum SequencePackageExporter {
    public static let checksumAlgorithm: String = {
        #if canImport(CryptoKit)
        return "sha256"
        #else
        return "fnv1a64"
        #endif
    }()

    /// - Parameter parent: the folder the package folder is created in.
    public static func export(_ sequence: ResolvedSequence, into parent: String,
                              formats: [SequenceTimelineFormat] = SequenceTimelineFormat.allCases,
                              strictEDLReels: Bool = false, now: Date = Date(),
                              progress: (@Sendable (PackageProgress) -> Void)? = nil) throws -> PackageResult {
        guard !sequence.cuts.isEmpty else { throw PackageError.emptySequence }
        let plan = SequencePackagePlan(sequence: sequence)
        guard plan.missing.isEmpty else { throw PackageError.missingOriginals(plan.missing.map(\.sourcePath)) }

        let fm = FileManager.default
        #if os(macOS)
        if let free = try? URL(fileURLWithPath: parent).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < plan.totalBytes {
            throw PackageError.notEnoughSpace(needed: plan.totalBytes, free: free)
        }
        #endif

        // A new folder every time: an earlier package is never written over.
        let baseName = safeFileName(sequence.sequence.name)
        var folder = parent + "/" + baseName + " package"
        var attempt = 2
        while fm.fileExists(atPath: folder) {
            folder = parent + "/" + baseName + " package \(attempt)"
            attempt += 1
        }
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            throw PackageError.cannotWrite(error.localizedDescription)
        }

        let total = plan.totalBytes * 2
        var done: Int64 = 0
        var files: [PackageManifest.File] = []
        var mediaPaths: [String: String] = [:]
        for item in plan.items {
            let destination = folder + "/" + item.relativePath
            let checksum = try copyAndVerify(from: item.asset.sourcePath, to: destination) { bytes in
                done += bytes
                progress?(PackageProgress(fileName: item.asset.fileName, bytesDone: done, bytesTotal: total))
            }
            files.append(PackageManifest.file(for: item, in: sequence, checksum: checksum, verified: true))
            mediaPaths[item.asset.id] = destination
            for sidecar in item.sidecars {
                let name = (sidecar.sourcePath as NSString).lastPathComponent
                let sum = try copyAndVerify(from: sidecar.sourcePath, to: folder + "/" + sidecar.relativePath) { bytes in
                    done += bytes
                    progress?(PackageProgress(fileName: name, bytesDone: done, bytesTotal: total))
                }
                files.append(PackageManifest.File(path: sidecar.relativePath, sourcePath: sidecar.sourcePath, bytes: sidecar.bytes,
                                                  checksum: sum, verified: true, clipName: nil, reel: nil,
                                                  startTimecode: nil, frameRate: nil, uses: []))
            }
        }

        // The timelines point at the copies in the package, where they are now.
        var timelineFiles: [String] = []
        let options = TimelineExportOptions(mediaPaths: mediaPaths, strictEDLReels: strictEDLReels)
        do {
            for format in formats {
                let name = baseName + "." + format.fileExtension
                try EditorExport.timeline(sequence, format: format, options: options)
                    .write(toFile: folder + "/" + name, atomically: true, encoding: .utf8)
                timelineFiles.append(name)
            }
            let manifest = PackageManifest(createdAt: now, sequence: sequence, checksumAlgorithm: checksumAlgorithm,
                                           timelineFiles: timelineFiles, files: files)
            try manifest.json().write(to: URL(fileURLWithPath: folder + "/manifest.json"))
            try manifest.checksumList.write(toFile: folder + "/checksums." + checksumAlgorithm, atomically: true, encoding: .utf8)
            return PackageResult(folder: folder, manifest: manifest)
        } catch {
            throw PackageError.cannotWrite(error.localizedDescription)
        }
    }

    /// Checks a package against its manifest by reading every file again. Returns the paths that
    /// are missing or no longer match.
    public static func verify(packageAt folder: String) throws -> [String] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(PackageManifest.self, from: Data(contentsOf: URL(fileURLWithPath: folder + "/manifest.json")))
        return manifest.files.filter { (try? checksum(ofFileAt: folder + "/" + $0.path)) != $0.checksum }.map(\.path)
    }

    public static func safeFileName(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix(".") ? "Sequence" : trimmed
    }

    // MARK: Copying

    static let chunkSize = 8 << 20

    /// Copies a file, then reads the copy back and compares checksums. Returns the checksum.
    static func copyAndVerify(from source: String, to destination: String, advanced: (Int64) -> Void) throws -> String {
        try ResilientCopy().copy(from: source, to: destination, advanced: advanced)
    }

    static func checksum(ofFileAt path: String, advanced: (Int64) -> Void = { _ in }) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw PackageError.cannotWrite("\((path as NSString).lastPathComponent) could not be read back.")
        }
        defer { try? handle.close() }
        var hasher = Checksum()
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleased { try handle.read(upToCount: chunkSize) ?? Data() }
            if chunk.isEmpty { break }
            hasher.update(chunk)
            advanced(Int64(chunk.count))
        }
        return hasher.finish()
    }

    private static func autoreleased<T>(_ work: () throws -> T) rethrows -> T {
        #if os(macOS)
        return try autoreleasepool(invoking: work)
        #else
        return try work()
        #endif
    }
}

/// SHA-256 where the system provides it; a 64-bit FNV-1a otherwise.
struct Checksum {
    #if canImport(CryptoKit)
    private var sha = SHA256()
    mutating func update(_ data: Data) { sha.update(data: data) }
    func finish() -> String { sha.finalize().map { String(format: "%02x", $0) }.joined() }
    #else
    private var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func update(_ data: Data) {
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
    }
    func finish() -> String { String(hash, radix: 16) }
    #endif
}
