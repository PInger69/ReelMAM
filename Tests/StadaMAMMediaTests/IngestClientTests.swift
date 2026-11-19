import Foundation
import Testing
import StadaMAMCore
@testable import StadaMAMMedia

@Suite struct IngestClientOptionTests {
    @Test func defaults() {
        guard case .run(let options) = IngestClient.parse(["/Volumes/CARD"]) else { Issue.record("should run"); return }
        #expect(options.folders == ["/Volumes/CARD"])
        #expect(options.presets == [.proResProxyHalf])
        #expect(options.naming == .sameName)
        #expect(!options.once && !options.quiet)
        #expect(options.libraryFolder == nil && options.stabilitySeconds == nil && options.parallel == nil)
        #expect(options.scanInterval == 15)
    }

    @Test func everyOption() {
        let parsed = IngestClient.parse([
            "--library", "/Volumes/SAN/Library/", "--preset", "h264-720", "--preset", "remote-hevc", "--preset", "h264-720",
            "--naming", "beside", "--once", "--stability", "5", "--parallel", "4", "--quiet", "--scan-interval", "20",
            "/Volumes/A", "/Volumes/B/", "/Volumes/A",
        ])
        guard case .run(let options) = parsed else { Issue.record("should run: \(parsed)"); return }
        #expect(options.libraryFolder == "/Volumes/SAN/Library")
        #expect(options.presets == [.h264_720, .remoteHEVC])
        #expect(options.naming == .besideSource)
        #expect(options.once && options.quiet)
        #expect(options.stabilitySeconds == 5 && options.parallel == 4 && options.scanInterval == 20)
        #expect(options.folders == ["/Volumes/A", "/Volumes/B"])
        #expect(IngestClient.locations(for: options) == IngestClient.Locations(
            catalogPath: "/Volumes/SAN/Library/Catalog.sqlite", storageRoot: "/Volumes/SAN/Library",
            statePath: "/Volumes/SAN/Library/IngestClient.json"))
    }

    @Test func catalogueOnlyAndMistakes() {
        guard case .run(let options) = IngestClient.parse(["--no-proxies", "/in"]) else { Issue.record("should run"); return }
        #expect(options.presets.isEmpty)
        #expect(IngestClient.parse(["--help"]) == .help)
        #expect(IngestClient.parse([]) == .failure("Give at least one folder to ingest from."))
        #expect(IngestClient.parse(["--once"]) == .failure("Give at least one folder to ingest from."))
        #expect(IngestClient.parse(["/in", "--bogus"]) == .failure("Unknown option --bogus."))
        #expect(IngestClient.parse(["/in", "--parallel", "0"]) == .failure("--parallel needs a whole number, 1 or more."))
        #expect(IngestClient.parse(["/in", "--stability"]) == .failure("--stability needs a number of seconds."))
        #expect(IngestClient.parse(["/in", "--no-proxies", "--preset", "h264-720"]) == .failure("--no-proxies cannot be combined with --preset."))
        if case .failure(let message) = IngestClient.parse(["/in", "--preset", "8k"]) {
            #expect(message.contains("prores-half"))
        } else {
            Issue.record("unknown preset should fail")
        }
    }

    @Test func summaryReadsPlainly() {
        var summary = IngestClient.Summary()
        summary.ingested = 1
        #expect(IngestClient.describe(summary) == "1 clip ingested.")
        #expect(summary.exitStatus == 0)
        summary.ingested = 12
        summary.skipped = 2
        summary.failures = [.init(path: "/Volumes/CARD/A001.mov", reason: "The proxy does not match its source.")]
        #expect(IngestClient.describe(summary)
            == "12 clips ingested, 2 skipped, 1 failed:\n  A001.mov: The proxy does not match its source.")
        #expect(summary.exitStatus == 1)
    }
}

