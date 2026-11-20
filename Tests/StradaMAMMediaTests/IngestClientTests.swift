import Foundation
import Testing
import StradaMAMCore
@testable import StradaMAMMedia

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

    @Test func offloadPlanKeepsEachCardsLayout() {
        let plan = OffloadPlan(sources: ["/Volumes/CARD_A/", "/Volumes/CARD_B"], destination: "/Volumes/RAID/Day 1/")
        #expect(plan.destinationPath(for: "/Volumes/CARD_A/CLIPS/A001.mov") == "/Volumes/RAID/Day 1/CARD_A/CLIPS/A001.mov")
        #expect(plan.destinationPath(for: "/Volumes/CARD_B/A001.mov") == "/Volumes/RAID/Day 1/CARD_B/A001.mov")
        #expect(plan.destinationPath(for: "/Volumes/OTHER/A001.mov") == nil)
        #expect(plan.sourcePath(forCopy: "/Volumes/RAID/Day 1/CARD_A/CLIPS/A001.mov") == "/Volumes/CARD_A/CLIPS/A001.mov")
        #expect(plan.sourcePath(forCopy: "/Volumes/RAID/Day 2/CARD_A/A001.mov") == nil)
        #expect(plan.problem == nil)
        #expect(OffloadPlan(sources: ["/Volumes/CARD"], destination: "/Volumes/CARD/Copies").problem != nil)
        #expect(OffloadPlan(sources: ["/Volumes/RAID/in"], destination: "/Volumes/RAID").problem != nil)
        #expect(OffloadPlan(sources: ["/Volumes/A/CARD", "/Volumes/B/CARD"], destination: "/Volumes/RAID").problem != nil)
        #expect(IngestClient.parse(["/Volumes/CARD", "--copy-to", "/Volumes/CARD/x"])
            == .failure("The copy destination is inside /Volumes/CARD, which is being watched."))
        guard case .run(let options) = IngestClient.parse(["/Volumes/CARD", "--copy-to", "/Volumes/RAID/"]) else {
            Issue.record("should run"); return
        }
        #expect(options.copyDestination == "/Volumes/RAID")
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
        root = NSTemporaryDirectory() + "stradamam-client-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/CARD/PRIVATE/CLIPS", withIntermediateDirectories: true)
    }

    private func makeClip(_ name: String, timecode: String) async throws {
        try await tools.runOffPool(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:v", "mpeg4", "-q:v", "5", "-c:a", "pcm_s16le", "-ac", "2", "-timecode", timecode,
            root + "/CARD/PRIVATE/CLIPS/" + name,
        ])
    }

    @Test func aCardIsIngestedIntoALibraryAndASecondPassDoesNothing() async throws {
        try await makeClip("A001_C001.mov", timecode: "01:00:00:00")
        try await makeClip("A001_C002.mov", timecode: "01:00:10:00")
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
        try await makeClip("A001_C004.mov", timecode: "01:00:20:00")
        let third = try await IngestClient.runOnce(options, tools: tools) { lines.add($0) }
        #expect(third.ingested == 1 && third.failures.isEmpty, "\(third)")
        #expect(try Catalog(path: root + "/Library/Catalog.sqlite").allAssets().count == 4)
    }

    /// The offload: clips are copied off the card and checked, the catalogue points at the
    /// copies, and wiping the card afterwards loses nothing.
    @Test func aCardIsCopiedVerifiedAndCataloguedFromItsCopy() async throws {
        let clips = root + "/CARD/PRIVATE/CLIPS"
        try await makeClip("A001_C001.mov", timecode: "01:00:00:00")
        try await makeClip("A001_C002.mov", timecode: "01:00:10:00")
        _ = FileManager.default.createFile(atPath: clips + "/A001_C001.sidecar", contents: Data("grade".utf8))
        _ = FileManager.default.createFile(atPath: root + "/CARD/PRIVATE/notes.txt", contents: Data("not media".utf8))

        var options = IngestClient.Options()
        options.folders = [root + "/CARD"]
        options.libraryFolder = root + "/Library"
        options.copyDestination = root + "/Storage"
        options.presets = [.h264_720]
        options.once = true
        options.quiet = true
        let first = try await IngestClient.runOnce(options, tools: tools) { _ in }
        #expect(first == IngestClient.Summary(ingested: 2, skipped: 0, failures: []), "\(first)")

        // The copies are identical to the card, with the sidecar, in the card's own layout.
        let fm = FileManager.default
        let copies = root + "/Storage/CARD/PRIVATE/CLIPS"
        for name in ["A001_C001.mov", "A001_C002.mov", "A001_C001.sidecar"] {
            #expect(fm.contentsEqual(atPath: clips + "/" + name, andPath: copies + "/" + name), "\(name)")
        }
        #expect(!fm.fileExists(atPath: root + "/Storage/CARD/PRIVATE/notes.txt"))
        let list = try String(contentsOfFile: root + "/Storage/CARD/checksums." + SequencePackageExporter.checksumAlgorithm, encoding: .utf8)
        #expect(list.split(separator: "\n").count == 3)
        #expect(list.contains("  PRIVATE/CLIPS/A001_C001.mov\n"))
        let line = try #require(list.split(separator: "\n").first { $0.hasSuffix("A001_C002.mov") })
        let listed = String(line.prefix { $0 != " " })
        let independent = try SequencePackageExporter.checksum(ofFileAt: clips + "/A001_C002.mov")
        #expect(listed == independent)

        // The catalogue knows the copies, not the card, and the proxies are of the copies.
        let catalog = try Catalog(path: root + "/Library/Catalog.sqlite")
        let assets = try catalog.allAssets()
        #expect(Set(assets.map(\.sourcePath)) == [copies + "/A001_C001.mov", copies + "/A001_C002.mov"])
        for asset in assets {
            let proxy = try #require(try catalog.proxies(forAsset: asset.id).first)
            #expect(proxy.status == .ready && proxy.mismatch == nil)
        }

        // A second pass over the same card copies and imports nothing.
        let dates = try [copies + "/A001_C001.mov", copies + "/A001_C002.mov"].map {
            try fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date
        }
        let second = try await IngestClient.runOnce(options, tools: tools) { _ in }
        #expect(second == IngestClient.Summary(), "\(second)")
        #expect(try Catalog(path: root + "/Library/Catalog.sqlite").allAssets().count == 2)
        #expect(try [copies + "/A001_C001.mov", copies + "/A001_C002.mov"].map {
            try fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date
        } == dates)

        // The card is wiped: every clip is still there, from its copy.
        try fm.removeItem(atPath: root + "/CARD")
        #expect(try catalog.allAssets().allSatisfy { fm.fileExists(atPath: $0.sourcePath) })
    }

    /// A copy left behind by an interrupted run is checked, not trusted and not redone needlessly.
    @Test func anInterruptedCopyIsFinishedProperly() async throws {
        try await makeClip("B001_C001.mov", timecode: "02:00:00:00")
        let fm = FileManager.default
        let copy = root + "/Storage/CARD/PRIVATE/CLIPS/B001_C001.mov"
        try fm.createDirectory(atPath: (copy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Half a file, as a power cut would leave.
        let whole = try Data(contentsOf: URL(fileURLWithPath: root + "/CARD/PRIVATE/CLIPS/B001_C001.mov"))
        try whole.prefix(whole.count / 2).write(to: URL(fileURLWithPath: copy))

        var options = IngestClient.Options()
        options.folders = [root + "/CARD"]
        options.libraryFolder = root + "/Library"
        options.copyDestination = root + "/Storage"
        options.presets = []
        options.once = true
        options.quiet = true
        let summary = try await IngestClient.runOnce(options, tools: tools) { _ in }
        #expect(summary.ingested == 1 && summary.failures.isEmpty, "\(summary)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy)) == whole)
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
