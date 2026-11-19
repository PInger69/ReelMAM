import StadaMAMCore
import SwiftUI

@main
struct StadaMAMApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("StradaXR AI MAM") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1560, height: 940)
        .commands {
            CommandGroup(after: .newItem) {
                Menu("Generate Missing Proxies") {
                    ForEach(ProxyPreset.allCases, id: \.self) { preset in
                        Button(preset.displayName) { model.makeMissingProxies(preset: preset) }
                    }
                }
            }
            CommandMenu("Editor") {
                SendToEditorMenu()
                    .environment(model)
                Divider()
                Button("Find Source for Proxy or Timeline…") { model.presentRecallPanel() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Import Media…") { model.presentImportPanel() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Find Source for Proxy or Timeline…") { model.presentRecallPanel() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Locate Missing Originals…") { model.presentLocateMissingPanel() }
            }
        }
        Settings {
            TabView {
                SettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                LabelRulesView()
                    .tabItem { Label("Picture Labels", systemImage: "tag") }
                DialogueAndStorageView()
                    .tabItem { Label("Dialogue & Storage", systemImage: "waveform") }
            }
            .environment(model)
            .frame(width: 680, height: 640)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Make a proxy for every clip as it is imported", isOn: $model.makesProxiesOnImport)
            Picker("Proxy format", selection: $model.defaultPreset) {
                ForEach(ProxyPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            Picker("New proxies go to", selection: $model.proxyNaming) {
                ForEach(ProxyNaming.allCases, id: \.self) { naming in
                    Text(naming.displayName).tag(naming)
                }
            }
            .pickerStyle(.radioGroup)
            Section("Editors on other computers") {
                Toggle("Write editor files with the other computer's paths", isOn: $model.editorIsOnAnotherComputer)
                ForEach($model.pathMappings) { $mapping in
                    HStack {
                        TextField("On this Mac", text: $mapping.macPrefix, prompt: Text("/Volumes/Media"))
                        Image(systemName: "arrow.right")
                        TextField("On the editor's computer", text: $mapping.editorPrefix, prompt: Text("Z:\\Media or /mnt/media"))
                        Button {
                            model.pathMappings.removeAll { $0.id == mapping.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .labelsHidden()
                }
                Button("Add Path Mapping") {
                    model.pathMappings.append(PathMapping(macPrefix: "", editorPrefix: ""))
                }
            }
            Section("External A.I.") {
                Text("After the on-device analysis, each enabled service is sent the clip's name, technical details, transcript and tags as JSON — never the media — and may reply with a summary and extra tags.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach($model.analysisHooks) { $hook in
                    HStack {
                        Toggle("Enabled", isOn: $hook.isEnabled)
                        TextField("Name", text: $hook.name, prompt: Text("Name"))
                            .frame(width: 110)
                        TextField("Address", text: $hook.url, prompt: Text("https://…"))
                        HookTokenField(hookID: hook.id)
                            .frame(width: 110)
                        Button {
                            Keychain.setToken("", for: hook.id)
                            model.analysisHooks.removeAll { $0.id == hook.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .labelsHidden()
                }
                Button("Add External A.I. Service") { model.analysisHooks.append(AnalysisHook()) }
            }
            Text("Every proxy keeps its source's name, timecode, duration, frame rate and audio layout, so Premiere Pro, DaVinci Resolve and Final Cut Pro can attach it to the original.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

/// Edits a hook's access token, which is kept in the keychain rather than in preferences.
struct HookTokenField: View {
    let hookID: String
    @State private var token = ""

    var body: some View {
        SecureField("Token", text: $token, prompt: Text("Token"))
            .onAppear { token = Keychain.token(for: hookID) ?? "" }
            .onChange(of: token) { _, value in Keychain.setToken(value, for: hookID) }
    }
}
