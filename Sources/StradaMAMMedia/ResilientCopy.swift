import Foundation
import StradaMAMCore

/// Copies one file so that a card or a share that stumbles does not lose the copy.
///
/// - The file is read and written in buffers of a fixed size, never as a whole, so a clip of any
///   length uses the same small amount of memory.
/// - A read or a write that fails is tried again from the same place, after a pause that grows:
///   a card reader that drops off the bus for a moment, or a share that stalls, is waited for.
/// - The copy is written beside its final name as `<name>.partial` and only takes the final name
///   once it has been read back and its checksum matches what was read from the source. A file
///   with the final name is therefore always a whole, checked copy.
/// - A `.partial` left by a run that was stopped is carried on from where it ended.
/// - A copy that does not match is made once more before it is given up on.
public struct ResilientCopy: Sendable {
    public var chunkSize = SequencePackageExporter.chunkSize
    /// The pause before each further try at a read or write that failed. About two and a half minutes in all.
    public var retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 15, 30, 30, 30, 30]
    /// Told when the copy is waiting to try again, with what went wrong.
    public var stalled: @Sendable (String) -> Void = { _ in }
    /// How a buffer is read. Replaced in tests to stand in for a card that fails.
    var read: @Sendable (FileHandle, Int) throws -> Data = { handle, count in try handle.read(upToCount: count) ?? Data() }

    public static let partialSuffix = ".partial"

    public init() {}

    /// Copies `source` to `destination` and returns the checksum both were found to have.
    public func copy(from source: String, to destination: String, advanced: (Int64) -> Void) throws -> String {
        let fm = FileManager.default
        let name = (source as NSString).lastPathComponent
        let partial = destination + Self.partialSuffix
        let folder = (destination as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            throw PackageError.cannotWrite("\(name): the folder on the destination could not be made. \(error.localizedDescription)")
        }
        let size = Self.size(of: source)
        if let free = Self.freeSpace(at: folder) {
            let needed = size - Self.size(of: partial)
            if needed > free { throw PackageError.notEnoughSpace(needed: needed, free: free) }
        }

        for attempt in 0..<2 {
            var hasher = Checksum()
            var offset: Int64 = 0
            // Carry on a copy that was stopped part-way: keep what is there, in whole buffers.
            let existing = Self.size(of: partial)
            if attempt == 0, existing > 0, existing <= size {
                offset = existing - existing % Int64(chunkSize)
            }
            if offset == 0 {
                guard fm.createFile(atPath: partial, contents: nil) else {
                    throw PackageError.cannotWrite("\(name) could not be created on the destination.")
                }
            }
            let input = Reader(path: source, name: name, copy: self)
            defer { input.close() }
            // The checksum is of what the source holds, so the part already copied is read again from the source.
            var position: Int64 = 0
            while position < offset {
                try Task.checkCancellation()
                let chunk = try input.chunk(at: position, upTo: min(chunkSize, Int(offset - position)))
                if chunk.isEmpty { break }
                hasher.update(chunk)
                position += Int64(chunk.count)
                advanced(Int64(chunk.count))
            }
            offset = position
            let output = Writer(path: partial, name: name, copy: self)
            defer { output.close() }
            try output.truncate(to: offset)
            while true {
                try Task.checkCancellation()
                let chunk = try input.chunk(at: offset, upTo: chunkSize)
                if chunk.isEmpty { break }
                try output.write(chunk, at: offset)
                hasher.update(chunk)
                offset += Int64(chunk.count)
                advanced(Int64(chunk.count))
            }
            try output.finish()
            let written = hasher.finish()

            var check = Checksum()
            let copyReader = Reader(path: partial, name: name, copy: self)
            defer { copyReader.close() }
            var read: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try copyReader.chunk(at: read, upTo: chunkSize)
                if chunk.isEmpty { break }
                check.update(chunk)
                read += Int64(chunk.count)
                advanced(Int64(chunk.count))
            }
            guard check.finish() == written, read == offset else {
                try? fm.removeItem(atPath: partial)
                if attempt == 0 { stalled("The copy of \(name) did not match; copying it again") }
                continue
            }
            // Keep the original's dates, which editing apps show and sort by.
            if let attributes = try? fm.attributesOfItem(atPath: source) {
                let dates = attributes.filter { $0.key == .modificationDate || $0.key == .creationDate }
                try? fm.setAttributes(dates, ofItemAtPath: partial)
            }
            do {
                if fm.fileExists(atPath: destination) { try fm.removeItem(atPath: destination) }
                try fm.moveItem(atPath: partial, toPath: destination)
            } catch {
                throw PackageError.cannotWrite("\(name): the finished copy could not be given its name. \(error.localizedDescription)")
            }
            return written
        }
        throw PackageError.copyDoesNotMatch(name)
    }

    // MARK: Trying again

    /// Runs `work`, and if it fails runs `recover` and tries again after each pause in turn.
    fileprivate func retrying<T>(_ what: String, name: String, path: String,
                                 recover: () -> Void, _ work: () throws -> T) throws -> T {
        var lastError: Error?
        for delay in [0] + retryDelays {
            if delay > 0 {
                try Task.checkCancellation()
                stalled("\(what) \(name) failed; trying again")
                Thread.sleep(forTimeInterval: delay)
                recover()
            }
            do {
                return try work()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        // Still failing because the card or share has gone: the clip waits for it to come back.
        if !FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent) {
            throw IngestVolumeOffline()
        }
        throw PackageError.cannotWrite("\(what) \(name) failed \(retryDelays.count + 1) times: \(lastError?.localizedDescription ?? "unknown error")")
    }

    private final class Reader {
        let path: String, name: String, copy: ResilientCopy
        var handle: FileHandle?

        init(path: String, name: String, copy: ResilientCopy) {
            self.path = path
            self.name = name
            self.copy = copy
        }

        func close() {
            try? handle?.close()
            handle = nil
        }

        func chunk(at offset: Int64, upTo count: Int) throws -> Data {
            try copy.retrying("Reading", name: name, path: path, recover: close) {
                if handle == nil {
                    guard let opened = FileHandle(forReadingAtPath: path) else {
                        throw PackageError.cannotWrite("\(name) could not be opened.")
                    }
                    handle = opened
                }
                try handle!.seek(toOffset: UInt64(offset))
                return try Self.autoreleased { try copy.read(handle!, count) }
            }
        }

        private static func autoreleased<T>(_ work: () throws -> T) rethrows -> T {
            #if os(macOS)
            return try autoreleasepool(invoking: work)
            #else
            return try work()
            #endif
        }
    }

    private final class Writer {
        let path: String, name: String, copy: ResilientCopy
        var handle: FileHandle?

        init(path: String, name: String, copy: ResilientCopy) {
            self.path = path
            self.name = name
            self.copy = copy
        }

        func close() {
            try? handle?.close()
            handle = nil
        }

        private func open() throws -> FileHandle {
            if let handle { return handle }
            guard let opened = FileHandle(forWritingAtPath: path) else {
                throw PackageError.cannotWrite("\(name) could not be opened on the destination.")
            }
            handle = opened
            return opened
        }

        func truncate(to offset: Int64) throws {
            try copy.retrying("Writing", name: name, path: path, recover: close) {
                try open().truncate(atOffset: UInt64(offset))
            }
        }

        func write(_ data: Data, at offset: Int64) throws {
            try copy.retrying("Writing", name: name, path: path, recover: close) {
                let handle = try open()
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
            }
        }

        /// Makes sure everything has reached the disk, not just the system's memory.
        func finish() throws {
            try copy.retrying("Writing", name: name, path: path, recover: close) {
                try open().synchronize()
            }
            close()
        }
    }

    static func size(of path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func freeSpace(at folder: String) -> Int64? {
        ((try? FileManager.default.attributesOfFileSystem(forPath: folder))?[.systemFreeSize] as? NSNumber)?.int64Value
    }
}
