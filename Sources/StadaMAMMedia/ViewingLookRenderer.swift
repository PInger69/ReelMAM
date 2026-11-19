#if os(macOS)
import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import StadaMAMCore

/// Shows a clip through a viewing look while it plays. The look is applied to each frame on its
/// way to the screen; the file is never changed.
public enum ViewingLookRenderer {
    /// Core Image's colour cube takes at most 64 steps a side; many `.cube` files have 65.
    public static let largestCube = 64

    /// A Core Image filter that puts a picture through a lookup table.
    public static func filter(for lut: ColorLUT) -> CIFilter? {
        var table = lut
        if table.size > largestCube {
            table = ColorLUT(title: lut.title, size: largestCube) { lut.sample($0, $1, $2) }
        }
        var rgba = [Float]()
        rgba.reserveCapacity(table.values.count / 3 * 4)
        for index in stride(from: 0, to: table.values.count, by: 3) {
            rgba += [table.values[index], table.values[index + 1], table.values[index + 2], 1]
        }
        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        filter.setValue(table.size, forKey: "inputCubeDimension")
        filter.setValue(rgba.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCubeData")
        return filter
    }

    /// Loads the table for a look. Nil for `.none`.
    public static func table(for look: ViewingLook) throws -> ColorLUT? {
        switch look {
        case .none: return nil
        case .conversion(let conversion): return ColorLUT(conversion: conversion)
        case .lut(let path): return try ColorLUT(cubeFileAtPath: path)
        }
    }

    /// A video composition that shows `asset` through a look.
    /// - Parameter looks: the table to use over each stretch of time. A whole clip is one entry
    ///   covering everything; a sequence has one per cut. Times with no entry are shown as they are.
    public static func videoComposition(for asset: AVAsset,
                                        looks: [(range: CMTimeRange, lut: ColorLUT)]) async throws -> AVVideoComposition {
        let stage = Stage(looks: looks.compactMap { entry in filter(for: entry.lut).map { (entry.range, $0) } })
        let composition = try await AVVideoComposition.videoComposition(with: asset) { request in
            stage.render(request)
        }
        // What comes out of a look is a Rec.709 picture, whatever the camera recorded.
        guard let tagged = composition.mutableCopy() as? AVMutableVideoComposition else { return composition }
        tagged.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        tagged.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        tagged.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return tagged
    }

    public static func videoComposition(for asset: AVAsset, lut: ColorLUT) async throws -> AVVideoComposition {
        try await videoComposition(for: asset, looks: [(CMTimeRange(start: .zero, duration: .positiveInfinity), lut)])
    }

    /// Applies the filters. Colour management is switched off so the table sees the camera's own
    /// code values, exactly as a LUT expects, and its output is taken as it is.
    private final class Stage: @unchecked Sendable {
        let looks: [(CMTimeRange, CIFilter)]
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let lock = NSLock()

        init(looks: [(CMTimeRange, CIFilter)]) { self.looks = looks }

        func render(_ request: AVAsynchronousCIImageFilteringRequest) {
            guard let filter = looks.first(where: { $0.0.containsTime(request.compositionTime) })?.1 else {
                request.finish(with: request.sourceImage, context: context)
                return
            }
            // A filter object holds its input, so one frame at a time goes through it.
            lock.lock()
            filter.setValue(request.sourceImage, forKey: kCIInputImageKey)
            let output = filter.outputImage
            filter.setValue(nil, forKey: kCIInputImageKey)
            lock.unlock()
            request.finish(with: output ?? request.sourceImage, context: context)
        }
    }

    // MARK: What a file says about its colour

    /// The colour tags of a file's picture track as "primaries/transfer/matrix/log", with "-" for
    /// a tag that is absent. The last part is the log identifier Apple writes for Apple Log
    /// footage ("com.apple.rec2020.apple-log", "com.apple.apple-wide-gamut.apple-log").
    public static func colorDescription(path: String) async -> String? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first else { return nil }
        return colorDescription(of: format)
    }

    static func colorDescription(of format: CMFormatDescription) -> String? {
        func tag(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
        }
        var parts = [tag(kCMFormatDescriptionExtension_ColorPrimaries), tag(kCMFormatDescriptionExtension_TransferFunction),
                     tag(kCMFormatDescriptionExtension_YCbCrMatrix)]
        if #available(macOS 14.2, *) {
            parts.append(tag(kCMFormatDescriptionExtension_LogTransferFunction))
        }
        guard parts.contains(where: { $0 != nil }) else { return nil }
        while parts.count > 3, parts.last! == nil { parts.removeLast() }
        return parts.map { $0 ?? "-" }.joined(separator: "/")
    }
}
#endif
