import Foundation

/// A rational frame rate (e.g. 24000/1001 for 23.976).
public struct FrameRate: Codable, Hashable, Sendable {
    public var numerator: Int
    public var denominator: Int

    public init(_ numerator: Int, _ denominator: Int = 1) {
        self.numerator = max(numerator, 1)
        self.denominator = max(denominator, 1)
    }

    /// Parses "24000/1001", "25/1" or "29.97".
    public init?(string: String) {
        let parts = string.split(separator: "/")
        if parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), n > 0, d > 0 {
            self.init(n, d)
        } else if let value = Double(string), value > 0 {
            self.init(fps: value)
        } else {
            return nil
        }
    }

    /// Snaps a floating-point rate to the nearest standard rational rate.
    public init(fps: Double) {
        let ntsc: [(Double, Int)] = [(23.976, 24000), (29.97, 30000), (47.952, 48000), (59.94, 60000), (119.88, 120000)]
        if let match = ntsc.first(where: { abs($0.0 - fps) < 0.01 }) {
            self.init(match.1, 1001)
        } else {
            self.init(Int(fps.rounded()), 1)
        }
    }

    public static let fps23_976 = FrameRate(24000, 1001)
    public static let fps24 = FrameRate(24)
    public static let fps25 = FrameRate(25)
    public static let fps29_97 = FrameRate(30000, 1001)
    public static let fps30 = FrameRate(30)
    public static let fps50 = FrameRate(50)
    public static let fps59_94 = FrameRate(60000, 1001)
    public static let fps60 = FrameRate(60)

    public var fps: Double { Double(numerator) / Double(denominator) }

    /// The integer timecode base (24 for 23.976, 30 for 29.97, ...).
    public var nominal: Int { Int(fps.rounded()) }

    /// Drop-frame timecode exists for the NTSC rates that are multiples of 30: 29.97, 59.94, 119.88.
    public var supportsDropFrame: Bool { denominator == 1001 && nominal % 30 == 0 }

    public func seconds(forFrames frames: Int) -> Double {
        Double(frames) * Double(denominator) / Double(numerator)
    }

    public func frames(forSeconds seconds: Double) -> Int {
        Int((seconds * Double(numerator) / Double(denominator)).rounded())
    }
}

/// SMPTE timecode backed by an absolute frame count.
public struct Timecode: Hashable, Sendable, CustomStringConvertible {
    public var frames: Int
    public var rate: FrameRate
    public var dropFrame: Bool

    public init(frames: Int, rate: FrameRate, dropFrame: Bool = false) {
        self.frames = frames
        self.rate = rate
        self.dropFrame = dropFrame && rate.supportsDropFrame
    }

    /// Parses "HH:MM:SS:FF" or drop-frame "HH:MM:SS;FF".
    public init?(_ string: String, rate: FrameRate) {
        let isDrop = string.contains(";") && rate.supportsDropFrame
        let fields = string.split(whereSeparator: { $0 == ":" || $0 == ";" }).map { Int($0) }
        guard fields.count == 4, let h = fields[0], let m = fields[1], let s = fields[2], let f = fields[3],
              h >= 0, (0..<60).contains(m), (0..<60).contains(s), (0..<rate.nominal).contains(f)
        else { return nil }
        let base = rate.nominal
        var total = base * (h * 3600 + m * 60 + s) + f
        if isDrop {
            let drop = base / 15
            let totalMinutes = h * 60 + m
            total -= drop * (totalMinutes - totalMinutes / 10)
        }
        self.init(frames: total, rate: rate, dropFrame: isDrop)
    }

    public var description: String {
        let base = rate.nominal
        var f = max(frames, 0)
        if dropFrame {
            let drop = base / 15
            let framesPer10Min = base * 600 - drop * 9
            let framesPerMin = base * 60 - drop
            let tens = f / framesPer10Min
            let rem = f % framesPer10Min
            f += drop * 9 * tens
            if rem > drop { f += drop * ((rem - drop) / framesPerMin) }
        }
        let ff = f % base
        let ss = (f / base) % 60
        let mm = (f / (base * 60)) % 60
        let hh = f / (base * 3600)
        let pad = { (v: Int) in v < 10 ? "0\(v)" : "\(v)" }
        return "\(pad(hh)):\(pad(mm)):\(pad(ss))\(dropFrame ? ";" : ":")\(pad(ff))"
    }

    public func advanced(by frameCount: Int) -> Timecode {
        Timecode(frames: frames + frameCount, rate: rate, dropFrame: dropFrame)
    }
}
