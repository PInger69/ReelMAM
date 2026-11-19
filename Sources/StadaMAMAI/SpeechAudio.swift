#if canImport(AVFoundation)
import AVFoundation
import Foundation
import StadaMAMCore

/// Reads a clip's sound the way a dialogue editor would: every track and channel, with the live
/// microphones picked out and the dead ones left behind.
///
/// Camera originals and production-sound files often carry several mono channels (boom, lavs,
/// a mixdown) on separate tracks or in one multichannel track. A plain "export the audio" call
/// keeps only the first two channels, which on a film set can be silent, so the speech
/// recogniser is fed nothing and invents a word or two. This reader never does that.
struct SpeechAudio: @unchecked Sendable {
    static let sampleRate = 16_000.0
    static let windowSeconds = 0.1

    struct Source: Hashable { var track: Int; var channel: Int }

    let asset: AVURLAsset
    let tracks: [AVAssetTrack]
    /// Live channels, summed to mono.
    let sources: [Source]
    /// Loudness of each 100 ms window across the live channels, 0...1.
    let levels: [Double]
    let duration: Double

    // MARK: Opening

    static func open(url: URL) async throws -> SpeechAudio {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AnalysisError.noAudio }

        // Pass 1: energy of every channel in every window.
        var perChannel: [Source: [Double]] = [:]
        let window = Int(sampleRate * windowSeconds)
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            // Running sums carry across buffers so every window is exactly 100 ms.
            var running: [Double] = []
            var filled = 0
            try read(asset: asset, track: track, range: nil) { samples, frames, channels in
                if running.count != channels { running = [Double](repeating: 0, count: channels) }
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        let value = Double(samples[frame * channels + channel])
                        running[channel] += value * value
                    }
                    filled += 1
                    if filled == window {
                        for channel in 0..<channels {
                            perChannel[Source(track: index, channel: channel), default: []].append(running[channel] / Double(window))
                            running[channel] = 0
                        }
                        filled = 0
                    }
                }
            }
            if filled > 0 {
                for channel in 0..<running.count {
                    perChannel[Source(track: index, channel: channel), default: []].append(running[channel] / Double(filled))
                }
            }
        }
        guard !perChannel.isEmpty else { throw AnalysisError.noAudio }

        // A channel is live when its overall level is within reach of the loudest one.
        func overall(_ energy: [Double]) -> Double {
            (energy.reduce(0, +) / Double(max(energy.count, 1))).squareRoot()
        }
        let loudest = perChannel.values.map(overall).max() ?? 0
        let chosen = perChannel
            .filter { overall($0.value) >= max(loudest * 0.35, 0.0005) }
            .sorted { overall($0.value.self) > overall($1.value.self) }
            .prefix(4)
            .map(\.key)
        let sources = chosen.isEmpty ? Array(perChannel.keys.prefix(1)) : Array(chosen)

        let windowCount = sources.compactMap { perChannel[$0]?.count }.max() ?? 0
        var levels = [Double](repeating: 0, count: windowCount)
        for source in sources {
            for (i, energy) in (perChannel[source] ?? []).enumerated() { levels[i] = max(levels[i], energy.squareRoot()) }
        }
        return SpeechAudio(asset: asset, tracks: tracks, sources: sources, levels: levels,
                           duration: Double(windowCount) * windowSeconds)
    }

    // MARK: Chunks

    /// Mono samples for a stretch of the clip, with the live channels summed and the level
    /// brought up to where a recogniser works best.
    func samples(from start: Double, to end: Double) throws -> [Float] {
        let count = max(Int((end - start) * Self.sampleRate), 0)
        var mix = [Float](repeating: 0, count: count)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: end - start, preferredTimescale: 600))
        let byTrack = Dictionary(grouping: sources, by: \.track)
        for (trackIndex, wanted) in byTrack {
            var offset = 0
            let channels = Set(wanted.map(\.channel))
            try Self.read(asset: asset, track: tracks[trackIndex], range: range) { buffer, frames, channelCount in
                let usable = min(frames, count - offset)
                guard usable > 0 else { return }
                for frame in 0..<usable {
                    var sum: Float = 0
                    for channel in channels where channel < channelCount { sum += buffer[frame * channelCount + channel] }
                    mix[offset + frame] += sum
                }
                offset += frames
            }
        }
        return Self.normalised(mix)
    }

    /// Brings quiet dialogue up to a steady level (without ever clipping) — set recordings of
    /// whispered or distant dialogue can be 40 dB down.
    static func normalised(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var peak: Float = 0, energy: Double = 0
        for value in samples {
            peak = max(peak, abs(value))
            energy += Double(value * value)
        }
        let rms = Float((energy / Double(samples.count)).squareRoot())
        guard rms > 1e-5 else { return samples }
        let gain = min(max(0.1 / rms, 1), 40, 0.9 / max(peak, 1e-6))
        guard gain > 1.05 else { return samples }
        return samples.map { $0 * gain }
    }

    /// Writes mono samples to a temporary file the recogniser and sound classifier can open.
    static func write(_ samples: [Float], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stradaxr-\(name)-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { throw AnalysisError.audioExportFailed }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    /// The whole clip as one mono file, for the sound classifier.
    func mixdownFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stradaxr-mix-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)
        else { throw AnalysisError.audioExportFailed }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var start = 0.0
        while start < duration {
            let end = min(start + 60, duration)
            let chunk = try samples(from: start, to: end)
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(chunk.count, 1))) {
                buffer.frameLength = AVAudioFrameCount(chunk.count)
                chunk.withUnsafeBufferPointer { source in
                    if let base = source.baseAddress { buffer.floatChannelData![0].update(from: base, count: chunk.count) }
                }
                try file.write(from: buffer)
            }
            start = end
        }
        return url
    }

    // MARK: Reading

    /// Streams a track as interleaved Float32 at 16 kHz, keeping every channel it has.
    static func read(asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange?,
                     body: (UnsafePointer<Float>, Int, Int) -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.audioExportFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.audioExportFailed }
        var scratch = [Float]()
        while let buffer = output.copyNextSampleBuffer() {
            guard let description = CMSampleBufferGetFormatDescription(buffer),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let channels = max(Int(stream.pointee.mChannelsPerFrame), 1)
            let length = CMBlockBufferGetDataLength(block)
            let floats = length / MemoryLayout<Float>.size
            if scratch.count < floats { scratch = [Float](repeating: 0, count: floats) }
            let status = scratch.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: floats * MemoryLayout<Float>.size,
                                           destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            scratch.withUnsafeBufferPointer { body($0.baseAddress!, floats / channels, channels) }
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.audioExportFailed }
    }
}
#endif
