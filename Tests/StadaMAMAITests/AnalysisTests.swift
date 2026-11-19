import Foundation
import Testing
import StadaMAMCore
@testable import StadaMAMMedia
@testable import StadaMAMAI

@Suite struct ExternalHookTests {
    private func asset() -> Asset {
        Asset(sourcePath: "/Volumes/RAID/A001.mov", width: 3840, height: 2160, frameRate: .fps24,
              durationFrames: 240, reelName: "A001", formatName: "Apple ProRes 422")
    }

    @Test func requestDescribesTheClipButNeverPointsAtMedia() throws {
        let clip = asset()
        let body = ExternalAnalysisRequest(
            asset: clip,
            transcript: [TranscriptSegment(assetID: clip.id, startSeconds: 1, endSeconds: 3, text: "Hello harbour")],
            tags: [SceneTag(assetID: clip.id, kind: .label, label: "boat", confidence: 0.9, startSeconds: 0, endSeconds: 4),
                   SceneTag(assetID: clip.id, kind: .summary, label: "old summary", confidence: 1, startSeconds: 0, endSeconds: 10)])
        #expect(body.clip.durationSeconds == 10)
        #expect(body.transcript.map(\.text) == ["Hello harbour"])
        // Earlier hook output is not sent back to hooks.
        #expect(body.tags.map(\.label) == ["boat"])
        let json = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        #expect(!json.contains("/Volumes"))
        #expect(try JSONDecoder().decode(ExternalAnalysisRequest.self, from: Data(json.utf8)) == body)
    }

    @Test func replyBecomesClampedTags() throws {
        let reply = try JSONDecoder().decode(ExternalAnalysisResponse.self, from: Data("""
            {"summary": "  A boat leaves the harbour at dawn. ",
             "tags": [{"kind": "anything", "label": "sunrise", "start": -2, "end": 4, "confidence": 3},
                      {"kind": "x", "label": "  ", "start": 0, "end": 1},
                      {"kind": "x", "label": "gulls", "start": 8, "end": 99}]}
            """.utf8))
        let tags = reply.sceneTags(for: asset())
        #expect(tags.map(\.kind) == [.summary, .external, .external])
        #expect(tags[0].label == "A boat leaves the harbour at dawn.")
        #expect(tags[1].startSeconds == 0 && tags[1].endSeconds == 4 && tags[1].confidence == 1)
        #expect(tags[2].startSeconds == 8 && tags[2].endSeconds == 10)
        #expect(try JSONDecoder().decode(ExternalAnalysisResponse.self, from: Data("{}".utf8)).sceneTags(for: asset()).isEmpty)
    }

    @Test func onlySecureAddressesAreAccepted() throws {
        let body = ExternalAnalysisRequest(asset: asset(), transcript: [], tags: [])
        let good = try ExternalAnalysisClient.makeRequest(
            hook: AnalysisHook(name: "Tagger", url: " https://ai.example.com/analyse "), token: "secret", body: body)
        #expect(good.httpMethod == "POST")
        #expect(good.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(good.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(good.httpBody != nil)
        let local = try ExternalAnalysisClient.makeRequest(
            hook: AnalysisHook(url: "http://localhost:8080/hook"), token: nil, body: body)
        #expect(local.value(forHTTPHeaderField: "Authorization") == nil)
        for bad in ["http://ai.example.com/analyse", "ftp://x", "not a url", ""] {
            #expect(throws: ExternalAnalysisError.self) {
                try ExternalAnalysisClient.makeRequest(hook: AnalysisHook(url: bad), token: nil, body: body)
            }
        }
    }
}

#if os(macOS)
@Suite struct AppleAnalysisTests {
    @Test func namesInSpeechBecomeTags() {
        let segments = [
            TranscriptSegment(assetID: "a", startSeconds: 4, endSeconds: 8,
                              text: "Tim Cook flew from London to Paris to meet Angela Merkel."),
            TranscriptSegment(assetID: "a", startSeconds: 9, endSeconds: 12, text: "Nothing to see here."),
        ]
        let tags = TextAnalyzer.entities(in: segments, assetID: "a")
        let labels = Set(tags.map(\.label))
        #expect(labels.contains("Paris"))
        #expect(labels.contains("London"))
        #expect(tags.allSatisfy { $0.kind == .entity && $0.startSeconds == 4 })
        #expect(TextAnalyzer.dominantLanguage(of: "Bonjour tout le monde, comment allez-vous aujourd'hui ?") == "fr")
    }

    /// Runs the whole picture and sound pass on a real clip. The content is synthetic, so this
    /// checks that the analysers run and produce well-formed output, not what they recognise.
    @Test(.enabled(if: FFmpegTools.locate() != nil))
    func pictureAndSoundPassesRunOnAClip() async throws {
        let tools = try #require(FFmpegTools.locate())
        let path = NSTemporaryDirectory() + "stadamam-ai-\(UUID().uuidString).mov"
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Two visually different halves, so there is a cut to find, with a tone underneath.
        try tools.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "smptehdbars=size=1280x720:rate=24:duration=4",
            "-f", "lavfi", "-i", "mandelbrot=size=1280x720:rate=24:start_scale=0.5",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=8",
            "-filter_complex", "[1:v]trim=duration=4,setpts=PTS-STARTPTS[b];[0:v][b]concat=n=2:v=1:a=0[v]",
            "-map", "[v]", "-map", "2:a", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", path,
        ])
        let asset = Asset(sourcePath: path, width: 1280, height: 720, frameRate: .fps24, durationFrames: 192)
        let visual = try await VisionAnalyzer.analyze(mediaURL: URL(fileURLWithPath: path), asset: asset, sampleInterval: 1)
        let shots = visual.tags.filter { $0.kind == .shot }
        #expect(shots.count == 2)
        #expect(abs((shots.last?.startSeconds ?? 0) - 4) <= 1)
        #expect(visual.tags.allSatisfy { $0.endSeconds > $0.startSeconds && $0.endSeconds <= 9 })

        let sounds = try await SoundAnalyzer.classify(mediaURL: URL(fileURLWithPath: path), assetID: asset.id,
                                                      minimumConfidence: 0.2)
        #expect(sounds.allSatisfy { $0.kind == .sound && !$0.label.isEmpty })
    }
}
#endif
