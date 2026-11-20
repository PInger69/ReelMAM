import Foundation
import ImageCaptureCore
import Observation
import UniformTypeIdentifiers

/// iPhones and cameras connected by cable. They do not appear as volumes, so their clips are
/// fetched through the system's camera import service, the one Image Capture and Photos use.
@MainActor
@Observable
final class PhoneCameras: NSObject, @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    struct Camera: Identifiable, Hashable {
        var id: String
        var name: String
    }

    enum ImportError: LocalizedError {
        case notConnected(String)
        case locked(String)
        case noAnswer(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected(let name): return "\(name) is not connected any more."
            case .locked(let name): return "\(name) is locked. Unlock it, tap Trust if it asks, and start again."
            case .noAnswer(let name): return "\(name) did not list its clips. Unlock it, tap Trust if it asks, and start again."
            case .failed(let reason): return reason
            }
        }
    }

    private(set) var cameras: [Camera] = []

    @ObservationIgnored private let browser = ICDeviceBrowser()
    @ObservationIgnored private var devices: [String: ICCameraDevice] = [:]
    @ObservationIgnored private var whenReady: [String: [(Result<Void, Error>) -> Void]] = [:]
    @ObservationIgnored private var ready: Set<String> = []

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
        cameras = devices.map { Camera(id: $0.key, name: $0.value.name ?? "Camera") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Fetching clips

    /// Fetches every video on the camera into `folder`. A clip already there with the same
    /// size is left alone. Returns how many were fetched and how many were already there.
    func fetchVideos(from camera: Camera, into folder: String,
                     progress: @escaping @MainActor (String) -> Void) async throws -> (fetched: Int, alreadyThere: Int) {
        guard let device = devices[camera.id] else { throw ImportError.notConnected(camera.name) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        progress("Reading the clip list on \(camera.name)")
        try await open(device, name: camera.name)
        let videos = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.filter(Self.isVideo)
        var fetched = 0, alreadyThere = 0
        for (index, file) in videos.enumerated() {
            try Task.checkCancellation()
            let name = file.name ?? "clip-\(index + 1).mov"
            let target = folder + "/" + name
            let expected = Int64(file.fileSize)
            if Self.size(of: target) == expected, expected > 0 {
                alreadyThere += 1
                continue
            }
            progress("Fetching \(index + 1) of \(videos.count) from \(camera.name): \(name)")
            try await download(file, named: name, into: folder)
            // The camera gives no checksum, so the fetched file is at least held to the size it reported.
            guard Self.size(of: target) == expected else {
                try? FileManager.default.removeItem(atPath: target)
                throw ImportError.failed("\(name) from \(camera.name) arrived incomplete and was removed. Start again to fetch it.")
            }
            fetched += 1
        }
        return (fetched, alreadyThere)
    }

    private func open(_ device: ICCameraDevice, name: String) async throws {
        let id = Self.key(device)
        if ready.contains(id) { return }
        if device.isAccessRestrictedAppleDevice { throw ImportError.locked(name) }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { answer(.failure(ImportError.noAnswer(name))) }
        }
    }

    private func download(_ file: ICCameraFile, named name: String, into folder: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: URL(fileURLWithPath: folder, isDirectory: true),
                .saveAsFilename: name,
                .overwrite: true,
            ]
            _ = file.requestDownload(options: options) { _, error in
                if let error {
                    continuation.resume(throwing: ImportError.failed("\(name) could not be fetched: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            }
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
        finishOpening(device, .success(()))
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        finishOpening(device, .failure(ImportError.locked(device.name ?? "The iPhone")))
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
}
