import AppKit
import StradaMAMCore
import StradaMAMMedia
import SwiftUI

/// A person's face in the People list, cut from the clip they were seen in. Until it has been
/// made (or when their clip cannot be played), the usual person symbol is shown.
struct PersonPortrait: View {
    @Environment(AppModel.self) private var model
    let person: Person
    var side: CGFloat = 22
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: side, height: side).clipShape(Circle())
            } else {
                Image(systemName: person.name == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle")
            }
        }
        .accessibilityHidden(true)
        .task(id: person.id) { image = await PersonPortraits.image(for: person, model: model) }
    }
}

/// Makes each portrait once and keeps it beside the catalogue.
@MainActor
enum PersonPortraits {
    private static var memory: [String: NSImage] = [:]

    private static var folder: URL {
        AppNames.libraryFolder(in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("People")
    }

    static func image(for person: Person, model: AppModel) async -> NSImage? {
        guard let sighting = try? model.catalog.portraitSighting(forPerson: person.id) else { return nil }
        // Named by the sighting, so a person whose best face changes gets a new picture.
        if let cached = memory[sighting.id] { return cached }
        let path = folder.appendingPathComponent(sighting.id + ".jpg").path
        if !FileManager.default.fileExists(atPath: path) {
            guard let asset = try? model.catalog.asset(id: sighting.assetID),
                  let media = model.library?.playablePath(for: asset),
                  await FacePortrait.write(mediaPath: media, sighting: sighting, to: path) else { return nil }
        }
        let image = NSImage(contentsOfFile: path)
        memory[sighting.id] = image
        return image
    }
}
