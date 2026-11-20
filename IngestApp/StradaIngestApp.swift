import SwiftUI

/// StradaXR Ingest: lists the clips on every connected card, drive and iPhone, copies the ones
/// ticked to storage with every copy checked, and makes proxies in the StradaXR A.I. MAM library.
@main
struct StradaIngestApp: App {
    @State private var model = IngestModel()

    var body: some Scene {
        Window("StradaXR Ingest", id: "ingest") {
            IngestView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Source Folder…") { model.addFolder() }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
                Button("Choose Destination…") { model.chooseDestination() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.isBusy)
                Divider()
                Button("Scan") { Task { await model.scan() } }
                    .keyboardShortcut("r")
                    .disabled(!model.canScan)
                Button("Copy") { model.copy() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canCopy)
            }
        }
    }
}
