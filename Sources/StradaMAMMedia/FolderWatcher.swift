import Foundation
#if os(macOS)
import CoreServices
#endif

/// Tells the engine a local folder changed, using FSEvents. Network shares do not deliver
/// reliable events, so the engine scans those on a timer instead.
public final class FolderWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: @Sendable () -> Void
    #if os(macOS)
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.stradaxr.mam.fsevents", qos: .utility)
    #endif

    public init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    /// Whether the folder is on a disk attached to this Mac (not a mounted share).
    public static func isLocalVolume(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal ?? false
    }

    public func start() {
        #if os(macOS)
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
        #endif
    }

    public func stop() {
        #if os(macOS)
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        #endif
    }

    deinit { stop() }
}
