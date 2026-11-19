import Foundation

/// Identifies a media file by its content rather than its name or location, so an original
/// can be found again after it has been moved, renamed or copied to another volume.
///
/// The fingerprint is the file size plus a hash of the first and last megabyte. Reading two
/// megabytes keeps it instant even for very large camera files.
public enum SourceFingerprint {
    private static let sampleSize = 1 << 20

    public static func compute(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a
        func mix(_ data: Data) {
            for byte in data {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        do {
            try handle.seek(toOffset: 0)
            mix(try handle.read(upToCount: sampleSize) ?? Data())
            if size > UInt64(sampleSize) {
                try handle.seek(toOffset: size - UInt64(min(UInt64(sampleSize), size)))
                mix(try handle.read(upToCount: sampleSize) ?? Data())
            }
        } catch {
            return nil
        }
        return "\(size)-" + String(hash, radix: 16)
    }

    /// The file size encoded in a fingerprint, used to shortlist candidates before hashing.
    public static func size(of fingerprint: String) -> Int64? {
        fingerprint.split(separator: "-").first.flatMap { Int64($0) }
    }
}
