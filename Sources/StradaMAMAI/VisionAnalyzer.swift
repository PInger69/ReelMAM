#if canImport(Vision) && canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import Foundation
import StradaMAMCore
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
    /// - Parameters:
    ///   - sampleInterval: Seconds between sampled frames. By default it grows with the length of
    ///     the clip so a long camera roll is looked at about 600 times, not hundreds of thousands.
    ///   - labelThreshold: How sure the recogniser must be before a scene label is kept.
    ///   - rules: Corrections to apply to picture labels (hidden or reworded).
    public static func analyze(mediaURL: URL, asset: Asset, sampleInterval requestedInterval: Double? = nil,
                               labelThreshold: Double = 0.35, rules: [LabelRule] = [],
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> VisualAnalysis {
        let avAsset = AVURLAsset(url: mediaURL)
        let loaded = try await avAsset.load(.duration).seconds
        let duration = loaded.isFinite && loaded > 0 ? loaded : asset.durationSeconds
        let sampleInterval = requestedInterval ?? min(max(2, duration / 600), 30)
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

            let bigFaces = (detectFaces.results ?? []).filter { $0.boundingBox.width >= 0.03 }
            for animal in animals.results ?? [] {
                guard let best = animal.labels.first, best.confidence >= 0.5 else { continue }
                labels.append(FrameLabel(label: best.identifier.lowercased(), confidence: Double(best.confidence),
                                         timeSeconds: time))
            }
            // Framing and shot size, in the terms a camera department would use.
            let bodies = (humans.results ?? []).filter { $0.confidence >= 0.5 }
            if let framing = CinemaVocabulary.framing(headcount: max(bodies.count, bigFaces.count)) {
                labels.append(FrameLabel(label: framing, confidence: 1, timeSeconds: time))
            }
            if let largest = bigFaces.map({ $0.boundingBox.height }).max() {
                labels.append(FrameLabel(label: ShotScale.classify(largestFaceHeight: Double(largest)).rawValue,
                                         confidence: 1, timeSeconds: time))
            } else if let tallest = bodies.map({ $0.boundingBox.height }).max() {
                labels.append(FrameLabel(label: ShotScale.classify(tallestBodyHeight: Double(tallest)).rawValue,
                                         confidence: 0.7, timeSeconds: time))
            }

            var keptNames: Set<String> = []
            for observation in (classify.results ?? []).filter({ Double($0.confidence) >= labelThreshold }).prefix(6) {
                let name = observation.identifier.replacingOccurrences(of: "_", with: " ")
                keptNames.insert(name)
                labels.append(FrameLabel(label: name, confidence: Double(observation.confidence), timeSeconds: time))
            }
            // Instruments are kept even when small in frame or outranked by "person" and the room.
            let guesses = (classify.results ?? []).map { (label: $0.identifier, confidence: Double($0.confidence)) }
            for instrument in InstrumentVocabulary.extras(in: guesses, known: InstrumentVocabulary.picture, alreadyKept: keptNames,
                                                          minimumConfidence: min(labelThreshold, InstrumentVocabulary.pictureConfidence)) {
                labels.append(FrameLabel(label: instrument.label, confidence: instrument.confidence, timeSeconds: time))
            }
            for observation in readText.results ?? [] {
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5,
                      candidate.string.count >= 3 else { continue }
                texts.append(FrameLabel(label: candidate.string, confidence: Double(candidate.confidence),
                                        timeSeconds: time))
            }
            for face in bigFaces.sorted(by: { $0.boundingBox.width > $1.boundingBox.width }).prefix(4)
            where face.boundingBox.width >= 0.04 && faces.count < 240 {
                guard let embedding = faceEmbedding(in: image, box: face.boundingBox) else { continue }
                // The same face in neighbouring samples adds nothing to the catalogue but weight.
                let vector = FaceSighting.vector(from: embedding)
                if faces.suffix(6).contains(where: {
                    time - $0.timeSeconds < 20 && FaceClusterer.cosineSimilarity($0.vector, vector) >= 0.96
                }) { continue }
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
        return VisualAnalysis(tags: LabelRules.apply(rules, to: tags), faces: faces)
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
