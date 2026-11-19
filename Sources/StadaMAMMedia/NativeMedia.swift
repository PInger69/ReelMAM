#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import StadaMAMCore
import UniformTypeIdentifiers

/// Media handling built directly on Apple's frameworks: AVFoundation to read and write,
/// VideoToolbox (through AVFoundation) to decode, scale and encode on the Apple Silicon
/// media engine. This is the app's primary path; nothing here launches an external tool.
public enum NativeMedia {
    /// Containers AVFoundation opens without extra components.
    public static func canOpen(path: String) -> Bool {
        ["mov", "mp4", "m4v", "qt"].contains((path as NSString).pathExtension.lowercased())
    }

    public struct Probe: Sendable {
        public var asset: Asset
        /// Catalog ID embedded in the file when it is one of our own proxies.
        public var embeddedAssetID: String?
    }

    // MARK: Probe

    /// Reads a clip's technical metadata. Returns nil when the file has no picture track.
    public static func probe(path: String) async throws -> Probe? {
        let url = URL(fileURLWithPath: path)
        let source = AVURLAsset(url: url)
        guard let video = try await source.loadTracks(withMediaType: .video).first,
              let format = try await video.load(.formatDescriptions).first else { return nil }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let fourCC = fourCharacterCode(CMFormatDescriptionGetMediaSubType(format))
        let minFrameDuration = try await video.load(.minFrameDuration)
        let nominalRate = try await video.load(.nominalFrameRate)
        let rate: FrameRate = minFrameDuration.isValid && minFrameDuration.value > 0
            ? .normalized(Int(minFrameDuration.timescale), Int(minFrameDuration.value))
            : FrameRate(fps: Double(nominalRate > 0 ? nominalRate : 24))
        // The picture track's own length: audio often runs a few samples longer than picture.
        let duration = try await video.load(.timeRange).duration.seconds

        let fieldCount = (CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_FieldCount) as? NSNumber)?.intValue ?? 1
        let aspect = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Any]
        let aspectH = (aspect?[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber)?.intValue ?? 1
        let aspectV = (aspect?[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber)?.intValue ?? 1

        var channels = 0
        for track in try await source.loadTracks(withMediaType: .audio) {
            for description in try await track.load(.formatDescriptions) {
                if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                    channels += Int(basic.pointee.mChannelsPerFrame)
                }
            }
        }

        let timecode = try await readTimecode(from: source)
        let codec = codecName(forFourCC: fourCC)
        let identity = FormatIdentity.identify(fileExtension: url.pathExtension, codec: codec, codecTag: fourCC)
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        let created = try? await source.load(.creationDate)?.load(.dateValue)

        // If AVFoundation says it can decode the picture, the native pipeline handles the clip
        // whatever the codec is called.
        let decodable = (try? await video.load(.isDecodable)) ?? false
        let asset = Asset(
            sourcePath: path, fileSize: size, decodePath: decodable ? .avFoundation : identity.decodePath,
            container: url.pathExtension.lowercased(), videoCodec: codec,
            width: Int(dimensions.width), height: Int(dimensions.height), frameRate: rate,
            durationFrames: duration.isFinite ? rate.frames(forSeconds: duration) : 0,
            startTimecodeFrames: timecode?.frame ?? 0, dropFrame: timecode?.dropFrame ?? false,
            reelName: timecode?.reelName, audioChannels: channels,
            // Colour tags, including Apple's log identifier, which the viewing look is chosen from.
            colorSpace: ViewingLookRenderer.colorDescription(of: format), formatName: identity.name,
            scan: fieldCount > 1 ? .interlacedTopFirst : .progressive,
            pixelAspect: (max(aspectH, 1), max(aspectV, 1)), capturedAt: created)

        var embeddedID: String?
        var items = (try? await source.load(.metadata)) ?? []
        for format in (try? await source.load(.availableMetadataFormats)) ?? [] {
            items += (try? await source.loadMetadata(for: format)) ?? []
        }
        for item in items where embeddedID == nil {
            let key = (item.key as? String) ?? ""
            let identifier = item.identifier?.rawValue ?? ""
            if key == ProxyMetadataKey.assetID || identifier.hasSuffix(ProxyMetadataKey.assetID) {
                embeddedID = try? await item.load(.stringValue)
            }
        }
        return Probe(asset: asset, embeddedAssetID: embeddedID)
    }

    private static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Maps a QuickTime codec code to the codec names used throughout the catalog.
    private static func codecName(forFourCC fourCC: String) -> String {
        switch fourCC {
        case "apco", "apcs", "apcn", "apch", "ap4h", "ap4x": return "prores"
        case "aprn", "aprh": return "prores_raw"
        case "avc1", "avc3": return "h264"
        case "hvc1", "hev1": return "hevc"
        case "jpeg", "mjpa", "mjpb": return "mjpeg"
        case "dvc ", "dvcp", "dvpp", "dv5n", "dv5p", "dvh5", "dvh6": return "dvvideo"
        default: return fourCC.lowercased()
        }
    }

    private struct TimecodeStart {
        var frame: Int
        var dropFrame: Bool
        var reelName: String?
    }

    /// Reads the start frame from the timecode track: its first sample is a big-endian frame number.
    private static func readTimecode(from source: AVURLAsset) async throws -> TimecodeStart? {
        guard let track = try await source.loadTracks(withMediaType: .timecode).first,
              let format = try await track.load(.formatDescriptions).first else { return nil }
        guard let frame = firstSampleValue(of: track) ?? firstSampleValueByReading(track, in: source) else { return nil }
        let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(format)
        let reference = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMTimeCodeFormatDescriptionExtension_SourceReferenceName) as? [String: Any]
        let reel = reference?[kCMTimeCodeFormatDescriptionKey_Value as String] as? String
        return TimecodeStart(frame: frame, dropFrame: flags & kCMTimeCodeFlag_DropFrame != 0,
                             reelName: reel?.isEmpty == false ? reel : nil)
    }

    /// Locates the first timecode sample in the file and reads its four bytes directly.
    private static func firstSampleValue(of track: AVAssetTrack) -> Int? {
        guard track.canProvideSampleCursors,
              let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder(),
              let url = cursor.currentChunkStorageURL else { return nil }
        let range = cursor.currentSampleStorageRange
        guard range.length >= 4, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(range.offset))) != nil,
              let data = try? handle.read(upToCount: 4), data.count == 4 else { return nil }
        let raw = data.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Int(Int32(bitPattern: raw))
    }

    /// The same value through an asset reader, for files that cannot provide sample cursors.
    private static func firstSampleValueByReading(_ track: AVAssetTrack, in source: AVURLAsset) -> Int? {
        guard let reader = try? AVAssetReader(asset: source) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(block) >= 4 else { continue }
            var raw: UInt32 = 0
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &raw) == kCMBlockBufferNoErr
            else { return nil }
            return Int(Int32(bitPattern: UInt32(bigEndian: raw)))
        }
        return nil
    }

    // MARK: Proxy rendering

    public enum RenderError: Error, LocalizedError {
        case noVideoTrack
        case cannotConfigure(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The source has no picture track."
            case .cannotConfigure(let what): return "The native renderer could not set up \(what)."
            case .failed(let why): return "The native render failed: \(why)"
            }
        }
    }

    /// Renders a proxy that is frame-for-frame interchangeable with its source: every source
    /// frame is decoded and re-encoded once, audio tracks keep their channel layout (uncompressed PCM, or AAC for the remote preset), and the source's timecode, reel name and catalog ID are written in.
    public static func renderProxy(_ plan: ProxyRenderPlan,
                                   progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = plan.asset
        let source = AVURLAsset(url: URL(fileURLWithPath: asset.sourcePath))
        guard let videoTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }
        let audioTracks = try await source.loadTracks(withMediaType: .audio)
        let sourceDuration = try await source.load(.duration)

        let outputURL = URL(fileURLWithPath: plan.outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)
        let reader = try AVAssetReader(asset: source)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        // Picture: decode to a format the encoder takes directly, so frames stay in video memory.
        let pixelFormat = plan.preset.isProRes
            ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw RenderError.cannotConfigure("picture decoding") }
        reader.add(videoOutput)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: plan.preset.isProRes ? AVVideoCodecType.proRes422Proxy
                : plan.preset.isHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: plan.outputWidth,
            AVVideoHeightKey: plan.outputHeight,
        ]
        if !plan.preset.isProRes {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: plan.preset.videoBitrate(width: plan.outputWidth, height: plan.outputHeight),
                // A short GOP without reordering keeps scrubbing responsive in the editing app.
                AVVideoMaxKeyFrameIntervalKey: max(asset.frameRate.nominal / 2, 1),
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        // Keep frame times exact: at the default timescale 23.976 fps rounds to 24.
        videoInput.mediaTimeScale = CMTimeScale(asset.frameRateNum)
        writer.movieTimeScale = CMTimeScale(asset.frameRateNum)
        guard writer.canAdd(videoInput) else { throw RenderError.cannotConfigure("picture encoding") }
        writer.add(videoInput)

        // Audio: one output track per source track, uncompressed, channels untouched.
        var audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in audioTracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            // Remote proxies compress mono and stereo tracks to AAC; the channel count never changes.
            var audioSettings: [String: Any]?
            if plan.preset.isForRemoteViewing,
               let description = try await track.load(.formatDescriptions).first,
               let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
               ProxyPreset.remoteCompressesAudio(channelsInTrack: Int(basic.mChannelsPerFrame)) {
                let channels = Int(basic.mChannelsPerFrame)
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
                audioSettings = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: channels,
                    AVSampleRateKey: 48_000,
                    AVEncoderBitRateKey: ProxyPreset.remoteAudioBitrate(channels: channels),
                    AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
                ]
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { continue }
            reader.add(output)
            writer.add(input)
            audioPairs.append((output, input))
        }

        // Timecode: a track holding the source's start frame, tied to the picture track.
        let timecodeInput = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil)
        let timecodeSample = try makeTimecodeSample(for: asset, duration: sourceDuration)
        let timecodeType = AVAssetTrack.AssociationType.timecode.rawValue
        if writer.canAdd(timecodeInput), videoInput.canAddTrackAssociation(withTrackOf: timecodeInput, type: timecodeType) {
            videoInput.addTrackAssociation(withTrackOf: timecodeInput, type: timecodeType)
            writer.add(timecodeInput)
        } else {
            throw RenderError.cannotConfigure("the timecode track")
        }

        writer.metadata = [
            metadataItem(ProxyMetadataKey.assetID, asset.id),
            metadataItem(ProxyMetadataKey.sourcePath, asset.sourcePath),
        ]

        guard reader.startReading() else {
            throw RenderError.failed(reader.error?.localizedDescription ?? "could not start reading")
        }
        guard writer.startWriting() else {
            throw RenderError.failed(writer.error?.localizedDescription ?? "could not start writing")
        }
        writer.startSession(atSourceTime: .zero)
        timecodeInput.append(timecodeSample)
        timecodeInput.markAsFinished()

        let total = max(sourceDuration.seconds, 0.001)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pump(from: videoOutput, to: videoInput, label: "picture") { sample in
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if time.isFinite { progress?(min(max(time / total, 0), 1)) }
                }
            }
            for (index, pair) in audioPairs.enumerated() {
                group.addTask { await pump(from: pair.0, to: pair.1, label: "audio-\(index)", onSample: nil) }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw RenderError.failed(reader.error?.localizedDescription ?? "reading stopped")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RenderError.failed(writer.error?.localizedDescription ?? "writing stopped")
        }
        progress?(1)
    }

    /// Moves samples from a reader output to a writer input as fast as the encoder accepts them.
    private static func pump(from output: AVAssetReaderOutput, to input: AVAssetWriterInput, label: String,
                             onSample: ((CMSampleBuffer) -> Void)?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.stadaxr.mam.render." + label)
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    onSample?(sample)
                }
            }
        }
    }

    private static func metadataItem(_ key: String, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = key as NSString
        item.value = value as NSString
        return item
    }

    /// Builds the single sample of a QuickTime timecode track: the start frame number.
    private static func makeTimecodeSample(for asset: Asset, duration: CMTime) throws -> CMSampleBuffer {
        var flags = kCMTimeCodeFlag_24HourMax
        if asset.dropFrame { flags |= kCMTimeCodeFlag_DropFrame }
        var extensions: [String: Any] = [:]
        if let reel = asset.reelName, !reel.isEmpty {
            extensions[kCMTimeCodeFormatDescriptionExtension_SourceReferenceName as String] = [
                kCMTimeCodeFormatDescriptionKey_Value as String: reel,
                kCMTimeCodeFormatDescriptionKey_LangCode as String: 0,
            ] as [String: Any]
        }
        var format: CMTimeCodeFormatDescription?
        let frameDuration = CMTime(value: CMTimeValue(asset.frameRateDen), timescale: CMTimeScale(asset.frameRateNum))
        var status = CMTimeCodeFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: frameDuration, frameQuanta: UInt32(asset.frameRate.nominal), flags: flags,
            extensions: extensions.isEmpty ? nil : extensions as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw RenderError.cannotConfigure("the timecode format") }

        var frameNumber = Int32(truncatingIfNeeded: asset.startTimecodeFrames).bigEndian
        var block: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { throw RenderError.cannotConfigure("the timecode sample") }
        status = CMBlockBufferReplaceDataBytes(with: &frameNumber, blockBuffer: block,
                                               offsetIntoDestination: 0, dataLength: 4)
        guard status == kCMBlockBufferNoErr else { throw RenderError.cannotConfigure("the timecode sample") }

        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw RenderError.cannotConfigure("the timecode sample") }
        return sample
    }

    // MARK: Thumbnails

    /// Writes evenly spaced JPEG frames for the poster and hover-scrub strip.
    public static func writeThumbnails(mediaPath: String, durationSeconds: Double, count: Int,
                                       height: Int = 270, to directory: String) async throws -> [String] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: mediaPath)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 4, height: height)
        let tolerance = CMTime(seconds: max(durationSeconds / Double(max(count, 1)) / 2, 0.05), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var paths: [String] = []
        for index in 0..<max(count, 1) {
            // Sample the middle of each slice so the first thumbnail is not a black lead-in frame.
            let seconds = durationSeconds * (Double(index) + 0.5) / Double(max(count, 1))
            guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            else { continue }
            let path = directory + "/" + String(format: "%03d.jpg", index)
            guard let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image,
                                       [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            if CGImageDestinationFinalize(destination) { paths.append(path) }
        }
        return paths
    }
}
#endif
