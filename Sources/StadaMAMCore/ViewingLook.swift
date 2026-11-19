import Foundation
import GRDB

/// A built-in conversion from a camera's log picture to Rec.709 for viewing.
///
/// These are viewing looks made from the published definition of each log format, not the camera
/// maker's own LUT: they show a normal-looking picture, they are not a grade. Load the maker's
/// `.cube` file instead when an exact match to another tool matters.
public enum LookConversion: String, Codable, CaseIterable, Sendable {
    /// Apple Log (iPhone 15 Pro and later): Rec.2020 primaries.
    case appleLog
    /// Apple Log 2 (iPhone 17 Pro and later): the same curve with Apple Wide Gamut primaries.
    case appleLog2

    public var displayName: String {
        switch self {
        case .appleLog: return "Apple Log to Rec.709"
        case .appleLog2: return "Apple Log 2 to Rec.709"
        }
    }

    /// Chooses a conversion from what the file says about itself: the log identifier Apple writes
    /// into the picture track ("com.apple.rec2020.apple-log", "com.apple.apple-wide-gamut.apple-log"),
    /// as recorded in `Asset.colorSpace`. Nil when the clip does not declare a known log format.
    public static func detect(colorSpace: String?) -> LookConversion? {
        guard let text = colorSpace?.lowercased() else { return nil }
        if text.contains("apple-wide-gamut.apple-log") || text.contains("applelog2") { return .appleLog2 }
        if text.contains("apple-log") || text.contains("applelog") { return .appleLog }
        return nil
    }
}

/// What a clip is shown through.
public enum ViewingLook: Hashable, Sendable {
    /// The picture as it is in the file.
    case none
    case conversion(LookConversion)
    /// A `.cube` file on this Mac.
    case lut(path: String)

    public var displayName: String {
        switch self {
        case .none: return "No look"
        case .conversion(let conversion): return conversion.displayName
        case .lut(let path): return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
    }
}

/// A person's choice of look for one clip. Without one, the look is chosen from the clip's metadata.
public struct ClipLook: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "clipLook"
    public enum Mode: String, Codable, Sendable { case off, conversion, lut }

    public var assetID: String
    public var mode: Mode
    public var conversion: LookConversion?
    public var lutPath: String?

    public init(assetID: String, look: ViewingLook) {
        self.assetID = assetID
        switch look {
        case .none: mode = .off
        case .conversion(let conversion): mode = .conversion; self.conversion = conversion
        case .lut(let path): mode = .lut; lutPath = path
        }
    }

    public var look: ViewingLook {
        switch mode {
        case .off: return .none
        case .conversion: return conversion.map(ViewingLook.conversion) ?? .none
        case .lut: return lutPath.map { ViewingLook.lut(path: $0) } ?? .none
        }
    }
}

extension Catalog {
    /// The look chosen by hand for a clip, if any.
    public func clipLook(forAsset assetID: String) throws -> ClipLook? {
        try db.read { try ClipLook.fetchOne($0, key: assetID) }
    }

    /// Sets a clip's look by hand; nil goes back to choosing from the clip's metadata.
    public func setClipLook(_ look: ViewingLook?, forAsset assetID: String) throws {
        try db.write { db in
            if let look {
                try ClipLook(assetID: assetID, look: look).save(db)
            } else {
                _ = try ClipLook.deleteOne(db, key: assetID)
            }
        }
    }

    /// The look a clip is shown through: the hand-made choice, else what its metadata calls for.
    public func viewingLook(for asset: Asset) throws -> ViewingLook {
        if let chosen = try clipLook(forAsset: asset.id) { return chosen.look }
        return LookConversion.detect(colorSpace: asset.colorSpace).map(ViewingLook.conversion) ?? .none
    }

    /// Every `.cube` file already in use on some clip, for offering again.
    public func lutPathsInUse() throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT DISTINCT lutPath FROM clipLook WHERE lutPath IS NOT NULL ORDER BY lutPath") }
    }
}

public enum LUTError: Error, LocalizedError, Equatable {
    case notA3DLUT
    case wrongEntryCount(expected: Int, found: Int)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notA3DLUT:
            return "This file has no 3D LUT in it. Only 3D .cube files can be used as a viewing look."
        case .wrongEntryCount(let expected, let found):
            return "The LUT is damaged: it should hold \(expected) colours but holds \(found)."
        case .unreadable(let why):
            return "The LUT could not be read: \(why)"
        }
    }
}

/// A 3D colour lookup table: `size` steps along each of red, green and blue, red changing fastest
/// (the order of a `.cube` file and of Core Image's colour cube). Input and output are 0 to 1.
public struct ColorLUT: Hashable, Sendable {
    public var title: String
    public var size: Int
    /// `size³` colours, three numbers each.
    public var values: [Float]