/// The client end to end against real FFmpeg: a card is ingested into a library folder.
@Suite(.enabled(if: FFmpegTools.locate() != nil))
struct IngestClientRunTests {
    let tools = FFmpegTools.locate()!
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "stadamam-client-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/CARD/PRIVATE/CLIPS", withIntermediateDirectories: true)
    }

    private func makeClip(_ name: String, timecode: String) throws {
        try tools.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:v", "mpeg4", "-q:v", "5", "-c:a", "pcm_s16le", "-ac", "2", "-timecode", timecode,
            root + "/CARD/PRIVATE/CLIPS/" + name,
        ])
    }

    @Test func aCardIsIngestedIntoALibraryAndASecondPassDoesNothing() async throws {
        try makeClip("A001_C001.mov", timecode: "01:00:00:00")
        try makeClip("A001_C002.mov", timecode: "01:00:10:00")
        _ = FileManager.default.createFile(atPath: root + "/CARD/PRIVATE/CLIPS/A001_C003.braw", contents: Data([1, 2, 3]))
        _ = FileManager.default.createFile(atPath: root + "/CARD/PRIVATE/notes.txt", contents: Data("not media".utf8))

        var options = IngestClient.Options()
        options.folders = [root + "/CARD"]
        options.libraryFolder = root + "/Library"
        options.presets = [.h264_720]
        options.once = true
        options.quiet = true
        let lines = Lines()
        let first = try await IngestClient.runOnce(options, tools: tools) { lines.add($0) }
        #expect(first == IngestClient.Summary(ingested: 3, skipped: 0, failures: []), "\(first)")

        // What the MAM app will find: a catalog with every clip, and verified proxies beside it.
        let catalog = try Catalog(path: root + "/Library/Catalog.sqlite")
        let assets = try catalog.allAssets()
        #expect(Set(assets.map(\.fileName)) == ["A001_C001.mov", "A001_C002.mov", "A001_C003.braw"])
        for asset in assets where asset.fileName.hasSuffix(".mov") {
            let proxy = try #require(try catalog.proxies(forAsset: asset.id).first)
            #expect(proxy.status == .ready && proxy.mismatch == nil)
            #expect(proxy.path.hasPrefix(root + "/Library/Proxies/"))
            #expect(FileManager.default.fileExists(atPath: proxy.path))
            #expect(try tools.probe(path: proxy.path).embeddedAssetID == asset.id)
        }
        let raw = try #require(assets.first { $0.fileName == "A001_C003.braw" })
        #expect(raw.formatName == "Blackmagic RAW")
        #expect(try catalog.proxies(forAsset: raw.id).isEmpty)

        // Running it again on the same card neither re-imports nor re-renders anything.
        let proxyDates = try proxyModificationDates(under: root + "/Library/Proxies")
        let second = try await IngestClient.runOnce(options, tools: tools) { lines.add($0) }
        #expect(second.failures.isEmpty)
        #expect(try Catalog(path: root + "/Library/Catalog.sqlite").allAssets().count == 3)
        #expect(try proxyModificationDates(under: root + "/Library/Proxies") == proxyDates)

        // A clip that arrives later is picked up by the next pass, alone.
        try makeClip("A001_C004.mov", timecode: "01:00:20:00")
        let third = try await IngestClient.runOnce(options, tools: tools) { lines.add($0) }
        #expect(third.ingested == 1 && third.failures.isEmpty, "\(third)")
        #expect(try Catalog(path: root + "/Library/Catalog.sqlite").allAssets().count == 4)
    }

    @Test func aMissingFolderIsRefusedBeforeAnythingIsWritten() async throws {
        var options = IngestClient.Options()
        options.folders = [root + "/NOT-THERE"]
        options.libraryFolder = root + "/Library2"
        options.once = true
        await #expect(throws: IngestClient.ClientError.missingFolder(root + "/NOT-THERE")) {
            try await IngestClient.runOnce(options, tools: tools) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: root + "/Library2"))
    }

    private func proxyModificationDates(under folder: String) throws -> [String: Date] {
        var dates: [String: Date] = [:]
        for case let relative as String in FileManager.default.enumerator(atPath: folder) ?? .init() where relative.hasSuffix(".mov") {
            dates[relative] = try FileManager.default.attributesOfItem(atPath: folder + "/" + relative)[.modificationDate] as? Date
        }
        return dates
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
}
