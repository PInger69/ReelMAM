import SwiftUI

/// StradaXR Ingest: point it at a card or volume, and every clip ends up on storage with a
/// proxy in the StradaXR A.I. MAM library.
@main
struct StradaIngestApp: App {
    @State private var model = IngestModel()

    var body: some Scene {
        Window("StradaXR Ingest", id: "ingest") {
            IngestView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 560)
        }
        .defaultSize(width: 640, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Source Folder…") { model.chooseSource() }
                    .keyboardShortcut("o")
                    .disabled(model.isRunning)
            }
        }
    }
}