    public init(title: String = "", size: Int, values: [Float]) {
        self.title = title
        self.size = size
        self.values = values
    }

    /// Builds a table by asking for the colour at every grid point.
    public init(title: String = "", size: Int = 33, _ transform: (Double, Double, Double) -> (Double, Double, Double)) {
        var values: [Float] = []
        values.reserveCapacity(size * size * size * 3)
        let top = Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let out = transform(Double(r) / top, Double(g) / top, Double(b) / top)
                    values += [Float(out.0), Float(out.1), Float(out.2)]
                }
            }
        }
        self.init(title: title, size: size, values: values)
    }

    /// A table that changes nothing.
    public static func identity(size: Int = 17) -> ColorLUT {
        ColorLUT(title: "Identity", size: size) { ($0, $1, $2) }
    }

    /// The colour for an input, blending between the eight nearest grid points.
    public func sample(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let top = Double(size - 1)
        func split(_ value: Double) -> (Int, Double) {
            let scaled = min(max(value, 0), 1) * top
            let low = min(Int(scaled), size - 2)
            return (low, scaled - Double(low))
        }
        let (r0, rf) = split(r), (g0, gf) = split(g), (b0, bf) = split(b)
        var out = [0.0, 0.0, 0.0]
        for (db, wb) in [(0, 1 - bf), (1, bf)] {
            for (dg, wg) in [(0, 1 - gf), (1, gf)] {
                for (dr, wr) in [(0, 1 - rf), (1, rf)] {
                    let index = (((b0 + db) * size + g0 + dg) * size + r0 + dr) * 3
                    let weight = wb * wg * wr
                    for channel in 0..<3 { out[channel] += Double(values[index + channel]) * weight }
                }
            }
        }
        return (out[0], out[1], out[2])
    }

    // MARK: .cube files

    /// Reads an Adobe / Resolve `.cube` file. A file whose input range is not 0 to 1 is resampled.
    public init(cubeText text: String) throws {
        var title = ""
        var size = 0
        var has1D = false
        var low = [0.0, 0.0, 0.0], high = [1.0, 1.0, 1.0]
        var values: [Float] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let keyword = parts[0].uppercased()
            let numbers = parts.dropFirst().compactMap { Double($0) }
            switch keyword {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            case "LUT_3D_SIZE":
                size = Int(numbers.first ?? 0)
                values.reserveCapacity(size * size * size * 3)
            case "LUT_1D_SIZE":
                has1D = true
            case "DOMAIN_MIN" where numbers.count == 3:
                low = numbers
            case "DOMAIN_MAX" where numbers.count == 3:
                high = numbers
            case "LUT_3D_INPUT_RANGE" where numbers.count == 2:
                low = [numbers[0], numbers[0], numbers[0]]
                high = [numbers[1], numbers[1], numbers[1]]
            default:
                let row = parts.compactMap { Float($0) }
                if row.count == 3, parts.count == 3 { values += row }
            }
        }
        guard size >= 2, size <= 256 else { throw has1D ? LUTError.notA3DLUT : LUTError.unreadable("no LUT_3D_SIZE line") }
        guard values.count == size * size * size * 3 else {
            throw LUTError.wrongEntryCount(expected: size * size * size, found: values.count / 3)
        }
        let table = ColorLUT(title: title, size: size, values: values)
        if low == [0, 0, 0], high == [1, 1, 1] {
            self = table
        } else {
            // The table covers `low...high`; rebuild it over 0...1 so every renderer can use it.
            self = ColorLUT(title: title, size: size) { r, g, b in
                func place(_ value: Double, _ channel: Int) -> Double {
                    let span = high[channel] - low[channel]
                    return span == 0 ? 0 : (value - low[channel]) / span
                }
                return table.sample(place(r, 0), place(g, 1), place(b, 2))
            }
        }
    }

    public init(cubeFileAtPath path: String) throws {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LUTError.unreadable("\((path as NSString).lastPathComponent) is not there any more.")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw LUTError.unreadable("it is not a text file.")
        }
        try self.init(cubeText: text)
        if title.isEmpty { title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    }

    /// The table as `.cube` text, so a built-in conversion can be used in other tools.
    public var cubeText: String {
        var lines = ["TITLE \"\(title)\"", "LUT_3D_SIZE \(size)", ""]
        for index in stride(from: 0, to: values.count, by: 3) {
            lines.append(String(format: "%.6f %.6f %.6f", values[index], values[index + 1], values[index + 2]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Built-in conversions

    public init(conversion: LookConversion, size: Int = 33) {
        let toRec709: [[Double]]
        switch conversion {
        case .appleLog: toRec709 = ColorMath.matrix(from: ColorMath.rec2020, to: ColorMath.rec709)
        case .appleLog2: toRec709 = ColorMath.matrix(from: ColorMath.appleWideGamut, to: ColorMath.rec709)
        }
        self.init(title: conversion.displayName, size: size) { r, g, b in
            let linear = [ColorMath.appleLogToLinear(r), ColorMath.appleLogToLinear(g), ColorMath.appleLogToLinear(b)]
            let display = ColorMath.intoGamut(ColorMath.apply(toRec709, linear)).map {
                ColorMath.rec709Encode(ColorMath.toneMap($0))
            }
            return (display[0], display[1], display[2])
        }
    }
}

/// The arithmetic behind the built-in conversions.
enum ColorMath {
    struct Primaries {
        var red: (Double, Double), green: (Double, Double), blue: (Double, Double)
        var white: (Double, Double) = (0.3127, 0.3290)  // D65
    }

    static let rec709 = Primaries(red: (0.640, 0.330), green: (0.300, 0.600), blue: (0.150, 0.060))
    static let rec2020 = Primaries(red: (0.708, 0.292), green: (0.170, 0.797), blue: (0.131, 0.046))
    /// Apple Wide Gamut, from Apple's Apple Log 2 profile.
    static let appleWideGamut = Primaries(red: (0.725, 0.301), green: (0.221, 0.814), blue: (0.068, -0.076))

    /// Apple Log code value (0...1) to scene-linear light, where 0.18 is mid-grey.
    /// Constants from Apple's Apple Log Profile White Paper.
    static func appleLogToLinear(_ p: Double) -> Double {
        let r0 = -0.05641088, rt = 0.01, c = 47.28711236, beta = 0.00964052, gamma = 0.08550479, delta = 0.69336945
        let pt = c * (rt - r0) * (rt - r0)
        if p >= pt { return pow(2, (p - delta) / gamma) - beta }
        if p >= 0 { return (p / c).squareRoot() + r0 }
        return r0
    }

    static func linearToAppleLog(_ r: Double) -> Double {
        let r0 = -0.05641088, rt = 0.01, c = 47.28711236, beta = 0.00964052, gamma = 0.08550479, delta = 0.69336945
        if r >= rt { return gamma * log2(r + beta) + delta }
        if r >= r0 { return c * (r - r0) * (r - r0) }
        return 0
    }

    /// Brings scene light (mid-grey 0.18, highlights up to about 12) into 0...1 for a display,
    /// rolling the highlights off instead of clipping them.
    static func toneMap(_ value: Double) -> Double {
        let x = max(value, 0), white = 12.0
        return min(x * (1 + x / (white * white)) / (1 + x), 1)
    }

    /// Display light to a Rec.709 video level, for a gamma 2.4 display (BT.1886).
    static func rec709Encode(_ value: Double) -> Double {
        pow(min(max(value, 0), 1), 1 / 2.4)
    }

    /// Colours outside Rec.709 come out of the matrix with a negative part. They are pulled toward
    /// grey just far enough to fit, which keeps their hue instead of clipping it.
    static func intoGamut(_ rgb: [Double]) -> [Double] {
        let lowest = rgb.min() ?? 0
        guard lowest < 0 else { return rgb }
        let luma = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
        guard luma > 0 else { return rgb.map { max($0, 0) } }
        let keep = luma / (luma - lowest)
        return rgb.map { luma + ($0 - luma) * keep }
    }

    static func apply(_ m: [[Double]], _ v: [Double]) -> [Double] {
        m.map { $0[0] * v[0] + $0[1] * v[1] + $0[2] * v[2] }
    }

    static func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
    }

    static func inverse(_ m: [[Double]]) -> [[Double]] {
        let a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2], g = m[2][0], h = m[2][1], i = m[2][2]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
                [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
                [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]
    }

    /// The matrix taking linear RGB with these primaries to CIE XYZ.
    static func toXYZ(_ p: Primaries) -> [[Double]] {
        func xyz(_ xy: (Double, Double)) -> [Double] { [xy.0 / xy.1, 1, (1 - xy.0 - xy.1) / xy.1] }
        let r = xyz(p.red), g = xyz(p.green), b = xyz(p.blue), w = xyz(p.white)
        let columns = [[r[0], g[0], b[0]], [r[1], g[1], b[1]], [r[2], g[2], b[2]]]
        let scale = apply(inverse(columns), w)
        return columns.map { [$0[0] * scale[0], $0[1] * scale[1], $0[2] * scale[2]] }
    }

    /// Linear RGB in one set of primaries to linear RGB in another (both D65, so no adaptation).
    static func matrix(from source: Primaries, to target: Primaries) -> [[Double]] {
        multiply(inverse(toXYZ(target)), toXYZ(source))
    }
}
