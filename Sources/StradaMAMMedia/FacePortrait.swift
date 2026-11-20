#if os(macOS)
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import StradaMAMCore
import UniformTypeIdentifiers

/// A small picture of a person's face, cut from the frame they were seen in, for the People list.
public enum FacePortrait {
    /// Writes the portrait for `sighting` to `path` as a JPEG and returns whether it did.
    /// `mediaPath` is whatever can be played for the clip: its proxy, or the original.
    @discardableResult
    public static func write(mediaPath: String, sighting: FaceSighting, to path: String, size: Int = 160) async -> Bool {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: mediaPath)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        // Close to the analysed frame, without paying for an exact decode on long-GOP proxies.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        guard let frame = try? await generator.image(at: CMTime(seconds: sighting.timeSeconds, preferredTimescale: 600)).image
        else { return false }
        let rect = sighting.portraitRect(imageWidth: frame.width, imageHeight: frame.height)
        guard let face = frame.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.side, height: rect.side)),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        context.interpolationQuality = .high
        context.draw(face, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage() else { return false }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
#endif
