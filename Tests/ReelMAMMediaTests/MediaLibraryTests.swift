import Foundation
import Testing
import ReelMAMCore
@testable import ReelMAMMedia

/// End-to-end against real FFmpeg: ingest, proxy, and recall of the source from the proxy.
/// Skipped automatically on machines without FFmpeg.
@Suite(.enabled(if: FFmpegTools.locate() != nil))
struct MediaLibraryTests {
    let tools = FFmpegTools.locate()!
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "reelmam-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/Volumes/RAID/Day 1", withIntermediateDirectories: true)
    }

    /// A 2-second 29.97 DF test clip with timecode, reel name and stereo audio.
    private func makeSource(_ name: String, timecode: String = "01:00:00;00") throws -> String {
        let path = root + "/Volumes/RAID/Day 1/" + name
        try tools.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30000/1001:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:v", "mpeg4", "-q:v", "5", "-c:a", "pcm_s16le", "-ac", "2",
            "-timecode", timecode, "-metadata:s:v:0", "reel_name=A001", path,
        ])
        return path
    }

    private func makeLibrary() throws -> MediaLibrary {
        MediaLibrary(catalog: try Catalog.inMemory(), tools: tools, storageRoot: root + "/Library",
                     hardwareEncoding: false)
    }

    @Test func ingestReadsTechnicalMetadata() throws {
        let library = try makeLibrary()
        let asset = try library.importFile(at: try makeSource("A001_C003.mov"))
        #expect(asset.width == 640 && asset.height == 360)
        #expect(asset.frameRate == .fps29_97)
        #expect(asset.durationFrames == 60)
        #expect(asset.startTimecode.description == "01:00:00;00")
        #expect(asset.reelName == "A001")
        #expect(asset.audioChannels == 2)
        #expect(MediaLibrary.mediaFiles(at: root + "/Volumes") == [asset.sourcePath])
    }

    @Test func proxyKeepsIdentityAndSourceIsRecalledAfterRenaming() throws {
        let library = try makeLibrary()
        let asset = try library.importFile(at: try makeSource("A001_C003.mov"))
        let progress = ProgressBox()
        let proxy = try library.makeProxy(for: asset, preset: .h264_720) { progress.set($0) }
        #expect(proxy.status == .ready)
        #expect(proxy.fileName == "A001_C003.mov")
        #expect(progress.value > 0)

        // The proxy carries what Premiere and Resolve relink on.
        let probe = try tools.probe(path: proxy.path)
        let proxyAsset = try #require(probe.asset(path: proxy.path))
        #expect(proxyAsset.startTimecode.description == "01:00:00;00")
        #expect(proxyAsset.durationFrames == asset.durationFrames)
        #expect(proxyAsset.frameRate == asset.frameRate)
        #expect(proxyAsset.reelName == "A001")
        #expect(proxyAsset.audioChannels == 2)
        #expect(probe.embeddedAssetID == asset.id)

        // Rename and move it, as happens once it has been handed to an editor.
        let moved = root + "/handed-to-editor.mov"
        try FileManager.default.copyItem(atPath: proxy.path, toPath: moved)
        let recalled = try library.source(forFileAt: moved)
        #expect(recalled.asset?.id == asset.id)
        #expect(recalled.evidence == .embeddedID)

        // A ReelMAM proxy is never ingested as if it were a source.
        #expect(throws: MediaError.isReelMAMProxy(assetID: asset.id)) { try library.importFile(at: moved) }
        #expect(library.playablePath(for: asset) == proxy.path)
    }

    @Test func proResProxyAndThumbnails() throws {
        let library = try makeLibrary()
        let asset = try library.importFile(at: try makeSource("B001_C001.mov", timecode: "00:59:58;00"))
        let proxy = try library.makeProxy(for: asset, preset: .proResProxyHalf)
        let probe = try tools.probe(path: proxy.path)
        #expect(probe.asset(path: proxy.path)?.videoCodec == "prores")
        #expect(probe.asset(path: proxy.path)?.height == 180)
        let thumbs = try library.makeThumbnails(for: asset, count: 4)
        #expect(thumbs.count == 4)
        #expect(library.thumbnails(forAssetID: asset.id) == thumbs)
    }

    @Test func timelineCutOnProxiesRelinksToSources() throws {
        let library = try makeLibrary()
        let asset = try library.importFile(at: try makeSource("A001_C003.mov"))
        let proxy = try library.makeProxy(for: asset, preset: .h264_720)
        let xml = """
            <?xml version="1.0"?><xmeml version="4"><sequence><media><video><track><clipitem>
            <file id="f1"><name>A001_C003.mov</name><pathurl>file://localhost\(proxy.path.replacingOccurrences(of: " ", with: "%20"))</pathurl></file>
            </clipitem><clipitem><file id="f2"><name>missing.mov</name><pathurl>file:///nowhere/missing.mov</pathurl></file>
            </clipitem></track></video></media></sequence></xmeml>
            """
        let relink = try #require(try library.relinkTimeline(text: xml))
        #expect(relink.resolutions.count == 2)
        #expect(relink.unresolvedCount == 1)
        #expect(relink.relinkedText.contains(asset.sourcePath.replacingOccurrences(of: " ", with: "%20")))
        #expect(!relink.relinkedText.contains("/Library/Proxies/"))
    }

    @Test func brawIsCataloguedButNeedsSDK() throws {
        let library = try makeLibrary()
        let path = root + "/Volumes/RAID/Day 1/C001.braw"
        _ = FileManager.default.createFile(atPath: path, contents: Data([0, 1, 2]))
        let asset = try library.importFile(at: path)
        #expect(asset.decodePath == .blackmagicRAW)
        #expect(throws: MediaError.blackmagicRAWSDKRequired) { try library.makeProxy(for: asset, preset: .h264_720) }
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0.0
    var value: Double { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ v: Double) { lock.lock(); stored = max(stored, v); lock.unlock() }
}
