import AVFoundation
import Observation
import StadaMAMCore

/// Frame-accurate transport: play, JKL shuttle, single-frame stepping, and mark in / out.
@MainActor
@Observable
final class PlayerController {
    let player = AVPlayer()
    private(set) var frameRate = FrameRate.fps24
    private(set) var durationFrames = 0
    private(set) var hasMedia = false
    private(set) var currentSeconds = 0.0
    private(set) var rate: Float = 0
    var inFrame: Int?
    var outFrame: Int?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var loadedPath: String?

    init() {
        player.actionAtItemEnd = .pause
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if time.seconds.isFinite { self.currentSeconds = time.seconds }
                self.rate = self.player.rate
            }
        }
    }

    /// Loads media for a clip. Marks are kept when the same clip is reloaded (e.g. once its proxy is ready).
    func load(path: String?, frameRate: FrameRate, durationFrames: Int) {
        self.frameRate = frameRate
        self.durationFrames = durationFrames
        guard path != loadedPath else { return }
        loadedPath = path
        hasMedia = path != nil
        let resumeAt = currentSeconds
        player.replaceCurrentItem(with: path.map { AVPlayerItem(url: URL(fileURLWithPath: $0)) })
        if resumeAt > 0 { seek(toSeconds: resumeAt) }
    }

    var currentFrame: Int { min(max(frameRate.frames(forSeconds: currentSeconds), 0), max(durationFrames - 1, 0)) }
    var durationSeconds: Double { frameRate.seconds(forFrames: durationFrames) }
    var isPlaying: Bool { rate != 0 }

    func seek(toSeconds seconds: Double) {
        let clamped = min(max(seconds, 0), max(durationSeconds, 0))
        currentSeconds = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 60_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(toFrame frame: Int) {
        // Aim at the middle of the frame so rounding never lands on the previous one.
        seek(toSeconds: frameRate.seconds(forFrames: frame) + 0.5 / frameRate.fps)
    }

    func step(frames: Int) {
        pause()
        seek(toFrame: min(max(currentFrame + frames, 0), max(durationFrames - 1, 0)))
    }

    func pause() {
        player.pause()
        rate = 0
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            if currentFrame >= durationFrames - 1 { seek(toSeconds: 0) }
            setRate(1)
        }
    }

    /// L: play forward, doubling speed on each press. J: the same in reverse.
    func shuttle(forward: Bool) {
        let direction: Float = forward ? 1 : -1
        let next: Float = rate * direction > 0 ? min(abs(rate) * 2, 8) * direction : direction
        setRate(next)
    }

    private func setRate(_ value: Float) {
        guard hasMedia else { return }
        player.rate = value
        rate = value
    }

    // MARK: Marks

    func markIn() {
        inFrame = currentFrame
        if let out = outFrame, out < currentFrame { outFrame = nil }
    }

    func markOut() {
        outFrame = currentFrame
        if let start = inFrame, start > currentFrame { inFrame = nil }
    }

    func clearMarks() {
        inFrame = nil
        outFrame = nil
    }

    func goToIn() {
        seek(toFrame: inFrame ?? 0)
    }

    func goToOut() {
        seek(toFrame: outFrame ?? max(durationFrames - 1, 0))
    }

    /// Number of frames in the marked range (out point inclusive), when both marks are set.
    var markedDurationFrames: Int? {
        guard let start = inFrame, let end = outFrame, end >= start else { return nil }
        return end - start + 1
    }
}
