#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import StradaMAMCore

/// A sequence made playable: its cuts joined end to end from whatever media can be played for
/// each clip (normally the proxy). Cuts only; each clip's own sound plays with its picture.
public struct SequencePlayback: @unchecked Sendable {
    public struct Segment: Sendable {
        public var cutID: String
        public var assetID: String
        public var start: CMTime
        public var duration: CMTime
        /// False when the clip has nothing playable (camera RAW with no proxy): the cut keeps its
        /// place and length, and plays as black.
        public var hasPicture: Bool

        public var range: CMTimeRange { CMTimeRange(start: start, duration: duration) }
    }

    public let composition: AVComposition
    public let segments: [Segment]

    public var duration: CMTime { segments.last.map { $0.start + $0.duration } ?? .zero }

    /// The cut playing at a time, and how many source frames into it.
    public func position(at time: CMTime, in sequence: ResolvedSequence) -> (index: Int, sourceFrame: Int)? {
        guard !segments.isEmpty else { return nil }
        let index = segments.firstIndex { time < $0.start + $0.duration } ?? segments.count - 1
        guard index < sequence.cuts.count else { return nil }
        let placed = sequence.cuts[index]
        let into = max((time - segments[index].start).seconds, 0)
        let frame = min(Int(into * placed.asset.frameRate.fps + 0.0001), placed.cut.durationFrames - 1)
        return (index, placed.cut.inFrame + max(frame, 0))
    }

    /// - Parameter mediaPath: the playable file for a clip, or nil when there is none.
    public static func build(_ sequence: ResolvedSequence, mediaPath: (Asset) -> String?) async throws -> SequencePlayback {
        let composition = AVMutableComposition()
        var videoTrack: AVMutableCompositionTrack?
        var audioTracks: [AVMutableCompositionTrack] = []
        var segments: [Segment] = []
        var sources: [String: AVURLAsset] = [:]
        var cursor = CMTime.zero

        for placed in sequence.cuts {
            let asset = placed.asset
            let scale = CMTimeScale(asset.frameRateNum)
            let start = CMTime(value: CMTimeValue(placed.cut.inFrame * asset.frameRateDen), timescale: scale)
            var length = CMTime(value: CMTimeValue(placed.cut.durationFrames * asset.frameRateDen), timescale: scale)
            var hasPicture = false

            if let path = mediaPath(asset) {
                let source = sources[path] ?? AVURLAsset(url: URL(fileURLWithPath: path))
                sources[path] = source
                if let picture = try await source.loadTracksOnce(withMediaType: .video).first {
                    // Never ask for more than the file holds.
                    let available = try await picture.load(.timeRange)
                    let wanted = CMTimeRange(start: start, duration: length).intersection(available)
                    if wanted.duration > .zero {
                        if videoTrack == nil {
                            videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                        }
                        try videoTrack?.insertTimeRange(wanted, of: picture, at: cursor)
                        length = wanted.duration
                        hasPicture = true
                        for (index, sound) in try await source.loadTracksOnce(withMediaType: .audio).enumerated() {
                            while audioTracks.count <= index {
                                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                                else { break }
                                audioTracks.append(track)
                            }
                            guard index < audioTracks.count else { continue }
                            let range = wanted.intersection(try await sound.load(.timeRange))
                            if range.duration > .zero { try? audioTracks[index].insertTimeRange(range, of: sound, at: cursor) }
                        }
                    }
                }
            }
            segments.append(Segment(cutID: placed.cut.id, assetID: asset.id, start: cursor, duration: length, hasPicture: hasPicture))
            cursor = cursor + length
        }
        return SequencePlayback(composition: composition, segments: segments)
    }
}
#endif
