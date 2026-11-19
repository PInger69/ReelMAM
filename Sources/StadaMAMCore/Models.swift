import Foundation
import GRDB

public func newID() -> String { UUID().uuidString }

/// How a file's essence gets decoded.
public enum DecodePath: String, Codable, Sendable {
    /// Decodable by AVFoundation / VideoToolbox (ProRes, H.264, HEVC, ProRes RAW ...).
    case avFoundation
    /// Blackmagic RAW; requires the Blackmagic RAW SDK.
    case blackmagicRAW
    /// Everything FFmpeg can read (MXF, MKV, DNxHR, XAVC, MPEG-2 transport streams ...).
    case ffmpeg
    /// Identified and catalogued, but no decoder is available yet (e.g. Sony X-OCN, ARRIRAW,
    /// REDCODE). Searchable and relinkable; playback and proxies need the vendor's SDK.
    case unsupported

    public var canRender: Bool { self == .avFoundation || self == .ffmpeg }
}

/// A catalogued high-resolution source clip.
public struct Asset: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "asset"

    public var id: String
    public var sourcePath: String
    public var fileName: String
    public var volumeName: String?
    public var fileSize: Int64
    /// Security-scoped bookmark so the source can be found again after it moves or the volume remounts.
    public var bookmark: Data?
    public var decodePath: DecodePath
    public var container: String?
    public var videoCodec: String?
    public var width: Int
    public var height: Int
    public var frameRateNum: Int
    public var frameRateDen: Int
    public var durationFrames: Int
    public var startTimecodeFrames: Int
    public var dropFrame: Bool
    public var reelName: String?
    public var audioChannels: Int
    public var colorSpace: String?
    /// Human-readable essence name, e.g. "Apple ProRes 422 HQ" or "Sony X-OCN / RAW".
    public var formatName: String
    public var scan: ScanType
    /// Pixel (sample) aspect ratio; 1:1 for square pixels, 10:11 for 4:3 NTSC SD, and so on.
    public var pixelAspectNum: Int
    public var pixelAspectDen: Int
    public var capturedAt: Date?
    public var importedAt: Date
    public var rating: Int
    public var notes: String

    public init(
        id: String = newID(), sourcePath: String, fileSize: Int64 = 0, bookmark: Data? = nil,
        decodePath: DecodePath = .avFoundation, container: String? = nil, videoCodec: String? = nil,
        width: Int = 0, height: Int = 0, frameRate: FrameRate = .fps24, durationFrames: Int = 0,
        startTimecodeFrames: Int = 0, dropFrame: Bool = false, reelName: String? = nil,
        audioChannels: Int = 0, colorSpace: String? = nil, formatName: String = "",
        scan: ScanType = .progressive, pixelAspect: (num: Int, den: Int) = (1, 1), capturedAt: Date? = nil,
        importedAt: Date = Date(), rating: Int = 0, notes: String = ""
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.fileName = (sourcePath as NSString).lastPathComponent
        let parts = sourcePath.split(separator: "/")
        self.volumeName = parts.first == "Volumes" && parts.count > 1 ? String(parts[1]) : nil
        self.fileSize = fileSize
        self.bookmark = bookmark
        self.decodePath = decodePath
        self.container = container
        self.videoCodec = videoCodec
        self.width = width
        self.height = height
        self.frameRateNum = frameRate.numerator
        self.frameRateDen = frameRate.denominator
        self.durationFrames = durationFrames
        self.startTimecodeFrames = startTimecodeFrames
        self.dropFrame = dropFrame
        self.reelName = reelName
        self.audioChannels = audioChannels
        self.colorSpace = colorSpace
        self.formatName = formatName
        self.scan = scan
        self.pixelAspectNum = max(pixelAspect.num, 1)
        self.pixelAspectDen = max(pixelAspect.den, 1)
        self.capturedAt = capturedAt
        self.importedAt = importedAt
        self.rating = rating
        self.notes = notes
    }

    public var frameRate: FrameRate { FrameRate(frameRateNum, frameRateDen) }
    public var durationSeconds: Double { frameRate.seconds(forFrames: durationFrames) }
    public var startTimecode: Timecode { Timecode(frames: startTimecodeFrames, rate: frameRate, dropFrame: dropFrame) }

    /// "2160p23.976", "1080i59.94", "4320p24" ...
    public var pictureFormatName: String { PictureFormat.name(height: height, frameRate: frameRate, scan: scan) }
    /// "UHD 4K", "DCI 4K", "UHD 8K", "8.6K" ...
    public var resolutionClass: String { PictureFormat.resolutionClass(width: width, height: height) }
    public var broadcastStandards: [PictureFormat.BroadcastStandard] {
        PictureFormat.broadcastStandards(width: width, height: height, frameRate: frameRate, scan: scan)
    }

    /// Width as displayed, after applying the pixel aspect ratio (704×480 at 10:11 shows as 640 wide).
    public var displayWidth: Int {
        Int((Double(width) * Double(pixelAspectNum) / Double(pixelAspectDen)).rounded())
    }

    /// Source timecode for a frame offset from the start of the clip.
    public func timecode(atFrame frame: Int) -> Timecode { startTimecode.advanced(by: frame) }
}

