#if canImport(Vision) && canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import Foundation
import StadaMAMCore
import Vision

/// Everything the visual pass learns about one clip.
public struct VisualAnalysis: Sendable {
    /// Shot ranges, scene / object labels and on-screen text, as time ranges.
    public var tags: [SceneTag]
    public var faces: [FaceSighting]
}

/// Samples frames through a clip and runs Apple's on-device Vision models on each:
/// scene classification, text recognition, face detection, and a feature print used for
/// shot-boundary detection and for grouping faces.
public enum VisionAnalyzer {
    public static func analyze(mediaURL: URL, asset: Asset, sampleInterval: Double = 2,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> VisualAnalysis {
        let avAsset = AVURLAsset(url: mediaURL)
        let loaded = try await avAsset.load(.duration).seconds
        let duration = loaded.isFinite && loaded > 0 ? loaded : asset.durationSeconds
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = CMTime(seconds: sampleInterval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: sampleInterval / 2, preferredTimescale: 600)

        var labels: [FrameLabel] = []
        var texts: [FrameLabel] = []
        var faces: [FaceSighting] = []
        var sampleTimes: [Double] = []
        var distances: [Double] = []
        var previousPrint: VNFeaturePrintObservation?

        let times = Array(stride(from: sampleInterval / 2, to: max(duration, sampleInterval), by: sampleInterval))
        for (index, time) in times.enumerated() {
            try Task.checkCancellation()
            progress?(Double(index) / Double(times.count))
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            else { continue }

            let classify = VNClassifyImageRequest()
            let readText = VNRecognizeTextRequest()
            readText.recognitionLevel = .fast
            let detectFaces = VNDetectFaceRectanglesRequest()
            let featurePrint = VNGenerateImageFeaturePrintRequest()
            let animals = VNRecognizeAnimalsRequest()
            let humans = VNDetectHumanRectanglesRequest()
            try VNImageRequestHandler(cgImage: image)
                .perform([classify, readText, detectFaces, featurePrint, animals, humans])

            for animal in animals.results ?? [] {
                guard let best = animal.labels.first, best.confidence >= 0.5 else { continue }
                labels.append(FrameLabel(label: best.identifier.lowercased(), confidence: Double(best.confidence),
                                         timeSeconds: time))
            }
            // How many people are in frame, in the terms a logger would use.
            let headcount = (humans.results ?? []).filter { $0.confidence >= 0.5 }.count
            if headcount > 0 {
                let label = headcount == 1 ? "one person" : headcount == 2 ? "two people"
                    : headcount <= 5 ? "small group" : "crowd"
                labels.append(FrameLabel(label: label, confidence: 1, timeSeconds: time))
            }

            for observation in (classify.results ?? []).filter({ $0.confidence >= 0.35 }).prefix(6) {
                labels.append(FrameLabel(label: observation.identifier.replacingOccurrences(of: "_", with: " "),
                                         confidence: Double(observation.confidence), timeSeconds: time))
            }
            for observation in readText.results ?? [] {
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5,
                      candidate.string.count >= 3 else { continue }
                texts.append(FrameLabel(label: candidate.string, confidence: Double(candidate.confidence),
                                        timeSeconds: time))
            }
            for face in detectFaces.results ?? [] where face.boundingBox.width >= 0.04 {
                guard let embedding = faceEmbedding(in: image, box: face.boundingBox) else { continue }
                faces.append(FaceSighting(
                    assetID: asset.id, timeSeconds: time,
                    x: face.boundingBox.minX, y: face.boundingBox.minY,
                    width: face.boundingBox.width, height: face.boundingBox.height, embedding: embedding))
            }
            if let current = featurePrint.results?.first {
                if let previous = previousPrint {
                    var distance: Float = 0
                    try previous.computeDistance(&distance, to: current)
                    distances.append(Double(distance))
                }
                previousPrint = current
                sampleTimes.append(time)
            }
        }
        progress?(1)

        let tags = TagBuilder.shots(assetID: asset.id, sampleTimes: sampleTimes, distances: distances,
                                    durationSeconds: duration)
            + TagBuilder.ranges(assetID: asset.id, kind: .label, samples: labels, sampleInterval: sampleInterval)
            + TagBuilder.ranges(assetID: asset.id, kind: .text, samples: texts, sampleInterval: sampleInterval)
        return VisualAnalysis(tags: tags, faces: faces)
    }

    /// Crops the face (with a little margin) and returns its feature print as Float32 data.
    private static func faceEmbedding(in image: CGImage, box: CGRect) -> Data? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        // Vision boxes are normalised with a bottom-left origin; CGImage cropping is top-left.
        let rect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                          width: box.width * width, height: box.height * height)
            .insetBy(dx: -box.width * width * 0.15, dy: -box.height * height * 0.15)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isEmpty, let crop = image.cropping(to: rect) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: crop).perform([request])) != nil,
              let observation = request.results?.first, observation.elementType == .float else { return nil }
        return observation.data
    }
}
#endif
