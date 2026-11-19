import SwiftUI

@main
struct StadaMAMApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("StadaXR A.I. MAM") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Media…") { model.presentImportPanel() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Find Source for Proxy or Timeline…") { model.presentRecallPanel() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
