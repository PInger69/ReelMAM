#if canImport(AVFoundation)
import AVFoundation
import XCTest
@testable import StadaMAMAI

/// Regression: dialogue recorded on a channel other than 1 or 2 used to reach the speech
/// recogniser as silence, which answered with a stray "thank you".
final class SpeechAudioTests: XCTestCase {
    func testDialogueOnTheFourthMicChannelIsHeard() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("four-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: layout)
        let frames = 48000 * 12
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![2][i] = 0.2 * sinf(Float(i) * 0.05) }   // only channel 3 is live
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)

        let audio = try await SpeechAudio.open(url: url)
        XCTAssertEqual(audio.sources.map(\.channel), [2], "only the live microphone is used")
        XCTAssertEqual(audio.duration, 12, accuracy: 0.3)
        let mean = audio.levels.reduce(0, +) / Double(audio.levels.count)
        XCTAssertGreaterThan(mean, 0.05)
        let samples = try audio.samples(from: 2, to: 8)
        XCTAssertEqual(samples.count, 96_000, accuracy: 200)
        let rms = (samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot()
        XCTAssertGreaterThan(rms, 0.05, "the dialogue channel reaches the recogniser")
    }
}
#endif
