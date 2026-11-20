import Foundation
import ImageCaptureCore
import Observation
import UniformTypeIdentifiers

/// iPhones and cameras connected by cable. They do not appear as volumes, so their clips are
/// listed and fetched through the system's camera import service, the one Image Capture uses.
@MainActor
@Observable
final class PhoneCameras: NSObject, @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    struct Camera: Identifiable, Hashable {
        var id: String
        var name: String
        /// Where it is on the USB bus, to find how fast it is connected.
        var locationID: Int
    }

    struct Clip: Sendable {
        var name: String
        var size: Int64
        var date: Date?
    }

    enum ImportError: LocalizedError {
        case notConnected(String)
        case locked(String)
        case noAnswer(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected(let name): return "\(name) is not connected any more."
            case .locked(let name): return "\(name) is locked. Unlock it, tap Trust if it asks, and scan again."
            case .noAnswer(let name): return "\(name) did not list its clips. Unlock it, tap Trust if it asks, and scan again."
            case .failed(let reason): return reason
            }
        }
    }

    private(set) var cameras: [Camera] = []

    @ObservationIgnored private let browser = ICDeviceBrowser()
    @ObservationIgnored private var devices: [String: ICCameraDevice] = [:]
    @ObservationIgnored private var whenReady: [String: [(Result<Void, Error>) -> Void]] = [:]
    @ObservationIgnored private var ready: Set<String> = []
    /// Devices that said they are locked; cleared when they say they are unlocked.
    @ObservationIgnored private var locked: Set<String> = []
    @ObservationIgnored private var files: [String: [String: ICCameraFile]] = [:]

    override init() {
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        if let wanted = ICDeviceTypeMask(rawValue: mask) { browser.browsedDeviceTypeMask = wanted }
        browser.start()
    }

    private static func key(_ device: ICDevice) -> String {
        device.uuidString ?? device.name ?? "camera"
    }

    private func refresh() {
        cameras = devices.map { Camera(id: $0.key, name: $0.value.name ?? "Camera", locationID: Int($0.value.usbLocationID)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Listing and fetching

    /// Every video on the camera.
    func clips(on cameraID: String) async throws -> [Clip] {
        guard let device = devices[cameraID] else { throw ImportError.notConnected(name(of: cameraID)) }
        try await open(device, name: device.name ?? "The camera")
        // Every file the device lists, from its flat media list and by walking its folders, in
        // case one of the two leaves files out.
        var all: [ICCameraFile] = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        var seen = Set(all.map(ObjectIdentifier.init))
        func walk(_ items: [ICCameraItem]?) {
            for item in items ?? [] {
                if let folder = item as? ICCameraFolder {
                    walk(folder.contents)
                } else if let file = item as? ICCameraFile, seen.insert(ObjectIdentifier(file)).inserted {
                    all.append(file)
                }
            }
        }
        walk(device.contents)
        let videos = all.filter(Self.isVideo)
        if videos.isEmpty {
            // Say exactly what the device gave, so a file that should count as a video can be told apart.
            let sample = all.prefix(6).map { "\($0.name ?? "?") (\($0.uti ?? "no type"))" }.joined(separator: ", ")
            throw ImportError.failed("\(device.name ?? "The device") listed \(all.count) file\(all.count == 1 ? "" : "s") and no videos"
                                     + (sample.isEmpty ? "." : ": " + sample + (all.count > 6 ? ", …" : "") + ".")
                                     + " Only videos in its Photos library are visible over the cable.")
        }
        var byName: [String: ICCameraFile] = [:]
        for file in videos { byName[file.name ?? ""] = file }
        files[cameraID] = byName
        return videos.map { Clip(name: $0.name ?? "clip.mov", size: Int64($0.fileSize), date: $0.creationDate) }
    }

    /// Fetches one clip to `path`. It is written under a temporary name and takes its own only
    /// once it has the size the camera gave; a fetch that fails is tried twice more.
    func fetch(cameraID: String, clip name: String, to path: String,
               progress: @escaping @Sendable (Double) -> Void) async throws {
        guard devices[cameraID] != nil, let file = files[cameraID]?[name] else {
            throw ImportError.notConnected(self.name(of: cameraID))
        }
        let folder = (path as NSString).deletingLastPathComponent
        let partialName = (path as NSString).lastPathComponent + ".partial"
        let partial = folder + "/" + partialName
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) }
            try? FileManager.default.removeItem(atPath: partial)
            do {
                try await download(file, as: partialName, into: folder, progress: progress)
                guard Self.size(of: partial) == Int64(file.fileSize) else {
                    throw ImportError.failed("\(name) arrived incomplete from \(self.name(of: cameraID)).")
                }
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
                try FileManager.default.moveItem(atPath: partial, toPath: path)
                return
            } catch {
                lastError = error
                if devices[cameraID] == nil { break }
            }
        }
        try? FileManager.default.removeItem(atPath: partial)
        throw lastError ?? ImportError.failed("\(name) could not be fetched.")
    }

    private func name(of cameraID: String) -> String {
        cameras.first { $0.id == cameraID }?.name ?? "The camera"
    }

    private func open(_ device: ICCameraDevice, name: String) async throws {
        let id = Self.key(device)
        if ready.contains(id) { return }
        // The locked flag is not checked here: it can be left over from before the phone was
        // unlocked or trusted. The session is always asked for, and a phone that really is locked
        // is waited for until it is unlocked, or until the time below runs out.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var answered = false
            let answer: (Result<Void, Error>) -> Void = { result in
                guard !answered else { return }
                answered = true
                continuation.resume(with: result)
            }
            whenReady[id, default: []].append(answer)
            device.delegate = self
            device.requestOpenSession()
            // A phone that is locked or was never trusted says nothing at all.
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
                let locked = self?.locked.contains(id) ?? false
                answer(.failure(locked ? ImportError.locked(name) : ImportError.noAnswer(name)))
            }
        }
    }

    private func download(_ file: ICCameraFile, as fileName: String, into folder: String,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: URL(fileURLWithPath: folder, isDirectory: true),
                .saveAsFilename: fileName,
                .overwrite: true,
            ]
            let request: Progress? = file.requestDownload(options: options) { _, error in
                if let error {
                    continuation.resume(throwing: ImportError.failed("\(file.name ?? "A clip") could not be fetched: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            }
            observation = request?.observe(\.fractionCompleted) { request, _ in progress(request.fractionCompleted) }
        }
    }

    private static func isVideo(_ file: ICCameraFile) -> Bool {
        if let uti = file.uti, let type = UTType(uti), type.conforms(to: .movie) || type.conforms(to: .video) { return true }
        let ext = ((file.name ?? "") as NSString).pathExtension.lowercased()
        return ["mov", "mp4", "m4v", "mxf", "braw"].contains(ext)
    }

    private static func size(of path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func finishOpening(_ device: ICDevice, _ result: Result<Void, Error>) {
        let id = Self.key(device)
        if case .success = result { ready.insert(id) }
        let waiting = whenReady.removeValue(forKey: id) ?? []
        waiting.forEach { $0(result) }
    }

    // MARK: ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        devices[Self.key(device)] = camera
        refresh()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let id = Self.key(device)
        devices[id] = nil
        files[id] = nil
        ready.remove(id)
        finishOpening(device, .failure(ImportError.notConnected(device.name ?? "The camera")))
        refresh()
    }

    // MARK: ICDeviceDelegate

    func didRemove(_ device: ICDevice) {}

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { finishOpening(device, .failure(ImportError.failed("\(device.name ?? "The camera") could not be opened: \(error.localizedDescription)"))) }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        ready.remove(Self.key(device))
    }

    // MARK: ICCameraDeviceDelegate

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard !locked.contains(Self.key(device)) else { return }
        finishOpening(device, .success(()))
    }

    /// The phone locked, or was locked when the session opened. Not a failure: the scan keeps
    /// waiting, and its clips are listed once it is unlocked.
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        let id = Self.key(device)
        locked.insert(id)
        ready.remove(id)
    }

    /// Unlocked: what was listed while it was locked is incomplete, so the session is opened afresh.
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        let id = Self.key(device)
        locked.remove(id)
        ready.remove(id)
        if whenReady[id] != nil, let camera = device as? ICCameraDevice {
            camera.requestCloseSession()
            camera.requestOpenSession()
        }
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
}
