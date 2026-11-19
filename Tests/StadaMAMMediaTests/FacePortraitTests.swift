#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import StadaMAMCore
@testable import StadaMAMMedia

/// The picture in the People list is really cut from the right place in the right frame.
@Suite(.enabled(if: FFmpegTools.locate() != nil))
struct FacePortraitTests {
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Draw so that the wanted pixel (counted from the top-left) lands on the one-pixel canvas.
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return bytes.prefix(3).map(Int.init)
    }

    @Test func cutsTheFaceOutOfTheFrameItWasSeenIn() async throws {
        let tools = FFmpegTools.locate()!
        let root = NSTemporaryDirectory() + "portrait-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let clip = root + "/clip.mov"
        // Black frame; a red "face" 80x80 at (400, 60) from the top-left appears only in the second half.
        try tools.run(tools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                                     "-i", "color=c=black:size=640x360:rate=24:duration=2",
                                     "-vf", "drawbox=x=400:y=60:w=80:h=80:color=red:t=fill:enable='gte(t,1)'",
                                     "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "1", "-crf", "10", clip])
        // The same box as the analysis stores it: normalised, counted up from the bottom.
        let sighting = FaceSighting(assetID: "a", timeSeconds: 1.5, x: 400.0 / 640, y: 1 - 140.0 / 360,
                                    width: 80.0 / 640, height: 80.0 / 360, embedding: Data())
        let out = root + "/People/face.jpg"
        #expect(await FacePortrait.write(mediaPath: clip, sighting: sighting, to: out, size: 160))
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: out) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 160 && image.height == 160)
        let centre = pixel(image, x: 80, y: 80)
        #expect(centre[0] > 180 && centre[1] < 70 && centre[2] < 70)     // the face fills the middle
        let corner = pixel(image, x: 6, y: 6)
        #expect(corner.allSatisfy { $0 < 50 })                           // with room around it

        // Before the face appears there is nothing red there: the time is honoured.
        let early = FaceSighting(assetID: "a", timeSeconds: 0.25, x: sighting.x, y: sighting.y,
                                 width: sighting.width, height: sighting.height, embedding: Data())
        #expect(await FacePortrait.write(mediaPath: clip, sighting: early, to: root + "/People/early.jpg"))
        let earlySource = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: root + "/People/early.jpg") as CFURL, nil))
        let earlyImage = try #require(CGImageSourceCreateImageAtIndex(earlySource, 0, nil))
        #expect(pixel(earlyImage, x: 80, y: 80).allSatisfy { $0 < 50 })
        // A clip that cannot be read gives no picture rather than a broken one.
        #expect(await FacePortrait.write(mediaPath: root + "/missing.mov", sighting: sighting, to: root + "/People/none.jpg") == false)
        #expect(!FileManager.default.fileExists(atPath: root + "/People/none.jpg"))
    }
}
#endif
