import Foundation
import Testing
import StadaMAMCore
@testable import StadaMAMMedia

/// The real worker against real FFmpeg: one import gives the editors' proxy and the remote
/// proxy, in separate files, and a second pass renders nothing. Skipped without FFmpeg.
@Suite(.enabled(if: FFmpegTools.locate() != nil))
struct IngestWorkerTests {
    let tools = FFmpegTools.locate()!
    let root = NSTemporaryDirectory() + "stadamam-worker-" + UUID().uuidString

    private func makeSource() async throws -> String {
        let dir = root + "/Volumes/RAID/Day 1"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/A001_C003.mov"
        try await tools.runOffPool(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:v", "mpeg4", "-q:v", "5", "-c:a", "pcm_s16le", "-ac", "2",
            "-timecode", "01:00:00:00", "-metadata:s:v:0", "reel_name=A001", path,
        ])
        return path
    }

    @Test func importMakesBothProxiesOnceAndKeepsThemApart() async throws {
        let library = MediaLibrary(catalog: try Catalog.inMemory(), tools: tools, storageRoot: root + "/Library",
                                   pipelines: [.software])
        let worker = LibraryIngestWorker(library: library, limiter: JobLimiter(limit: 2),
                                         presets: { [.h264_720, .remoteHEVC] })
        let source = try await makeSource()
        let outcome = try await worker.process(path: source) { _, _ in }
        let assetID = try #require(outcome.assetID)
        let asset = try #require(try library.catalog.asset(id: assetID))
        let proxies = try library.catalog.proxies(forAsset: asset.id)
        #expect(Set(proxies.map(\.preset)) == [.h264_720, .remoteHEVC])
        #expect(Set(proxies.map(\.path)).count == 2)
        #expect(proxies.allSatisfy { $0.status == .ready && $0.mismatch == nil })
        let remote = try #require(proxies.first { $0.preset == .remoteHEVC })
        #expect(remote.path.hasPrefix(library.proxyRoot + "/Remote/"))
        #expect(library.hasVerifiedProxy(for: asset, preset: .remoteHEVC))

        // Second pass: nothing is rendered again.
        let before = proxies.map { ($0.path, (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date) }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        _ = try await worker.process(path: source) { _, _ in }
        let after = try library.catalog.proxies(forAsset: asset.id)
        #expect(after.count == 2)
        for (path, date) in before {
            #expect((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date == date)
        }
        // Nothing is left to backfill, and the filter keeps the proxy folder out of later scans.
        #expect(worker.pathsNeedingProxies(among: [source]).isEmpty)
        #expect(!worker.filter().accepts(path: remote.path))
    }
}