public enum ProxyStatus: String, Codable, Sendable { case queued, rendering, ready, failed, offline }

/// A low-resolution stand-in for an asset. Always points back at its source.
public struct ProxyRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "proxy"
    public var id: String
    public var assetID: String
    public var path: String
    public var fileName: String
    public var preset: ProxyPreset
    public var status: ProxyStatus
    public var createdAt: Date
    /// The pipeline that produced the file, and how fast it rendered relative to real time.
    public var pipeline: RenderPipeline?
    public var speed: Double?

    public init(id: String = newID(), assetID: String, path: String, preset: ProxyPreset,
                status: ProxyStatus = .queued, createdAt: Date = Date()) {
        self.id = id
        self.assetID = assetID
        self.path = path
        self.fileName = (path as NSString).lastPathComponent
        self.preset = preset
        self.status = status
        self.createdAt = createdAt
    }
}

/// A point marker (outFrame == nil) or a subclip / marked range (in + out).
/// Frames are offsets from the first frame of the clip.
public struct Marker: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "marker"
    public var id: String
    public var assetID: String
    public var inFrame: Int
    public var outFrame: Int?
    public var name: String
    public var note: String
    public var color: String
    public var createdAt: Date

    public init(id: String = newID(), assetID: String, inFrame: Int, outFrame: Int? = nil,
                name: String = "", note: String = "", color: String = "blue", createdAt: Date = Date()) {
        self.id = id
        self.assetID = assetID
        self.inFrame = inFrame
        self.outFrame = outFrame
        self.name = name
        self.note = note
        self.color = color
        self.createdAt = createdAt
    }

    public var isSubclip: Bool { outFrame != nil }
}

/// One caption-sized piece of speech-to-text output.
public struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcriptSegment"
    public var id: String
    public var assetID: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var speaker: String?

    public init(id: String = newID(), assetID: String, startSeconds: Double, endSeconds: Double,
                text: String, speaker: String? = nil) {
        self.id = id
        self.assetID = assetID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.speaker = speaker
    }
}

public enum TagKind: String, Codable, Sendable {
    /// A shot boundary (cut) range.
    case shot
    /// A scene / object classification label ("beach", "crowd").
    case label
    /// On-screen text found by OCR.
    case text
}

/// A time-ranged piece of machine-generated description.
public struct SceneTag: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sceneTag"
    public var id: String
    public var assetID: String
    public var kind: TagKind
    public var label: String
    public var confidence: Double
    public var startSeconds: Double
    public var endSeconds: Double

    public init(id: String = newID(), assetID: String, kind: TagKind, label: String,
                confidence: Double, startSeconds: Double, endSeconds: Double) {
        self.id = id
        self.assetID = assetID
        self.kind = kind
        self.label = label
        self.confidence = confidence
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// A named (or not yet named) individual that face sightings are grouped under.
public struct Person: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "person"
    public var id: String
    public var name: String?

    public init(id: String = newID(), name: String? = nil) {
        self.id = id
        self.name = name
    }
}

/// One detected face at one moment in one clip.
public struct FaceSighting: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "faceSighting"
    public var id: String
    public var assetID: String
    public var personID: String?
    public var timeSeconds: Double
    /// Normalised bounding box (0...1, origin bottom-left as Vision reports it).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Little-endian Float32 embedding vector used for clustering.
    public var embedding: Data

    public init(id: String = newID(), assetID: String, personID: String? = nil, timeSeconds: Double,
                x: Double, y: Double, width: Double, height: Double, embedding: Data) {
        self.id = id
        self.assetID = assetID
        self.personID = personID
        self.timeSeconds = timeSeconds
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.embedding = embedding
    }

    public var vector: [Float] {
        embedding.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    public static func data(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
