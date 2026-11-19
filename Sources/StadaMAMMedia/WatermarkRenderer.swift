import Foundation
import StadaMAMCore
#if os(macOS)
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Draws the transparent overlay that carries the production's mark in the lower-left quarter
/// of the picture: inside that quarter, anchored to its bottom-left corner with a margin.
public enum WatermarkImage {
    /// Fraction of the frame left empty at the left and bottom edges.
    public static let marginX = 0.04, marginY = 0.05

    public static func write(text: String, width: Int, height: Int, to path: String) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaError.ffmpegFailed("could not create the watermark image")
        }
        func line(size: CGFloat, alpha: CGFloat, gray: CGFloat) -> CTLine {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: gray, alpha: alpha),
            ]
            return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
        }
        // Big enough to read, small enough to sit well inside the quarter.
        var size = max(CGFloat(height) / 12, 12)
        let quarterWidth = CGFloat(width) / 2
        let probe = CTLineGetBoundsWithOptions(line(size: size, alpha: 1, gray: 1), [])
        let available = quarterWidth - CGFloat(width) * marginX
        if probe.width > available * 0.9 { size *= available * 0.9 / probe.width }
        let light = line(size: size, alpha: 0.55, gray: 1), dark = line(size: size, alpha: 0.35, gray: 0)
        let x = CGFloat(width) * marginX, y = CGFloat(height) * marginY   // origin is bottom-left
        context.textPosition = CGPoint(x: x + 1.5, y: y - 1.5); CTLineDraw(dark, context)
        context.textPosition = CGPoint(x: x, y: y); CTLineDraw(light, context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil) else {
            throw MediaError.ffmpegFailed("could not save the watermark image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MediaError.ffmpegFailed("could not save the watermark image") }
    }
}

/// Makes the marked copy of each proxy in the background and keeps it in a cache folder. A copy is only ever published after it has been checked
/// against the source the same way every proxy is, so Find Source and the editing apps relink
/// it like any other proxy.
public final class WatermarkRenderer: ProxyWatermarker, @unchecked Sendable {
    private let tools: FFmpegTools
    private let cacheRoot: String
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var running = Set<String>()
    private var failures: [String: (message: String, at: Date)] = [:]
    /// Try the media engine first; software when the hardware encoder refuses.
    public var useHardware = true
    public var retryFailedAfter: TimeInterval = 60

    public init(tools: FFmpegTools, cacheRoot: String, concurrentRenders: Int = 2) {
        self.tools = tools
        self.cacheRoot = cacheRoot
        queue.maxConcurrentOperationCount = max(concurrentRenders, 1)
        queue.qualityOfService = .utility
    }

    public func outputPath(for proxy: ProxyRecord) -> String { "\(cacheRoot)/\(proxy.id).mov" }

    public func state(for proxy: ProxyRecord, asset: Asset) -> WatermarkState {
        let output = outputPath(for: proxy)
        let fm = FileManager.default
        let proxyDate = (try? fm.attributesOfItem(atPath: proxy.path)[.modificationDate] as? Date) ?? nil
        lock.lock(); defer { lock.unlock() }
        if running.contains(output) { return .preparing }
        // A copy older than its proxy is stale (the proxy was re-rendered).
        if let made = (try? fm.attributesOfItem(atPath: output)[.modificationDate] as? Date) ?? nil,
           proxyDate.map({ made >= $0 }) ?? true {
            return .ready(path: output)
        }
        if let failure = failures[output], Date().timeIntervalSince(failure.at) < retryFailedAfter {
            return .failed(failure.message)
        }
        failures[output] = nil
        running.insert(output)
        queue.addOperation { [self] in
            let result = Result { try render(proxy: proxy, asset: asset, output: output) }
            lock.lock()
            running.remove(output)
            if case .failure(let error) = result { failures[output] = (error.localizedDescription, Date()) }
            lock.unlock()
        }
        return .preparing
    }

    private func render(proxy: ProxyRecord, asset: Asset, output: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (output as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let probe = try tools.probe(path: proxy.path)
        guard let seen = probe.asset(path: proxy.path) else { throw MediaError.ffmpegFailed("could not read the proxy") }
        let overlay = NSTemporaryDirectory() + "wm-\(UUID().uuidString).png"
        let partial = output + ".partial"
        defer { try? fm.removeItem(atPath: overlay); try? fm.removeItem(atPath: partial) }
        try WatermarkImage.write(text: Watermark.text, width: seen.width, height: seen.height, to: overlay)

        func attempt(hardware: Bool) throws {
            try? fm.removeItem(atPath: partial)
            let plan = WatermarkRenderPlan(asset: asset, proxyPath: proxy.path, overlayPath: overlay, outputPath: partial,
                                           width: seen.width, height: seen.height, hardware: hardware)
            try tools.run(tools.ffmpeg, plan.ffmpegArguments)
        }
        do {
            if useHardware { try attempt(hardware: true) } else { try attempt(hardware: false) }
        } catch where useHardware {
            try attempt(hardware: false)
        }
        // Same check every proxy gets: it must still match the source frame for frame.
        let made = try tools.probe(path: partial)
        guard let result = made.asset(path: partial) else { throw MediaError.ffmpegFailed("could not read the marked copy") }
        if let problem = ProxyVerifier.mismatch(source: asset, proxy: result) { throw MediaError.ffmpegFailed(problem) }
        try? fm.removeItem(atPath: output)
        try fm.moveItem(atPath: partial, toPath: output)
    }
}
#endif
