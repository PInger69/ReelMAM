#if os(macOS)
import AVFoundation
import Foundation

extension AVAsset {
    /// Loads an asset's tracks of one kind, tolerating AVFoundation answering more than once.
    ///
    /// After a video composition has been built for an asset, a later request for that asset's
    /// tracks can have its completion handler called twice. The system's own `async` version
    /// resumes its continuation on each call, and the second resume crashes the process; this
    /// version listens only to the first answer.
    public func loadTracksOnce(withMediaType type: AVMediaType) async throws -> [AVAssetTrack] {
        let gate = FirstAnswerGate()
        return try await withCheckedThrowingContinuation { continuation in
            loadTracks(withMediaType: type) { tracks, error in
                guard gate.claim() else { return }
                if let tracks {
                    continuation.resume(returning: tracks)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}

/// Lets exactly one caller through.
private final class FirstAnswerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if answered { return false }
        answered = true
        return true
    }
}
#endif
