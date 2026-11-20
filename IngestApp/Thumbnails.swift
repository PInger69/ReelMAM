import AppKit
import Observation
import QuickLookThumbnailing
import StradaMAMMedia

/// Small previews for the clip list, made only for the rows that come into view: the
/// thumbnail an iPhone keeps for each clip, or the Finder's Quick Look thumbnail for a file.
@MainActor
@Observable
final class Thumbnails {
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let phones: PhoneCameras

    init(phones: PhoneCameras) {
        self.phones = phones
    }

    func load(_ item: TransferItem) {
        guard requested.insert(item.id).inserted else { return }
        Task {
            let image: NSImage?
            switch item.origin {
            case .file(let path):
                image = await Self.quickLook(path)
            case .device(let name):
                let cameraID = String(item.sourceID.dropFirst("camera:".count))
                image = await phones.thumbnail(cameraID: cameraID, clip: name).map { NSImage(cgImage: $0, size: .zero) }
            }
            if let image { images[item.id] = image }
        }
    }

    /// Forgets everything, e.g. after a new scan.
    func reset() {
        images = [:]
        requested = []
    }

    private static func quickLook(_ path: String) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 96, height: 54),
                                                   scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
